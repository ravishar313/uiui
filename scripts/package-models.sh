#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Builds one zip per model pack (resources/Phonon, resources/MiniLM) into
# build/model-packs/ and writes resources/ModelPacks.json, the signed pin the app
# uses to find and verify downloaded packs. Packs only change when a model changes.
# --publish creates a GitHub release models-<name>-<id> for each pack not yet released.
publish=0
for argument in "$@"; do
  case "$argument" in
    --publish) publish=1 ;;
    *) print -u2 "Usage: $0 [--publish]"; exit 1 ;;
  esac
done
python3 scripts/verify-minilm-assets.py resources/MiniLM
python3 scripts/verify-phonon-assets.py resources/Phonon
output="$PWD/build/model-packs"
mkdir -p "$output"
scratch="$(mktemp -d "$PWD/build/.uiui-models.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
repository="$(/usr/libexec/PlistBuddy -c 'Print :UIUIUpdateRepository' resources/Info.plist 2>/dev/null || true)"
if (( publish )); then
  [[ -n "$repository" ]] || { print -u2 "UIUIUpdateRepository is missing from resources/Info.plist."; exit 1; }
fi
entries=()
tags=()
for pack in Phonon:assets.json MiniLM:manifest.json; do
  name="${pack%%:*}"
  manifest="${pack##*:}"
  id="$(/usr/bin/shasum -a 256 "resources/$name/$manifest" | /usr/bin/cut -c 1-12)"
  archive="uiui-model-${name:l}-$id.aar"
  # A published pack is immutable: its exact bytes are what the app pins, even
  # if a local rebuild would differ (another Mac, a newer ditto).
  if (( publish )) && gh release view "models-${name:l}-$id" --repo "$repository" >/dev/null 2>&1; then
    mkdir -p "$scratch/published"
    gh release download "models-${name:l}-$id" --repo "$repository" --pattern "$archive" --dir "$scratch/published" --clobber
    [[ -f "$scratch/published/$archive" ]] || { print -u2 "Release models-${name:l}-$id has no $archive."; exit 1; }
    mv -f "$scratch/published/$archive" "$output/$archive"
  elif [[ ! -f "$output/$archive" ]]; then
    # LZMA Apple Archive: about 20% smaller than zip for the speech weights, and
    # unpacked by macOS's own /usr/bin/aa. Owners and times are left out so a
    # rebuild of the same files is byte-identical.
    rm -rf "$scratch/pack"
    mkdir -p "$scratch/pack"
    ditto --norsrc --noextattr --noqtn "resources/$name" "$scratch/pack/$name"
    find "$scratch/pack" -exec touch -t 202601010000 {} +
    aa archive -a lzma -b 16m -d "$scratch/pack" -o "$output/$archive" -exclude-field uid,gid,mtm,ctm,btm
  fi
  digest="$(/usr/bin/shasum -a 256 "$output/$archive" | /usr/bin/cut -d ' ' -f 1)"
  size="$(/usr/bin/stat -f %z "$output/$archive")"
  entries+=("    {\"name\": \"$name\", \"id\": \"$id\", \"archive\": \"$archive\", \"sha256\": \"$digest\", \"bytes\": $size}")
  tags+=("models-${name:l}-$id:$archive")
  print "$name $id $size bytes"
done
{
  print '{'
  print '  "schema": 1,'
  print '  "packs": ['
  for (( index = 1; index <= $#entries; index++ )); do
    if (( index < $#entries )); then print -r -- "${entries[index]},"; else print -r -- "${entries[index]}"; fi
  done
  print '  ]'
  print '}'
} > resources/ModelPacks.json
print "Wrote resources/ModelPacks.json"
for item in $tags; do
  tag="${item%%:*}"
  archive="${item#*:}"
  if (( publish )); then
    if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
      print "$tag already published"
    else
      # Never "latest": the app reads releases/latest and expects an app release.
      gh release create "$tag" "$output/$archive" --repo "$repository" --title "uiui model $tag" --latest=false \
        --notes "Model pack for uiui. Downloaded automatically by the app; do not delete."
    fi
  else
    print "Would publish $tag with $archive to ${repository:-<repository>}"
  fi
done
