# Chostty

English | [한국어](FORK.ko.md)

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
domain until then. A session already saved under the new identifier always
wins, and a failed copy is retried on the next launch rather than recorded as
done. macOS privacy grants such as Automation and notifications
are keyed by bundle identifier and must be granted again. Everything a user
or a script already depends on is deliberately unchanged: the `Ghostty` Swift
module, `GhosttyKit`, `GHOSTTY_*` environment variables, `xterm-ghostty`
terminfo, `share/ghostty` resource paths, `~/.config/ghostty/`, every AppleScript
four-char code, and the `ghostty` executable name on Linux/GTK.
The SSH-host manager does not alter this frozen compatibility list or
Ghostty's canonical configuration paths.

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

**No crash reporter.** GhosttyKit is built with `-Dsentry=false`, so the app
links no Sentry or Breakpad code and writes no crash reports of its own;
`+crash-report` only lists reports left by upstream Ghostty or earlier Chostty
builds, which share its directory. Upstream's default is on for macOS, so every
`zig build` here must pass the flag. Without it a Debug build also prints
`[sentry]` lines into every SSH pane, because each pane runs the app executable
as `+ssh`.

**Files panel Reader.** Opening a file from the right Files panel adds a
read-only document tab to the selected Virtual Tab without unmounting its
terminal surface. Each Virtual Tab keeps up to 20 open documents independently;
opening an existing path reselects it, `Esc` hides the Reader, and `⌘W` closes
only the selected document while the Reader is active. Markdown, source text,
JSON/YAML/TOML/XML/property lists, images, and static HTML have dedicated
views; other formats use an embedded Quick Look preview. Static HTML runs with
JavaScript and network resources disabled. Open document tabs are intentionally
not restored after an app restart.

**Configuration editor.** `⌘,` (Preferences…) and the `open_config` action now
open a GUI editor instead of handing the config file straight to an external
editor. It covers the common keys (fonts, colors, cursor, window behavior, and
repeatable keys like `keybind` and `font-feature`) with inline help, and
rewrites only the lines it changes: comments, ordering, unknown keys and
repeated keys survive a save byte for byte. **Save & Apply** writes the file
atomically and reloads the app configuration; **Edit in External Editor** keeps
the raw-file workflow one click away, and per-row **Reset** removes a key so its
default applies again. Setting a control writes the value explicitly — a value
equal to the default is not auto-removed; Reset (or clearing a text field) is
the removal path. Every edit is checked with libghostty's own parser, so problems
show on their row before saving. Saving writes through a symlinked config to its
target, and refuses to silently overwrite a file edited elsewhere since it was
loaded. Save & Apply is `⌘S`, not Return. The `open_config` keybinding keeps
working and now routes to the editor.

The `theme` row opens a gallery of the bundled themes and any in
`~/.config/ghostty/themes` (user themes shadow bundled ones of the same name),
with a preview per theme, search, a dark/light filter, and a separate pick per
appearance written as `light:…,dark:…`. Rows a theme or a `config-file` include
sets show the value that actually applies and where it comes from, following
Ghostty's precedence (include > this file > theme > default); a key this file
sets but an include overrides is flagged. **All Settings** lists every key the
running binary reports through `+show-config --default --docs`, with the full
upstream doc behind **More…**, so keys outside the curated pages are editable
too; settings for other platforms are hidden there unless the file sets them.

**Structure persistence, not window restoration.** Chostty still registers no
`NSWindowRestoration` class and still pins `NSQuitAlwaysKeepsWindows` to false,
so AppKit's window archive plays no part here. Instead the app keeps a single
JSON file of its own —
`~/Library/Application Support/<bundle id>/session.json`, plus a
`session-previous.json` holding the previous validated snapshot — describing
workspaces, virtual tabs and panes: names, colors, order, collapsed state,
tab titles, each tab's split layout, and each pane's working directory. On the
next launch that structure comes back.

After a restart each local pane is a **new shell** started in the recorded working
directory. The previous processes, their screens and the scrollback are gone,
and no terminal contents are ever written to disk. A recorded directory that no
longer exists is dropped rather than silently swapped for your home directory,
matching every other tab-creating path in this fork.

