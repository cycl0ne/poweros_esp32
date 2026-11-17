// SPDX-License-Identifier: MPL-2.0
//! vchiq.resource's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vec = exec.vec;
const vchiq = sdk.resources.vchiq;
const VchiqBase = @import("vchiq_base.zig").VchiqBase;
const OpenService = @import("service/openservice.zig").OpenService;
const CloseService = @import("service/closeservice.zig").CloseService;
const SendMessage = @import("service/sendmessage.zig").SendMessage;
const ReceiveMessage = @import("service/receivemessage.zig").ReceiveMessage;
const QueueBulk = @import("service/queuebulk.zig").QueueBulk;
const WaitBulk = @import("service/waitbulk.zig").WaitBulk;

/// vchiq.resource's interface, as the SDK generates it from
/// sdk/fd/vchiq_lib.fd.
const interface = sdk.interface.vchiq;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("vchiq.resource: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "vchiq.resource", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("service/openservice.zig"),
    @embedFile("service/closeservice.zig"),
    @embedFile("service/sendmessage.zig"),
    @embedFile("service/receivemessage.zig"),
    @embedFile("service/queuebulk.zig"),
    @embedFile("service/waitbulk.zig"),
};

fn lvoOpenService(vb: *VchiqBase, fourcc: u32, version: u32, version_min: u32, err: ?*u32) callconv(.c) ?*vchiq.VchiqService {
    return OpenService(vb, fourcc, version, version_min, err);
}
fn lvoCloseService(vb: *VchiqBase, service: ?*vchiq.VchiqService) callconv(.c) void {
    CloseService(vb, service);
}
fn lvoSendMessage(vb: *VchiqBase, service: *vchiq.VchiqService, data: [*]const u8, size: u32) callconv(.c) u32 {
    return SendMessage(vb, service, data, size);
}
fn lvoReceiveMessage(vb: *VchiqBase, service: *vchiq.VchiqService, buffer: [*]u8, size: u32, length: *u32, timeout_us: u64) callconv(.c) u32 {
    return ReceiveMessage(vb, service, buffer, size, length, timeout_us);
}
fn lvoQueueBulk(vb: *VchiqBase, service: *vchiq.VchiqService, bulk: *vchiq.VchiqBulk) callconv(.c) u32 {
    return QueueBulk(vb, service, bulk);
}
fn lvoWaitBulk(vb: *VchiqBase, bulk: *vchiq.VchiqBulk, timeout_us: u64) callconv(.c) u32 {
    return WaitBulk(vb, bulk, timeout_us);
}

/// The jump table, in slot order: a resource has no standard vectors, so
/// its first function is in the first slot.
pub const vectors = [_]*const anyopaque{
    vec(lvoOpenService),
    vec(lvoCloseService),
    vec(lvoSendMessage),
    vec(lvoReceiveMessage),
    vec(lvoQueueBulk),
    vec(lvoWaitBulk),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: this resource's own, from the first slot" {
    try testing.expectEqual(@as(usize, @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("vchiq_lvo.zig"), LVO, &.{});
}
