// SPDX-License-Identifier: MIT
//! bsdsocket.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end. The stack's base and
//! every opener's base share this one table.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const utility = sdk.utility;
const vec = exec.vec;
const _base = @import("bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const bsdsocket_init = @import("bsdsocket_init.zig");

const Socket = @import("socket/socket.zig").Socket;
const Bind = @import("socket/bind.zig").Bind;
const Connect = @import("socket/connect.zig").Connect;
const SendTo = @import("socket/sendto.zig").SendTo;
const Send = @import("socket/send.zig").Send;
const RecvFrom = @import("socket/recvfrom.zig").RecvFrom;
const Recv = @import("socket/recv.zig").Recv;
const SetSockOpt = @import("socket/setsockopt.zig").SetSockOpt;
const GetSockOpt = @import("socket/getsockopt.zig").GetSockOpt;
const GetSockName = @import("socket/getsockname.zig").GetSockName;
const GetPeerName = @import("socket/getpeername.zig").GetPeerName;
const IoctlSocket = @import("socket/ioctlsocket.zig").IoctlSocket;
const CloseSocket = @import("socket/closesocket.zig").CloseSocket;
const WaitSelect = @import("socket/waitselect.zig").WaitSelect;
const GetDTableSize = @import("socket/getdtablesize.zig").GetDTableSize;
const Errno = @import("socket/errno.zig").Errno;
const SetErrnoPtr = @import("socket/seterrnoptr.zig").SetErrnoPtr;
const Inet_NtoA = @import("socket/inet_ntoa.zig").Inet_NtoA;
const Inet_Addr = @import("socket/inet_addr.zig").Inet_Addr;
const SocketBaseTagList = @import("socket/socketbasetaglist.zig").SocketBaseTagList;
const AddInterfaceTagList = @import("netif/addinterfacetaglist.zig").AddInterfaceTagList;
const RemoveInterface = @import("netif/removeinterface.zig").RemoveInterface;
const GetSocketEvents = @import("socket/getsocketevents.zig").GetSocketEvents;
const ReleaseSocket = @import("socket/releasesocket.zig").ReleaseSocket;
const ObtainSocket = @import("socket/obtainsocket.zig").ObtainSocket;

/// bsdsocket.library's interface, as the SDK generates it from
/// sdk/fd/bsdsocket_lib.fd.
const interface = sdk.interface.bsdsocket;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("bsdsocket.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "bsdsocket.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("socket/socket.zig"),
    @embedFile("socket/bind.zig"),
    @embedFile("socket/connect.zig"),
    @embedFile("socket/sendto.zig"),
    @embedFile("socket/send.zig"),
    @embedFile("socket/recvfrom.zig"),
    @embedFile("socket/recv.zig"),
    @embedFile("socket/setsockopt.zig"),
    @embedFile("socket/getsockopt.zig"),
    @embedFile("socket/getsockname.zig"),
    @embedFile("socket/getpeername.zig"),
    @embedFile("socket/ioctlsocket.zig"),
    @embedFile("socket/closesocket.zig"),
    @embedFile("socket/waitselect.zig"),
    @embedFile("socket/getdtablesize.zig"),
    @embedFile("socket/errno.zig"),
    @embedFile("socket/seterrnoptr.zig"),
    @embedFile("socket/inet_ntoa.zig"),
    @embedFile("socket/inet_addr.zig"),
    @embedFile("socket/socketbasetaglist.zig"),
    @embedFile("netif/addinterfacetaglist.zig"),
    @embedFile("netif/removeinterface.zig"),
    @embedFile("socket/getsocketevents.zig"),
    @embedFile("socket/releasesocket.zig"),
    @embedFile("socket/obtainsocket.zig"),
};

fn lvoSocket(sb: *SocketBase, domain: i32, socket_type: i32, protocol: i32) callconv(.c) i32 {
    return Socket(sb, domain, socket_type, protocol);
}
fn lvoBind(sb: *SocketBase, socket: i32, address: *const bsd.sockaddr, address_length: u32) callconv(.c) i32 {
    return Bind(sb, socket, address, address_length);
}
fn lvoConnect(sb: *SocketBase, socket: i32, address: *const bsd.sockaddr, address_length: u32) callconv(.c) i32 {
    return Connect(sb, socket, address, address_length);
}
fn lvoSendTo(sb: *SocketBase, socket: i32, message: *const anyopaque, length: u32, flags: u32, to: ?*const bsd.sockaddr, to_length: u32) callconv(.c) i32 {
    return SendTo(sb, socket, message, length, flags, to, to_length);
}
fn lvoSend(sb: *SocketBase, socket: i32, message: *const anyopaque, length: u32, flags: u32) callconv(.c) i32 {
    return Send(sb, socket, message, length, flags);
}
fn lvoRecvFrom(sb: *SocketBase, socket: i32, buffer: *anyopaque, length: u32, flags: u32, from: ?*bsd.sockaddr, from_length: ?*u32) callconv(.c) i32 {
    return RecvFrom(sb, socket, buffer, length, flags, from, from_length);
}
fn lvoRecv(sb: *SocketBase, socket: i32, buffer: *anyopaque, length: u32, flags: u32) callconv(.c) i32 {
    return Recv(sb, socket, buffer, length, flags);
}
fn lvoSetSockOpt(sb: *SocketBase, socket: i32, level: i32, option: i32, value: *const anyopaque, value_length: u32) callconv(.c) i32 {
    return SetSockOpt(sb, socket, level, option, value, value_length);
}
fn lvoGetSockOpt(sb: *SocketBase, socket: i32, level: i32, option: i32, value: *anyopaque, value_length: *u32) callconv(.c) i32 {
    return GetSockOpt(sb, socket, level, option, value, value_length);
}
fn lvoGetSockName(sb: *SocketBase, socket: i32, address: *bsd.sockaddr, address_length: *u32) callconv(.c) i32 {
    return GetSockName(sb, socket, address, address_length);
}
fn lvoGetPeerName(sb: *SocketBase, socket: i32, address: *bsd.sockaddr, address_length: *u32) callconv(.c) i32 {
    return GetPeerName(sb, socket, address, address_length);
}
fn lvoIoctlSocket(sb: *SocketBase, socket: i32, request: u32, argument: *anyopaque) callconv(.c) i32 {
    return IoctlSocket(sb, socket, request, argument);
}
fn lvoCloseSocket(sb: *SocketBase, socket: i32) callconv(.c) i32 {
    return CloseSocket(sb, socket);
}
fn lvoWaitSelect(sb: *SocketBase, count: i32, read: ?*bsd.fd_set, write: ?*bsd.fd_set, except: ?*bsd.fd_set, timeout: ?*timer.TimeVal, signals: ?*u32) callconv(.c) i32 {
    return WaitSelect(sb, count, read, write, except, timeout, signals);
}
fn lvoGetDTableSize(sb: *SocketBase) callconv(.c) i32 {
    return GetDTableSize(sb);
}
fn lvoErrno(sb: *SocketBase) callconv(.c) i32 {
    return Errno(sb);
}
fn lvoSetErrnoPtr(sb: *SocketBase, errno_pointer: ?*anyopaque, size: u32) callconv(.c) void {
    return SetErrnoPtr(sb, errno_pointer, size);
}
fn lvoInet_NtoA(sb: *SocketBase, address: u32) callconv(.c) [*:0]const u8 {
    return Inet_NtoA(sb, address);
}
fn lvoInet_Addr(sb: *SocketBase, text: [*:0]const u8) callconv(.c) u32 {
    return Inet_Addr(sb, text);
}
fn lvoSocketBaseTagList(sb: *SocketBase, tags: ?[*]const utility.TagItem) callconv(.c) i32 {
    return SocketBaseTagList(sb, tags);
}
fn lvoAddInterfaceTagList(sb: *SocketBase, name: [*:0]const u8, tags: ?[*]const utility.TagItem) callconv(.c) i32 {
    return AddInterfaceTagList(sb, name, tags);
}
fn lvoRemoveInterface(sb: *SocketBase, name: [*:0]const u8) callconv(.c) i32 {
    return RemoveInterface(sb, name);
}
fn lvoGetSocketEvents(sb: *SocketBase, events: *u32) callconv(.c) i32 {
    return GetSocketEvents(sb, events);
}
fn lvoReleaseSocket(sb: *SocketBase, socket: i32, id: i32) callconv(.c) i32 {
    return ReleaseSocket(sb, socket, id);
}
fn lvoObtainSocket(sb: *SocketBase, id: i32, domain: i32, socket_type: i32, protocol: i32) callconv(.c) i32 {
    return ObtainSocket(sb, id, domain, socket_type, protocol);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(bsdsocket_init.openVector),
    vec(bsdsocket_init.closeVector),
    vec(bsdsocket_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoSocket),
    vec(lvoBind),
    vec(lvoConnect),
    vec(lvoSendTo),
    vec(lvoSend),
    vec(lvoRecvFrom),
    vec(lvoRecv),
    vec(lvoSetSockOpt),
    vec(lvoGetSockOpt),
    vec(lvoGetSockName),
    vec(lvoGetPeerName),
    vec(lvoIoctlSocket),
    vec(lvoCloseSocket),
    vec(lvoWaitSelect),
    vec(lvoGetDTableSize),
    vec(lvoErrno),
    vec(lvoSetErrnoPtr),
    vec(lvoInet_NtoA),
    vec(lvoInet_Addr),
    vec(lvoSocketBaseTagList),
    vec(lvoAddInterfaceTagList),
    vec(lvoRemoveInterface),
    vec(lvoGetSocketEvents),
    vec(lvoReleaseSocket),
    vec(lvoObtainSocket),
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
    try exec.libraries.checkForwarding(@embedFile("bsdsocket_lvo.zig"), LVO, &.{});
}
