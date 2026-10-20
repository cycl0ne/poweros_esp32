// SPDX-License-Identifier: MIT
//! What uac.device reads in a USB audio function's descriptors, and how
//! it puts a buffer of frames into packets: pure code, no bus.
//!
//! **A setting to play through** is an alternate setting of a streaming
//! interface with an isochronous OUT endpoint, linear PCM of type I, one
//! or two channels of 16, 24 or 32 bits, and the rate asked for among
//! its rates; of those an interface offers, two channels come before
//! one, then the narrowest samples (`findSetting`).
//!
//! **Its feature unit** - mute and volume - is the one whose source is
//! the terminal the setting is linked to, on the function's control
//! interface (`findFeature`).
//!
//! **A packet** is a millisecond's frames, or the interval's when the
//! endpoint asks less often: at a rate of whole frames a millisecond,
//! every packet is as long as the next.
//!
//! **An asynchronous endpoint** runs on the device's own clock and names
//! the IN endpoint of its setting that tells that clock's rate back
//! (bSynchAddress): samples a frame, 10.14 in three bytes, 16.16 in four
//! (`feedbackRate`).
//!
//! **A volume** is a gain - 0x10000 as played - and the feature unit's is
//! in 1/256 dB: the gain's level put within the unit's range, and the
//! gain left over for the mix where the range does not reach it
//! (`levelFor`). The log and the power of two are worked out in fixed
//! point, to a 65536th.

const sdk = @import("sdk");
const d = sdk.usb.descriptors;

/// A setting a stream can be played through, and what its endpoint and
/// format are.
pub const Setting = struct {
    interface: u8 = 0,
    alternate: u8 = 0,
    endpoint: u8 = 0,
    max_packet: u32 = 0,
    /// bInterval: 2^(n-1) frames.
    interval: u8 = 1,
    channels: u8 = 0,
    /// Bytes a sample takes, and how many bits of them are heard.
    bytes: u8 = 0,
    bits: u8 = 0,
    /// The endpoint takes its rate set (SET_CUR of UAC_EP_SAMPLING_FREQ).
    rate_control: bool = false,
    /// The terminal the interface is linked to.
    terminal: u8 = 0,
    /// The endpoint's synchronisation (USB_ENDPOINT_SYNC_*).
    sync: u8 = 0,
    /// An asynchronous endpoint's feedback endpoint, and the bytes of its
    /// packets; 0 for none.
    feedback: u8 = 0,
    feedback_packet: u32 = 0,

    /// Milliseconds between packets.
    pub fn intervalMs(setting: Setting) u32 {
        const exponent: u5 = @intCast(@min(@max(setting.interval, 1), 16) - 1);
        return @as(u32, 1) << exponent;
    }

    /// Bytes a frame takes.
    pub fn frameBytes(setting: Setting) u32 {
        return @as(u32, setting.channels) * setting.bytes;
    }
};

/// The feature unit a setting's stream goes through: its control
/// interface, its ID, and which channels (0 the master) have mute and
/// volume - a bit each.
pub const Feature = struct {
    interface: u8 = 0,
    unit: u8 = 0,
    mutes: u32 = 0,
    volumes: u32 = 0,
};

/// One alternate setting as the walk finds it, before it is judged.
const Candidate = struct {
    setting: Setting = .{},
    pcm: bool = false,
    type_i: bool = false,
    has_rate: bool = false,
    out_iso: bool = false,
    /// The OUT endpoint's bSynchAddress, the setting's isochronous IN
    /// endpoint and its packet size, and whether the endpoint seen last
    /// was the OUT one.
    synch_address: u8 = 0,
    in_endpoint: u8 = 0,
    in_packet: u32 = 0,
    last_out: bool = false,
};

/// A candidate's setting, with its feedback endpoint when it is
/// asynchronous and names one the setting has.
fn settled(candidate: Candidate) Setting {
    var setting = candidate.setting;
    const named = candidate.synch_address;
    if (setting.sync == d.USB_ENDPOINT_SYNC_ASYNC and named & d.USB_DIR_IN != 0 and named == candidate.in_endpoint) {
        setting.feedback = named;
        setting.feedback_packet = candidate.in_packet;
    }
    return setting;
}

