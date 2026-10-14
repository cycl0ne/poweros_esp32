// SPDX-License-Identifier: MIT
//! The supplicant's table (struct wpa_funcs), which the radio's libraries
//! are given after their init and call for everything security: the
//! security elements of every beacon and probe response they hear, a
//! string of the station's settings, joining a network, and the EAPOL
//! frames of a key handshake.
//!
//! The libraries reach into the table on every management frame, so it must
//! be there before the first scan. The access point's, WPA3's and OWE's
//! entries are empty, as the libraries expect of a station without them.
//!
//! **Joining.** A network with no security is handed straight on. A
//! WPA2-Personal one has its side prepared first, in `staConnect`, because
//! the libraries ask before they associate:
//!
//!   - the station's RSN element, made by wpa.library from the access
//!     point's (`StationElement`), which goes into the association request
//!     through `esp_wifi_set_appie_internal` and is repeated under a MIC in
//!     message 2;
//!   - the access point's, read from the beacon the libraries kept, which
//!     message 3 must repeat;
//!   - the key handshake (`CreateHandshake`), with both elements, the two
//!     addresses, and the network's key the join already made.
//!
//! **The handshake is wpa.library's** and runs on the libraries' task as
//! the frames arrive (`HandshakeFrame`). What it asks comes through its
//! hook (`handshakeHook`): a frame sent with `esp_wifi_internal_tx`, the
//! keys put into the hardware with `esp_wifi_set_sta_key_internal`, the
//! port opened with `esp_wifi_auth_done_internal`. The libraries confirm
//! the EAPOL frames they were given in the order they were given them, so
//! the numbers of those not yet confirmed are kept in that order, and each
//! confirmation hands the oldest to `HandshakeSent`.
//!
//! **The network's key is not made here.** PBKDF2's 4096 rounds are 8192
//! hashes, far too long to spend on the libraries' task while an access
//! point waits for an association. `makePmk` runs on the device's task when
//! the join is asked for (`join.zig`), and keeps the key with the network
//! and passphrase it was made for, so a rejoin skips it.
//!
//! The table is the libraries' to free when they are stopped, so it comes
//! from the adapter's memory, which their `free` gives back.

const sdk = @import("sdk");
const wpa = sdk.wpa;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const WPABase = sdk.interface.wpa.WPABase;
const _osi = @import("../osi/_osi.zig");
const _wifi = @import("../_esp32s3wifi.zig");
const WifiBase = _wifi.WifiBase;
const ie = @import("ie.zig");

/// struct wifi_ssid: the network name the libraries hold for the station.
const WifiSsid = extern struct {
    len: c_int,
    ssid: [32]u8,
};

/// eapol_txcb_t: an EAPOL frame of ours has been dealt with. The last
/// argument is whether sending it **failed**, so false is the good one.
const TxDone = *const fn (?[*]u8, usize, bool) callconv(.c) void;

extern fn esp_wifi_register_wpa_cb_internal(table: *WpaFuncs) callconv(.c) c_int;
extern fn esp_wifi_register_eapol_txdonecb_internal(callback: TxDone) callconv(.c) c_int;
extern fn esp_wifi_sta_connect_internal(bssid: ?[*]const u8) callconv(.c) c_int;
extern fn esp_wifi_sta_get_prof_authmode_internal() callconv(.c) u8;
extern fn esp_wifi_sta_get_prof_ssid_internal() callconv(.c) *WifiSsid;
extern fn esp_wifi_sta_prof_is_rsn_internal() callconv(.c) bool;
extern fn esp_wifi_sta_get_ie(bssid: [*]const u8, element_id: u8) callconv(.c) ?[*]const u8;
/// The buffer is written to, not only read: the length goes into its first
/// two bytes (see `Station.own_ie`), so it is not const.
extern fn esp_wifi_set_appie_internal(kind: u8, element: [*]u8, length: u16, flag: u8) callconv(.c) c_int;
extern fn esp_wifi_unset_appie_internal(kind: u8) callconv(.c) c_int;
extern fn esp_wifi_get_macaddr_internal(interface: u8, address: *[6]u8) callconv(.c) c_int;
extern fn esp_wifi_auth_done_internal() callconv(.c) bool;
extern fn esp_wifi_deauthenticate_internal(reason: u8) callconv(.c) void;
extern fn esp_wifi_internal_tx(interface: u32, buffer: [*]const u8, length: u16) callconv(.c) c_int;
extern fn hexstr2bin(hex: [*]const u8, out: [*]u8, length: usize) callconv(.c) c_int;

