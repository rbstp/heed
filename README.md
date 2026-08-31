# Heed

Focus follows mouse for macOS, in the spirit of Hyprland's `follow_mouse`. A small background agent
that moves keyboard focus to the window under the pointer, so you stop clicking to type.

Installs as `Heed.app` (a background agent -- no Dock icon, no window). The repo, and the defaults
domain, stay `focus-macos` / `io.github.rbstp.heed`.

Built and verified on macOS 27.0 (arm64, Swift 6.4). Requires macOS 14+.

```sh
make install     # build, sign, install to ~/Applications, load the login agent
make logs        # watch what it decides
make uninstall
```

On first run macOS will ask for Accessibility permission — grant it under **System Settings >
Privacy & Security > Accessibility**. The agent notices on its own within a couple of seconds; there
is nothing to restart.

## Configuration

Stored in the `io.github.rbstp.heed` defaults domain. Change a key, then `make restart`
(or `kill -HUP` the process).

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Master switch. |
| `dwellMs` | `0` | How long the pointer must rest on a window before focus follows. `0` is instant. Raise it to ~200 if sweeping the pointer across windows churns focus more than you like. |
| `pollMs` | `40` | Cursor sampling interval. |
| `raise` | `true` | Also raise the window. See *Focus and raise* below. |
| `typingCooldownMs` | `500` | Ignore the pointer for this long after a keystroke. |
| `entryMotionPx` | `6` | Pointer travel (in points, over roughly the last 200 ms) required before a *different* window may take focus. Stops windows that appear under a still pointer from taking it. `0` disables. |
| `verifyTimeoutMs` | `600` | How long to wait for focus to actually land before trying the next fallback. Electron apps activate noticeably slower than native ones. |
| `ignoreWhenCommandHeld` | `true` | Ignore the pointer while ⌘ is down, so Cmd-Tab is not fought. |
| `menuGuard` | `true` | Ignore the pointer while a menu, popover or drag image is on screen. |
| `requireStandardWindow` | `true` | Only focus ordinary windows (`AXStandardWindow`). Keeps transient pop-ups from dragging their app forward -- see *Transient windows* below. Set `false` if an app you use exposes windows that don't report a standard subrole. |
| `excludedWindowTitles` | `[]` | Case-insensitive **regular expressions**; a window whose title matches any of them is never focused. Applies to every app, and adds to the built-in rules below. |
| `verbose` | `false` | Log every decision. |
| `excludedBundleIDs` | `[]` | Extra apps to never focus. **Added to** the built-in list, not replacing it. |

```sh
defaults write io.github.rbstp.heed dwellMs -int 200
defaults write io.github.rbstp.heed excludedBundleIDs -array com.example.Overlay
make restart
```

Excluded by default: this agent, Dock (which also covers Mission Control and Launchpad), WindowServer,
loginwindow, Control Center, Notification Center, SystemUIServer, the screenshot UI, Spotlight,
Raycast and AltTab. The last two draw floating panels the pointer would otherwise chase.

## When it doesn't do what you expect

```sh
make probe
```

Reports exactly what the agent sees under the pointer right now — every guard, the raw Accessibility
element, how the window was resolved, and the final target:

```
cursor:               2517, 382  (top-left origin)
accessibility:        trusted

guards
  mouse buttons:      none
  last keystroke:     49.66s ago (cooldown 500ms)
  secure input:       no
  command held:       no
  overlay on screen:  no

accessibility at cursor
  element role:       AXWindow
  resolved via:       the hit element is itself the window
  top-level role:     AXWindow
  subrole:            AXStandardWindow
  size:               1920x1050
  AXMain settable:    true
  AXFocused settable: false

result
  target:             Zen (pid 1906)
  bundle:             app.zen-browser.zen
  granularity:        window
  already focused:    true
```

`make logs` with `verbose true` shows the running decisions, including which fallback rung each app
responded to and why a window was skipped.

## Permissions, and the rebuild gotcha

There is no code-signing identity on the machine this was built for, so the app is **ad-hoc signed**.
An ad-hoc signature's designated requirement is a bare hash of the binary:

```
$ make requirement
designated => cdhash H"469f06f184bd6d10061d03a099aa144ff37937dc"
```

Every rebuild produces a different hash, which is a different identity as far as TCC is concerned.
**So rebuilding silently invalidates the Accessibility grant** — while the checkbox in System
Settings still appears ticked. If the agent stops working right after a rebuild, that is why:

```sh
make reset-permission     # clears the stale grant so macOS asks again
```

To avoid re-granting on every rebuild, create a self-signed code-signing certificate in your login
keychain (Keychain Access > Certificate Assistant > Create a Certificate, type *Code Signing*) and
sign with `--sign <name>` instead of `--sign -`. That gives an identity-based requirement rather than
a hash-based one. Confirm it actually worked with `make requirement` before and after a rebuild
rather than assuming — the whole point is that the requirement stops mentioning `cdhash`.