Structural changes — tabs, workspaces, names, colors, windows, and splits — are
saved about one second later. Titles and directories reported by the shell are
saved at most every eight seconds. A save runs only after something changed and
is skipped when its bytes match the file on disk, so an idle window writes
nothing. Quitting
normally saves once more before closing windows; a crash or force quit can lose
up to that interval. The file is written atomically with owner-only (`0600`)
permissions.

Saved sessions support up to 32 physical windows. If a save is refused or keeps
failing, the workspace-actions button shows an orange warning badge and its
menu gains **Check Sidebar Sync…**, which explains the cause and how to resolve
it. The item is hidden while saving works.

The backup is seeded after a successful launch, then refreshed before each
changed save with the existing primary only if it passes the same checks as
loading. Recovery from a damaged primary therefore falls back by one successful
save, not to an arbitrarily old boot state. Invalid primary bytes never replace
the backup. If writing the backup fails, the primary is preserved and the save
fails for retry. Both slots use atomic writes and owner-only permissions;
identical saves leave both untouched.

The Chostty instance you are using — the active one — saves the file;
activating another running instance hands saving to it. An instance that has
yielded to another one only removes the windows it closed, and stays that way
until you activate it, even after the other instance exits. A recorded pid now
held by an unrelated process does not count as a running Chostty instance.

Closing every physical window does not replace the last valid snapshot with an
empty one. If the app later quits without opening another window, the next
launch restores that last non-empty layout.

Only the selected tab of the selected workspace starts a shell at launch. The
other tabs in that workspace then open one at a time, paced by their pane count;
tabs in other workspaces start no shell until you open that workspace. This keeps
restoring twenty tabs from starting twenty terminals at once. If Chostty quit
while opening a tab, that tab is held back: it shows an indicator and opens only
when you select it. A tab that fails to open shows a warning and retries when you
select it.

If Chostty cannot record restore attempts, the warning badge and **Check Sidebar
Sync…** report that restore protection is unavailable. Saved windows and tabs
then open only when you select them.

File- and URL-first launches, launches that carry an explicit open intent
(`ghostty -e …`, `open --args`), and `initial-window = false` keep saved
windows unopened in the session file. Open the saved windows with **Reopen
Saved Windows** in the sidebar's workspace actions, or by clicking the Dock
when no window is open. An explicit-open launch still saves the windows it
opens next to the unopened ones; the `-e` command itself is not saved. Closing
a window removes it from the file even when only unopened saved windows remain.
Windows and tabs whose restore crashed stay held back until opened explicitly.
A new instance does not restore saved windows while another instance is
running.

Set `macos-session-persistence = false` to turn persistence off, or export
`GHOSTTY_MAC_DISABLE_SESSION_RESTORE=1` for a single launch. Persistence also
disables itself for test hosts.

`window-save-state` is inherited from upstream and still parses, but the macOS
app ignores it and always behaves as `never`; `macos-session-persistence` is the
key that controls the behavior described above.

## SSH connections

Hosts declared in `~/.ssh/config` are available from `⌘⇧P` as a new tab or a
right-hand split. SSH tabs show their destination and connection status in the
sidebar. `ssh-env` is on by default; use `no-ssh-env` to turn it off. When
Chostty cannot determine the configuration source, it follows that
configuration instead of forcing `ssh-env` on. Quick Terminal has no SSH entry
point.

SSH panes retain only their host binding in the optional `ssh` snapshot field.
After a restart or Reopen Closed Tab they wait for **Connect** without contacting
the server; Duplicate Tab starts a new connection. A lost connection stays in
the pane until you reconnect or close it. Removing a host prevents reconnecting
but does not interrupt an existing connection.

SSH diagnostics go to the unified log under the `ssh`, `ssh-askpass`, and
`ssh-tunnel` categories:

```sh
log stream --level debug --predicate 'subsystem BEGINSWITH "kr.co.devch.chostty" AND category BEGINSWITH "ssh"'
```

