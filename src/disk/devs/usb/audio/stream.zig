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
};

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
                    if (playable(done, rate) and (best == null or better(done.setting, best.?))) best = done.setting;
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
                if (length >= 7 and here[3] & d.USB_ENDPOINT_XFERTYPE_MASK == d.USB_ENDPOINT_XFER_ISOC and here[2] & d.USB_DIR_IN == 0) {
                    candidate.out_iso = true;
                    candidate.setting.endpoint = here[2];
                    candidate.setting.max_packet = word(here, 4) & 0x7FF;
                    candidate.setting.interval = here[6];
                }
            },
            d.USB_DT_CS_ENDPOINT => if (current) |*candidate| {
                if (length >= 3 and here[2] == d.UAC_EP_GENERAL) candidate.setting.rate_control = here[3] & d.UAC_EP_SAMPLING_FREQ != 0;
            },
            else => {},
        }
        at += length;
    }
    if (current) |done| {
        if (playable(done, rate) and (best == null or better(done.setting, best.?))) best = done.setting;
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