fn word(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | @as(u16, bytes[at + 1]) << 8;
}

fn rateAt(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) | @as(u32, bytes[at + 1]) << 8 | @as(u32, bytes[at + 2]) << 16;
}

/// Whether a format type descriptor lists `rate`: between its two rates
/// when it gives a range (bSamFreqType 0), among them when it lists them.
fn listsRate(format: []const u8, rate: u32) bool {
    if (format.len < 8) return false;
    const count = format[7];
    if (count == 0) return format.len >= 14 and rateAt(format, 8) <= rate and rate <= rateAt(format, 11);
    var n: usize = 0;
    while (n < count and 8 + 3 * n + 3 <= format.len) : (n += 1) {
        if (rateAt(format, 8 + 3 * n) == rate) return true;
    }
    return false;
}

/// Whether a candidate plays at `rate`: everything there, and a packet
/// of the interval's frames fits the endpoint.
fn playable(candidate: Candidate, rate: u32) bool {
    const setting = candidate.setting;
    if (!candidate.pcm or !candidate.type_i or !candidate.has_rate or !candidate.out_iso) return false;
    if (setting.channels < 1 or setting.channels > 2) return false;
    if (setting.bytes < 2 or setting.bytes > 4) return false;
    if (rate % 1000 != 0) return false;
    return packetBytes(setting, rate) <= setting.max_packet;
}

/// Whether `a` is to be played through before `b`: two channels first,
/// then the fewer bytes.
fn better(a: Setting, b: Setting) bool {
    if (a.channels != b.channels) return a.channels > b.channels;
    return a.bytes < b.bytes;
}

/// The best setting of streaming interface `interface` in `config` (a
/// configuration descriptor and what follows it) that plays at `rate`,
/// or null.
pub fn findSetting(config: []const u8, interface: u8, rate: u32) ?Setting {
    var best: ?Setting = null;
    var current: ?Candidate = null;
    var at: usize = 0;
    while (at + 2 <= config.len) {
        const length = config[at];
        if (length < 2 or at + length > config.len) break;
        const here = config[at..][0..length];
        switch (here[1]) {
            d.USB_DT_INTERFACE => if (length >= 9) {
                if (current) |done| {
                    if (playable(done, rate) and (best == null or better(done.setting, best.?))) best = settled(done);
                }
                current = null;
                if (here[2] == interface and here[5] == d.USB_CLASS_AUDIO and here[6] == d.AUDIO_SUBCLASS_STREAMING) {
                    current = .{ .setting = .{ .interface = interface, .alternate = here[3] } };
                }
            },
            d.USB_DT_CS_INTERFACE => if (current) |*candidate| {
                if (length >= 7 and here[2] == d.UAC_AS_GENERAL) {
                    candidate.setting.terminal = here[3];
                    candidate.pcm = word(here, 5) == d.UAC_FORMAT_PCM;
                } else if (length >= 8 and here[2] == d.UAC_FORMAT_TYPE) {
                    candidate.type_i = here[3] == d.UAC_FORMAT_TYPE_I;
                    candidate.setting.channels = here[4];
                    candidate.setting.bytes = here[5];
                    candidate.setting.bits = here[6];
                    candidate.has_rate = listsRate(here, rate);
                }
            },
            d.USB_DT_ENDPOINT => if (current) |*candidate| {
                candidate.last_out = false;
                if (length >= 7 and here[3] & d.USB_ENDPOINT_XFERTYPE_MASK == d.USB_ENDPOINT_XFER_ISOC) {
                    if (here[2] & d.USB_DIR_IN == 0) {
                        candidate.out_iso = true;
                        candidate.last_out = true;
                        candidate.setting.endpoint = here[2];
                        candidate.setting.max_packet = word(here, 4) & 0x7FF;
                        candidate.setting.interval = here[6];
                        candidate.setting.sync = here[3] & d.USB_ENDPOINT_SYNCTYPE_MASK;
                        // An audio endpoint's descriptor is nine bytes.
                        candidate.synch_address = if (length >= 9) here[8] else 0;
                    } else {
                        candidate.in_endpoint = here[2];
                        candidate.in_packet = word(here, 4) & 0x7FF;
                    }
                }
            },
            d.USB_DT_CS_ENDPOINT => if (current) |*candidate| {
                if (length >= 3 and here[2] == d.UAC_EP_GENERAL and candidate.last_out) candidate.setting.rate_control = here[3] & d.UAC_EP_SAMPLING_FREQ != 0;
            },
            else => {},
        }
        at += length;
    }
    if (current) |done| {
        if (playable(done, rate) and (best == null or better(done.setting, best.?))) best = settled(done);
    }
    return best;
}

