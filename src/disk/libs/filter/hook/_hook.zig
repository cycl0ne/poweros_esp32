// SPDX-License-Identifier: MIT
//! The two hooks filter.library puts in bsdsocket.library's chains, and
//! putting them there and taking them out.
//!
//! **Coming in**: a segment of a connection the stack has passes; an
//! answer to a noted exchange passes; then the first rule that matches,
//! the interface's default, and pass. **Going out**: a UDP datagram or an
//! echo is noted, and everything passes.
//!
//! A hook runs under the stack's lock, on whichever task holds it; it
//! reads the clock first and then takes the library's spinlock for as
//! long as it reads the rules and the table. bsdsocket.library is opened
//! for the length of a load or a clear, on its caller's task, and the
//! hooks are added with PH_Keep, so they stay when that base is closed.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const _base = @import("../filter_base.zig");
const FilterBase = _base.FilterBase;
const match = @import("../rules/match.zig");

/// The hooks made, each pointing back at the base.
pub fn make(base: *FilterBase) void {
    base.in_hook = .{ .entry = &inEntry, .data = base };
    base.out_hook = .{ .entry = &outEntry, .data = base };
}

fn inEntry(hook: *utility.Hook, object: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
    const base: *FilterBase = @ptrCast(@alignCast(hook.data.?));
    const view: *const bsd.PacketView = @ptrCast(@alignCast(object.?));
    return decideIn(base, view);
}

fn outEntry(hook: *utility.Hook, object: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
    const base: *FilterBase = @ptrCast(@alignCast(hook.data.?));
    const view: *const bsd.PacketView = @ptrCast(@alignCast(object.?));
    noteOut(base, view);
    return bsd.PACKET_PASS;
}

/// What a packet coming in gets (see the file's head).
pub fn decideIn(base: *FilterBase, view: *const bsd.PacketView) u32 {
    if (view.belongs == bsd.PACKET_BELONGS_CONNECTION) return bsd.PACKET_PASS;
    const sys = base.sys_base;
    const now = _base.now(base);
    sys.AcquireLock(&base.lock);
    defer sys.ReleaseLock(&base.lock);
    const set = base.rules orelse return bsd.PACKET_PASS;
    if (base.flows.answers(view, now)) return bsd.PACKET_PASS;
    if (match.firstRule(set, view)) |rule| {
        rule.hits +%= 1;
        return rule.action.verdict();
    }
    if (match.defaultFor(set, view)) |each| {
        each.hits +%= 1;
        return each.action.verdict();
    }
    return bsd.PACKET_PASS;
}

/// A packet going out: the exchange it begins noted.
pub fn noteOut(base: *FilterBase, view: *const bsd.PacketView) void {
    const sys = base.sys_base;
    const now = _base.now(base);
    sys.AcquireLock(&base.lock);
    defer sys.ReleaseLock(&base.lock);
    if (base.rules == null) return;
    base.flows.note(view, now);
}

/// The hooks put in bsdsocket.library's chains, if they are not: false
/// when the library cannot be opened or takes them not.
pub fn hookIn(base: *FilterBase) bool {
    if (base.hooked != 0) return true;
    const sys = base.sys_base;
    const lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return false;
    defer sys.CloseLibrary(lib);
    const sb: *SocketBase = @ptrCast(lib);
    const keep = [_]utility.TagItem{ .{ .tag = bsd.PH_Keep, .data = 1 }, .{} };
    if (sb.AddPacketHook(&base.in_hook, &keep) != 0) return false;
    const outward = [_]utility.TagItem{ .{ .tag = bsd.PH_Keep, .data = 1 }, .{ .tag = bsd.PH_Direction, .data = bsd.PH_OUT }, .{} };
    if (sb.AddPacketHook(&base.out_hook, &outward) != 0) {
        sb.RemPacketHook(&base.in_hook);
        return false;
    }
    base.hooked = 1;
    return true;
}

/// The hooks taken out of bsdsocket.library's chains: when this returns,
/// neither runs.
pub fn hookOut(base: *FilterBase) void {
    if (base.hooked == 0) return;
    const sys = base.sys_base;
    // Open: the stack is there, and so are the hooks - it holds itself.
    const lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return;
    defer sys.CloseLibrary(lib);
    const sb: *SocketBase = @ptrCast(lib);
    sb.RemPacketHook(&base.in_hook);
    sb.RemPacketHook(&base.out_hook);
    base.hooked = 0;
}
