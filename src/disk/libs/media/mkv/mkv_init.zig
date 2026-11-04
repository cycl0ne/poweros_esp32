// SPDX-License-Identifier: MIT
//! mkv.container's ROM tag: a library's, opened by media.library as
//! "codecs/mkv.container".

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const mcontainer = sdk.mcontainer;
const module = @import("../mcontainer_module.zig");
const kind = @import("_mkv.zig");

pub const LIBRARY_NAME = "mkv.container";
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 2;
const BUILD_DATE = "04.11.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

pub const Module = module.Module(LIBRARY_REVISION, kind);

/// AUTOINIT: on the disk in LIBS:codecs/, made when media.library opens it
/// - ramlib loads the file and hands this tag to InitResident. In
/// `.resident`, which program.ld KEEPs.
pub export const mkv_container_tag: mcontainer.ResidentMContainer linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&mkv_container_tag),
        .flags = exec.RTF_AUTOINIT,
        .version = LIBRARY_VERSION,
        .type = .library,
        .pri = 0,
        .name = LIBRARY_NAME,
        .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
        .init = &Module.init_table,
    },
    .kinds = mcontainer.kindBit(media.MEDIA_MKV),
};
