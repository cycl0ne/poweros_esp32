// SPDX-License-Identifier: MPL-2.0
//! The kernel image's memory map on this chip: the addresses kernel.ld
//! exports - the ROM tags, .bss, the boot stack and exec's heap.

extern var _bss_start: u8;
extern var _bss_end: u8;
extern var _heap_start: u8;
extern var _heap_end: u8;
extern var _stack_bottom: u8;
extern var _stack_top: u8;
extern var _resident_start: u8;
extern var _resident_end: u8;

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