## Transient windows

A meeting reminder, an alert or a floating palette should not drag its whole application in front of
what you were doing, just because the pointer crossed it on the way to dismissing it. So only
ordinary windows are eligible: `requireStandardWindow` requires the subrole `AXStandardWindow`.

That is an allowlist rather than a list of things to reject, which is both simpler and safer --
every real window across the apps tested here, Electron ones (Slack, Notion, Docker Desktop)
included, reports `AXStandardWindow`, while transient chrome does not. Refusing these windows costs
nothing, because focusing one is not useful anyway: keyboard focus can only move by making its app
frontmost, which is exactly the disruption you are trying to avoid.

### When a pop-up is indistinguishable from a real window

Some are. Outlook's meeting reminder is a 400x146 panel that reports subrole `AXStandardWindow` and
role description `standard window`, and carries both minimize and zoom buttons -- nothing structural
separates it from a document window. Its one difference, no `AXFullScreenButton`, is useless as a
rule: legitimate fixed-size windows lack one too, Calculator among them. Hovering it on the way to
dismissing it would drag the whole of Outlook in front of your work.

So there is a small built-in list of title rules for windows like this, currently:

| App | Title pattern |
| --- | --- |
| Microsoft Outlook | `^[0-9]+ Reminders?$` |

The pattern is anchored on the exact titles Outlook uses (`1 Reminder`, `3 Reminders`) so that an
email whose subject merely mentions a reminder stays focusable. That distinction is covered by tests
in `Tests/FFMCoreTests/TitleRuleTests.swift`, because the hazard with title rules is not failing to
match -- it is matching too much.

To add your own, `excludedWindowTitles` takes regular expressions and applies them to every app:

```sh
defaults write io.github.rbstp.heed excludedWindowTitles -array '^Picture in Picture$'
make restart
```

`make probe` while the pointer is over the offending window prints its title and subrole, and
`make probe X Y` does the same for a screen point you would rather not hover.

## Windows that arrive under the pointer

Focus follows the pointer, not the other way round. A window that appears -- or is raised -- beneath
a pointer that is sitting still has not been moved onto, so focusing it would let a pop-up, or an app
raising itself, take focus with no input from you at all.

A change of target is therefore only accepted when the pointer has actually travelled recently,
which `entryMotionPx` sets. Movement is accumulated over roughly 200 ms rather than compared
tick-to-tick, because a slow deliberate crossing covers only a pixel or two per tick and would
otherwise be mistaken for a stationary pointer. `Tests/FFMCoreTests/MotionTrackerTests.swift` covers
both ends of that.

One thing this cannot fix: **clicking** a button in a background app's window activates that app.
That is macOS, not Heed. Dismissing an Outlook reminder brings Outlook forward for exactly that
reason, whatever Heed does or does not do.

## Focus and raise

macOS does not separate them. Making an app frontmost brings its window forward, so Hyprland's
focus-without-raise has no equivalent here and `raise` only controls ordering *within* an app. This
is a platform constraint, not a missing feature.

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
4. Apply focus through a ladder, stopping at the first rung that **verifiably** worked:
   `AXRaise` + `AXMain` + `AXFrontmost`; then `AXFocused` where the window accepts it; then
   `NSRunningApplication.activate`.

Step 4 verifies by reading focus back rather than trusting return codes, because writing those
attributes successfully does not mean focus moved: `AXMain` is documented as not implying key focus,
and `AXRaise` can report failure even when it worked. Which rung an app honours differs between
apps and can only be observed, so it is logged.

The agent holds no memory of what it last focused. An earlier design cached it and refused to
re-focus the same window, which broke the moment focus moved by other means — focus a window with the
pointer, switch away with the keyboard, nudge the pointer, and the cache insisted that window was
already focused. Live system state is the only authority.

`Sources/FFMCore` is the dwell logic with no platform dependency, so the timing rules are covered by
`swift test` rather than by moving a mouse around and hoping.

## Limitations

- Focus and raise are inseparable across apps (above).
- Apps with a weak Accessibility tree may ignore `AXMain`. Apps with none — some games, XQuartz, a
  few Java toolkits — fall back to app-level activation; per-window precision is not reachable for
  them without private API.
- Stage Manager manages its own window layering and may fight this.
- Rebuilding invalidates the ad-hoc Accessibility grant (above).

## Prior art

[`sbmpost/AutoRaise`](https://github.com/sbmpost/AutoRaise) solves the same problem in C++ and
carries per-app workarounds worth reading if an app misbehaves here. yabai and AeroSpace have
focus-follows-mouse adjacent features as part of full tiling window managers.

## License

MIT — see [LICENSE](LICENSE).
