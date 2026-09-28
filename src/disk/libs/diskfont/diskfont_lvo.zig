// SPDX-License-Identifier: MIT
//! diskfont.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const fontfile = sdk.diskfont.fontfile;
const vec = exec.vec;
const DiskfontBase = @import("diskfont_base.zig").DiskfontBase;
const diskfont_init = @import("diskfont_init.zig");

const OpenDiskFont = @import("font/opendiskfont.zig").OpenDiskFont;
const AvailFonts = @import("font/availfonts.zig").AvailFonts;
const NewFontContents = @import("contents/newfontcontents.zig").NewFontContents;
const DisposeFontContents = @import("contents/disposefontcontents.zig").DisposeFontContents;
const NewScaledDiskFont = @import("font/newscaleddiskfont.zig").NewScaledDiskFont;

/// diskfont.library's interface, as the SDK generates it from
/// sdk/fd/diskfont_lib.fd.
const interface = sdk.interface.diskfont;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("diskfont.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "diskfont.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("font/opendiskfont.zig"),
    @embedFile("font/availfonts.zig"),
    @embedFile("contents/newfontcontents.zig"),
    @embedFile("contents/disposefontcontents.zig"),
    @embedFile("font/newscaleddiskfont.zig"),
};

fn lvoOpenDiskFont(dfb: *DiskfontBase, text_attr: *const graphics.TextAttr) callconv(.c) ?*graphics.TextFont {
    return OpenDiskFont(dfb, text_attr);
}
fn lvoAvailFonts(dfb: *DiskfontBase, buffer: *anyopaque, buffer_size: u32, flags: u32) callconv(.c) u32 {
    return AvailFonts(dfb, buffer, buffer_size, flags);
}
fn lvoNewFontContents(dfb: *DiskfontBase, lock: ?*dos.FileLock, name: [*:0]const u8) callconv(.c) ?*fontfile.ContentsHeader {
    return NewFontContents(dfb, lock, name);
}
fn lvoDisposeFontContents(dfb: *DiskfontBase, contents: ?*fontfile.ContentsHeader) callconv(.c) void {
    return DisposeFontContents(dfb, contents);
}
fn lvoNewScaledDiskFont(dfb: *DiskfontBase, font: *graphics.TextFont, text_attr: *const graphics.TextAttr) callconv(.c) ?*graphics.TextFont {
    return NewScaledDiskFont(dfb, font, text_attr);
}

pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(diskfont_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenDiskFont),
    vec(lvoAvailFonts),
    vec(lvoNewFontContents),
    vec(lvoDisposeFontContents),
    vec(lvoNewScaledDiskFont),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("diskfont_lvo.zig"), LVO, &.{});
}
