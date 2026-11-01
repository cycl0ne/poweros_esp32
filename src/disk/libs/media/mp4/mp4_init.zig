// SPDX-License-Identifier: MIT
//! mp4.container's ROM tag: a library's, opened by media.library as
//! "codecs/mp4.container".

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const module = @import("../mcontainer_module.zig");
const kind = @import("_mp4.zig");

pub const LIBRARY_NAME = "mp4.container";
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 1;
const BUILD_DATE = "01.11.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

pub const Module = module.Module(LIBRARY_REVISION, kind);

/// AUTOINIT: on the disk in LIBS:codecs/, made when media.library opens it
/// - ramlib loads the file and hands this tag to InitResident. In
/// `.resident`, which program.ld KEEPs.
pub export const mp4_container_tag: exec.Resident linksection(".resident") = .{
    .match_tag = @ptrCast(&mp4_container_tag),
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &Module.init_table,
};
