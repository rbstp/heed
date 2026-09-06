import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import FFMCore
import Foundation

final class Agent {
    private let systemWide = AXUIElementCreateSystemWide()
    private let queue = DispatchQueue(label: "\(bundleID).loop", qos: .userInitiated)
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    private var config: Config
    private var machine: DwellMachine<Target>
    private var timer: DispatchSourceTimer?
    private var hangupSource: DispatchSourceSignal?

    // Main thread only; `syncMenuBar` and `syncHotkey` are the hops from `queue`.
    private var menuBar: MenuBarController?
    private var hotkeys: [Hotkey] = []
    private var shortcut: HotkeySpec?
    /// Mirrors "the loop is idling", so a mouse event costs one bool test rather than a dispatch.
    private var wantsMouseWake = false
    private var mouseMonitor: Any?
    private var observersInstalled = false

    private var interval: Double = 0
    private var lastTickAt: Double = 0
    private var lastCursor = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    private var pendingInvalidation = false

    private var motion = MotionTracker(capacity: 5)
    /// The last window accepted as a focus target.
    private var lastResolved: Target?
    /// The last window under the pointer, whether or not it was allowed to take focus.
    private var lastPointerWindow: Target?
    /// False after a reset until a hit test has run: nil then means unknown, not "over nothing".
    private var pointerWindowKnown = false
    /// Whether the last hit test answered at all; false during a cooldown or with Accessibility revoked.
    private var hitTestAnswered = false
    private var pointerMovedThisTick = false
    private var handoverNotedThisTick = false

    /// Keyed by pid and validated against launch date, because pids are recycled.
    private var appElements: [pid_t: (element: AXUIElement, launched: Date?)] = [:]
    /// Apps that repeatedly failed to answer, so one hung process does not cost a timeout per tick.
    private var blockedUntil: [pid_t: Double] = [:]
    private var failureCounts: [pid_t: Int] = [:]

    private var isRunning = false
    private var overlayCached = false
    private var overlayCacheUntil: Double = 0
    private var handover = FocusHandover<Target>(settle: 0)
    private var holdingFocus = false
    private var lastStep: (from: Target?, to: Target)?
    private var lastStepAt: Double = 0
    private var promptCached = false
    private var promptCacheUntil: Double = 0
    private var hitTestFailures = 0
    private var hitTestCooldownUntil: Double = 0
    private var accessibilityLost = false
    private var lastResolvedName: String?

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    init() {
        config = Config.load()
        Log.verbose = config.verbose
        machine = DwellMachine(dwell: config.dwell)
    }

    // MARK: - Lifecycle

    /// Every mutation of agent state happens on `queue`.
    func start() {
        observeSystemEvents()
        queue.async { [self] in
            guard !isRunning else { return }

            // Passing the system-wide element sets the process-wide default. Per message, not per
            // tick, and a tick issues several.
            AXUIElementSetMessagingTimeout(systemWide, 0.1)

            isRunning = true
            scheduleTimer()
            syncMenuBar()
            Log.note("running: enabled=\(config.enabled) dwell=\(config.dwellMs)ms "
                + "poll=\(config.pollMs)ms raise=\(config.raise) "
                + "typingCooldown=\(config.typingCooldownMs)ms "
                + "handoverGuard=\(config.handoverGuard) "
                + "handoverSettle=\(config.handoverSettleMs)ms verbose=\(config.verbose)")
        }
    }

