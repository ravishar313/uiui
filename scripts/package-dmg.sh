#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Builds the disk image to hand to a tester. By default the app inside has no
# speech models (about 15 MB); the setup guide downloads the published model
# packs once. --full bundles the models for an offline install (about 250 MB).
# Both use LZMA (ULMO) compression.
full=0
for argument in "$@"; do
  case "$argument" in
    --full) full=1 ;;
    *) print -u2 "Usage: $0 [--full]"; exit 1 ;;
  esac
done
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' resources/Info.plist)"
variant=$([[ $full == 1 ]] && print full || print lite)
directory="$PWD/build/dmg-$version-$variant"
rm -rf "$directory"
mkdir -p "$directory"
if (( full )); then
  ./scripts/build-app.sh --output "$directory/uiui.app"
else
  ./scripts/build-app.sh --without-models --output "$directory/uiui.app"
fi
staging="$(mktemp -d "$PWD/build/.uiui-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$directory/uiui.app" "$staging/uiui.app"
ln -s /Applications "$staging/Applications"
if (( full )); then
  models_line="The speech models are included, so setup works offline."
else
  models_line="Setup downloads the speech models once (about 250 MB) from GitHub. App updates never download them again."
fi
cat > "$staging/Read Me.txt" <<EOF
uiui $version · private beta

Requirements: Apple Silicon Mac, macOS 15 or later for English dictation.

Install
1. Drag uiui into Applications, then open it from Applications.
2. The setup guide walks you through Microphone and Accessibility access,
   your shortcut, the notch style, the speech model and a paste test.
   $models_line
3. Later updates appear inside uiui (menu bar → Check for Updates…).

First launch security
This build is signed with a local development certificate, not an Apple
Developer ID, and is not notarized. If macOS blocks the first launch, open
System Settings → Privacy & Security and choose Open Anyway for uiui.
https://support.apple.com/en-us/102445

Dictation starts only when you press your shortcut. Audio stays on this Mac.
EOF
image="$directory/uiui-$version-$variant.dmg"
hdiutil create -volname "uiui $version" -srcfolder "$staging" -format ULMO -fs APFS -ov "$image" >/dev/null
hdiutil verify "$image" >/dev/null
/usr/bin/shasum -a 256 "$image" | /usr/bin/sed "s|$directory/||" > "$image.sha256"
print "Built $image ($(/usr/bin/stat -f %z "$image") bytes)"