/// The feature unit fed by terminal `terminal`, on the first control
/// interface in `config`, or null.
pub fn findFeature(config: []const u8, terminal: u8) ?Feature {
    var control: ?u8 = null;
    var at: usize = 0;
    while (at + 2 <= config.len) {
        const length = config[at];
        if (length < 2 or at + length > config.len) break;
        const here = config[at..][0..length];
        switch (here[1]) {
            d.USB_DT_INTERFACE => if (length >= 9) {
                const is_control = here[5] == d.USB_CLASS_AUDIO and here[6] == d.AUDIO_SUBCLASS_CONTROL;
                // The first control interface's descriptors only.
                if (control != null and is_control) return null;
                if (is_control) control = here[2] else if (control != null) return null;
            },
            d.USB_DT_CS_INTERFACE => if (control) |interface| {
                if (length >= 7 and here[2] == d.UAC_FEATURE_UNIT and here[4] == terminal) {
                    var feature = Feature{ .interface = interface, .unit = here[3] };
                    const size = here[5];
                    if (size == 0) return feature;
                    var channel: u5 = 0;
                    var offset: usize = 6;
                    while (offset + size <= length - 1 and channel < 31) : ({
                        offset += size;
                        channel += 1;
                    }) {
                        const controls = here[offset];
                        if (controls & 1 != 0) feature.mutes |= @as(u32, 1) << channel;
                        if (controls & 2 != 0) feature.volumes |= @as(u32, 1) << channel;
                    }
                    return feature;
                }
            },
            else => {},
        }
        at += length;
    }
    return null;
}

/// Bytes of one packet at `rate`: the interval's frames.
pub fn packetBytes(setting: Setting, rate: u32) u32 {
    return rate / 1000 * setting.intervalMs() * setting.frameBytes();
}

/// Frames of one packet at `rate`.
pub fn packetFrames(setting: Setting, rate: u32) u32 {
    return rate / 1000 * setting.intervalMs();
}

/// `count` 16-bit stereo frames written as the setting's samples into
/// `into`: both sides for two channels, the first half - the mixer puts
/// both sides there for a mono output - for one; each sample's top bits
/// the 16, the bits below them zero. The bytes written.
pub fn convert(setting: Setting, frames: [*]const i16, count: u32, into: [*]u8) u32 {
    var at: usize = 0;
    var n: usize = 0;
    while (n < count) : (n += 1) {
        var side: usize = 0;
        while (side < setting.channels) : (side += 1) {
            const sample: u16 = @bitCast(frames[n * 2 + side]);
            var pad: usize = 2;
            while (pad < setting.bytes) : (pad += 1) {
                into[at] = 0;
                at += 1;
            }
            into[at] = @truncate(sample);
            into[at + 1] = @truncate(sample >> 8);
            at += 2;
        }
    }
    return @intCast(at);
}

/// The rate a feedback packet tells, in thousandths of a hertz: three
/// bytes are 10.14 samples a frame; four are 16.16 samples a frame, or a
/// microframe at high speed. Null for a packet too short, or for zero.
pub fn feedbackRate(packet: []const u8, high_speed: bool) ?u64 {
    if (packet.len < 3) return null;
    var value: u64 = @as(u64, packet[0]) | @as(u64, packet[1]) << 8 | @as(u64, packet[2]) << 16;
    if (packet.len == 3) {
        if (value == 0) return null;
        return value * 1_000_000 >> 14;
    }
    value |= @as(u64, packet[3]) << 24;
    if (value == 0) return null;
    const per_second: u64 = if (high_speed) 8000 else 1000;
    return value * per_second * 1000 >> 16;
}

