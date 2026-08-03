#!/usr/bin/env bash
#
# Stamp, sign and package a built Chostty.app into a DMG and a zip.
#
# This fork has no Apple Developer ID, so the signature is ad-hoc. That is not
# a shortcut around notarization — it is the only option, and it has a visible
# consequence: macOS quarantines the download and refuses to open it until the
# user clears the attribute. Say so in the release notes rather than shipping a
# bundle that appears broken.
#
# Usage:
#   macos/scripts/package-release.sh --app <path> --version <v> [--out <dir>]
#                                    [--commit <sha>] [--build <n>]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LICENSE_SOURCE="$REPO_ROOT/LICENSE"

APP=""
VERSION=""
OUT="dist-release"
COMMIT=""
BUILD=""

while [ $# -gt 0 ]; do
	case "$1" in
	--app) APP="$2"; shift 2 ;;
	--version) VERSION="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	--commit) COMMIT="$2"; shift 2 ;;
	--build) BUILD="$2"; shift 2 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

[ -n "$APP" ] || { echo "--app is required" >&2; exit 2; }
[ -n "$VERSION" ] || { echo "--version is required" >&2; exit 2; }
[ -d "$APP" ] || { echo "no app bundle at $APP" >&2; exit 1; }
[ -f "$LICENSE_SOURCE" ] || { echo "missing license: $LICENSE_SOURCE" >&2; exit 1; }

COMMIT="${COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BUILD="${BUILD:-1}"
PLIST="$APP/Contents/Info.plist"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# --- Stamp -----------------------------------------------------------------

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :GhosttyCommit $COMMIT" "$PLIST" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Add :GhosttyCommit string $COMMIT" "$PLIST"

# Sparkle is disabled in this fork and there is no appcast or signing key to
# point it at. Assert the packaged bundle cannot advertise an update channel
# rather than trusting that the source-level switch stayed off.
/usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PLIST" 2>/dev/null || true
if /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" >/dev/null 2>&1; then
	echo "refusing to package: SUPublicEDKey is present, so the disabled updater is still armed" >&2
	exit 1
fi

# Every distributed copy must carry the upstream MIT notice. Install it before
# signing so both the zip and DMG contain the exact repository LICENSE.
LICENSE_DEST="$APP/Contents/Resources/LICENSE"
install -m 0644 "$LICENSE_SOURCE" "$LICENSE_DEST"
cmp -s "$LICENSE_SOURCE" "$LICENSE_DEST" || {
	echo "refusing to package: bundled LICENSE does not match repository LICENSE" >&2
	exit 1
}

# --- Sign ------------------------------------------------------------------

# Inside out. --deep is deprecated and skips some nested code, so walk the
# known nested bundles explicitly and let a new one show up as a verify
# failure rather than shipping unsigned.
# Absent nested bundles are fine; a codesign that runs and fails is not. The
# earlier form sent both down the same `|| true` and hid the error output, so a
# nested bundle that could not be signed only surfaced later as a confusing
# --verify failure.
sign() {
	[ -e "$1" ] || return 0
	codesign --force --timestamp=none --sign - "$1" || {
		echo "failed to sign nested bundle: $1" >&2
		exit 1
	}
}

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
	for v in "$SPARKLE"/Versions/*/; do
		sign "$v/XPCServices/Downloader.xpc"
		sign "$v/XPCServices/Installer.xpc"
		sign "$v/Autoupdate"
		sign "$v/Updater.app"
	done
	sign "$SPARKLE"
fi
sign "$APP/Contents/PlugIns/DockTilePlugin.plugin"

codesign --force --sign - --entitlements macos/Ghostty.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "signed ad-hoc: $(codesign -dv "$APP" 2>&1 | grep -c 'Signature=adhoc') (1 = ad-hoc)"

# --- Package ---------------------------------------------------------------

ZIP="$OUT/Chostty-$VERSION-macos-universal.zip"
rm -f "$ZIP"
(cd "$(dirname "$APP")" && zip -9 -r -q --symlinks "$ZIP" "$(basename "$APP")")
ARCHIVE_LICENSE="$(basename "$APP")/Contents/Resources/LICENSE"
unzip -p "$ZIP" "$ARCHIVE_LICENSE" | cmp -s - "$LICENSE_SOURCE" || {
	echo "refusing to package: zip is missing the repository LICENSE" >&2
	exit 1
}

DMG="$OUT/Chostty-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Chostty $VERSION" -srcfolder "$STAGE" \
	-ov -format UDZO -quiet "$DMG"

# The universal slice is the whole point of building on macOS; a runner that
# silently produced a single-architecture binary would still package fine.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/chostty")"
case "$ARCHS" in
*arm64*x86_64* | *x86_64*arm64*) ;;
*) echo "refusing to publish: expected a universal binary, got '$ARCHS'" >&2; exit 1 ;;
esac

echo
echo "architectures: $ARCHS"
ls -lh "$DMG" "$ZIP"
