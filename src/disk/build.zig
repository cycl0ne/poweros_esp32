// SPDX-License-Identifier: MIT
//! The disk's own programs as a Zig package: the commands in C:, the test
//! programs in C:test, the libraries, devices and handlers loaded from
//! LIBS:, DEVS: and HANDLERS:, and the scripts in S:. Every one of them is
//! built against the SDK package alone.
//!
//! What it builds is listed here (`programs`, `files`), and each is handed
//! out under its place on the disk - `c/list`, `devs/sd.device`,
//! `s/startup-sequence` - as a named lazy path, so the system's build can
//! put them on its disk image without knowing how they are made. Built on
//! its own, the load files land in `zig-out/bin`.

const std = @import("std");
const poweros_sdk = @import("poweros_sdk");

/// Something built for the disk: its place there, its root source file,
/// and the name its load file is known by.
pub const Program = struct { disk: []const u8, source: []const u8, name: []const u8 };

/// Something copied onto the disk as it is.
pub const File = struct { disk: []const u8, source: []const u8 };

/// What a command is for decides which directory it lives in, and the one
/// name serves for both the source tree and the disk: `c` is what the
/// system is used with, `c/test` the programs that exercise a device or a
/// library and print what happened.
const commands = [_][]const u8{
    "type",       "dir",      "delete",  "makedir",       "rename",
    "avail",      "assign",   "version", "addbuffers",    "which",
    "list",       "format",   "protect", "changetaskpri", "wait",
    "info",       "platform", "copy",    "rdb",           "i2c",
    "backlight",  "rtg",      "show",    "setmap",        "mount",
    "showconfig",
};
const tests = [_][]const u8{
    "hello",     "echoargs", "testlib",  "gfx",   "anim",
    "intuition", "console",  "keyboard", "touch", "input",
    "lines",     "nyan",     "plasma",   "audio", "fonts",
};

/// Modules on the disk: built exactly as a command is. What makes one a
/// module is the ROM tag in it: ramlib finds a library's or a device's
/// after LoadSeg and hands it to InitResident, dos finds a handler's when
/// the device it serves is first used. Each goes where its kind is looked
/// for - LIBS:, DEVS:, HANDLERS:.
const modules = [_]Program{
    .{ .disk = "libs/hello.library", .source = "libs/hello/hello.zig", .name = "hello.library" },
    .{ .disk = "devs/sd.device", .source = "devs/sd/sd.zig", .name = "sd.device" },
    .{ .disk = "handlers/fat-handler", .source = "handlers/fat/fat.zig", .name = "fat-handler" },
};

pub const programs: []const Program = blk: {
    var list: [commands.len + tests.len + modules.len]Program = undefined;
    var n: usize = 0;
    for (commands) |name| {
        list[n] = .{ .disk = "c/" ++ name, .source = "c/" ++ name ++ "/" ++ name ++ ".zig", .name = name };
        n += 1;
    }
    for (tests) |name| {
        list[n] = .{ .disk = "c/test/" ++ name, .source = "c/test/" ++ name ++ "/" ++ name ++ ".zig", .name = name };
        n += 1;
    }
    for (modules) |module| {
        list[n] = module;
        n += 1;
    }
    const done = list;
    break :blk &done;
};

/// The scripts in S:, and what HANDLERS: holds for Mount to read.
pub const files = [_]File{
    .{ .disk = "s/startup-sequence", .source = "s/startup-sequence" },
    .{ .disk = "s/shell-startup", .source = "s/shell-startup" },
    .{ .disk = "handlers/mountlist", .source = "handlers/mountlist" },
};

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSafe)") orelse .ReleaseSafe;
    const sdk = b.dependency("poweros_sdk", .{});
    for (programs) |program| {
        const seg = poweros_sdk.addProgram(b, sdk, .{ .name = program.name, .root = b.path(program.source), .optimize = optimize });
        b.addNamedLazyPath(program.disk, seg);
        b.getInstallStep().dependOn(&b.addInstallBinFile(seg, b.fmt("{s}.seg", .{program.name})).step);
    }
    for (files) |file| b.addNamedLazyPath(file.disk, b.path(file.source));
}
