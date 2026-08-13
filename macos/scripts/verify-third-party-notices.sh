#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
NOTICES="$REPO_ROOT/THIRD-PARTY-NOTICES.md"
RESOLVED="$REPO_ROOT/macos/Ghostty.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [ "${1:-}" = "--checkouts" ]; then
    [ "$#" -eq 2 ] || { echo "usage: $0 [--checkouts <dir>]" >&2; exit 2; }
    CHECKOUTS=$2
else
    CHECKOUTS=""
    for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/Ghostty-*/SourcePackages/checkouts; do
        [ -d "$candidate/swift-markdown-ui" ] || continue
        CHECKOUTS=$candidate
    done
    [ -n "$CHECKOUTS" ] || { echo "unable to locate Ghostty SourcePackages checkouts; pass --checkouts" >&2; exit 1; }
fi

python3 - "$NOTICES" "$RESOLVED" "$CHECKOUTS" <<'PY'
import json
import pathlib
import re
import sys

notices_path, resolved_path, checkouts_path = map(pathlib.Path, sys.argv[1:])
notices = notices_path.read_text(encoding="utf-8")
pins = {pin["identity"]: pin for pin in json.loads(resolved_path.read_text())["pins"]}
expected = {
    "swift-markdown-ui": "LICENSE",
    "networkimage": "LICENSE",
    "swift-cmark": "COPYING",
    "highlighterswift": "LICENCE.md",
    "yams": "LICENSE",
    "tomldecoder": "LICENSE.md",
}

headings = re.findall(r"^## ([^ ]+) ([^\n]+)$", notices, flags=re.MULTILINE)
actual_identities = {identity for identity, _ in headings}
if actual_identities != set(expected):
    raise SystemExit(f"unexpected notice sections: {sorted(actual_identities)}")

for identity, filename in expected.items():
    version = pins[identity]["state"]["version"]
    pattern = rf"^## {re.escape(identity)} {re.escape(version)}\n.*?^```text\n(.*?)^```$"
    match = re.search(pattern, notices, flags=re.MULTILINE | re.DOTALL)
    if not match:
        raise SystemExit(f"missing notice section: {identity} {version}")
    embedded = match.group(1).encode("utf-8")
    checkout_names = {
        "networkimage": "NetworkImage",
        "highlighterswift": "HighlighterSwift",
        "tomldecoder": "TOMLDecoder",
        "yams": "Yams",
    }
    upstream = (checkouts_path / checkout_names.get(identity, identity) / filename).read_bytes()
    if embedded != upstream:
        raise SystemExit(f"notice differs from upstream license: {identity}")
    print(f"verified {identity} {version}")
PY
