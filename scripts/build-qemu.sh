#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Build Espressif QEMU with the ESP32-S3 CPU clock hardwired to 240 MHz.
# Stock QEMU emulates the S3 core at a fixed 40 MHz and ignores the clock
# registers. Installs into toolchain/qemu, which `zig build qemu` prefers.
set -eu

tag=esp-develop-9.2.2-20260417
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/toolchain/qemu-src"
prefix="$root/toolchain/qemu"
core=target/xtensa/core-esp32s3.c
rgb=include/hw/display/esp_rgb.h
rgb_c=hw/display/esp_rgb.c
sdl=ui/sdl2.c
machine=hw/xtensa/esp32s3.c
kconfig=hw/xtensa/Kconfig

if [ ! -d "$src" ]; then
    git clone --depth 1 --branch "$tag" https://github.com/espressif/qemu.git "$src"
fi
cd "$src"

# patch <file> <sed expression> <string that must be present afterwards>
patch() {
    sed -i "$2" "$1"
    if ! grep -q "$3" "$1"; then
        echo "patch did not apply to $1" >&2
        exit 1
    fi
}
git checkout -- "$core" "$rgb" "$rgb_c" "$sdl" "$machine" "$kconfig"
patch "$core" 's/\.clock_freq_khz = 40000,/.clock_freq_khz = 240000,/' '\.clock_freq_khz = 240000,'
# Virtual display: allow the Waveshare 7B's 1024x600 panel (stock max is 800).
patch "$rgb" 's/#define ESP_RGB_MAX_WIDTH   (800)/#define ESP_RGB_MAX_WIDTH   (1024)/' 'ESP_RGB_MAX_WIDTH   (1024)'
# Virtual display: the window's input for the guest - the pointer over it
# and its three buttons for mouse.device (RGB_POINTER, RGB_POINTER_SEQ) and
# the keys typed into it for keyboard.device (RGB_KEY, RGB_KEY_COUNT), and
# the device's minor version raised to 5 so a guest can tell.
git apply "$root/scripts/qemu/esp_rgb_input.patch"
# The SDL window: with show-cursor=off and a pointer the guest is told the
# position of, the host's cursor stays hidden over the window whether or
# not it is grabbed - the guest draws its own pointer.
git apply "$root/scripts/qemu/sdl_hide_cursor.patch"
# Virtual display: twice the VRAM - four pictures of the largest window at
# two bytes a pixel, so screens and their back buffers each have one - and
# the minor version raised to 6 so a guest can tell.
patch "$rgb" 's/#define ESP_RGB_MAX_VRAM_SIZE   (ESP_RGB_MAX_WIDTH \* ESP_RGB_MAX_HEIGHT \* 4)/#define ESP_RGB_MAX_VRAM_SIZE   (ESP_RGB_MAX_WIDTH * ESP_RGB_MAX_HEIGHT * 8)/' 'ESP_RGB_MAX_HEIGHT \* 8)'
patch "$rgb_c" 's/#define RGB_VERSION_MINOR 5/#define RGB_VERSION_MINOR 6/' 'RGB_VERSION_MINOR 6'
# Virtual display: the mouse wheel's notches for mouse.device (RGB_WHEEL),
# and the minor version raised to 7 so a guest can tell.
git apply "$root/scripts/qemu/esp_rgb_wheel.patch"
patch "$rgb_c" 's/#define RGB_VERSION_MINOR 6/#define RGB_VERSION_MINOR 7/' 'RGB_VERSION_MINOR 7'
# USB OTG: QEMU's DWC2 host controller at the OTG's registers (0x6008_0000,
# interrupt source 38), full and low speed only as the S3's PHY is, and
# USB_WRAP kept as plain registers; the machine selects the controller and
# the USB devices to plug into it (-device usb-kbd, usb-mouse, usb-tablet,
# usb-hub, usb-storage, usb-serial, usb-net).
git apply "$root/scripts/qemu/esp32s3_dwc2.patch"

# The DWC2 model looks a channel's device up by its address each time it
# services the channel again, and asserts when none is there: a device
# unplugged while a transfer to it was retried or in flight took the
# emulator down. Such a transfer now ends as one no device answers - a
# transaction error and the channel halted - as on a real bus.
git apply "$root/scripts/qemu/dwc2_unplugged.patch"

# Espressif's release flags (.github/workflows/scripts/configure-native.sh),
# minus -Werror. SDL provides the window for the virtual display. Newer glibc turns const-qualifier mismatches in
# QEMU 9.2 into warnings, which -Werror (on by default in a git checkout)
# would make fatal. The xtensa target does not need fdt, whose bundled dtc
# subproject forces -Werror on itself.
./configure \
    --disable-werror \
    --disable-fdt \
    --prefix="$prefix" \
    --bindir=bin \
    --datadir=share/qemu \
    --with-suffix="" \
    --target-list=xtensa-softmmu \
    --without-default-features \
    --enable-gcrypt \
    --enable-sdl \
    --enable-pixman \
    --enable-slirp \
    --with-pkgversion="$tag-s3-240mhz"
make -j"$(nproc)"
make install

"$prefix/bin/qemu-system-xtensa" --version
