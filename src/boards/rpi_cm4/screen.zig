// SPDX-License-Identifier: MPL-2.0
//! The picture on the Compute Module 4's HDMI port, asked of the
//! VideoCore's firmware before anything else runs (`boards.firmware_screen`).
//!
//! The board has no serial port, so the screen is where the kernel's
//! first lines can be read, and where a boot that stops says why. The
//! firmware drives the display itself - it read the monitor's EDID and
//! lit a mode on it before the kernel started - and hands out a
//! framebuffer in its own memory through the mailbox's property channel:
//! the size it lit, 32 bits a pixel, the buffer's address and the bytes
//! between rows. The kernel writes its lines there (src/arch/screentext.zig)
//! and declares it a panel part (CHIP_UEFI_FB, the framebuffer a firmware
//! lit), which the display driver takes over from the kernel once the
//! cold start is done (rtg_driver/fbboard/uefi.zig).
//!
//! **Before exec, without it.** Nothing allocates yet, so the message is
//! written into low RAM the firmware reaches - its first GiB, of which
//! the first 2 MiB hold nothing but the firmware's spin table in page 0
//! until exec is handed them - and pushed past the caches by hand: the
//! firmware reads it from memory and writes its answer there. The
//! VideoCore names RAM by its bus address, the ARM's with the top two bits
//! of the first GiB's alias; the buffer it gives back is in its own memory
//! below 1 GiB, which the kernel maps without caches.

const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const rtg = sdk.rtg;
const tags = rtg.tags;
const Tag = sdk.utility.FixedTagItem;
const reg = sdk.hardware.mmio.reg;
const hwcpu = sdk.hardware.cpu;
const system = @import("system.zig");

/// The picture the firmware lit, as it handed it over.
pub const Picture = sdk.hardware.videocore.Picture;

/// Where the message is written: 1 MiB, between the firmware's page 0 and
/// the kernel's load address, 16-byte aligned (the low four bits of the
/// mailbox's word are its channel).
const message_at: usize = 0x0010_0000;
const message_words = 40;

const MAIL0_READ: usize = 0x00;
const MAIL0_STATUS: usize = 0x18;
const MAIL1_WRITE: usize = 0x20;
const MAIL1_STATUS: usize = 0x38;
const STATUS_FULL: u32 = 1 << 31;
const STATUS_EMPTY: u32 = 1 << 30;
const CHANNEL_PROPERTY: u32 = 8;
const CODE_SUCCESS: u32 = 0x8000_0000;

const TAG_ALLOCATE_BUFFER: u32 = 0x0004_0001;
const TAG_GET_PHYSICAL_SIZE: u32 = 0x0004_0003;
const TAG_GET_PITCH: u32 = 0x0004_0008;
const TAG_SET_PHYSICAL_SIZE: u32 = 0x0004_8003;
const TAG_SET_VIRTUAL_SIZE: u32 = 0x0004_8004;
const TAG_SET_DEPTH: u32 = 0x0004_8005;
const TAG_SET_PIXEL_ORDER: u32 = 0x0004_8006;
const TAG_SET_VIRTUAL_OFFSET: u32 = 0x0004_8009;
/// The firmware's word for blue, green, red in memory - a 32-bit word
/// 0x00RRGGBB, the library's bgra32 - which it calls BGR. Its other
/// order, RGB (1), is red first in memory: the HVS's plane then reads the
/// pixels as ABGR (its control word's order 3), not as ARGB (2).
const ORDER_BGR: u32 = 0;

/// The size asked for where the firmware says it lit none: what a
/// monitor that gives no EDID takes.
const fallback_width: u32 = 1920;
const fallback_height: u32 = 1080;
/// The largest picture asked for: the firmware's own limit.
const most_side: u32 = 4096;

/// How long the firmware is given to answer, in counter ticks.
fn deadline() u64 {
    return hwcpu.time() + hwcpu.counterFrequency() / 2;
}

fn words() *volatile [message_words]u32 {
    return @ptrFromInt(message_at);
}

