# Chostty

A private fork of [Ghostty](https://github.com/ghostty-org/ghostty) that replaces
macOS native window tabs with an in-window Workspace → Tab → Pane hierarchy,
driven from a left sidebar.

## Licence

Ghostty is MIT licensed, which permits forking, modification and private or
commercial redistribution, with one obligation: the original copyright notice
and permission notice must be retained in all copies. `LICENSE` keeps the
upstream notice verbatim and adds this fork's line beneath it.

Nothing here needs to be published, and there is no copyleft obligation. If this
fork is ever distributed, ship `LICENSE` with it.

## What differs from upstream

**Window model.** Upstream gives each tab its own `NSWindow` in an
`NSWindowTabGroup`. This fork disallows AppKit tabbing entirely
(`tabbingMode = .disallowed`) and keeps one physical window that owns a
Workspace → Virtual Tab → Pane graph in memory. The AppKit native-tab code is
removed, not merely bypassed; `macos/scripts/native-tab-audit.sh` is an
enforcing gate that fails if any of it returns.

**Product identity on macOS only.** The bundle is `Chostty.app`, the executable
is `chostty`, and the bundle identifier is `com.chostty.app`. Everything a user
or a script already depends on is deliberately unchanged: the `Ghostty` Swift
module, `GhosttyKit`, `GHOSTTY_*` environment variables, `xterm-ghostty`
terminfo, `share/ghostty` resource paths, `~/.config/ghostty/`, every AppleScript
four-char code, and the `ghostty` executable name on Linux/GTK.

**Updater disabled.** Sparkle is off, `SUPublicEDKey` is absent from the built
bundle, and the appcast workflows are deleted. An enabled updater pointed at
upstream's feed would replace this fork with stock Ghostty. Do not re-enable it
without this fork's own feed and signing key.

## Reserved shortcuts

| Chord | Action |
|---|---|
| `⌘N` | New workspace (same window) |
| `⌘T` | New virtual tab |
| `⌘⇧N` | New physical window |
| `⌘1`–`⌘8` | Go to workspace by index |
| `⌘9` | Go to last workspace |
| `⌘⇧[` / `⌘⇧]` | Previous / next tab |
| `Ctrl+Tab` / `Ctrl+⇧+Tab` | Previous / next workspace |
| `⌘⇧T` | Reopen closed tab (undo stays on `⌘Z`) |
| `⌘B` | Toggle sidebar |

These are matched on hardware key codes, not characters, so they behave
identically under non-Latin input sources. `⌘⌥` arrows and bare `⌘[` / `⌘]` are
deliberately NOT claimed — they are live `goto_split` bindings upstream.

## Building

```sh
zig build -Doptimize=ReleaseFast -Demit-macos-app=false   # refresh GhosttyKit
./macos/build.nu --configuration Release --action build
```

Tests and the native-tab gate:

```sh
./macos/build.nu --configuration Debug --action build
xattr -cr macos/build/Debug/Chostty.app
./macos/build.nu --configuration Debug --action test
./macos/scripts/native-tab-audit.sh
```

`xattr -cr` before the test step is required: launching the app re-adds extended
attributes that fail the test host's codesign step.

## Known gaps

- Fullscreen enter/exit, tab-strip scrolling with many tabs, the sidebar
  empty-area context menu hit area, and AppleScript end-to-end behaviour are
  verified manually. Hosting SwiftUI in this test target hangs the XCTest
  runner, so those paths have no automated coverage.
- `new tab` without an explicit `in window …` target is unreliable under
  osascript automation; `new tab in window 1` works.
- An AppleScript `window id` is stable for the window's lifetime but changes
  across relaunch — the persisted `physicalID` is written but never read back.
- Collapse All, Expand All and the single-workspace policy toggle are reachable
  from menus, not the command palette; the palette is driven by Ghostty config
  and has no app-local command source.
- The app icon is still Ghostty's.
