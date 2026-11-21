#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch resvg's test suite, by the Resvg Authors, under the MIT and the
# Apache 2.0 licence, at a pinned commit: some 1800 SVG files, each with
# resvg's picture of it beside it, the files they name, and the fonts
# their text is drawn in, each font under the licence beside it.
# `zig build svg-suite` draws every file with svg.datatype's code and
# compares it with resvg's picture (tools/svgcompare --suite).
#
# Checked against its sha256. Nothing of it is committed: it lands in
# toolchain/svg-suite - tests/, resources/ and fonts/ as the suite keeps
# them, since its files name each other by those places - with the two
# licences and `commit`, the commit it is.
set -eu

resvg=433d0213a98d611793d105e08e141325e13720e3 # linebender/resvg, 17.11.2026
resvg_sha256=112dd4a042710571c49ed19e9ffd38f5cd6ced64491dea3a46a1775798b3b91e

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/svg-suite"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -sSfL -o "$work/resvg.tar.gz" "https://github.com/linebender/resvg/archive/$resvg.tar.gz"
(cd "$work" && echo "$resvg_sha256  resvg.tar.gz" | sha256sum -c --quiet)
top="resvg-$resvg"
tar xzf "$work/resvg.tar.gz" -C "$work" "$top/crates/resvg/tests/tests" "$top/crates/resvg/tests/resources" "$top/crates/resvg/tests/fonts" "$top/LICENSE-MIT" "$top/LICENSE-APACHE"
rm -rf "$out"
mkdir -p "$out"
mv "$work/$top/crates/resvg/tests/tests" "$work/$top/crates/resvg/tests/resources" "$work/$top/crates/resvg/tests/fonts" "$out/"
mv "$work/$top/LICENSE-MIT" "$work/$top/LICENSE-APACHE" "$out/"
echo "$resvg" > "$out/commit"
echo "resvg's test suite in $out"
