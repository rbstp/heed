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

    /// The menu bar item, the hotkey, and the combination the menu shows for it: the state here
    /// that belongs to the main thread rather than to `queue`. `syncMenuBar` and `syncHotkey` are
    /// the hops between the two.
    private var menuBar: MenuBarController?
    private var hotkey: Hotkey?
    private var shortcut: HotkeySpec?

    /// What the timer is currently scheduled at, so retiming is a no-op when nothing changed, and
    /// when the last tick ran, which is how an idling tick tells that it missed something.
    private var interval: Double = 0
    private var lastTickAt: Double = 0
    /// Main thread only. Mirrors "the loop is idling, wake it", so a mouse event costs one bool test
    /// rather than a dispatch hop -- and events arrive far faster than the loop ever ticked.
    private var wantsMouseWake = false
    private var mouseMonitor: Any?
    private var observersInstalled = false

    private var lastCursor = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    private var pendingInvalidation = false

    /// Recent pointer travel, and the last window accepted as a focus target. Together they
    /// distinguish the pointer moving onto a window from a window arriving under a still pointer.
    private var motion = MotionTracker(capacity: 5)
    private var lastResolved: Target?
    /// What the pointer is over, whether or not it was allowed to take focus. See `hitTestForFocus`.
    private var lastPointerWindow: Target?
    /// Whether the pointer moved on the tick being served, for the guards that run below `tick`.
    private var pointerMovedThisTick = false

    /// Cached per-app Accessibility elements. Keyed by pid but validated against launch date,
    /// because pids are recycled and handing a dead element back to the Accessibility API is not
    /// something to find out about in production.
    private var appElements: [pid_t: (element: AXUIElement, launched: Date?)] = [:]

    /// Apps that repeatedly failed to answer. Prevents one hung process from costing a messaging
    /// timeout on every tick.
    private var blockedUntil: [pid_t: Double] = [:]
    private var failureCounts: [pid_t: Int] = [:]

    private var isRunning = false
    private var overlayCached = false
    private var surveyUntil: Double = 0
    /// Focus that arrived without the pointer -- a new window, a window raised by a shortcut,
    /// Cmd-Tab -- and the window the pointer has to leave to overrule it. Fed by `surveyWindows`,
    /// consulted by `hitTestForFocus`.
    private var handover = FocusHandover<Target>(settle: 0)
    /// Whether the last hit test was withheld by a hold, so verbose mode says so once on entry
    /// rather than on every tick for as long as the pointer stays put.
    private var holdingFocus = false
    private var promptCached = false
    private var promptCacheUntil: Double = 0
    private var hitTestFailures = 0
    private var hitTestCooldownUntil: Double = 0
    private var accessibilityLost = false


    /// Last target named in the log, so verbose mode reports each window once on entry rather than
    /// 25 times a second while the pointer moves across it.
    private var lastResolvedName: String?

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    init() {
        config = Config.load()
        Log.verbose = config.verbose
        machine = DwellMachine(dwell: config.dwell)
    }

    // MARK: - Lifecycle

    /// Registration happens here; every mutation of agent state happens on the queue.
    ///
    /// Startup used to run on whichever thread called it, which raced with a SIGHUP reload arriving
    /// on the queue -- two `scheduleTimer()` calls at once, and torn writes to config and motion.
    func start() {
        observeSystemEvents()
        queue.async { [self] in
            guard !isRunning else { return }

            // Bound every Accessibility message process-wide. Passing the system-wide element sets
            // the global default rather than a per-element one.
            //
            // This bounds each *message*, not a whole tick: a tick issues several. Hence short, and
            // hence keeping the number of messages per tick down.
            AXUIElementSetMessagingTimeout(systemWide, 0.1)

            isRunning = true
            scheduleTimer()
            // The icon was dimmed while the Accessibility grant was outstanding; it is not now.
            syncMenuBar()
            Log.note("running: enabled=\(config.enabled) dwell=\(config.dwellMs)ms "
                + "poll=\(config.pollMs)ms raise=\(config.raise) "
                + "typingCooldown=\(config.typingCooldownMs)ms "
                + "handoverGuard=\(config.handoverGuard) "
                + "handoverSettle=\(config.handoverSettleMs)ms verbose=\(config.verbose)")
        }
    }

    fileprivate func noteDisplayReconfiguration() {
        queue.async {
            self.pendingInvalidation = true
            self.wakeLoop()
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        motion = MotionTracker(capacity: max(2, Int((0.2 / config.poll).rounded())))
        handover.settle = config.handoverSettle

        // Disabled means no timer rather than a tick that wakes 25 times a second to return
        // immediately. Everything that can flip `enabled` -- the menu bar, a config reload -- comes
        // back through here, so this is the only place that has to know.
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

    /// Re-aims the timer, and tells the main thread whether a mouse event should wake it.
    ///
    /// Idling gets generous leeway on purpose: it lets the system fire this alongside whatever else
    /// it was going to wake for, which is most of where the saving comes from -- a timer nobody has
    /// to wake the CPU for costs close to nothing.
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

    /// Back to the fast cadence, firing at once rather than at the end of the idle interval: the
    /// pointer has already moved by the time this runs.
    private func wakeLoop() {
        retime(to: config.poll, startingNow: true)
    }

    /// Forget what the pointer was last resolved to, so the next tick adopts a baseline instead of
    /// acting on it.
    ///
    /// This is what `.invalidating` does inside `tick`, for the two paths that re-evaluate from
    /// outside it. `machine.invalidate()` alone is not enough and is the more dangerous half: it
    /// forces a hit test, and a target equal to the surviving `lastResolved` passes the entry-motion
    /// guard on the strength of a baseline set before the pause. Keyboard focus moved elsewhere in
    /// the meantime would be dragged back to the window under a pointer that never moved.
    private func forgetTarget() {
        machine.invalidate()
        motion.reset()
        lastResolved = nil
        // And any hold, which is anchored on a window the pointer may have left long ago.
        lastPointerWindow = nil
        handover.reset()
    }

    private func reload() {
        queue.async { [self] in
            config = Config.load()
            Log.verbose = config.verbose
            machine.dwell = config.dwell
            forgetTarget()
            if isRunning { scheduleTimer() }   // pollMs may have changed
            syncMenuBar()
            syncHotkey()
            Log.note("reloaded config: dwell=\(config.dwellMs)ms poll=\(config.pollMs)ms "
                + "raise=\(config.raise) enabled=\(config.enabled)")
        }
    }

    // MARK: - Menu bar

    /// Installed from the launch path rather than from `start()`, so both are there whether or not
    /// the Accessibility grant has arrived. The hotkey especially: waiting for a permission you have
    /// not decided to give yet is exactly when you want to be able to switch this off.
    func installMenuBar() {
        queue.async { [self] in
            syncMenuBar()
            syncHotkey()
        }
    }

    /// The click and hotkey handler, and the only thing that changes `enabled` at runtime.
    ///
    /// It writes the same defaults key `defaults write` does, so the choice survives a restart and
    /// the icon and the configuration cannot come to disagree.
    func toggleEnabled() {
        queue.async { [self] in
            let value = !config.enabled
            config.enabled = value
            Config.store().set(value, forKey: "enabled")

            // Turning it back on must not act on what the pointer was over minutes ago.
            forgetTarget()
            if isRunning { scheduleTimer() }

            Log.note(value ? "enabled" : "disabled")
            syncMenuBar()
        }
    }

    /// Push the current state into the menu bar. Called on `queue`; the item is main-thread only, so
    /// the values are read here and applied there.
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
                    // Not the agent's to do: quitting is about the process and the job launchd
                    // holds it in, neither of which is state on `queue`.
                    onQuit: { quitHeed() }
                )
            }
            // Set here as well as in syncHotkey, because either can run first.
            menuBar?.shortcut = shortcut
            // Trust is read here rather than carried across the hop: it can change at any moment,
            // and it is what decides whether the icon claims to be working.
            menuBar?.render(enabled: enabled, trusted: accessibilityTrusted(prompt: false))
        }
    }

    /// Registers the toggle hotkey, replacing any previous one. Called on `queue`; Carbon
    /// registration belongs to the main thread, so the value is read here and applied there.
    private func syncHotkey() {
        let text = config.hotkey
        DispatchQueue.main.async { [self] in
            // Dropping the old one unregisters it, which is also how a changed combination takes
            // effect: there is no editing a registration in place.
            hotkey = nil
            shortcut = nil
            menuBar?.shortcut = nil

            let wanted = text.trimmingCharacters(in: .whitespaces)
            guard !wanted.isEmpty, wanted.lowercased() != "none" else { return }
            guard let spec = HotkeySpec(wanted) else {
                Log.note("hotkey \"\(wanted)\" is not a combination I understand "
                    + "(try cmd+ctrl+h); none registered")
                return
            }
            guard let registered = Hotkey(spec: spec, action: { [weak self] in
                self?.toggleEnabled()
            }) else {
                return   // Hotkey logs why
            }
            hotkey = registered
            shortcut = spec
            menuBar?.shortcut = spec
            Log.note("hotkey \(spec.display) toggles Heed")
        }
    }

    // MARK: - Main loop

    private func tick() {
        guard config.enabled else { return }

        let sinceLastTick = lastTickAt > 0 ? now - lastTickAt : 0
        lastTickAt = now

        // A circuit-breaker block expiring changes what is focusable, but nothing moves the pointer
        // to announce it. Without re-arming here, a stationary pointer over a recovered app would
        // never hit-test again: the forced test that `noteFailure` armed was already spent on the
        // tick that found the app still blocked.
        if let soonest = blockedUntil.values.min(), now >= soonest {
            blockedUntil = blockedUntil.filter { $0.value > now }
            machine.invalidate()
        }

        // And the hit-test cooldown, for the same reason: it was spending its two seconds waiting
        // for a deadline and then never performing the retry it waited for.
        if hitTestCooldownUntil > 0, now >= hitTestCooldownUntil {
            hitTestCooldownUntil = 0
            machine.invalidate()
        }

        // A contested hold is a deadline like the others above: the pointer has arrived on some
        // other window and is waiting out the settle, and once it stops moving nothing performs the
        // hit test that would notice the settle lapse. Bounded by the settle itself, so this keeps
        // the loop awake for a fraction of a second rather than for as long as focus is held.
        if handover.isSettling { machine.invalidate() }

        // Same problem, and the reason idling is not simply "wake on mouse events".
        //
        // A whole suppression can begin and end between two heartbeats: press Cmd-Tab with the
        // pointer parked, and the command held, the keystroke and its cooldown are all over before
        // the next one. The 40ms loop always saw that and armed a hit test; an idling loop sees a
        // quiet `.normal` tick and would leave focus wherever the keyboard put it, sometimes -- and
        // "sometimes" is the worst of the options, since it depends on where the heartbeat landed.
        //
        // Watching the keyboard for it is the obvious fix and the wrong one: a global key monitor
        // is a second permission and a shape this program should not have. So the question is asked
        // backwards instead -- is any input newer than our last tick? -- which needs no monitor and
        // covers every kind of input at once.
        if sinceLastTick > config.poll * 2, secondsSinceAny(of: suppressingInputs) < sinceLastTick {
            Log.debug("input arrived while idling; re-deriving")
            machine.invalidate()
        }

        let cursor = CGEvent(source: nil)?.location ?? lastCursor
        let moved = cursor != lastCursor
        let step = lastCursor.x.isFinite
            ? Double(hypot(cursor.x - lastCursor.x, cursor.y - lastCursor.y))
            : 0
        motion.record(step.isFinite ? step : 0)
        lastCursor = cursor
        pointerMovedThisTick = moved

        // Before anything else acts this tick. A handover has to be noticed before the machine gets
        // a chance to undo it: a forced hit test in this same tick would otherwise take focus
        // straight back, and then focus *would* be on the pointer's window, so there would be
        // nothing left to notice.
        noteHandover()

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

        // Every return below leaves the cadence to this, so a tick cannot exit and forget to.
        defer { retime(to: hasPendingWork(cursorMoved: moved) ? config.poll : config.idlePoll,
                       startingNow: false) }

        guard let target else { return }

        // Revalidate before acting, even at instant dwell. Time passes regardless of the dwell
        // setting: resolving the window and checking current focus are several cross-process calls,
        // and the window can close, quit, minimize, move or change Space during them. Acting on the
        // stale reference could make a window-less app frontmost.
        guard let confirmed = hitTest(at: cursor), confirmed == target else {
            Log.debug("target changed before it could be focused; discarding \(target.describedAs)")
            machine.invalidate()
            return
        }

        // The pointer must not bury a question. While a prompt awaits an answer in the frontmost
        // app -- Finder asking whether to replace the file just dropped -- focus moves nowhere:
        // stealing it would raise another window over the prompt, and a buried prompt can never be
        // reached by pointer again, because the hit test resolves whatever covers it. Going through
        // invalidate() keeps retrying, so the window under the resting pointer still takes focus
        // the moment the question is answered.
        if config.promptGuard, frontmostPromptAwaitsAnswer() {
            Log.debug("not focusing \(confirmed.describedAs): a prompt awaits an answer "
                + "in the frontmost app")
            machine.invalidate()
            return
        }

        if !applyFocus(to: confirmed) {
            // Re-arm so a stationary pointer still gets another attempt; going through invalidate()
            // means the next attempt re-derives the target rather than reusing this reference.
            machine.invalidate()
        }
    }

    /// Whether anything can still change without new input from outside.
    ///
    /// False means the pointer is parked, no dwell or forced hit test is outstanding, and no timer
    /// of our own is due -- so ticking 25 times a second only proves the pointer is still parked. A
    /// mouse event wakes it again, and the idle heartbeat is the safety net for anything that never
    /// sends one.
    private func hasPendingWork(cursorMoved: Bool) -> Bool {
        if cursorMoved || pendingInvalidation || machine.needsTick { return true }
        if now < hitTestCooldownUntil { return true }
        // A hold being contested has to be counted here even though the forced hit test that
        // advances it is already spent by now: `machine.needsTick` is asked after `machine.tick`
        // consumed it, so relying on that dropped the loop to the heartbeat mid-settle and turned a
        // 300ms settle into a second and a half.
        if handover.isSettling { return true }
        // A block expiring changes what is focusable with nothing to announce it, and `tick` relies
        // on being there to notice.
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

        // One call covering every button, rather than polling each button index separately. This is
        // an instantaneous snapshot, which Apple documents as unsuitable for tracking, so the grace
        // period below covers presses it cannot see.
        if NSEvent.pressedMouseButtons != 0 { return .suppressing }

        // A click can begin and end entirely between two polls, and a click is a deliberate focus
        // choice that the pointer should not immediately override. Short, because unlike typing this
        // is only closing a sampling gap.
        if config.clickGraceMs > 0, secondsSinceAny(of: deliberateMouseEvents) < config.clickGrace {
            return .suppressing
        }

        // Typing must win over the pointer. Without this, resting the pointer over another window
        // while typing sends the rest of the sentence somewhere else -- the worst thing this tool
        // could do.
        if config.typingCooldownMs > 0,
           CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            < config.typingCooldown {
            return .suppressing
        }

        // A password field makes an unwanted focus change more dangerous, not less.
        if IsSecureEventInputEnabled() { return .suppressing }

        if config.ignoreWhenCommandHeld,
           CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
            return .suppressing   // Cmd-Tab in progress
        }

        // Only worth a round trip while something is actually pending -- which includes a hit test
        // armed by the previous tick. Keyed on `hasCandidate` alone, a suppressing tick cleared the
        // candidate and the next tick stopped checking, so the still-open menu was no longer seen
        // and the armed test could move focus underneath it.
        if config.menuGuard, cursorMoved || machine.needsTick, overlayPresent() {
            return .suppressing
        }

        return .normal
    }

    /// Releases as well as presses: the grace after a drag has to start at the drop, not at the
    /// grab, or a long drag exhausts it before the release even happens.
    private let deliberateMouseEvents: [CGEventType] = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseUp, .rightMouseUp, .otherMouseUp,
    ]

    /// Every input that can start a suppression, so an idling tick can tell whether one ran its
    /// course while the loop was not looking. `flagsChanged` is in here for Cmd-Tab, which can
    /// begin and end without a single keyDown reaching this list.
    private lazy var suppressingInputs: [CGEventType] = deliberateMouseEvents + [
        .keyDown, .flagsChanged,
    ]

    private func secondsSinceAny(of types: [CGEventType]) -> Double {
        types.reduce(Double.greatestFiniteMagnitude) { earliest, type in
            min(earliest, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type))
        }
    }

    /// True when a menu, popover, drag image or similar transient overlay is on screen.
    ///
    /// Detected by window level rather than by sampling the focused element, because while a
    /// pointer-driven menu is open the focused element can still report the control underneath it.
    /// The upper bound excludes the cursor's own window, which sits far above everything.
    private func overlayPresent() -> Bool {
        surveyWindows()
        return overlayCached
    }

    /// Enumerating every on-screen window is a Window Server round trip, so hold the answer for a
    /// moment rather than repeating it on consecutive ticks of the same gesture.
    private func surveyWindows() {
        if now < surveyUntil { return }
        surveyUntil = now + 0.1

        // Menus and popovers through drag images, and no further. An earlier upper bound of 2000
        // swept in the screen-saver and assistive-technology levels, where a single always-present
        // accessibility or HUD window would have disabled focus-follows-mouse globally and silently.
        let lower = Int(CGWindowLevelForKey(.popUpMenuWindow))    // 101
        let upper = Int(CGWindowLevelForKey(.screenSaverWindow))  // 1000
        var found = false

        if let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] {
            for window in windows {
                guard let level = window[kCGWindowLayer as String] as? Int,
                      level >= lower, level < upper,
                      (window[kCGWindowOwnerPID as String] as? pid_t) != ownPid
                else { continue }
                let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
                Log.debug("suppressed: overlay on screen (\(owner) at level \(level))")
                found = true
                break
            }
        }
        overlayCached = found
    }

    // MARK: - Hit testing

    /// The hit test used to drive focus, with the entry guard applied.
    ///
    /// Focus follows the pointer, not the other way round. A window that appears or is raised
    /// underneath a pointer that is sitting still has not been "moved onto", and focusing it means
    /// a pop-up, or an app raising itself, can take focus without the user doing anything. So a
    /// change of target is only accepted when the pointer has actually travelled recently.
    ///
    /// The raw `hitTest` stays unguarded: `--probe` and the pre-apply revalidation both need to see
    /// what is genuinely under the pointer, not what is eligible.
    private func hitTestForFocus(at point: CGPoint) -> Target? {
        guard let target = hitTest(at: point) else {
            // Nothing resolvable under the pointer: the window closed, the pointer reached the
            // desktop, an app stopped answering. Any contest in progress is over -- left standing it
            // would keep the loop forcing hit tests for a settle that can never complete.
            handover.abandonContest()
            // While moving across a menu bar, the Dock, or a gap between windows, keep the last
            // focusable window as the baseline. Menu-opened windows arrive during exactly this gap:
            // erasing it here left no evidence that Zen's About window had taken key focus, and the
            // underlying browser window was focused again as soon as the menu closed. Once the
            // pointer is stationary, nil is a real observation and replaces the old baseline.
            if !pointerMovedThisTick {
                lastPointerWindow = nil
            }
            return nil
        }
        // What the pointer is over, as opposed to `lastResolved`, which is what was last *accepted*
        // as a focus target. They part company exactly when a hold is in force, and the handover
        // needs the former: a hold armed while the pointer sits on B must be anchored on B, not on
        // wherever focus was last allowed to follow.
        lastPointerWindow = target
        noteMovingPointerBaseline(window: target)

        // Ahead of the entry-motion guard below, which cannot see this case: nothing about the
        // target changed -- the pointer is resting on the window it was already resting on, so
        // there is no arrival to reject. What changed is that focus was handed somewhere else, and
        // a pointer that has not moved since is not a request to take it back.
        switch handoverDecision(for: target) {
        case .hold:
            if !holdingFocus {
                holdingFocus = true
                Log.debug("not focusing \(target.describedAs): focus was handed to "
                    + "\(frontmostName()) and the pointer has not settled anywhere else since")
            }
            return nil
        case .entered:
            // The entry guard below is answered already: the handover watched the pointer travel
            // here and stay, which is more than recent motion can still show by now.
            holdingFocus = false
            Log.debug("settled on \(target.describedAs); following the pointer again")
            lastResolved = target
            return target
        case .free:
            holdingFocus = false
        }

        if config.entryMotionPx > 0, motion.total < Double(config.entryMotionPx) {
            guard let previous = lastResolved else {
                // Just started, or just invalidated by a Space change or display reconfiguration.
                // Adopt whatever is under the pointer as the baseline rather than focusing it: the
                // pointer has not moved, so nothing has been entered. Without this, at the default
                // instant dwell, launching the agent stole focus to whatever the pointer happened to
                // be resting on.
                lastResolved = target
                Log.debug("baseline \(target.describedAs): not focusing without pointer movement")
                return nil
            }
            if previous != target {
                // Deliberately does not update the baseline: doing so would let the next tick accept
                // the same pop-up unconditionally, which is the thing being guarded against.
                Log.debug("ignoring \(target.describedAs): it arrived under a near-stationary "
                    + "pointer (\(Int(motion.total.rounded()))px of recent travel)")
                return nil
            }
        }

        lastResolved = target
        return target
    }

    /// What to do about this target while something else holds focus. The decision lives in
    /// `FocusHandover`, where it is tested; this supplies the live facts it needs -- which app holds
    /// focus, and how the pointer is moving -- and only while something is actually held.
    private func handoverDecision(for target: Target) -> HandoverDecision {
        guard config.handoverGuard, handover.isHolding,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != ownPid
        else { return .free }
        return handover.decide(
            for: target, frontmost: front,
            pointerMoved: pointerMovedThisTick, travelling: pointerIsTravelling, at: now
        )
    }

    /// The entry guard's own test, so the two cannot come to disagree about what counts as a pointer
    /// in motion -- except at `entryMotionPx` 0, where the guard is off and the comparison it uses
    /// would be trivially true of a pointer that has not moved at all. Any travel at all stands in
    /// for the threshold there; without it the settle clock could never start and the loop would
    /// poll at full rate for as long as focus was held.
    private var pointerIsTravelling: Bool {
        config.entryMotionPx > 0
            ? motion.total >= Double(config.entryMotionPx)
            : motion.total > 0
    }

    /// Ask, once a tick, whether the window last known under the pointer still holds focus, and let
    /// the handover judge what that means.
    ///
    /// This is deliberately asked before resolving the pointer's new position. Movement cannot
    /// explain focus leaving the window the pointer was already over: Heed has not acted on the new
    /// position yet. That closes the sampling hole where a menu-opened Settings or About window
    /// arrived during a tiny mouse movement and the old implementation discarded the evidence.
    /// `noteMovingPointerBaseline` records the newly resolved position later in the same tick.
    private func noteHandover() {
        guard config.handoverGuard else { return }

        let window = lastPointerWindow
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let hasFocus = window.map { focusMatches($0) }

        // An app with no usable Accessibility tree is resolved at app granularity, and every window
        // of it compares equal, so a hold anchored on one could not be ended by moving to another.
        // It still earns a hold -- just an unanchored one, which anywhere the pointer settles ends.
        let anchor = window?.window == nil ? nil : window

        let handed = handover.sample(
            window: window, hasFocus: hasFocus, anchor: anchor,
            owner: front == ownPid ? nil : front, pointerMoved: false
        )
        guard handed else { return }

        Log.debug("focus was handed to \(frontmostName()); it keeps it until the pointer settles "
            + "somewhere else")
        // A dwell candidate formed before this must not outlive it: the machine would return it
        // without hit-testing again, and the revalidation before applying focus deliberately uses
        // the raw hit test, which knows nothing about holds.
        machine.invalidate()
    }

    /// Once a moving tick has resolved where the pointer is now, make that the next comparison's
    /// baseline. Do not overwrite a hold just discovered above: that hold must judge the movement.
    private func noteMovingPointerBaseline(window: Target?) {
        guard config.handoverGuard, pointerMovedThisTick,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != ownPid, !handover.isHolding(owner: front)
        else { return }

        let anchor = window?.window == nil ? nil : window
        handover.sample(
            window: window, hasFocus: nil, anchor: anchor,
            owner: front, pointerMoved: true
        )
    }

    private func frontmostName() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else { return "another app" }
        return front.localizedName ?? front.bundleIdentifier ?? "pid \(front.processIdentifier)"
    }

    private func hitTest(at point: CGPoint) -> Target? {
        if now < hitTestCooldownUntil { return nil }

        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &hit
        )

        // One line per transition, not per call: hit tests run on every tick the pointer moves,
        // and an unrotated log must not pay by the hour for a permission revoked mid-run.
        if accessibilityLost, error != .apiDisabled {
            accessibilityLost = false
            syncMenuBar()
            Log.note("Accessibility access returned")
        }

        // Only some of these mean "there is no Accessibility here"; the rest are infrastructure
        // problems, and treating them all as the former sent healthy apps down the app-level path.
        switch error {
        case .success:
            hitTestFailures = 0
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
            return appLevelFallback(at: point)
        case .noValue:
            return nil   // nothing under the pointer, e.g. the desktop
        case .apiDisabled:
            if !accessibilityLost {
                accessibilityLost = true
                // Undimmed, the icon would go on claiming to work after the grant was revoked.
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

    private func resolveWindow(from element: AXUIElement) -> Target? {
        guard let pid = axPid(element), pid != ownPid else { return nil }
        if let until = blockedUntil[pid], now < until { return nil }

        let elementRole = axString(element, kAXRoleAttribute)
        let topLevel = axElement(element, kAXTopLevelUIElementAttribute)
        let topLevelRole = topLevel.flatMap { axString($0, kAXRoleAttribute) }

        let sources: [WindowSource]
        switch resolveWindowSource(topLevelRole: topLevelRole, elementRole: elementRole) {
        case .sheet:
            Log.debug("skipped: the pointer is over a sheet")
            return nil
        case .tryInOrder(let order):
            sources = order
        }

        var candidateWindow: AXUIElement?
        for source in sources {
            switch source {
            case .topLevel: candidateWindow = topLevel
            case .windowAttribute: candidateWindow = axElement(element, kAXWindowAttribute)
            case .hitElement: candidateWindow = element
            }
            if candidateWindow != nil { break }
        }
        guard let window = candidateWindow else {
            Log.debug("skipped: nothing window-shaped under the pointer "
                + "(element \(elementRole ?? "?"), top level \(topLevelRole ?? "none"))")
            return nil
        }

        // These two need no Accessibility round trip, and hovering an excluded app -- the Dock, at
        // any screen edge -- is constant. The policy checks both as well and remains the authority;
        // this only avoids paying for the attribute reads below to arrive at the same answer.
        guard let app = runningApp(pid: pid) else { return nil }
        let bundle = app.bundleIdentifier
        guard app.activationPolicy != .prohibited else { return nil }
        if let bundle, config.excludedBundleIDs.contains(bundle) {
            Log.debug("skipped: excluded \(bundle)")
            return nil
        }

        let size = axSize(window, kAXSizeAttribute)
        let title = axString(window, kAXTitleAttribute)
        let candidate = WindowCandidate(
            role: axString(window, kAXRoleAttribute),
            subrole: axString(window, kAXSubroleAttribute),
            isModal: axBool(window, kAXModalAttribute) == true,
            isMinimized: axBool(window, kAXMinimizedAttribute) == true,
            size: size,
            title: title,
            bundleID: bundle,
            canActivate: true
        )

        if case let .reject(why) = evaluate(candidate, policy: config.windowPolicy) {
            Log.debug("skipped: \(why)")
            return nil
        }

        // Rejected above when absent; unwrapped here only to build the frame.
        guard let size else { return nil }
        // No position reported means no geometric identity, rather than a fabricated (0, 0).
        let frame = axPoint(window, kAXPositionAttribute)
            .map { CGRect(origin: $0, size: size) } ?? .null

        let name = app.localizedName ?? bundle ?? "pid \(pid)"
        if name != lastResolvedName {
            lastResolvedName = name
            Log.debug("cursor over \(name)")
        }
        return Target(
            pid: pid, window: window, bundleID: bundle,
            frame: frame, title: title, describedAs: name
        )
    }

    /// App-level target for windows with no usable Accessibility tree. Per-window precision is not
    /// reachable for these without private API, so the app is the ceiling.
    private func appLevelFallback(at point: CGPoint) -> Target? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for window in windows {   // front to back
            guard let level = window[kCGWindowLayer as String] as? Int, level == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPid,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point)
            else { continue }

            if let until = blockedUntil[pid], now < until { return nil }
            guard let app = runningApp(pid: pid), app.activationPolicy != .prohibited else { return nil }
            let bundle = app.bundleIdentifier
            if let bundle, config.excludedBundleIDs.contains(bundle) { return nil }

            let name = app.localizedName ?? bundle ?? "pid \(pid)"
            Log.debug("no AX tree at cursor; falling back to app level for \(name)")
            return Target(
                pid: pid, window: nil, bundleID: bundle,
                frame: frame, title: nil, describedAs: name
            )
        }
        return nil
    }

    // MARK: - Applying focus

    /// Move focus to a target, then confirm it actually moved.
    ///
    /// Everything is fired in one go rather than as separately verified steps. Verification is the
    /// only expensive part -- it blocks this queue while it waits -- and measurement showed that on
    /// this OS only `activate` ever moves focus: `AXFrontmost` reports `settable = true`, the write
    /// returns success, and the frontmost app does not change. Waiting after each write to discover
    /// that was pure latency, up to three times per switch, which is what a sluggish, fighting focus
    /// felt like.
    ///
    /// The Accessibility writes stay because they cost one message each and may matter on an app not
    /// tested here. They are no longer waited on.
    private func applyFocus(to target: Target) -> Bool {
        let app = appElement(for: target.pid)

        // Order the window within its app first: this is what decides which of the app's windows
        // ends up in front once it activates.
        if let window = target.window {
            if config.raise { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
            axSet(window, kAXMainAttribute, kCFBooleanTrue)
        }

        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        axSet(app, kAXFrontmostAttribute, kCFBooleanTrue)
        if let window = target.window, axIsSettable(window, kAXFocusedAttribute) {
            axSet(window, kAXFocusedAttribute, kCFBooleanTrue)
        }

        guard verifyFocus(target) else {
            noteFailure(pid: target.pid)
            return false
        }
        failureCounts[target.pid] = nil
        handover.noteAppliedFocus(window: target, owner: target.pid)
        return true
    }

    /// Wait for focus to actually land, and say how long it took.
    ///
    /// Asks NSWorkspace which app is frontmost, not the Accessibility API. `AXFocusedApplication` on
    /// the system-wide element looks like the natural choice and is what an earlier version used, but
    /// on this OS it returns nothing at all whenever the focused app has no usable AX tree -- so it
    /// failed for precisely the apps most likely to need the fallback rungs, and it also made
    /// `focusMatches` below answer "not focused" for everything. That is worse than a wrong answer:
    /// it meant focus was re-applied on every tick, each attempt walking all three rungs and blocking
    /// this queue, which showed up as windows visibly fighting each other for the front.
    ///
    /// Verification is app-level. Making the app frontmost is the part that moves keyboard focus, so
    /// it is the part worth checking; the right window within the app is handled by AXRaise + AXMain
    /// on the way in. The elapsed time is logged so this stays a measurement rather than a guess.
    /// This budget is spent with the agent's queue blocked, so it is deliberately tight. An earlier
    /// 600ms turned a refusal into 1.2s of frozen agent across two rungs, which is exactly what a
    /// stuttering, fighting focus feels like. Nothing is lost by being impatient: the pointer is
    /// still over the target, so a failure simply retries on the next tick.
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

    /// Live check against real system focus, used to decide whether focusing is needed at all.
    private func focusMatches(_ target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            return false
        }

        // App-level fallback targets have no window to compare.
        guard let window = target.window else { return true }

        // The app's own focused window, rather than going through the system-wide element.
        let app = appElement(for: target.pid)
        guard let focusedWindow = axElement(app, kAXFocusedWindowAttribute) else {
            // No usable answer: treat the app being frontmost as good enough rather than
            // re-focusing forever.
            return true
        }
        if CFEqual(focusedWindow, window) { return true }

        // A dialog or floating panel that holds the app's key focus keeps it; see
        // transientWindowHoldsFocus in FFMCore. Reported as "already focused" so the machine
        // treats the tick as settled instead of retrying into a fight it must not win.
        let focusedSubrole = axString(focusedWindow, kAXSubroleAttribute)
        if transientWindowHoldsFocus(subrole: focusedSubrole) {
            Log.debug("\(target.describedAs): a \(focusedSubrole ?? "?") window holds the app's "
                + "key focus; leaving it")
            return true
        }
        // The target's app is the frontmost app here, so the cached check answers for it too.
        if config.promptGuard, frontmostPromptAwaitsAnswer() {
            Log.debug("\(target.describedAs): a prompt awaits an answer; leaving key focus alone")
            return true
        }

        // Electron hands back a different instance for the same window depending on how it was
        // obtained, so fall back to what was captured at hit-test time -- frame *and* title, for the
        // reason on Target's equality. Anything unreadable counts as "not a match": the cost is a
        // redundant focus call on an app that is already frontmost, which is cheap and idempotent.
        guard !target.frame.isNull,
              let origin = axPoint(focusedWindow, kAXPositionAttribute),
              let size = axSize(focusedWindow, kAXSizeAttribute),
              CGRect(origin: origin, size: size) == target.frame
        else { return false }
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

    // MARK: - Caches

    private func runningApp(pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }

    /// Whether the frontmost app's key window is a prompt in mid-question; see windowAwaitsAnswer.
    ///
    /// Cached briefly: at instant dwell this is consulted on every tick of a focus fight, and the
    /// answer takes several cross-process reads. Cheap for every other tick of heed's life -- no
    /// Accessibility call happens until the frontmost app actually has a prompt rule, which only
    /// Finder does.
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

    /// Buttons that are direct children of the window; the buttons inside a prompt's content
    /// (a scroll area's per-item controls, say) deliberately do not count.
    private func windowLevelButtonCount(_ window: AXUIElement) -> Int {
        guard let children = axCopy(window, kAXChildrenAttribute) as? [AXUIElement] else { return 0 }
        return children.reduce(0) {
            $0 + (axString($1, kAXRoleAttribute) == kAXButtonRole ? 1 : 0)
        }
    }

    private func appElement(for pid: pid_t) -> AXUIElement {
        let launched = NSRunningApplication(processIdentifier: pid)?.launchDate
        // A nil launch date never matches: two unrelated processes can both fail to report one,
        // and creating the element again is local work, not a cross-process call.
        if let cached = appElements[pid], let launched, cached.launched == launched {
            return cached.element
        }
        // Either nothing cached, or the pid was recycled by a different process.
        let element = AXUIElementCreateApplication(pid)
        appElements[pid] = (element, launched)
        return element
    }

    // MARK: - System events

    private func observeSystemEvents() {
        // Main thread, and once: `start()` registers before the queue's `isRunning` guard, so a
        // second call would double up every observer and leak the monitor token.
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
                guard let self else { return }
                queue.async {
                    self.pendingInvalidation = true
                    self.wakeLoop()   // an idling loop must not sit on this for a whole heartbeat
                }
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
                // Pids are recycled: a hold left behind by a dead process would be applied to
                // whatever inherits its number.
                self.handover.forget(owner: pid)
            }
        }

        // Pointer movement, which is the whole input to this program, arrives as events rather than
        // being polled for. A global monitor sees what is delivered to other applications, which is
        // every application but this one.
        //
        // It is an optimisation, not the mechanism: everything still works if it never fires, just
        // with up to `idlePollMs` of latency instead of none, which is why the heartbeat is a
        // second rather than a minute. Mouse-up is in the mask because a click can change what is
        // frontmost without the pointer travelling a pixel.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                       .leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] _ in
            guard let self, wantsMouseWake else { return }
            wantsMouseWake = false
            queue.async { self.wakeLoop() }
        }
        // Two gaps this leaves, both bounded by the heartbeat rather than closed: an event landing
        // in the moment between the queue deciding to idle and the main thread being told, and
        // events delivered to this process itself, which a global monitor never sees -- the pointer
        // sitting on our own status item is the whole of that case.

        // The callback is a bare C function pointer, but it takes a context pointer, so it can hand
        // off to the queue instead of writing a shared global -- which was a genuine data race, and
        // could also drop an update entirely if it landed between the read and the clear.
        //
        // Unretained is safe because the agent lives for the life of the process.
        CGDisplayRegisterReconfigurationCallback({ _, _, context in
            guard let context else { return }
            Unmanaged<Agent>.fromOpaque(context).takeUnretainedValue().noteDisplayReconfiguration()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Installed before the Accessibility gate, not from `start()`.
    ///
    /// Left inside `start()` it was never installed while the agent sat waiting for permission,
    /// so SIGHUP kept its default disposition and killed the process instead of reloading. KeepAlive
    /// hid that by respawning it.
    func installSignalHandlers() {
        // A dispatch source, not a POSIX handler: almost nothing is safe to call from inside a
        // signal handler, and reloading config is not on that list.
        signal(SIGHUP, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        source.setEventHandler { [weak self] in self?.reload() }
        source.resume()
        hangupSource = source
    }

    // MARK: - Diagnostics

    /// One-shot report of what the agent sees at the pointer right now.
    ///
    /// Exists because every interesting failure of a tool like this is invisible: "it did not focus
    /// that window" has a dozen possible causes, and this prints which one applies.
    func probe(at explicit: CGPoint? = nil) {
        Log.verbose = true
        AXUIElementSetMessagingTimeout(systemWide, 0.5)   // patience over responsiveness here

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
        // Reported rather than answered: a hold belongs to the running agent, which has been
        // watching what comes to the front. This process has just started and has no history at all.
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
            let elementRole = axString(element, kAXRoleAttribute)
            print("  element role:       \(elementRole ?? "-")")

            // Uses the same resolution the agent does, rather than a second copy of the rules: a
            // diagnostic that disagrees with the code it is diagnosing is worse than none.
            let topLevel = axElement(element, kAXTopLevelUIElementAttribute)
            let topLevelRole = topLevel.flatMap { axString($0, kAXRoleAttribute) }
            print("  top-level role:     \(topLevelRole ?? "-")")

            var window: AXUIElement?
            switch resolveWindowSource(topLevelRole: topLevelRole, elementRole: elementRole) {
            case .sheet:
                print("  resolved via:       nothing -- the pointer is over a sheet")
            case .tryInOrder(let order):
                for source in order {
                    switch source {
                    case .topLevel: window = topLevel
                    case .windowAttribute: window = axElement(element, kAXWindowAttribute)
                    case .hitElement: window = element
                    }
                    if window != nil {
                        print("  resolved via:       \(source)")
                        break
                    }
                }
                if window == nil { print("  resolved via:       nothing window-shaped") }
            }

            if let window {
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

    private var hangupSource: DispatchSourceSignal?
}
