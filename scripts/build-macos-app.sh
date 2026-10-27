#!/usr/bin/env bash
# A local runnable .app from the SwiftPM executable target. No Xcode project generator needed.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
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
<key>NSLocalNetworkUsageDescription</key><string>Mystic connects to your game-streaming host on your local network.</string>
</dict></plist>
PLIST
# Local development signing only; distribution signing and notarization are later work.
codesign --force --deep --sign - --identifier com.mystic.streaming "$app"
printf '\nBuilt %s\n' "$app"
