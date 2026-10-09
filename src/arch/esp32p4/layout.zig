// SPDX-License-Identifier: MPL-2.0
//! The kernel image's memory map on this chip: the addresses kernel.ld
//! exports - its code in RAM and in flash, the ROM tags, .bss, the boot
//! stack and exec's heap.

extern var _bss_start: u8;
extern var _bss_end: u8;
extern var _heap_start: u8;
extern var _heap_end: u8;
extern var _stack_bottom: u8;
extern var _stack_top: u8;
extern var _resident_start: u8;
extern var _resident_end: u8;
extern var _ram_text_start: u8;
extern var _ram_text_end: u8;
extern var _flash_start: u8;
extern var _flash_end: u8;

/// A ROM tag's module size: its code and its data, in bytes.
pub const ResidentSize = extern struct { tag: u32, code: u32, data: u32 };

/// The module size of the ROM tag at `tag`: none measured on this chip
/// yet.
pub fn residentSize(_: usize) ?ResidentSize {
    return null;
}

/// Whether `address` is in the kernel's code: the RAM part's or the
/// flash part's (which holds its constants too).
pub fn inKernel(address: usize) bool {
    return (address >= @intFromPtr(&_ram_text_start) and address < @intFromPtr(&_ram_text_end)) or
        (address >= @intFromPtr(&_flash_start) and address < @intFromPtr(&_flash_end));
}

pub fn bssEnd() usize {
    return @intFromPtr(&_bss_end);
}
pub fn heapStart() usize {
    return @intFromPtr(&_heap_start);
}
pub fn heapEnd() usize {
    return @intFromPtr(&_heap_end);
}
pub fn stackBottom() usize {
    return @intFromPtr(&_stack_bottom);
}
pub fn stackTop() usize {
    return @intFromPtr(&_stack_top);
}
/// The .resident section: the kernel's ROM tags.
pub fn residentStart() usize {
    return @intFromPtr(&_resident_start);
}
pub fn residentEnd() usize {
    return @intFromPtr(&_resident_end);
}