Events record classifications, counts, and timings, such as `connect.requested`,
`state.changed`, `resolver.ran`, `askpass.request`, and `tunnel.phase`. Aliases
and paths are private; passwords, prompts, answers, tokens, and argv are never
logged.

### SSH-host manager

Chostty places its own hosts in
`<XDG config home>/chostty/ssh/hosts.conf`, with `hosts.meta.json` beside it
for optional display names and favorites. An unset or empty `XDG_CONFIG_HOME`
means `~/.config`. Finder-launched apps inherit launchd's environment, not shell
profiles. The host file is owner-only (`0600`); newly created `chostty` and
`ssh` directories are `0700`.

The manager applies only to normal terminal windows, through **Window > Manage
SSH Hosts…**, **SSH: Manage Hosts…** in the command palette, or the SSH popover
footer. Managed hosts alone launch with `ssh -F hosts.conf`. `~/.ssh/config`,
its Includes, and system configuration remain read-only. Blocks carrying the
Chostty ownership marker are editable; unmarked blocks are read-only.

Opening or searching never runs `ssh -G`. **Resolve** and **Duplicate to Edit**
require explicit consent before running it when `Match exec` is present.
Duplicate to Edit requires a new unique alias, copies only supported
General/Advanced differences from OpenSSH defaults, lists unsupported settings
as **Not copied**, and never copies credentials. A changed on-disk hash presents
**Reload** or **Overwrite**.

**IdentityFile** rows take a typed path or **Choose…**, which writes a file
under the home folder as `~/…` and escapes `%`; paths with spaces and `.pub`
files are refused because the managed file does not quote values. **ProxyJump**
offers **None**, any other host in the catalog, or **Custom** with Jump User,
HostName, and Port fields (a multi-hop value is edited as text). A jump host
that needs its own key or options should be added as a host and chosen from the
list; a jump host's password is typed in the terminal, because the Keychain
answers only the destination host's prompt. **Check Jump Host** checks a single
hop: it runs `ssh -G`, then `ssh -T … true` with `BatchMode=yes`,
`StrictHostKeyChecking=yes`, `ControlPath=none`, agent, X11, and port
forwarding off, and, once it exists, the managed file. Like panes and tunnels,
it uses the login shell's `PATH` and `SSH_AUTH_SOCK`. The check never prompts,
records no host key, reuses no multiplexed session, and sends no password. It
reports signed in, key authentication refused, unknown or changed host key,
unreachable, failed, or unresolved. With `Match exec` present it asks for the
same consent as **Resolve**.

### Password management and automatic delivery

Managed hosts can select **Password in Keychain**. It requires explicit User,
HostName, and Port, and is unavailable when a matching `Host`, any
preceding `Match`, a global endpoint option, or an early `Include` can affect
the host; nonmatching `Host` blocks do not disqualify it. Eligibility examines
the exact saved bytes. External configuration remains read-only. The metadata
records only the authentication choice; the password is stored under the host
UUID in the file-based login Keychain service `<bundle id>.ssh.password`, never in
`hosts.conf`, `hosts.meta.json`, snapshots, arguments, environment, or logs.
Tunnels are described below.

Changing only an alias keeps the existing Keychain item. Changing User,
HostName, or Port requires **Use for <destination>** or **Replace Password…**;
the manager never silently reuses a password for a different endpoint. It never
stores key passphrases. For Apple OpenSSH, use `UseKeychain yes` and
`AddKeysToAgent yes` for key handling.

Automatic password delivery starts before `ghostty_init`. A services-wide
listener starts before metadata hydration, and the pane coordinator issues and
reserves a per-pane nonce for the first connection and for each reconnect;
launch arguments never carry one. Grants expire 120 monotonic seconds after
issuance. Kernel socket-peer and exact three-parent-hop pin checks gate
credential requests, not nonce issuance. Delivery is explicit Keychain opt-in
and is limited to system `/usr/bin/ssh`; other `PATH` clients keep manual
authentication.

