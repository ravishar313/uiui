# Sourced by package-models.sh and package-release.sh. The Hugging Face mirror of
# the model packs: repository UIUIModelHuggingFaceRepository in resources/Info.plist,
# one tag per pack named like its GitHub release (models-<name>-<id>).
hf_model_repository="$(/usr/libexec/PlistBuddy -c 'Print :UIUIModelHuggingFaceRepository' resources/Info.plist 2>/dev/null || true)"

# hf_pack_status <tag> <archive> <sha256> <bytes>: prints "match", "missing" or
# "different". Reads the public resolve headers (no redirect, no login); for an
# LFS/Xet file x-linked-etag is the file's SHA-256.
hf_pack_status() {
  local tag="$1" archive="$2" sha="$3" bytes="$4" headers code size etag
  headers="$(/usr/bin/curl -sS -I --max-time 30 "https://huggingface.co/$hf_model_repository/resolve/$tag/$archive" | tr -d '\r')" || { print missing; return; }
  code="$(print -r -- "$headers" | /usr/bin/awk 'NR==1 {print $2}')"
  [[ "$code" == 302 || "$code" == 200 ]] || { print missing; return; }
  size="$(print -r -- "$headers" | /usr/bin/awk -F': ' 'tolower($1)=="x-linked-size" {print $2}')"
  etag="$(print -r -- "$headers" | /usr/bin/awk -F': ' 'tolower($1)=="x-linked-etag" {gsub(/"/, "", $2); print $2}')"
  if [[ "$size" == "$bytes" && "$etag" == "$sha" ]]; then print match; else print different; fi
}
