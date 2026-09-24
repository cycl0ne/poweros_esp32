// SPDX-License-Identifier: MPL-2.0
//! The kernel image's memory map on this chip: the addresses kernel.ld
//! exports - IRAM, DRAM, the ROM tags, the heap, the boot stack and the
//! code in flash - and the table of each ROM tag's module size, which
//! tools/ressize.zig fills in after linking.

extern var _iram_start: u8;
extern var _iram_end: u8;
extern var _dram_start: u8;
extern var _bss_start: u8;
extern var _bss_end: u8;
extern var _heap_start: u8;
extern var _heap_end: u8;
extern var _stack_bottom: u8;
extern var _stack_top: u8;
extern var _resident_start: u8;
extern var _resident_end: u8;
extern var _flash_text_start: u8;
extern var _flash_text_end: u8;

pub fn iramStart() usize {
    return @intFromPtr(&_iram_start);
}
pub fn iramEnd() usize {
    return @intFromPtr(&_iram_end);
}
pub fn dramStart() usize {
    return @intFromPtr(&_dram_start);
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
/// The code in flash (.flash.text), mapped at boot.
pub fn flashTextStart() usize {
    return @intFromPtr(&_flash_text_start);
}
pub fn flashTextEnd() usize {
    return @intFromPtr(&_flash_text_end);
}

/// A ROM tag's module size: its code (.text) and data (.rodata, .data and
/// the tag), in bytes.
pub const ResidentSize = extern struct { tag: u32, code: u32, data: u32 };

/// How many ROM tags the build can measure. ressize takes the capacity
/// from the table's size and fails the build beyond it.
pub const max_residents = 64;

/// Filled in after linking by tools/ressize.zig, from the ELF's symbol
/// sizes. In .data, so the table is in the image for the tool to patch (a
/// zeroed one would go to .bss).
export var resident_sizes: [max_residents]ResidentSize linksection(".data.resident_sizes") =
    [_]ResidentSize{.{ .tag = 0, .code = 0, .data = 0 }} ** max_residents;

/// The module size of the ROM tag at `tag`, if the build measured it.
pub fn residentSize(tag: usize) ?ResidentSize {
    const table: *volatile [max_residents]ResidentSize = &resident_sizes;
    for (table) |entry| {
        if (entry.tag == tag) return entry;
    }
    return null;
}