The C helper uses a direct byte reader rather than libc `readpassphrase`, which
cannot distinguish a nonempty EOF or NUL reliably. Separately, Darwin canonical
mode measurably loses the terminator at the 1024-byte boundary. The reader
temporarily enables `ISIG`, then restores the complete saved TTY state with
`TCSAFLUSH`. The supervisor treats a connection as connected only after both
`-icanon` and `-isig`, keeping helper authentication in its connecting state.
On ordinary failure it stops the verified SSH consumer before EOF. `confirm`
and `none` modes never terminate the consumer; a no-TTY confirmation or
unverifiable ordinary parent holds stdout until exit. A blank key-passphrase
request cancels rather than skipping the key.

An abrupt helper death, external `SIGKILL`, crash before supervisor pinning, or
Darwin PID check-to-kill race can still leave OpenSSH to make a blank attempt;
the design makes no absolute blank-prevention claim. On success the helper
explicitly wipes owned buffers, retains fatal handlers through exit, then calls
native `_exit(0)`. If the helper crashes after pinning, its fatal-signal handler
kills the consuming parent before it reads EOF.

The broker retries transient accept errors and reports fatal unavailability.
Services recheck availability for each connection, then revalidate the final
file and attributes before the kernel rewalk.

One-time checks outside this repository ran the helper standalone and bundled
in a genuine non-orphaned foreground process group: Ctrl-Z and delayed suspend
were rejected and the TTY was restored exactly. A live broker check drove
system `ssh`, the bundled helper and the app-plus-SSH PTY supervisor through
three parent hops; it served one fetch from a fake store and denied an
unrelated same-UID peer holding a valid nonce. Because the store was fake, that
check does not prove real Keychain access or password bytes. SSH-origin `none`
and hardware FIDO keys remain unverified; see Known gaps.

During development, an ad-hoc code identity can prompt for Keychain
authorization again after builds or updates. **Always Allow** trusts that code
identity for later access, not necessarily for every update. A Developer ID
signed release is the intended distribution expectation; no signing keys or
credentials are in this repository.

### SSH tunnels

The SSH manager's **TUNNELS** section saves `-L`, `-R`, and `-D` forwards for a
catalog host in `hosts.meta.json`. A tunnel can be edited or deleted only while
stopped, and a failed start keeps its settings. A bind address other than
`127.0.0.1`, `::1`, or `localhost` needs **Allow** in a consent alert;
**Cancel** saves and starts nothing, and changing the address, port, or type
asks again. For `-R`, the server decides the remote bind: unless its
`GatewayPorts` is `clientspecified` or `yes`, sshd listens on loopback only. `LocalForward`, `RemoteForward`, and
`DynamicForward` lines in the host's SSH configuration still apply to the
tunnel's ssh and are not covered by this consent.

Tunnels start and stop from the manager, the SSH popover, or **SSH: Start
Tunnel <name>** and **SSH: Stop Tunnel <name>** in the command palette. They
run `/usr/bin/ssh -N` with `ExitOnForwardFailure=yes`,
`ForkAfterAuthentication=no`, and `PermitLocalCommand=no`, without connection
sharing, with the login-shell `PATH` for ssh's own helpers; only managed hosts
add `-F hosts.conf`. Authentication prompts and host-key trust are described
under "Tunnel authentication and host-key trust" below. `-L` and `-D` turn **ready** once ssh listens
on the bind port. `-R` has no readiness signal and shows **running,
unconfirmed**. Failures distinguish interactive authentication, unknown and
changed host keys, a local port in use, a refused server forward, and other
exits. A target that refuses one forwarded connection leaves the tunnel ready
and shows the last channel error. The SSH button badge counts running tunnels.

ssh's stderr stays in a 64 KiB memory buffer and logs record only the
classification. Quitting stops every tunnel without confirmation (SIGTERM, two
seconds, SIGKILL); nothing restarts on the next launch. Each ssh runs under
`chostty-ssh-tunnel-watchdog.sh`, which stops it when the app's stdin lifeline
closes or when the app stops being its parent. The parent check exists because
a terminal pane forked while a tunnel pipe is being opened can inherit the
lifeline: Darwin creates the pipe and sets `FD_CLOEXEC` in separate calls, and
libghostty does not sweep descriptors before `exec`. A per-tunnel record under
the runtime root lets the next launch reap an ssh that outlived a crash, after
checking its uid, start time, and executable. Deleting a managed host stops its
running tunnels first and removes their definitions; if a tunnel cannot be
stopped, the host is kept.

