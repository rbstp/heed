import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import FFMCore
import Foundation

/// Set from a CoreGraphics display-reconfiguration callback, which is a bare C function pointer and
/// so cannot capture context. Written on the CG callback thread, read on the agent queue; a torn
/// read of a Bool is not a practical concern and the only cost of missing an update is one extra
/// tick before dwell is invalidated.
nonisolated(unsafe) private var displayDidReconfigure = false

final class Agent {
    private let systemWide = AXUIElementCreateSystemWide()
    private let queue = DispatchQueue(label: "\(bundleID).loop", qos: .userInitiated)
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    private var config: Config
    private var machine: DwellMachine<Target>
    private var timer: DispatchSourceTimer?

    private var lastCursor = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    private var pendingInvalidation = false

    /// Recent pointer travel, and the last window accepted as a focus target. Together they
    /// distinguish the pointer moving onto a window from a window arriving under a still pointer.
    private var motion = MotionTracker(capacity: 5)
    private var lastResolved: Target?

    /// Cached per-app Accessibility elements. Keyed by pid but validated against launch date,
    /// because pids are recycled and handing a dead element back to the Accessibility API is not
    /// something to find out about in production.
    private var appElements: [pid_t: (element: AXUIElement, launched: Date?)] = [:]

    /// Apps that repeatedly failed to answer. Prevents one hung process from costing a messaging
    /// timeout on every tick.
    private var blockedUntil: [pid_t: Double] = [:]
    private var failureCounts: [pid_t: Int] = [:]

    private var isRunning = false
    private var hitTestFailures = 0
    private var hitTestCooldownUntil: Double = 0


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

    func start() {
        // Bound every Accessibility message process-wide. Passing the system-wide element sets the
        // global default rather than a per-element one.
        //
        // Note this bounds each *message*, not a whole tick: a tick can issue several. That is why
        // it is deliberately short and why the number of messages per tick is kept small.
        AXUIElementSetMessagingTimeout(systemWide, 0.1)

        isRunning = true
        observeSystemEvents()
        scheduleTimer()

        Log.note("running: dwell=\(config.dwellMs)ms poll=\(config.pollMs)ms raise=\(config.raise) "
            + "typingCooldown=\(config.typingCooldownMs)ms verbose=\(config.verbose)")
    }

    private func scheduleTimer() {
        timer?.cancel()
        motion = MotionTracker(capacity: max(2, Int((0.2 / config.poll).rounded())))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.poll, repeating: config.poll, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func reload() {
        queue.async { [self] in
            config = Config.load()
            Log.verbose = config.verbose
            machine.dwell = config.dwell
            machine.invalidate()
            if isRunning { scheduleTimer() }   // pollMs may have changed
            Log.note("reloaded config: dwell=\(config.dwellMs)ms poll=\(config.pollMs)ms "
                + "raise=\(config.raise) enabled=\(config.enabled)")
        }
    }

    // MARK: - Main loop

    private func tick() {
        guard config.enabled else { return }

        if displayDidReconfigure {
            displayDidReconfigure = false
            pendingInvalidation = true
        }

        let cursor = CGEvent(source: nil)?.location ?? lastCursor
        let moved = cursor != lastCursor
        let step = lastCursor.x.isFinite
            ? Double(hypot(cursor.x - lastCursor.x, cursor.y - lastCursor.y))
            : 0
        motion.record(step.isFinite ? step : 0)
        lastCursor = cursor

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

        guard let target else { return }

        // Revalidate before acting. Dwell gives the world time to change underneath a stationary
        // pointer -- the window can close, quit, minimize, move, or slide to another Space -- and
        // acting on a stale reference could make a window-less app frontmost.
        //
        // Skipped when dwell is instant: there is no elapsed time for anything to change in, so the
        // second hit test would only repeat the first one's answer at twice the cost.
        var confirmed = target
        if config.dwellMs > 0 {
            guard let revalidated = hitTest(at: cursor), revalidated == target else {
                Log.debug("target changed during dwell; discarding \(target.describedAs)")
                machine.invalidate()
                return
            }
            confirmed = revalidated
        }

        if !applyFocus(to: confirmed) {
            // Re-arm so a stationary pointer still gets another attempt; going through invalidate()
            // means the next attempt re-derives the target rather than reusing this reference.
            machine.invalidate()
        }
    }

    // MARK: - Guards

    private func currentCondition(cursorMoved: Bool) -> TickCondition {
        if pendingInvalidation {
            pendingInvalidation = false
            Log.debug("invalidated by a system event")
            return .invalidating
        }

        // One call covering every button, rather than polling each button index separately.
        if NSEvent.pressedMouseButtons != 0 { return .suppressing }

        // Typing must win over the pointer. Without this, resting the pointer over another window
        // while typing sends the rest of the sentence somewhere else -- the worst thing this tool
        // could do. Reading "time since last key" also catches clicks and keystrokes that begin and
        // end entirely between two polls, which sampling instantaneous state cannot.
        if config.typingCooldownMs > 0 {
            let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            if sinceKey < config.typingCooldown { return .suppressing }
        }

        // A password field makes an unwanted focus change more dangerous, not less.
        if IsSecureEventInputEnabled() { return .suppressing }

        if config.ignoreWhenCommandHeld,
           CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
            return .suppressing   // Cmd-Tab in progress
        }

        // Only worth a round trip while something is actually pending.
        if config.menuGuard, cursorMoved || machine.hasCandidate, overlayPresent() {
            return .suppressing
        }

        return .normal
    }

