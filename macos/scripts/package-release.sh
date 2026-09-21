#!/usr/bin/env bash
#
# Stamp, sign and package a built Chostty.app into a DMG and a zip.
#
# The signature is ad-hoc by default so credential-less builds (CI, local
# test packaging) stay reproducible. For direct distribution, set:
#
#   CHOSTTY_SIGNING_IDENTITY  "Developer ID Application: NAME (TEAMID)"
#   CHOSTTY_NOTARY_PROFILE    a stored `notarytool` keychain profile
#                             (xcrun notarytool store-credentials ...)
#
# With both set, the app is signed with a hardened runtime and a secure
# timestamp, notarized and stapled, the zip is rebuilt from the stapled app,
# and the DMG is signed, notarized and stapled as well, so every artifact
# carries offline-valid proof. A Developer ID signature without a notary
# profile is refused: Gatekeeper blocks that harder than an ad-hoc build.
# Ad-hoc artifacts are quarantined on download; say so in the release notes
# rather than shipping a bundle that appears broken.
#
# Usage:
#   macos/scripts/package-release.sh --app <path> --version <v> [--out <dir>]
#                                    [--commit <sha>] [--build <n>]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LICENSE_SOURCE="$REPO_ROOT/LICENSE"
NOTICES_SOURCE="$REPO_ROOT/THIRD-PARTY-NOTICES.md"
UPDATE_FEED_URL="https://github.com/chlee1001/chostty/releases/latest/download/appcast.xml"
UPDATE_DOWNLOAD_PREFIX="https://github.com/chlee1001/chostty/releases/download"

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
[ -f "$NOTICES_SOURCE" ] || { echo "missing third-party notices: $NOTICES_SOURCE" >&2; exit 1; }

COMMIT="${COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BUILD="${BUILD:-1}"
PLIST="$APP/Contents/Info.plist"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
rm -f "$OUT/appcast.xml"

# --- Stamp -----------------------------------------------------------------

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :GhosttyCommit $COMMIT" "$PLIST" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Add :GhosttyCommit string $COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks true" "$PLIST" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SURequireSignedFeed true" "$PLIST" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SUVerifyUpdateBeforeExtraction true" "$PLIST" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$PLIST"

# Fail closed if the packaged app no longer advertises this fork's feed.
[ "$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST" 2>/dev/null)" = "$UPDATE_FEED_URL" ] || {
	echo "refusing to package: SUFeedURL does not match $UPDATE_FEED_URL" >&2
	exit 1
}
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" 2>/dev/null |
	grep -qE '^[A-Za-z0-9+/]+={0,2}$' || {
	echo "refusing to package: SUPublicEDKey missing or malformed" >&2
	exit 1
}

# Every distributed copy must carry the upstream MIT notice. Install it before
# signing so both the zip and DMG contain the exact repository LICENSE.
LICENSE_DEST="$APP/Contents/Resources/LICENSE"
install -m 0644 "$LICENSE_SOURCE" "$LICENSE_DEST"
cmp -s "$LICENSE_SOURCE" "$LICENSE_DEST" || {
	echo "refusing to package: bundled LICENSE does not match repository LICENSE" >&2
	exit 1
}
NOTICES_DEST="$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
install -m 0644 "$NOTICES_SOURCE" "$NOTICES_DEST"
cmp -s "$NOTICES_SOURCE" "$NOTICES_DEST" || {
	echo "refusing to package: bundled THIRD-PARTY-NOTICES does not match repository original" >&2
	exit 1
}

# --- Sign ------------------------------------------------------------------

# "-" (the default) keeps the historical ad-hoc signature; a Developer ID
# identity switches every signature to a secure timestamp plus hardened
# runtime, which notarization requires.
IDENTITY="${CHOSTTY_SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${CHOSTTY_NOTARY_PROFILE:-}"
ENTITLEMENTS="$REPO_ROOT/macos/Ghostty.entitlements"
GENERATE_APPCAST="${CHOSTTY_SPARKLE_BIN:-$HOME/.local/share/chostty-sparkle/bin}/generate_appcast"
ED_KEY_FILE="${CHOSTTY_SPARKLE_ED_KEY_FILE:-$HOME/.local/share/chostty-sparkle/eddsa-private.key}"
if [ "$IDENTITY" != "-" ] && [ -z "$NOTARY_PROFILE" ]; then
	echo "refusing to sign: CHOSTTY_SIGNING_IDENTITY is set but CHOSTTY_NOTARY_PROFILE is not" >&2
	echo "store one with: xcrun notarytool store-credentials <profile>" >&2
	exit 1
fi
if [ "$IDENTITY" != "-" ] && { [ ! -x "$GENERATE_APPCAST" ] || [ ! -f "$ED_KEY_FILE" ]; }; then
	echo "signed releases need Sparkle's generate_appcast and the EdDSA key" >&2
	echo "got: $GENERATE_APPCAST / $ED_KEY_FILE" >&2
	exit 1
fi
if [ "$IDENTITY" != "-" ]; then
	[ "$(stat -f %Su "$ED_KEY_FILE")" = "$(id -un)" ] &&
		[ "$(stat -f %Lp "$ED_KEY_FILE")" = 600 ] || {
		echo "Sparkle EdDSA key must be owned by the current user with mode 0600" >&2
		exit 1
	}
	BUNDLE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST")"
	PRIVATE_KEY_PUBLIC_KEY="$("$SCRIPT_DIR/sparkle-public-key.swift" "$ED_KEY_FILE")"
	[ "$BUNDLE_PUBLIC_KEY" = "$PRIVATE_KEY_PUBLIC_KEY" ] || {
		echo "Sparkle private key does not match SUPublicEDKey" >&2
		exit 1
	}
