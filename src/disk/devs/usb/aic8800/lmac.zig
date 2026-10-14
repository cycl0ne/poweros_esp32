// SPDX-License-Identifier: MIT
//! The Wi-Fi firmware's messages: their ids, their parameters as the
//! firmware lays them out, and a request answered by its confirmation.
//!
//! **A request and its answer.** A request names the confirmation it
//! expects; the first message in with that id is it - there is no
//! number on the wire to tell two apart, so requests go one at a time
//! (`Caller.call`). What comes in meanwhile - an indication, a frame, a
//! line of the firmware's log - is handed to `other`, so nothing is lost
//! while a request waits.

const msg = @import("msg.zig");

// --- the ids ------------------------------------------------------------------------

pub const MM_RESET_REQ = msg.id(msg.TASK_MM, 0x00);
pub const MM_RESET_CFM = msg.id(msg.TASK_MM, 0x01);
pub const MM_START_REQ = msg.id(msg.TASK_MM, 0x02);
pub const MM_START_CFM = msg.id(msg.TASK_MM, 0x03);
pub const MM_VERSION_REQ = msg.id(msg.TASK_MM, 0x04);
pub const MM_VERSION_CFM = msg.id(msg.TASK_MM, 0x05);
pub const MM_ADD_IF_REQ = msg.id(msg.TASK_MM, 0x06);
pub const MM_ADD_IF_CFM = msg.id(msg.TASK_MM, 0x07);
pub const MM_KEY_ADD_REQ = msg.id(msg.TASK_MM, 0x24);
pub const MM_KEY_ADD_CFM = msg.id(msg.TASK_MM, 0x25);
pub const MM_KEY_DEL_REQ = msg.id(msg.TASK_MM, 0x26);
pub const MM_KEY_DEL_CFM = msg.id(msg.TASK_MM, 0x27);
pub const MM_SET_COEX_REQ = msg.id(msg.TASK_MM, 0x65);
pub const MM_SET_COEX_CFM = msg.id(msg.TASK_MM, 0x66);
pub const MM_SET_RF_CALIB_REQ = msg.id(msg.TASK_MM, 0x69);
pub const MM_SET_RF_CALIB_CFM = msg.id(msg.TASK_MM, 0x6A);
pub const MM_GET_MAC_ADDR_REQ = msg.id(msg.TASK_MM, 0x73);
pub const MM_GET_MAC_ADDR_CFM = msg.id(msg.TASK_MM, 0x74);
pub const MM_SET_TXPWR_IDX_LVL_REQ = msg.id(msg.TASK_MM, 0x77);
pub const MM_SET_TXPWR_IDX_LVL_CFM = msg.id(msg.TASK_MM, 0x78);
pub const MM_SET_STACK_START_REQ = msg.id(msg.TASK_MM, 0x7B);
pub const MM_SET_STACK_START_CFM = msg.id(msg.TASK_MM, 0x7C);
pub const MM_GET_FW_VERSION_REQ = msg.id(msg.TASK_MM, 0x80);
pub const MM_GET_FW_VERSION_CFM = msg.id(msg.TASK_MM, 0x81);

pub const DBG_MEM_READ_REQ = msg.id(msg.TASK_DBG, 0);
pub const DBG_MEM_READ_CFM = msg.id(msg.TASK_DBG, 1);
pub const DBG_MEM_WRITE_REQ = msg.id(msg.TASK_DBG, 2);
pub const DBG_MEM_WRITE_CFM = msg.id(msg.TASK_DBG, 3);
pub const DBG_MEM_MASK_WRITE_REQ = msg.id(msg.TASK_DBG, 17);
pub const DBG_MEM_MASK_WRITE_CFM = msg.id(msg.TASK_DBG, 18);