    /// True when a menu, popover, drag image or similar transient overlay is on screen.
    ///
    /// Detected by window level rather than by sampling the focused element, because while a
    /// pointer-driven menu is open the focused element can still report the control underneath it.
    /// The upper bound excludes the cursor's own window, which sits far above everything.
    private func overlayPresent() -> Bool {
        let lower = Int(CGWindowLevelForKey(.popUpMenuWindow))   // 101: menus, popovers
        let upper = 2000                                          // below the cursor window
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for window in windows {
            guard let level = window[kCGWindowLayer as String] as? Int,
                  level >= lower, level < upper
            else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
            Log.debug("suppressed: overlay on screen (\(owner) at level \(level))")
            return true
        }
        return false
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
        guard let target = hitTest(at: point) else { return nil }

        if config.entryMotionPx > 0,
           let previous = lastResolved,
           previous != target,
           motion.total < Double(config.entryMotionPx) {
            Log.debug("ignoring \(target.describedAs): it arrived under a near-stationary pointer "
                + "(\(Int(motion.total.rounded()))px of recent travel)")
            return nil
        }

        lastResolved = target
        return target
    }

    private func hitTest(at point: CGPoint) -> Target? {
        if now < hitTestCooldownUntil { return nil }

        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &hit
        )

        if error == .cannotComplete {
            hitTestFailures += 1
            if hitTestFailures >= 3 {
                hitTestCooldownUntil = now + 2
                hitTestFailures = 0
                Log.debug("hit test timing out; backing off for 2s")
            }
            return nil
        }
        hitTestFailures = 0