    private func invalidateFromSystemEvent() {
        queue.async { [self] in
            pendingInvalidation = true
            wakeLoop()
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        motion = MotionTracker(capacity: max(2, Int((0.2 / config.poll).rounded())))
        handover.settle = config.handoverSettle
        handover.travel = Double(config.entryMotionPx)

        guard config.enabled else {
            interval = 0
            setMouseWake(false)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        interval = 0
        retime(to: config.poll, startingNow: false)
    }

    /// Idling gets generous leeway so the system can coalesce the wakeup with others.
    private func retime(to wanted: Double, startingNow: Bool) {
        guard let timer, wanted != interval else { return }
        interval = wanted
        let idling = wanted > config.poll
        timer.schedule(
            deadline: startingNow ? .now() : .now() + wanted,
            repeating: wanted,
            leeway: idling ? .milliseconds(Int(wanted * 500)) : .milliseconds(10)
        )
        setMouseWake(idling)
    }

    private func setMouseWake(_ wanted: Bool) {
        DispatchQueue.main.async { [self] in wantsMouseWake = wanted }
    }

    private func wakeLoop() {
        retime(to: config.poll, startingNow: true)
    }

    /// Forget what the pointer was over, so the next tick adopts a baseline instead of acting on it.
    /// `machine.invalidate()` alone would let a stale `lastResolved` pass the entry guard and drag
    /// focus back to a window under a pointer that never moved.
    private func forgetTarget() {
        machine.invalidate()
        motion.reset()
        lastResolved = nil
        lastPointerWindow = nil
        pointerWindowKnown = false
        handover.reset()
    }

    /// Observe the pointer at the moment of a reset, so focus handed over right after it is judged
    /// against a real baseline rather than against nothing.
    private func seedPointerWindow() {
        guard config.enabled, let cursor = CGEvent(source: nil)?.location else { return }
        let target = hitTest(at: cursor)
        if hitTestAnswered { adoptPointerWindow(target) }
    }

    private func reload() {
        queue.async { [self] in
            config = Config.load()
            Log.verbose = config.verbose
            machine.dwell = config.dwell
            forgetTarget()
            if isRunning {
                scheduleTimer()
                seedPointerWindow()
            }
            syncMenuBar()
            syncHotkey()
            Log.note("reloaded config: dwell=\(config.dwellMs)ms poll=\(config.pollMs)ms "
                + "raise=\(config.raise) enabled=\(config.enabled)")
        }
    }

    // MARK: - Menu bar and hotkeys

    /// Installed before the Accessibility gate, so the switch works while the grant is outstanding.
    func installMenuBar() {
        queue.async { [self] in
            syncMenuBar()
            syncHotkey()
        }
    }

    /// Writes the same defaults key `defaults write` does, so the choice survives a restart.
    func toggleEnabled() {
        queue.async { [self] in
            let value = !config.enabled
            config.enabled = value
            Config.store().set(value, forKey: "enabled")

            forgetTarget()
            if isRunning {
                scheduleTimer()
                seedPointerWindow()
            }

            Log.note(value ? "enabled" : "disabled")
            syncMenuBar()
        }
    }

    private func syncMenuBar() {
        let wanted = config.menuBarIcon
        let enabled = config.enabled
        DispatchQueue.main.async { [self] in
            guard wanted else {
                menuBar?.remove()
                menuBar = nil
                return
            }
            if menuBar == nil {
                menuBar = MenuBarController(
                    onClick: { [weak self] in self?.toggleEnabled() },
                    onQuit: { quitHeed() },
                    onChooseModifier: { [weak self] preset in
                        self?.changeModifiers(to: preset) { accepted in
                            self?.menuBar?.flash(accepted: accepted)
                        }
                    }
                )
            }
            menuBar?.shortcut = shortcut
            // Read here rather than carried across the hop: trust can change at any moment.
            menuBar?.render(enabled: enabled, trusted: accessibilityTrusted(prompt: false))
        }
    }

    private enum Shortcut: CaseIterable {
        case toggle, focusNext, focusPrevious, focusWindow
        case focusLeft, focusRight, focusUp, focusDown

        var which: String {
            switch self {
            case .toggle: "toggles Heed"
            case .focusNext: "moves focus to the next window"
            case .focusPrevious: "moves focus to the previous window"
            case .focusWindow: "moves focus to a window by number"
            case .focusLeft, .focusRight, .focusUp, .focusDown:
                "moves focus \(direction?.rawValue ?? "")"
            }
        }

        var defaultsKey: String {
            switch self {
            case .toggle: "hotkey"
            case .focusNext: "focusNextHotkey"
            case .focusPrevious: "focusPreviousHotkey"
            case .focusWindow: "focusWindowHotkey"
            case .focusLeft: "focusLeftHotkey"
            case .focusRight: "focusRightHotkey"
            case .focusUp: "focusUpHotkey"
            case .focusDown: "focusDownHotkey"
            }
        }

        var keyPath: WritableKeyPath<Config, String> {
            switch self {
            case .toggle: \.hotkey
            case .focusNext: \.focusNextHotkey
            case .focusPrevious: \.focusPreviousHotkey
            case .focusWindow: \.focusWindowHotkey
            case .focusLeft: \.focusLeftHotkey
            case .focusRight: \.focusRightHotkey
            case .focusUp: \.focusUpHotkey
            case .focusDown: \.focusDownHotkey
            }
        }

        var direction: FocusDirection? {
            switch self {
            case .focusLeft: .left
            case .focusRight: .right
            case .focusUp: .up
            case .focusDown: .down
            default: nil
            }
        }
    }

    /// The registrations one setting asks for: one for most shortcuts, nine for the numbered
    /// windows, whose setting names the combination for window 1. Nil when it names another key.
    private func combinations(for shortcut: Shortcut, _ spec: HotkeySpec) -> [(HotkeySpec, () -> Void)]? {
        switch shortcut {
        case .toggle:
            return [(spec, { [weak self] in self?.toggleEnabled() })]
        case .focusNext:
            return [(spec, { [weak self] in self?.stepFocus(by: 1) })]
        case .focusPrevious:
            return [(spec, { [weak self] in self?.stepFocus(by: -1) })]
        case .focusWindow:
            guard spec.key == "1" else { return nil }
            return (1...9).compactMap { number in
                spec.withKey("\(number)").map { ($0, { [weak self] in self?.focusWindow(number) }) }
            }
        case .focusLeft, .focusRight, .focusUp, .focusDown:
            guard let direction = shortcut.direction else { return nil }
            return [(spec, { [weak self] in self?.focusDirection(direction) })]
        }
    }

    private var shortcutTexts: [String] {
        Shortcut.allCases.map { config[keyPath: $0.keyPath] }
    }

    /// Registers every hotkey, replacing the previous set. Whatever can be had is kept: a
    /// combination another app holds costs that one shortcut, not the other two.
    private func syncHotkey() {
        let texts = shortcutTexts
        DispatchQueue.main.async { [self] in
            hotkeys = []
            adopt(specs: [])

            let claimed = claim(texts)
            hotkeys = claimed.held
            adopt(specs: claimed.specs)
            announce(specs: claimed.specs)
        }
    }

    /// Claim combinations without releasing the current registrations, so a change can be tried
    /// before the working shortcuts are given up. `specs` is in `Shortcut.allCases` order; `refused`
    /// is only about combinations another app holds.
    private func claim(_ texts: [String]) -> (held: [Hotkey], specs: [HotkeySpec?], refused: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        var held: [Hotkey] = []
        var specs: [HotkeySpec?] = []
        var refused = false

        for (shortcut, text) in zip(Shortcut.allCases, texts) {
            guard !HotkeySpec.isOff(text) else {
                specs.append(nil)
                continue
            }
            let wanted = text.trimmingCharacters(in: .whitespaces)
            guard let spec = HotkeySpec(wanted) else {
                Log.note("hotkey \"\(wanted)\" is not a combination I understand "
                    + "(try cmd+ctrl+h); nothing \(shortcut.which)")
                specs.append(nil)
                continue
            }
            guard let combinations = combinations(for: shortcut, spec) else {
                Log.note("hotkey \"\(wanted)\" must end in 1, the other digits follow; nothing \(shortcut.which)")
                specs.append(nil)
                continue
            }
            var registered: [Hotkey] = []
            for (combination, action) in combinations {
                guard let hotkey = Hotkey(spec: combination, action: action) else { break }
                registered.append(hotkey)
            }
            guard registered.count == combinations.count else {
                specs.append(nil)
                refused = true   // Hotkey logs why; dropping the partial set unregisters it
                continue
            }
            held += registered
            specs.append(spec)
        }
        return (held, specs, refused)
    }

    private func announce(specs: [HotkeySpec?]) {
        for (shortcut, spec) in zip(Shortcut.allCases, specs) {
            guard let spec else { continue }
            let combination = shortcut == .focusWindow
                ? "\(spec.display) to \(spec.withKey("9")?.display ?? "?")"
                : spec.display
            Log.note("hotkey \(combination) \(shortcut.which)")
        }
    }

    private func adopt(specs: [HotkeySpec?]) {
        shortcut = specs.first.flatMap { $0 }
        menuBar?.shortcut = shortcut
        menuBar?.modifiers = specs.compactMap { $0 }.first?.modifiers
    }

    /// Put every shortcut under a different modifier, keeping each key. All or none, and stored only
    /// once it took. `report` is called on the main thread.
    func changeModifiers(to preset: ModifierPreset, report: @escaping (Bool) -> Void) {
        queue.async { [self] in
            let current = shortcutTexts
            let texts = current.map { rewriteHotkey($0, modifiers: preset.modifiers) }

            // Compared as combinations: the stored text is however it was typed, the rewrite is
            // canonical, and Carbon refuses a combination this process already holds.
            guard !zip(current, texts).allSatisfy({ HotkeySpec($0) == HotkeySpec($1) }) else {
                DispatchQueue.main.async { report(true) }
                return
            }

            DispatchQueue.main.async { [self] in
                let claimed = claim(texts)
                guard !claimed.refused else {
                    Log.note("keeping the current shortcuts: \(preset.display) is not free")
                    report(false)
                    return
                }
                hotkeys = claimed.held
                adopt(specs: claimed.specs)
                announce(specs: claimed.specs)

                queue.async { [self] in
                    // A SIGHUP reload can have changed the configuration in between; it wins.
                    guard shortcutTexts == current else {
                        Log.note("the configuration changed while \(preset.display) was being "
                            + "applied; keeping what it says instead")
                        syncHotkey()
                        DispatchQueue.main.async { report(false) }
                        return
                    }

                    let store = Config.store()
                    for (shortcut, text) in zip(Shortcut.allCases, texts) {
                        store.set(text, forKey: shortcut.defaultsKey)
                        config[keyPath: shortcut.keyPath] = text
                    }
                    Log.note("shortcuts now use \(preset.display)")
                    DispatchQueue.main.async { report(true) }
                }
            }
        }
    }

    // MARK: - Main loop

    private func tick() {
        guard config.enabled else { return }

        let sinceLastTick = lastTickAt > 0 ? now - lastTickAt : 0
        lastTickAt = now

        // Deadlines of our own change what is focusable with nothing to announce it, so each one
        // re-arms a hit test as it expires.
        if let soonest = blockedUntil.values.min(), now >= soonest {
            blockedUntil = blockedUntil.filter { $0.value > now }
            machine.invalidate()
        }
        if hitTestCooldownUntil > 0, now >= hitTestCooldownUntil {
            hitTestCooldownUntil = 0
            machine.invalidate()
        }
        if handover.isSettling { machine.invalidate() }

        // A whole suppression (Cmd-Tab and its cooldown) can begin and end between two heartbeats.
        // Asking whether any input is newer than the last tick needs no key monitor.
        if sinceLastTick > config.poll * 2, secondsSinceAny(of: Agent.suppressingInputs) < sinceLastTick {
            Log.debug("input arrived while idling; re-deriving")
            machine.invalidate()
        }

        var cursor = CGEvent(source: nil)?.location ?? lastCursor
        let moved = cursor != lastCursor
        motion.record(lastCursor.x.isFinite ? hypot(cursor.x - lastCursor.x, cursor.y - lastCursor.y) : 0)
        lastCursor = cursor
        pointerMovedThisTick = moved
        // Asked before the guards: a pointer leaving the window it was handed from is readable
        // whether or not this tick may act on it. Only when the pointer moved, which is both a
        // window server round trip saved and the point of the question: a window arriving under a
        // pointer that has not moved is not the pointer leaving.
        if config.handoverGuard, moved, cursor.x.isFinite, holdingApplies {
            handover.notePointer(cursor, under: windowNumber(under: cursor))
        }

        // Before the machine can undo it: a forced hit test this tick would take focus straight back.
        // A warp moves the pointer out from under the position this tick read.
        if let warped = noteHandover() { cursor = warped }

        let condition = currentCondition(cursorMoved: moved)
        if condition == .invalidating {
            motion.reset()
            lastResolved = nil
        }

        let target = machine.tick(
            now: now,
            condition: condition,
            cursorMoved: moved,
            hitTest: { self.hitTestForFocus(at: cursor) },
            isAlreadyFocused: { self.focusMatches($0) }
        )

        defer { retime(to: hasPendingWork(cursorMoved: moved) ? config.poll : config.idlePoll,
                       startingNow: false) }

        guard let target else { return }

        // Time passes regardless of dwell: the window can close, minimize or move during the reads.
        guard let confirmed = hitTest(at: cursor), confirmed == target else {
            Log.debug("target changed before it could be focused; discarding \(target.describedAs)")
            machine.invalidate()
            return
        }

        // Stealing focus would raise another window over the prompt, and a buried prompt can never
        // be reached by pointer again.
        if config.promptGuard, frontmostPromptAwaitsAnswer() {
            Log.debug("not focusing \(confirmed.describedAs): a prompt awaits an answer "
                + "in the frontmost app")
            machine.invalidate()
            return
        }

        if !applyFocus(to: confirmed) {
            machine.invalidate()
        }
    }

    /// Whether anything can still change without new input, so the loop can drop to the heartbeat.
    private func hasPendingWork(cursorMoved: Bool) -> Bool {
        if cursorMoved || pendingInvalidation || machine.needsTick { return true }
        if now < hitTestCooldownUntil { return true }
        // Asked after `machine.tick` spent the forced test, so the settle has to be counted here.
        if handover.isSettling { return true }
        if let soonest = blockedUntil.values.min(), soonest > now { return true }
        return false
    }

    // MARK: - Guards

    private func currentCondition(cursorMoved: Bool) -> TickCondition {
        if pendingInvalidation {
            pendingInvalidation = false
            Log.debug("invalidated by a system event")
            return .invalidating
        }

        // An instantaneous snapshot; the grace period covers presses it cannot see.
        if NSEvent.pressedMouseButtons != 0 { return .suppressing }

        if config.clickGraceMs > 0, secondsSinceAny(of: Agent.deliberateMouseEvents) < config.clickGrace {
            return .suppressing
        }

        if config.typingCooldownMs > 0,
           CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            < config.typingCooldown {
            return .suppressing
        }

        if IsSecureEventInputEnabled() { return .suppressing }

        if config.ignoreWhenCommandHeld,
           CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
            return .suppressing
        }

        // Only worth a round trip while something is pending, including a hit test armed by the
        // previous tick.
        if config.menuGuard, cursorMoved || machine.needsTick, overlayPresent() {
            return .suppressing
        }

        return .normal
    }

    /// Releases as well as presses, so the grace after a drag starts at the drop.
    private static let deliberateMouseEvents: [CGEventType] = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseUp, .rightMouseUp, .otherMouseUp,
    ]

