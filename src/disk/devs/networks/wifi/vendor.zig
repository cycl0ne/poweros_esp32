// SPDX-License-Identifier: MIT
//! The radio's libraries as the device calls them: their entry points,
//! and the configuration they are started with (wifi_init_config_t).
//!
//! The configuration asks for fewer buffers than the libraries' defaults,
//! since every one is internal memory: 6 frames always held for receiving,
//! 16 more when traffic needs them, and 16 for sending. The settings store
//! is off (the device gives the settings each time), and so is every
//! feature the supplicant does not do (WPA3, fine timing).

const osi_table = @import("osi/table.zig");
const crypto = @import("wpa/crypto.zig");

/// wifi_mode_t.
pub const mode_null: u32 = 0;
pub const mode_sta: u32 = 1;

/// wifi_interface_t.
pub const if_sta: u32 = 0;

/// ESP_OK, and WIFI_INIT_CONFIG_MAGIC.
pub const ok: i32 = 0;
pub const init_magic: c_int = 0x1F2F3F4F;

pub const InitConfig = extern struct {
    osi_funcs: *const osi_table.OsiFuncs = &osi_table.funcs,
    wpa_crypto_funcs: crypto.CryptoFuncs = crypto.funcs,
    static_rx_buf_num: c_int = 6,
    dynamic_rx_buf_num: c_int = 16,
    /// 1: send buffers allocated as frames are sent.
    tx_buf_type: c_int = 1,
    static_tx_buf_num: c_int = 0,
    dynamic_tx_buf_num: c_int = 16,
    rx_mgmt_buf_type: c_int = 0,
    rx_mgmt_buf_num: c_int = 5,
    cache_tx_buf_num: c_int = 0,
    csi_enable: c_int = 0,
    ampdu_rx_enable: c_int = 1,
    ampdu_tx_enable: c_int = 1,
    amsdu_tx_enable: c_int = 0,
    nvs_enable: c_int = 0,
    nano_enable: c_int = 0,
    rx_ba_win: c_int = 6,
    wifi_task_core_id: c_int = 0,
    beacon_max_len: c_int = 752,
    mgmt_sbuf_num: c_int = 32,
    feature_caps: u64 = 0,
    sta_disconnected_pm: bool = false,
    espnow_max_encrypt_num: c_int = 7,
    tx_hetb_queue_num: c_int = 1,
    dump_hesigb_enable: bool = false,
    privacy_enhancements: bool = false,
    rmac_auto_reset_int: u8 = 0,
    magic: c_int = init_magic,
};

comptime {
    if (@sizeOf(usize) == 4 and (@sizeOf(InitConfig) != 160 or @offsetOf(InitConfig, "feature_caps") != 128 or @offsetOf(InitConfig, "magic") != 152))
        @compileError("wifi_init_config_t is 160 bytes, feature_caps at 128, magic at 152");
}

pub extern fn esp_wifi_init_internal(config: *const InitConfig) callconv(.c) i32;
pub extern fn esp_wifi_deinit_internal() callconv(.c) i32;
pub extern fn esp_wifi_set_mode(mode: u32) callconv(.c) i32;
pub extern fn esp_wifi_start() callconv(.c) i32;
pub extern fn esp_wifi_stop() callconv(.c) i32;

// --- scanning -------------------------------------------------------------

/// wifi_country_t, on a 2.4 GHz radio.
pub const Country = extern struct {
    cc: [3]u8,
    schan: u8,
    nchan: u8,
    max_tx_power: i8,
    policy: c_uint,
};

/// wifi_ap_record_t: one network a scan found.
pub const ApRecord = extern struct {
    bssid: [6]u8,
    ssid: [33]u8,
    primary: u8,
    second: c_uint,
    rssi: i8,
    authmode: c_uint,
    pairwise_cipher: c_uint,
    group_cipher: c_uint,
    ant: c_uint,
    phy_bits: u32,
    country: Country,
    he_ap: [2]u8,
    bandwidth: c_uint,
    vht_ch_freq1: u8,
    vht_ch_freq2: u8,
};

/// wifi_scan_config_t.
pub const ScanConfig = extern struct {
    ssid: ?[*:0]const u8 = null,
    bssid: ?[*]const u8 = null,
    channel: u8 = 0,
    show_hidden: bool = false,
    /// WIFI_SCAN_TYPE_ACTIVE.
    scan_type: c_uint = 0,
    active_min_ms: u32 = 0,
    active_max_ms: u32 = 0,
    passive_ms: u32 = 0,
    home_chan_dwell_time: u8 = 0,
    /// wifi_scan_channel_bitmap_t: 0, every channel.
    channel_bitmap: extern struct { ghz_2_channels: u16 = 0, ghz_5_channels: u32 = 0 } = .{},
    coex_background_scan: bool = false,
};