fi

# Inside out. --deep is deprecated and skips some nested code, so walk the
# known nested bundles explicitly and let a new one show up as a verify
# failure rather than shipping unsigned.
# Absent nested bundles are fine; a codesign that runs and fails is not. The
# earlier form sent both down the same `|| true` and hid the error output, so a
# nested bundle that could not be signed only surfaced later as a confusing
# --verify failure.
sign() {
	[ -e "$1" ] || return 0
	if [ "$IDENTITY" = "-" ]; then
		codesign --force --timestamp=none --sign - "$1" || {
			echo "failed to sign nested bundle: $1" >&2
			exit 1
		}
	else
		codesign --force --timestamp --options runtime --sign "$IDENTITY" "$1" || {
			echo "failed to sign nested bundle: $1" >&2
			exit 1
		}
	fi
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

if [ "$IDENTITY" = "-" ]; then
	codesign --force --timestamp=none --sign - \
		--entitlements "$ENTITLEMENTS" "$APP"
	codesign --verify --deep --strict "$APP"
	echo "signed ad-hoc: $(codesign -dv "$APP" 2>&1 | grep -c 'Signature=adhoc') (1 = ad-hoc)"
else
	codesign --force --timestamp --options runtime --sign "$IDENTITY" \
		--entitlements "$ENTITLEMENTS" "$APP"
	codesign --verify --deep --strict "$APP"
	spctl --assess --type execute "$APP" ||
		echo "warning: Gatekeeper assessment failed (expected before notarization)" >&2
	echo "signed: $IDENTITY"
fi

# --- Package ---------------------------------------------------------------

ZIP="$OUT/Chostty-$VERSION-macos-universal.zip"
ARCHIVE_LICENSE="$(basename "$APP")/Contents/Resources/LICENSE"
ARCHIVE_NOTICES="$(basename "$APP")/Contents/Resources/THIRD-PARTY-NOTICES.md"

build_zip() {
	rm -f "$ZIP"
	(cd "$(dirname "$APP")" && zip -9 -r -q --symlinks "$ZIP" "$(basename "$APP")")
}
verify_zip() {
	unzip -p "$ZIP" "$ARCHIVE_LICENSE" | cmp -s - "$LICENSE_SOURCE" || {
		echo "refusing to package: zip is missing the repository LICENSE" >&2
		exit 1
	}
	unzip -p "$ZIP" "$ARCHIVE_NOTICES" | cmp -s - "$NOTICES_SOURCE" || {
		echo "refusing to package: zip is missing the repository THIRD-PARTY-NOTICES" >&2
		exit 1
	}
}
build_zip
verify_zip

# --- Notarize ---------------------------------------------------------------

# Submit the zip, staple the ticket onto the app, then rebuild the zip from
# the stapled bundle; the DMG below is created from that same stapled app.
if [ "$IDENTITY" != "-" ]; then
	xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$APP"
	build_zip
	verify_zip
	spctl --assess --type execute "$APP" || {
		echo "refusing to package: stapled app fails Gatekeeper assessment" >&2
		exit 1
	}
	echo "notarized and stapled: $IDENTITY"
fi

DMG="$OUT/Chostty-$VERSION.dmg"
STAGE="$(mktemp -d)"
APPCAST_DIR=""
trap 'rm -rf "$STAGE" "$APPCAST_DIR"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Chostty $VERSION" -srcfolder "$STAGE" \
	-ov -format UDZO -quiet "$DMG"

if [ "$IDENTITY" != "-" ]; then
	codesign --force --timestamp --sign "$IDENTITY" "$DMG"
	xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$DMG"
fi

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

# --- Appcast ---------------------------------------------------------------

if [ "$IDENTITY" != "-" ]; then
	APPCAST_DIR="$(mktemp -d)"
	cp "$ZIP" "$APPCAST_DIR/"
	"$GENERATE_APPCAST" \
		--ed-key-file "$ED_KEY_FILE" \
		--download-url-prefix "$UPDATE_DOWNLOAD_PREFIX/v$VERSION/" \
		--maximum-versions 1 \
		-o "$OUT/appcast.xml" \
		"$APPCAST_DIR"
	rm -rf "$APPCAST_DIR"
	APPCAST_DIR=""
	xmllint --noout "$OUT/appcast.xml"
	grep -q "<sparkle:version>$BUILD</sparkle:version>" "$OUT/appcast.xml" || {
		echo "generated appcast has the wrong sparkle:version" >&2
		exit 1
	}
	grep -Eq 'sparkle:edSignature="[^"]+"' "$OUT/appcast.xml" || {
		echo "generated appcast has no EdDSA signature" >&2
		exit 1
	}
	if ! grep -q '<!-- sparkle-signatures:' "$OUT/appcast.xml" ||
		! grep -Eq '^edSignature: [A-Za-z0-9+/]+={0,2}$' "$OUT/appcast.xml"; then
		echo "generated appcast has no feed signature" >&2
		exit 1
	fi
	echo "appcast: $OUT/appcast.xml"
fi
