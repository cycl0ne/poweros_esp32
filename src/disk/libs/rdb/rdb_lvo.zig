// SPDX-License-Identifier: MIT
//! rdb.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const vec = exec.vec;
const RDBBase = @import("rdb_base.zig").RDBBase;
const rdb_init = @import("rdb_init.zig");

const OpenRDB = @import("handle/openrdb.zig").OpenRDB;
const CloseRDB = @import("handle/closerdb.zig").CloseRDB;
const InitRDB = @import("table/initrdb.zig").InitRDB;
const NextPartition = @import("partition/nextpartition.zig").NextPartition;
const FindPartition = @import("partition/findpartition.zig").FindPartition;
const AddPartition = @import("partition/addpartition.zig").AddPartition;
const RemPartition = @import("partition/rempartition.zig").RemPartition;
const WriteRDB = @import("table/writerdb.zig").WriteRDB;

/// rdb.library's interface, as the SDK generates it from
/// sdk/fd/rdb_lib.fd.
const interface = sdk.interface.rdb;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("rdb.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "rdb.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("handle/openrdb.zig"),
    @embedFile("handle/closerdb.zig"),
    @embedFile("table/initrdb.zig"),
    @embedFile("partition/nextpartition.zig"),
    @embedFile("partition/findpartition.zig"),
    @embedFile("partition/addpartition.zig"),
    @embedFile("partition/rempartition.zig"),
    @embedFile("table/writerdb.zig"),
};

fn lvoOpenRDB(base: *RDBBase, device: [*:0]const u8, unit: u32, err: ?*i32) callconv(.c) ?*rdb.RDBHandle {
    return OpenRDB(base, device, unit, err);
}
fn lvoCloseRDB(base: *RDBBase, handle: ?*rdb.RDBHandle) callconv(.c) void {
    return CloseRDB(base, handle);
}
fn lvoInitRDB(base: *RDBBase, handle: *rdb.RDBHandle) callconv(.c) i32 {
    return InitRDB(base, handle);
}
fn lvoNextPartition(base: *RDBBase, handle: *rdb.RDBHandle, previous: ?*rdb.RDBPartition) callconv(.c) ?*rdb.RDBPartition {
    return NextPartition(base, handle, previous);
}
fn lvoFindPartition(base: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8) callconv(.c) ?*rdb.RDBPartition {
    return FindPartition(base, handle, name);
}
fn lvoAddPartition(base: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8, low_cyl: u32, high_cyl: u32, dos_type: u32) callconv(.c) i32 {
    return AddPartition(base, handle, name, low_cyl, high_cyl, dos_type);
}
fn lvoRemPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.RDBPartition) callconv(.c) void {
    return RemPartition(base, handle, partition);
}
fn lvoWriteRDB(base: *RDBBase, handle: *rdb.RDBHandle) callconv(.c) i32 {
    return WriteRDB(base, handle);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(rdb_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenRDB),
    vec(lvoCloseRDB),
    vec(lvoInitRDB),
    vec(lvoNextPartition),
    vec(lvoFindPartition),
    vec(lvoAddPartition),
    vec(lvoRemPartition),
    vec(lvoWriteRDB),
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
    try exec.libraries.checkForwarding(@embedFile("rdb_lvo.zig"), LVO, &.{});
}