### Tunnel authentication and host-key trust

A tunnel has no terminal, so its ssh asks the app instead. Each tunnel gets
`SSH_ASKPASS` pointing at the Chostty executable, `SSH_ASKPASS_REQUIRE=force`,
and a 32-byte random token that lives only in the environment, never in
arguments, and is revoked when the tunnel ends. The broker answers a tunnel
request only when the asking process is the Chostty executable, its parent is
`/usr/bin/ssh`, that ssh's parent is the watchdog the app launched for this
tunnel, and the watchdog's parent is the app; pid, parent, uids, and start time
are compared, and the chain is checked again before each answer. A request that
fails the check ends the tunnel with **SSH asked for input Chostty couldn't
verify.** For that reason `ProxyJump` hops that prompt are not supported:
their ssh is not the tunnel's own child. Whenever the app gives no answer, the
helper ends its ssh instead of writing an empty one.

With the broker running, a tunnel drops `BatchMode` and uses
`StrictHostKeyChecking=ask`. While a prompt is open the tunnel shows **waiting
for authentication**.

- An unknown host key opens **Trust the host key for <alias>?** with the
  destination resolved for the alias, the fingerprint ssh showed, and ssh's
  question as written. The alert is critical when ssh asks about a different
  host or port or shows no fingerprint, and Return selects **Cancel**. **Trust
  and Connect** answers `yes`, and ssh itself appends the key to the tunnel's
  `UserKnownHostsFile`. **Cancel** answers `no` and the tunnel fails with
  **The host key was not trusted.**
- A question in which ssh reports a conflict with a key it already knows
  (another key type known for the host, a different key for the IP address, a
  DNS mismatch, or any ssh warning) gets `no` without a sheet, and the tunnel
  fails with **SSH reported a conflict with a known host key. Check it in a
  terminal tab.** A changed key is refused by ssh itself: `known_hosts` is left
  as it was and the tunnel fails with the changed-key message.
- Other questions, such as a key passphrase or a one-time code, open **SSH
  needs input for <name>**. The answer is relayed once and not saved; **Cancel**
  fails the tunnel with **Authentication was cancelled.** An unanswered prompt
  closes after 110 seconds with **Authentication timed out.**