pub const SCANU_START_REQ = msg.id(msg.TASK_SCANU, 0x00);
pub const SCANU_START_CFM = msg.id(msg.TASK_SCANU, 0x01);
pub const SCANU_RESULT_IND = msg.id(msg.TASK_SCANU, 0x04);
pub const SCANU_START_CFM_ADDITIONAL = msg.id(msg.TASK_SCANU, 0x09);

pub const ME_CONFIG_REQ = msg.id(msg.TASK_ME, 0x00);
pub const ME_CONFIG_CFM = msg.id(msg.TASK_ME, 0x01);
pub const ME_CHAN_CONFIG_REQ = msg.id(msg.TASK_ME, 0x02);
pub const ME_CHAN_CONFIG_CFM = msg.id(msg.TASK_ME, 0x03);
pub const ME_SET_CONTROL_PORT_REQ = msg.id(msg.TASK_ME, 0x04);
pub const ME_SET_CONTROL_PORT_CFM = msg.id(msg.TASK_ME, 0x05);

pub const SM_CONNECT_REQ = msg.id(msg.TASK_SM, 0x00);
pub const SM_CONNECT_CFM = msg.id(msg.TASK_SM, 0x01);
pub const SM_CONNECT_IND = msg.id(msg.TASK_SM, 0x02);
pub const SM_DISCONNECT_REQ = msg.id(msg.TASK_SM, 0x03);
pub const SM_DISCONNECT_CFM = msg.id(msg.TASK_SM, 0x04);
pub const SM_DISCONNECT_IND = msg.id(msg.TASK_SM, 0x05);

/// The task a message's id says it is for.
pub fn taskOf(id: u16) u16 {
    return id >> 10;
}

// --- a request answered --------------------------------------------------------------

pub const Error = error{
    /// The request did not go, or its answer did not come.
    NoAnswer,
};

/// What came in while a request waited for its answer.
pub const Other = struct {
    context: *anyopaque,
    handle: *const fn (context: *anyopaque, record: msg.Record) void,
};

pub const Caller = struct {
    transport: msg.Transport,
    other: ?Other = null,
    out: [msg.header_bytes + 1024]u8 = undefined,
    in: [8192]u8 = undefined,
    /// How many transfers in a request waits through for its answer.
    patience: u32 = 32,

    /// `id` with `params` sent to its task, and the parameters of its
    /// confirmation `answer` copied to `into`: how many there were.
    pub fn call(c: *Caller, id: u16, params: []const u8, answer: u16, into: []u8) Error!usize {
        const t = c.transport;
        const length = msg.request(&c.out, id, taskOf(id), params);
        if (length == 0 or !t.send(t.context, c.out[0..length])) return Error.NoAnswer;
        return c.waitFor(answer, into, c.patience, 0);
    }

    /// The message `answer` waited for through at most `transfers`
    /// transfers in, its parameters copied to `into`: how many there
    /// were. Up to `silences` of the transfers may bring nothing before it
    /// gives up - for an answer that takes its time, a scan's end.
    pub fn waitFor(c: *Caller, answer: u16, into: []u8, transfers: u32, silences: u32) Error!usize {
        const t = c.transport;
        var tries: u32 = 0;
        var quiet: u32 = 0;
        while (tries < transfers) : (tries += 1) {
            const got = t.receive(t.context, &c.in) orelse {
                quiet += 1;
                if (quiet > silences) return Error.NoAnswer;
                continue;
            };
            var reader = msg.Reader{ .bytes = c.in[0..got] };
            while (reader.next()) |record| {
                switch (record) {
                    .message => |m| if (m.id == answer) {
                        const count = @min(into.len, m.params.len);
                        @memcpy(into[0..count], m.params[0..count]);
                        // Whatever followed it in the same transfer.
                        while (reader.next()) |rest| c.pass(rest);
                        return count;
                    },
                    else => {},
                }
                c.pass(record);
            }
        }
        return Error.NoAnswer;
    }

    /// A request whose answer has nothing in it that matters.
    pub fn tell(c: *Caller, id: u16, params: []const u8, answer: u16) Error!void {
        var none: [8]u8 = undefined;
        _ = try c.call(id, params, answer, &none);
    }

    fn pass(c: *Caller, record: msg.Record) void {
        switch (record) {
            .log => |text| c.transport.say(c.transport.context, text),
            else => if (c.other) |other| other.handle(other.context, record),
        }
    }

    pub fn readMem(c: *Caller, address: u32) Error!u32 {
        var params: [4]u8 = undefined;
        msg.put32(&params, 0, address);
        var answer: [8]u8 = @splat(0);
        _ = try c.call(DBG_MEM_READ_REQ, &params, DBG_MEM_READ_CFM, &answer);
        return msg.get32(&answer, 4);
    }

    pub fn writeMem(c: *Caller, address: u32, value: u32) Error!void {
        var params: [8]u8 = undefined;
        msg.put32(&params, 0, address);
        msg.put32(&params, 4, value);
        try c.tell(DBG_MEM_WRITE_REQ, &params, DBG_MEM_WRITE_CFM);
    }

    pub fn maskWrite(c: *Caller, address: u32, mask: u32, value: u32) Error!void {
        var params: [12]u8 = undefined;
        msg.put32(&params, 0, address);
        msg.put32(&params, 4, mask);
        msg.put32(&params, 8, value);
        try c.tell(DBG_MEM_MASK_WRITE_REQ, &params, DBG_MEM_MASK_WRITE_CFM);
    }
};

