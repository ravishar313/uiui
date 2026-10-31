#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Builds the app-only update archive (models are installed separately, see
# docs/updates.md) and its checksum. With --publish it also creates the GitHub
# release; the model packs it needs must already be published
# (scripts/package-models.sh --publish).
usage() { print -u2 "Usage: $0 [--publish --notes <file> [--attach <file>]...]"; exit 1; }
publish=0
notes=""
# Extra downloads on the release page, such as the tester disk image.
extra_assets=()
while (( $# > 0 )); do
  case "$1" in
    --publish) publish=1; shift ;;
    --notes) (( $# >= 2 )) || usage; notes="${2:A}"; shift 2 ;;
    --attach) (( $# >= 2 )) && [[ -f "$2" ]] || usage; extra_assets+=("${2:A}"); shift 2 ;;
    *) usage ;;
  esac
done
if (( publish )); then
  [[ -f "$notes" ]] || { print -u2 "--publish needs --notes <file>."; exit 1; }
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' resources/Info.plist)"
if [[ ! "$version" =~ '^[0-9]+(\.[0-9]+){1,3}$' ]]; then
  print -u2 "CFBundleShortVersionString must be dotted numbers, found '$version'."
  exit 1
fi
repository="$(/usr/libexec/PlistBuddy -c 'Print :UIUIUpdateRepository' resources/Info.plist 2>/dev/null || true)"
release_directory="$PWD/build/release-$version"
app="$release_directory/uiui.app"
archive="$release_directory/uiui-$version-arm64.zip"
mkdir -p "$release_directory"
rm -f "$archive" "$archive.sha256"
./scripts/build-app.sh --without-models --output "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd "$release_directory" && /usr/bin/shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
# The archive must survive extraction with its signature intact.
check="$(mktemp -d "$PWD/build/.uiui-release-check.XXXXXX")"
trap 'rm -rf "$check"' EXIT
ditto -x -k "$archive" "$check"
codesign --verify --strict "$check/uiui.app"
print "Archive verified: $archive ($(/usr/bin/stat -f %z "$archive") bytes)"
cat "$archive.sha256"
# Every release carries the installer for new users, not only the update archive.
scripts/package-dmg.sh
dmg="$PWD/build/dmg-$version-lite/uiui-$version-lite.dmg"
[[ -f "$dmg" && -f "$dmg.sha256" ]] || { print -u2 "Installer was not built: $dmg"; exit 1; }
extra_assets+=("$dmg" "$dmg.sha256")
if (( ! publish )); then
  print "Would upload to ${repository:-<UIUIUpdateRepository>} as v$version:"
  print "  $archive"
  print "  $archive.sha256"
  print "  $dmg"
  print "  $dmg.sha256"
  print "Run with --publish --notes <file> to create the release."
  exit 0
fi
[[ -n "$repository" ]] || { print -u2 "UIUIUpdateRepository is missing from resources/Info.plist."; exit 1; }
# An app-only release is unusable if its model packs were never published.
# The signed app pins each pack's hash; the published asset must be those bytes.
for line in $(/usr/bin/python3 -c 'import json; [print("models-%s-%s:%s:%s:%s" % (p["name"].lower(), p["id"], p["archive"], p["sha256"], p["bytes"])) for p in json.load(open("resources/ModelPacks.json"))["packs"]]'); do
  tag="${line%%:*}"; rest="${line#*:}"; pack_archive="${rest%%:*}"; rest="${rest#*:}"; pinned="${rest%%:*}"; bytes="${rest#*:}"
  release_json="$(gh api "repos/$repository/releases/tags/$tag" 2>/dev/null)" || { print -u2 "Model pack release $tag is not published. Run scripts/package-models.sh --publish first."; exit 1; }
  print -r -- "$release_json" | /usr/bin/python3 -c '
import json, sys
name, pinned, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
assets = [a for a in json.load(sys.stdin)["assets"] if a["name"] == name]
if len(assets) != 1 or assets[0]["size"] != size:
    sys.exit("published %s is missing or a different size" % name)
digest = assets[0].get("digest")
if digest and digest != "sha256:" + pinned:
    sys.exit("published %s does not match resources/ModelPacks.json" % name)
' "$pack_archive" "$pinned" "$bytes" || { print -u2 "Run scripts/package-models.sh --publish to re-pin, then rebuild."; exit 1; }
done
gh release create "v$version" "$archive" "$archive.sha256" "${extra_assets[@]}" --repo "$repository" --title "uiui $version" --notes-file "$notes" --latest
