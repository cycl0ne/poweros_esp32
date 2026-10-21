// SPDX-License-Identifier: MPL-2.0
//! flash.device's chip on a machine with no flash for it: the disk image
//! the loader put in RAM (sdk.hardware.ramdisk), behaving as NOR flash
//! does - an erase sets a sector's bytes to 0xFF, and a program can only
//! clear bits (it ANDs the page in), so what flashfs does here it does on
//! a real chip. The image is the whole chip and the disk all of it, and
//! it is always mapped: it is memory. What is written is gone at power
//! off.
//!
//! The calls are the ESP32s' spiflash.zig's.

const ramdisk = @import("sdk").hardware.ramdisk;

pub const sector_size = 4096;
pub const page_size = 256;
pub const mmu_page_size = 64 * 1024;

var page: [page_size / 4]u32 = undefined;

fn bytes() [*]u8 {
    return @ptrFromInt(ramdisk.base);
}

/// The image's size, which is the disk's: null when there is no image, or
/// it is not whole sectors.
pub fn wholeDisk() ?u32 {
    if (ramdisk.base == 0 or ramdisk.size == 0) return null;
    if (ramdisk.size % sector_size != 0 or ramdisk.size > 0xFFFF_FFFF) return null;
    return @intCast(ramdisk.size);
}

/// The bytes of the disk that can be read straight from memory: all of it.
pub fn mapped() []const u8 {
    return bytes()[0..ramdisk.size];
}

/// Where `programPage` takes its bytes from: fill this, then call it.
pub fn pageBuffer() *align(4) [page_size]u8 {
    return @ptrCast(&page);
}

pub fn size() u32 {
    return @intCast(ramdisk.size);
}

/// Nothing to size: the image is as large as it is.
pub fn setSize(_: u32) bool {
    return true;
}

/// Nothing is write-protected.
pub fn unlock() bool {
    return true;
}

pub fn map(offset: u32, len: u32) usize {
    if (@as(usize, offset) + len > ramdisk.size) return 0;
    return ramdisk.base + offset;
}

pub fn eraseSector(sector: u32) bool {
    const at = @as(usize, sector) * sector_size;
    if (at + sector_size > ramdisk.size) return false;
    @memset(bytes()[at..][0..sector_size], 0xFF);
    return true;
}

/// `len` bytes of the page buffer ANDed in at `offset`.
pub fn programPage(offset: u32, len: u32) bool {
    if (@as(usize, offset) + len > ramdisk.size or len > page_size) return false;
    const from = pageBuffer();
    const into = bytes()[offset..][0..len];
    for (into, from[0..len]) |*byte, new| byte.* &= new;
    return true;
}

pub fn readRaw(from: u32, dest: [*]u32, len: u32) bool {
    if (@as(usize, from) + len > ramdisk.size) return false;
    const into: [*]u8 = @ptrCast(dest);
    @memcpy(into[0..len], bytes()[from..][0..len]);
    return true;
}
