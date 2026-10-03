#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the root certificates the disk's trust store is made from:
# Mozilla's, as the curl project extracts them into one PEM file, at a
# pinned date and checked against its sha256. Nothing of it is
# committed: it lands in toolchain/certs, which the build looks for;
# without it the disk has no roots and a TLS connection trusts only
# the roots of ENVARC:Sys/net/certificates/.
set -eu

date=2026-09-25
sha256=a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/certs"
mkdir -p "$out"
cd "$out"

file="cacert-$date.pem"
curl -sSfL -o "$file" "https://curl.se/ca/$file"
echo "$sha256  $file" | sha256sum -c --quiet
echo "roots in $out/$file"