/// How far a rate in thousandths of a hertz is from `rate`, in parts a
/// million.
pub fn driftPpm(rate_mhz: u64, rate: u32) i32 {
    const nominal = @as(i64, rate) * 1000;
    const told: i64 = @intCast(@min(rate_mhz, 1 << 40));
    const ppm = @divTrunc((told - nominal) * 1_000_000, nominal);
    return @intCast(@max(@min(ppm, 0x7FFF_FFFF), -0x7FFF_FFFF));
}

/// A gain as played: 0x10000.
pub const unity: u32 = 0x10000;
/// The most gain the mix is left: four times as played.
const most_rest: u32 = 4 * unity;
/// 20 * log10(2) in 1/256 dB, a thousandth of it a step: the level of a
/// doubling.
const doubling_db: i64 = 1_541_274;

/// log2 of `gain` (not 0), both 16.16.
fn log2Of(gain: u32) i32 {
    const top: u5 = @intCast(31 - @clz(gain));
    // The gain as a number from 1 to 2, 1.31, squared a bit at a time.
    var z: u64 = @as(u64, gain) << (31 - @as(u6, top));
    var fraction: i32 = 0;
    var bit: i32 = 1 << 15;
    while (bit != 0) : (bit >>= 1) {
        z = (z * z) >> 31;
        if (z >= 1 << 32) {
            z >>= 1;
            fraction |= bit;
        }
    }
    return (@as(i32, top) - 16) * 65536 + fraction;
}

/// 2 to the power `x`, both 16.16, at most `most_rest`.
fn exp2Of(x: i32) u32 {
    const whole = x >> 16;
    const f: u64 = @intCast(x & 0xFFFF);
    // 2^f from 0 to 1: 1 + 0.69583 f + 0.22606 f^2 + 0.07807 f^3.
    const power: u64 = 65536 + ((f * (45602 + ((f * (14815 + ((f * 5116) >> 16))) >> 16))) >> 16);
    if (whole >= 2) return most_rest;
    if (whole >= 0) return @intCast(@min(power << @intCast(whole), most_rest));
    if (whole < -31) return 0;
    return @intCast(power >> @intCast(-whole));
}

/// A gain's level, in 1/256 dB.
pub fn dbOf(gain: u32) i32 {
    return @intCast(@divTrunc(@as(i64, log2Of(gain)) * doubling_db, 65_536_000));
}

/// The gain of a level in 1/256 dB.
pub fn gainOf(db: i32) u32 {
    return exp2Of(@intCast(@divTrunc(@as(i64, db) * 65_536_000, doubling_db)));
}

/// What a feature unit is set to for a gain, and what the mix is left.
pub const Level = struct {
    /// The unit's volume, 1/256 dB.
    value: i16,
    /// The gain the mix still gives: `unity` when the unit took it all.
    rest: u32,
};

