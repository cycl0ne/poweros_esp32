// SPDX-License-Identifier: MIT
//! What the radio's libraries take by name from the system beyond the
//! adapter and the chip's ROM: a few C library calls, their own printf
//! hooks, the PHY's critical section, and data.
//!
//! The ROM has the string and memory functions (`memcpy`, `strlen`, ...)
//! and the compiler's helpers; what it lacks is what formats (`sprintf`,
//! `puts`), `free` for blocks the adapter gave out, and `hexstr2bin`.
//! `memcpy`, `memmove` and `memset` are defined here all the same, and hand
//! over to the ROM's: the compiler's own would otherwise take the names.
//!
//! **The data**: the delays the radio's fine timing measurement adds on
//! each kind of channel, and the vendor number ESP-NOW frames carry.
//! Neither feature is used; the libraries refer to both.

const _osi = @import("osi/_osi.zig");
const sync = @import("osi/sync.zig");
const system = @import("osi/system.zig");
const format = @import("format.zig");

export fn sprintf(buffer: [*]u8, format_string: [*:0]const u8, ...) callconv(.c) c_int {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    var sink: format.Sink = .{ .buffer = buffer[0..0xFFFF] };
    format.format(&sink, format_string, &args);
    sink.put(0);
    return @intCast(sink.length - 1);
}

/// The ROM's memory functions, under the second names romld gives them.
const RomCopy = *const fn (?*anyopaque, ?*const anyopaque, usize) callconv(.c) ?*anyopaque;
const RomSet = *const fn (?*anyopaque, c_int, usize) callconv(.c) ?*anyopaque;
const rom_memcpy = @extern(RomCopy, .{ .name = "rom.memcpy" });
const rom_memmove = @extern(RomCopy, .{ .name = "rom.memmove" });
const rom_memset = @extern(RomSet, .{ .name = "rom.memset" });

/// memcpy, memmove and memset are the ROM's, for everything in this
/// device. The libraries were built against them, and they copy the keys
/// into the MAC's key registers with memcpy: the ROM's stores whole words
/// where both sides are aligned, while the compiler's own stores what it
/// likes, and the registers take nothing from a store narrower than a
/// word - the keys went in as zeroes, and nothing encrypted was sent or
/// received.
export fn memcpy(to: ?*anyopaque, from: ?*const anyopaque, length: usize) callconv(.c) ?*anyopaque {
    return rom_memcpy(to, from, length);
}

export fn memmove(to: ?*anyopaque, from: ?*const anyopaque, length: usize) callconv(.c) ?*anyopaque {
    return rom_memmove(to, from, length);
}

export fn memset(to: ?*anyopaque, value: c_int, length: usize) callconv(.c) ?*anyopaque {
    return rom_memset(to, value, length);
}

export fn puts(text: [*:0]const u8) callconv(.c) c_int {
    const state = _osi.adapter orelse return 0;
    @import("sdk").exec.kprintf(state.sys, "wifi: %s\n", .{text});
    return 0;
}

export fn free(memory: ?*anyopaque) callconv(.c) void {
    _osi.free(memory);
}

fn hexValue(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// `length` bytes from twice as many hex digits; -1 at the first that is
/// not one.
export fn hexstr2bin(hex: [*]const u8, out: [*]u8, length: usize) callconv(.c) c_int {
    for (0..length) |i| {
        const high = hexValue(hex[2 * i]) orelse return -1;
        const low = hexValue(hex[2 * i + 1]) orelse return -1;
        out[i] = high << 4 | low;
    }
    return 0;
}

fn hook(comptime tag: [*:0]const u8) type {
    return struct {
        fn printf(format_string: [*:0]const u8, ...) callconv(.c) c_int {
            var args = @cVaStart();
            defer @cVaEnd(&args);
            system.print(tag, format_string, format.OwnList{ .list = &args });
            return 0;
        }
    };
}

comptime {
    @export(&hook("phy").printf, .{ .name = "phy_printf" });
    @export(&hook("pp").printf, .{ .name = "pp_printf" });
    @export(&hook("net80211").printf, .{ .name = "net80211_printf" });
    @export(&sync.phyEnterCritical, .{ .name = "phy_enter_critical" });
    @export(&sync.phyExitCritical, .{ .name = "phy_exit_critical" });
}

export var g_espnow_user_oui: [3]u8 = .{ 0x18, 0xfe, 0x34 };

export var est_PHY_INIT_FTM_COMP_20_20U_MHZ: u16 = 453;
export var est_PHY_INIT_FTM_COMP_20_20U_MHZ_DIS: u16 = 453;
export var est_PHY_INIT_FTM_COMP_20_20D_MHZ: u16 = 453;
export var est_PHY_INIT_FTM_COMP_20_20D_MHZ_DIS: u16 = 454;
export var est_PHY_RESP_FTM_COMP_20_20U_MHZ: u16 = 444;
export var est_PHY_RESP_FTM_COMP_20_20U_MHZ_DIS: u16 = 444;
export var est_PHY_RESP_FTM_COMP_20_20D_MHZ: u16 = 440;
export var est_PHY_RESP_FTM_COMP_20_20D_MHZ_DIS: u16 = 440;
export var est_PHY_INIT_FTM_COMP_20_40U_MHZ: u16 = 271;
export var est_PHY_INIT_FTM_COMP_20_40U_MHZ_DIS: u16 = 269;
export var est_PHY_INIT_FTM_COMP_20_40D_MHZ: u16 = 270;
export var est_PHY_INIT_FTM_COMP_20_40D_MHZ_DIS: u16 = 270;
export var est_PHY_RESP_FTM_COMP_20_40U_MHZ: u16 = 262;
export var est_PHY_RESP_FTM_COMP_20_40U_MHZ_DIS: u16 = 262;
export var est_PHY_RESP_FTM_COMP_20_40D_MHZ: u16 = 261;
export var est_PHY_RESP_FTM_COMP_20_40D_MHZ_DIS: u16 = 258;
export var est_PHY_INIT_FTM_COMP_40_40U_MHZ: u16 = 443;
export var est_PHY_INIT_FTM_COMP_40_40U_MHZ_DIS: u16 = 442;
export var est_PHY_INIT_FTM_COMP_40_40D_MHZ: u16 = 443;
export var est_PHY_INIT_FTM_COMP_40_40D_MHZ_DIS: u16 = 445;
export var est_PHY_RESP_FTM_COMP_40_40U_MHZ: u16 = 88;
export var est_PHY_RESP_FTM_COMP_40_40U_MHZ_DIS: u16 = 89;
export var est_PHY_RESP_FTM_COMP_40_40D_MHZ: u16 = 84;
export var est_PHY_RESP_FTM_COMP_40_40D_MHZ_DIS: u16 = 82;