/// A key into the hardware: the algorithm, whose key it is, which index,
/// whether it is also used to send, the receive sequence counter it starts
/// at, the key, and what kind of key it is.
///
/// The tenth argument is not one the function takes. Nine arguments put
/// three words on the stack, and the compiler moves the stack pointer by
/// just those twelve bytes, which leaves it four short of eight-byte
/// alignment for everything the call runs; a fourth word keeps it aligned,
/// and is written and never read. The first nine arrive as they are either
/// way.
extern fn esp_wifi_set_sta_key_internal(
    alg: c_int,
    address: *const [6]u8,
    key_index: c_int,
    set_tx: c_int,
    seq: [*]const u8,
    seq_length: usize,
    key: [*]const u8,
    key_length: usize,
    key_flag: c_int,
    stack_alignment: u32,
) callconv(.c) c_int;

/// The authmodes the station's settings report: no security, and
/// WPA2-Personal with either key derivation.
const auth_none: u8 = 0x01;
const auth_wpa2_psk: u8 = 0x05;
const auth_wpa2_psk_sha256: u8 = 0x08;

/// wifi_appie_t: the element added to an association request.
const appie_rsn: u8 = 4;

/// enum key_flag: which key is being set, and what it is used for. The
/// pairwise key is set for both directions; the group key only for
/// receiving, since a station that has a pairwise key sends under that.
const key_flag_rx: c_int = 1 << 2;
const key_flag_tx: c_int = 1 << 3;
const key_flag_group: c_int = 1 << 4;
const key_flag_pairwise: c_int = 1 << 5;
const key_flag_for_pairwise: c_int = key_flag_pairwise | key_flag_tx | key_flag_rx;
const key_flag_for_group: c_int = key_flag_group | key_flag_rx;

/// The station's interface.
const if_sta: u32 = 0;

/// The receive sequence counter a key is installed with: eight bytes for
/// the pairwise key, which starts at zero, and the six the group key's
/// counter is carried in.
const ptk_seq_bytes: usize = 8;
const gtk_seq_bytes: usize = 6;

/// The longest RSN element the station keeps from a beacon. One longer
/// cannot be held to compare against what message 3 repeats, so the
/// network is not joined rather than joined unchecked.
pub const ap_ie_max = 96;

/// The longest passphrase: 63 characters, or the 64 hex digits of the key
/// itself.
const passphrase_max = wpa.WPA_PASSPHRASE_MAX;

/// The radio's key algorithms (enum wpa_alg).
const alg_tkip: c_int = 2;
const alg_ccmp: c_int = 3;

/// The 802.1X header and the key descriptor, before an EAPOL-Key frame's
/// key data: as much as a trace reads.
const eapol_header_bytes = 99;

/// Where the element sits in a `struct wifi_appie`: after its length.
const element_offset = 2;

/// What the key handshake reaches outside itself, and what a join leaves
/// ready for it.
pub const Station = struct {
    base: *WifiBase,
    /// The network's key, and the network and passphrase it was made for:
    /// a join that repeats them skips making it again.
    pmk_key: [wpa.WPA_KEY_BYTES]u8 = @splat(0),
    pmk_ssid: [32]u8 = @splat(0),
    pmk_ssid_len: usize = 0,
    pmk_pass: [passphrase_max]u8 = @splat(0),
    pmk_pass_len: usize = 0,
    /// The two ends: the access point's address, and the station's own.
    aa: [6]u8 = @splat(0),
    spa: [6]u8 = @splat(0),
    /// The element the station associates with, and the one the beacon
    /// carried, which message 3 must repeat.
    ///
    /// The station's own has two bytes of room in front of it, and
    /// `own_ie_len` counts only the element. `esp_wifi_set_appie_internal`
    /// takes the buffer it is given as a `struct wifi_appie`, whose first
    /// field is the element's length: it writes that length over those two
    /// bytes and reads the element from the third. A buffer holding the
    /// element from its first byte comes back with its id and length
    /// overwritten, and the access point refuses what is then sent.
    own_ie: [element_offset + wpa.WPA_ELEMENT_MAX]u8 = @splat(0),
    own_ie_len: usize = 0,
    ap_ie: [ap_ie_max]u8 = @splat(0),
    ap_ie_len: usize = 0,
    /// The join's key handshake, and the hook it asks through.
    handshake: ?*wpa.Handshake = null,
    hook: utility.Hook = .{},
    /// The handshake's numbers of the EAPOL frames the libraries were
    /// given and have not confirmed yet, oldest first.
    unconfirmed: [unconfirmed_max]u32 = @splat(0),
    unconfirmed_count: usize = 0,
};

