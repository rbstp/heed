# Heed

**Focus follows mouse for macOS, in the spirit of Hyprland's `follow_mouse`.**

[![CI](https://github.com/rbstp/heed/actions/workflows/ci.yml/badge.svg)](https://github.com/rbstp/heed/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/rbstp/heed?logo=github)](https://github.com/rbstp/heed/releases/latest)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![macOS 14+ on Apple Silicon](https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)

A small background agent that moves keyboard focus to the window under the pointer, so you stop
clicking to type. Installs as `Heed.app` — no Dock icon and no window of its own, just a menu bar
icon that turns it on and off.

Built and verified on macOS 27.0 (Swift 6.4). Requires macOS 14+ on Apple Silicon — releases
carry no Intel slice, and the cask refuses Intel Macs rather than installing a binary that
cannot run.

## Install

### Homebrew

```sh
brew install --cask rbstp/tap/heed
```

That installs `Heed.app`, loads the login agent, and strips the quarantine attribute — released
builds are ad-hoc signed, so Gatekeeper would otherwise refuse them outright. The cost of ad-hoc is
that every upgrade invalidates the Accessibility grant, so expect to grant it again after one. The
cask clears the dead entry as it installs, which is what lets Heed ask you rather than going quiet;
see *Signing* below.

### From source

```sh
make cert        # once per machine, so the grant survives rebuilds -- see Signing below
make install     # build, sign, install to ~/Applications, load the login agent
make logs        # watch what it decides
make uninstall
```

Either way, macOS asks for Accessibility permission on first run — grant it under **System Settings >
Privacy & Security > Accessibility**. The agent notices within a couple of seconds; there is nothing
to restart.

## Turning it on and off

A cube in the menu bar says whether focus is following the pointer. Click it to turn Heed off, click
again to turn it back on. The icon is dimmed while it is off, and dimmed too while the Accessibility
grant is missing, since the pointer moves nothing in either case. Hovering it says which: an icon
that reports itself on and is still dimmed names the missing permission.

Clicking writes the same `enabled` key `defaults write` does, so the choice survives a restart and
the icon and the configuration cannot come to disagree. Off, the polling timer is cancelled rather
than left waking 25 times a second to return immediately.

Right-click, or control-click, for a short menu: the running version, the same switch as a menu
item, *Open Log*, and *Quit Heed*.

*Quit Heed* unloads the login agent rather than merely exiting, because the agent sets KeepAlive —
launchd replaces a process that exits within a second, so a Quit item that only exited would be
theatre, the icon back before the menu had finished closing. Unloading the job stops both at once.
The plist stays in `~/Library/LaunchAgents`, so Heed is back at your next login, and
`make install-agent` brings it back sooner. Which of the two quitting does is decided by
`XPC_SERVICE_NAME`: a copy you started yourself simply exits, and leaves the installed agent alone.

The switch, not *Quit*, is the off button for focus following — quitting gives up the hotkey and the
icon with it. To remove Heed altogether: `brew uninstall --cask heed`, or `make uninstall`. The
unload the menu item runs, by hand:

```sh
launchctl bootout gui/$(id -u)/io.github.rbstp.heed
```

**⌃⌘H toggles it from anywhere**, which the icon cannot: reaching the menu bar means dragging the
pointer across other windows, and with focus following the pointer, that moves focus on the way to
the switch. The combination is registered with Carbon rather than watched for, so pressing it is
consumed instead of also landing in whatever you were typing, and it needs no Accessibility grant —
it works while Heed is still waiting for one, which is when you are most likely to want it. The
registration is *exclusive*: a hotkey registered the ordinary way still succeeds when another app
already holds the combination, and then both actions fire on every press. Refused is the better
answer, and the log names the clash so you can pick another.

```sh
defaults write io.github.rbstp.heed hotkey 'cmd+ctrl+alt+f'   # or '' for none
make restart
```

Modifier names are forgiving (`cmd`, `command`, `⌘`, and `+`, `-` or a space between), and at least
one modifier that is not shift is required — a bare key would be swallowed system-wide, starting
with your ability to type it, and `shift+a` is not a chord, it is how a capital A is typed. A combination that cannot be parsed is refused with a log line rather than quietly
registering some other key; `Tests/FFMCoreTests/HotkeySpecTests.swift` covers that.

To keep the menu bar as it was, with the hotkey and `defaults write enabled` as the switches:

```sh
defaults write io.github.rbstp.heed menuBarIcon -bool false
make restart
```

## Configuration

Stored in the `io.github.rbstp.heed` defaults domain. Change a key, then `make restart` (or
`kill -HUP` the process).

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Master switch. Clicking the menu bar icon writes this key; off, no polling timer runs at all. |
| `menuBarIcon` | `true` | Show the cube in the menu bar. See *Turning it on and off* above. |
| `hotkey` | `cmd+ctrl+h` | Global combination that toggles Heed. Empty string disables it. |
| `dwellMs` | `0` | How long the pointer must rest on a window before focus follows. `0` is instant. Raise it to ~200 if sweeping the pointer across windows churns focus more than you like. |
| `pollMs` | `40` | Cursor sampling interval while there is something to watch. |
| `idlePollMs` | `1000` | Sampling interval once the pointer is parked and nothing is pending. A mouse event restores `pollMs` immediately, so this is the safety net rather than the mechanism — see *How it works*. |
| `raise` | `true` | Also raise the window. See *Focus and raise* below. |
| `typingCooldownMs` | `500` | Ignore the pointer for this long after a keystroke. |
| `clickGraceMs` | `150` | Ignore the pointer for this long after a mouse press or release. Releases count so the grace survives a long drag — it starts at the drop, not at the grab. Short: unlike typing, this exists only to cover clicks that begin and end between two polls, which an instantaneous button check cannot see. |
| `entryMotionPx` | `6` | Pointer travel (in points, over roughly the last 200 ms) required before a *different* window may take focus. Stops windows that appear under a still pointer from taking it. `0` disables. |
| `verifyTimeoutMs` | `100` | How long to wait for focus to land before giving up on this attempt. Spent with the agent blocked, so it is deliberately tight — the mechanism that works confirms in roughly 25 ms, and a failure just retries on the next tick. |
| `ignoreWhenCommandHeld` | `true` | Ignore the pointer while ⌘ is down, so Cmd-Tab is not fought. |
| `menuGuard` | `true` | Ignore the pointer while a menu, popover or drag image is on screen. |
| `requireStandardWindow` | `true` | Only focus ordinary windows (`AXStandardWindow`). Keeps transient pop-ups from dragging their app forward — see *Transient windows* below. |
| `promptGuard` | `true` | While a prompt awaits an answer in the frontmost app — Finder asking whether to replace the file you just dropped — the pointer moves no focus at all, so the prompt cannot be buried mid-question. Lifts the moment the question is answered. |
| `excludedWindowTitles` | `[]` | Case-insensitive **regular expressions**; a window whose title matches any of them is never focused. Applies to every app, and adds to the built-in rules below. |
| `excludedBundleIDs` | `[]` | Extra apps to never focus. **Added to** the built-in list, not replacing it. |
| `verbose` | `false` | Log every decision. |

Every numeric key is clamped to a sane range and says so in the log when it clamps, so a stray zero
cannot park the agent.

```sh
defaults write io.github.rbstp.heed dwellMs -int 200
defaults write io.github.rbstp.heed excludedBundleIDs -array com.example.Overlay
make restart
```

Excluded by default: this agent, Dock (which also covers Mission Control and Launchpad),
WindowServer, loginwindow, Control Center, Notification Center, SystemUIServer, the screenshot UI,
Spotlight, Raycast and AltTab. The last two draw floating panels the pointer would otherwise chase.

## When it doesn't do what you expect

```sh
make probe              # what the agent sees under the pointer right now
make probe X=960 Y=540  # ...or at a screen point you would rather not hover
```

It reports every guard, the raw Accessibility element, how the window was resolved and the final
target:

```
guards
  last keystroke:     49.66s ago (cooldown 500ms)
  command held:       no
  overlay on screen:  no

accessibility at cursor
  element role:       AXWindow
  resolved via:       the hit element is itself the window
  subrole:            AXStandardWindow
  AXMain settable:    true

result
  target:             Zen (pid 1906)
  granularity:        window
  already focused:    true
```

The log is append-only with no rotation — negligible with `verbose` off, less so with it on;
`make logs-clear` truncates it in place. `make logs` with `verbose` on shows which focus mechanism
each app responded to, how long it took to land, and why a window was skipped.

## Signing, and why it decides whether you keep re-granting

Accessibility grants are keyed to the app's *designated requirement*, so how the app is signed
decides whether a new build keeps the grant. `make requirement` reports which mode you are in.

Ad-hoc signing — what you get from Homebrew, and from `make bundle ADHOC=1` — produces a bare hash
of the binary:

```
designated => cdhash H"469f06f184bd6d10061d03a099aa144ff37937dc"
```

Every build is then a different identity as far as TCC is concerned, so **upgrading invalidates the
grant**. The dead record left behind is worse than no record at all: macOS suppresses the permission
prompt while any record for the bundle ID exists, so the agent waits forever while the checkbox in
System Settings still appears ticked. That was the single most confusing failure mode here.

The Homebrew cask now clears that record in its `postflight`, before it loads the agent, so an
upgrade asks you for the permission again instead of going quiet. From a source build,
`make reset-permission` does the same by hand. Uninstalling leaves the entry listed either way:

```sh
tccutil reset Accessibility io.github.rbstp.heed     # then grant it again
```

Building from source avoids this. `make cert` creates an identity called `Heed Local Signing`,
scoped to code signing only and trusted in your login keychain rather than system-wide, so it cannot
vouch for anything else. `make bundle` picks it up automatically, and the requirement then names the
certificate, which does not change:

```
designated => identifier "io.github.rbstp.heed" and certificate leaf = H"28d1366140a85b670c777c19..."
```

Two things to expect: the first time `codesign` uses the key macOS asks for keychain access (choose
**Always Allow**, or it asks on every build), and switching from ad-hoc to certificate signing
changes the app's identity, so you grant Accessibility once more. After that it sticks. If the
identity is missing, `make bundle` **refuses** rather than quietly falling back to ad-hoc, which
would silently reinstate the loss the certificate exists to prevent.

To remove the identity later (`-t` also removes the trust setting, which `-c` alone leaves behind):

```sh
security delete-identity -t -c "Heed Local Signing" ~/Library/Keychains/login.keychain-db
```

Trust `make requirement` over this document: the difference that matters is whether the requirement
mentions `cdhash` or a certificate.

## Transient windows

A meeting reminder, an alert or a floating palette should not drag its whole application in front of
what you were doing, just because the pointer crossed it on the way to dismissing it. So only
ordinary windows are eligible: `requireStandardWindow` requires the subrole `AXStandardWindow`.

That is an allowlist rather than a list of things to reject, which is both simpler and safer — every
real window across the apps tested here, Electron ones (Slack, Notion, Docker Desktop) included,
reports `AXStandardWindow`, while transient chrome does not. Refusing these windows costs nothing,
because focusing one is not useful anyway: keyboard focus can only move by making its app frontmost,
which is exactly the disruption you are trying to avoid.

Some pop-ups are indistinguishable from real windows. Outlook's meeting reminder is a 400x146 panel
that reports subrole `AXStandardWindow` and carries both minimize and zoom buttons — nothing
structural separates it from a document window. Its one difference, no `AXFullScreenButton`, is
useless as a rule: legitimate fixed-size windows lack one too, Calculator among them. So there is a
small built-in list of title rules:

| App | Title pattern |
| --- | --- |
| Microsoft Outlook | `^[0-9]+ (Reminders?|rappels?)$` |

The pattern is anchored on the exact titles Outlook uses (`1 Reminder`, `3 Reminders` — and
`1 rappel` in French, since the title follows the app's locale) so an email whose subject merely
mentions a reminder stays focusable. Other locales need an `excludedWindowTitles` entry until
their titles are added to the built-in rule. `Tests/FFMCoreTests/TitleRuleTests.swift`
covers that, because the hazard with title rules is not failing to match — it is matching too much.
To add your own:

```sh
defaults write io.github.rbstp.heed excludedWindowTitles -array '^Picture in Picture$'
make restart
```

The rule also works in the opposite direction: a dialog or floating panel that *holds* the
app's keyboard focus keeps it. The everyday case is the About box — picked from a menu, it opens
away from the pointer, so the main window still sitting under the pointer would immediately take
key status back, and since a dialog can never be acquired by pointer, hovering it could not
restore it. The panel was buried before it could be read. So within the app that owns the dialog,
the pointer does not move key focus at all; moving to a different app still switches, and clicking
a sibling window still works — that is macOS, not Heed.

Some prompts cannot be classified even by subrole. Finder's copy prompt — the one asking whether
to replace the file you just dropped — reports `AXStandardWindow`, while on this OS Finder's
ordinary browser windows report `AXDialog`: exactly backwards. It is recognised instead by the
accessibility identifier its developer gave it (`Progress`), which unlike its localized title
survives a language change, together with the row of answer buttons that only its question form
shows — the same window doubles as the plain copy-progress bar, which must not hold anything.
While such a prompt awaits an answer in the *frontmost* app, the pointer moves no focus anywhere,
not even to another app: stealing focus would raise some other window over the prompt, and a
buried prompt can never be reached by pointer again, because the hit test resolves whatever covers
it. The moment the question is answered everything resumes, including the window under the resting
pointer taking focus. `promptGuard` turns this off.

## Windows that arrive under the pointer

Focus follows the pointer, not the other way round. A window that appears — or is raised — beneath a
pointer that is sitting still has not been moved onto, so focusing it would let a pop-up take focus
with no input from you at all. A change of target is therefore only accepted when the pointer has
actually travelled recently, which `entryMotionPx` sets. Movement is accumulated over roughly 200 ms
rather than compared tick-to-tick, because a slow deliberate crossing covers only a pixel or two per
tick and would otherwise be mistaken for a stationary pointer.

One thing this cannot fix: **clicking** a button in a background app's window activates that app.
That is macOS, not Heed. Dismissing an Outlook reminder brings Outlook forward for exactly that
reason.

## Focus and raise

macOS does not separate them. Making an app frontmost brings its window forward, so Hyprland's
focus-without-raise has no equivalent here and `raise` only controls ordering *within* an app. A
platform constraint, not a missing feature.

## How it works

1. Sample the cursor with `CGEvent.location` at `pollMs`, but only while there is something to
   watch (below). Already in top-left screen coordinates, which is what Accessibility uses —
   `NSEvent.mouseLocation` is bottom-left and silently mis-targets on multi-display setups.
2. When the pointer moved, hit-test with `AXUIElementCopyElementAtPosition`, which is z-order aware.
   This is what lets the whole thing stay on public API: identifying a window this way avoids having
   to map a `CGWindowID` onto an `AXUIElement`, which is what pushes yabai, AeroSpace and Amethyst
   onto the private `_AXUIElementGetWindow`. Accessibility is the only permission needed — no Screen
   Recording.
3. Resolve the window via `AXTopLevelUIElement`, then `AXWindow`, then the element itself. That order
   matters: `AXWindow` maps an element inside a sheet to the window that *owns* the sheet, which
   would hide the fact that the pointer is over a sheet.
4. Order the window within its app (`AXRaise` + `AXMain`), then move focus:
   `NSRunningApplication.activate`, plus `AXFrontmost` and `AXFocused` as cheap extra writes. Confirm
   it actually moved, with a tight budget.

**The loop stops sampling when the pointer does.** A window can only be entered by moving onto it, so
a pointer parked over a window that has already been resolved has nothing left to say, and sampling
it 25 times a second only proves it is still parked. The timer drops to `idlePollMs` with half of
that as leeway, which lets the system fire it alongside whatever else it was going to wake for —
measured here, 25 wakeups a second becomes about one. A global mouse monitor snaps it back to
`pollMs` on the first event, firing that tick immediately rather than at the end of the interval, so
what this costs is wakeups rather than latency.

Movement is not the only thing worth waiting for, so the loop also stays fast while a dwell is
running, while a hit test has been armed by a suppression or a Space change, and while an
unresponsive app's circuit breaker or hit-test cooldown is still counting down — a deadline
expiring changes what is focusable with nothing to announce it. `DwellMachine.needsTick` is the
tested half of that decision.

The harder half is input the loop never saw. A whole suppression can begin and end between two
heartbeats — press Cmd-Tab with the pointer parked and the modifier, the keystroke and its cooldown
are over before the next one — where the old loop always sampled it and armed a hit test. Watching
the keyboard for that would mean a second permission this program deliberately does not ask for, so
the question is asked backwards instead: an idling tick checks whether any input is newer than the
previous tick, and re-derives if so. That needs no monitor and covers every kind of input at once.
What is left is bounded rather than eliminated: an event arriving in the moment between the loop
deciding to idle and the monitor being told, or delivered to Heed's own status item, waits for the
heartbeat.

Confirmation reads focus back rather than trusting return codes, because a successful write proves
nothing here. Three measurements shaped this, and each was the opposite of what the API surface
suggests:

- **`AXFrontmost` does not move focus on macOS 27.** It reports `settable = true`, the write returns
  success, and the frontmost app does not change. AppKit activation is what works — every app tested,
  including Electron ones and System Settings, moved via `activate` and none via `AXFrontmost`.
- **`AXFocusedApplication` on the system-wide element returns nothing** whenever the focused app has
  no usable Accessibility tree, so `NSWorkspace.frontmostApplication` answers that question instead.
  Used as the "is this already focused?" check it was worse than useless: it said "no" for
  everything, so focus was re-applied on every tick.
- **Waiting is the expensive part.** Confirmation blocks the agent's loop, so everything is fired in
  one go and confirmed once, rather than verified step by step. Nothing is lost by being impatient —
  the pointer is still over the target, so a failed attempt just retries on the next tick.

The agent holds no memory of what it last focused. An earlier design cached it and refused to
re-focus the same window, which broke the moment focus moved by other means. Live system state is the
only authority.

`Sources/FFMCore` holds the decisions that are functions of values rather than of API calls: dwell
timing, which element counts as the window, whether a candidate is eligible, the title rules and the
motion window. Those are covered by `swift test`. What is deliberately *not* abstracted is the
platform behaviour itself — whether `AXFrontmost` moves focus cannot be learned from a test double,
which returns whatever its author believed, and in that case the belief was the bug.

## Limitations

- Focus and raise are inseparable across apps (above).
- Apps with a weak Accessibility tree may ignore `AXMain`. Apps with none — some games, XQuartz, a
  few Java toolkits — fall back to app-level activation; per-window precision is not reachable for
  them without private API.
- Stage Manager manages its own window layering and may fight this.
- Homebrew builds, and source builds without `make cert`, lose the Accessibility grant on every
  upgrade (see *Signing* above).

## Development

```sh
make test             # the FFMCore logic; builds in Swift 6 language mode
make check-package    # assemble and verify a staged bundle without touching the install
make dist             # build the release archive the cask downloads, and print its checksum
```

CI runs the tests, a release compile and `check-package` on pull requests. `check-package` exists
because compiling proves very little here: a broken plist, a missing icon or a signature that does
not verify all build perfectly well.

Merging a pull request into `master` releases. `.github/workflows/release.yml` works out the next
version from the latest tag — a PR whose title starts with `feat` takes the minor, anything else the
patch — then builds the archive, publishes it as a GitHub release, and commits the new version and
checksum into `Casks/heed.rb` in [rbstp/homebrew-tap](https://github.com/rbstp/homebrew-tap) using
the `TAP_TOKEN` secret. Those two lines are generated — editing them by hand only invites the cask
and the release disagreeing.

A PR that changes nothing but `.github/` and this file does not release, since neither ships a
binary. Otherwise put `[skip-release]` in the PR title to merge without releasing, and run the
workflow by hand from the Actions tab to release a specific version.

The repository has immutable releases enabled, so a published release can never gain an asset. The
workflow therefore drafts the release, attaches the archive and publishes last, which leaves a
fixable draft when a run fails rather than a permanently empty release. Creating a release yourself
in the UI publishes it empty before any archive exists, which cannot be undone — let the workflow
do it.

## Prior art

[`sbmpost/AutoRaise`](https://github.com/sbmpost/AutoRaise) solves the same problem in C++ and
carries per-app workarounds worth reading if an app misbehaves here. yabai and AeroSpace have
focus-follows-mouse adjacent features as part of full tiling window managers.

## License

MIT — see [LICENSE](LICENSE).
