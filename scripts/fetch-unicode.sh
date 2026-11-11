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
for name in UnicodeData.txt CaseFolding.txt EastAsianWidth.txt Scripts.txt PropertyValueAliases.txt \
    CompositionExclusions.txt NormalizationTest.txt; do
    curl -sSfL -o "$name" "https://www.unicode.org/Public/$version/ucd/$name"
done
sha256sum -c --quiet <<EOF
ff58e5823bd095166564a006e47d111130813dcf8bf234ef79fa51a870edb48f  UnicodeData.txt
6f1f9c588eb4a5c718d9e8f93b782685e5c7fec872cf05e8e6878053599e09bb  CaseFolding.txt
43adc76c0686a42cb370764eb8cfe2b2a45b10b855e5572a2db4a0eecce15d5b  EastAsianWidth.txt
9e88f0a677df47311106340be8ede2ecdacd9c1c931831218d2be6d5508e0039  Scripts.txt
440fd3e5460b9bfe31da67b6f923992e1989d31fe2ed91e091c4b8f8e2620bf9  PropertyValueAliases.txt
89e83cf9cc8bef6c1f8bf77e42cf6f0341dfa42e66261f4dbe9b492e7a23c8ee  CompositionExclusions.txt
d811971453e7075e1ad56fb1b301eece5aa80757b81f6156e74a1bfb3ae5ceb1  NormalizationTest.txt
EOF
echo "Unicode $version in $out"
