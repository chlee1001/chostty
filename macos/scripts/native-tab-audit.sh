#!/bin/bash
#
# Native-tab audit gate (plan F4).
#
# HARD tokens must reach zero across every shipping target's sources; the only
# sanctioned survivors are explanatory comment lines whose full text is
# checked into the allowlist below. SOFT tokens are allowed to survive but
# must be exactly attributed: the set of matching path:<content> entries has
# to equal the checked-in expected file, so a NEW soft match is a failure even
# though the token itself is permitted.
#
# Usage:
#   native-tab-audit.sh            enforcing (exit 1 on any violation)
#   native-tab-audit.sh --warn     report only, always exit 0 (PM-8 per-sub-commit)
#   AUDIT_WARN=1 native-tab-audit.sh   same as --warn
#   native-tab-audit.sh --seed-soft    (re)write $EXPECTED_SOFT from the
#                                      current soft-token matches. Refused
#                                      only when a HARD violation (`hard_fail`)
#                                      is currently failing, so seeding never
#                                      launders a red tree. A SOFT-only
#                                      failure (attribution drift with no
#                                      HARD hit) does NOT block seeding
#                                      — that IS the reseed workflow after a
#                                      reviewed, intentional edit near a
#                                      soft-token line. No file deletion is
#                                      required or should ever be necessary:
#                                      just re-run with --seed-soft once the
#                                      diff it prints has been read and is
#                                      judged intentional.
#
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2

WARN=0
[ "${AUDIT_WARN:-0}" = "1" ] && WARN=1
[ "${1:-}" = "--warn" ] && WARN=1

# Every shipping target's sources, including the UI-test target — a HARD
# match there is guaranteed-failing/runtime-only, not merely undesirable, and
# the plan's own gate must cover it or "HARD = 0" is scope-limited theatre.
ROOTS=(macos/Sources macos/Tests macos/GhosttyUITests)
EXPECTED_SOFT="macos/scripts/native-tab-audit-soft-expected.txt"

# Individual runtime-only files that carry class-name and action-selector
# STRING references (a nib instantiation failure or a menu item AppKit never
# synthesizes, not a compile error) but do NOT live under any of $ROOTS, so no
# glob against $ROOTS can ever reach them. Listed explicitly (as direct grep/
# find arguments, not via `--include`/`FILE_NAME_MATCH`, which only matches
# during recursion into $ROOTS and would never see a path outside it).
EXTRA_FILES=(
  macos/Ghostty.xcodeproj/project.pbxproj
  macos/Ghostty-Info.plist
  macos/Ghostty.sdef
)
for f in "${EXTRA_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: expected runtime-only file missing (moved/renamed?): $f"
    exit 2
  fi
done

# File types scanned under $ROOTS. `.xib` is the only one of these that
# actually occurs under $ROOTS today; `.pbxproj`/`.plist`/`.sdef` live outside
# $ROOTS entirely and are covered instead via $EXTRA_FILES above.
FILE_NAME_MATCH=(-name '*.swift' -o -name '*.m' -o -name '*.h' -o -name '*.xib')
GREP_INCLUDES=(--include='*.swift' --include='*.m' --include='*.h' --include='*.xib')

HARD_PATTERN='tabGroup|tabbedWindows|addTabbedWindow|mergeAllWindows|toggleTabOverview|toggleTabBar|moveTabToNewWindow|performCloseOtherTabs|NSWindowTabGroup|selectNextTab|selectPreviousTab|relabelTabs|tabWindowsHash|tabListenForFrame|fixTabBar|hasMoreThanOneTabs|isFirstWindowInTabGroup|tabGroupCloseCoordinator|titlebarTabs|isTabBar|tabBarView|tabBarDidAppear|tabBarDidDisappear|tabButtonsInVisualOrder|tabButtonHit|tabIndex[(]atScreenPoint'

SOFT_PATTERN='tabIndex|tabButton'

# Sanctioned HARD survivors: explanatory comments that must keep naming the
# removed machinery. Matched as a fixed STRING against "path:<full line
# content>" — anchored to content, not line number, so a future edit that
# shifts the comment down a line does not silently drop it out of the
# allowlist, and (the actual bug this replaces) a future CODE line landing on
# a previously-allowlisted line number is never silently sanctioned.
# Empty: no current survivor's content matches; add entries here only when a
# real explanatory comment must keep naming removed machinery.
ALLOWLIST=(
)

hard_fail=0
fail=0
report() {
  if [ "$WARN" = "1" ]; then
    echo "WARN: $*"
  else
    echo "FAIL: $*"
    fail=1
  fi
}

