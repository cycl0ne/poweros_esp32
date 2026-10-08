// SPDX-License-Identifier: MIT
//! icon.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const icon = sdk.icon;
const vec = exec.vec;
const IconBase = @import("icon_base.zig").IconBase;
const icon_init = @import("icon_init.zig");

const GetDiskObject = @import("object/getdiskobject.zig").GetDiskObject;
const PutDiskObject = @import("object/putdiskobject.zig").PutDiskObject;
const FreeDiskObject = @import("object/freediskobject.zig").FreeDiskObject;
const GetDiskObjectNew = @import("object/getdiskobjectnew.zig").GetDiskObjectNew;
const DeleteDiskObject = @import("object/deletediskobject.zig").DeleteDiskObject;
const GetDefDiskObject = @import("default/getdefdiskobject.zig").GetDefDiskObject;
const PutDefDiskObject = @import("default/putdefdiskobject.zig").PutDefDiskObject;
const FindToolType = @import("tooltype/findtooltype.zig").FindToolType;
const MatchToolValue = @import("tooltype/matchtoolvalue.zig").MatchToolValue;
const BumpRevision = @import("name/bumprevision.zig").BumpRevision;

/// icon.library's interface, as the SDK generates it from
/// sdk/fd/icon_lib.fd.
const interface = sdk.interface.icon;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("icon.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "icon.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("object/getdiskobject.zig"),
    @embedFile("object/putdiskobject.zig"),
    @embedFile("object/freediskobject.zig"),
    @embedFile("object/getdiskobjectnew.zig"),
    @embedFile("object/deletediskobject.zig"),
    @embedFile("default/getdefdiskobject.zig"),
    @embedFile("default/putdefdiskobject.zig"),
    @embedFile("tooltype/findtooltype.zig"),
    @embedFile("tooltype/matchtoolvalue.zig"),
    @embedFile("name/bumprevision.zig"),
};

fn lvoGetDiskObject(base: *IconBase, name: ?[*:0]const u8) callconv(.c) ?*icon.DiskObject {
    return GetDiskObject(base, name);
}
fn lvoPutDiskObject(base: *IconBase, name: [*:0]const u8, object: *const icon.DiskObject) callconv(.c) bool {
    return PutDiskObject(base, name, object);
}
fn lvoFreeDiskObject(base: *IconBase, object: ?*icon.DiskObject) callconv(.c) void {
    return FreeDiskObject(base, object);
}
fn lvoGetDiskObjectNew(base: *IconBase, name: [*:0]const u8) callconv(.c) ?*icon.DiskObject {
    return GetDiskObjectNew(base, name);
}
fn lvoDeleteDiskObject(base: *IconBase, name: [*:0]const u8) callconv(.c) bool {
    return DeleteDiskObject(base, name);
}
fn lvoGetDefDiskObject(base: *IconBase, kind: u32) callconv(.c) ?*icon.DiskObject {
    return GetDefDiskObject(base, kind);
}
fn lvoPutDefDiskObject(base: *IconBase, object: *const icon.DiskObject) callconv(.c) bool {
    return PutDefDiskObject(base, object);
}
fn lvoFindToolType(base: *IconBase, types: ?[*]const ?[*:0]const u8, name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return FindToolType(base, types, name);
}
fn lvoMatchToolValue(base: *IconBase, value: [*:0]const u8, wanted: [*:0]const u8) callconv(.c) bool {
    return MatchToolValue(base, value, wanted);
}
fn lvoBumpRevision(base: *IconBase, into: [*]u8, name: [*:0]const u8) callconv(.c) [*:0]u8 {
    return BumpRevision(base, into, name);
}

/// The standard four, then the library's own in .fd order.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(icon_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoGetDiskObject),
    vec(lvoPutDiskObject),
    vec(lvoFreeDiskObject),
    vec(lvoGetDiskObjectNew),
    vec(lvoDeleteDiskObject),
    vec(lvoGetDefDiskObject),
    vec(lvoPutDefDiskObject),
    vec(lvoFindToolType),
    vec(lvoMatchToolValue),
    vec(lvoBumpRevision),
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
    try exec.libraries.checkForwarding(@embedFile("icon_lvo.zig"), LVO, &.{});
}
