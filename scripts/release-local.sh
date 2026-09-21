#!/usr/bin/env bash
#
# Build a universal Chostty release locally. With --publish, tag the current
# origin/main commit and upload the DMG and zip to GitHub Releases.
#
# Usage:
#   scripts/release-local.sh --version <semver> [--build <n>] [--out <dir>]
#                            [--publish]
#   scripts/release-local.sh --publish-next
#
# Signed, notarized releases need both (ad-hoc otherwise; see
# macos/scripts/package-release.sh):
#   CHOSTTY_SIGNING_IDENTITY  "Developer ID Application: NAME (TEAMID)"
#   CHOSTTY_NOTARY_PROFILE    stored `notarytool` keychain profile
# Publishing a signed release also generates the Sparkle appcast with:
#   CHOSTTY_SPARKLE_BIN         dir holding Sparkle's `generate_appcast`
#   CHOSTTY_SPARKLE_ED_KEY_FILE ed25519 private key file for the appcast
# Export them per shell, or put them once in a gitignored .release-env at
# the repo root; this script sources that file when it exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Per-machine signing defaults so a signed release needs no prior export.
# The file is gitignored; write assignments with ${VAR:=...} so a value
# exported in the calling shell still wins.
[ -f "$REPO_ROOT/.release-env" ] && . "$REPO_ROOT/.release-env"

VERSION=""
BUILD=""
OUT="dist-local"
PUBLISH="no"
PUBLISH_NEXT="no"

usage() {
  sed -n '2,16p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --publish) PUBLISH="yes"; shift ;;
    --publish-next) PUBLISH="yes"; PUBLISH_NEXT="yes"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"

# Untracked files do not affect the release commit, but tracked edits would make
# the bundle impossible to reproduce from its stamped SHA.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "tracked changes present; commit or discard them before releasing" >&2
  exit 1
fi

latest_release_tag() {
  gh release list --limit 100 \
    --json tagName,isDraft,isPrerelease,publishedAt \
    --jq '[.[] | select(
      .isDraft == false and
      .isPrerelease == false and
      (.tagName | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
    )] | sort_by(.publishedAt) | last | .tagName // empty'
}

LATEST_RELEASE_TAG=""
if [ "$PUBLISH" = yes ]; then
  command -v gh >/dev/null || { echo "missing command: gh" >&2; exit 1; }
  gh auth status >/dev/null
  git fetch --quiet origin main --tags

  if [ "$PUBLISH_NEXT" = yes ]; then
    [ -z "$VERSION" ] || {
      echo "--publish-next cannot be combined with --version" >&2
      exit 2
    }
    git switch main
    git merge --ff-only origin/main
    LATEST_RELEASE_TAG="$(latest_release_tag)"
    if [ -n "$LATEST_RELEASE_TAG" ]; then
      current="${LATEST_RELEASE_TAG#v}"
      major="${current%%.*}"
      remainder="${current#*.}"
      minor="${remainder%%.*}"
      patch="${remainder#*.}"
      VERSION="$major.$minor.$((patch + 1))"
    else
      VERSION="0.1.0"
    fi
  fi
fi

[ -n "$VERSION" ] || { echo "--version is required" >&2; exit 2; }
printf '%s\n' "$VERSION" | grep -Eq \
  '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' || {
  echo "not a semantic version: $VERSION" >&2
  exit 2
}
if [ -z "$BUILD" ]; then
  case "$VERSION" in
    *[-+]*)
      echo "--build is required for prerelease or build-metadata versions" >&2
      exit 2
      ;;
    *) BUILD="$VERSION" ;;
  esac
fi
printf '%s\n' "$BUILD" | grep -Eq '^[0-9]+([.][0-9]+){0,2}$' || {
  echo "not a valid CFBundleVersion: $BUILD" >&2
  exit 2
}
if [ "$PUBLISH" = yes ]; then
  case "$VERSION" in
    *[-+]*) ;;
    *)
      [ "$BUILD" = "$VERSION" ] || {
        echo "stable publishes require CFBundleVersion to equal $VERSION" >&2
        exit 2
      }
      ;;
  esac