const unconfirmed_max = 4;

/// What the handshake asks of the radio, on the libraries' task from
/// inside HandshakeFrame and HandshakeSent.
fn handshakeHook(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const station: *Station = @ptrCast(@alignCast(hook.data.?));
    const asked: *const wpa.HandshakeMessage = @ptrCast(@alignCast(message orelse return 0));
    switch (asked.kind) {
        wpa.WPAHM_SEND => {
            const frame = (asked.data orelse return 0)[0..asked.length];
            _osi.trace2("eapol out", frame.len, keyInfo(frame[eapol_ether_bytes..]));
            // Its number, for the confirmation the libraries send back.
            if (station.unconfirmed_count == unconfirmed_max) {
                for (0..unconfirmed_max - 1) |i| station.unconfirmed[i] = station.unconfirmed[i + 1];
                station.unconfirmed_count -= 1;
            }
            station.unconfirmed[station.unconfirmed_count] = asked.number;
            station.unconfirmed_count += 1;
            _ = esp_wifi_internal_tx(if_sta, frame.ptr, @intCast(frame.len));
        },
        // The pairwise key, which the hardware uses for everything the
        // station sends and receives to itself from here on.
        wpa.WPAHM_PAIRWISEKEY => {
            const seq: [ptk_seq_bytes]u8 = @splat(0);
            const key = (asked.data orelse return 0)[0..asked.length];
            _osi.trace2("install pairwise", @intCast(asked.cipher), key.len);
            _ = esp_wifi_set_sta_key_internal(algOf(asked.cipher), &station.aa, 0, 1, &seq, ptk_seq_bytes, key.ptr, key.len, key_flag_for_pairwise, 0);
        },
        // The group key, with the send bit the access point set dropped. A
        // station that has a pairwise key never sends under the group key,
        // and installing the group key as one to send would have the
        // hardware use its index for what the station sends, which stops
        // its traffic.
        wpa.WPAHM_GROUPKEY => {
            const key = (asked.data orelse return 0)[0..asked.length];
            _osi.trace2("install group", asked.index, key.len);
            _ = esp_wifi_set_sta_key_internal(algOf(asked.cipher), &station.aa, @intCast(asked.index), 0, &asked.rsc, gtk_seq_bytes, key.ptr, key.len, key_flag_for_group, 0);
        },
        // The keys are in: the port opens and the libraries finish the
        // association.
        wpa.WPAHM_AUTHORIZED => {
            _osi.trace("the key handshake is done");
            _ = esp_wifi_auth_done_internal();
        },
        wpa.WPAHM_LEAVE => esp_wifi_deauthenticate_internal(@truncate(asked.reason)),
        else => {},
    }
    return 0;
}

/// The radio's algorithm for a key of `cipher` (sdk.wpa's bit).
fn algOf(cipher: u32) c_int {
    return if (cipher == wpa.WPA_CIPHER_TKIP) alg_tkip else alg_ccmp;
}

/// The Ethernet header in front of a frame the handshake sends.
const eapol_ether_bytes = 14;

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

/// The device the libraries belong to, through the adapter they were
/// given. Every one of the table's entries comes in without a context.
pub fn device() ?*WifiBase {
    const state = _osi.adapter orelse return null;
    const carried = state.device orelse return null;
    const base: *WifiBase = @ptrCast(@alignCast(carried));
    if (base.work == null) return null;
    return base;
}

fn stationOf(base: *WifiBase) *Station {
    return &base.work.?.station;
}

