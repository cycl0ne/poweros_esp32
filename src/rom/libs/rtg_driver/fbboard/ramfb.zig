// SPDX-License-Identifier: MPL-2.0
//! QEMU's ramfb (CHIP_QEMU_RAMFB): a picture in the machine's own RAM,
//! which the emulator shows in its window. It is told where the picture
//! is, its size, its pitch and its pixel format by writing the file
//! "etc/ramfb" of the firmware configuration device (fw_cfg), and reads
//! the picture from RAM at every refresh of the window - so what the CPU
//! writes is seen with nothing handed on, and showing another buffer is
//! writing the file again.
//!
//! fw_cfg on the virt machine is a register window (the part's
//! PART_Address): a selector, a data port and the address of a DMA
//! request, a few words in RAM that say what to read or write where. The
//! device carries the request out before the write that names it returns,
//! and clears the request's control word when it is done. Everything it
//! reads or writes is big-endian. Only what the ramfb needs is here: the
//! device's signature, its directory, and a write.

const std = @import("std");
const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const reg8 = sdk.hardware.mmio.reg8;

const DATA = 0x00;
const SELECTOR = 0x08;
const DMA_ADDRESS = 0x10;

/// The items every fw_cfg has.
const ITEM_SIGNATURE: u16 = 0x0000;
const ITEM_ID: u16 = 0x0001;
const ITEM_FILE_DIR: u16 = 0x0019;
/// ITEM_ID: the DMA interface is there.
const ID_DMA: u32 = 1 << 1;

/// A DMA request's control word.
const CONTROL_ERROR: u32 = 1 << 0;
const CONTROL_READ: u32 = 1 << 1;
const CONTROL_SELECT: u32 = 1 << 3;
const CONTROL_WRITE: u32 = 1 << 4;

const Request = extern struct {
    control: u32,
    length: u32,
    address: u64,
};

/// A directory entry, as the device has it.
const File = extern struct {
    size: u32,
    select: u16,
    reserved: u16,
    name: [56]u8,
};

/// What "etc/ramfb" holds: 28 bytes, as the emulator reads them.
const Config = extern struct {
    address: u64,
    fourcc: u32,
    flags: u32,
    width: u32,
    height: u32,
    pitch: u32,
};
const config_bytes = 28;

/// The DRM name of each format the window takes: 'XR24' is the bytes B,
/// G, R and one unused - bgra32 - and 'RG16' is rgb565.
const FOURCC_XRGB8888: u32 = 0x3432_5258;
const FOURCC_RGB565: u32 = 0x3631_4752;

pub const Format = enum { bgra32, rgb565 };

/// How many times a request is looked at before it is given up: it is done
/// before the write that names it returns, so the first look is the last.
const patience: u32 = 1000;

/// The ramfb found: the fw_cfg it is in, and its file's selector.
pub const Ramfb = struct {
    base: usize,
    select: u16,
};

/// The item `item`'s first bytes, through the data port.
fn readItem(base: usize, item: u16, into: []u8) void {
    const selector: *volatile u16 = @ptrFromInt(base + SELECTOR);
    selector.* = @byteSwap(item);
    for (into) |*byte| byte.* = reg8(base + DATA).*;
}

/// One DMA request: `length` bytes between `address` and the item
/// selected, which `control` says.
fn transfer(base: usize, control: u32, address: usize, length: u32) bool {
    var request: Request = .{
        .control = @byteSwap(control),
        .length = @byteSwap(length),
        .address = @byteSwap(@as(u64, address)),
    };
    const at = @intFromPtr(&request);
    // The request is in memory before the device is told where it is.
    sdk.hardware.barrier.toDevice();
    reg(base + DMA_ADDRESS).* = @byteSwap(@as(u32, @truncate(at >> 32)));
    reg(base + DMA_ADDRESS + 4).* = @byteSwap(@as(u32, @truncate(at)));
    sdk.hardware.barrier.full();
    const word: *volatile u32 = &request.control;
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        const now = @byteSwap(word.*);
        if (now & CONTROL_ERROR != 0) return false;
        if (now == 0) return true;
    }
    return false;
}

/// The ramfb, when the fw_cfg at `base` is one with a DMA interface and
/// lists "etc/ramfb": QEMU started with `-device ramfb`.
pub fn find(base: usize) ?Ramfb {
    var signature: [4]u8 = undefined;
    readItem(base, ITEM_SIGNATURE, &signature);
    if (!std.mem.eql(u8, &signature, "QEMU")) return null;
    var id: [4]u8 = undefined;
    readItem(base, ITEM_ID, &id);
    if (@as(u32, id[0]) & ID_DMA == 0) return null;

    var count_be: u32 = 0;
    if (!transfer(base, CONTROL_SELECT | CONTROL_READ | @as(u32, ITEM_FILE_DIR) << 16, @intFromPtr(&count_be), 4)) return null;
    var left = @byteSwap(count_be);
    while (left != 0) : (left -= 1) {
        var file: File = undefined;
        if (!transfer(base, CONTROL_READ, @intFromPtr(&file), @sizeOf(File))) return null;
        const name = "etc/ramfb";
        if (std.mem.eql(u8, file.name[0..name.len], name) and file.name[name.len] == 0) {
            if (@byteSwap(file.size) != config_bytes) return null;
            return .{ .base = base, .select = @byteSwap(file.select) };
        }
    }
    return null;
}

/// Show the picture at `address`: `width` by `height` pixels, rows
/// `pitch` bytes apart, in `format`. The window takes it at its next
/// refresh. False if the device would not have it.
pub fn show(ramfb: Ramfb, address: usize, width: u32, height: u32, pitch: u32, format: Format) bool {
    const config: Config = .{
        .address = @byteSwap(@as(u64, address)),
        .fourcc = @byteSwap(switch (format) {
            .bgra32 => FOURCC_XRGB8888,
            .rgb565 => FOURCC_RGB565,
        }),
        .flags = 0,
        .width = @byteSwap(width),
        .height = @byteSwap(height),
        .pitch = @byteSwap(pitch),
    };
    return transfer(ramfb.base, CONTROL_SELECT | CONTROL_WRITE | @as(u32, ramfb.select) << 16, @intFromPtr(&config), config_bytes);
}
