// SPDX-License-Identifier: MIT
//! The supplicant's table (struct wpa_funcs), which the radio's libraries
//! are given after their init and call for everything security: the
//! security elements of every beacon and probe response they hear, a
//! string of the station's settings, joining a network, and the EAPOL
//! frames of a key handshake.
//!
//! The libraries reach into the table on every management frame, so it
//! must be there before the first scan, whatever it can do. What it does
//! now: parse security elements (`ie.zig`), so a scan knows each network's
//! security; parse a setting string; join a network with no security.
//! The key handshake is not here yet: an EAPOL frame is dropped, and a
//! protected network is never joined. The access point's, WPA3's and
//! OWE's entries are empty, as the libraries expect of a station without
//! them.
//!
//! The table is the libraries' to free when they are stopped, so it comes
//! from the adapter's memory, which their `free` gives back.

const _osi = @import("../osi/_osi.zig");
const ie = @import("ie.zig");

/// struct wpa_funcs, in its order.
pub const WpaFuncs = extern struct {
    wpa_sta_init: ?*const fn () callconv(.c) bool = null,
    wpa_sta_deinit: ?*const fn () callconv(.c) bool = null,
    wpa_sta_connect: ?*const fn (?[*]u8) callconv(.c) c_int = null,
    wpa_sta_connected_cb: ?*const fn (?[*]u8) callconv(.c) void = null,
    wpa_sta_disconnected_cb: ?*const fn (u8) callconv(.c) void = null,
    wpa_sta_rx_eapol: ?*const fn (?[*]u8, ?[*]u8, u32) callconv(.c) c_int = null,
    wpa_sta_in_4way_handshake: ?*const fn () callconv(.c) bool = null,
    wpa_ap_init: ?*const anyopaque = null,
    wpa_ap_deinit: ?*const anyopaque = null,
    wpa_ap_join: ?*const anyopaque = null,
    wpa_ap_remove: ?*const anyopaque = null,
    wpa_ap_get_wpa_ie: ?*const anyopaque = null,
    wpa_ap_rx_eapol: ?*const anyopaque = null,
    wpa_ap_get_peer_spp_msg: ?*const anyopaque = null,
    wpa_config_parse_string: ?*const fn (?[*:0]const u8, ?*usize) callconv(.c) ?[*]u8 = null,
    wpa_parse_wpa_ie: ?*const fn (?[*]const u8, usize, ?*ie.WpaIe) callconv(.c) c_int = null,
    wpa_config_bss: ?*const anyopaque = null,
    wpa_michael_mic_failure: ?*const fn (u16) callconv(.c) c_int = null,
    wpa3_build_sae_msg: ?*const anyopaque = null,
    wpa3_parse_sae_msg: ?*const anyopaque = null,
    wpa3_hostap_handle_auth: ?*const anyopaque = null,
    wpa_sta_rx_mgmt: ?*const anyopaque = null,
    wpa_config_done: ?*const fn () callconv(.c) void = null,
    owe_build_dhie: ?*const anyopaque = null,
    owe_process_assoc_resp: ?*const anyopaque = null,
    wpa_sta_clear_curr_pmksa: ?*const fn () callconv(.c) void = null,
    wpa_config_reload: ?*const fn () callconv(.c) void = null,
};

comptime {
    if (@sizeOf(usize) == 4 and @sizeOf(WpaFuncs) != 27 * 4) @compileError("struct wpa_funcs is 27 words");
}

extern fn esp_wifi_register_wpa_cb_internal(table: *WpaFuncs) callconv(.c) c_int;
extern fn esp_wifi_sta_connect_internal(bssid: ?[*]const u8) callconv(.c) c_int;
extern fn esp_wifi_sta_get_prof_authmode_internal() callconv(.c) u8;
extern fn hexstr2bin(hex: [*]const u8, out: [*]u8, length: usize) callconv(.c) c_int;

/// NONE_AUTH: a network with no security.
const auth_none: u8 = 0x01;

fn staInit() callconv(.c) bool {
    _osi.trace("wpa_sta_init");
    return true;
}

fn staDeinit() callconv(.c) bool {
    return true;
}

/// A network is joined: one with no security straight away; a protected
/// one is refused until the key handshake is there.
fn staConnect(bssid: ?[*]u8) callconv(.c) c_int {
    _osi.trace("wpa_sta_connect");
    if (esp_wifi_sta_get_prof_authmode_internal() != auth_none) return -1;
    return esp_wifi_sta_connect_internal(bssid);
}

fn staConnected(_: ?[*]u8) callconv(.c) void {}

fn staDisconnected(_: u8) callconv(.c) void {}

fn rxEapol(_: ?[*]u8, _: ?[*]u8, _: u32) callconv(.c) c_int {
    return -1;
}

fn in4way() callconv(.c) bool {
    return false;
}

fn nothing() callconv(.c) void {}

fn micFailure(_: u16) callconv(.c) c_int {
    return 0;
}

/// `"text"` gives the text, anything else is hex (or, 5 or 13
/// characters long, a WEP key as it stands); in new memory the libraries
/// free, NUL-terminated, its length in `length`.
fn parseString(value: ?[*:0]const u8, length: ?*usize) callconv(.c) ?[*]u8 {
    const text = value orelse return null;
    const out_length = length orelse return null;
    var size: usize = 0;
    while (text[size] != 0) size += 1;
    var start: usize = 0;
    var end: usize = size;
    const quoted = size >= 2 and text[0] == '"' or size >= 3 and text[0] == 'P' and text[1] == '"';
    if (quoted) {
        start = if (text[0] == 'P') 2 else 1;
        if (text[size - 1] != '"') return null;
        end = size - 1;
    }
    const raw = quoted or size == 5 or size == 13;
    const bytes = if (raw) end - start else size / 2;
    if (!raw and size % 2 != 0) return null;
    const memory: [*]u8 = @ptrCast(_osi.alloc(bytes + 1, true, false) orelse return null);
    if (raw) {
        @memcpy(memory[0..bytes], text[start..end]);
    } else if (hexstr2bin(text, memory, bytes) != 0) {
        _osi.free(memory);
        return null;
    }
    memory[bytes] = 0;
    out_length.* = bytes;
    return memory;
}

/// The table made and handed to the libraries. False if they refuse it.
pub fn register() bool {
    const memory = _osi.alloc(@sizeOf(WpaFuncs), true, true) orelse return false;
    const table: *WpaFuncs = @ptrCast(@alignCast(memory));
    table.* = .{
        .wpa_sta_init = &staInit,
        .wpa_sta_deinit = &staDeinit,
        .wpa_sta_connect = &staConnect,
        .wpa_sta_connected_cb = &staConnected,
        .wpa_sta_disconnected_cb = &staDisconnected,
        .wpa_sta_rx_eapol = &rxEapol,
        .wpa_sta_in_4way_handshake = &in4way,
        .wpa_config_parse_string = &parseString,
        .wpa_parse_wpa_ie = &ie.parse,
        .wpa_michael_mic_failure = &micFailure,
        .wpa_config_done = &nothing,
        .wpa_sta_clear_curr_pmksa = &nothing,
        .wpa_config_reload = &nothing,
    };
    return esp_wifi_register_wpa_cb_internal(table) == 0;
}
