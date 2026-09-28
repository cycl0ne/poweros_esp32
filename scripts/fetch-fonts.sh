#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the fonts the disk carries in FONTS:: Spleen, by Frederic Cambus,
# under the BSD 2-Clause licence, as bitmap sources (BDF) at a pinned
# release; and the Go fonts, by Bigelow & Holmes, under the Go project's
# BSD licence, as TrueType outlines at a pinned commit. Each is checked
# against its sha256. Nothing of it is committed: it lands in
# toolchain/fonts, which the build looks for; without it the disk has no
# fonts beyond the ROM's.
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