fi

for command in zig xcodebuild codesign hdiutil shasum; do
  command -v "$command" >/dev/null || {
    echo "missing command: $command" >&2
    exit 1
  }
done

# Fail before the multi-minute build, not after it: package-release.sh would
# refuse a Developer ID signature with no notary profile once the app exists.
if [ -n "${CHOSTTY_SIGNING_IDENTITY:-}" ] && [ -z "${CHOSTTY_NOTARY_PROFILE:-}" ]; then
  echo "CHOSTTY_SIGNING_IDENTITY is set but CHOSTTY_NOTARY_PROFILE is not" >&2
  echo "store one with: xcrun notarytool store-credentials <profile>" >&2
  exit 1
fi

if [ "$PUBLISH" = yes ] && [ -z "${CHOSTTY_SIGNING_IDENTITY:-}" ]; then
  echo "--publish requires CHOSTTY_SIGNING_IDENTITY" >&2
  exit 1
fi

GENERATE_APPCAST="${CHOSTTY_SPARKLE_BIN:-$HOME/.local/share/chostty-sparkle/bin}/generate_appcast"
ED_KEY_FILE="${CHOSTTY_SPARKLE_ED_KEY_FILE:-$HOME/.local/share/chostty-sparkle/eddsa-private.key}"
if [ "$PUBLISH" = yes ] &&
  { [ ! -x "$GENERATE_APPCAST" ] || [ ! -f "$ED_KEY_FILE" ]; }; then
  echo "--publish needs Sparkle's generate_appcast and the EdDSA key" >&2
  echo "got: $GENERATE_APPCAST / $ED_KEY_FILE" >&2
  exit 1
fi

COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="$(git rev-parse --short HEAD)"
TAG="v$VERSION"

if [ "$PUBLISH" = yes ]; then
  [ "$COMMIT" = "$(git rev-parse origin/main)" ] || {
    echo "--publish requires HEAD to equal origin/main" >&2
    exit 1
  }
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "GitHub release $TAG already exists" >&2
    exit 1
  fi
  [ -n "$LATEST_RELEASE_TAG" ] || LATEST_RELEASE_TAG="$(latest_release_tag)"
  if [ -n "$LATEST_RELEASE_TAG" ]; then
    git fetch --quiet origin \
      "refs/tags/$LATEST_RELEASE_TAG:refs/tags/$LATEST_RELEASE_TAG"
    git merge-base --is-ancestor "$LATEST_RELEASE_TAG^{commit}" "$COMMIT" || {
      echo "$LATEST_RELEASE_TAG is not an ancestor of origin/main" >&2
      exit 1
    }
    [ "$(git rev-list --count "$LATEST_RELEASE_TAG..$COMMIT")" -gt 0 ] || {
      echo "no commits since $LATEST_RELEASE_TAG" >&2
      exit 1
    }
    if [ "$PUBLISH_NEXT" = yes ] && git diff --quiet \
      "$LATEST_RELEASE_TAG" "$COMMIT" -- \
      build.zig build.zig.zon include pkg src vendor \
      macos/Sources macos/GhosttyUITests macos/Ghostty.xcodeproj \
      macos/Ghostty-Info.plist macos/Ghostty.sdef macos/build.nu \
      macos/*.entitlements macos/scripts/package-release.sh \
      LICENSE THIRD-PARTY-NOTICES.md; then
      echo "no release inputs changed since $LATEST_RELEASE_TAG" >&2
      exit 1
    fi
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

Open the DMG and drag Chostty to Applications. The app is Developer ID
signed and notarized, so macOS opens it without any quarantine workaround.
In-app updates are enabled (Check for Updates… or automatic checks) and
are served from this repository's releases. Universal binary, macOS 13+.
NOTES
)"

gh release create "$TAG" "$DMG" "$ZIP" "$CHECKSUMS" "$OUT/appcast.xml" \
  --verify-tag \
  --fail-on-no-commits \
  --title "Chostty $VERSION" \
  --generate-notes \
  --notes "$INSTALL_NOTES"

printf 'Published %s\n' "$TAG"
