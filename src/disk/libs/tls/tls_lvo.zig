// SPDX-License-Identifier: MIT
//! tls.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const tls = sdk.tls;
const utility = sdk.utility;
const vec = exec.vec;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TLSBase = @import("tls_base.zig").TLSBase;
const tls_init = @import("tls_init.zig");

const OpenSession = @import("session/opensession.zig").OpenSession;
const CloseSession = @import("session/closesession.zig").CloseSession;
const ReadSession = @import("session/readsession.zig").ReadSession;
const WriteSession = @import("session/writesession.zig").WriteSession;
const SessionPending = @import("session/sessionpending.zig").SessionPending;
const GetSessionAttr = @import("session/getsessionattr.zig").GetSessionAttr;

/// tls.library's interface, as the SDK generates it from sdk/fd/tls_lib.fd.
const interface = sdk.interface.tls;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("tls.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "tls.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("session/opensession.zig"),
    @embedFile("session/closesession.zig"),
    @embedFile("session/readsession.zig"),
    @embedFile("session/writesession.zig"),
    @embedFile("session/sessionpending.zig"),
    @embedFile("session/getsessionattr.zig"),
};

fn lvoOpenSession(base: *TLSBase, socket_base: *SocketBase, socket: i32, tags: ?[*]const utility.TagItem, err: ?*i32) callconv(.c) ?*tls.Session {
    return OpenSession(base, socket_base, socket, tags, err);
}
fn lvoCloseSession(base: *TLSBase, session: ?*tls.Session) callconv(.c) void {
    return CloseSession(base, session);
}
fn lvoReadSession(base: *TLSBase, session: *tls.Session, buffer: *anyopaque, length: u32) callconv(.c) i32 {
    return ReadSession(base, session, buffer, length);
}
fn lvoWriteSession(base: *TLSBase, session: *tls.Session, data: *const anyopaque, length: u32) callconv(.c) i32 {
    return WriteSession(base, session, data, length);
}
fn lvoSessionPending(base: *TLSBase, session: *tls.Session) callconv(.c) u32 {
    return SessionPending(base, session);
}
fn lvoGetSessionAttr(base: *TLSBase, session: *tls.Session, attr: utility.Tag) callconv(.c) usize {
    return GetSessionAttr(base, session, attr);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(tls_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenSession),
    vec(lvoCloseSession),
    vec(lvoReadSession),
    vec(lvoWriteSession),
    vec(lvoSessionPending),
    vec(lvoGetSessionAttr),
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
    try exec.libraries.checkForwarding(@embedFile("tls_lvo.zig"), LVO, &.{});
}