comptime {
    if (@sizeOf(usize) == 4 and @sizeOf(ApRecord) != 92) @compileError("wifi_ap_record_t is 92 bytes");
    if (@sizeOf(usize) == 4 and @sizeOf(ScanConfig) != 44) @compileError("wifi_scan_config_t is 44 bytes");
}

/// wifi_auth_mode_t and wifi_cipher_type_t, the values the device reads.
pub const auth_open = 0;
pub const auth_wep = 1;
pub const auth_wpa_psk = 2;
pub const auth_wpa2_psk = 3;
pub const auth_wpa_wpa2_psk = 4;
pub const auth_enterprise = 5;
pub const auth_wpa3_psk = 6;
pub const auth_wpa2_wpa3_psk = 7;
pub const auth_wpa3_enterprise = 15;
pub const auth_wpa2_wpa3_enterprise = 16;
pub const auth_wpa_enterprise = 17;
pub const cipher_none = 0;
pub const cipher_wep40 = 1;
pub const cipher_wep104 = 2;
pub const cipher_tkip = 3;
pub const cipher_ccmp = 4;
pub const cipher_tkip_ccmp = 5;

pub extern fn esp_wifi_scan_start(config: ?*const ScanConfig, block: bool) callconv(.c) i32;
pub extern fn esp_wifi_scan_get_ap_num(number: *u16) callconv(.c) i32;
pub extern fn esp_wifi_scan_get_ap_records(number: *u16, records: [*]ApRecord) callconv(.c) i32;

// --- frames ---------------------------------------------------------------

/// wifi_rxcb_t: an Ethernet frame the radio received, on the libraries'
/// own task; `eb` is what frees it.
pub const RxCallback = *const fn (buffer: ?*anyopaque, length: u16, eb: ?*anyopaque) callconv(.c) i32;

pub extern fn esp_wifi_internal_reg_rxcb(interface: u32, callback: ?RxCallback) callconv(.c) i32;
pub extern fn esp_wifi_internal_free_rx_buffer(eb: ?*anyopaque) callconv(.c) void;
/// An Ethernet frame sent; the libraries copy it.
pub extern fn esp_wifi_internal_tx(interface: u32, buffer: *const anyopaque, length: u16) callconv(.c) c_int;

// --- joining --------------------------------------------------------------

/// wifi_sta_config_t, as the device fills it in: a network's name, its
/// passphrase, the whole band scanned for it and the strongest access
/// point taken, and the weakest security the station accepts. The
/// fields past `sae_pk_mode` stay zero.
pub const StaConfig = extern struct {
    ssid: [32]u8 = @splat(0),
    password: [64]u8 = @splat(0),
    /// WIFI_ALL_CHANNEL_SCAN.
    scan_method: c_uint = 1,
    bssid_set: bool = false,
    bssid: [6]u8 = @splat(0),
    channel: u8 = 0,
    listen_interval: u16 = 0,
    /// WIFI_CONNECT_AP_BY_SIGNAL.
    sort_method: c_uint = 0,
    /// wifi_scan_threshold_t.
    threshold: extern struct { rssi: i8 = 0, authmode: c_uint = auth_open, rssi_5g_adjustment: u8 = 0 } = .{},
    pmf_capable: bool = false,
    pmf_required: bool = false,
    flags: u32 = 0,
    sae_pwe_h2e: c_uint = 0,
    sae_pk_mode: c_uint = 0,
    rest: [40]u8 = @splat(0),
};

comptime {
    if (@sizeOf(usize) == 4 and (@sizeOf(StaConfig) != 184 or @offsetOf(StaConfig, "scan_method") != 96 or
        @offsetOf(StaConfig, "sort_method") != 112 or @offsetOf(StaConfig, "pmf_capable") != 128 or @offsetOf(StaConfig, "rest") != 144))
        @compileError("wifi_sta_config_t: 184 bytes, as GCC lays it out");
}

pub extern fn esp_wifi_set_config(interface: u32, config: *StaConfig) callconv(.c) i32;
pub extern fn esp_wifi_connect_internal() callconv(.c) i32;
pub extern fn esp_wifi_disconnect_internal() callconv(.c) i32;
/// Tells the libraries the station has an address.
pub extern fn esp_wifi_internal_set_sta_ip() callconv(.c) i32;
pub extern fn esp_wifi_sta_get_ap_info(record: *ApRecord) callconv(.c) i32;
