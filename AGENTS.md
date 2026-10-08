# Repository Guidelines

## Project Overview

Chostty is a macOS fork of [Ghostty](https://github.com/ghostty-org/ghostty) that removes
AppKit native window tabs and replaces them with an in-window **Workspace → Virtual Tab →
Pane** hierarchy driven from a left sidebar. One physical `NSWindow` owns the whole graph
in memory. Everything below the window model — renderer, config, terminfo, shell
integration — is stock Ghostty.

The fork's code lives almost entirely in `macos/`. The Zig core in `src/` is upstream's and
is carried nearly unmodified. The Linux/FreeBSD GTK tree (`src/apprt/gtk`) is inherited and
is **not built or tested here**.

Remotes: `origin` = `chlee1001/chostty`, `upstream` = `ghostty-org/ghostty`.

## Architecture & Data Flow

### Zig core (`src/`)

`src/main.zig` is an entrypoint multiplexer; `build_config.exe_entrypoint` selects one of
`main_ghostty.zig` (the app), `main_c.zig` (libghostty embedding lib), `lib_vt.zig`
(libghostty-vt), `main_bench.zig`, `main_gen.zig`, `main_wasm.zig`.

Runtime flow for one terminal:

```
PTY ─ termio/Termio.zig (subprocess + IO thread)
    → terminal/stream.zig → terminal/Parser.zig
    → terminal/Screen.zig + terminal/PageList.zig   (the terminal model)
    → renderer/ (own thread) → font/ (shaping, atlas) → GPU
```

- `src/App.zig` owns the allocator, the live `*apprt.Surface` list, the app mailbox and the
  shared `font.SharedGridSet`. It dispatches app/global keybinds and runtime actions.
- `src/Surface.zig` is the runtime-agnostic terminal unit. It is **deliberately
  hierarchy-agnostic** — window/tab/split policy belongs to the host runtime. Do not push
  container semantics into it.
- `renderer.State.mutex` guards terminal/preedit/mouse state; the PTY parser and the
  renderer hand off via `yieldToDemand`/`lockDemand`. Never touch `Surface.io.terminal`
  cross-thread outside that pattern.

`src/apprt.zig` picks the runtime at comptime. `apprt.Runtime` only enumerates `.none` and
`.gtk` — **macOS is not a third runtime value**. It embeds the `.lib` build through
`apprt.embedded` and the `include/ghostty.h` C ABI, shipped as the `GhosttyKit` xcframework.

Two independent C ABIs; do not conflate them:

| Header | Purpose | Zig export root |
|---|---|---|
| `include/ghostty.h` | app embedding (GhosttyKit, consumed by `macos/`) | `src/main_c.zig` |
| `include/ghostty/vt.h` + `include/ghostty/vt/*.h` | standalone libghostty-vt | `src/lib_vt.zig` |

### macOS app (`macos/`)

There is no macOS `@main`. `macos/Sources/App/macOS/main.swift` is top-level code that calls
`ghostty_init` → `ghostty_cli_try_action` → `NSApplicationMain`, which loads `MainMenu.xib`
and instantiates `AppDelegate`. `AppDelegate` owns the single `Ghostty.App`
(`macos/Sources/Ghostty/Ghostty.App.swift`), the bridge that translates libghostty callbacks
into `NotificationCenter` posts.

The fork's model graph:

```
TerminalController              (one NSWindow, one store, nonoptional)
└── WorkspaceSessionStore       structural root; transactional @Published snapshot
    └── WorkspaceSession        value struct — owns NO NSWindow
        └── TerminalSessionState   virtual tab; owns a pane split tree
            └── SurfaceView         pane, bound to a libghostty surface
```

`TerminalControllerGraphFactory` (in `TerminalController.swift`) builds a complete graph
*before* observers or view loading; a controller must never receive a partial one.
**Every structural edit goes through a single store transaction.** Publishing parallel
structural state can overwrite another session's tree and release its PTY —
`BaseTerminalController.selectSession` documents that failure mode.

UI is mixed: AppKit owns windows/controllers (`TerminalWindow`, `BaseTerminalController`),
SwiftUI owns content (`TerminalView`, `SidebarView`, `SplitView`), hosted via
`NSHostingView`.

## Key Directories

| Path | Contents |
|---|---|
| `src/terminal/` | VT parser/stream, `Screen`/`PageList`, selection, styling, protocols, page compression, libghostty-vt C adapters (`src/terminal/c/`) |
| `src/termio/` | PTY/subprocess backend, IO thread, mailbox, `stream_handler.zig` (VT → terminal side effects) |
| `src/renderer/` | Renderer thread + state, cell→GPU conversion, backends, shaders |
| `src/font/` | Discovery/backends, fallback collections, shaping, sprites, atlases |
| `src/apprt/` | Runtime adapters — `embedded.zig` (macOS host), `gtk/` (inherited) |
| `src/config/` | `Config.zig` is the authoritative user-config struct + docs |
| `src/build/` | `Config.zig` defines every `-D` flag; artifact constructors |
| `src/lib/`, `src/datastruct/` | ABI helpers for C bindings; queues/caches/split trees |
|`macos/Sources/Features/Workspace/`|Fork core: store, session state, surface-owner registry, undo leases, reserved shortcuts, session snapshot persistence (schema, repository, validator, gate, save trigger, pending-hydration registry)|
| `macos/Sources/Features/Terminal/` | Window controllers, SwiftUI composition, window styles |
| `macos/Sources/Features/Sidebar/` | Workspace/tab tree, workspace controls, `VirtualTabBar` |
| `macos/Sources/Features/FilesPanel/` | Right-side file tree; `Reader/` = per-tab read-only document tabs |
| `macos/Sources/Ghostty/` | Swift wrappers over GhosttyKit C types; `Surface View/` = AppKit pane |
| `macos/Sources/Helpers/` | Shared utilities; `Extensions/` and private CGS/Dock wrappers |
| `macos/scripts/` | Fork-authored gates: `native-tab-audit.sh`, `verify-third-party-notices.sh`, `package-release.sh` |
| `scripts/` | `upstream-sync.sh` (drift report) and `release-local.sh` (local release/package/publish) |
| `pkg/`, `vendor/`, `po/`, `dist/`, `nix/` | Upstream-inherited; not fork-authored |
| `docs/` | **Not product docs** — only `docs/history/`, gitignored agent scratch |

## Development Commands

### Zig core

```sh
zig build -Demit-macos-app=false          # build GhosttyKit only — the fast path
zig build test                            # full Zig suite (slow)
zig build test -Dtest-filter=<name>       # PREFER THIS; substring match on test names
zig build test-lib-vt -Dtest-filter=<f>   # prefer for libghostty-vt changes
zig fmt .
```

Plain `zig build` on macOS defaults to `emit_xcframework`/`emit_macos_app` = true and will
silently invoke `xcodebuild`. Always pass `-Demit-macos-app=false` unless you actually want
the bundle — and even then, build the bundle with `build.nu`, not `zig build`.

Declared `zig build` steps: `run`, `run-valgrind`, `test`, `test-lib-vt`, `test-valgrind`,
`update-translations`, `dist`, `distcheck`. Notable `-D` flags (full list in
`src/build/Config.zig`): `emit-macos-app`, `emit-lib-vt`, `emit-xcframework`, `emit-bench`,
`emit-docs`, `app-runtime`, `renderer`, `font-backend`, `test-filter`, plus stock
`-Doptimize` / `-Dtarget`.

### macOS app

```sh
./macos/build.nu --configuration Debug --action build
xattr -cr macos/build/Debug/Chostty.app          # REQUIRED before the test step
./macos/build.nu --configuration Debug --action test
./macos/scripts/native-tab-audit.sh              # enforcing gate, exit 1 on violation
```

`build.nu` flags: `--scheme` (default `Ghostty`), `--configuration`
(`Debug`|`Release`|`ReleaseLocal`), `--action` (any xcodebuild action). It wraps
`xcodebuild … SYMROOT=macos/build` under `env -i` to keep a Nix shell from poisoning the
build, and always adds `-skip-testing GhosttyUITests` for `--action test`. Output is
`macos/build/<Configuration>/Chostty.app` (the product is named **Chostty**, not Ghostty).

If a build fails with no `error:` line it is usually a stale signature — delete
`macos/build/<Configuration>` and rebuild.

### libghostty-vt

```sh
zig build -Demit-lib-vt
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

`-D` flags are **not independent**: `-Demit-lib-vt` flips the defaults of `emit-exe`,
`emit-docs`, `emit-xcframework` and `emit-macos-app` (see the `orelse` chains at
`src/build/Config.zig:377,412,464,482`), and `zig build test` is skipped entirely when it is
set. Read those chains rather than assuming a flag only does what its name says.

### Other

```sh
swiftlint lint --strict --fix              # Swift
prettier -w .                              # JSON/YAML/TOML/MD — never touches macos/
shellcheck macos/scripts/*.sh scripts/*.sh # what CI's `scripts` job runs
./scripts/upstream-sync.sh [--markdown]    # upstream drift report; does not merge
./scripts/release-local.sh --version <v>   # local universal DMG + zip
./scripts/release-local.sh --version <v> --publish  # also tag and publish
./scripts/release-local.sh --publish-next  # sync main, bump patch, build and publish
# Signed + notarized release: export CHOSTTY_SIGNING_IDENTITY (Developer ID
# Application) and CHOSTTY_NOTARY_PROFILE (notarytool keychain profile), or put
# them once in a gitignored .release-env at the repo root
```

`make` and `cmake` are **not** entry points for this product. `Makefile` has only `glad`
(manual vendor regen) and `clean`; `CMakeLists.txt` exists so downstream C/C++ projects can
consume libghostty-vt.

## Code Conventions & Common Patterns

### Zig

- **PascalCase file = its type.** `src/Surface.zig`, `src/terminal/Screen.zig` open with
  `const Screen = @This()`. Lowercase `main.zig` files are package facades that re-export
  with `pub const X = @import(...)`.
- **Explicit allocator threading.** Constructors take `std.mem.Allocator`, store it when the
  state owns allocations, and pair `init`/`deinit` or `create`/`destroy`. Ownership transfer
  is stated in a comment (`Stream` takes ownership of its handler).
- **`errdefer` immediately after acquisition.** See `src/Surface.zig:491-580` for the stacked
  cleanup pattern.
- **Arena per logical scope** for frame-temporary or grouped allocations
  (`src/renderer/generic.zig` builds one per frame update).
- **Typed error sets**, narrow where useful: `DetectError = error{MultipleActions,
  InvalidAction}`. Background/recoverable failures are caught and logged at the thread
  boundary rather than aborting; invariant violations use assertions.
- **Comptime feature gating, not runtime branching.** `src/build_config.zig` derives
  artifact/runtime/renderer/font selection from `build_options`; optional backend hooks are
  detected structurally with `@hasDecl`.
- Config field names mirror CLI keys, so quoted identifiers are normal:
  `config.@"font-size"`. Doc comments in `src/config/Config.zig` feed generated manpages and
  must be Pandoc-flavored Markdown.

### Swift

- **`ObservableObject` + `@Published`, not `@Observable`** — there is no `@Observable` usage
  in the tree. `@State`/`@StateObject`/`@AppStorage` for owned local UI state,
  `@ObservedObject` for passed-in models.
- **Combine + NotificationCenter** is the event bus. Cancellables live in
  `Set<AnyCancellable>`/dictionaries; observers and cancellables are torn down in `deinit`.
- **Injection is explicit at boundaries** (`TerminalControllerGraphFactory.InitialGraph` into
  `BaseTerminalController`, `.environmentObject(ghostty)` into SwiftUI subtrees). Singletons
  exist and are established: `SecureInput.shared`, `GitMetadataService.shared`,
  `AboutController.shared`.
- **Concurrency:** `@MainActor` on UI-bound models (`FilesPanelController`,
  `SurfaceOwnerRegistry`); `actor` for background services (`FilesPanelDocumentLoader`,
  `GitMetadataService`); `Task` + cancellation checks for async work.
- **Errors:** typed enums for expected I/O (`FilesPanelScanner.ScanError`),
  `preconditionFailure`/`fatalError` only for programmer invariants.
- **Naming:** file = primary type; `Ghostty.App.swift` style dotted names for namespaced
  bridge types; `NSWindow+Extension.swift` / `AppDelegate+AppleScript.swift` for extensions.
  Sections marked with `// MARK: -`.
- SwiftLint (`macos/.swiftlint.yml`) disables line/file/function-length and nesting rules;
  `.editorconfig` sets 4-space Swift, 2-space shell/nu.

### Commits

The fork's own history uses Conventional Commits — `feat(workspace):`, `fix(sidebar):`,
`refactor(macos):`, `test:`, `ci:`, `build:`, `chore:`. Match it. (Note
`.agents/skills/writing-commit-messages/SKILL.md` describes upstream's older
`<subsystem>: <summary>` style; it is inherited, and upstream commits below the fork point
still look like that.)

## Important Files

| File | Why it matters |
|---|---|
| `FORK.md` | What changed vs upstream, what is frozen for compatibility, known gaps, release/verification notes. Read before touching the window model. |
| `README.ko.md` / `FORK.ko.md` | Korean translations of `README.md` / `FORK.md`. The English file is canonical; update the Korean one in the same change. |
| `build.zig` / `src/build/Config.zig` | Every build step and `-D` flag |
| `build.zig.zon` | Deps + `minimum_zig_version = "0.16.0"` |
| `build.zig.zon.{nix,txt,json}` | **Generated** by `nix/build-support/check-zig-cache.sh --update`; never hand-edit |
| `macos/build.nu` | The only sanctioned macOS build/test entry point |
| `macos/Ghostty.xcodeproj/project.pbxproj` | Target membership, GhosttyKit/SwiftPM linkage |
| `macos/Ghostty.sdef` | AppleScript dictionary — deliberately frozen; ordering is Classes→Records→Enums→Commands |
| `macos/scripts/native-tab-audit-soft-expected.txt` | Checked-in allowlist of benign `tabIndex`/`tabButton` matches |
| `THIRD-PARTY-NOTICES.md` | Must stay byte-identical to each pinned SwiftPM dep's license |
| `HACKING.md` | Mostly upstream; references a `CONTRIBUTING.md` that does not exist here |

Nested `AGENTS.md` files bind within their directory and must be read before editing there:
`macos/`, `example/`, `src/benchmark/`, `src/inspector/`, `src/terminal/c/`,
`src/terminal/compress/`, `src/terminal/apc/glyph/`, `test/fuzz-libghostty/`.

## Runtime/Tooling Preferences

- **Zig 0.16.0**, pinned in `build.zig.zon` and enforced at comptime by `requireZig` in
  `build.zig` — a mismatched `zig` fails immediately, not gracefully.
- **Xcode 26 / macOS 26 SDK** for the app. Deployment target is macOS 13+, universal binary.
- **Nushell** is required to run `macos/build.nu`.
- **Nix is optional and does not build the app.** `flake.nix`'s `buildablePlatforms` filters
  Darwin out of the `ghostty` package; only `libghostty-vt-*` builds there. `nix develop`
  works as a dev shell on macOS but produces no bundle.
- Formatter ownership: `zig fmt` → Zig; `swiftlint` → Swift; `prettier` → everything else
  except `macos/` (Xcode-managed) and the paths in `.prettierignore`; `.clang-format` →
  vendored C/C++ only.

## Testing & QA

### Zig

Tests are colocated as `test { ... }` / `test "descriptive name" { ... }` blocks using
`std.testing` and `std.testing.allocator` (so leaks surface). Package facades force lazy
analysis with `std.testing.refAllDecls(@This())` and bare `_ = @import(...)` — a new module
that is not referenced from a facade **will not be compiled by the test build**.

Test names conventionally lead with the owning type or protocol family (`Screen ...`,
`PageList ...`, `csi: ...`, `osc: ...`), which is what makes `-Dtest-filter` usable.

### Swift

- `macos/Tests/` (`GhosttyTests`) uses **swift-testing** — `import Testing`, `@Suite`,
  `@Test`, `#expect`, `#require`. No XCTest here.
- `macos/GhosttyUITests/` uses **XCUITest** — `XCTestCase` via `GhosttyCustomConfigCase`,
  which writes a UUID-named temp config, sets `GHOSTTY_CONFIG_PATH` and
  `GHOSTTY_USER_DEFAULTS_SUITE`, then launches `XCUIApplication`. Most UI suites skip
  themselves outside the Xcode IDE unless they override `defaultTestSuite`.
- UI tests never run via `build.nu` (it always passes `-skip-testing GhosttyUITests`); they
  need accessibility permission and must be driven from Xcode.

### Gates

`./macos/scripts/native-tab-audit.sh` is the fork's defining gate. It scans `macos/Sources`,
`macos/Tests`, `macos/GhosttyUITests` plus `project.pbxproj`, `Ghostty-Info.plist` and
`Ghostty.sdef` for two classes of token:

- **HARD** (`tabGroup`, `NSWindowTabGroup`, `addTabbedWindow`, `toggleTabBar`,
  `mergeAllWindows`, …) — must be zero.
- **SOFT** (`tabIndex`, `tabButton`) — allowed, but the exact match set must equal
  `native-tab-audit-soft-expected.txt` byte-for-byte.

A soft failure is often just an unseeded new variable name, not a real regression. Re-seed
with `--seed-soft` (refused while a hard violation stands) and review the diff. `--warn` /
`AUDIT_WARN=1` makes it report-only.

`macos/scripts/verify-third-party-notices.sh` is **not wired into CI** — run it manually
whenever a SwiftPM dependency version changes. It needs a prior local Xcode build to populate
DerivedData, or an explicit `--checkouts` path.

### CI

- `.github/workflows/ci.yml` — PR / manual dispatch only. The Ubuntu `scripts` job runs
  shellcheck and native-tab-audit, then reports whether the PR changed a macOS build input.
  The `macos-26` job runs Zig core build and `xcodebuild … -configuration Debug` tests only
  when that output is true. Main is not rebuilt after a green PR merges; that duplicate
  macOS run consumed hosted minutes without testing new code.
- `.github/workflows/release.yml` — manual no-publish fallback. It builds and uploads the
  packaged artifacts but never tags or creates a GitHub release. Normal releases use
  `scripts/release-local.sh`; `--publish` uploads from the local Mac without hosted minutes.
- `.github/workflows/upstream-check.yml` — weekly cron; runs `upstream-sync.sh --markdown`
  and maintains one rolling issue on `origin`.

**CI is a floor, not a ceiling.** UI tests are always skipped there, tests run serially
(concurrent `TerminalController` + Metal suites crash the runner and xcodebuild then
misreports every unfinished test as failed), and
`reopenAfterForcedFinalizeCreatesFreshTabWithRecordedMetadata` is skipped by name because it
takes the host process down.

**The local gate is the whole macOS suite run in batches — never one invocation.** A single
`build.nu --action test` (or one `xcodebuild … test` over every suite) wedges rather than
fails: each `TerminalControllerTestHarness`-built controller keeps a loaded window alive for
the life of the test host, and a live `Ghostty.SurfaceView` under it owns a real PTY plus a
renderer thread and three IO threads. Around forty accumulated surfaces — ~176 threads —
starve the host's main run loop and the run blocks in `CFRunLoopRun`. This is the same
resource exhaustion as the concurrent-suite crash above, reached serially.

**A test that does not exercise a terminal must not spawn one.** Build its views with
`Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)`: the object graph is
identical and no PTY, renderer thread or IO thread is created. That is the only lever, since
a live surface cannot be released afterwards (see the `TerminalControllerTestHarness` doc).
Reserve real surfaces for the few tests that genuinely drive a terminal, and close them
explicitly there.

The session-persistence suites are the worked example: they build every graph with
`spawnsSurface: false`, inject the surface factory where a snapshot would otherwise create
real panes, and point the repository at a temporary directory so nothing touches
`~/Library/Application Support`. They also always inject the controller list rather than
reading `TerminalController.all`, because the harness leaves earlier suites' controllers in
`NSApp.windows` for the life of the test host.

Run the suite as `-only-testing:` batches of a few suites each, serially, with an execution
allowance so a wedged batch fails instead of hanging:

```sh
xattr -cr macos/build/Debug/Chostty.app
env -i "HOME=$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild \
  -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug \
  -derivedDataPath /tmp/chostty-dd \
  -skip-testing GhosttyUITests \
  -skip-testing 'GhosttyTests/DuplicateTabAndReopenClosedTabTests/reopenAfterForcedFinalizeCreatesFreshTabWithRecordedMetadata()' \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -only-testing:GhosttyTests/<SuiteA> -only-testing:GhosttyTests/<SuiteB> test
```

A batch of four controller-building suites finishes in seconds. Use a scratch
`-derivedDataPath` when the shared DerivedData goes bad: a corrupted one makes every test
host stall inside dyld (`mapFileReadOnly`) and xcodebuild reports "The test runner hung
before establishing connection" ~344s later — that is a broken cache, not a product failure,
and a fresh path fixes it.

GUI-backed suites also need an awake display. With the screen asleep,
`CVDisplayLinkCreateWithCGDisplays` reports `invalid display count (0)`, surface creation
fails with `error.OutOfMemory`, and every live-surface test fails for reasons that have
nothing to do with the change under test. Check `system_profiler SPDisplaysDataType` for
`Display Asleep` before believing those failures.

## Traps

- **The clean-merge trap.** A `git merge upstream/main` that resolves with zero conflicts can
  still restore a window-level "one tab = one NSWindow" assumption this fork deleted — git
  has no textual overlap to flag. That is exactly what `upstream-sync.sh`'s "clean merge,
  still worth reading" bucket exists for, with the native-tab audit as the backstop.
- **Never open an issue or PR against `upstream`.** Against `origin`, only when asked, and
  name the remote explicitly so a stray default cannot aim it upstream.
- **Upstream-compatible identifiers are frozen on purpose**: the `Ghostty` Swift module,
  `GhosttyKit`, `GHOSTTY_*` env vars, `xterm-ghostty`, `share/ghostty`, `~/.config/ghostty/`,
  the Linux `ghostty` executable name, and every AppleScript four-char code. Only the macOS
  bundle/executable/identifier are renamed. Do not "clean these up". The bundle identifier
  is `kr.co.devch.chostty` (`.debug` for Debug); releases through 0.2.15 used
  `com.chostty.app`, which `LegacyBundleMigration` copies from once at launch.
- **Sparkle:** `Ghostty-Info.plist` points at this fork's signed appcast and
  carries its Ed25519 public key. Because the plist is preprocessed by cpp, URL slashes
  use `&#x2F;`. Source builds keep automatic checks off; packaging enables them.
  Chostty publishes stable updates only. Signed releases require the external
  private key and Sparkle's `generate_appcast`; neither belongs in the
  repository. Never use upstream's appcast — it would replace Chostty with
  stock Ghostty.
- **libghostty-vt C enums** must end with `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`; the
  `INT_MAX` sentinel forces `int` sizing on pre-C23 compilers. Omitting it is an ABI break. A
  new vt function must be threaded all the way through: `src/terminal/c/<module>.zig` →
  re-export in `src/terminal/c/main.zig` → `@export` under a `ghostty_` symbol in
  `src/lib_vt.zig` → declaration in `include/ghostty/vt/`.
- **Generated files:** `src/font/nerd_font_attributes.zig`,
  `src/font/nerd_font_codepoint_tables.py`, `src/unicode/*_table.zig` and the
  `build.zig.zon.*` mirrors are all machine-produced. So is every icon —
  `images/Chostty.icon`, the asset-catalog app/alternate/custom-icon PNGs, `images/gnome`,
  `images/icons` and the `dist/` icons all come from `macos/scripts/generate-icons.py`.
  Fix the generator, not the output.
- **Version tags collide with upstream.** Chostty's own versions reached 1.0.0, and
  upstream's `vX.Y.Z` tags use the same names. `upstream-sync.sh` fetches with `--no-tags`;
  if an earlier fetch imported them, `release-local.sh` refuses to publish with "already
  points at another commit" — run `git tag -d vX.Y.Z` for the upstream tag, never move a
  pushed Chostty tag.
- **Signing.** Release artifacts are ad-hoc signed unless both `CHOSTTY_SIGNING_IDENTITY`
  (a "Developer ID Application: …" identity) and `CHOSTTY_NOTARY_PROFILE` (a stored
  `xcrun notarytool store-credentials` profile) are exported; then the app and DMG are
  signed, notarized and stapled, and `package-release.sh` refuses one without the other.
  Ad-hoc artifacts stay quarantined until the user runs `xattr -cr /Applications/Chostty.app`
  — a distribution consequence, not a build bug.
- **LaunchServices ambiguity:** build copies register under the same bundle id, so
  `tell application "Chostty"` can target a non-running copy and block in `AESendMessage`
  forever. Target AppleScript by absolute path, or
  `lsregister -u "$PWD/macos/build/Release/Chostty.app"` right before scripting work.