/// The level of `gain` within a unit's range, `min` to `max`, and the
/// gain left for the mix: what is above the range, or below it. None at
/// all is the range's bottom and nothing left.
pub fn levelFor(gain: u32, min: i16, max: i16) Level {
    if (gain == 0) return .{ .value = min, .rest = 0 };
    const wanted = dbOf(gain);
    const value = @max(@min(wanted, @as(i32, max)), @as(i32, min));
    if (value == wanted) return .{ .value = @intCast(value), .rest = unity };
    return .{ .value = @intCast(value), .rest = gainOf(wanted - value) };
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// A speaker as QEMU's is described: a control interface with a USB
/// streaming input terminal (1), a feature unit (2) with mute on the
/// master and volume on both channels, an output terminal (3); a
/// streaming interface with its empty setting and one of 16-bit stereo
/// at 48 kHz, and a third of 24-bit mono at 44.1 and 48 kHz.
const speaker = [_]u8{ 9, d.USB_DT_CONFIG, 0, 0, 2, 1, 0, 0x80, 50 } ++
    [_]u8{ 9, d.USB_DT_INTERFACE, 0, 0, 0, d.USB_CLASS_AUDIO, d.AUDIO_SUBCLASS_CONTROL, 0, 0 } ++
    [_]u8{ 9, d.USB_DT_CS_INTERFACE, d.UAC_HEADER, 0, 1, 0, 0, 1, 1 } ++
    [_]u8{ 12, d.USB_DT_CS_INTERFACE, d.UAC_INPUT_TERMINAL, 1, 0x01, 0x01, 0, 2, 3, 0, 0, 0 } ++
    [_]u8{ 10, d.USB_DT_CS_INTERFACE, d.UAC_FEATURE_UNIT, 2, 1, 1, 0x01, 0x02, 0x02, 0 } ++
    [_]u8{ 9, d.USB_DT_CS_INTERFACE, d.UAC_OUTPUT_TERMINAL, 3, 0x01, 0x03, 0, 2, 0 } ++
    [_]u8{ 9, d.USB_DT_INTERFACE, 1, 0, 0, d.USB_CLASS_AUDIO, d.AUDIO_SUBCLASS_STREAMING, 0, 0 } ++
    // Setting 1: 16-bit stereo at 48 kHz, 192-byte packets every frame;
    // its packet size at offset 98.
    [_]u8{ 9, d.USB_DT_INTERFACE, 1, 1, 1, d.USB_CLASS_AUDIO, d.AUDIO_SUBCLASS_STREAMING, 0, 0 } ++
    [_]u8{ 7, d.USB_DT_CS_INTERFACE, d.UAC_AS_GENERAL, 1, 1, 0x01, 0x00 } ++
    [_]u8{ 11, d.USB_DT_CS_INTERFACE, d.UAC_FORMAT_TYPE, d.UAC_FORMAT_TYPE_I, 2, 2, 16, 1, 0x80, 0xBB, 0x00 } ++
    [_]u8{ 9, d.USB_DT_ENDPOINT, 0x01, 0x09, 0xC0, 0x00, 1, 0, 0 } ++
    [_]u8{ 7, d.USB_DT_CS_ENDPOINT, d.UAC_EP_GENERAL, 0, 0, 0, 0 } ++
    // Setting 2: 24-bit mono at 44.1 and 48 kHz, its rate set by request.
    [_]u8{ 9, d.USB_DT_INTERFACE, 1, 2, 1, d.USB_CLASS_AUDIO, d.AUDIO_SUBCLASS_STREAMING, 0, 0 } ++
    [_]u8{ 7, d.USB_DT_CS_INTERFACE, d.UAC_AS_GENERAL, 1, 1, 0x01, 0x00 } ++
    [_]u8{ 14, d.USB_DT_CS_INTERFACE, d.UAC_FORMAT_TYPE, d.UAC_FORMAT_TYPE_I, 1, 3, 24, 2, 0x44, 0xAC, 0x00, 0x80, 0xBB, 0x00 } ++
    [_]u8{ 9, d.USB_DT_ENDPOINT, 0x01, 0x09, 0x90, 0x00, 1, 0, 0 } ++
    [_]u8{ 7, d.USB_DT_CS_ENDPOINT, d.UAC_EP_GENERAL, 1, 0, 0, 0 };

test "the setting played through: two channels before one, at a rate it lists" {
    const setting = findSetting(&speaker, 1, 48_000).?;
    try testing.expectEqual(@as(u8, 1), setting.alternate);
    try testing.expectEqual(@as(u8, 2), setting.channels);
    try testing.expectEqual(@as(u8, 2), setting.bytes);
    try testing.expectEqual(@as(u8, 0x01), setting.endpoint);
    try testing.expectEqual(@as(u32, 192), setting.max_packet);
    try testing.expectEqual(@as(u32, 1), setting.intervalMs());
    try testing.expectEqual(@as(u8, 1), setting.terminal);
    try testing.expect(!setting.rate_control);
    try testing.expectEqual(@as(u32, 192), packetBytes(setting, 48_000));
    // 44.1 kHz is not a whole number of frames a millisecond.
    try testing.expect(findSetting(&speaker, 1, 44_100) == null);
    // No streaming interface 2; the control interface streams nothing.
    try testing.expect(findSetting(&speaker, 2, 48_000) == null);
    try testing.expect(findSetting(&speaker, 0, 48_000) == null);
}

test "a mono setting is taken when it is the one that fits" {
    var narrow = speaker;
    // The stereo setting's packet made too small for a millisecond.
    narrow[98] = 100;
    const setting = findSetting(&narrow, 1, 48_000).?;
    try testing.expectEqual(@as(u8, 2), setting.alternate);
    try testing.expectEqual(@as(u8, 1), setting.channels);
    try testing.expectEqual(@as(u8, 3), setting.bytes);
    try testing.expect(setting.rate_control);
}

test "the feature unit the stream's terminal feeds, and its controls" {
    const feature = findFeature(&speaker, 1).?;
    try testing.expectEqual(@as(u8, 0), feature.interface);
    try testing.expectEqual(@as(u8, 2), feature.unit);
    try testing.expectEqual(@as(u32, 0b001), feature.mutes);
    try testing.expectEqual(@as(u32, 0b110), feature.volumes);
    try testing.expect(findFeature(&speaker, 7) == null);
}

test "frames into samples: both sides, one, and wider" {
    const frames = [_]i16{ 0x1234, -2, 0x0102, 0x7FFF };
    var into: [16]u8 = @splat(0xAA);
    const stereo = Setting{ .channels = 2, .bytes = 2 };
    try testing.expectEqual(@as(u32, 8), convert(stereo, &frames, 2, &into));
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xFE, 0xFF, 0x02, 0x01, 0xFF, 0x7F }, into[0..8]);
    const mono = Setting{ .channels = 1, .bytes = 3 };
    try testing.expectEqual(@as(u32, 6), convert(mono, &frames, 2, &into));
    try testing.expectEqualSlices(u8, &.{ 0, 0x34, 0x12, 0, 0x02, 0x01 }, into[0..6]);
}

