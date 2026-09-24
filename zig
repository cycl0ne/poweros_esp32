#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Run the Espressif Zig toolchain from ./toolchain/zig instead of the zig on
# PATH. Downloads it on first use.
set -eu

version=0.16.0-xtensa
root=$(cd "$(dirname "$0")" && pwd)
zig="$root/toolchain/zig/zig"

if [ ! -x "$zig" ]; then
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) asset=zig-relsafe-x86_64-linux-musl-baseline ;;
        Linux-aarch64) asset=zig-relsafe-aarch64-linux-musl-baseline ;;
        Darwin-arm64) asset=zig-relsafe-aarch64-macos-baseline ;;
        *)
            echo "no prebuilt Espressif Zig for $(uname -s)-$(uname -m)" >&2
            exit 1
            ;;
    esac
    echo "Downloading Espressif Zig $version ($asset)..." >&2
    mkdir -p "$root/toolchain"
    curl -fL --progress-bar \
        "https://github.com/kassane/zig-espressif-bootstrap/releases/download/$version/$asset.tar.xz" |
        tar -xJ -C "$root/toolchain"
    mv "$root/toolchain/$asset" "$root/toolchain/zig"
fi

exec "$zig" "$@"
