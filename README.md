# Chostty

A macOS fork of [Ghostty](https://github.com/ghostty-org/ghostty) that replaces
native window tabs with an in-window **Workspace → Tab → Pane** hierarchy,
driven from a left sidebar.

Upstream gives every tab its own `NSWindow` inside an `NSWindowTabGroup`. That
is the right default for a terminal, but it makes a set of related shells a
property of the window manager rather than of the app: there is no grouping
above a tab, the group is invisible when the window is not frontmost, and
anything that wants to reason about "the session I was working in" has to go
through AppKit.

Chostty keeps one physical window and owns the hierarchy itself. Workspaces
group tabs, tabs own a split tree of panes, and the sidebar shows all of it at
once. AppKit tabbing is not hidden or worked around — it is removed, and
`macos/scripts/native-tab-audit.sh` fails the build if any of it comes back.

Everything below the window model is stock Ghostty: the same renderer, the same
config file, the same terminfo, the same shell integration.

## Install

Download the DMG from [Releases](../../releases), drag Chostty to Applications,
then run:

```sh
xattr -cr /Applications/Chostty.app
```

**That step is required.** This fork has no Apple Developer ID, so the app is
ad-hoc signed and cannot be notarized. macOS quarantines the download and
reports it as damaged until the attribute is cleared — which looks exactly like
a corrupt build, so do not skip it and conclude the release is broken.

There is no auto-updater. Sparkle is compiled out on purpose: pointing it at
upstream's appcast would quietly replace this fork with stock Ghostty. New
versions come from the releases page.

Universal binary, macOS 13 and later.

## Using it

`⌘B` toggles the sidebar, or use the buttons next to the traffic lights — the
toggle, `+` for a new workspace, and the workspace actions menu. `⌘N` makes a
workspace, `⌘T` a tab inside the current one, `⌘⇧N` a separate physical window.
Right-click a workspace, a tab, or empty sidebar space for the rest. The full
chord table is in [FORK.md](FORK.md).

Configuration is unchanged from Ghostty — `~/.config/ghostty/config`, the same
keybind and theme syntax, `TERM=xterm-ghostty`. An existing Ghostty setup works
as-is, and the two can be installed side by side.

Shortcuts this fork reserves are taken only from chords upstream left unbound or
already broken; live Ghostty bindings such as `⌘⌥←/→` and `⌘0` are untouched.

## Building

Needs Xcode 26 (macOS 26 SDK) and Zig 0.16. Nix is not required.

```sh
zig build -Demit-macos-app=false     # GhosttyKit, the Zig core the app links
./macos/build.nu --configuration Release --action build
```

Verify with the test suite and the audit gate:

```sh
./macos/build.nu --configuration Debug --action test
./macos/scripts/native-tab-audit.sh
```

If a build fails with no `error:` line, it is usually a stale signature — remove
`macos/build/<Configuration>` and rebuild. Running the app re-adds quarantine
attributes to the build output, so re-run `xattr -cr` on the bundle before
testing.

The Linux and GTK trees are inherited from upstream and carried unmodified.
They are not built or tested here.

## Tracking upstream

This is a fork, not a snapshot. `scripts/upstream-sync.sh` reports what upstream
changed since the last merge, sorted by how likely it is to hurt:

```sh
./scripts/upstream-sync.sh
```

It groups changes into files this fork also modified (real conflicts), files it
deleted (delete/modify stops), macOS code it has not touched (merges cleanly but
lands in the restructured app), and the Zig core (usually uneventful). It does
not merge. The fork's actual risk is a merge git resolves without complaint that
restores a window-level assumption removed on purpose, and only reading the list
catches that. A scheduled workflow posts the same report to a tracking issue.

The sync point is the git merge base with `upstream/main`, so there is no
recorded revision to fall out of date.

## Licence

Ghostty is MIT licensed. `LICENSE` keeps the upstream copyright notice verbatim
and adds this fork's line beneath it; ship it with any copy. See
[FORK.md](FORK.md) for what changed, what is deliberately kept compatible, and
the known gaps.
