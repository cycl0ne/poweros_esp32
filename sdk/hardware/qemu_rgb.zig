// SPDX-License-Identifier: MIT
//! QEMU's virtual RGB display ("display.esp.rgb" in Espressif QEMU), the
//! qemu board's display, keyboard and mouse parts: its registers, and the
//! few steps each of its uses takes. Our QEMU build (scripts/build-qemu.sh)
//! allows up to 1024x600 and adds the window's pointer and keys.

const reg = @import("mmio.zig").reg;

const regs = 0x2100_0000;
const version_reg = regs + 0x00;
/// Our QEMU build's addition (scripts/qemu/esp_rgb_input.patch): the
/// pointer over the window and a count of its events, and the keys typed
/// into it.
const pointer_reg = regs + 0x1C;
const pointer_seq_reg = regs + 0x20;
const key_reg = regs + 0x24;
const key_count_reg = regs + 0x28;
const win_size = regs + 0x04;
const update_from = regs + 0x08;
const update_to = regs + 0x0C;
const update_content = regs + 0x10;
const update_status = regs + 0x14;
const bpp_value = regs + 0x18;

/// Framebuffer RAM provided by the device.
pub const vram = 0x2000_0000;

/// How much of it there is: the largest window at four bytes a pixel, or
/// twice that in our build from version 0.6 (scripts/build-qemu.sh) -
/// room for four pictures of the largest window at two bytes a pixel.
pub fn vramSize() usize {
    const v = reg(version_reg).*;
    const doubled = (v >> 16) > 0 or (v & 0xFFFF) >= 6;
    return @as(usize, 1024) * 600 * 4 * @as(usize, if (doubled) 2 else 1);
}

/// Size the window; false if QEMU clamped it (stock QEMU stops at 800 px).
pub fn init(width: u16, height: u16) bool {
    const size = @as(u32, width) << 16 | height;
    reg(bpp_value).* = 16;
    reg(win_size).* = size;
    return reg(win_size).* == size;
}

/// Copy the picture at `pixels` - packed rows, in VRAM - to the window on
/// QEMU's next screen refresh. Whatever address it is given is what it
/// reads, so showing another picture is naming another address.
pub fn update(pixels: usize, width: u16, height: u16) void {
    reg(update_from).* = 0;
    reg(update_to).* = @as(u32, width) << 16 | height;
    reg(update_content).* = @truncate(pixels); // CPU address of the pixels
    reg(update_status).* = 1;
}

/// Whether this QEMU gives the pointer over the window: our build's display,
/// version 0.3 or later. A stock one answers the registers with 0.
pub fn hasPointer() bool {
    const v = reg(version_reg).*;
    return (v >> 16) > 0 or (v & 0xFFFF) >= 3;
}

/// Whether this QEMU gives the pointer's right and middle buttons as well:
/// version 0.5 or later. An older one leaves them up.
pub fn hasAllButtons() bool {
    const v = reg(version_reg).*;
    return (v >> 16) > 0 or (v & 0xFFFF) >= 5;
}

/// Where the pointer is over the window, in its pixels, which of its buttons
/// are down, and how many pointer events there have been.
pub const Pointer = struct { x: u32, y: u32, left: bool, right: bool, middle: bool, seq: u32 };

pub fn pointer() Pointer {
    const v = reg(pointer_reg).*;
    return .{
        .x = (v >> 16) & 0x7FFF,
        .y = v & 0x3FFF,
        .left = v >> 31 != 0,
        .right = (v >> 15) & 1 != 0,
        .middle = (v >> 14) & 1 != 0,
        .seq = reg(pointer_seq_reg).*,
    };
}

/// Whether this QEMU gives the keys typed into the window: version 0.4 or
/// later.
pub fn hasKeyboard() bool {
    const v = reg(version_reg).*;
    return (v >> 16) > 0 or (v & 0xFFFF) >= 4;
}

/// A key that went down or up, by its Linux keycode.
pub const Key = struct { code: u32, down: bool };

/// The oldest key waiting, taken off the device's queue, or null for none.
pub fn key() ?Key {
    const v = reg(key_reg).*;
    if (v >> 31 == 0) return null;
    return .{ .code = v & 0xFFFF, .down = (v >> 30) & 1 != 0 };
}

/// How many keys wait.
pub fn keysWaiting() u32 {
    return reg(key_count_reg).*;
}
