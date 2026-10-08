// SPDX-License-Identifier: MIT
//! mkicon: an icon made from a picture, on the host - for the icons the
//! build puts on the disk image.
//!
//!   mkicon <picture.png> <name.info> [KEY=value] ...
//!
//! The picture is a PNG; the icon is that PNG with its fields as the text
//! of an `icOn` chunk after `IHDR` (sdk/libs/icon/file.zig), in the order
//! given: `KIND=TOOL TOOL=SYS:Programs/MultiView TYPE=FILETYPE=text
//! STACK=16384 AT=20,10 WINDOW=40,30,400,200 VIEW=NAME SHOW=ALL`. An
//! `icOn` the picture had already is left out. What is written is read
//! back and its fields compared with what was given, so a field that would
//! not read stops the build here and not on the machine.

const std = @import("std");
const sdk = @import("sdk");
const iconfile = sdk.icon.file;
const decode = sdk.datatypes.png.decode;
const Io = std.Io;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("mkicon: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) fatal("usage: mkicon <picture.png> <name.info> [KEY=value] ...", .{});
    const cwd = Io.Dir.cwd();
    const picture = try cwd.readFileAlloc(io, args[1], arena, .limited(1024 * 1024));

    // The fields, a line each, each one that reads.
    var text: std.ArrayList(u8) = .empty;
    for (args[3..]) |field| {
        var one = iconfile.Fields{ .text = field };
        _ = one.next() orelse fatal("{s}: not a field (KIND, AT, TOOL, TYPE, STACK, WINDOW, SCROLL, VIEW, SHOW)", .{field});
        try text.appendSlice(arena, field);
        try text.append(arena, '\n');
    }
    if (text.items.len > iconfile.FIELDS_MAX) fatal("the fields are more than {d} bytes", .{iconfile.FIELDS_MAX});

    const info = decode.readInfo(picture) catch |failure| fatal("{s}: {t}", .{ args[1], failure });
    if (info.width > iconfile.PICTURE_MAX or info.height > iconfile.PICTURE_MAX) {
        fatal("{s}: {d}x{d} is more than {d} pixels either way", .{ args[1], info.width, info.height, iconfile.PICTURE_MAX });
    }
    const header = try iconfile.headerChunk(picture);
    const kept = try arena.alloc(u8, try iconfile.keptSize(picture));
    try iconfile.keepChunks(picture, kept);

    const out = try arena.alloc(u8, decode.signature.len + header.len + text.items.len + 12 + kept.len);
    var at: usize = 0;
    @memcpy(out[at..][0..decode.signature.len], &decode.signature);
    at += decode.signature.len;
    @memcpy(out[at..][0..header.len], header);
    at += header.len;
    at += iconfile.putChunk(iconfile.CHUNK_ID, text.items, out[at..][0 .. text.items.len + 12]);
    @memcpy(out[at..][0..kept.len], kept);
    at += kept.len;

    // Read back as the library reads it.
    const back = (iconfile.fieldsOf(out) catch |failure| fatal("written wrongly: {t}", .{failure})) orelse fatal("written without its fields", .{});
    if (!std.mem.eql(u8, back, text.items)) fatal("the fields read back are not the ones given", .{});
    _ = decode.readInfo(out) catch |failure| fatal("written wrongly: {t}", .{failure});

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out });
}
