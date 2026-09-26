// SPDX-License-Identifier: MIT
//! The rest of the adapter: the radio's power and clocks, time, random
//! numbers, the MAC address, the libraries' settings store, their log, and
//! the hooks for Bluetooth coexistence and sleep, which answer "nothing"
//! on a system with neither.
//!
//! **The settings store** (the NVS calls) keeps nothing: the libraries are
//! started with their store turned off and are given their settings each
//! time, so a read finds nothing and a write is accepted and dropped.
//!
//! **The log**: a warning or an error is printed on the raw port with the
//! libraries' tag; the rest only when the adapter traces.

const std = @import("std");
const sdk = @import("sdk");
const rng = sdk.hardware.rng;
const _osi = @import("_osi.zig");
const phy_file = @import("../phy/phy.zig");
const format = @import("../format.zig");

pub fn envIsChip() callconv(.c) bool {
    return true;
}

pub fn nothing() callconv(.c) void {}

pub fn phyEnable() callconv(.c) void {
    _osi.trace("phy_enable");
    phy_file.enable(&_osi.get().phy);
}

pub fn phyDisable() callconv(.c) void {
    _osi.trace("phy_disable");
    phy_file.disable(&_osi.get().phy);
}

pub fn phyUpdateCountryInfo(_: ?[*:0]const u8) callconv(.c) c_int {
    return 0;
}

/// ESP_MAC_WIFI_STA (0) is the factory address; the access point's
/// (ESP_MAC_WIFI_SOFTAP, 1) is the next one up.
pub fn readMac(mac: ?[*]u8, kind: c_uint) callconv(.c) c_int {
    const out = mac orelse return -1;
    var address = _osi.get().mac;
    if (kind == 1) address[5] +%= 1;
    @memcpy(out[0..6], &address);
    return 0;
}

pub fn wifiResetMac() callconv(.c) void {
    _osi.trace("wifi_reset_mac");
    phy_file.resetMac();
}

pub fn timerGetTime() callconv(.c) i64 {
    return @intCast(_osi.now());
}

pub fn slowClockCal() callconv(.c) u32 {
    return phy_file.slowClockCalibration();
}

// --- random numbers -------------------------------------------------------

pub fn rand() callconv(.c) u32 {
    return rng.read();
}

pub fn random() callconv(.c) c_ulong {
    return rng.read();
}

pub fn getRandom(buffer: ?[*]u8, length: usize) callconv(.c) c_int {
    const out = buffer orelse return -1;
    rng.fill(out[0..length]);
    return 0;
}

/// os_get_time: seconds and microseconds since the E-clock started.
const OsTime = extern struct { sec: u64, usec: c_long };

pub fn getTime(time: ?*anyopaque) callconv(.c) c_int {
    const out: *OsTime = @ptrCast(@alignCast(time orelse return -1));
    const us = _osi.now();
    out.* = .{ .sec = us / 1_000_000, .usec = @intCast(us % 1_000_000) };
    return 0;
}

pub fn logTimestamp() callconv(.c) u32 {
    return @truncate(_osi.now() / 1000);
}

// --- the settings store ---------------------------------------------------

/// ESP_ERR_NVS_NOT_FOUND.
const not_found: c_int = 0x1102;

pub fn nvsOpen(_: ?[*:0]const u8, _: c_uint, handle: ?*u32) callconv(.c) c_int {
    if (handle) |out| out.* = 1;
    return 0;
}

pub fn nvsClose(_: u32) callconv(.c) void {}

pub fn nvsCommit(_: u32) callconv(.c) c_int {
    return 0;
}

pub fn nvsSetI8(_: u32, _: ?[*:0]const u8, _: i8) callconv(.c) c_int {
    return 0;
}

pub fn nvsGetI8(_: u32, _: ?[*:0]const u8, _: ?*i8) callconv(.c) c_int {
    return not_found;
}

pub fn nvsSetU8(_: u32, _: ?[*:0]const u8, _: u8) callconv(.c) c_int {
    return 0;
}

pub fn nvsGetU8(_: u32, _: ?[*:0]const u8, _: ?*u8) callconv(.c) c_int {
    return not_found;
}