/// The message's lines written back to memory and dropped from the
/// caches: before it goes, so the firmware reads it, and after the answer,
/// so the cores read the firmware's.
fn pushOut() void {
    var at: usize = message_at;
    while (at < message_at + message_words * 4) : (at += 64) {
        asm volatile ("dc civac, %[at]"
            :
            : [at] "r" (at),
            : .{ .memory = true });
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

/// The message in `words()` sent on the property channel, and its answer
/// waited for: false when the firmware did not take it or answer in time,
/// or answered that it failed.
fn send() bool {
    pushOut();
    const until = deadline();
    while (reg(system.mailbox + MAIL1_STATUS).* & STATUS_FULL != 0) {
        if (hwcpu.time() > until) return false;
    }
    // The first GiB as the VideoCore names it from its side: uncached.
    const sent: u32 = @as(u32, @intCast(message_at)) | 0xC000_0000 | CHANNEL_PROPERTY;
    reg(system.mailbox + MAIL1_WRITE).* = sent;
    while (true) {
        if (reg(system.mailbox + MAIL0_STATUS).* & STATUS_EMPTY == 0) {
            if (reg(system.mailbox + MAIL0_READ).* == sent) break;
            continue;
        }
        if (hwcpu.time() > until) return false;
    }
    pushOut();
    return words()[1] == CODE_SUCCESS;
}

/// A tag written at `at`: its id, its value's size, the request code and
/// the value. Where the next one goes.
fn put(at: usize, tag: u32, value: []const u32) usize {
    const w = words();
    w[at] = tag;
    w[at + 1] = @intCast(value.len * 4);
    w[at + 2] = 0;
    for (value, 0..) |word, index| w[at + 3 + index] = word;
    return at + 3 + value.len;
}

/// The message's head and end around tags that end at `end`.
fn close(end: usize) void {
    const w = words();
    w[end] = 0;
    w[0] = @intCast((end + 1) * 4);
    w[1] = 0;
}

/// The picture the firmware lit, or null where it lit none or would not
/// say: its size as the firmware chose it from the monitor, 32 bits a
/// pixel.
pub fn ask() ?Picture {
    // What it lit.
    var at = put(2, TAG_GET_PHYSICAL_SIZE, &.{ 0, 0 });
    close(at);
    var width = fallback_width;
    var height = fallback_height;
    if (send()) {
        const w = words();
        if (w[5] != 0 and w[6] != 0) {
            width = @min(w[5], most_side);
            height = @min(w[6], most_side);
        }
    }
    // That size, as a buffer of 32-bit pixels, blue first in memory.
    at = 2;
    at = put(at, TAG_SET_PHYSICAL_SIZE, &.{ width, height });
    at = put(at, TAG_SET_VIRTUAL_SIZE, &.{ width, height });
    at = put(at, TAG_SET_VIRTUAL_OFFSET, &.{ 0, 0 });
    const depth_at = at + 3;
    at = put(at, TAG_SET_DEPTH, &.{32});
    const order_at = at + 3;
    at = put(at, TAG_SET_PIXEL_ORDER, &.{ORDER_BGR});
    const buffer_at = at + 3;
    at = put(at, TAG_ALLOCATE_BUFFER, &.{ 4096, 0 });
    const pitch_at = at + 3;
    at = put(at, TAG_GET_PITCH, &.{0});
    close(at);
    if (!send()) return null;
    const w = words();
    if (w[depth_at] != 32) return null;
    // The VideoCore's bus address of its own memory, as the ARM has it.
    const base: usize = w[buffer_at] & 0x3FFF_FFFF;
    const bytes: usize = w[buffer_at + 1];
    const pitch = w[pitch_at];
    if (base == 0 or bytes == 0 or pitch < width * 4) return null;
    if (@as(usize, pitch) * height > bytes) return null;
    return .{
        .base = base,
        .bytes = bytes,
        .width = width,
        .height = height,
        .pitch = pitch,
        .bgra = w[order_at] == ORDER_BGR,
    };
}

/// The picture as the board's panel part, for the display driver:
/// filled in by `declare`.
var panel: [12]Tag = @splat(.done);

/// `picture` written into the board's description as the panel the
/// firmware lit. Nothing where its pixels are in an order the display
/// driver does not draw; the kernel's lines are drawn on it all the same,
/// white on black.
pub fn declare(picture: Picture) bool {
    if (!picture.bgra) return false;
    panel = .{
        .value(st.PART_Kind, st.PARTKIND_PANEL),
        .value(st.PART_Chip, st.CHIP_UEFI_FB),
        .pointer(st.PART_ChipName, "videocore framebuffer"),
        .value(st.PART_Bus, st.BUS_MEMORY),
        .value(st.PART_Address, picture.base),
        .value(tags.RTGA_Width, picture.width),
        .value(tags.RTGA_Height, picture.height),
        .value(tags.RTGA_Pitch, picture.pitch),
        .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32)),
        // At most sixteen pictures at once - screens, and the buffers
        // behind them - each taken from memory as it is opened: a ceiling,
        // not memory set aside.
        .value(tags.RTGA_Buffers, 16),
        // The windows of a screen each draw into a buffer of their own,
        // and what can be seen of them is copied into the screen's.
        .value(tags.RTGA_Compose, 1),
        .done,
    };
    return system.addPart(&panel);
}
