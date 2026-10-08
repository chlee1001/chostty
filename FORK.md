# Chostty

A macOS fork of [Ghostty](https://github.com/ghostty-org/ghostty) that replaces
native window tabs with an in-window Workspace → Tab → Pane hierarchy, driven
from a left sidebar. `README.md` is the front door; this file records what
changed and why.

## Licence

Ghostty is MIT licensed, which permits forking, modification and private or
commercial redistribution, with one obligation: the original copyright notice
and permission notice must be retained in all copies. `LICENSE` keeps the
upstream notice verbatim and adds this fork's line beneath it.

There is no copyleft obligation. Releases are published from this repository,
so `LICENSE` ships inside the bundle and in the source tree.

## What differs from upstream

**Window model.** Upstream gives each tab its own `NSWindow` in an
`NSWindowTabGroup`. This fork disallows AppKit tabbing entirely
(`tabbingMode = .disallowed`) and keeps one physical window that owns a
Workspace → Virtual Tab → Pane graph in memory. The AppKit native-tab code is
removed, not merely bypassed; `macos/scripts/native-tab-audit.sh` is an
enforcing gate that fails if any of it returns.

**Product identity on macOS only.** The bundle is `Chostty.app`, the executable
is `chostty`, and the bundle identifier is `kr.co.devch.chostty` (Debug:
`kr.co.devch.chostty.debug`). Releases through 0.2.15 used `com.chostty.app`;
on first launch the renamed app copies that domain's preferences and its saved
session once, keeping the originals, and the Dock tile plugin reads the old
domain until then. macOS privacy grants such as Automation and notifications
are keyed by bundle identifier and must be granted again. Everything a user
or a script already depends on is deliberately unchanged: the `Ghostty` Swift
module, `GhosttyKit`, `GHOSTTY_*` environment variables, `xterm-ghostty`
terminfo, `share/ghostty` resource paths, `~/.config/ghostty/`, every AppleScript
four-char code, and the `ghostty` executable name on Linux/GTK.

**Updater.** Packaged stable releases enable Sparkle and verify this repository's
latest-release appcast and update archive using the Ed25519 public key.
Source builds do not check automatically. Packaged builds check automatically
unless `auto-update` says otherwise, overriding the `SUEnableAutomaticChecks = 0`
preference that releases through 0.2.12 stored. The appcast is a release asset,
so Sparkle can only fetch it while this repository is public. The private key stays outside the
repository and must match the bundled public key before packaging. Releases
through 0.2.12 require one manual upgrade. Losing the private key likewise
requires a new public key and one manual release. Never use upstream Ghostty's
appcast: it would replace Chostty with stock Ghostty.

**Files panel Reader.** Opening a file from the right Files panel adds a
read-only document tab to the selected Virtual Tab without unmounting its
terminal surface. Each Virtual Tab keeps up to 20 open documents independently;
opening an existing path reselects it, `Esc` hides the Reader, and `⌘W` closes
only the selected document while the Reader is active. Markdown, source text,
JSON/YAML/TOML/XML/property lists, images, and static HTML have dedicated
views; other formats use an embedded Quick Look preview. Static HTML runs with
JavaScript and network resources disabled. Open document tabs are intentionally
not restored after an app restart.

**Structure persistence, not window restoration.** Chostty still registers no
`NSWindowRestoration` class and still pins `NSQuitAlwaysKeepsWindows` to false,
so AppKit's window archive plays no part here. Instead the app keeps a single
JSON file of its own —
`~/Library/Application Support/<bundle id>/session.json`, plus a
`session-previous.json` holding the previous validated snapshot — describing
workspaces, virtual tabs and panes: names, colors, order, collapsed state,
tab titles, each tab's split layout, and each pane's working directory. On the
next launch that structure comes back.

After a restart each pane is a **new shell** started in the recorded working
directory. The previous processes, their screens and the scrollback are gone,
and no terminal contents are ever written to disk. A recorded directory that no
longer exists is dropped rather than silently swapped for your home directory,
matching every other tab-creating path in this fork.

Saving is driven by an eight-second timer, never by terminal output: a save
happens only when a generation counter shows something actually changed, and it
is skipped entirely when the encoded bytes match the file already on disk, so an
idle window writes nothing. Quitting normally writes once more, synchronously, so
an ordinary quit loses nothing; a crash or a force quit can lose at most eight
seconds of structural change. The file is written atomically with owner-only
(`0600`) permissions.

The backup is seeded after a successful launch, then refreshed before each
changed save with the existing primary only if it passes the same checks as
loading. Recovery from a damaged primary therefore falls back by one successful
save, not to an arbitrarily old boot state. Invalid primary bytes never replace
the backup. If writing the backup fails, the primary is preserved and the save
fails for retry. Both slots use atomic writes and owner-only permissions;
identical saves leave both untouched.

Only one running Chostty writes the file. A launch that finds the file owned by
another running Chostty (same bundle identifier, still alive) stays passive and
resumes saving as soon as that instance exits; a recorded pid now held by an
unrelated process does not count. The sidebar's **Check Sidebar Sync…** sheet
names the owning instance and offers **Take Over and Save**, which writes the
current window's state; the previous owner reads the new owner before its next
write and goes passive.

Closing every physical window does not replace the last valid snapshot with an
empty one. If the app later quits without opening another window, the next
launch restores that last non-empty layout.

Only the selected tab of the selected workspace starts a shell at launch. The
rest are rebuilt as values and materialize the first time you select them, which
is what keeps restoring twenty tabs from starting twenty terminals at once.

Set `macos-session-persistence = false` to turn all of this off, or export
`GHOSTTY_MAC_DISABLE_SESSION_RESTORE=1` for a single launch. Persistence also
disables itself for test hosts and for launches that carry an explicit open
intent (`ghostty -e …`, `open --args`).

`window-save-state` is inherited from upstream and still parses, but the macOS
app ignores it and always behaves as `never`; `macos-session-persistence` is the
key that controls the behavior described above.

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

## Workspace controls

The sidebar toggle and workspace actions menu sit in the titlebar, immediately
right of the traffic lights. Creating a workspace and checking whether the live
sidebar graph matches the saved session are both available from that menu. They
used to live in the sidebar header, where closing the sidebar took the button
that reopens it away too and left `⌘B` as the only way back.

Windows with no titlebar to host them draw the same controls as a strip
along the top of the window content, next to the window title — fullscreen
(native parks the titlebar in an auto-hiding overlay, non-native removes it) and
`window-decorations = false`. Two windows keep the controls in the sidebar
header instead: the quick terminal, a borderless panel with no titlebar and no
room for a strip, and `macos-titlebar-style = hidden`, where a strip would hand
back the window chrome the setting exists to remove.

`WorkspaceControlsPlacement.forStandaloneWindow` is the whole decision, and
`WorkspaceControlsPlacementTests` covers its matrix.

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

## Releasing

Releases are built locally so the private repository does not spend hosted
macOS minutes rebuilding code that already passed pull-request CI:

```sh
./scripts/release-local.sh --version <semver>
```

The command builds a ReleaseFast universal GhosttyKit, builds Chostty with the
Release configuration, and asks `macos/scripts/package-release.sh` to stamp,
sign and package the app into `dist-local/`. It then verifies the bundle
signature and DMG and writes SHA-256 checksums.
Signing is ad-hoc unless both `CHOSTTY_SIGNING_IDENTITY` and
`CHOSTTY_NOTARY_PROFILE` are exported, in which case the app and DMG are
Developer ID signed, notarized and stapled.

To tag the current `origin/main` commit and upload the DMG and zip to GitHub
Releases in the same command:

```sh
./scripts/release-local.sh --version <semver> --publish
```

The normal post-merge path is shorter:

```sh
./scripts/release-local.sh --publish-next
```

It requires a clean tracked tree, switches to `main`, fast-forwards it to
`origin/main`, increments the patch component of the latest stable GitHub
release, then runs the same verified build and publish path. It refuses to
publish when `origin/main` has no commits or no app/package input changes after
the latest release, so documentation and release-tool-only merges do not create
an empty app version.

Publishing refuses a dirty tracked tree, a commit other than `origin/main`, a
non-increasing version, an ad-hoc identity, or an existing tag/release. The
packaging script also checks the feed URL, public/private Sparkle key pair,
signed appcast, and universal binary.

`.github/workflows/release.yml` remains as a manual, no-publish fallback. It can
build downloadable workflow artifacts, but it never tags or creates a GitHub
release and is not triggered after CI.

Signing defaults to ad-hoc so credential-less builds (CI, local test
packaging) stay reproducible. For a distributed release, export both
`CHOSTTY_SIGNING_IDENTITY` (a "Developer ID Application: …" identity) and
`CHOSTTY_NOTARY_PROFILE` (a stored `xcrun notarytool store-credentials`
profile) before running `release-local.sh`, or write both once into a
gitignored `.release-env` at the repo root, which `release-local.sh`
sources when present. The app is then signed with a
hardened runtime and a secure timestamp, notarized and stapled, the zip is
rebuilt from the stapled app, and the DMG is signed, notarized and stapled
too. `package-release.sh` refuses a Developer ID identity without a notary
profile — Gatekeeper blocks that harder than an ad-hoc build — and the
GitHub release notes drop the `xattr -cr` workaround automatically for a
notarized build. Ad-hoc artifacts are quarantined on download; the release
notes say so rather than letting it look like a corrupt artifact.

`.github/workflows/ci.yml` runs the audit, shellcheck, the build and the test
suite on pull requests. UI tests are skipped there for the same reason
`macos/build.nu` skips them: no CI runner grants accessibility permission.

Two further CI-only concessions, both about the hosted runner rather than the
code. Tests run serially: twenty of the forty-two suites stand up a real
`TerminalController` with windows and a Metal surface, and run concurrently the
test host exits partway through, which xcodebuild reports as every unfinished
test failing. And `reopenAfterForcedFinalizeCreatesFreshTabWithRecordedMetadata`
is skipped by name — the only case that finalizes a lease and then builds a
fresh live surface, which takes the host process down on a runner. It passes
locally and the full suite remains the local gate, so treat a green CI as
necessary rather than sufficient.

## Verification

The suite and `macos/scripts/native-tab-audit.sh` run on every change. Hosting
SwiftUI in this test target hangs the XCTest runner, so a few paths are checked
by hand instead; all of the following were exercised on macOS 26 / Apple
silicon and pass:

- Fullscreen enter and exit, native and non-native, with one tab and with four.
- Twenty tabs render and scroll; `Cmd+Shift+]` brings the last one into view.
- Right-clicking blank sidebar space opens the workspace menu.
- Workspace controls in all three hosts, including a native fullscreen
  transition — `GhosttyWorkspaceControlsUITests` drives the real app, asserting
  hittability and, in fullscreen, that the strip's workspace menu entry creates
  a workspace. The
  first cut of the accessory was laid out but clipped to zero width, which an
  existence-only assertion accepted.

Where hosting is impossible, some assertions pin the shipped source text rather
than observed layout. Those normalize away comments and whitespace first, and
each was checked to fail on the real defect and to survive a cosmetic reformat —
an earlier version was satisfied by a doc comment while the real frame was
hard-coded.

## App icon

Ghostty's icon is not reused. The app icon (`images/Chostty.icon`), the eight
alternate icons, the custom-icon layers that `macos-icon = custom-style`
composites, and the Linux and Windows icon files are all drawn by
`macos/scripts/generate-icons.py`: a window with a workspace sidebar, a split
pane and a `>_` prompt. Edit the script and re-run it rather than editing the
PNGs:

    python3 macos/scripts/generate-icons.py

It needs Pillow. The `macos-icon` values and the Swift asset names
(`CustomIconGhost` and so on) keep their upstream spelling so existing configs
still resolve; only the artwork changed.

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

## Working on this

The build directories hold `Chostty.app` copies carrying the same bundle
identifier as the installed one, and Xcode registers each one with
LaunchServices as the last step of every build (`RegisterWithLaunchServices` →
`lsregister -f -R -trusted`). Once that has happened,
`tell application "Chostty"` and `tell application id "kr.co.devch.chostty"` can
resolve to a copy that is not running and block in `AESendMessage` forever,
which looks exactly like the app hanging — it is not; its main thread is idle.

Unregistering fixes it until the next build re-registers, so do it immediately
before scripting work rather than once:

    lsregister -u "$PWD/macos/build/Release/Chostty.app"

`lsregister` lives in
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support`.
`tell application "/Applications/Chostty.app"` bypasses the ambiguity and is a
quick way to tell the two failures apart.
