#!/usr/bin/env bash
#
# Build a universal Chostty release locally. With --publish, tag the current
# origin/main commit and upload the DMG and zip to GitHub Releases.
#
# Usage:
#   scripts/release-local.sh --version <semver> [--build <n>] [--out <dir>]
#                            [--publish]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=""
BUILD="1"
OUT="dist-local"
PUBLISH="no"

usage() {
  sed -n '2,9p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --publish) PUBLISH="yes"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$VERSION" ] || { echo "--version is required" >&2; exit 2; }
printf '%s\n' "$VERSION" | grep -Eq \
  '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' || {
  echo "not a semantic version: $VERSION" >&2
  exit 2
}
printf '%s\n' "$BUILD" | grep -Eq '^[0-9]+([.][0-9]+){0,2}$' || {
  echo "not a valid CFBundleVersion: $BUILD" >&2
  exit 2
}

cd "$REPO_ROOT"

# Untracked files do not affect the release commit, but tracked edits would make
# the bundle impossible to reproduce from its stamped SHA.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "tracked changes present; commit or discard them before releasing" >&2
  exit 1
fi

for command in zig xcodebuild codesign hdiutil shasum; do
  command -v "$command" >/dev/null || {
    echo "missing command: $command" >&2
    exit 1
  }
done

COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="$(git rev-parse --short HEAD)"
TAG="v$VERSION"

if [ "$PUBLISH" = yes ]; then
  command -v gh >/dev/null || { echo "missing command: gh" >&2; exit 1; }
  gh auth status >/dev/null
  git fetch --quiet origin main --tags
  [ "$COMMIT" = "$(git rev-parse origin/main)" ] || {
    echo "--publish requires HEAD to equal origin/main" >&2
    exit 1
  }
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "GitHub release $TAG already exists" >&2
    exit 1
  fi
fi

printf 'Building Chostty %s from %s\n' "$VERSION" "$SHORT_COMMIT"

zig build \
  -Doptimize=ReleaseFast \
  -Demit-macos-app=false \
  -Dversion-string="$VERSION"

rm -rf macos/build/Release
env -i "HOME=$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  xcodebuild \
    -project macos/Ghostty.xcodeproj \
    -scheme Ghostty \
    -configuration Release \
    SYMROOT="$REPO_ROOT/macos/build" \
    build

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
rm -f \
  "$OUT/Chostty-$VERSION.dmg" \
  "$OUT/Chostty-$VERSION-macos-universal.zip" \
  "$OUT/SHA256SUMS-$VERSION"

./macos/scripts/package-release.sh \
  --app macos/build/Release/Chostty.app \
  --version "$VERSION" \
  --commit "$SHORT_COMMIT" \
  --build "$BUILD" \
  --out "$OUT"

DMG="$OUT/Chostty-$VERSION.dmg"
ZIP="$OUT/Chostty-$VERSION-macos-universal.zip"
CHECKSUMS="$OUT/SHA256SUMS-$VERSION"
APP="macos/build/Release/Chostty.app"

codesign --verify --deep --strict "$APP"
hdiutil verify -quiet "$DMG"
(
  cd "$OUT"
  shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" \
    > "$(basename "$CHECKSUMS")"
)

printf '\nVerified local release:\n'
cat "$CHECKSUMS"

[ "$PUBLISH" = yes ] || exit 0

if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG"
else
  if git rev-parse "$TAG^{commit}" >/dev/null 2>&1; then
    [ "$(git rev-parse "$TAG^{commit}")" = "$COMMIT" ] || {
      echo "$TAG already points at another commit" >&2
      exit 1
    }
  else
    git tag -a "$TAG" -m "Chostty $VERSION"
  fi
  git push origin "$TAG"
fi

[ "$(git rev-parse "$TAG^{commit}")" = "$COMMIT" ] || {
  echo "$TAG does not point at HEAD" >&2
  exit 1
}

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "GitHub release $TAG already exists" >&2
  exit 1
fi

INSTALL_NOTES="$(cat <<'NOTES'
## Install

Open the DMG and drag Chostty to Applications, then run:

```
xattr -cr /Applications/Chostty.app
```

This is required because the app is ad-hoc signed and cannot be notarized.
There is no auto-updater. Universal binary, macOS 13 and later.
NOTES
)"

gh release create "$TAG" "$DMG" "$ZIP" "$CHECKSUMS" \
  --verify-tag \
  --fail-on-no-commits \
  --title "Chostty $VERSION" \
  --generate-notes \
  --notes "$INSTALL_NOTES"

printf 'Published %s\n' "$TAG"
