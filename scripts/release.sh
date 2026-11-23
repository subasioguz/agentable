#!/bin/bash
# Builds Agentable.app for Apple silicon and Intel, signs it with Developer ID (hardened runtime),
# notarizes and staples it, and zips it for a GitHub release.
#
#   scripts/release.sh 0.1.0
#
# Needs a "Developer ID Application" certificate in the keychain and a notarytool profile, saved
# once in Terminal with: xcrun notarytool store-credentials agentable
# NOTARY_PROFILE and SIGN_IDENTITY override them. The zip and its checksum land in .build/release-<version>.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROFILE=${NOTARY_PROFILE:-agentable}
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in the keychain" >&2; exit 1; }
cd "$ROOT"

# Fail before the build if the notary profile is missing.
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null

APP=$(AGENTABLE_VERSION="$VERSION" ARCHS="arm64 x86_64" SIGN_IDENTITY="$IDENTITY" \
    scripts/bundle-app.sh release | tail -1)
codesign --verify --strict --deep "$APP"
lipo -archs "$APP/Contents/MacOS/Agentable"
lipo -archs "$APP/Contents/Helpers/agentable"

OUT="$ROOT/.build/release-$VERSION"
ZIP="$OUT/Agentable-$VERSION.zip"
rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$ZIP"

RESULT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json)
echo "$RESULT"
if ! grep -q '"status":"Accepted"' <<<"$RESULT"; then
    ID=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' <<<"$RESULT")
    [ -z "$ID" ] || xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2
    echo "Notarization was not accepted" >&2
    exit 1
fi

# Staple the ticket so the app opens offline too, then zip the stapled app.
xcrun stapler staple "$APP"
rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256")
echo "$ZIP"