/// A sound adapter on its own clock: setting 1 plays 16-bit stereo at
/// 48 kHz on OUT endpoint 1, asynchronous, its rate told back on IN
/// endpoint 2 in three-byte packets.
const adapter = [_]u8{ 9, d.USB_DT_CONFIG, 0, 0, 1, 1, 0, 0x80, 50 } ++
    [_]u8{ 9, d.USB_DT_INTERFACE, 1, 0, 0, d.USB_CLASS_AUDIO, d.AUDIO_SUBCLASS_STREAMING, 0, 0 } ++
    [_]u8{ 9, d.USB_DT_INTERFACE, 1, 1, 2, d.USB_CLASS_AUDIO, d.AUDIO_SUBCLASS_STREAMING, 0, 0 } ++
    [_]u8{ 7, d.USB_DT_CS_INTERFACE, d.UAC_AS_GENERAL, 1, 1, 0x01, 0x00 } ++
    [_]u8{ 11, d.USB_DT_CS_INTERFACE, d.UAC_FORMAT_TYPE, d.UAC_FORMAT_TYPE_I, 2, 2, 16, 1, 0x80, 0xBB, 0x00 } ++
    [_]u8{ 9, d.USB_DT_ENDPOINT, 0x01, 0x05, 0xC4, 0x00, 1, 0, 0x82 } ++
    [_]u8{ 7, d.USB_DT_CS_ENDPOINT, d.UAC_EP_GENERAL, 1, 0, 0, 0 } ++
    [_]u8{ 9, d.USB_DT_ENDPOINT, 0x82, 0x01, 0x03, 0x00, 1, 5, 0 };

