#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Staging uses the same packaging/signing path as installation. Benchmarks can
# qualify a separate bundle before the default installed bundle is replaced.
installed_app="$PWD/build/uiui.app"
include_models=1
while (( $# > 0 )); do
  case "$1" in
    --output)
      if (( $# < 2 )); then
        print -u2 "Usage: $0 [--output build/path/uiui.app] [--without-models]"
        exit 1
      fi
      installed_app="${2:A}"
      if [[ "$installed_app" != "$PWD/build/"*.app ]]; then
        print -u2 "The output must be an .app bundle within this project's build directory."
        exit 1
      fi
      shift 2 ;;
    --without-models)
      # App-only bundle for updates: models are installed separately (docs/updates.md).
      include_models=0
      shift ;;
    *)
      print -u2 "Usage: $0 [--output build/path/uiui.app] [--without-models]"
      exit 1 ;;
  esac
done
# A persistent certificate-bound identity keeps macOS privacy grants valid as the
# executable changes. Ad-hoc signing binds grants to one executable hash only.
signing_certificate="$PWD/.local-signing/uiui-local.cer"
if [[ ! -f "$signing_certificate" ]]; then
  print -u2 "uiui needs its persistent local signing identity. See docs/local-signing.md."
  exit 1
fi
/usr/bin/openssl x509 -inform DER -in "$signing_certificate" -noout >/dev/null
certificate_hash="$(/usr/bin/shasum -a 1 "$signing_certificate" | /usr/bin/cut -d ' ' -f 1)"
if [[ ! "$certificate_hash" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "The local signing certificate could not be identified."
  exit 1
fi
signing_requirement="=designated => anchor H\"$certificate_hash\" and identifier \"app.uiui.mac\""
python3 scripts/verify-minilm-assets.py resources/MiniLM
python3 scripts/verify-phonon-assets.py resources/Phonon
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/package-cache"
mkdir -p "$PWD/build"
package_directory="$(mktemp -d "$PWD/build/.uiui-package.XXXXXX")"
trap 'rm -rf "$package_directory"' EXIT
app="$package_directory/uiui.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/uiui "$app/Contents/MacOS/uiui"
cp resources/Info.plist "$app/Contents/Info.plist"
cp resources/SpeechModels.txt "$app/Contents/Resources/SpeechModels.txt"
install -m 644 .build/checkouts/FluidAudio/LICENSE "$app/Contents/Resources/FluidAudio-LICENSE.txt"
# SwiftPM resource bundles must accompany the executable in the standalone app.
for bundle in .build/release/*.bundle; do
  [[ -d "$bundle" ]] && ditto "$bundle" "$app/Contents/Resources/${bundle:t}"
done
if [[ -f resources/UIUIIcon.icns ]]; then cp resources/UIUIIcon.icns "$app/Contents/Resources/UIUIIcon.icns"; fi
mkdir -p "$app/Contents/Frameworks"
# MiniLM's tokenizer is statically linked. Only its pinned CPU runtime and
# redistribution notices accompany the app; build and training tools stay out.
install -m 755 Vendor/MiniLM/lib/libonnxruntime.1.23.2.dylib "$app/Contents/Frameworks/libonnxruntime.1.23.2.dylib"
codesign --force --sign "$certificate_hash" "$app/Contents/Frameworks/libonnxruntime.1.23.2.dylib"
ditto Vendor/MiniLM/licenses "$app/Contents/Resources/MiniLM-Runtime-Licenses"
# ModelPacks.json (sealed by the signature) pins the model packs this build needs.
# Its ids must describe the source models, or installs could never find them.
for pack in Phonon:assets.json MiniLM:manifest.json; do
  pack_id="$(/usr/bin/shasum -a 256 "resources/${pack%%:*}/${pack##*:}" | /usr/bin/cut -c 1-12)"
  if ! /usr/bin/grep -q "\"id\": \"$pack_id\"" resources/ModelPacks.json; then
    print -u2 "resources/ModelPacks.json is out of date for ${pack%%:*}. Run scripts/package-models.sh."
    exit 1
  fi
done
install -m 644 resources/ModelPacks.json "$app/Contents/Resources/ModelPacks.json"
if (( include_models )); then
  ditto resources/MiniLM "$app/Contents/Resources/MiniLM"
  ditto resources/Phonon "$app/Contents/Resources/Phonon"
fi
install -m 644 Vendor/PhononCoreML/LICENSE "$app/Contents/Resources/Phonon-Runtime-LICENSE.txt"
install -m 644 Vendor/PhononCoreML/NOTICE "$app/Contents/Resources/Phonon-Runtime-NOTICE.txt"
# An interrupted codesign authentication can leave its generated executable
# beside the real one; it is not an app component and cannot be signed again.
rm -f "$app/Contents/MacOS/uiui.cstemp"
codesign --force --sign "$certificate_hash" --requirements "$signing_requirement" --entitlements resources/uiui.entitlements "$app"
codesign --verify --strict "$app"
# Leave the installed app untouched while compilation or keychain approval runs.
# Install the fully signed bundle only after verification, retaining open inodes
# for a currently running instance instead of truncating its executable in place.
mkdir -p "${installed_app:h}"
if [[ -d "$installed_app" ]]; then mv "$installed_app" "$package_directory/previous.app"; fi
if ! mv "$app" "$installed_app"; then
  if [[ -d "$package_directory/previous.app" ]]; then mv "$package_directory/previous.app" "$installed_app"; fi
  exit 1
fi
print "Built $installed_app"
