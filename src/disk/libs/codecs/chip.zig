// SPDX-License-Identifier: MIT
//! chip.vcodec: a codec module in LIBS:codecs/ - H.264 and H.265 decoded
//! by the board's chip, through videodec.resource. On a board without one
//! it opens no decoder (VCERR_NOCODEC), and videocodec.library tries the
//! next module.
//!
//! The ROM tag is chip/chip_init.zig, the decoder chip/_chip.zig (the
//! container's packets turned into Annex B by chip/annexb.zig), the base,
//! init, Expunge and jump table every module shares module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const chip_init = @import("chip/chip_init.zig");

comptime {
    _ = &chip_init.chip_vcodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a codec module, not a command\n", .{chip_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [chip_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = chip_init.LIBRARY_VERSION_STRING.*;