/// The key information of an EAPOL-Key frame, for a trace: which message
/// of the handshake it is reads off it.
fn keyInfo(frame: []const u8) usize {
    if (frame.len < eapol_header_bytes) return 0;
    return @as(usize, frame[5]) << 8 | frame[6];
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// A join the station cannot make, said once. -1 is what the libraries
/// take for "do not associate", and without a word here the only sign of it
/// is the reason they then report, which names none of these.
fn refuse(base: *WifiBase, text: [*:0]const u8) c_int {
    sdk.exec.kprintf(base.sys_base, "%s: not joining: %s\n", .{ _wifi.DEVICE_NAME, text });
    return -1;
}

fn staInit() callconv(.c) bool {
    _osi.trace("wpa_sta_init");
    return true;
}

fn staDeinit() callconv(.c) bool {
    return true;
}

/// A network is joined. One with no security goes straight on, with any
/// RSN element an earlier join left behind taken off the association
/// request. A WPA2-Personal one is prepared here; anything else is
/// refused, and the libraries give up on it.
fn staConnect(bssid: ?[*]u8) callconv(.c) c_int {
    const base = device() orelse return -1;
    _osi.trace2("wpa_sta_connect", esp_wifi_sta_get_prof_authmode_internal(), @intFromBool(esp_wifi_sta_prof_is_rsn_internal()));
    const authmode = esp_wifi_sta_get_prof_authmode_internal();
    if (authmode == auth_none) {
        _ = esp_wifi_unset_appie_internal(appie_rsn);
        return esp_wifi_sta_connect_internal(bssid);
    }
    if (authmode != auth_wpa2_psk and authmode != auth_wpa2_psk_sha256) {
        sdk.exec.kprintf(base.sys_base, "%s: not joining: security %u is not one it can do\n", .{ _wifi.DEVICE_NAME, @as(u32, authmode) });
        return -1;
    }
    if (!esp_wifi_sta_prof_is_rsn_internal()) return refuse(base, "the network is not RSN");
    const address = bssid orelse return refuse(base, "no access point was named");
    const station = stationOf(base);

    // The key the join made must be this network's.
    const settings = esp_wifi_sta_get_prof_ssid_internal();
    const name_length: usize = if (settings.len <= 0) 0 else @min(@as(usize, @intCast(settings.len)), settings.ssid.len);
    if (name_length == 0 or !same(settings.ssid[0..name_length], station.pmk_ssid[0..station.pmk_ssid_len])) {
        return refuse(base, "there is no key for this network");
    }

    // The beacon's RSN element, kept for what message 3 must repeat.
    const beacon = esp_wifi_sta_get_ie(address, ie.eid_rsn) orelse return refuse(base, "the beacon carried no RSN element");
    const beacon_length = @as(usize, beacon[1]) + 2;
    if (beacon_length > station.ap_ie.len) return refuse(base, "the beacon's RSN element is too long to hold");
    @memcpy(station.ap_ie[0..beacon_length], beacon[0..beacon_length]);
    station.ap_ie_len = beacon_length;

    // The station's own element: the group cipher the access point uses,
    // CCMP for what the station sends, PSK, and the station's own
    // capabilities - no protected management frames.
    const wb = base.wpa_base orelse return refuse(base, "there is no wpa.library");
    station.own_ie_len = wb.StationElement(&station.ap_ie, station.own_ie[element_offset..].ptr, wpa.WPA_ELEMENT_MAX);
    if (station.own_ie_len == 0) return refuse(base, "the network asks for a security it can't do (WPA2-Personal with CCMP is)");
    if (esp_wifi_set_appie_internal(appie_rsn, &station.own_ie, @intCast(station.own_ie_len), 1) != 0) {
        return refuse(base, "the radio would not take its RSN element");
    }

    @memcpy(&station.aa, address[0..6]);
    if (esp_wifi_get_macaddr_internal(0, &station.spa) != 0) return refuse(base, "the radio would not say its own address");
    dropHandshake(base);
    station.hook = .{ .entry = &handshakeHook, .data = station };
    const tags = [_]TagItem{
        .{ .tag = wpa.WPAH_Key, .data = @intFromPtr(&station.pmk_key) },
        .{ .tag = wpa.WPAH_Authenticator, .data = @intFromPtr(&station.aa) },
        .{ .tag = wpa.WPAH_Supplicant, .data = @intFromPtr(&station.spa) },
        .{ .tag = wpa.WPAH_StationElement, .data = @intFromPtr(&station.own_ie[element_offset]) },
        .{ .tag = wpa.WPAH_NetworkElement, .data = @intFromPtr(&station.ap_ie) },
        .{ .tag = wpa.WPAH_Hook, .data = @intFromPtr(&station.hook) },
        .{},
    };
    station.handshake = wb.CreateHandshake(&tags) orelse return refuse(base, "there is no memory for the key handshake");
    return esp_wifi_sta_connect_internal(address);
}

/// The join's handshake given up, and every frame it waited to hear of.
fn dropHandshake(base: *WifiBase) void {
    const station = stationOf(base);
    if (station.handshake) |handshake| base.wpa_base.?.DeleteHandshake(handshake);
    station.handshake = null;
    station.unconfirmed_count = 0;
}

fn staConnected(_: ?[*]u8) callconv(.c) void {}

/// The station is off the network: whatever a handshake had reached is
/// void, so a rejoin starts from message 1.
fn staDisconnected(_: u8) callconv(.c) void {
    const base = device() orelse return;
    dropHandshake(base);
}

/// An EAPOL frame from the access point, the 802.1X header first. Only one
/// from the access point the station is joining is looked at; the MIC is
/// what settles the rest.
fn rxEapol(source: ?[*]u8, buffer: ?[*]u8, length: u32) callconv(.c) c_int {
    const base = device() orelse return -1;
    const from = source orelse return -1;
    const frame = buffer orelse return -1;
    const station = stationOf(base);
    if (!same(from[0..6], &station.aa)) return -1;
    const handshake = station.handshake orelse return -1;
    _osi.trace2("eapol in", length, keyInfo(frame[0..length]));
    base.wpa_base.?.HandshakeFrame(handshake, frame, length);
    return 0;
}

/// An EAPOL frame of ours has been dealt with, `failed` saying whether
/// sending it went wrong: the oldest the libraries were given. Its number
/// goes to the handshake, which lets the keys in only for message 4's -
/// before message 4 has gone they must not be, or it would leave
/// encrypted under a key the access point does not use yet.
fn txDone(payload: ?[*]u8, length: usize, failed: bool) callconv(.c) void {
    _ = payload;
    const base = device() orelse return;
    const station = stationOf(base);
    if (station.unconfirmed_count == 0) return;
    const number = station.unconfirmed[0];
    for (0..station.unconfirmed_count - 1) |i| station.unconfirmed[i] = station.unconfirmed[i + 1];
    station.unconfirmed_count -= 1;
    _osi.trace2("eapol sent", length, number);
    if (failed) return;
    const handshake = station.handshake orelse return;
    base.wpa_base.?.HandshakeSent(handshake, number);
}

/// Whether the libraries should hold data frames back: they should while
/// the pairwise key is being agreed.
fn in4way() callconv(.c) bool {
    const base = device() orelse return false;
    const handshake = stationOf(base).handshake orelse return false;
    return base.wpa_base.?.HandshakeStatus(handshake) == wpa.WPAHS_RUNNING;
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

/// The network's key for `passphrase` on `ssid`, made by wpa.library -
/// PBKDF2 with HMAC-SHA1 over 4096 rounds, or, for 64 hex digits, the key
/// itself. It is kept with the network and passphrase it was made for, so
/// joining the same network again costs nothing. False without
/// wpa.library, or for a passphrase that is not one.
///
/// This runs on the device's task. The libraries ask to connect from their
/// own, where 8192 hashes cannot be spent.
pub fn makePmk(base: *WifiBase, ssid: []const u8, passphrase: []const u8) bool {
    const wb = base.wpa_base orelse return false;
    if (ssid.len == 0 or ssid.len > 32) return false;
    if (passphrase.len < wpa.WPA_PASSPHRASE_MIN or passphrase.len > passphrase_max) return false;
    const station = stationOf(base);
    if (same(station.pmk_ssid[0..station.pmk_ssid_len], ssid) and
        same(station.pmk_pass[0..station.pmk_pass_len], passphrase)) return true;

    // Until the key is made, there is none: a join that fails here must
    // not go on with the last network's.
    station.pmk_ssid_len = 0;
    station.pmk_pass_len = 0;
    var text: [passphrase_max + 1]u8 = @splat(0);
    @memcpy(text[0..passphrase.len], passphrase);
    if (!wb.PassphraseKey(@ptrCast(&text), ssid.ptr, @intCast(ssid.len), &station.pmk_key)) return false;
    @memcpy(station.pmk_ssid[0..ssid.len], ssid);
    station.pmk_ssid_len = ssid.len;
    @memcpy(station.pmk_pass[0..passphrase.len], passphrase);
    station.pmk_pass_len = passphrase.len;
    return true;
}

/// The station's side set up and the table handed to the libraries, with
/// the callback that tells the handshake a frame of its has gone out.
/// False if the libraries refuse either.
pub fn register(base: *WifiBase) bool {
    const work = base.work orelse return false;
    work.station = .{ .base = base };
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
    if (esp_wifi_register_wpa_cb_internal(table) != 0) return false;
    return esp_wifi_register_eapol_txdonecb_internal(&txDone) == 0;
}