- `SSH_ASKPASS_PROMPT=confirm` opens **Allow**/**Cancel**; `none` shows a
  notice that closes when the tunnel turns ready or fails. ssh ends a notice
  helper itself once the key is done.
- For a **Password in Keychain** host, ssh's exact `<user>@<host>'s password:`
  prompt is answered from the Keychain after the host's eligibility is checked
  again, once per ssh process. A second request fails with **Saved password
  was rejected.** A locked, denied, or missing item fails with its own message,
  and a saved password with a line break or NUL fails with **Saved password
  contains characters SSH can't receive.** The password is never shown in a
  sheet.

Prompts open as a sheet on the key or main window, never on the SSH popover,
and as an app-modal alert when no window is open. Stopping a tunnel closes its
prompt. When the broker is unavailable, a Keychain host's tunnels fail with
**Saved password broker is unavailable.** and other tunnels fall back to
`BatchMode=yes` and `StrictHostKeyChecking=yes`, where an unknown key fails
with **Connect once in a terminal tab to trust this host.** The watchdog unsets
the askpass variables in its own shell after starting ssh so they do not reach
its other subprocesses. They remain in ssh's environment, and ssh passes them to
its own children such as `ProxyCommand`, `KnownHostsCommand`, and `Match exec`
commands. Those commands run with the same trust as in a terminal: one that
runs the Chostty executable directly under ssh passes the process check.

## Reserved shortcuts

| Chord | Action |
|---|---|
| `⌘N` | New workspace (same window) |
| `⌘T` | New virtual tab |
| `⌘⇧N` | New physical window |
| `⌘1`–`⌘8` | Go to workspace by index |
| `⌘9` | Go to last workspace |
| `⌘⇧[` / `⌘⇧]` | Previous / next tab |
| `Ctrl+Tab` / `Ctrl+⇧+Tab` | Next / previous workspace |
| `⌘⇧T` | Reopen closed tab (undo stays on `⌘Z`) |
| `⌘B` | Toggle sidebar |

These are matched on hardware key codes, not characters, so they behave
identically under non-Latin input sources. `⌘⌥` arrows and bare `⌘[` / `⌘]` are
deliberately NOT claimed — they are live `goto_split` bindings upstream.

The Edit menu always carries the standard `⌘Z`, `⌘⇧Z`, `⌘X`, `⌘C`, `⌘V` and `⌘A`
chords, so text fields outside the terminal (SSH Hosts, sheets, the sidebar) can
edit. A focused terminal still runs its own bindings for these chords first. If
you unbind one, the terminal does not receive the raw chord; the Edit menu item
handles it instead.

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

Ordinary terminal windows also show **SSH Hosts** after the files-panel button
in each placement. The popover filters registered hosts and recent connections;
Return opens a new tab, Option-Return splits right, and Escape returns focus to
the terminal. Opening it does not run `ssh -G`. Quick Terminal omits this button.

`WorkspaceControlsPlacement.forStandaloneWindow` is the whole decision, and
`WorkspaceControlsPlacementTests` covers its matrix.

## Building

```sh
zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dsentry=false   # refresh GhosttyKit
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
attributes that fail the test host's codesign step. Locally, run the suite as
`-only-testing:` batches rather than one invocation; every controller-building
test keeps live terminal surfaces, and enough of them starve the test host.
`AGENTS.md` has the exact command.

## Releasing

Releases are built locally, where the signing identity, notary profile and
Sparkle private key live, rather than spending hosted macOS minutes rebuilding
code that already passed pull-request CI:

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

Chostty versions are independent of Ghostty's. 1.0.0 is the first stable
Chostty release; `--publish-next` increments the patch from there, and minor or
major bumps are an explicit `--version`. Upstream's own `vX.Y.Z` tags share the
same namespace, so `scripts/upstream-sync.sh` fetches with `--no-tags`. A
checkout that already imported them refuses to publish a colliding version
with "already points at another commit"; delete the local upstream tag
(`git tag -d vX.Y.Z`) and publish again.

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

`.github/workflows/ci.yml` runs shellcheck and the audit on every pull request,
and the Zig core build and macOS test suite only when the pull request changes a
macOS build input. UI tests are skipped there for the same reason
`macos/build.nu` skips them: no CI runner grants accessibility permission.

Two further CI-only concessions, both about the hosted runner rather than the
code. Tests run serially: many suites stand up a real
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

- Only the curated keys in
  `macos/Sources/Features/Settings/ConfigEditor/ConfigSchema.swift` get
  type-specific controls (pickers, color wells, sliders). Every other key in
  All Settings is a text field, a switch for `bool` fields, or a list for
  repeatable ones. Effective values are resolved from the file, its includes
  and its theme; CLI arguments are not considered.
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
  from menus, not the command palette. Workspace and SSH commands are available
  in the app-local command palette source.
- Source-pinned assertions catch a modifier being removed or moved, but not one
  being added alongside.
- SSH has been checked by hand against a real server for a Keychain password
  sign-in, a ProxyJump host and two app instances running tunnels at once.
  These manual checks are still unverified: a hardware FIDO key (none was
  available), VoiceOver (deferred by the user), the Keychain consent and ACL
  prompt and a locked Keychain, a PAM keyboard-interactive server, SSH-origin
  `none` prompts, the live host-key trust sheet, password and secure-input
  tunnels, Debug and Release Keychain separation, and the first connect after
  an ad-hoc signed update. Treat the SSH feature as not release-ready until
  those checks pass.
- Reopening a closed group that mixes SSH and local tabs rebuilds every tab
  from its recorded metadata, so the local tabs come back as fresh shells
  rather than their original processes.

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
