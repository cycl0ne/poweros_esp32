#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the fonts the disk carries in FONTS:: Spleen, by Frederic Cambus,
# under the BSD 2-Clause licence, as bitmap sources (BDF) at a pinned
# release; and the Go fonts, by Bigelow & Holmes, under the Go project's
# BSD licence, as TrueType outlines at a pinned commit; and the
# Liberation fonts, by Red Hat, under the SIL Open Font Licence 1.1, as
# TrueType outlines at a pinned release - Sans, Serif and Mono, drawn to
# the widths of Arial, Times New Roman and Courier New, which is what
# SVG files most often ask for; and Noto Sans Devanagari, Regular and
# Bold, by Google, under the SIL Open Font Licence 1.1, as TrueType
# outlines at a pinned release - the script Hindi is written in, which
# the host tests read too: a script whose text is reordered and joined;
# and Noto Sans CJK Regular, by Google and Adobe, under the SIL Open
# Font Licence 1.1, at a pinned release - Japanese, Chinese and Korean
# in one file, a collection of ten fonts over one set of outlines of
# cubic curves, each font a region's forms of the characters, which the
# host tests read too; and Noto Color Emoji, by Google, under the SIL
# Open Font Licence 1.1, at a pinned release - the emoji as colour
# pictures, a glyph for each sequence, which the host tests read too.
#
# And the fonts only the host tests read, which go on no disk: Source
# Sans 3 Regular, by Adobe, under the SIL Open Font Licence 1.1, at a
# pinned release - a Latin font of outlines of cubic curves; and Source
# Sans 3's two variable fonts of the upright face, from the same
# release - one axis, the weight, over outlines of quadratic curves in
# the one and of cubic curves in the other.
#
# Each is checked against its sha256. Nothing of it is committed: it lands
# in toolchain/fonts, which the build looks for; without it the disk has
# no fonts beyond the ROM's, and the tests that read a fetched font are
# skipped.
set -eu

spleen=2.2.0
spleen_sha256=ec42925c6b56d2138c862b2f97147c872e472f674bf03423417d827a08d69a89

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/fonts"
mkdir -p "$out"
cd "$out"

tarball="spleen-$spleen.tar.gz"
curl -sSfL -o "$tarball" "https://github.com/fcambus/spleen/releases/download/$spleen/$tarball"
echo "$spleen_sha256  $tarball" | sha256sum -c --quiet
tar xzf "$tarball"
rm "$tarball"
echo "fonts in $out/spleen-$spleen"

go_image=b06f1de3f4900ff828b8f114c37eb9ea10dfed90 # golang/image
mkdir -p go
for name in Go-Regular.ttf Go-Bold.ttf Go-Italic.ttf Go-Mono.ttf Go-Mono-Bold.ttf README; do
    curl -sSfL -o "go/$name" "https://raw.githubusercontent.com/golang/image/$go_image/font/gofont/ttfs/$name"
done
cd go
sha256sum -c --quiet <<EOF
197d9f3703b4c00af609178876a8d73e396f64fe438b2c871778566632374be3  Go-Regular.ttf
c18494baa7ea35b8dbfac3861787d360b9c0ab91232562371a09e6fbf09aaa40  Go-Bold.ttf
6efef00d080c8fe68bbe2bf08526294c83d52d7b90b16f938953025c0868cc57  Go-Italic.ttf
8bc66a0154bbf69cd24e5bde41a12ec9495c8a242c5def2255e4a164900f1ed7  Go-Mono.ttf
b165f1a142dc88d3c388de2c89d3ab62dd04620ef21ad07f43fb51f77857edc3  Go-Mono-Bold.ttf
dc588a7ba9130043b67c2380cc03cc6644ed3557f6d5e8589b96acba1c64e343  README
EOF
echo "fonts in $out/go"

liberation=2.1.5
liberation_sha256=7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0
cd "$out"
tarball="liberation-fonts-ttf-$liberation.tar.gz"
# The release's files are attached to its notes, not to the release.
curl -sSfL -o "$tarball" "https://github.com/liberationfonts/liberation-fonts/files/7261482/$tarball"
echo "$liberation_sha256  $tarball" | sha256sum -c --quiet
tar xzf "$tarball"
rm "$tarball"
echo "fonts in $out/liberation-fonts-ttf-$liberation"

