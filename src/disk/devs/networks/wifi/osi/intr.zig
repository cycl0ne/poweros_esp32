// SPDX-License-Identifier: MIT
//! The adapter's interrupt calls. The libraries route the MAC's sources
//! (0, the MAC; 2, its power control) to one CPU line and set one handler
//! on it; here that is an exec interrupt server on each source, calling
//! the handler. exec routes a source to a line of its own when a server
//! goes on it, so the line number the libraries pick means nothing here.
//!
//! The handler runs with `in_isr` raised, which is how `_is_from_isr`
//! knows: nothing else calls the libraries from an interrupt.
//!
//! A flash write masks interrupts for the length of a page or an erase,
//! so the handler never runs while the cache is off, and runs late then.

const sdk = @import("sdk");
const exec = sdk.exec;
const intbits = sdk.hardware.intbits;
const _osi = @import("_osi.zig");

/// The sources the servers go on, in `servers` order.
const sources = [_]u32{ intbits.INTB_WIFI_MAC, intbits.INTB_WIFI_PWR };

fn server(data: ?*anyopaque, _: u32) callconv(.c) i32 {
    const state: *_osi.Adapter = @ptrCast(@alignCast(data.?));
    const handler = state.isr orelse return 0;
    state.in_isr += 1;
    handler(state.isr_arg);
    state.in_isr -= 1;
    return 1;
}

pub fn setIntr(_: i32, source: u32, _: u32, _: i32) callconv(.c) void {
    _osi.trace("set_intr");
    if (source < 32) _osi.get().sources |= @as(u32, 1) << @intCast(source);
}

pub fn clearIntr(_: u32, _: u32) callconv(.c) void {}

pub fn setIsr(_: i32, handler: ?*anyopaque, arg: ?*anyopaque) callconv(.c) void {
    _osi.trace("set_isr");
    const state = _osi.get();
    const sys = state.sys;
    sys.Disable();
    state.isr = @ptrCast(@alignCast(handler));
    state.isr_arg = arg;
    sys.Enable();
}

/// The servers on the routed sources (the mask's bit 0 is the libraries'
/// one line).
pub fn intsOn(mask: u32) callconv(.c) void {
    _osi.trace("ints_on");
    if (mask & 1 == 0) return;
    const state = _osi.get();
    for (sources, 0..) |source, i| {
        const bit = @as(u32, 1) << @intCast(source);
        if (state.sources & bit == 0 or state.hooked & bit != 0) continue;
        state.servers[i] = .{
            .node = .{ .type = .interrupt, .pri = 0, .name = "wifi.device" },
            .data = state,
            .code = &server,
        };
        state.sys.AddIntServer(source, &state.servers[i]);
        state.hooked |= bit;
    }
}

pub fn intsOff(mask: u32) callconv(.c) void {
    _osi.trace("ints_off");
    if (mask & 1 == 0) return;
    const state = _osi.get();
    for (sources, 0..) |source, i| {
        const bit = @as(u32, 1) << @intCast(source);
        if (state.hooked & bit == 0) continue;
        state.sys.RemIntServer(source, &state.servers[i]);
        state.hooked &= ~bit;
    }
}

pub fn isFromIsr() callconv(.c) bool {
    return _osi.get().in_isr != 0;
}