pub fn nvsSetU16(_: u32, _: ?[*:0]const u8, _: u16) callconv(.c) c_int {
    return 0;
}

pub fn nvsGetU16(_: u32, _: ?[*:0]const u8, _: ?*u16) callconv(.c) c_int {
    return not_found;
}

pub fn nvsSetBlob(_: u32, _: ?[*:0]const u8, _: ?*const anyopaque, _: usize) callconv(.c) c_int {
    return 0;
}

pub fn nvsGetBlob(_: u32, _: ?[*:0]const u8, _: ?*anyopaque, _: ?*usize) callconv(.c) c_int {
    return not_found;
}

pub fn nvsEraseKey(_: u32, _: ?[*:0]const u8) callconv(.c) c_int {
    return 0;
}

// --- the log --------------------------------------------------------------

/// ESP_LOG_ERROR, _WARN, _INFO.
const log_warn: c_uint = 2;

/// One line of the libraries' log: `wifi: <tag>: <text>`.
pub fn print(tag: ?[*:0]const u8, format_string: [*:0]const u8, args: *std.builtin.VaList) void {
    const state = _osi.adapter orelse return;
    var buffer: [160]u8 = undefined;
    var sink: format.Sink = .{ .buffer = &buffer };
    format.format(&sink, format_string, args);
    sink.finish();
    var end = @min(sink.length, buffer.len - 1);
    while (end > 0 and (buffer[end - 1] == '\n' or buffer[end - 1] == '\r')) end -= 1;
    buffer[end] = 0;
    const line: [*:0]const u8 = @ptrCast(&buffer);
    sdk.exec.kprintf(state.sys, "wifi: %s: %s\n", .{ tag orelse "", line });
}

fn shown(level: c_uint) bool {
    const state = _osi.adapter orelse return false;
    return level <= log_warn or state.trace;
}

pub fn logWrite(level: c_uint, tag: ?[*:0]const u8, format_string: ?[*:0]const u8, ...) callconv(.c) void {
    if (!shown(level)) return;
    var args = @cVaStart();
    defer @cVaEnd(&args);
    print(tag, format_string orelse return, &args);
}

pub fn logWritev(level: c_uint, tag: ?[*:0]const u8, format_string: ?[*:0]const u8, args: std.builtin.VaList) callconv(.c) void {
    if (!shown(level)) return;
    var copy = args;
    print(tag, format_string orelse return, &copy);
}

// --- coexistence ----------------------------------------------------------

pub fn coexZero() callconv(.c) c_int {
    return 0;
}

pub fn coexStatusGet() callconv(.c) u32 {
    return 0;
}

pub fn coexRequest(_: u32, _: u32, _: u32) callconv(.c) c_int {
    return 0;
}

pub fn coexRelease(_: u32) callconv(.c) c_int {
    return 0;
}

pub fn coexChannelSet(_: u8, _: u8) callconv(.c) c_int {
    return 0;
}

pub fn coexDurationGet(_: u32, duration: ?*u32) callconv(.c) c_int {
    if (duration) |out| out.* = 0;
    return 0;
}

pub fn coexPtiGet(_: u32, pti: ?*u8) callconv(.c) c_int {
    if (pti) |out| out.* = 0;
    return 0;
}

pub fn coexStatusBit(_: u32, _: u32) callconv(.c) void {}

pub fn coexIntervalSet(_: u32) callconv(.c) c_int {
    return 0;
}

pub fn coexPeriodGet() callconv(.c) u8 {
    return 0;
}

pub fn coexPhaseGet() callconv(.c) ?*anyopaque {
    return null;
}

pub fn coexRegisterCb(_: c_int, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

pub fn coexRegisterStartCb(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

pub fn coexFlexiblePeriodSet(_: u8) callconv(.c) c_int {
    return 0;
}

pub fn coexFlexiblePeriodGet() callconv(.c) u8 {
    return 1;
}

pub fn coexPhaseByIndex(_: c_int) callconv(.c) ?*anyopaque {
    return null;
}