    /// Every input that can start a suppression; `flagsChanged` covers a Cmd-Tab with no keyDown.
    private static let suppressingInputs: [CGEventType] = deliberateMouseEvents + [
        .keyDown, .flagsChanged,
    ]

    private func secondsSinceAny(of types: [CGEventType]) -> Double {
        types.reduce(Double.greatestFiniteMagnitude) { earliest, type in
            min(earliest, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type))
        }
    }

    /// Whether a menu, popover or drag image is on screen, judged by window level: while a menu is
    /// open the focused element can still report the control underneath it. Cached briefly, since
    /// enumerating windows is a window server round trip.
    private func overlayPresent() -> Bool {
        if now < overlayCacheUntil { return overlayCached }
        overlayCacheUntil = now + 0.1

        // Pop-up menus through drag images. Higher levels hold always-present assistive windows.
        let levels = Int(CGWindowLevelForKey(.popUpMenuWindow))..<Int(CGWindowLevelForKey(.screenSaverWindow))
        let overlay = onScreenWindows().first { levels.contains($0.level) && $0.pid != ownPid }
        if let overlay {
            Log.debug("suppressed: overlay on screen (\(overlay.owner ?? "?") at level \(overlay.level))")
        }
        overlayCached = overlay != nil
        return overlayCached
    }

    // MARK: - Window server

    private struct ListedWindow {
        let number: Int
        let pid: pid_t
        let level: Int
        let frame: CGRect
        let owner: String?
    }

    /// What is on screen in this Space, front to back. Decoded lazily, so a search stops early.
    private func onScreenWindows() -> some Sequence<ListedWindow> {
        let listed = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return listed.lazy.compactMap { window -> ListedWindow? in
            guard let number = window[kCGWindowNumber as String] as? Int,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let level = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return ListedWindow(number: number, pid: pid, level: level, frame: frame,
                                owner: window[kCGWindowOwnerName as String] as? String)
        }
    }

    /// The displays, in the top-left-origin space Accessibility uses. `NSScreen` is main-thread only.
    private func screenFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        // Mirrored displays report identical bounds.
        var frames: [CGRect] = []
        for id in ids.prefix(Int(count)) {
            let bounds = CGDisplayBounds(id)
            if !frames.contains(bounds) { frames.append(bounds) }
        }
        return frames
    }

    // MARK: - Hit testing

    /// The hit test that drives focus, with the handover and entry guards applied. A window that
    /// appears under a still pointer has not been moved onto.
    private func hitTestForFocus(at point: CGPoint) -> Target? {
        let target = hitTest(at: point)
        guard let target else {
            handover.abandonContest()
            // Crossing the menu bar, the Dock or a gap keeps the last window as the baseline; only a
            // stationary, answered nil is a real observation.
            if hitTestAnswered, !pointerMovedThisTick {
                adoptPointerWindow(nil)
            }
            return nil
        }
        adoptPointerWindow(target)
        noteMovingPointerBaseline(window: target)

        switch handoverDecision(for: target) {
        case .hold:
            if !holdingFocus {
                holdingFocus = true
                Log.debug("not focusing \(target.describedAs): focus was handed to "
                    + "\(frontmostName()) and the pointer has not settled anywhere else since")
            }
            return nil
        case .entered:
            holdingFocus = false
            Log.debug("settled on \(target.describedAs); following the pointer again")
            lastResolved = target
            return target
        case .free:
            holdingFocus = false
        }

        if config.entryMotionPx > 0, motion.total < Double(config.entryMotionPx) {
            guard let previous = lastResolved else {
                lastResolved = target
                Log.debug("baseline \(target.describedAs): not focusing without pointer movement")
                return nil
            }
            if previous != target {
                // The baseline is deliberately not updated, or the next tick would accept it.
                Log.debug("ignoring \(target.describedAs): it arrived under a near-stationary "
                    + "pointer (\(Int(motion.total.rounded()))px of recent travel)")
                return nil
            }
        }

        lastResolved = target
        return target
    }

    private func handoverDecision(for target: Target) -> HandoverDecision {
        guard config.handoverGuard, handover.isHolding,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != ownPid
        else { return .free }
        return handover.decide(
            for: target, frontmost: front, pointer: pointerLocation,
            pointerMoved: pointerMovedThisTick, travelling: pointerIsTravelling, at: now
        )
    }

    /// The entry guard's own test, except at threshold 0 where any travel at all stands in for it.
    private var pointerIsTravelling: Bool {
        config.entryMotionPx > 0
            ? motion.total >= Double(config.entryMotionPx)
            : motion.total > 0
    }

    /// Ask, once a tick and before resolving the new pointer position, whether the window last under
    /// the pointer still holds focus. Movement cannot explain focus leaving a window Heed has not
    /// acted on yet.
    @discardableResult
    private func noteHandover() -> CGPoint? {
        handoverNotedThisTick = false
        guard config.handoverGuard, pointerWindowKnown, sampleHandover() else { return nil }
        handoverNotedThisTick = true

        Log.debug("focus was handed to \(frontmostName()); it keeps it until the pointer settles "
            + "somewhere else")
        let warped = warpAfterHandover()
        // A dwell candidate formed before this must not land: the pre-apply revalidation uses the
        // raw hit test, which knows nothing about holds.
        machine.invalidate()
        return warped
    }

    private func sampleHandover() -> Bool {
        let window = lastPointerWindow
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return handover.sample(
            window: window, hasFocus: window.map { focusMatches($0) }, anchor: anchor(for: window),
            number: windowNumber(under: pointerLocation), pointer: pointerLocation,
            owner: front == ownPid ? nil : front, pointerMoved: false
        )
    }

    /// Record what an answered hit test found under the pointer. The first observation after a reset
    /// also seeds the handover baseline: sampling before it would record "over nothing" and read the
    /// real window as having arrived under a still pointer.
    private func adoptPointerWindow(_ target: Target?) {
        lastPointerWindow = target
        guard !pointerWindowKnown else { return }
        pointerWindowKnown = true
        if config.handoverGuard { _ = sampleHandover() }
    }

    /// Whether a hold could act on this tick at all: only the frontmost app's is ever consulted, so
    /// asking the window server about the pointer for any other is work nothing can use.
    private var holdingApplies: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return false
        }
        return front != ownPid && handover.isHolding(owner: front)
    }

    /// The pointer as a hold should record it. Nil until a tick has read it: a position that is not
    /// known yet must not read as one the pointer has left.
    private var pointerLocation: CGPoint? { lastCursor.x.isFinite ? lastCursor : nil }

    /// An app-level target compares equal for every window of its app, so it cannot anchor a hold.
    private func anchor(for window: Target?) -> Target? {
        window?.window == nil ? nil : window
    }

    /// The window the window server has under the pointer, ignoring anything above the ordinary
    /// level. Its number identifies the window the pointer is on when no hit test may run.
    private func windowNumber(under point: CGPoint?) -> Int? {
        guard let point else { return nil }
        return onScreenWindows().first {
            $0.level == 0 && $0.pid != ownPid && $0.frame.contains(point)
        }?.number
    }

    /// Record the newly resolved window as the next comparison's baseline, except on the tick a hold
    /// was just discovered: that hold has to judge the movement rather than be overwritten by it.
    private func noteMovingPointerBaseline(window: Target?) {
        guard config.handoverGuard, pointerMovedThisTick, !handoverNotedThisTick,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != ownPid
        else { return }

        handover.sample(
            window: window, hasFocus: nil, anchor: anchor(for: window),
            number: nil, pointer: pointerLocation, owner: front, pointerMoved: true
        )
    }

    private func frontmostName() -> String {
        NSWorkspace.shared.frontmostApplication?.describedAs ?? "another app"
    }

    private func hitTest(at point: CGPoint) -> Target? {
        hitTestAnswered = false
        if now < hitTestCooldownUntil { return nil }

        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &hit
        )

        if accessibilityLost, error != .apiDisabled {
            accessibilityLost = false
            syncMenuBar()
            Log.note("Accessibility access returned")
        }

        switch error {
        case .success:
            hitTestFailures = 0
            hitTestAnswered = true
        case .cannotComplete:
            hitTestFailures += 1
            if hitTestFailures >= 3 {
                hitTestCooldownUntil = now + 2
                hitTestFailures = 0
                Log.debug("hit test timing out; backing off for 2s")
            }
            return nil
        case .notImplemented, .attributeUnsupported:
            // Genuinely no usable tree: some games, XQuartz, a few Java toolkits.
            hitTestAnswered = true
            return appLevelFallback(at: point)
        case .noValue:
            hitTestAnswered = true
            return nil
        case .apiDisabled:
            if !accessibilityLost {
                accessibilityLost = true
                syncMenuBar()
                Log.note("Accessibility access is no longer granted; waiting for it to return")
            }
            return nil
        default:
            Log.debug("hit test failed: AXError \(error.rawValue)")
            return nil
        }

        guard let element = hit else { return appLevelFallback(at: point) }
        return resolveWindow(from: element)
    }

    private enum WindowElement {
        case sheet
        case none(elementRole: String?, topLevelRole: String?)
        case window(AXUIElement, via: WindowSource)
    }

    private func windowElement(from element: AXUIElement) -> WindowElement {
        let elementRole = axString(element, kAXRoleAttribute)
        let topLevel = axElement(element, kAXTopLevelUIElementAttribute)
        let topLevelRole = topLevel.flatMap { axString($0, kAXRoleAttribute) }

        switch resolveWindowSource(topLevelRole: topLevelRole, elementRole: elementRole) {
        case .sheet:
            return .sheet
        case .tryInOrder(let sources):
            for source in sources {
                let candidate: AXUIElement? = switch source {
                case .topLevel: topLevel
                case .windowAttribute: axElement(element, kAXWindowAttribute)
                case .hitElement: element
                }
                if let candidate { return .window(candidate, via: source) }
            }
            return .none(elementRole: elementRole, topLevelRole: topLevelRole)
        }
    }

    private func resolveWindow(from element: AXUIElement) -> Target? {
        guard let pid = axPid(element), pid != ownPid, let app = eligibleApp(pid: pid) else {
            return nil
        }

        let window: AXUIElement
        switch windowElement(from: element) {
        case .sheet:
            Log.debug("skipped: the pointer is over a sheet")
            return nil
        case let .none(elementRole, topLevelRole):
            Log.debug("skipped: nothing window-shaped under the pointer "
                + "(element \(elementRole ?? "?"), top level \(topLevelRole ?? "none"))")
            return nil
        case let .window(found, _):
            window = found
        }

        let size = axSize(window, kAXSizeAttribute)
        let title = axString(window, kAXTitleAttribute)
        let candidate = windowCandidate(window, size: size, title: title, bundleID: app.bundleIdentifier)
        if case let .reject(why) = evaluate(candidate, policy: config.windowPolicy) {
            Log.debug("skipped: \(why)")
            return nil
        }

        guard let size else { return nil }
        let frame = axPoint(window, kAXPositionAttribute)
            .map { CGRect(origin: $0, size: size) } ?? .null

        let name = app.describedAs
        if name != lastResolvedName {
            lastResolvedName = name
            Log.debug("cursor over \(name)")
        }
        return Target(
            pid: pid, window: window, bundleID: app.bundleIdentifier,
            frame: frame, title: title, describedAs: name
        )
    }

    /// App-level target for windows with no usable Accessibility tree.
    private func appLevelFallback(at point: CGPoint) -> Target? {
        guard let window = onScreenWindows().first(where: {
            $0.level == 0 && $0.pid != ownPid && $0.frame.contains(point)
        }) else { return nil }
        guard let app = eligibleApp(pid: window.pid) else { return nil }

        Log.debug("no AX tree at cursor; falling back to app level for \(app.describedAs)")
        return Target(
            pid: window.pid, window: nil, bundleID: app.bundleIdentifier,
            frame: window.frame, title: nil, describedAs: app.describedAs
        )
    }

    /// The app owning `pid`, unless it is blocked, cannot be activated, or is excluded. Checked
    /// before any attribute read, since hovering an excluded app (the Dock) is constant.
    private func eligibleApp(pid: pid_t) -> NSRunningApplication? {
        if let until = blockedUntil[pid], now < until { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy != .prohibited
        else { return nil }
        if let bundle = app.bundleIdentifier, config.excludedBundleIDs.contains(bundle) {
            Log.debug("skipped: excluded \(bundle)")
            return nil
        }
        return app
    }

    private func windowCandidate(
        _ window: AXUIElement, size: CGSize?, title: String?, bundleID: String?
    ) -> WindowCandidate {
        WindowCandidate(
            role: axString(window, kAXRoleAttribute),
            subrole: axString(window, kAXSubroleAttribute),
            isModal: axBool(window, kAXModalAttribute) == true,
            isMinimized: axBool(window, kAXMinimizedAttribute) == true,
            size: size,
            title: title,
            bundleID: bundleID,
            canActivate: true
        )
    }

    // MARK: - Applying focus

    /// Move focus and confirm it moved. Only `activate` moves focus on this OS; the Accessibility
    /// writes cost one message each and may matter elsewhere, so they are fired but not waited on.
    ///
    /// `followingPointer` is false for the focus-ring shortcuts: focus moved by keyboard is what a
    /// hold is for, so the change is left for `noteHandover` to discover like a Cmd-Tab.
    private func applyFocus(to target: Target, followingPointer: Bool = true) -> Bool {
        let app = appElement(for: target.pid)

        var wantedWindow = false
        var gotWindow = false
        if let window = target.window {
            wantedWindow = true
            if config.raise { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
            gotWindow = axSet(window, kAXMainAttribute, kCFBooleanTrue) == .success
        }

        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        axSet(app, kAXFrontmostAttribute, kCFBooleanTrue)
        if let window = target.window, axIsSettable(window, kAXFocusedAttribute) {
            gotWindow = axSet(window, kAXFocusedAttribute, kCFBooleanTrue) == .success || gotWindow
        }

        // The shortcut asked for a particular window; the log is the only place that can explain a
        // press that appears to do nothing.
        if !followingPointer, wantedWindow, !gotWindow {
            Log.note("\(target.describedAs) refused both AXMain and AXFocused for this window; "
                + "it was brought forward, but not that window of it")
        }

        guard verifyFocus(target) else {
            noteFailure(pid: target.pid)
            return false
        }
        failureCounts[target.pid] = nil
        if followingPointer {
            handover.noteAppliedFocus(window: target, owner: target.pid)
        }
        return true
    }

    /// Wait for the app to become frontmost. NSWorkspace rather than `AXFocusedApplication`, which
    /// returns nothing when the focused app has no usable AX tree. The budget blocks `queue`, so it
    /// is tight; a failure retries on the next tick.
    private func verifyFocus(_ target: Target) -> Bool {
        let started = now
        while true {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
                Log.debug("focused \(target.describedAs) in \(Int((now - started) * 1000))ms")
                return true
            }
            if now - started >= config.verifyTimeout {
                let holder = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing"
                Log.debug("verify timed out after \(config.verifyTimeoutMs)ms: "
                    + "focus is on \(holder), wanted \(target.describedAs)")
                return false
            }
            usleep(10_000)
        }
    }

    /// Live check against system focus.
    private func focusMatches(_ target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            return false
        }
        guard let window = target.window else { return true }

        let app = appElement(for: target.pid)
        guard let focusedWindow = axElement(app, kAXFocusedWindowAttribute) else {
            return true
        }
        if CFEqual(focusedWindow, window) { return true }

        // Reported as focused so the machine settles instead of fighting a dialog or a prompt.
        let focusedSubrole = axString(focusedWindow, kAXSubroleAttribute)
        if transientWindowHoldsFocus(subrole: focusedSubrole) {
            Log.debug("\(target.describedAs): a \(focusedSubrole ?? "?") window holds the app's "
                + "key focus; leaving it")
            return true
        }
        if config.promptGuard, frontmostPromptAwaitsAnswer() {
            Log.debug("\(target.describedAs): a prompt awaits an answer; leaving key focus alone")
            return true
        }

        // Electron: same window, different element. Anything unreadable counts as no match, which
        // costs a redundant activate of an app that is already frontmost.
        guard !target.frame.isNull, axFrame(focusedWindow) == target.frame else { return false }
        return axString(focusedWindow, kAXTitleAttribute) == target.title
    }

    private func noteFailure(pid: pid_t) {
        let count = (failureCounts[pid] ?? 0) + 1
        failureCounts[pid] = count
        if count >= 3 {
            blockedUntil[pid] = now + 10
            failureCounts[pid] = 0
            Log.note("pid \(pid) is not responding to focus requests; skipping it for 10s")
        }
    }

    // MARK: - Mouse follows focus

    /// A click that brought an app forward left the pointer where the user put it. Its own grace,
    /// because `clickGraceMs` is about pointer focus and may legitimately be zero.
    private static let warpClickGrace: Double = 0.25

    /// Move the pointer into a window that just took focus, so pointer focus and keyboard focus
    /// agree rather than fight: the next hit test resolves the window that already has focus.
    /// Returns where it landed, or nil when nothing moved.
    private func warpPointer(into frame: CGRect, why: String) -> CGPoint? {
        guard config.warpPointer else { return nil }
        let cursor = CGEvent(source: nil)?.location ?? pointerLocation
        guard let point = warpPoint(into: frame, xPercent: config.warpX, yPercent: config.warpY,
                                    pointer: cursor, screens: screenFrames())
        else { return nil }

        CGWarpMouseCursorPosition(point)
        // Without this the system swallows mouse movement for about a quarter second after a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
        Log.debug("warped the pointer to \(Int(point.x)), \(Int(point.y)): \(why)")

        // Re-seeded, or the jump reads as the user moving the mouse on the next tick.
        lastCursor = point
        motion.reset()
        let under = hitTest(at: point)
        if hitTestAnswered { adoptPointerWindow(under) }
        machine.invalidate()
        return point
    }

    /// Follow focus that arrived without the pointer: Cmd-Tab, an app activating, a window picked
    /// from Raycast. The hold this tick just declared is re-declared around the new position, so
    /// the pointer has to leave the window it was put in before focus can move again.
    private func warpAfterHandover() -> CGPoint? {
        guard config.warpPointer,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ownPid
        else { return nil }

        // Never out of a drag, and never off a click: this is for focus the keyboard moved.
        guard NSEvent.pressedMouseButtons == 0,
              secondsSinceAny(of: Agent.deliberateMouseEvents)
                >= max(config.clickGrace, Agent.warpClickGrace)
        else { return nil }

        guard let window = axElement(appElement(for: front.processIdentifier), kAXFocusedWindowAttribute),
              let frame = axFrame(window)
        else { return nil }

        // Raycast's own palette is an excluded bundle, so opening it never drags the cursor onto it.
        let candidate = windowCandidate(window, size: frame.size,
                                        title: axString(window, kAXTitleAttribute),
                                        bundleID: front.bundleIdentifier)
        if case let .reject(why) = evaluate(candidate, policy: config.windowPolicy) {
            Log.debug("not warping to \(front.describedAs): \(why)")
            return nil
        }

        guard let point = warpPointer(into: frame, why: "focus was handed to \(front.describedAs)")
        else { return nil }
        handover.noteKeyboardFocus(anchor: anchor(for: lastPointerWindow),
                                   number: windowNumber(under: point), pointer: point,
                                   owner: front.processIdentifier)
        return point
    }

    // MARK: - Focus ring

    /// Move keyboard focus around the ring of visible windows. Runs whether or not Heed is
    /// switched on: `enabled` is about the mouse. `choose` picks the ring index to land on.
    private func moveFocus(_ what: String, choose: @escaping (Ring, _ live: Int?, _ front: pid_t?) -> Int?) {
        queue.async { [self] in
            guard accessibilityTrusted(prompt: false) else {
                Log.note("\(what): no Accessibility permission yet")
                return
            }

            guard let ring = focusRing() else { return }
            let windows = ring.windows
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let live = liveFocusIndex(in: windows, frontmost: front)
            guard let index = choose(ring, live, front) else { return }

            // Building the ring is many cross-process calls; a window can go away during them.
            let target = windows[index]
            guard let window = target.window,
                  axString(window, kAXRoleAttribute) == kAXWindowRole,
                  axBool(window, kAXMinimizedAttribute) != true
            else {
                Log.debug("\(what): \(target.describedAs) went away while the ring was being built")
                return
            }

            Log.debug("\(what) to \(target.describedAs) -- \(target.title ?? "untitled") "
                + "(\(index + 1) of \(windows.count))")

            // Where the pointer is now, not as of the last tick: movement before the keystroke must
            // not release the hold this declares. Written back so `noteHandover` samples the same
            // window; a hit test that could not answer leaves the last answer standing, since "over
            // nothing" is a claim only an answered one can make.
            let cursor = CGEvent(source: nil)?.location ?? pointerLocation
            let under = cursor.flatMap { hitTest(at: $0) }
            if hitTestAnswered { adoptPointerWindow(under) }
            // Before the focus is applied: raising the target can put it under the pointer.
            let number = cursor.flatMap { windowNumber(under: $0) }

            guard applyFocus(to: target, followingPointer: false) else { return }
            // Recorded even when the app refused the window, so the shortcut walks past such
            // windows rather than stopping dead on the first.
            lastStep = (from: live.map { windows[$0] }, to: target)
            lastStepAt = now

            // The pointer moves before the hold is declared, so the hold anchors where it lands.
            let warped = warpPointer(into: target.frame, why: "\(what) to \(target.describedAs)")

            // A step between two windows of the frontmost app changes nothing `noteHandover` can
            // see, so the hold is declared here.
            if config.handoverGuard {
                handover.noteKeyboardFocus(
                    anchor: anchor(for: lastPointerWindow),
                    number: warped.map { windowNumber(under: $0) } ?? number,
                    pointer: warped ?? cursor, owner: target.pid
                )
            }
            machine.invalidate()
            wakeLoop()
        }
    }

    private func stepFocus(by delta: Int) {
        moveFocus(delta > 0 ? "focus step forward" : "focus step back") { [self] ring, live, front in
            let windows = ring.windows
            // The last step is honoured only while it can still describe the same gesture.
            let recent = now - lastStepAt < 1 ? lastStep : nil
            // Focus on something the ring cannot name steps on from where that app sits.
            let from = ringStart(in: windows, live: live, lastStep: recent)
                ?? front.flatMap { pid in windows.firstIndex { $0.pid == pid } }

            // Starting from the first window is a fair guess for an app with nothing in the ring,
            // not for one that failed to answer.
            if from == nil, let front, ring.unanswered.contains(front) {
                let name = NSRunningApplication(processIdentifier: front)?.describedAs ?? "pid \(front)"
                Log.note("focus step: \(name) did not answer, so there is no telling where to step from")
                return nil
            }

            guard let index = ringStep(count: windows.count, from: from, by: delta) else {
                Log.debug("focus step ignored: no windows in the ring")
                return nil
            }
            return index
        }
    }

    /// Focus the nearest window in a direction, starting from the one that has focus.
    private func focusDirection(_ direction: FocusDirection) {
        moveFocus("focus \(direction.rawValue)") { ring, live, front in
            let windows = ring.windows
            let source = live ?? front.flatMap { pid in windows.firstIndex { $0.pid == pid } }
            guard let source else {
                Log.debug("focus \(direction.rawValue): focus is on nothing the ring can name, "
                    + "so there is no telling where to step from")
                return nil
            }

            // Ring order is the tie-break, so equally near windows resolve the way the ring runs.
            let candidates = windows.enumerated().map { RingWindow(frame: $1.frame, key: $0) }
            guard let index = directionalStep(from: windows[source].frame, in: candidates, direction)
            else {
                Log.debug("focus \(direction.rawValue): no window that way")
                return nil
            }
            return index
        }
    }

    /// Focus the window with this number in ring order, the way Hyprland switches workspaces.
    private func focusWindow(_ number: Int) {
        moveFocus("focus window \(number)") { ring, _, _ in
            guard ring.windows.indices.contains(number - 1) else {
                Log.note("focus window \(number): only \(ring.windows.count) windows on screen")
                return nil
            }
            return number - 1
        }
    }

    private struct Ring {

        let windows: [Target]
        /// Apps asked for their windows that did not answer, as opposed to having none.
        let unanswered: Set<pid_t>
    }

    /// Every visible window the shortcuts can reach, in ring order. The window server says what is
    /// on screen in this Space and in what order; Accessibility judges each window and hands back
    /// the element to focus. Apps with no usable tree are left out: several windows that cannot be
    /// told apart would be one entry the shortcut could never step between.
    private func focusRing() -> Ring? {
        let stack = onScreenWindows().filter { $0.level == 0 }
        let frames = stack.map(\.frame)

        // Set before the visibility pass, whose cost grows with the square of the window count.
        let deadline = now + 0.5

        var onScreen: [pid_t: [ListedWindow]] = [:]
        for (depth, window) in stack.enumerated() {
            if now > deadline { return outOfTime() }
            // Tested against everything in front whoever owns it; our own windows are dropped after.
            guard isVisible(window.frame, behind: frames[..<depth]), window.pid != ownPid else { continue }
            onScreen[window.pid, default: []].append(window)
        }

        var targets: [Int: Target] = [:]
        var ring: [RingWindow] = []
        var unanswered: Set<pid_t> = []

        // Exceeding the budget abandons the whole ring: a partial one is an arbitrary subset.
        for (pid, listed) in onScreen {
            if now > deadline { return outOfTime() }
            guard let app = eligibleApp(pid: pid) else { continue }
            guard let windows = axCopy(appElement(for: pid), kAXWindowsAttribute) as? [AXUIElement]
            else {
                unanswered.insert(pid)
                continue
            }

            let bundle = app.bundleIdentifier
            let name = app.describedAs
            var claimed: Set<Int> = []

            for window in windows {
                if now > deadline { return outOfTime() }
                // Position and size first: an app's window list spans every Space, and nothing else
                // is read until a window matches something on screen.
                guard let frame = axFrame(window) else {
                    unanswered.insert(pid)
                    continue
                }
                guard let listing = listed.first(where: {
                    !claimed.contains($0.number) && framesAgree($0.frame, frame)
                }) else { continue }
                claimed.insert(listing.number)

                let title = axString(window, kAXTitleAttribute)
                let candidate = windowCandidate(window, size: frame.size, title: title, bundleID: bundle)
                if case let .reject(why) = evaluate(candidate, policy: config.windowPolicy) {
                    Log.debug("ring skips a window of \(name): \(why)")
                    continue
                }

                targets[listing.number] = Target(
                    pid: pid, window: window, bundleID: bundle,
                    frame: frame, title: title, describedAs: name
                )
                ring.append(RingWindow(frame: frame, key: listing.number))
            }
        }

        // The checkpoints above are all before a read; the last read can run past the deadline.
        if now > deadline { return outOfTime() }

        return Ring(
            windows: ringOrder(ring, screens: screenFrames()).compactMap { targets[$0.key] },
            unanswered: unanswered
        )
    }

    private func outOfTime() -> Ring? {
        Log.note("gave up building the focus ring after 500ms; some app is not answering")
        return nil
    }

    /// Which ring entry holds focus, or nil when focus is on something the ring does not contain.
    private func liveFocusIndex(in ring: [Target], frontmost front: pid_t?) -> Int? {
        guard let front, front != ownPid,
              let focused = axElement(appElement(for: front), kAXFocusedWindowAttribute)
        else { return nil }

        // Identity across the whole ring first: two maximised windows share a frame, and taking
        // geometry as soon as CFEqual failed would answer with whichever came first.
        if let index = ring.firstIndex(where: { candidate in
            guard candidate.pid == front, let window = candidate.window else { return false }
            return CFEqual(window, focused)
        }) {
            return index
        }

        // Exact, unlike `framesAgree`: both sides are Accessibility's own report.
        guard let frame = axFrame(focused) else { return nil }
        let title = axString(focused, kAXTitleAttribute)
        return ring.firstIndex { $0.pid == front && $0.frame == frame && $0.title == title }
    }

    /// Whether the window server's rectangle and Accessibility's describe the same window. Tolerant
    /// only because they are separate reports from separate APIs.
    private func framesAgree(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= 2 && abs(a.origin.y - b.origin.y) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    // MARK: - Caches

    /// Whether the frontmost app's key window is a prompt mid-question. Cached briefly; nothing is
    /// read unless the frontmost app has a prompt rule.
    private func frontmostPromptAwaitsAnswer() -> Bool {
        if now < promptCacheUntil { return promptCached }
        promptCacheUntil = now + 0.25
        promptCached = false
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ownPid,
           let bundle = front.bundleIdentifier,
           config.promptRules.contains(where: { $0.bundleID == bundle }),
           let key = axElement(appElement(for: front.processIdentifier), kAXFocusedWindowAttribute) {
            promptCached = windowAwaitsAnswer(
                identifier: axString(key, kAXIdentifierAttribute),
                bundleID: bundle,
                buttonCount: windowLevelButtonCount(key),
                promptRules: config.promptRules
            )
        }
        return promptCached
    }

    /// Buttons that are direct children of the window; buttons inside its content do not count.
    private func windowLevelButtonCount(_ window: AXUIElement) -> Int {
        guard let children = axCopy(window, kAXChildrenAttribute) as? [AXUIElement] else { return 0 }
        return children.filter { axString($0, kAXRoleAttribute) == kAXButtonRole }.count
    }

    private func appElement(for pid: pid_t) -> AXUIElement {
        let launched = NSRunningApplication(processIdentifier: pid)?.launchDate
        // A nil launch date never matches; creating the element again is local work.
        if let cached = appElements[pid], let launched, cached.launched == launched {
            return cached.element
        }
        let element = AXUIElementCreateApplication(pid)
        appElements[pid] = (element, launched)
        return element
    }

    // MARK: - System events

    private func observeSystemEvents() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !observersInstalled else { return }
        observersInstalled = true

        let center = NSWorkspace.shared.notificationCenter

        for name: NSNotification.Name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.invalidateFromSystemEvent()
            }
        }

        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            queue.async {
                self.appElements[pid] = nil
                self.blockedUntil[pid] = nil
                self.failureCounts[pid] = nil
                self.handover.forget(owner: pid)
            }
        }

        // An optimisation, not the mechanism: the idle heartbeat covers anything this never sees,
        // including events delivered to this process itself. Mouse-up is here because a click can
        // change what is frontmost without the pointer travelling.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                       .leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] _ in
            guard let self, wantsMouseWake else { return }
            wantsMouseWake = false
            queue.async { self.wakeLoop() }
        }

        // Unretained is safe: the agent lives for the life of the process.
        CGDisplayRegisterReconfigurationCallback({ _, _, context in
            guard let context else { return }
            Unmanaged<Agent>.fromOpaque(context).takeUnretainedValue().invalidateFromSystemEvent()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Installed before the Accessibility gate; otherwise SIGHUP kept its default disposition while
    /// the agent waited for permission, and KeepAlive hid the resulting exit.
    func installSignalHandlers() {
        signal(SIGHUP, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        source.setEventHandler { [weak self] in self?.reload() }
        source.resume()
        hangupSource = source
    }

    // MARK: - Diagnostics

    /// One-shot report of what the agent sees at the pointer, using the agent's own resolution.
    func probe(at explicit: CGPoint? = nil) {
        Log.verbose = true
        AXUIElementSetMessagingTimeout(systemWide, 0.5)

        let cursor = explicit ?? CGEvent(source: nil)?.location ?? .zero
        if explicit != nil { print("(probing an explicit point, not the pointer)") }
        print("cursor:               \(Int(cursor.x)), \(Int(cursor.y))  (top-left origin)")
        print("accessibility:        \(accessibilityTrusted(prompt: false) ? "trusted" : "NOT TRUSTED")")

        print("\nguards")
        let buttons = NSEvent.pressedMouseButtons
        print("  mouse buttons:      \(buttons == 0 ? "none" : "0b" + String(buttons, radix: 2))"
            + (buttons == 0 ? "" : "  <- SUPPRESSING"))
        let sinceKey = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .keyDown
        )
        print(String(format: "  last keystroke:     %.2fs ago (cooldown %dms)%@",
                     sinceKey, config.typingCooldownMs,
                     sinceKey < config.typingCooldown ? "  <- SUPPRESSING" : ""))
        print("  secure input:       \(IsSecureEventInputEnabled() ? "yes  <- SUPPRESSING" : "no")")
        let command = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        print("  command held:       \(command && config.ignoreWhenCommandHeld ? "yes  <- SUPPRESSING" : "no")")
        print("  overlay on screen:  \(config.menuGuard && overlayPresent() ? "yes  <- SUPPRESSING" : "no")")
        let promptHolds = config.promptGuard && frontmostPromptAwaitsAnswer()
        print("  prompt mid-question:\(promptHolds ? " yes  <- HOLDING ALL FOCUS" : " no")")
        // A hold belongs to the running agent's history, which this process does not have.
        let handoverSetting = config.handoverGuard
            ? "on, settle \(config.handoverSettleMs)ms -- held by the running agent, see its log"
            : "off"
        print("  handover hold:      \(handoverSetting)")

        print("\naccessibility at cursor")
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide, Float(cursor.x), Float(cursor.y), &hit
        )
        if error != .success {
            print("  hit test:           failed, AXError \(error.rawValue)")
        }
        if let element = hit {
            print("  element role:       \(axString(element, kAXRoleAttribute) ?? "-")")
            let topLevel = axElement(element, kAXTopLevelUIElementAttribute)
            print("  top-level role:     \(topLevel.flatMap { axString($0, kAXRoleAttribute) } ?? "-")")

            switch windowElement(from: element) {
            case .sheet:
                print("  resolved via:       nothing -- the pointer is over a sheet")
            case .none:
                print("  resolved via:       nothing window-shaped")
            case let .window(window, via):
                print("  resolved via:       \(via)")
                print("  subrole:            \(axString(window, kAXSubroleAttribute) ?? "-")")
                if let size = axSize(window, kAXSizeAttribute) {
                    print("  size:               \(Int(size.width))x\(Int(size.height))")
                }
                print("  title:              \(axString(window, kAXTitleAttribute) ?? "-")")
                print("  identifier:         \(axString(window, kAXIdentifierAttribute) ?? "-")")
                print("  AXMain settable:    \(axIsSettable(window, kAXMainAttribute))")
                print("  AXFocused settable: \(axIsSettable(window, kAXFocusedAttribute))")
            }
        }

        print("\nresult")
        if let target = hitTest(at: cursor) {
            print("  target:             \(target.describedAs) (pid \(target.pid))")
            print("  bundle:             \(target.bundleID ?? "-")")
            print("  granularity:        \(target.window != nil ? "window" : "app only (no AX tree)")")
            print("  already focused:    \(focusMatches(target))")
        } else {
            print("  target:             none -- see the guards above, or the role/size checks")
        }
    }
}

private extension NSRunningApplication {
    var describedAs: String {
        localizedName ?? bundleIdentifier ?? "pid \(processIdentifier)"
    }
}
