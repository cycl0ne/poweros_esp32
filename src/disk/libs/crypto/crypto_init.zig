// SPDX-License-Identifier: MIT
//! crypto.library's ROM tag, its init and its Expunge. Open and Close
//! are exec's standard ones: every opener shares the one base.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("crypto_base.zig");
const CryptoBase = _base.CryptoBase;
const _engine = @import("engine/_engine.zig");
const crypto_lvo = @import("crypto_lvo.zig");

pub const LIBRARY_NAME = crypto.CRYPTONAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 1;
const BUILD_DATE = "03.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in, the engines' locks made, and the engines started.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const cb = _base.cryptoBase(lib);
    const header = lib.*;
    cb.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    lib.revision = LIBRARY_REVISION;
    sys_base.InitSemaphore(&cb.sha_lock);
    sys_base.InitSemaphore(&cb.aes_lock);
    sys_base.InitSemaphore(&cb.rsa_lock);
    // Inside Disable: the engines' clocks and resets are SYSTEM's
    // registers, shared with the other core's drivers.
    sys_base.Disable();
    _engine.start();
    sys_base.Enable();
    return lib;
}

/// The library goes when nobody has it open: the engines stopped, the
/// base freed, and the file it was loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const cb = _base.cryptoBase(lib);
    const sys = cb.sys_base;
    const seg_list = cb.seg_list;
    sys.Disable();
    _engine.stop();
    sys.Enable();
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(CryptoBase),
    .vectors = &crypto_lvo.vectors,
    .vector_count = crypto_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it - ramlib loads the file and hands this tag to
/// InitResident. In `.resident`, which program.ld KEEPs.
pub export const crypto_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &crypto_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
