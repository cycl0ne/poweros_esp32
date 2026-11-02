// SPDX-License-Identifier: MIT
//! flac.acodec's ROM tag: a library's, opened by audiocodec.library as
//! "codecs/flac.acodec".

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const acodec = sdk.acodec;
const module = @import("../acodec_module.zig");
const kind = @import("_flac.zig");

pub const LIBRARY_NAME = "flac.acodec";
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "01.11.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

pub const Module = module.Module(LIBRARY_REVISION, kind, kind.Flac);

/// AUTOINIT: on the disk in LIBS:codecs/, made when audiocodec.library
/// opens it - ramlib loads the file and hands this tag to InitResident. In
/// `.resident`, which program.ld KEEPs.
pub export const flac_acodec_tag: acodec.ResidentACodec linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&flac_acodec_tag),
        .flags = exec.RTF_AUTOINIT,
        .version = LIBRARY_VERSION,
        .type = .library,
        .pri = 0,
        .name = LIBRARY_NAME,
        .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
        .init = &Module.init_table,
    },
    .codecs = acodec.codecBit(ac.ACODEC_FLAC),
    .kind = acodec.ACMOD_SOFTWARE,
};
