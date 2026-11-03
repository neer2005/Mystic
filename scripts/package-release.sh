#!/usr/bin/env bash
# Packs .build/Mystic.app into a disk image with a checksum, in .build/release:
# Mystic-<version>.dmg. With MYSTIC_NOTARY_PROFILE, a notarytool keychain profile, the image is
# notarized and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: package-release.sh <version>}"
app=.build/Mystic.app
out=.build/release
image="$out/Mystic-$version.dmg"
[[ -d "$app" ]] || { echo "Build $app first." >&2;exit 1; }
rm -rf "$out";mkdir -p "$out"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/Mystic.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Mystic $version" -srcfolder "$stage" -format UDZO -ov "$image"
if [[ -n "${MYSTIC_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$image" --keychain-profile "$MYSTIC_NOTARY_PROFILE" --wait
    xcrun stapler staple "$image"
    spctl --assess --type open --context context:primary-signature --verbose "$image"
fi
(cd "$out" && shasum -a 256 "$(basename "$image")" > "$(basename "$image").sha256")
printf 'Packaged %s\n' "$image"
