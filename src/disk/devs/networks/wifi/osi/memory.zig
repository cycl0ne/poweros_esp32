// SPDX-License-Identifier: MIT
//! The adapter's memory calls. Every block comes from internal memory:
//! the MAC reads and writes its frame buffers by DMA, and the interrupt
//! handler reads the libraries' state, and neither may go through the
//! PSRAM cache. Each block carries its size (`_osi.alloc`), for realloc
//! and for the C library's `free`, which the libraries also call.

const _osi = @import("_osi.zig");

pub fn malloc(size: usize) callconv(.c) ?*anyopaque {
    return _osi.alloc(size, true, false);
}

pub fn free(memory: ?*anyopaque) callconv(.c) void {
    _osi.free(memory);
}

pub fn realloc(memory: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return _osi.realloc(memory, size, true);
}

pub fn calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    return _osi.alloc(count * size, true, true);
}

pub fn zalloc(size: usize) callconv(.c) ?*anyopaque {
    return _osi.alloc(size, true, true);
}

pub fn freeHeapSize() callconv(.c) u32 {
    const sdk = @import("sdk");
    return @intCast(_osi.get().sys.AvailMem(sdk.exec.MEMF_INTERNAL));
}