// --- joining ------------------------------------------------------------------------

/// `SM_CONNECT_REQ`'s flags: the host runs the key handshake and opens
/// the port itself; the network is WPA or WPA2.
pub const CONNECT_CONTROL_PORT_HOST: u32 = 1 << 0;
pub const CONNECT_WPA_WPA2: u32 = 1 << 3;
/// The ciphers `MM_KEY_ADD_REQ` names.
pub const CIPHER_WEP40: u8 = 0;
pub const CIPHER_TKIP: u8 = 1;
pub const CIPHER_CCMP: u8 = 2;
pub const CIPHER_WEP104: u8 = 3;
/// A key for every station: the group's.
pub const STA_NONE: u8 = 0xFF;

/// What a connection is made to: the network's name, its access point,
/// the channel, and the elements for the association request (the RSN
/// element, for a protected network).
pub const Target = struct {
    ssid: []const u8,
    bssid: [6]u8,
    freq: u16,
    band: u8,
    vif: u8,
    protected: bool,
    elements: []const u8,
};

/// `SM_CONNECT_REQ`: 320 bytes. EAPOL is the control port's type.
pub fn connectRequest(target: Target) [320]u8 {
    var params: [320]u8 = @splat(0);
    const ssid_len = @min(target.ssid.len, 32);
    params[0] = @intCast(ssid_len);
    @memcpy(params[1..][0..ssid_len], target.ssid[0..ssid_len]);
    @memcpy(params[34..40], &target.bssid);
    putChannel(&params, 40, target.freq, target.band, 0, 20);
    var flags: u32 = 0;
    if (target.protected) flags |= CONNECT_CONTROL_PORT_HOST | CONNECT_WPA_WPA2;
    msg.put32(&params, 48, flags);
    // EAPOL's type, as it stands in a frame.
    params[52] = 0x88;
    params[53] = 0x8E;
    const elements_len = @min(target.elements.len, 256);
    params[54] = @truncate(elements_len);
    params[55] = @truncate(elements_len >> 8);
    // Listening at every beacon; open system authentication.
    params[56] = 1;
    params[59] = 0;
    params[61] = target.vif;
    @memcpy(params[64..][0..elements_len], target.elements[0..elements_len]);
    return params;
}

/// What `SM_CONNECT_IND` says: 0 and the access point's station number,
/// or the status the access point refused with.
pub const Connected = struct { status: u16, bssid: [6]u8, ap: u8 };

