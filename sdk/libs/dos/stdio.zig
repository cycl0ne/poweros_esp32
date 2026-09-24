// SPDX-License-Identifier: MIT
//! dos.library's buffered I/O (dos/stdio.h): SetVBuf's modes, the buffer's
//! default size, and FPrintf/Printf, which pack their values for VFPrintf
//! and VPrintf as kprintf does for RawDoFmt (the format is RawDoFmt's:
//! `%d %u %x %c` 32 bits, with `l` 64, `%s` a C string), checked at
//! compile time.
//!
//!   _ = sdk.dos.stdio.FPrintf(dl, fh, "%s: %d lines\n", .{ name, count });

const exec = @import("../exec/exec.zig");
const dosextens = @import("dosextens.zig");
const DosBase = @import("../../interface/dos.zig").DosBase;

/// Line buffered: written out at a newline, on consoles (IsInteractive);
/// other files like BUF_FULL. Every handle starts so.
pub const BUF_LINE: i32 = 0;
/// Written out when the buffer is full.
pub const BUF_FULL: i32 = 1;
/// No buffering: each FPutC goes out, FGetC reads one byte at a time.
pub const BUF_NONE: i32 = 2;

/// FGetC's answer at the end of the file (or on an error).
pub const ENDSTREAMCH: i32 = -1;

/// The buffer dos allocates on a handle's first buffered call; SetVBuf
/// picks another.
pub const BUFFER_SIZE: u32 = 1024;
/// How many characters UnGetC can push back.
pub const UNGET_MAX = 4;

/// VFPrintf with the values packed from a tuple: the bytes written, or -1.
pub fn FPrintf(dl: *DosBase, file: ?*dosextens.FileHandle, comptime format: [:0]const u8, args: anytype) i32 {
    comptime exec.checkFormat(format, @TypeOf(args));
    const stream = exec.fmtStream(args);
    return dl.VFPrintf(file, format, &stream);
}

/// VPrintf (to Output()) with the values packed from a tuple.
pub fn Printf(dl: *DosBase, comptime format: [:0]const u8, args: anytype) i32 {
    comptime exec.checkFormat(format, @TypeOf(args));
    const stream = exec.fmtStream(args);
    return dl.VPrintf(format, &stream);
}