# Noto Sans Devanagari for the 64-bit disks, Noto Sans CJK and Noto
# Color Emoji for the 64-bit packages and system disks, all three and the
# rest for the host tests. The expected values in the libraries' tests/
# folders name these files' sha256: a new release here means running
# scripts/font-reference.py, scripts/shape-reference.py and
# scripts/shape-text-reference.py again.
devanagari=2.007
devanagari_sha256=820c7da45b1e63562cb41c0a8cac5d9a4202312043a3a040ed1325857ef469b1
emoji=v2026-09-24-unicode18_0 # googlefonts/noto-emoji
cjk=Sans2.004 # notofonts/noto-cjk
source_sans=3.052R
source_sans_sha256=a4ebbdea20b08ccbd7bf3665a9462454eefdd01d9a6307129d3b3d4672981074
source_sans_vf_sha256=d8e2ac355e06e6a0f0e0a0b1ac0c2451afa707584d7bb9d6b11ef9e4b749904c
mkdir -p noto
archive="NotoSansDevanagari-v$devanagari.zip"
curl -sSfL -o "$archive" "https://github.com/notofonts/devanagari/releases/download/NotoSansDevanagari-v$devanagari/$archive"
echo "$devanagari_sha256  $archive" | sha256sum -c --quiet
unzip -q -o -j "$archive" NotoSansDevanagari/hinted/ttf/NotoSansDevanagari-Regular.ttf NotoSansDevanagari/hinted/ttf/NotoSansDevanagari-Bold.ttf -d noto
unzip -p "$archive" OFL.txt >noto/NotoSansDevanagari.licence
rm "$archive"
curl -sSfL -o noto/NotoColorEmoji.ttf "https://raw.githubusercontent.com/googlefonts/noto-emoji/$emoji/2D/fonts/NotoColorEmoji.ttf"
curl -sSfL -o noto/NotoColorEmoji.licence "https://raw.githubusercontent.com/googlefonts/noto-emoji/$emoji/LICENSE"
curl -sSfL -o noto/NotoSansCJK-Regular.ttc "https://raw.githubusercontent.com/notofonts/noto-cjk/$cjk/Sans/OTC/NotoSansCJK-Regular.ttc"
curl -sSfL -o noto/NotoSansCJK.licence "https://raw.githubusercontent.com/notofonts/noto-cjk/$cjk/LICENSE"
cd noto
sha256sum -c --quiet <<EOF
4e3c66638958c3e2ab5d37f47a8deb89fffeb7be9985c665a519bbc7ba762313  NotoSansDevanagari-Regular.ttf
6a09c8d797cfc803d32cdc731e809424d74cbaff59f503de34ade421a08e5bc2  NotoSansDevanagari-Bold.ttf
15671215ab769fdc7162a045d56fd7d7e477c51b04e6b3c761d914d8fdd6cc44  NotoColorEmoji.ttf
500bb1ccf43df7bbb522112f9133a52b16e1c35e809632f5d8609b179152de5b  NotoColorEmoji.licence
b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a  NotoSansCJK-Regular.ttc
6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2  NotoSansCJK.licence
EOF
echo "fonts in $out/noto"

cd "$out"
mkdir -p source-sans
archive="OTF-source-sans-$source_sans.zip"
curl -sSfL -o "$archive" "https://github.com/adobe-fonts/source-sans/releases/download/$source_sans/$archive"
echo "$source_sans_sha256  $archive" | sha256sum -c --quiet
unzip -q -o -j "$archive" OTF/SourceSans3-Regular.otf -d source-sans
rm "$archive"
# The same family as one file of every weight, in quadratic curves and
# in cubic ones.
archive="VF-source-sans-$source_sans.zip"
curl -sSfL -o "$archive" "https://github.com/adobe-fonts/source-sans/releases/download/$source_sans/$archive"
echo "$source_sans_vf_sha256  $archive" | sha256sum -c --quiet
unzip -q -o -j "$archive" VF/SourceSans3VF-Upright.ttf VF/SourceSans3VF-Upright.otf -d source-sans
rm "$archive"
cd source-sans
sha256sum -c --quiet <<EOF
08df266400933d3178d081a45f94a08814c3e55b4b7dd2e0ff69cb1329f13ab6  SourceSans3-Regular.otf
1147db9a3f0edd4956068de77930148acce2742dd76d57f7239b2b1c687ac63f  SourceSans3VF-Upright.ttf
3d0dfd6a3a644ab3d462a737923ffac41fb0ae007ce9ba83c24e6bfa76aa56c7  SourceSans3VF-Upright.otf
EOF
echo "fonts in $out/source-sans"
