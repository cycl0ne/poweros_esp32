// SPDX-License-Identifier: MIT
//! Host tests of what AddDataTypes makes of a descriptor's words: the
//! four characters of a group or an id, the bytes of a mask, the kind a
//! TYPE names, and a whole descriptor read with its tools.

const std = @import("std");
const sdk = @import("sdk");
const datatypes = sdk.datatypes;
const iffparse = sdk.iffparse;
const add = @import("../descriptor.zig");
const host = @import("host_rom");
const kexec = host.exec;

const testing = std.testing;

test "AddDataTypes: four characters, short ones filled out with spaces" {
    try testing.expectEqual(iffparse.MakeID("ILBM"), add.idOf("ILBM"));
    try testing.expectEqual(iffparse.MakeID("pict"), add.idOf("pict"));
    try testing.expectEqual(iffparse.MakeID("BMP "), add.idOf("BMP"));
    try testing.expectEqual(iffparse.MakeID("MD  "), add.idOf("MD"));
    // More than four is cut, since an id is four characters and no more.
    try testing.expectEqual(iffparse.MakeID("LONG"), add.idOf("LONGER"));
}

test "AddDataTypes: a mask's bytes, its wildcards and its numbers" {
    var bytes: [16]u8 = @splat(0xAA);
    var any: [16]u8 = @splat(0xAA);
    try testing.expectEqual(@as(u16, 12), add.readMask("FORM????ILBM", &bytes, &any, bytes.len));
    try testing.expectEqualSlices(u8, "FORM", bytes[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, any[0..4]);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1 }, any[4..8]);
    try testing.expectEqualSlices(u8, "ILBM", bytes[8..12]);

    // A byte written as a number, for a signature that is not text.
    try testing.expectEqual(@as(u16, 4), add.readMask("\\x89PNG", &bytes, &any, bytes.len));
    try testing.expectEqual(@as(u8, 0x89), bytes[0]);
    try testing.expectEqualSlices(u8, "PNG", bytes[1..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, any[0..4]);

    // Longer than there is room for is cut where the room ends.
    var small: [2]u8 = undefined;
    var small_any: [2]u8 = undefined;
    try testing.expectEqual(@as(u16, 2), add.readMask("FORM", &small, &small_any, small.len));
}

test "AddDataTypes: what a TYPE word names" {
    try testing.expectEqual(datatypes.DTF_IFF, add.kindOf("IFF"));
    try testing.expectEqual(datatypes.DTF_ASCII, add.kindOf("ASCII"));
    try testing.expectEqual(datatypes.DTF_MISC, add.kindOf("MISC"));
    try testing.expectEqual(datatypes.DTF_BINARY, add.kindOf("BINARY"));
    // Nothing said is plain bytes.
    try testing.expectEqual(datatypes.DTF_BINARY, add.kindOf(null));
}

test "AddDataTypes: a descriptor's tools, a node each in its one block" {
    const db = try host.dos.testSetUp();
    const dl = host.dos.testBase(db);
    const sys = kexec.SysBase.iface();
    var text = "NAME=Markdown BASE=markdown GROUP=text ID=MD PATTERN=#?.(md|markdown) TYPE=ASCII EDIT=SYS:Programs/Notepad BROWSE=SYS:Programs/MultiView\n".*;
    const dt = add.readDescriptor(sys, dl, @ptrCast(db.utility_base), &text).?;
    try testing.expectEqualStrings("SYS:Programs/MultiView", std.mem.span(datatypes.toolFor(dt, datatypes.TW_BROWSE).?));
    try testing.expectEqualStrings("SYS:Programs/Notepad", std.mem.span(datatypes.toolFor(dt, datatypes.TW_EDIT).?));
    try testing.expect(datatypes.toolFor(dt, datatypes.TW_PRINT) == null);
    // In the order of their kinds, whatever the file's order: BROWSE first.
    const first: *const datatypes.ToolNode = @ptrCast(@alignCast(dt.tools.first().?));
    try testing.expectEqual(datatypes.TW_BROWSE, first.tool.which);
    try testing.expectEqual(datatypes.TF_SHELL, first.tool.flags);
    try testing.expectEqualStrings("Markdown", std.mem.span(dt.header.name));
    sys.FreeVec(dt);

    // None given: an empty list.
    var plain = "NAME=Binary BASE=binary GROUP=syst ID=BINA TYPE=BINARY PRI=-128\n".*;
    const bare = add.readDescriptor(sys, dl, @ptrCast(db.utility_base), &plain).?;
    try testing.expect(bare.tools.isEmpty());
    sys.FreeVec(bare);
    try host.dos.testTearDown(db);
    kexec.deinit();
}