        guard error == .success, let element = hit else {
            // No Accessibility tree here at all (some games, XQuartz, a few Java toolkits).
            return appLevelFallback(at: point)
        }
        return resolveWindow(from: element)
    }

    private func resolveWindow(from element: AXUIElement) -> Target? {
        guard let pid = axPid(element), pid != ownPid else { return nil }
        if let until = blockedUntil[pid], now < until { return nil }

        // Top level first, then the owning window.
        //
        // Order matters: kAXWindowAttribute deliberately maps an element inside a sheet to the
        // window that owns the sheet, which would erase the fact that the pointer is over a sheet
        // before the guards below ever get to see it.
        let container = axElement(element, kAXTopLevelUIElementAttribute)
            ?? axElement(element, kAXWindowAttribute)
            ?? (axString(element, kAXRoleAttribute) == kAXWindowRole ? element : nil)

        guard let window = container else { return nil }

        let role = axString(window, kAXRoleAttribute)
        guard role == kAXWindowRole else {
            // Sheets, menus, popovers, tooltips. A sheet's app is already frontmost anyway, so
            // there is nothing useful to do and touching it risks disturbing a modal interaction.
            Log.debug("skipped: role \(role ?? "nil")")
            return nil
        }

        let subrole = axString(window, kAXSubroleAttribute)

        // Only ordinary document/app windows are eligible for pointer focus.
        //
        // An allowlist rather than a blocklist, which is both simpler and safer: every real window
        // across the apps on this machine -- Electron ones (Slack, Notion, Docker Desktop) included
        // -- reports AXStandardWindow, while transient chrome does not. Enumerating every kind of
        // panel, alert, HUD and popover to reject would be a losing game.
        //
        // This is what stops something like an Outlook meeting reminder from dragging its whole
        // application forward just because the pointer crossed it. Focusing such a window is not
        // useful anyway: keyboard focus can only move by making the app frontmost, which is exactly
        // the disruption you do not want from a transient pop-up you are trying to dismiss.
        if config.requireStandardWindow {
            guard subrole == kAXStandardWindowSubrole else {
                Log.debug("skipped: subrole \(subrole ?? "none") is not a standard window")
                return nil
            }
        } else if let subrole, [
            kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole,
            kAXDialogSubrole, kAXSystemDialogSubrole,
        ].contains(subrole) {
            Log.debug("skipped: subrole \(subrole)")
            return nil
        }

        if axBool(window, kAXModalAttribute) == true { return nil }
        if axBool(window, kAXMinimizedAttribute) == true { return nil }

        let origin = axPoint(window, kAXPositionAttribute) ?? .zero
        let size = axSize(window, kAXSizeAttribute) ?? .zero
        if size.width < 40 || size.height < 40 { return nil }
        let frame = CGRect(origin: origin, size: size)

        guard let app = runningApp(pid: pid) else { return nil }

        // .prohibited apps cannot be activated at all. Accessory apps are allowed through: they can
        // own perfectly ordinary user-facing windows, so activation policy is treated as one signal
        // rather than as a gate. Role, subrole, size and visibility above are the real policy.
        if app.activationPolicy == .prohibited { return nil }

        let bundle = app.bundleIdentifier
        if let bundle, config.excludedBundleIDs.contains(bundle) {
            Log.debug("skipped: excluded \(bundle)")
            return nil
        }

        // Windows that pass every structural check but are still transient chrome. Matches on
        // AXTitle, which -- unlike CGWindowList's window names -- needs no Screen Recording grant.
        // The title is only fetched when a rule could apply, so most windows cost nothing here.
        let rules = config.titleExclusions.filter { $0.applies(toBundleID: bundle) }
        if !rules.isEmpty, let title = axString(window, kAXTitleAttribute) {
            if titleIsExcluded(title, bundleID: bundle, rules: rules) {
                Log.debug("skipped: title \"\(title)\" matches a transient-window rule")
                return nil
            }
        }

        let name = app.localizedName ?? bundle ?? "pid \(pid)"
        if name != lastResolvedName {
            lastResolvedName = name
            Log.debug("cursor over \(name)")
        }
        return Target(pid: pid, window: window, bundleID: bundle, frame: frame, describedAs: name)
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

            guard let app = runningApp(pid: pid), app.activationPolicy != .prohibited else { return nil }
            let bundle = app.bundleIdentifier
            if let bundle, config.excludedBundleIDs.contains(bundle) { return nil }

            let name = app.localizedName ?? bundle ?? "pid \(pid)"
            Log.debug("no AX tree at cursor; falling back to app level for \(name)")
            return Target(pid: pid, window: nil, bundleID: bundle, frame: frame, describedAs: name)
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
        failureCounts[target.pid] = 0
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

        // Electron hands back a different instance for the same window depending on how it was
        // obtained, so fall back to the frame captured at hit-test time.
        guard let origin = axPoint(focusedWindow, kAXPositionAttribute),
              let size = axSize(focusedWindow, kAXSizeAttribute)
        else { return true }
        return CGRect(origin: origin, size: size) == target.frame
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

    private func appElement(for pid: pid_t) -> AXUIElement {
        let launched = NSRunningApplication(processIdentifier: pid)?.launchDate
        if let cached = appElements[pid], cached.launched == launched {
            return cached.element
        }
        // Either nothing cached, or the pid was recycled by a different process.
        let element = AXUIElementCreateApplication(pid)
        appElements[pid] = (element, launched)
        return element
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter

        for name: NSNotification.Name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                queue.async { self.pendingInvalidation = true }
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
            }
        }

        CGDisplayRegisterReconfigurationCallback({ _, _, _ in displayDidReconfigure = true }, nil)
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
            // Same three-step resolution the agent uses, including the case where the hit element is
            // itself the window and both container attributes are absent.
            let container = axElement(element, kAXTopLevelUIElementAttribute)
                ?? axElement(element, kAXWindowAttribute)
                ?? (elementRole == kAXWindowRole ? element : nil)
            if let container {
                let via = axElement(element, kAXTopLevelUIElementAttribute) != nil ? "AXTopLevelUIElement"
                    : axElement(element, kAXWindowAttribute) != nil ? "AXWindow"
                    : "the hit element is itself the window"
                print("  resolved via:       \(via)")
                print("  top-level role:     \(axString(container, kAXRoleAttribute) ?? "-")")
                print("  subrole:            \(axString(container, kAXSubroleAttribute) ?? "-")")
                if let size = axSize(container, kAXSizeAttribute) {
                    print("  size:               \(Int(size.width))x\(Int(size.height))")
                }
                print("  title:              \(axString(container, kAXTitleAttribute) ?? "-")")
                print("  AXMain settable:    \(axIsSettable(container, kAXMainAttribute))")
                print("  AXFocused settable: \(axIsSettable(container, kAXFocusedAttribute))")
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
