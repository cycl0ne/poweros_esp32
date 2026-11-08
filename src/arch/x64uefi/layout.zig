// SPDX-License-Identifier: MPL-2.0
//! The kernel image's memory map: the addresses kernel.ld exports - its
//! code, the ROM tags, .bss, the boot stack - and where exec's heap
//! starts. The image is one block in RAM, code and data together.

extern var _text_start: u8;
extern var _text_end: u8;
extern var _image_end: u8;
extern var _bss_start: u8;
extern var _bss_end: u8;
extern var _heap_start: u8;
extern var _stack_bottom: u8;
extern var _stack_top: u8;
extern var _resident_start: u8;
extern var _resident_end: u8;

/// A ROM tag's module size: its code and its data, in bytes.
pub const ResidentSize = extern struct { tag: u32, code: u32, data: u32 };

/// The module size of the ROM tag at `tag`: none measured on this chip
/// yet.
pub fn residentSize(_: usize) ?ResidentSize {
    return null;
}

/// Whether `address` is in the kernel's code.
pub fn inKernel(address: usize) bool {
    return address >= @intFromPtr(&_text_start) and address < @intFromPtr(&_text_end);
}

/// The code. platform.resource's names are the ESP32s': the code in
/// internal RAM is all of it, the data starts at the ROM tags, and there
/// is no code in flash.
pub fn iramStart() usize {
    return textStart();
}
pub fn iramEnd() usize {
    return textEnd();
}
pub fn dramStart() usize {
    return residentStart();
}
pub fn flashTextStart() usize {
    return 0;
}
pub fn flashTextEnd() usize {
    return 0;
}

pub fn textStart() usize {
    return @intFromPtr(&_text_start);
}
pub fn textEnd() usize {
    return @intFromPtr(&_text_end);
}
/// The whole image as loaded: code, constants and data.
pub fn imageEnd() usize {
    return @intFromPtr(&_image_end);
}
pub fn bssStart() usize {
    return @intFromPtr(&_bss_start);
}
pub fn bssEnd() usize {
    return @intFromPtr(&_bss_end);
}
/// Where exec's heap starts: above the boot stack. It runs to the end of
/// RAM (ram.zig).
pub fn heapStart() usize {
    return @intFromPtr(&_heap_start);
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
