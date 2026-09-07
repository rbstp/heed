import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import HeedCore

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
    /// Keyed by setting, so a claim can tell a combination that is moving from one that is not.
    private var registrations: [Shortcut: Registration] = [:]
    private var shortcut: HotkeySpec?
    private var numberOverlay: NumberOverlay?
    /// The modifier the numbered shortcuts are registered under, which is the one that raises the
    /// numbers. Nil when no numbered shortcut is registered, and then nothing raises them.
    private var numberModifiers: Set<HotkeySpec.Modifier>?
    /// `config.windowNumbers` and its delay, mirrored for the main thread by `syncMenuBar`.
    private var numbersEnabled = true
    private var numbersDelay = 0.1
    private var numberWatch: [Any] = []
    private var numbersArmWork: DispatchWorkItem?
    private var numbersWatchdog: DispatchSourceTimer?
    /// A ring is being built for the numbers, and whether another was asked for while it was.
    /// Building one is the most expensive thing the agent does, and it runs on the queue the focus
    /// loop and the shortcuts themselves need, so a burst of shortcuts must not queue a build each.
    private var numbersBuilding = false
    private var numbersAskedAgain = false
    /// Bumped whenever the numbers are asked for or taken down, so a ring that finished building
    /// after the key was let go is discarded rather than shown.
    private var numbersGeneration = 0
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
    /// Whether the window numbers are on screen. Written from the main thread through `queue`.
    private var numbersShowing = false
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
    /// The last app other than Heed to come forward. A `heed://` URL activates Heed, so this is the
    /// app a command arriving that way means.
    private var lastForeignFront: pid_t?
    /// The app a click brought forward, if any. Sampled as the activation arrives: the loop can
    /// notice the handover long after, by when "how long since the last click" says nothing. Keyed
    /// by pid so a stale answer cannot speak for the app that came forward next.
    private var clickActivated: pid_t?

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
            lastForeignFront = frontmostForFocus()
            scheduleTimer()
            syncMenuBar()
            // Only now: a global key monitor is given nothing until Accessibility is granted.
            DispatchQueue.main.async { [self] in installNumberWatch() }
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
        // Windows are somewhere else now, so numbers drawn a moment ago point at the wrong ones and
        // the digits they promise belong to a ring that has been rebuilt underneath them. A Space
        // change and a display rearrangement both move windows without touching the modifier, so
        // nothing else here would notice.
        DispatchQueue.main.async { [self] in refreshNumbers() }
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

    func toggleEnabled() {
        queue.async { [self] in applyEnabled(!config.enabled) }
    }

    func setEnabled(_ value: Bool) {
        queue.async { [self] in applyEnabled(value) }
    }

    /// Writes the same defaults key `defaults write` does, so the choice survives a restart.
    private func applyEnabled(_ value: Bool) {
        guard value != config.enabled else { return }
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

    /// Everything another program can ask for, over the URL scheme or the command-line flags.
    func perform(_ command: HeedCommand) {
        switch command {
        case .toggle: toggleEnabled()
        case .enable: setEnabled(true)
        case .disable: setEnabled(false)
        case .focusStep(let delta): stepFocus(by: delta)
        case .focusNumber(let number): focusWindow(number)
        case .focusWindowID(let id): focusWindow(id: id)
        case .focusDirection(let direction): focusDirection(direction)
        }
    }

    private func syncMenuBar() {
        let wanted = config.menuBarIcon
        let enabled = config.enabled
        let numbers = config.windowNumbers
        let delay = config.windowNumbersDelay
        DispatchQueue.main.async { [self] in
            // Before the menu bar guard: the numbers do not depend on the status item being shown.
            numbersEnabled = numbers
            numbersDelay = delay
            if !numbers { hideNumbers() }

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
                    },
                    onToggleNumbers: { [weak self] in self?.toggleWindowNumbers() }
                )
            }
            menuBar?.showsNumbers = numbers
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
        let under = sharedModifiers(of: texts, primary: Agent.toggleIndex)
        DispatchQueue.main.async { [self] in
            registrations = [:]
            adopt(specs: [], under: [])

            let claimed = claim(texts)
            registrations = claimed.held
            adopt(specs: claimed.specs, under: under)
            announce(specs: claimed.specs)
        }
    }

    private struct Registration {
        let spec: HotkeySpec
        let keys: [Hotkey]
    }

    /// Claim combinations without releasing the current registrations, so a change can be tried
    /// before the working shortcuts are given up. `specs` is in `Shortcut.allCases` order; `refused`
    /// means a combination could not be had, whoever holds it.
    private func claim(_ texts: [String]) -> (held: [Shortcut: Registration], specs: [HotkeySpec?],
                                              refused: Bool, clashes: Set<Shortcut>) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Read before anything is registered, so a clash is caught as one.
        var specs: [HotkeySpec?] = []
        var wanted: [Shortcut: [(HotkeySpec, () -> Void)]] = [:]
        for (shortcut, text) in zip(Shortcut.allCases, texts) {
            guard !HotkeySpec.isOff(text) else {
                specs.append(nil)
                continue
            }
            let written = text.trimmingCharacters(in: .whitespaces)
            guard let spec = HotkeySpec(written) else {
                Log.note("hotkey \"\(written)\" is not a combination I understand "
                    + "(try cmd+ctrl+h); nothing \(shortcut.which)")
                specs.append(nil)
                continue
            }
            guard let combinations = combinations(for: shortcut, spec) else {
                Log.note("hotkey \"\(written)\" must end in 1, the other digits follow; nothing \(shortcut.which)")
                specs.append(nil)
                continue
            }
            wanted[shortcut] = combinations
            specs.append(spec)
        }

        var refused = false
        // Both sides of every clash, so a caller can tell one its own change caused from one the
        // settings already had.
        var clashes: Set<Shortcut> = []

        // A combination belongs to one action. The later claim is dropped rather than the whole
        // set, so the rest still register.
        while true {
            let claims = Shortcut.allCases.flatMap { shortcut in
                (wanted[shortcut] ?? []).map { (name: shortcut, spec: $0.0) }
            }
            guard let clash = firstClash(in: claims) else { break }
            Log.note("hotkey \(clash.spec.display) already \(clash.earlier.which), "
                + "so nothing \(clash.later.which)")
            wanted[clash.later] = nil
            if let index = Shortcut.allCases.firstIndex(of: clash.later) { specs[index] = nil }
            clashes.formUnion([clash.earlier, clash.later])
        }

        var held: [Shortcut: Registration] = [:]
        for (index, shortcut) in Shortcut.allCases.enumerated() {
            guard let combinations = wanted[shortcut], let spec = specs[index] else { continue }

            // Carbon refuses a combination this process already holds.
            if let standing = registrations[shortcut], standing.spec == spec {
                held[shortcut] = standing
                continue
            }

            // The registrations are not released before this runs, so a combination another
            // setting is still holding would come back from Carbon as another app having it.
            if let owner = standingHolder(of: combinations.map(\.0), excluding: shortcut) {
                Log.note("hotkey \(owner.spec.display) is one Heed already has: it "
                    + "\(owner.shortcut.which), so nothing \(shortcut.which)")
                specs[index] = nil
                refused = true
                continue
            }

            var keys: [Hotkey] = []
            for (combination, action) in combinations {
                guard let hotkey = Hotkey(spec: combination, action: action) else { break }
                keys.append(hotkey)
            }
            guard keys.count == combinations.count else {
                specs[index] = nil
                refused = true   // Hotkey logs why; dropping the partial set unregisters it
                continue
            }
            held[shortcut] = Registration(spec: spec, keys: keys)
        }
        return (held, specs, refused, clashes)
    }

    /// Which other setting's live registration already holds one of `combinations`.
    private func standingHolder(
        of combinations: [HotkeySpec], excluding shortcut: Shortcut
    ) -> (shortcut: Shortcut, spec: HotkeySpec)? {
        let asked = Set(combinations)
        for other in Shortcut.allCases where other != shortcut {
            guard let standing = registrations[other] else { continue }
            let holds = self.combinations(for: other, standing.spec)?.map(\.0) ?? []
            if let shared = holds.first(where: asked.contains) { return (other, shared) }
        }
        return nil
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

    /// `Shortcut.allCases` order is the order `claim` reports in.
    private static let toggleIndex = Shortcut.allCases.firstIndex(of: .toggle) ?? 0

    /// `under` is what `changeModifiers` would replace, so the tick cannot claim a modifier the
    /// menu would not actually move away from.
    private func adopt(specs: [HotkeySpec?], under: Set<HotkeySpec.Modifier>) {
        shortcut = specs.indices.contains(Agent.toggleIndex) ? specs[Agent.toggleIndex] : nil
        menuBar?.shortcut = shortcut
        menuBar?.modifiers = under.isEmpty ? nil : under
        // The numbers stand for the numbered shortcuts, so they follow that setting's modifier
        // rather than the toggle's: the two need not be the same, and only one is being pictured.
        let numbered = Shortcut.allCases.firstIndex(of: .focusWindow)
        numberModifiers = numbered.flatMap { specs.indices.contains($0) ? specs[$0] : nil }?.modifiers
        // A changed shortcut renumbers nothing, but the numbers on screen were drawn for the old one.
        hideNumbers()
    }

    /// Put the shortcuts under a different modifier, keeping each key. All or none, and stored only
    /// once it took. `report` is called on the main thread. Only the settings already under the
    /// modifier being replaced move; see `rewriteHotkeys`.
    func changeModifiers(to preset: ModifierPreset, report: @escaping (Bool) -> Void) {
        queue.async { [self] in
            let current = shortcutTexts
            let under = sharedModifiers(of: current, primary: Agent.toggleIndex)
            let texts = rewriteHotkeys(current, under: under, to: preset.modifiers)
            // A duplicate the settings already had is not this change's doing, and must not make
            // every preset refuse for good.
            let moved = Set(zip(Shortcut.allCases, zip(current, texts)).compactMap { shortcut, pair in
                HotkeySpec(pair.0) == HotkeySpec(pair.1) ? nil : shortcut
            })

            // Compared as combinations: the stored text is however it was typed, the rewrite is
            // canonical.
            guard !zip(current, texts).allSatisfy({ HotkeySpec($0) == HotkeySpec($1) }) else {
                DispatchQueue.main.async { report(true) }
                return
            }

            DispatchQueue.main.async { [self] in
                let claimed = claim(texts)
                guard !claimed.refused, claimed.clashes.isDisjoint(with: moved) else {
                    Log.note("keeping the current shortcuts: \(preset.display) could not be had")
                    report(false)
                    return
                }
                registrations = claimed.held
                adopt(specs: claimed.specs, under: preset.modifiers)
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

    // MARK: - Window numbers

    /// Watch the modifier keys, so holding the one the numbered shortcuts are registered under puts
    /// their numbers on the windows they would reach.
    ///
    /// Installed from `start`, which runs only once Accessibility is granted: a global key monitor
    /// is handed nothing without it, and would sit there silently never firing.
    private func installNumberWatch() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard numberWatch.isEmpty else { return }

        numberOverlay = NumberOverlay()
        // Global for every other app; local because a menu of ours makes Heed the active one, and a
        // global monitor is not given events while that is true.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: {
            [weak self] event in self?.modifiersChanged(event.modifierFlags)
        }) {
            numberWatch.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: {
            [weak self] event in
            self?.modifiersChanged(event.modifierFlags)
            return event
        }) {
            numberWatch.append(local)
        }
    }

    /// Raise the numbers after a beat of holding, and take them down the moment the combination
    /// changes. The beat is what keeps a quick ⌃⌘→ from flashing numbers across every screen.
    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard numbersEnabled,
              numbersArmed(pressed: Agent.modifiers(from: flags), wanted: numberModifiers)
        else {
            hideNumbers()
            return
        }
        // Already counting down, or already up: a modifier pressed in some other order arrives as
        // several events, and each must not start a fresh countdown.
        guard numbersArmWork == nil, numberOverlay?.isShowing != true else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.numbersArmWork = nil
            self?.requestNumbers()
        }
        numbersArmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + numbersDelay, execute: work)
    }

    /// Build the ring the numbered shortcuts would act on and badge it.
    ///
    /// Counted by generation: building a ring is many cross-process calls, and the key can be let go
    /// during them, so an answer that arrives after the numbers were dismissed is dropped.
    private func requestNumbers() {
        dispatchPrecondition(condition: .onQueue(.main))
        numbersGeneration += 1
        let generation = numbersGeneration

        // One build at a time, with at most one more remembered: a shortcut held down would
        // otherwise put a build on the queue per repeat, and each one delays the next shortcut.
        guard !numbersBuilding else {
            numbersAskedAgain = true
            return
        }
        numbersBuilding = true

        queue.async { [self] in
            let badges: [NumberBadge]? = accessibilityTrusted(prompt: false)
                ? focusRing().map { numberBadges(at: badgeCentres(for: $0)) }
                : nil

            DispatchQueue.main.async { [self] in
                numbersBuilding = false
                defer { askAgainIfPending() }
                guard generation == numbersGeneration else { return }

                // A ring that could not be built says nothing about the one on screen, and what is
                // on screen was drawn for an arrangement that has since changed. Take it away
                // rather than leave numbers standing that may no longer name these windows.
                guard let badges, !badges.isEmpty else {
                    hideNumbers()
                    return
                }
                guard let overlay = numberOverlay,
                      numbersArmed(pressed: Agent.modifiers(from: NSEvent.modifierFlags),
                                   wanted: numberModifiers)
                else { return }
                overlay.show(badges)
                watchTheModifier()
                Log.debug("window numbers: showing 1 to \(badges.count)")
                // The numbers are up because a window is about to be picked by keyboard; following
                // the pointer under them would take focus somewhere else first.
                queue.async { [self] in numbersShowing = true }
            }
        }
    }

    /// Run the build that was asked for while the last one was in flight, so the numbers settle on
    /// the arrangement as it finally is rather than as it was two shortcuts ago.
    private func askAgainIfPending() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard numbersAskedAgain else { return }
        numbersAskedAgain = false
        guard numberOverlay?.isShowing == true || numbersArmWork != nil else { return }
        requestNumbers()
    }

    /// Where each ring window's number goes: the middle of the largest part of it that nothing in
    /// front covers, so the digit sits on the window it names rather than on whatever buried it.
    ///
    /// The stack is read again rather than carried out of `focusRing`, which judges visibility but
    /// keeps no record of what did the covering. One window server round trip, for at most nine
    /// windows, on a key the user is deliberately holding down.
    private func badgeCentres(for ring: Ring) -> [CGPoint] {
        let stack = onScreenWindows().filter { $0.level == 0 }
        let frames = stack.map(\.frame)
        var depth: [Int: Int] = [:]
        for (index, window) in stack.enumerated() { depth[window.number] = index }

        return zip(ring.ids, ring.windows).map { id, window in
            // No depth means the window server no longer lists it; its own centre is the only
            // answer left, and the show is about to be overtaken by the next build anyway.
            guard let depth = depth[id] else { return CGPoint(x: window.frame.midX,
                                                              y: window.frame.midY) }
            return visibleCentre(of: window.frame, behind: frames[..<depth])
        }
    }

    /// Ask every so often whether the modifier is still down, and take the numbers away when it is
    /// not.
    ///
    /// A release can go unseen: secure event input takes the keyboard away from every monitor, so
    /// letting go inside a password field delivers nothing. Without this the numbers would sit
    /// there for good, with focus following held off behind them. `NSEvent.modifierFlags` is a
    /// snapshot of state rather than a round trip, so asking twice a second costs nothing.
    private func watchTheModifier() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard numbersWatchdog == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard numbersArmed(pressed: Agent.modifiers(from: NSEvent.modifierFlags),
                               wanted: numberModifiers)
            else {
                Log.debug("window numbers: the modifier went up unseen")
                hideNumbers()
                return
            }
        }
        timer.resume()
        numbersWatchdog = timer
    }

    private func hideNumbers() {
        dispatchPrecondition(condition: .onQueue(.main))
        numbersArmWork?.cancel()
        numbersArmWork = nil
        numbersWatchdog?.cancel()
        numbersWatchdog = nil
        numbersAskedAgain = false
        numbersGeneration += 1

        guard numberOverlay?.isShowing == true else { return }
        numberOverlay?.hide()
        Log.debug("window numbers: hidden")
        queue.async { [self] in
            numbersShowing = false
            // Following was held off while the numbers were up; pick the pointer back up at once
            // rather than at whatever the idle heartbeat would be.
            pendingInvalidation = true
            wakeLoop()
        }
    }

    /// Redraw the numbers after a focus shortcut, while the modifier is still down.
    ///
    /// Ring order is spatial, so raising a window does not renumber anything; a window the raise
    /// uncovered, though, joins the ring and shifts every number after it.
    private func refreshNumbers() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard numberOverlay?.isShowing == true,
              numbersArmed(pressed: Agent.modifiers(from: NSEvent.modifierFlags),
                           wanted: numberModifiers)
        else { return }
        requestNumbers()
    }

    func toggleWindowNumbers() {
        queue.async { [self] in
            config.windowNumbers.toggle()
            Config.store().set(config.windowNumbers, forKey: "windowNumbers")
            Log.note(config.windowNumbers ? "window numbers on" : "window numbers off")
            syncMenuBar()
        }
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeySpec.Modifier> {
        let held = flags.intersection(.deviceIndependentFlagsMask)
        var pressed: Set<HotkeySpec.Modifier> = []
        if held.contains(.command) { pressed.insert(.command) }
        if held.contains(.control) { pressed.insert(.control) }
        if held.contains(.option) { pressed.insert(.option) }
        if held.contains(.shift) { pressed.insert(.shift) }
        return pressed
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

        // A window is about to be picked by number; moving focus under the pointer first would
        // both fight the keystroke and renumber what the user is reading.
        if numbersShowing { return .suppressing }

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
        // No displays is a failed read, not a machine without screens: with nothing to clamp
        // against, a stale frame would look as warpable as a real one.
        let screens = screenFrames()
        guard !screens.isEmpty else { return nil }

        let cursor = CGEvent(source: nil)?.location ?? pointerLocation
        guard let point = warpPoint(into: frame, xPercent: config.warpX, yPercent: config.warpY,
                                    pointer: cursor, screens: screens)
        else { return nil }

        guard CGWarpMouseCursorPosition(point) == .success else {
            // Recording a move that did not happen would read as the user throwing the mouse back
            // across the screen on the next tick, and take focus with it.
            Log.debug("the window server refused to move the pointer to "
                + "\(Int(point.x)), \(Int(point.y))")
            return nil
        }
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

        // Never out of a drag, and never off a click: this is for focus the keyboard moved. The two
        // click tests cover each other: the sampled one is right however late the loop gets here,
        // and the elapsed one covers a click the activation observer has not caught up with yet.
        guard clickActivated != front.processIdentifier, NSEvent.pressedMouseButtons == 0,
              secondsSinceAny(of: Agent.deliberateMouseEvents) >= Agent.warpClickGrace
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
    private func moveFocus(
        _ what: String, choose: @escaping (Ring, _ from: Start) -> Int?
    ) {
        queue.async { [self] in
            guard accessibilityTrusted(prompt: false) else {
                Log.note("\(what): no Accessibility permission yet")
                return
            }

            // Read before the ring is built, which is many cross-process calls: movement during
            // those must not decide what the shortcut acts on, nor release the hold it declares.
            let cursor = CGEvent(source: nil)?.location ?? pointerLocation

            guard let ring = focusRing() else { return }
            let windows = ring.windows
            let front = frontmostForFocus()
            let live = liveFocusIndex(in: windows, frontmost: front)

            // Written back so `noteHandover` samples the same window; a hit test that could not
            // answer leaves the last answer standing, since "over nothing" is a claim only an
            // answered one can make.
            let under = cursor.flatMap { hitTest(at: $0) }
            if hitTestAnswered { adoptPointerWindow(under) }

            let start = Start(
                live: live, front: front,
                pointer: under.flatMap { windows.firstIndex(of: $0) },
                unanswered: front.map { ring.unanswered.contains($0) } ?? false
            )
            guard let index = choose(ring, start) else { return }

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

            // Before the focus is applied: raising the target can put it under the pointer.
            let number = cursor.flatMap { windowNumber(under: $0) }

            guard applyFocus(to: target, followingPointer: false) else { return }
            // Recorded even when the app refused the window, so the shortcut walks past such
            // windows rather than stopping dead on the first.
            lastStep = (from: live.map { windows[$0] }, to: target)
            lastStepAt = now

            // The pointer moves before the hold is declared, so the hold anchors where it lands.
            // Read again rather than reusing the ring's frame: the window can have moved, and a
            // warp into where it used to be would put the pointer on some other window.
            let warped = axFrame(window).flatMap {
                warpPointer(into: $0, why: "\(what) to \(target.describedAs)")
            }

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
            DispatchQueue.main.async { [self] in refreshNumbers() }
        }
    }

    private func stepFocus(by delta: Int) {
        moveFocus(delta > 0 ? "focus step forward" : "focus step back") { [self] ring, start in
            let windows = ring.windows
            // The last step is honoured only while it can still describe the same gesture.
            let recent = now - lastStepAt < 1 ? lastStep : nil
            let from = self.source(in: windows, start: start, lastStep: recent)
            if from == nil, start.unanswered {
                self.refuse("focus step", start)
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
        moveFocus("focus \(direction.rawValue)") { [self] ring, start in
            let windows = ring.windows
            // The same start as a ring step, so a held key advances and focus on something the ring
            // cannot name steps from where that app sits.
            let recent = now - lastStepAt < 1 ? lastStep : nil
            guard let source = self.source(in: windows, start: start, lastStep: recent) else {
                if start.unanswered {
                    self.refuse("focus \(direction.rawValue)", start)
                } else {
                    Log.debug("focus \(direction.rawValue): nothing on screen to step from")
                }
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
        moveFocus("focus window \(number)") { ring, _ in
            guard ring.windows.indices.contains(number - 1) else {
                Log.note("focus window \(number): only \(ring.windows.count) windows on screen")
                return nil
            }
            return number - 1
        }
    }

    /// The ring entry a step starts from.
    private func source(
        in windows: [Target], start: Start, lastStep: (from: Target?, to: Target)?
    ) -> Int? {
        if let known = ringStart(in: windows, live: start.live, lastStep: lastStep)
            ?? start.front.flatMap({ pid in windows.firstIndex { $0.pid == pid } }) {
            return known
        }
        // The pointer answers for a front that has no windows, never for one that stayed silent.
        return start.unanswered ? nil : start.pointer
    }

    /// An app that did not answer is not an app with no windows. Neither the pointer nor the first
    /// entry may stand in for it: either would take focus off a window the ring never saw.
    private func refuse(_ what: String, _ start: Start) {
        let name = start.front.flatMap { NSRunningApplication(processIdentifier: $0)?.describedAs }
        Log.note("\(what): \(name ?? "the frontmost app") did not answer, so there is no telling "
            + "where to step from")
    }

    /// Where a focus shortcut may start from, best answer first. The pointer is the one that saves a
    /// cold start, where Heed was launched by the command it is answering and has seen nothing yet.
    private struct Start {
        let live: Int?
        let front: pid_t?
        let pointer: Int?
        /// Whether the frontmost app was asked for its windows and did not answer.
        let unanswered: Bool
    }

    /// Focus the window the window server numbers `id`. What a list hands back: a place in the ring
    /// is only true of the ring it came from, and this one is rebuilt from scratch.
    private func focusWindow(id: Int) {
        moveFocus("focus window id \(id)") { ring, _ in
            guard let index = ring.ids.firstIndex(of: id) else {
                Log.note("focus window id \(id): that window is not on screen any more")
                return nil
            }
            return index
        }
    }

    private struct Ring {

        let windows: [Target]
        /// The window server's number for each entry, in the same order.
        let ids: [Int]
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

        let ordered = ringOrder(ring, screens: screenFrames())
            .compactMap { entry in targets[entry.key].map { (id: entry.key, window: $0) } }
        return Ring(windows: ordered.map(\.window), ids: ordered.map(\.id), unanswered: unanswered)
    }

    private func outOfTime() -> Ring? {
        Log.note("gave up building the focus ring after 500ms; some app is not answering")
        return nil
    }

    /// Whose focus a shortcut should step from. Heed itself is never the answer: a `heed://` URL
    /// brings it forward, and the app it took the front from is the one the command is about.
    private func frontmostForFocus() -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPid,
              !isExcluded(front.bundleIdentifier)
        else { return lastForeignFront }
        lastForeignFront = front.processIdentifier
        return front.processIdentifier
    }

    /// Raycast and the rest of the overlay apps are never a window a shortcut steps from: their
    /// palette is what the command was typed into.
    private func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return config.excludedBundleIDs.contains(bundleID)
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
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPid
            else { return }
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier
            let byClick = secondsSinceAny(of: Agent.deliberateMouseEvents) < Agent.warpClickGrace
            queue.async {
                self.clickActivated = byClick ? pid : nil
                guard !self.isExcluded(bundleID) else { return }
                self.lastForeignFront = pid
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
                if self.lastForeignFront == pid { self.lastForeignFront = nil }
                if self.clickActivated == pid { self.clickActivated = nil }
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

    /// Commands from a second copy of the binary, which cannot reach this process's state. Any
    /// process in the login session can post one; they toggle Heed and move focus, nothing more.
    func observeCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(commandNotification), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let text = note.object as? String else { return }
            guard let command = parseCommand(text) else {
                // Anything in the session can post one, so it is quoted short and on one line.
                let quoted = text.prefix(40).map { $0.isNewline ? " " : $0 }
                Log.note("ignoring a command I do not understand: \"\(String(quoted))\"")
                return
            }
            Log.debug("command: \(text)")
            perform(command)
        }
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

    /// The focus ring as JSON on stdout, in the order the numbered shortcuts count. Built here
    /// rather than asked of the running agent: the ring is derived from the window server and
    /// Accessibility, so a second copy of the binary can read it for itself.
    func listWindows() {
        // Tighter than the probe's: every window costs several messages, and whoever is waiting on
        // the list has a timeout of their own.
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        guard accessibilityTrusted(prompt: false) else {
            fail("Heed has no Accessibility permission yet")
            return
        }
        guard let ring = focusRing() else {
            fail("no window list: some app did not answer in time")
            return
        }

        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmost = liveFocusIndex(in: ring.windows, frontmost: front) ?? topmostRingIndex(in: ring)
        let listed = ring.windows.enumerated().map { index, window in
            ListedForOutput(
                id: ring.ids[index],
                number: index + 1,
                app: window.describedAs,
                bundleID: window.bundleID,
                title: window.title,
                x: Int(window.frame.origin.x.rounded()),
                y: Int(window.frame.origin.y.rounded()),
                width: Int(window.frame.width.rounded()),
                height: Int(window.frame.height.rounded()),
                frontmost: index == frontmost
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(listed) else {
            fail("could not encode the window list")
            return
        }
        FileHandle.standardOutput.write(data)
        print()
    }

    /// The frontmost ring entry as the window server stacks it. Whoever asked for the list is the
    /// app in front while it is built, so the system's own answer is about them, not about focus.
    private func topmostRingIndex(in ring: Ring) -> Int? {
        for window in onScreenWindows() where window.level == 0 && window.pid != ownPid {
            if let index = ring.windows.firstIndex(where: {
                $0.pid == window.pid && framesAgree($0.frame, window.frame)
            }) {
                return index
            }
        }
        return nil
    }

    private struct ListedForOutput: Encodable {
        /// The window server's number, which is what to ask for the window back by.
        let id: Int
        /// Its place in ring order, which is what the numbered shortcuts count.
        let number: Int
        let app: String
        let bundleID: String?
        let title: String?
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        /// The window that was in front. Focus itself when the caller could be asked for it, and
        /// the window server's own order when the caller is the app holding the front.
        let frontmost: Bool
    }

    /// The reason on stderr, so a caller parsing stdout never has to tell an error from a window.
    private func fail(_ why: String) {
        FileHandle.standardError.write(Data("\(why)\n".utf8))
        exit(1)
    }

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
