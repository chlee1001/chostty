#!/usr/bin/env bash
#
# Report what upstream Ghostty changed since this fork last merged, sorted by
# how likely it is to hurt.
#
# This deliberately does not merge. Almost every change this fork carries is in
# macos/, and upstream rewrites files there for reasons that have nothing to do
# with the workspace model — so a merge that git resolves without complaint can
# still restore a native-tab path or reintroduce a window-level assumption the
# fork removed. Read the review list first.
#
# There is no recorded sync point to drift out of date: the merge base with
# upstream is the sync point, and git derives it.
#
# Usage:
#   scripts/upstream-sync.sh [--branch main] [--markdown] [--merge]

set -euo pipefail

BRANCH="main"
FORMAT="text"
DO_MERGE="no"

while [ $# -gt 0 ]; do
	case "$1" in
	--branch) BRANCH="$2"; shift 2 ;;
	--markdown) FORMAT="markdown"; shift ;;
	--merge) DO_MERGE="yes"; shift ;;
	-h | --help) sed -n '2,16p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

UPSTREAM_URL="https://github.com/ghostty-org/ghostty.git"
if ! git remote get-url upstream >/dev/null 2>&1; then
	git remote add upstream "$UPSTREAM_URL"
fi
git fetch --quiet upstream "$BRANCH"

REF="upstream/$BRANCH"
MB="$(git merge-base HEAD "$REF")"
AHEAD="$(git rev-list --count "$MB..$REF")"

# Files this fork touched since the merge base, split by whether they still
# exist here. Upstream editing a file we deleted is a delete/modify conflict
# that git will stop on, which is a different problem from a content clash.
OURS="$(git diff --name-only --diff-filter=d "$MB..HEAD")"
OURS_DELETED="$(git diff --name-only --diff-filter=D "$MB..HEAD")"
THEIRS="$(git diff --name-only "$MB..$REF")"

overlap() { comm -12 <(printf '%s\n' "$1" | sort -u) <(printf '%s\n' "$2" | sort -u); }

REVIEW="$(overlap "$THEIRS" "$OURS")"
DELETED_HIT="$(overlap "$THEIRS" "$OURS_DELETED")"
# macOS files upstream changed that we have not touched. Git merges these
# cleanly and that is exactly why they are worth a look: they land in the app
# this fork restructured.
MACOS_NEW="$(printf '%s\n' "$THEIRS" | grep '^macos/' | sort -u | comm -23 - <(printf '%s\n' "$REVIEW" | sort -u) || true)"
# Every bucket subtracts the ones above it. A file listed twice would read as
# two independent items and inflate the count a reviewer is triaging.
CLAIMED="$(printf '%s\n%s\n' "$REVIEW" "$DELETED_HIT" | grep . | sort -u || true)"
REST="$(printf '%s\n' "$THEIRS" | grep -v '^macos/' | grep . | sort -u | comm -23 - <(printf '%s\n' "$CLAIMED") || true)"

count() { printf '%s\n' "$1" | grep -c . || true; }

if [ "$AHEAD" -eq 0 ]; then
	if [ "$FORMAT" = markdown ]; then
		echo "Up to date with \`$REF\` at \`$(git rev-parse --short "$MB")\`."
	else
		echo "Up to date with $REF."
	fi
	exit 0
fi

# The single quotes below are deliberate: the backticks and $-free markdown in
# these format strings are literal output, not shell expansion.
# shellcheck disable=SC2016
section() { # title, list, note
	local n; n="$(count "$2")"
	[ "$n" -eq 0 ] && return 0
	if [ "$FORMAT" = markdown ]; then
		printf '\n### %s (%s)\n\n%s\n\n<details><summary>files</summary>\n\n```\n%s\n```\n\n</details>\n' \
			"$1" "$n" "$3" "$2"
	else
		printf '\n%s (%s)\n  %s\n\n' "$1" "$n" "$3"
		printf '%s\n' "$2" | sed 's/^/    /'
	fi
}

# shellcheck disable=SC2016
if [ "$FORMAT" = markdown ]; then
	printf '%s new upstream commit(s) on `%s` since `%s`.\n' \
		"$AHEAD" "$REF" "$(git rev-parse --short "$MB")"
else
	printf '%s new upstream commit(s) on %s since %s.\n' \
		"$AHEAD" "$REF" "$(git rev-parse --short "$MB")"
fi

section "Review before merging — upstream changed files this fork also changed" \
	"$REVIEW" \
	"Content conflicts land here. Read the upstream intent, then re-apply it on top of the fork's structure instead of taking either side wholesale."

section "Deleted here, changed upstream" \
	"$DELETED_HIT" \
	"Git will stop with a delete/modify conflict. Keeping them deleted is almost always right; confirm the change is not something the fork actually wants."

section "Clean merge, still worth reading — macOS code the fork did not touch" \
	"$MACOS_NEW" \
	"These merge without complaint but land in the app this fork restructured. Check for native-tab paths and single-window assumptions."

section "Core and tooling — expected to merge cleanly" \
	"$REST" \
	"Zig core, packaging and docs. The fork barely touches these."

# shellcheck disable=SC2016
if [ "$FORMAT" = markdown ]; then
	printf '\n### Commits\n\n```\n%s\n```\n' "$(git log -n 60 --oneline --no-decorate "$MB..$REF")"
	[ "$AHEAD" -gt 60 ] && printf '\n_Showing the newest 60 of %s._\n' "$AHEAD"
	printf '\nTo start: `git fetch upstream && git merge %s`\n' "$REF"
else
	printf '\nCommits:\n'
	git log -n 40 --oneline --no-decorate "$MB..$REF" | sed 's/^/    /'
	printf '\nTo start: git merge %s\n' "$REF"
fi

if [ "$DO_MERGE" = yes ]; then
	printf '\n--- merging ---\n'
	# No --no-commit: stopping at conflicts is the point, and a clean merge
	# should be a real commit that records the sync.
	git merge --no-ff "$REF" || {
		printf '\nMerge stopped with conflicts. Resolve, then verify with:\n'
		printf '  ./macos/scripts/native-tab-audit.sh\n'
		printf '  ./macos/build.nu --configuration Debug --action test\n'
		exit 1
	}
	printf '\nMerged. Verify before pushing:\n'
	printf '  ./macos/scripts/native-tab-audit.sh\n'
	printf '  ./macos/build.nu --configuration Debug --action test\n'
fi
