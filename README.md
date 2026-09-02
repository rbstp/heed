# Heed

**Focus follows mouse for macOS, inspired by Hyprland's `follow_mouse`.**

[![CI](https://github.com/rbstp/heed/actions/workflows/ci.yml/badge.svg)](https://github.com/rbstp/heed/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/rbstp/heed?logo=github)](https://github.com/rbstp/heed/releases/latest)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![macOS 14+ on Apple Silicon](https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)

Heed moves keyboard focus to the window under the pointer. It runs in the background with no Dock
icon or main window. Use the menu bar icon or the global hotkey to turn it on and off.

Heed requires macOS 14 or later on Apple Silicon. Release builds do not support Intel Macs.

## Install

### Homebrew

```sh
brew install --cask rbstp/tap/heed
```

### From source

```sh
make cert      # run once so Accessibility permission survives rebuilds
make install   # build, sign, install, and start Heed
```

On first launch, grant Heed access in **System Settings > Privacy & Security > Accessibility**.
Heed notices the permission without a restart.

Useful source install commands:

```sh
make restart
make logs
make uninstall
```

## Use

Click the cube in the menu bar to turn focus following on or off. A dim icon means Heed is off or
does not have Accessibility permission. Hover over it to see which one.

Right-click or control-click the icon to open the log, see the installed version, or quit. Quitting
unloads the current login agent. Heed starts again at the next login.

Press **Control+Command+H** to toggle Heed from anywhere. This is often easier than moving the pointer
to the menu bar.

Change or disable the hotkey with:

```sh
defaults write io.github.rbstp.heed hotkey 'cmd+ctrl+alt+f'
defaults write io.github.rbstp.heed hotkey ''
make restart
```

The hotkey needs at least one modifier other than Shift. If another app already owns it, Heed refuses
to register it and writes the reason to the log.

To hide the menu bar icon:

```sh
defaults write io.github.rbstp.heed menuBarIcon -bool false
make restart
```

## Behavior

Heed follows the pointer, but it avoids common focus fights:

- Typing, clicking, dragging, open menus, and Command-Tab temporarily suppress pointer focus.
- Dialogs, About windows, and prompts keep their focus.
- A window that appears under a still pointer does not take focus.
- Focus received from a shortcut, app launch, menu action, or Command-Tab stays put until the pointer
  moves to another window and rests there.
- Moving across the menu bar, Dock, or empty space does not discard that protection.
- Small pointer movement does not count as settling on another window.
- Transient windows such as floating panels are not pointer focus targets.

macOS does not cleanly separate focus from raising across applications. Focusing another app usually
brings it forward. The `raise` setting only controls window ordering within an app.

## Configuration

Settings use the `io.github.rbstp.heed` defaults domain. Restart Heed after changing them.

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Turn focus following on or off. |
| `menuBarIcon` | `true` | Show the menu bar icon. |
| `hotkey` | `cmd+ctrl+h` | Global toggle. Use an empty string to disable it. |
| `dwellMs` | `0` | Time the pointer must rest before focus changes. Try `200` if instant focus is too active. |
| `pollMs` | `40` | Pointer sampling interval while active. |
| `idlePollMs` | `1000` | Safety check interval while idle. Mouse movement wakes the fast loop. |
| `raise` | `true` | Raise the selected window within its app. |
| `typingCooldownMs` | `500` | Ignore pointer focus after a keystroke. |
| `clickGraceMs` | `150` | Ignore pointer focus after a mouse press or release. |
| `entryMotionPx` | `6` | Travel required before a different window may take focus. Use `0` to disable this guard. |
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

Examples:

```sh
defaults write io.github.rbstp.heed dwellMs -int 200
defaults write io.github.rbstp.heed excludedBundleIDs -array com.example.Overlay
defaults write io.github.rbstp.heed excludedWindowTitles -array '^Picture in Picture$'
make restart
```

Heed always excludes itself, Dock, WindowServer, loginwindow, Control Center, Notification Center,
SystemUIServer, the screenshot UI, Spotlight, Raycast, and AltTab.

## Troubleshooting

Check what Heed sees under the pointer:

```sh
make probe
make probe X=960 Y=540
```

The probe reports active guards, Accessibility roles, the resolved window, and whether it already has
focus.

For detailed decisions:

```sh
defaults write io.github.rbstp.heed verbose -bool true
make restart
make logs
```

Turn verbose logging off when finished:

```sh
defaults write io.github.rbstp.heed verbose -bool false
make restart
```

The log is append-only. Clear it with `make logs-clear`.

### Accessibility stopped working after an upgrade

Homebrew releases use ad-hoc signing. Each new binary has a new identity, so macOS requires a new
Accessibility grant after an upgrade. The cask clears the stale grant during installation so macOS
can ask again.

If the old entry remains or Heed stays dimmed, reset it manually and grant access again:

```sh
tccutil reset Accessibility io.github.rbstp.heed
```

Source builds can keep the permission across rebuilds. Run `make cert` once, then use `make install`.
The certificate is limited to code signing and stored in the login keychain. The build refuses to
silently fall back to ad-hoc signing if the certificate is missing.

Check the current signing mode with:

```sh
make requirement
```

A requirement containing `cdhash` is ad-hoc. A requirement naming a certificate is stable across
rebuilds.

## Limitations

- Focusing another application usually raises it.
- Apps with incomplete Accessibility support may only work at application level.
- Some games, XQuartz, and Java applications do not expose individual windows.
- Stage Manager may override window ordering.
- Homebrew upgrades require Accessibility permission again.

## Development

```sh
make test
make check-package
make dist
```

`make test` runs the focus policy tests. `make check-package` verifies the bundle, plist, icon,
signature, and probe command without changing the installed app. `make dist` creates the release
archive and prints its checksum.

CI tests and packages pull requests. Merging a pull request into `master` creates a release unless
the change only touches `.github/` or this README, or the title contains `[skip-release]`. A title
starting with `feat` increments the minor version. Other release titles increment the patch version.

## Prior art

[`sbmpost/AutoRaise`](https://github.com/sbmpost/AutoRaise) provides similar behavior in C++. yabai
and AeroSpace include related features as part of larger window management tools.

## License

MIT. See [LICENSE](LICENSE).