test "an asynchronous setting names its feedback endpoint; one that follows the stream has none" {
    const setting = findSetting(&adapter, 1, 48_000).?;
    try testing.expectEqual(d.USB_ENDPOINT_SYNC_ASYNC, setting.sync);
    try testing.expectEqual(@as(u8, 0x82), setting.feedback);
    try testing.expectEqual(@as(u32, 3), setting.feedback_packet);
    try testing.expectEqual(@as(u8, 0x01), setting.endpoint);
    try testing.expect(setting.rate_control);
    // Named, but not there: no feedback. bSynchAddress is the OUT
    // endpoint's last byte, before the class endpoint and the IN one.
    var elsewhere = adapter;
    elsewhere[adapter.len - 9 - 7 - 1] = 0x83;
    try testing.expectEqual(@as(u8, 0), findSetting(&elsewhere, 1, 48_000).?.feedback);
    const adaptive = findSetting(&speaker, 1, 48_000).?;
    try testing.expectEqual(d.USB_ENDPOINT_SYNC_ADAPTIVE, adaptive.sync);
    try testing.expectEqual(@as(u8, 0), adaptive.feedback);
}

test "a feedback packet's rate, and how far it is off" {
    // 48 samples a frame, 10.14; a little fast; 16.16 at high speed.
    try testing.expectEqual(@as(?u64, 48_000_000), feedbackRate(&.{ 0x00, 0x00, 0x0C }, false));
    try testing.expectEqual(@as(?u64, 48_000_976), feedbackRate(&.{ 0x10, 0x00, 0x0C }, false));
    try testing.expectEqual(@as(?u64, 48_000_000), feedbackRate(&.{ 0x00, 0x00, 0x06, 0x00 }, true));
    try testing.expectEqual(@as(?u64, 48_000_000), feedbackRate(&.{ 0x00, 0x00, 0x30, 0x00 }, false));
    try testing.expectEqual(@as(?u64, null), feedbackRate(&.{ 0x00, 0x0C }, false));
    try testing.expectEqual(@as(?u64, null), feedbackRate(&.{ 0, 0, 0 }, false));
    try testing.expectEqual(@as(i32, 20), driftPpm(48_000_976, 48_000));
    try testing.expectEqual(@as(i32, -1000), driftPpm(47_952_000, 48_000));
    try testing.expectEqual(@as(i32, 0x7FFF_FFFF), driftPpm(1 << 50, 48_000));
}

fn near(expected: u32, got: u32, per_mille: u32) !void {
    const off = if (got > expected) got - expected else expected - got;
    if (@as(u64, off) * 1000 > @as(u64, expected) * per_mille) {
        std.debug.print("expected {d}, got {d}\n", .{ expected, got });
        return error.TestExpectedApproxEq;
    }
}

test "a gain's level and back" {
    try testing.expectEqual(@as(i32, 0), dbOf(unity));
    // Half is 6.02 dB down, twice 6.02 up; a tenth 20 dB down.
    try testing.expectEqual(@as(i32, -1541), dbOf(unity / 2));
    try testing.expectEqual(@as(i32, 1541), dbOf(2 * unity));
    try testing.expectEqual(@as(i32, -5119), dbOf(unity / 10 + 1));
    try testing.expectEqual(unity, gainOf(0));
    try near(unity / 2, gainOf(-1541), 1);
    try near(unity / 10, gainOf(-5120), 1);
    try near(2 * unity, gainOf(1541), 1);
    try testing.expectEqual(most_rest, gainOf(12 * 256 + 512));
    try testing.expectEqual(@as(u32, 0), gainOf(-200 * 256));
}

test "a gain at a feature unit: within its range, above it, below it, none" {
    const min: i16 = -60 * 256;
    const within = levelFor(unity / 2, min, 0);
    try testing.expectEqual(@as(i16, -1541), within.value);
    try testing.expectEqual(unity, within.rest);
    // Above the unit's most: the rest in the mix.
    const above = levelFor(2 * unity, min, 0);
    try testing.expectEqual(@as(i16, 0), above.value);
    try near(2 * unity, above.rest, 2);
    // Below its least: the unit at its bottom, the mix the rest of the way.
    const below = levelFor(7, min, 0);
    try testing.expectEqual(min, below.value);
    try near(7000, below.rest, 10);
    const none = levelFor(0, min, 0);
    try testing.expectEqual(min, none.value);
    try testing.expectEqual(@as(u32, 0), none.rest);
}