pub fn connected(params: []const u8) ?Connected {
    if (params.len < 12) return null;
    var result = Connected{ .status = msg.get16(params, 0), .bssid = undefined, .ap = params[10] };
    @memcpy(&result.bssid, params[2..8]);
    return result;
}

/// `SM_DISCONNECT_REQ`: why, from which interface.
pub fn disconnectRequest(reason: u16, vif: u8) [4]u8 {
    return .{ @truncate(reason), @truncate(reason >> 8), vif, 0 };
}

/// `MM_KEY_ADD_REQ`: 44 bytes. `sta` the access point's number for the
/// pairwise key, `STA_NONE` for the group's, which `index` names.
pub fn keyRequest(key: []const u8, index: u8, sta: u8, cipher: u8, vif: u8, pairwise: bool) [44]u8 {
    var params: [44]u8 = @splat(0);
    params[0] = index;
    params[1] = sta;
    const length = @min(key.len, 32);
    params[4] = @intCast(length);
    @memcpy(params[8..][0..length], key[0..length]);
    params[40] = cipher;
    params[41] = vif;
    params[43] = @intFromBool(pairwise);
    return params;
}

// --- channels -----------------------------------------------------------------------

/// A channel as the firmware takes it: its frequency, its band (0 for
/// 2.4 GHz, 1 for 5), flags (`CHAN_*`) and the most power it may send
/// with, in dBm. Six bytes.
pub const channel_bytes = 6;
pub const BAND_2G4: u8 = 0;
pub const BAND_5G: u8 = 1;
pub const CHAN_NO_IR: u8 = 1 << 0;
pub const CHAN_DISABLED: u8 = 1 << 1;
pub const CHAN_RADAR: u8 = 1 << 2;

pub fn putChannel(into: []u8, at: usize, freq: u16, band: u8, flags: u8, power: i8) void {
    into[at] = @truncate(freq);
    into[at + 1] = @truncate(freq >> 8);
    into[at + 2] = band;
    into[at + 3] = flags;
    into[at + 4] = @bitCast(power);
    into[at + 5] = 0;
}

/// A 2.4 GHz channel's frequency, by its number (1-13).
pub fn freq2g4(number: u16) u16 {
    return 2407 + 5 * number;
}

/// A 5 GHz channel's frequency, by its number.
pub fn freq5g(number: u16) u16 {
    return 5000 + 5 * number;
}

// --- tests --------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "a connection request: name, access point, channel, flags, elements" {
    const rsn = [_]u8{ 48, 2, 1, 0 };
    const params = connectRequest(.{
        .ssid = "Home",
        .bssid = .{ 1, 2, 3, 4, 5, 6 },
        .freq = 2462,
        .band = BAND_2G4,
        .vif = 0,
        .protected = true,
        .elements = &rsn,
    });
    try testing.expectEqual(@as(u8, 4), params[0]);
    try testing.expectEqualStrings("Home", params[1..5]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, params[34..40]);
    try testing.expectEqual(@as(u16, 2462), msg.get16(&params, 40));
    try testing.expectEqual(@as(u32, 9), msg.get32(&params, 48));
    try testing.expectEqual(@as(u16, 4), msg.get16(&params, 54));
    try testing.expectEqualSlices(u8, &rsn, params[64..68]);
}

test "a key: index, station, length, key, cipher" {
    const key = [_]u8{0xAB} ** 16;
    const params = keyRequest(&key, 0, 1, CIPHER_CCMP, 0, true);
    try testing.expectEqual(@as(u8, 1), params[1]);
    try testing.expectEqual(@as(u8, 16), params[4]);
    try testing.expectEqual(@as(u8, 0xAB), params[8]);
    try testing.expectEqual(@as(u8, 0xAB), params[23]);
    try testing.expectEqual(@as(u8, 0), params[24]);
    try testing.expectEqual(CIPHER_CCMP, params[40]);
    try testing.expectEqual(@as(u8, 1), params[43]);
}