# Existence check FIRST. `rg`/`grep` exits non-zero both when a pattern has no
# matches (the desired end state) and when the paths do not exist (wrong cwd),
# so those two cases must be distinguished before interpreting a no-match.
# Threshold is <100, not merely ==0: a near-empty scan (e.g. a typo'd root or
# a glob that silently matched nothing) must fail loudly rather than reporting
# a false-green "0 hits" over 3 files. $EXTRA_FILES is added to the count (not
# just scanned) so a broken/removed extra file can't silently narrow coverage
# while still clearing the guard on $ROOTS alone.
file_count=$(find "${ROOTS[@]}" -type f \( "${FILE_NAME_MATCH[@]}" \) 2>/dev/null | wc -l | tr -d ' ')
file_count=$((file_count + ${#EXTRA_FILES[@]}))
if [ "$file_count" -lt 100 ]; then
  echo "FAIL: scan roots produced suspiciously few files ($file_count < 100; wrong working directory or a broken root?): ${ROOTS[*]} + ${EXTRA_FILES[*]}"
  exit 2
fi
echo "scanned $file_count source files under ${ROOTS[*]} + ${#EXTRA_FILES[@]} extra runtime-only file(s)"

# --- HARD: must reach zero ------------------------------------------------
# Two invocations, deliberately. `--include` filters EXPLICITLY NAMED file
# arguments as well as recursive descent, so passing $EXTRA_FILES alongside
# $GREP_INCLUDES silently drops every one of them (.sdef/.plist/.pbxproj match
# none of the include globs) — the coverage would read as present and scan
# nothing. $EXTRA_FILES therefore gets its own unfiltered grep.
hard_hits_raw=$(
  { grep -rnE "$HARD_PATTERN" "${ROOTS[@]}" "${GREP_INCLUDES[@]}" 2>/dev/null || true
    grep -nE "$HARD_PATTERN" "${EXTRA_FILES[@]}" 2>/dev/null || true
  })

while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  path="${hit%%:*}"
  rest="${hit#*:}"
  content="${rest#*:}"
  key="$path:$content"
  sanctioned=0
  for allowed in "${ALLOWLIST[@]:-}"; do
    [ "$key" = "$allowed" ] && sanctioned=1 && break
  done
  [ "$sanctioned" = "1" ] && continue
  hard_fail=1
  report "unsanctioned native-tab reference: $hit"
done <<< "$hard_hits_raw"

# --- SOFT: must be exactly attributed -------------------------------------
# Anchored by "path:<trimmed line content>", like $ALLOWLIST above, NOT by
# "path:<line number>": a line-number anchor breaks on any edit above the
# first soft-token line (pure line shift, content unchanged), which is not a
# real attribution drift and should never fail this gate.
soft_actual=$(
  { grep -rnE "$SOFT_PATTERN" "${ROOTS[@]}" "${GREP_INCLUDES[@]}" 2>/dev/null || true
    grep -nE "$SOFT_PATTERN" "${EXTRA_FILES[@]}" 2>/dev/null || true
  } \
  | grep -vE "$HARD_PATTERN" \
  | while IFS= read -r hit; do
      path="${hit%%:*}"
      rest="${hit#*:}"
      content="${rest#*:}"
      trimmed="$(printf '%s' "$content" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      printf '%s:%s\n' "$path" "$trimmed"
    done | sort || true)

if [ -f "$EXPECTED_SOFT" ]; then
  if ! diff_out=$(diff <(echo "$soft_actual") <(sort "$EXPECTED_SOFT")); then
    report "soft-token attribution drifted from $EXPECTED_SOFT:"$'\n'"$diff_out"
  fi
else
  echo "note: $EXPECTED_SOFT missing; seed it with:"
  echo "  $0 --seed-soft"
fi

if [ "${1:-}" = "--seed-soft" ]; then
  # Refuse to seed only on a HARD-failing tree: seeding then would rewrite
  # the expectation to match violations instead of catching them. A SOFT-only
  # failure (attribution drift, no HARD hit) is exactly what --seed-soft
  # exists to resolve, so it must NOT also be refused here — that would leave
  # deleting $EXPECTED_SOFT by hand as the only path forward, which is
  # undocumented and invites a blind delete-and-reseed that skips reviewing
  # the diff above.
  if [ "$hard_fail" = "1" ]; then
    echo "REFUSED: HARD violations are currently failing; fix those before seeding $EXPECTED_SOFT"
    exit 1
  fi
  echo "$soft_actual" > "$EXPECTED_SOFT"
  echo "seeded $EXPECTED_SOFT ($(wc -l < "$EXPECTED_SOFT" | tr -d ' ') entries)"
  exit 0
fi

if [ "$fail" = "1" ]; then
  echo "native-tab audit FAILED"
  exit 1
fi
if [ "$WARN" = "1" ]; then
  echo "native-tab audit (warn mode) complete"
else
  echo "native-tab audit PASSED"
fi
exit 0
