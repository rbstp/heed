# Heed

**Focus follows mouse for macOS, inspired by Hyprland's `follow_mouse`.**

[![CI](https://github.com/rbstp/heed/actions/workflows/ci.yml/badge.svg)](https://github.com/rbstp/heed/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/rbstp/heed?logo=github)](https://github.com/rbstp/heed/releases/latest)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![macOS 14+ on Apple Silicon](https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)

Heed moves keyboard focus to the window under the pointer. It runs in the background with no Dock
icon or main window; a menu bar icon and a global hotkey turn it on and off.

Requires macOS 14 or later on Apple Silicon.

## Install

```sh
brew install --cask rbstp/tap/heed
```

From source:

```sh
make cert      # once; keeps the Accessibility grant across rebuilds
make install   # build, sign, install, start
```

On first launch, grant Heed access in **System Settings > Privacy & Security > Accessibility**. It
picks the grant up without a restart.

Other targets: `make restart`, `make logs`, `make uninstall`.

## Use

- **Click** the mark in the menu bar to turn focus following on or off. It holds a filled core while
  Heed is on and is empty while it is off. A dim icon means Heed cannot work, because it is off or
  has no Accessibility permission; hover to see which.
- **Right-click** (or control-click) it to change the shortcut modifier, switch the window numbers
  on or off, open the log, see the version, or quit. Quitting unloads the login agent until the next
  login.
- **Control+Command+H** toggles Heed from anywhere.
- **Control+Command+Right / Left** moves keyboard focus to the next or previous visible window,
  screen by screen from left to right, then left to right within each screen. A window focused this
  way keeps focus until the pointer settles on another one. Windows completely covered by others are
  skipped. These work whether or not Heed is switched on.
- **Control+Command+1** to **9** moves keyboard focus to the window with that number, counted in
  the same order: with Zen on the left and a terminal on the right, 1 is Zen and 2 is the terminal. A
  number with no window on it does nothing.
- **Hold the modifier** on its own and each window is numbered on screen, so the digit to press can
  be read rather than counted. They follow whichever modifier the numbered shortcuts are under, and
  appear after a tenth of a second, so a shortcut typed at speed does not flash them. On by default;
  **Show Window Numbers** in the right-click menu turns them off.
- **Directional focus** moves to the nearest window left, right, up, or down of the focused one.
  Off by default, because each shortcut Heed registers is taken away from every other app:

  ```sh
  defaults write io.github.rbstp.heed focusLeftHotkey 'cmd+ctrl+alt+h'
  defaults write io.github.rbstp.heed focusDownHotkey 'cmd+ctrl+alt+j'
  defaults write io.github.rbstp.heed focusUpHotkey 'cmd+ctrl+alt+k'
  defaults write io.github.rbstp.heed focusRightHotkey 'cmd+ctrl+alt+l'
  make restart
  ```

  A window sharing a row or column with the focused one wins over a closer one that does not, and
  the edge of the arrangement is a dead end rather than a wrap. Pair it with a tiling shortcut:
  Raycast's halves and quarters put the windows where these then move between.

## Mouse follows focus

Focus moved by keyboard leaves the pointer over the window you just left, and the next flick of the
mouse drags focus back there. Turn it around and the pointer follows focus into the new window:

```sh
defaults write io.github.rbstp.heed warpPointer -bool true
make restart
```

It moves on Command-Tab, on the focus shortcuts, on a window picked from Raycast's Switch Windows,
and on any other keyboard-driven activation. It does not move for a click, mid-drag, into a window
Heed would not focus by pointer, or when the pointer is already inside the window. `warpX` and
`warpY` place it inside the window as percentages; the default is the centre.

Off by default, and it needs `handoverGuard` on, which it is by default.

Change or disable the shortcuts:

```sh
defaults write io.github.rbstp.heed hotkey 'cmd+ctrl+alt+f'
defaults write io.github.rbstp.heed focusNextHotkey 'cmd+ctrl+alt+right'
defaults write io.github.rbstp.heed hotkey ''
make restart
```

A hotkey needs at least one modifier other than Shift. If another app already registered it, Heed
logs the refusal and registers nothing.

**Shortcut Modifier** in the right-click menu changes the modifier of every shortcut at once
without a restart. The icon flashes green when it takes and red when the combination is taken, in
which case nothing changes and the log says which app holds it.

Heed registers hotkeys exclusively, so a combination it claims is gone from every other app. The
menu offers Command-Option with a warning (it moves between tabs in most browsers and terminals) and
does not offer Command-Shift at all (it selects a line in every text field). `defaults write` accepts
either. Combinations the system reads directly cannot be refused, only warned about.

Hide the menu bar icon:

```sh
defaults write io.github.rbstp.heed menuBarIcon -bool false
make restart
```

## Drive it from somewhere else

Every shortcut Heed registers is taken away from every other app, so it can also be driven without
registering anything. A URL reaches the running agent directly:

```sh
open 'heed://focus/next'
open 'heed://focus/left'
open 'heed://focus/3'
open 'heed://toggle'      # also enable, disable
```

Window numbers past 9 work here even though the shortcuts stop at the digit keys.
`heed://focus/id/<n>` takes the window server's own number instead, the `id` field of `--windows`:
a place in the ring is only true of the ring it came from, and Heed rebuilds that ring every time.

The same vocabulary as flags on the installed binary:

```sh
~/Applications/Heed.app/Contents/MacOS/Heed --focus next
~/Applications/Heed.app/Contents/MacOS/Heed --toggle
~/Applications/Heed.app/Contents/MacOS/Heed --on
```

`--windows` prints the focus ring as JSON, in the order the numbered shortcuts count, so something
else can show the list and pick from it:

```sh
~/Applications/Heed.app/Contents/MacOS/Heed --windows
```

It reads the windows for itself rather than asking the running agent, so it answers whether or not
Heed is running, and it needs the same Accessibility permission. Focus one of them back by its `id`
rather than its `number`, which is only that snapshot's ordering.

### With Raycast

Raycast already tiles and switches windows; Heed adds the pointer. Give Raycast the hotkey and let
Heed claim nothing.

There is a Raycast extension in [`raycast/`](raycast/) with a command for each of these, so the
hotkey is Raycast's and Heed claims nothing. Until it is in the store, run it from a checkout:

```sh
cd raycast && npm install && npm run dev
```

Or without the extension, with a Quicklink:

1. Create a Quicklink to `heed://focus/next` and assign it a hotkey.
2. Free the combination Heed holds: `defaults write io.github.rbstp.heed focusNextHotkey ''`, then
   `make restart`.

Turning `warpPointer` on is what makes Raycast's own Switch Windows move the pointer too, since that
is a keyboard-driven focus change like any other.

The flags reach the running agent over a distributed notification, which any process in your login
session can post and read. Heed holds Accessibility permission, so anything in your session can
switch it off or move focus around while it runs. The vocabulary is fixed at toggle-and-focus: it
takes no arbitrary arguments, carries no window contents, and reads nothing back. If that is not a
trade you want, leave the commands alone and use the hotkeys; nothing else in Heed listens.

## Behavior

Heed follows the pointer but avoids the common focus fights:

- Typing, clicking, dragging, open menus, and Command-Tab suppress pointer focus briefly.
- Dialogs, About windows, and prompts keep their focus.
- A window that appears under a still pointer does not take focus.
- Focus received from a shortcut, app launch, menu action, or Command-Tab stays put until the pointer
  moves to another window and rests there. Crossing the menu bar, Dock, or empty space on the way
  does not release it.
- Small pointer movement does not count as settling on another window.
- Floating panels and other transient windows are not pointer focus targets.
- The focus shortcuts cycle visible windows in spatial order, not stacking order, so stepping through
  them does not reorder the cycle.
- A focus shortcut with nothing to step from, which happens on a cold start driven by a URL, steps
  from the window under the pointer.
- Directional focus never wraps: running out of windows in a direction does nothing.
- With `warpPointer` on, the pointer follows keyboard-driven focus into the new window, and the
  window it lands in holds focus until the pointer leaves it.
- Pointer focus is suppressed while the window numbers are up: the next keystroke is going to pick a
  window, and following the pointer first would move focus somewhere else and renumber the rest.

macOS does not separate focus from raising across applications: focusing another app brings it
forward. The `raise` setting only orders windows within an app.

## Configuration

Settings live in the `io.github.rbstp.heed` defaults domain. Restart Heed after changing them.

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Turn focus following on or off. |
| `menuBarIcon` | `true` | Show the menu bar icon. |
| `hotkey` | `cmd+ctrl+h` | Global toggle. Empty string disables it. |
| `focusNextHotkey` | `cmd+ctrl+right` | Move focus to the next window. Empty to disable. |
| `focusPreviousHotkey` | `cmd+ctrl+left` | Move focus to the previous window. Empty to disable. |
| `focusWindowHotkey` | `cmd+ctrl+1` | Move focus to window 1; the same modifiers with 2 to 9 reach the others. Empty to disable. |
| `focusLeftHotkey` | off | Move focus to the nearest window to the left. |
| `focusRightHotkey` | off | Move focus to the nearest window to the right. |
| `focusUpHotkey` | off | Move focus to the nearest window above. |
| `focusDownHotkey` | off | Move focus to the nearest window below. |
| `windowNumbers` | `true` | Number the windows on screen while the numbered shortcuts' modifier is held. |
| `windowNumbersDelayMs` | `100` | How long that modifier must be held first. |
| `warpPointer` | `false` | Move the pointer into a window that took keyboard focus. |
| `warpX` | `50` | Where in that window the pointer lands, as a percentage across. |
| `warpY` | `50` | Where in that window the pointer lands, as a percentage down. |
| `dwellMs` | `0` | Time the pointer must rest before focus changes. Try `200` if instant is too eager. |
| `pollMs` | `40` | Pointer sampling interval while active. |
| `idlePollMs` | `1000` | Heartbeat while idle. Mouse movement wakes the fast loop. |
| `raise` | `true` | Raise the selected window within its app. |
| `typingCooldownMs` | `500` | Ignore pointer focus after a keystroke. |
| `clickGraceMs` | `150` | Ignore pointer focus after a mouse press or release. |
| `entryMotionPx` | `6` | Travel required before a different window may take focus. `0` disables the guard. |
| `verifyTimeoutMs` | `100` | Time allowed to confirm a focus change before retrying. |
| `ignoreWhenCommandHeld` | `true` | Suppress pointer focus while Command is held. |
| `menuGuard` | `true` | Suppress pointer focus while menus, popovers, or drag images are visible. |
| `handoverGuard` | `true` | Keep focus that arrived without pointer movement. |
| `handoverSettleMs` | `300` | Rest time on another window before releasing held focus. |
| `requireStandardWindow` | `true` | Only focus ordinary `AXStandardWindow` windows. |
| `promptGuard` | `true` | Keep focus on a prompt until it is answered. |
| `excludedWindowTitles` | `[]` | Case-insensitive regular expressions for window titles to skip. |
| `excludedBundleIDs` | `[]` | Extra application bundle IDs to skip. |
| `verbose` | `false` | Log each focus decision. |

```sh
defaults write io.github.rbstp.heed dwellMs -int 200
defaults write io.github.rbstp.heed excludedBundleIDs -array com.example.Overlay
defaults write io.github.rbstp.heed excludedWindowTitles -array '^Picture in Picture$'
make restart
```

Heed always excludes itself, Dock, WindowServer, loginwindow, Control Center, Notification Center,
SystemUIServer, the screenshot UI, Spotlight, Raycast, and AltTab.

## Troubleshooting

See what Heed sees under the pointer, or at a point:

```sh
make probe
make probe X=960 Y=540
```

For per-decision logging:

```sh
defaults write io.github.rbstp.heed verbose -bool true
make restart
make logs
```

The log is append-only; `make logs-clear` truncates it.

### Accessibility stopped working after an upgrade

Homebrew releases are ad-hoc signed, so every new binary is a new identity and needs a new
Accessibility grant. The cask clears the stale grant during installation. If Heed stays dimmed:

```sh
tccutil reset Accessibility io.github.rbstp.heed
```

Source builds keep the permission across rebuilds once `make cert` has created the local signing
identity; `make requirement` shows which signing mode the installed app uses.

## Limitations

- Focusing another application raises it.
- Apps with incomplete Accessibility support may only work at application level. Some games,
  XQuartz, and Java applications expose no individual windows: the pointer focuses them at
  application level, and the focus shortcuts skip them.
- Stage Manager may override window ordering.
- Homebrew upgrades require the Accessibility permission again.

## Development

```sh
make test
make check-package
make dist
```

CI tests and packages pull requests. Merging into `master` creates a release unless the change only
touches `.github/`, `raycast/` or this README, or the title contains `[skip-release]`. A title
starting with `feat` bumps the minor version; anything else bumps the patch.

## Prior art

[`sbmpost/AutoRaise`](https://github.com/sbmpost/AutoRaise) does the same in C++. yabai and
AeroSpace include related features in larger window managers.

## License

MIT. See [LICENSE](LICENSE).
