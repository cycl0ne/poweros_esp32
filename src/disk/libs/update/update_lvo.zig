// SPDX-License-Identifier: MIT
//! update.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const update = sdk.update;
const utility = sdk.utility;
const vec = exec.vec;
const UpdateBase = @import("update_base.zig").UpdateBase;
const update_init = @import("update_init.zig");

const CreateUpdate = @import("run/createupdate.zig").CreateUpdate;
const DoUpdate = @import("run/doupdate.zig").DoUpdate;
const GetUpdateInfo = @import("run/getupdateinfo.zig").GetUpdateInfo;
const DeleteUpdate = @import("run/deleteupdate.zig").DeleteUpdate;
const ConfirmUpdate = @import("boot/confirmupdate.zig").ConfirmUpdate;

/// update.library's interface, as the SDK generates it from
/// sdk/fd/update_lib.fd.
const interface = sdk.interface.update;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("update.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "update.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("run/createupdate.zig"),
    @embedFile("run/doupdate.zig"),
    @embedFile("run/getupdateinfo.zig"),
    @embedFile("run/deleteupdate.zig"),
    @embedFile("boot/confirmupdate.zig"),
};

fn lvoCreateUpdate(base: *UpdateBase, tags: ?[*]const utility.TagItem) callconv(.c) ?*update.Update {
    return @ptrCast(CreateUpdate(base, tags));
}
fn lvoDoUpdate(base: *UpdateBase, run: *update.Update, tags: ?[*]const utility.TagItem) callconv(.c) i32 {
    return DoUpdate(base, @ptrCast(@alignCast(run)), tags);
}
fn lvoGetUpdateInfo(base: *UpdateBase, run: *update.Update, info: *update.UpdateInfo) callconv(.c) void {
    return GetUpdateInfo(base, @ptrCast(@alignCast(run)), info);
}
fn lvoDeleteUpdate(base: *UpdateBase, run: ?*update.Update) callconv(.c) void {
    return DeleteUpdate(base, @ptrCast(@alignCast(run)));
}
fn lvoConfirmUpdate(base: *UpdateBase, tags: ?[*]const utility.TagItem) callconv(.c) i32 {
    return ConfirmUpdate(base, tags);
}

/// The standard four, then the library's own in .fd order.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(update_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoCreateUpdate),
    vec(lvoDoUpdate),
    vec(lvoGetUpdateInfo),
    vec(lvoDeleteUpdate),
    vec(lvoConfirmUpdate),
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
    try exec.libraries.checkForwarding(@embedFile("update_lvo.zig"), LVO, &.{});
}
