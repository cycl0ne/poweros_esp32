// SPDX-License-Identifier: MIT
//! vp8.vcodec's ROM tag: a library's, with what it decodes - VP8, in
//! software - read from its file by videocodec.library without loading
//! it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vc = sdk.videocodec;
const vcodec = sdk.vcodec;
const module = @import("../module.zig");
const calls = @import("_vp8.zig");

pub const LIBRARY_NAME = "vp8.vcodec";
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "31.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

pub const Module = module.Module(LIBRARY_REVISION, calls);

/// AUTOINIT: on the disk in LIBS:codecs/, made when videocodec.library
/// opens it - ramlib loads the file and hands this tag to InitResident. In
/// `.resident`, which program.ld KEEPs.
pub export const vp8_vcodec_tag: vcodec.ResidentVCodec linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&vp8_vcodec_tag),
        .flags = exec.RTF_AUTOINIT,
        .version = LIBRARY_VERSION,
        .type = .library,
        .pri = 0,
        .name = LIBRARY_NAME,
        .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
        .init = &Module.init_table,
    },
    .codecs = vcodec.codecBit(vc.VCODEC_VP8),
    .kind = vcodec.VCMOD_SOFTWARE,
};
