# Heed

**Focus follows mouse for macOS, in the spirit of Hyprland's `follow_mouse`.**

[![CI](https://github.com/rbstp/heed/actions/workflows/ci.yml/badge.svg)](https://github.com/rbstp/heed/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/rbstp/heed?logo=github)](https://github.com/rbstp/heed/releases/latest)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)

A small background agent that moves keyboard focus to the window under the pointer, so you stop
clicking to type. Installs as `Heed.app` — no Dock icon, no window of its own.

Built and verified on macOS 27.0 (arm64, Swift 6.4). Requires macOS 14+.

## Install

### Homebrew

```sh
brew install --cask rbstp/tap/heed
```

That installs `Heed.app`, loads the login agent, and strips the quarantine attribute — released
builds are ad-hoc signed, so Gatekeeper would otherwise refuse them outright. The cost of ad-hoc is
that `brew upgrade` invalidates the Accessibility grant; see *Signing* below.

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

## Configuration

Stored in the `io.github.rbstp.heed` defaults domain. Change a key, then `make restart` (or
`kill -HUP` the process).

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Master switch. |
| `dwellMs` | `0` | How long the pointer must rest on a window before focus follows. `0` is instant. Raise it to ~200 if sweeping the pointer across windows churns focus more than you like. |
| `pollMs` | `40` | Cursor sampling interval. |
| `raise` | `true` | Also raise the window. See *Focus and raise* below. |
| `typingCooldownMs` | `500` | Ignore the pointer for this long after a keystroke. |
| `clickGraceMs` | `150` | Ignore the pointer for this long after a mouse press. Short: unlike typing, this exists only to cover clicks that begin and end between two polls, which an instantaneous button check cannot see. |
| `entryMotionPx` | `6` | Pointer travel (in points, over roughly the last 200 ms) required before a *different* window may take focus. Stops windows that appear under a still pointer from taking it. `0` disables. |
| `verifyTimeoutMs` | `100` | How long to wait for focus to land before giving up on this attempt. Spent with the agent blocked, so it is deliberately tight — the mechanism that works confirms in roughly 25 ms, and a failure just retries on the next tick. |
| `ignoreWhenCommandHeld` | `true` | Ignore the pointer while ⌘ is down, so Cmd-Tab is not fought. |
| `menuGuard` | `true` | Ignore the pointer while a menu, popover or drag image is on screen. |
| `requireStandardWindow` | `true` | Only focus ordinary windows (`AXStandardWindow`). Keeps transient pop-ups from dragging their app forward — see *Transient windows* below. |
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
make probe          # what the agent sees under the pointer right now
make probe X Y      # ...or at a screen point you would rather not hover
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

Every build is then a different identity as far as TCC is concerned, so **upgrading silently
invalidates the grant** while the checkbox in System Settings still appears ticked. That is the
single most confusing failure mode here. If Heed goes quiet right after an upgrade:

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
| Microsoft Outlook | `^[0-9]+ Reminders?$` |

The pattern is anchored on the exact titles Outlook uses (`1 Reminder`, `3 Reminders`) so an email
whose subject merely mentions a reminder stays focusable. `Tests/FFMCoreTests/TitleRuleTests.swift`
covers that, because the hazard with title rules is not failing to match — it is matching too much.
To add your own:

```sh
defaults write io.github.rbstp.heed excludedWindowTitles -array '^Picture in Picture$'
make restart
```

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

1. Sample the cursor with `CGEvent.location` at `pollMs`. Already in top-left screen coordinates,
   which is what Accessibility uses — `NSEvent.mouseLocation` is bottom-left and silently mis-targets
   on multi-display setups.
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

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds the archive, publishes it as a
GitHub release, then commits the new version and checksum into `Casks/heed.rb` in
[rbstp/homebrew-tap](https://github.com/rbstp/homebrew-tap) using the `TAP_TOKEN` secret. Those two
lines are generated — editing them by hand only invites the cask and the release disagreeing.

## Prior art

[`sbmpost/AutoRaise`](https://github.com/sbmpost/AutoRaise) solves the same problem in C++ and
carries per-app workarounds worth reading if an app misbehaves here. yabai and AeroSpace have
focus-follows-mouse adjacent features as part of full tiling window managers.

## License

MIT — see [LICENSE](LICENSE).
