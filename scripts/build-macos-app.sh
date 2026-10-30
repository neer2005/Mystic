#!/usr/bin/env bash
# A local runnable .app from the SwiftPM executable target. No Xcode project generator needed.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
# Keep the signing identity stable across rebuilds so Keychain approvals can persist.
# The checkout's selection is local Git configuration, never a committed personal identity.
signing_identity="${MYSTIC_SIGNING_IDENTITY:-$(git config --get mystic.signingIdentity || true)}"
if [[ -z "$signing_identity" ]]; then
    identity_report="$(security find-identity -v -p codesigning)"
    development_identities=()
    while IFS= read -r fingerprint; do
        [[ -z "$fingerprint" ]] || development_identities+=("$fingerprint")
    done < <(printf '%s\n' "$identity_report" | sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) "Apple Development:.*"$/\1/p')
    if [[ ${#development_identities[@]} -ne 1 ]]; then
        printf '%s\n' 'Choose a persistent signing certificate before building Mystic.' \
            'Run: security find-identity -v -p codesigning' \
            'Then: git config --local mystic.signingIdentity <certificate-SHA-1>' \
            'See docs/SIGNING.md for setup and explicit ad-hoc builds.' >&2
        exit 1
    fi
    signing_identity="${development_identities[0]}"
fi
if [[ "$signing_identity" == "-" ]]; then
    printf '%s\n' 'Explicit ad-hoc signing: Keychain may ask again after each rebuild.' >&2
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/mystic-clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/mystic-swift}"
cargo build --manifest-path engine/Cargo.toml --release --locked
swift build --disable-sandbox --configuration "$configuration" --product MysticApp
binary_directory="$(swift build --disable-sandbox --configuration "$configuration" --show-bin-path)"
app="$PWD/.build/Mystic.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/MysticApp" "$app/Contents/MacOS/MysticApp.new"
mv -f "$app/Contents/MacOS/MysticApp.new" "$app/Contents/MacOS/MysticApp"
cp -R "$binary_directory/Mystic_MysticStream.bundle" "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/ThirdPartyNotices"
cp -R third_party/opus "$app/Contents/Resources/ThirdPartyNotices/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MysticApp</string>
<key>CFBundleIdentifier</key><string>com.mystic.streaming</string>
<key>CFBundleName</key><string>Mystic</string>
<key>CFBundleDisplayName</key><string>Mystic</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Mystic sends your microphone to the streaming host when you enable Use Mac Microphone.</string>
<key>NSBonjourServices</key><array><string>_nvstream._tcp</string></array>
<key>NSLocalNetworkUsageDescription</key><string>Mystic connects to your game-streaming host on your local network.</string>
</dict></plist>
PLIST
# Local development signing only; distribution signing and notarization are later work.
codesign --force --deep --sign "$signing_identity" --timestamp=none --identifier com.mystic.streaming "$app"
codesign --verify --deep --strict "$app"
printf '\nBuilt %s\n' "$app"
