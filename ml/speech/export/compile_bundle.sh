#!/bin/zsh
# Mac side of a Linux export: compile <bundle>/Phonon-2.mlpackage -> Phonon-2.mlmodelc (needs xcrun), then drop the package.
set -e
B=${1:?bundle dir}
[ -d "$B/Phonon-2.mlpackage" ] || { echo "no $B/Phonon-2.mlpackage"; exit 1; }
T=$(mktemp -d); xcrun coremlcompiler compile "$B/Phonon-2.mlpackage" "$T" >/dev/null
rm -rf "$B/Phonon-2.mlmodelc"; mv "$T/Phonon-2.mlmodelc" "$B/"; rm -rf "$T" "$B/Phonon-2.mlpackage"
echo "compiled $B/Phonon-2.mlmodelc ($(du -sh $B/Phonon-2.mlmodelc | cut -f1))"
