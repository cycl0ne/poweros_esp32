#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the files of the Unicode Character Database that tools/foldgen
# makes the system's character tables from, at a pinned version, each
# checked against its sha256. Nothing of it is committed: it lands in
# toolchain/unicode/<version>, and foldgen is run by hand on it - the
# tables it writes are committed, the build never runs it.
set -eu
version=16.0.0
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/unicode/$version"
mkdir -p "$out"
cd "$out"
for name in UnicodeData.txt CaseFolding.txt; do
    curl -sSfL -o "$name" "https://www.unicode.org/Public/$version/ucd/$name"
done
sha256sum -c --quiet <<EOF
ff58e5823bd095166564a006e47d111130813dcf8bf234ef79fa51a870edb48f  UnicodeData.txt
6f1f9c588eb4a5c718d9e8f93b782685e5c7fec872cf05e8e6878053599e09bb  CaseFolding.txt
EOF
echo "Unicode $version in $out"
