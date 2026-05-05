#!/usr/bin/env bash
# Peek release pipeline:
#   archive → notarize app → staple → DMG → notarize DMG → staple → Sparkle-sign → appcast.xml entry
#
# Prerequisites:
#   - notarytool keychain profile named "AC_PASSWORD" (xcrun notarytool store-credentials AC_PASSWORD …)
#   - Sparkle EdDSA private key in the user's Keychain (created by sparkle-tools/generate_keys)
#   - "Developer ID Application: Fabian de Groot (9U32932L68)" cert installed
#
# Usage:
#   ./release.sh                # uses MARKETING_VERSION from the .xcodeproj
#   ./release.sh 1.3            # bumps MARKETING_VERSION to 1.3, increments CFBundleVersion

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
RELEASES="$ROOT/Releases"
ARTIFACTS="$RELEASES/artifacts"
TOOLS="$RELEASES/sparkle-tools"
KEYCHAIN_PROFILE="AC_PASSWORD"
TEAM_ID="9U32932L68"
SCHEME="Peek"
PROJECT="Peek.xcodeproj"
APP_NAME="Peek"
BUNDLE_ID="io.degroot.Peek"
GH_REPO="fbdegroot/Peek"
FEED_URL="https://raw.githubusercontent.com/${GH_REPO}/main/Releases/appcast.xml"

mkdir -p "$ARTIFACTS"

# --- Version handling -------------------------------------------------------

PLIST="$ROOT/Peek/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
write_plist() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST"; }

if [[ $# -ge 1 ]]; then
    VERSION="$1"
    OLD_BUILD=$(read_plist CFBundleVersion)
    NEW_BUILD=$((OLD_BUILD + 1))
    write_plist CFBundleShortVersionString "$VERSION"
    write_plist CFBundleVersion "$NEW_BUILD"
    echo "→ Bumped to $VERSION (build $NEW_BUILD)"
else
    VERSION=$(read_plist CFBundleShortVersionString)
    NEW_BUILD=$(read_plist CFBundleVersion)
    echo "→ Releasing $VERSION (build $NEW_BUILD)"
fi

DMG_NAME="Peek-${VERSION}.dmg"
DMG_PATH="$RELEASES/$DMG_NAME"
ARCHIVE_PATH="$ARTIFACTS/Peek.xcarchive"
EXPORT_PATH="$ARTIFACTS/export"
APP_PATH="$EXPORT_PATH/${APP_NAME}.app"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

# --- Build & archive --------------------------------------------------------

echo "→ Archiving"
ARCHIVE_LOG="$ARTIFACTS/archive.log"
if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=macOS" \
        archive >"$ARCHIVE_LOG" 2>&1; then
    echo "✗ Archive failed. Last 60 log lines:"
    tail -n 60 "$ARCHIVE_LOG"
    exit 1
fi

# --- Export the .app --------------------------------------------------------

EXPORT_OPTIONS="$ARTIFACTS/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

echo "→ Exporting .app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" >/dev/null

# --- Notarize the .app ------------------------------------------------------

APP_ZIP="$ARTIFACTS/${APP_NAME}.zip"
echo "→ Zipping .app for notarization"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

echo "→ Submitting .app to notary"
xcrun notarytool submit "$APP_ZIP" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "→ Stapling .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl -a -vvv -t exec "$APP_PATH"

# --- Build DMG --------------------------------------------------------------

DMG_STAGE="$ARTIFACTS/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

rm -f "$DMG_PATH"
echo "→ Creating DMG"
hdiutil create \
    -volname "Peek ${VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

# --- Notarize DMG -----------------------------------------------------------

echo "→ Submitting DMG to notary"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "→ Stapling DMG"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# --- Sparkle sign + appcast entry ------------------------------------------

echo "→ Signing DMG with Sparkle EdDSA key"
SIGN_OUTPUT=$("$TOOLS/sign_update" "$DMG_PATH")
# sign_update prints e.g. `sparkle:edSignature="..." length="..."`
ED_SIG=$(printf '%s' "$SIGN_OUTPUT" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
DMG_LENGTH=$(printf '%s' "$SIGN_OUTPUT" | sed -E 's/.*length="([^"]+)".*/\1/')
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

DOWNLOAD_URL="https://github.com/${GH_REPO}/releases/download/v${VERSION}/${DMG_NAME}"

echo "→ Adding entry to appcast.xml"
APPCAST="$RELEASES/appcast.xml"
ENTRY=$(cat <<EOF
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${NEW_BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <enclosure
                url="${DOWNLOAD_URL}"
                length="${DMG_LENGTH}"
                type="application/octet-stream"
                sparkle:edSignature="${ED_SIG}"/>
        </item>
EOF
)

if [[ ! -f "$APPCAST" ]]; then
    cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Peek</title>
        <link>${FEED_URL}</link>
        <description>Latest Peek releases</description>
        <language>en</language>
${ENTRY}
    </channel>
</rss>
EOF
else
    # Insert new <item> right after the <language> tag
    python3 - "$APPCAST" "$ENTRY" <<'PY'
import sys, re
path, entry = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
text = re.sub(r'(<language>[^<]*</language>\s*\n)', r'\1' + entry + '\n', text, count=1)
with open(path, 'w') as f:
    f.write(text)
PY
fi

# --- Commit, push, GitHub release ------------------------------------------

echo "→ Committing version bump + appcast"
git add Peek/Info.plist Releases/appcast.xml
git commit -m "Release v${VERSION}" >/dev/null
git push

echo "→ Creating GitHub release"
gh release create "v${VERSION}" "$DMG_PATH" \
    --repo "$GH_REPO" \
    --title "Peek ${VERSION}" \
    --notes "Peek ${VERSION} (build ${NEW_BUILD})"

echo
echo "✓ Release v${VERSION} published"
echo "  DMG:      ${DOWNLOAD_URL}"
echo "  Appcast:  ${FEED_URL}"
echo
echo "Test: open an OLDER Peek install → menu → Check for Updates… → confirm it sees ${VERSION}"
