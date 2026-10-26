// SPDX-License-Identifier: MIT
//! http.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const http = sdk.http;
const utility = sdk.utility;
const vec = exec.vec;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = @import("http_base.zig").HttpBase;
const http_init = @import("http_init.zig");

const CreateClient = @import("client/createclient.zig").CreateClient;
const DeleteClient = @import("client/deleteclient.zig").DeleteClient;
const OpenRequest = @import("request/openrequest.zig").OpenRequest;
const CloseRequest = @import("request/closerequest.zig").CloseRequest;
const ReadRequest = @import("request/readrequest.zig").ReadRequest;
const WriteRequest = @import("request/writerequest.zig").WriteRequest;
const GetRequestAttr = @import("request/getrequestattr.zig").GetRequestAttr;
const GetHeader = @import("request/getheader.zig").GetHeader;

/// http.library's interface, as the SDK generates it from
/// sdk/fd/http_lib.fd.
const interface = sdk.interface.http;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("http.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "http.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("client/createclient.zig"),
    @embedFile("client/deleteclient.zig"),
    @embedFile("request/openrequest.zig"),
    @embedFile("request/closerequest.zig"),
    @embedFile("request/readrequest.zig"),
    @embedFile("request/writerequest.zig"),
    @embedFile("request/getrequestattr.zig"),
    @embedFile("request/getheader.zig"),
};

fn lvoCreateClient(base: *HttpBase, socket_base: *SocketBase, tags: ?[*]const utility.TagItem) callconv(.c) ?*http.Client {
    return CreateClient(base, socket_base, tags);
}
fn lvoDeleteClient(base: *HttpBase, client: ?*http.Client) callconv(.c) void {
    return DeleteClient(base, client);
}
fn lvoOpenRequest(base: *HttpBase, client: *http.Client, method: [*:0]const u8, url: [*:0]const u8, tags: ?[*]const utility.TagItem, err: ?*i32) callconv(.c) ?*http.Request {
    return OpenRequest(base, client, method, url, tags, err);
}
fn lvoCloseRequest(base: *HttpBase, request: ?*http.Request) callconv(.c) void {
    return CloseRequest(base, request);
}
fn lvoReadRequest(base: *HttpBase, request: *http.Request, buffer: *anyopaque, length: u32) callconv(.c) i32 {
    return ReadRequest(base, request, buffer, length);
}
fn lvoWriteRequest(base: *HttpBase, request: *http.Request, data: ?*const anyopaque, length: u32) callconv(.c) i32 {
    return WriteRequest(base, request, data, length);
}
fn lvoGetRequestAttr(base: *HttpBase, request: *http.Request, attr: utility.Tag) callconv(.c) usize {
    return GetRequestAttr(base, request, attr);
}
fn lvoGetHeader(base: *HttpBase, request: *http.Request, name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return GetHeader(base, request, name);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(http_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoCreateClient),
    vec(lvoDeleteClient),
    vec(lvoOpenRequest),
    vec(lvoCloseRequest),
    vec(lvoReadRequest),
    vec(lvoWriteRequest),
    vec(lvoGetRequestAttr),
    vec(lvoGetHeader),
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
    try exec.libraries.checkForwarding(@embedFile("http_lvo.zig"), LVO, &.{});
}
