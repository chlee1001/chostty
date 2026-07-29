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

## Verification

The suite and `macos/scripts/native-tab-audit.sh` run on every change. Hosting
SwiftUI in this test target hangs the XCTest runner, so a few paths are checked
by hand instead; all of the following were exercised on macOS 26 / Apple
silicon and pass:

- Fullscreen enter and exit, native and non-native, with one tab and with four.
- Twenty tabs render and scroll; `Cmd+Shift+]` brings the last one into view.
- Right-clicking blank sidebar space opens the workspace menu.

Where hosting is impossible, some assertions pin the shipped source text rather
than observed layout. Those normalize away comments and whitespace first, and
each was checked to fail on the real defect and to survive a cosmetic reformat —
an earlier version was satisfied by a doc comment while the real frame was
hard-coded.

## Known gaps

- `new tab` is only dispatched when the `in` parameter is present. `new tab in
  window 1` and `new tab in front window` work; `new tab` alone fails with
  errAEEventNotHandled (-1708), and so does `new tab with configuration …`
  without an `in`. It is not automation flakiness — the raw `«event GhstNTab»`
  fails the same way with the app frontmost, and upstream Ghostty fails
  identically, so this is inherited rather than introduced. `new window` takes
  no `in` and works with no parameters at all. Left alone because the fix is a
  dictionary change and the dictionary is deliberately frozen; pass `in front
  window`.
- Collapse All, Expand All and the single-workspace policy toggle are reachable
  from menus, not the command palette; the palette is driven by Ghostty config
  and has no app-local command source.
- Source-pinned assertions catch a modifier being removed or moved, but not one
  being added alongside.
- The app icon is still Ghostty's.

## Working on this

The build directories hold `Chostty.app` copies carrying the same bundle
identifier as the installed one. Once LaunchServices has seen them,
`tell application "Chostty"` and `tell application id "com.chostty.app"` can
resolve to a copy that is not running and block in `AESendMessage` forever,
which looks exactly like the app hanging — it is not; its main thread is idle.
Unregister them before any scripting work:

    lsregister -u "$PWD/macos/build/Release/Chostty.app"

`lsregister` lives in
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support`.
`tell application "/Applications/Chostty.app"` bypasses the ambiguity and is a
quick way to tell the two failures apart.
