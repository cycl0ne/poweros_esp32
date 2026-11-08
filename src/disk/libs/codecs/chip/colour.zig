// SPDX-License-Identifier: MIT
//! What a stream's numbers mean, read out of its own parameter sets.
//!
//! The chip decodes the pictures and says nothing about their colours:
//! the WAVE511 reports the size, the depth, the profile and the frame
//! rate, and not a word of the VUI, where the matrix, the curve, the
//! primaries and the range are. Guessing BT.709 from the picture's
//! height is right for an ordinary film and wrong for one in high
//! dynamic range, which comes out flat and grey.
//!
//! So the setup record's SPS is read here, once, when the stream is
//! opened - with the very readers videoparse.library uses
//! (`h264/params.zig`, `hevc/params.zig`), because the fields are at the
//! end of a sequence parameter set and everything before them has to be
//! walked exactly: a short-term reference picture set predicted from
//! another cannot be passed over without working out how many pictures
//! it holds. What it says then travels with every frame the chip hands
//! out.
//!
//! An in-band parameter set is not looked at: a film changing its
//! colours part way through is not a thing, and the setup is what the
//! chip itself is started from.
//!
//! The light the film was mastered for is another matter: HDR10 puts it
//! in a prefix SEI unit (H.265 D.2.28 and D.2.35, H.264 D.1.29 and
//! D.1.33), which travels in the stream beside the pictures and not in
//! the setup record - a Matroska file's hvcC carries the parameter sets
//! and nothing else. So the first packets of a film whose curve is PQ
//! are looked through for it as they are fed, until it is found or a
//! few of them have gone by, and then not again (`_chip.zig`). Without
//! it graphics maps from a thousand candelas, which is what most films
//! are mastered for but not all.
//!
//! VP9 and AV1 have no parameter sets: what they say is in their
//! headers. A VP9 key frame's names its colour space and range, and
//! nothing of a curve - a WebM keeps that in its container, which
//! videocodec lays over every frame. An AV1 sequence header has the whole
//! colour description, in the track's av1C or else with the first key
//! frame, and metadata OBUs say the light. They are read with
//! videoparse.library's readers of those headers (`vp9/header.zig`,
//! `av1/header.zig`): an av1C when the stream is opened, and the first
//! packets as they are fed, until the colours are found.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
// videoparse.library's readers of the sets, as their own modules hand
// them out (`h264/sets.zig`, `hevc/sets.zig`): a file belongs to one
// module, and these are the very files the library reads a stream with.
const h264sets = @import("h264sets");
const hevcsets = @import("hevcsets");
const h264_params = h264sets.params;
const h264_nal = h264sets.nal;
const h264_bits = h264sets.bits;
const hevc_params = hevcsets.params;
const hevc_nal = hevcsets.nal;
const hevc_bits = hevcsets.bits;
// And its readers of VP9's and AV1's headers, likewise.
const vp9header = @import("vp9header");
const av1header = @import("av1header");
const v9 = sdk.videoparse.vp9;

/// What a picture's numbers mean, as `RtgYuv` says it.
pub const Colour = struct {
    matrix: u8 = rtg.RTGYUV_BT709,
    transfer: u8 = rtg.RTGYUV_SDR,
    primaries: u8 = rtg.RTGYUV_BT709,
    range: u8 = rtg.RTGYUV_LIMITED,
    /// The light the film was mastered for, in candelas, or 0 where
    /// nothing says: out of a prefix SEI unit, in the record or in the
    /// stream (`peakOf`).
    peak: u16 = 0,
    /// False where nothing could be read: the frame falls back to the
    /// matrix the picture's height suggests, as it always did.
    known: bool = false,
};

/// How much room to unescape a prefix SEI unit into. The mastering
/// display's message is 24 bytes and the content light level's 4, and
/// both come early; a unit longer than this is read as far as it fits.
pub const sei_room = 512;

/// The messages the light is in: the mastering display's colour volume,
/// and the content light level.
const SEI_MASTERING = 137;
const SEI_LIGHT_LEVEL = 144;

/// And AV1's metadata OBUs that say it: the content light level, and the
/// mastering display's colour volume.
const METADATA_HDR_CLL = 1;
const METADATA_HDR_MDCV = 2;

// The VUI's matrix, curve and primaries are H.273's numbers, which rtg
// turns into its own (`cicpMatrix` and the two beside it); what the VUI
// does not say is what it would have been guessed to be.

fn matrixOf(matrix: u8, height: u32) u8 {
    return rtg.bitmaps.cicpMatrix(matrix) orelse
        if (height >= 720) rtg.RTGYUV_BT709 else rtg.RTGYUV_BT601;
}

fn transferOf(transfer: u8) u8 {
    return rtg.bitmaps.cicpTransfer(transfer) orelse rtg.RTGYUV_SDR;
}

fn primariesOf(primaries: u8) u8 {
    return rtg.bitmaps.cicpPrimaries(primaries) orelse rtg.RTGYUV_BT709;
}

/// The colours the setup record's SPS says, for a picture `height` rows
/// high; what it does not say is what it would have been guessed to be.
/// `hevc` tells an hvcC record from an avcC one.
pub fn of(sys: *ExecBase, hevc: bool, config: []const u8, height: u32) Colour {
    const unit = (if (hevc) hevcSps(config) else avcSps(config)) orelse return .{};
    // The unit without its header, unescaped: a parameter set is small,
    // and this happens once a stream.
    const payload = unit[if (hevc) 2 else 1..];
    if (payload.len == 0) return .{};
    const room: [*]u8 = @ptrCast(sys.AllocVec(@intCast(payload.len), exec.MEMF_ANY) orelse return .{});
    defer sys.FreeVec(room);
    const rbsp = room[0..payload.len];
    var got = if (hevc) hevcColour(sys, rbsp[0..hevc_nal.unescape(payload, rbsp)], height) else avcColour(sys, rbsp[0..h264_nal.unescape(payload, rbsp)], height);
    // An hvcC record may carry prefix SEI units of its own beside the
    // parameter sets; most carry none, and then the stream is where the
    // light is.
    if (hevc and got.transfer == rtg.RTGYUV_PQ) {
        var scratch: [sei_room]u8 = undefined;
        got.peak = configPeak(config, &scratch);
    }
    return got;
}

/// What a VP9 key frame's uncompressed header says of its colours, out of
/// `packet` - the frame, or a superframe whose first frame it is - for a
/// picture `height` rows high, as vp9.vcodec takes them; null where the
/// first frame is not a key frame or cannot be read. VP9 names its
/// colours and its range and nothing of a curve: a film in PQ says that
/// in its container, which videocodec lays over what is said here.
pub fn ofVp9(packet: []const u8, height: u32) ?Colour {
    var kept: vp9header.Persist = .{};
    var h: v9.Vp9Header = .{};
    vp9header.uncompressed(packet, &kept, &.{}, &h) catch return null;
    if (h.show_existing_frame or h.frame_type != v9.KEY_FRAME) return null;
    const c = kept.color;
    return .{
        .matrix = switch (c.color_space) {
            v9.CS_BT_601, v9.CS_SMPTE_170 => rtg.RTGYUV_BT601,
            v9.CS_BT_709, v9.CS_SMPTE_240, v9.CS_RGB => rtg.RTGYUV_BT709,
            v9.CS_BT_2020 => rtg.RTGYUV_BT2020,
            else => if (height >= 720) rtg.RTGYUV_BT709 else rtg.RTGYUV_BT601,
        },
        .primaries = if (c.color_space == v9.CS_BT_2020) rtg.RTGYUV_BT2020 else rtg.RTGYUV_BT709,
        .range = if (c.color_range) rtg.RTGYUV_FULL else rtg.RTGYUV_LIMITED,
        .known = true,
    };
}

/// What an AV1 stream's OBUs say, into `got`, for a picture `height`
/// rows high: `obus` is an av1C's configOBUs or a packet, a temporal
/// unit. A sequence header's colour description and range are taken
/// where `got` has none yet (`known` then), and the light metadata OBUs
/// say the film was mastered for wherever they say it.
pub fn readAv1(obus: []const u8, height: u32, got: *Colour) void {
    var light: Light = .{};
    var at: usize = 0;
    while (at < obus.len) {
        const o = av1header.obu(obus[at..]) catch break;
        at += o.len;
        switch (o.kind) {
            av1header.OBU_SEQUENCE_HEADER => if (!got.known) {
                const s = av1header.sequence(o.payload) catch continue;
                got.* = .{
                    .matrix = matrixOf(s.matrix_coefficients, height),
                    .transfer = transferOf(s.transfer_characteristics),
                    .primaries = primariesOf(s.color_primaries),
                    .range = if (s.color_range) rtg.RTGYUV_FULL else rtg.RTGYUV_LIMITED,
                    .peak = got.peak,
                    .known = true,
                };
            },
            av1header.OBU_METADATA => light.metadata(o.payload),
            else => {},
        }
    }
    const peak = light.nits();
    if (peak != 0) got.peak = peak;
}

/// The light a packet's own prefix SEI units say the film was mastered
/// for, 0 where they say nothing: the units are read as they lie in the
/// packet, each after its length of `length_size` bytes, and `scratch`
/// is room to unescape one into (`sei_room` bytes is plenty). `hevc`
/// tells an H.265 packet from an H.264 one.
pub fn peakOf(hevc: bool, packet: []const u8, length_size: u8, scratch: []u8) u16 {
    var light: Light = .{};
    var at: usize = 0;
    while (at + length_size <= packet.len) {
        var length: usize = 0;
        for (packet[at..][0..length_size]) |byte| length = (length << 8) | byte;
        at += length_size;
        if (length > packet.len - at) break;
        const unit = packet[at..][0..length];
        at += length;
        const head: usize = if (hevc) 2 else 1;
        if (unit.len <= head) continue;
        const sei = if (hevc)
            (unit[0] >> 1) & 0x3F == hevc_nal.Type.prefix_sei
        else
            unit[0] & 0x1F == h264_nal.Type.sei;
        if (sei) readSei(unit[head..], scratch, &light);
    }
    return light.nits();
}

/// What the two messages say, in candelas.
const Light = struct {
    /// The brightest the display it was graded on could go.
    mastering: u32 = 0,
    /// The brightest pixel in the film.
    content: u32 = 0,

    /// The light to map from: the mastering display's maximum, held down
    /// to the film's brightest pixel where it says that too and it is
    /// lower - a film is no brighter than its brightest pixel, and
    /// mapping from a peak it never reaches would darken it for nothing.
    fn nits(l: Light) u16 {
        const peak = if (l.mastering != 0 and l.content != 0)
            @min(l.mastering, l.content)
        else if (l.mastering != 0) l.mastering else l.content;
        return @intCast(@min(peak, 10000));
    }

    /// An AV1 metadata OBU's payload (5.8.1): its type - a leb128, one
    /// byte for the two read - then HDR_CLL's brightest pixel in
    /// candelas, or HDR_MDCV's primaries and white point (16 bytes) and
    /// its maximum in 256ths of a candela. Any other kind is passed over.
    fn metadata(l: *Light, payload: []const u8) void {
        if (payload.len == 0 or payload[0] & 0x80 != 0) return;
        const body = payload[1..];
        switch (payload[0]) {
            METADATA_HDR_CLL => if (body.len >= 2) {
                l.content = @intCast(be16(body));
            },
            METADATA_HDR_MDCV => if (body.len >= 20) {
                l.mastering = be32(body[16..]) >> 8;
            },
            else => {},
        }
    }
};

/// The messages of one SEI unit's payload, as far as `scratch` holds it:
/// what they say of the light goes into `light`. A message is a type and
/// a size, each a run of bytes where 255 means another follows, and then
/// that many bytes - all whole bytes, so no bit reader is wanted here.
fn readSei(payload: []const u8, scratch: []u8, light: *Light) void {
    // Both standards escape a payload alike (00 00 03), so either one's
    // unescaping does for both.
    const room = @min(payload.len, scratch.len);
    const rbsp = scratch[0..hevc_nal.unescape(payload[0..room], scratch[0..room])];
    var at: usize = 0;
    while (at < rbsp.len) {
        var kind: u32 = 0;
        while (at < rbsp.len and rbsp[at] == 0xFF) : (at += 1) kind += 255;
        if (at >= rbsp.len) return;
        kind += rbsp[at];
        at += 1;
        var size: usize = 0;
        while (at < rbsp.len and rbsp[at] == 0xFF) : (at += 1) size += 255;
        if (at >= rbsp.len) return;
        size += rbsp[at];
        at += 1;
        if (size > rbsp.len - at) return;
        const body = rbsp[at..][0..size];
        at += size;
        if (kind == SEI_MASTERING and size >= 24) {
            // Three primaries and the white point first, six words of
            // them, then the maximum in ten-thousandths of a candela.
            light.mastering = be32(body[16..]) / 10000;
        } else if (kind == SEI_LIGHT_LEVEL and size >= 4) {
            light.content = @intCast(be16(body));
        }
    }
}

/// The light an hvcC record's own prefix SEI units say, 0 where it has
/// none.
fn configPeak(config: []const u8, scratch: []u8) u16 {
    var units = HvcUnits.init(config) orelse return 0;
    var light: Light = .{};
    while (units.next()) |one| {
        if (one.kind == hevc_nal.Type.prefix_sei and one.unit.len > 2) readSei(one.unit[2..], scratch, &light);
    }
    return light.nits();
}

fn hevcColour(sys: *ExecBase, rbsp: []const u8, height: u32) Colour {
    // A sequence parameter set is a large thing to hold - its reference
    // picture sets alone are kilobytes - so it is not put on the
    // caller's stack.
    const s: *hevc_params.Sps = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(hevc_params.Sps), exec.MEMF_ANY) orelse return .{}));
    defer sys.FreeVec(s);
    s.* = .{};
    var b = hevc_bits.Bits.init(rbsp);
    _ = hevc_params.parseSps(&b, s, .{}) catch return .{};
    return .{
        .matrix = matrixOf(s.matrix, height),
        .transfer = transferOf(s.transfer),
        .primaries = primariesOf(s.colour_primaries),
        .range = if (s.full_range) rtg.RTGYUV_FULL else rtg.RTGYUV_LIMITED,
        .known = true,
    };
}

fn avcColour(sys: *ExecBase, rbsp: []const u8, height: u32) Colour {
    const s: *h264_params.Sps = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(h264_params.Sps), exec.MEMF_ANY) orelse return .{}));
    defer sys.FreeVec(s);
    s.* = .{};
    var b = h264_bits.Bits.init(rbsp);
    _ = h264_params.parseSps(&b, s, .{}) catch return .{};
    return .{
        .matrix = matrixOf(s.matrix, height),
        .transfer = transferOf(s.transfer),
        .primaries = primariesOf(s.colour_primaries),
        .range = if (s.full_range) rtg.RTGYUV_FULL else rtg.RTGYUV_LIMITED,
        .known = true,
    };
}

fn be16(b: []const u8) usize {
    return @as(usize, b[0]) << 8 | b[1];
}

fn be32(b: []const u8) u32 {
    return @as(u32, b[0]) << 24 | @as(u32, b[1]) << 16 | @as(u32, b[2]) << 8 | b[3];
}

/// The units of an hvcC record's arrays (8.3.3), one at a time, each
/// with its two-byte header still on it and the kind of unit it is.
const HvcUnits = struct {
    config: []const u8,
    at: usize = 23,
    arrays: usize,
    count: usize = 0,
    kind: u8 = 0,

    fn init(config: []const u8) ?HvcUnits {
        if (config.len < 23 or config[0] != 1) return null;
        return .{ .config = config, .arrays = config[22] };
    }

    fn next(u: *HvcUnits) ?struct { kind: u8, unit: []const u8 } {
        while (u.count == 0) {
            if (u.arrays == 0) return null;
            u.arrays -= 1;
            if (u.at + 3 > u.config.len) return null;
            u.kind = u.config[u.at] & 0x3F;
            u.count = be16(u.config[u.at + 1 ..]);
            u.at += 3;
        }
        u.count -= 1;
        if (u.at + 2 > u.config.len) return null;
        const length = be16(u.config[u.at..]);
        u.at += 2;
        if (u.at + length > u.config.len) return null;
        const unit = u.config[u.at..][0..length];
        u.at += length;
        return .{ .kind = u.kind, .unit = unit };
    }
};

/// The first sequence parameter set of an avcC record (ISO 14496-15
/// 5.3.3), with its one-byte header still on it.
fn avcSps(config: []const u8) ?[]const u8 {
    if (config.len < 7 or config[0] != 1) return null;
    const count = config[5] & 0x1F;
    if (count == 0) return null;
    const length = be16(config[6..]);
    if (8 + length > config.len or length == 0) return null;
    return config[8..][0..length];
}

/// The first sequence parameter set of an hvcC record, with its
/// two-byte header still on it: the arrays are walked for the one whose
/// units are of type 33.
fn hevcSps(config: []const u8) ?[]const u8 {
    var units = HvcUnits.init(config) orelse return null;
    while (units.next()) |one| {
        if (one.kind == hevc_nal.Type.sps and one.unit.len > 2) return one.unit;
    }
    return null;
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

/// What an encoder does to a payload on its way into a unit: a 03 byte
/// after every two zeros, so that no start code can appear inside one.
fn escape(payload: []const u8, out: []u8) usize {
    var n: usize = 0;
    var zeros: u32 = 0;
    for (payload) |byte| {
        if (zeros >= 2 and byte <= 3) {
            out[n] = 3;
            n += 1;
            zeros = 0;
        }
        out[n] = byte;
        n += 1;
        zeros = if (byte == 0) zeros + 1 else 0;
    }
    return n;
}

/// A prefix SEI unit with the two messages HDR10 says the light in:
/// `nits` on the mastering display, `cll` the brightest pixel (0 leaves
/// that message out). H.265 unless `hevc` is false.
fn seiUnit(hevc: bool, nits: u32, cll: u16, out: []u8) []const u8 {
    var at: usize = 0;
    if (hevc) {
        // The kind of unit in the top six bits of the first byte - as a
        // byte, or the shift would throw it away: the type is six bits.
        out[0] = @as(u8, hevc_nal.Type.prefix_sei) << 1;
        out[1] = 1;
        at = 2;
    } else {
        out[0] = h264_nal.Type.sei;
        at = 1;
    }
    if (nits != 0) {
        out[at] = SEI_MASTERING;
        out[at + 1] = 24;
        at += 2;
        // The primaries and the white point are left at zero here: the
        // curve wants the light alone, which is six words further on.
        @memset(out[at..][0..24], 0);
        std.mem.writeInt(u32, out[at + 16 ..][0..4], nits * 10_000, .big);
        at += 24;
    }
    if (cll != 0) {
        out[at] = SEI_LIGHT_LEVEL;
        out[at + 1] = 4;
        at += 2;
        std.mem.writeInt(u16, out[at..][0..2], cll, .big);
        std.mem.writeInt(u16, out[at + 2 ..][0..2], cll / 2, .big);
        at += 4;
    }
    // rbsp_trailing_bits.
    out[at] = 0x80;
    at += 1;
    return out[0..at];
}

/// `unit` as a packet's one unit, each after its four-byte length.
fn packetOf(unit: []const u8, out: []u8) []const u8 {
    std.mem.writeInt(u32, out[0..4], @intCast(unit.len), .big);
    @memcpy(out[4..][0..unit.len], unit);
    return out[0 .. 4 + unit.len];
}

test "a packet's prefix SEI: the light the film was mastered for" {
    var room: [64]u8 = undefined;
    var bytes: [80]u8 = undefined;
    var scratch: [sei_room]u8 = undefined;
    // A thousand candelas on the mastering display, a brighter pixel
    // than that nowhere: the display's is what the film is mapped from.
    const unit = seiUnit(true, 1000, 1200, &room);
    try testing.expectEqual(@as(u16, 1000), peakOf(true, packetOf(unit, &bytes), 4, &scratch));
    // The film's own brightest pixel below it: mapping from a light it
    // never reaches would darken it for nothing.
    const dimmer = seiUnit(true, 1000, 600, &room);
    try testing.expectEqual(@as(u16, 600), peakOf(true, packetOf(dimmer, &bytes), 4, &scratch));
    // One message or the other alone.
    const only_display = seiUnit(true, 4000, 0, &room);
    try testing.expectEqual(@as(u16, 4000), peakOf(true, packetOf(only_display, &bytes), 4, &scratch));
    const only_content = seiUnit(true, 0, 500, &room);
    try testing.expectEqual(@as(u16, 500), peakOf(true, packetOf(only_content, &bytes), 4, &scratch));
    // H.264 says it the same way, in a unit of its own kind.
    const avc = seiUnit(false, 1000, 0, &room);
    try testing.expectEqual(@as(u16, 1000), peakOf(false, packetOf(avc, &bytes), 4, &scratch));
    // An H.265 unit read as an H.264 one is not a prefix SEI: 0x4E's low
    // five bits are 14, a prefix unit. (In a room of its own: the one
    // above was written over by the units after it.)
    var again: [64]u8 = undefined;
    const h265 = seiUnit(true, 1000, 0, &again);
    try testing.expectEqual(@as(u16, 0), peakOf(false, packetOf(h265, &bytes), 4, &scratch));
}

test "a packet of pictures alone, and one whose SEI is escaped" {
    var room: [64]u8 = undefined;
    var bytes: [96]u8 = undefined;
    var scratch: [sei_room]u8 = undefined;
    // A slice and nothing else: nothing says a light, and none is
    // guessed.
    const slice = [_]u8{ 0x26, 0x01, 0xAF, 0x00, 0x00, 0x00, 0x01 };
    try testing.expectEqual(@as(u16, 0), peakOf(true, packetOf(&slice, &bytes), 4, &scratch));
    // The same SEI as it really travels: zeros in the primaries mean 03
    // bytes between them, which have to come out again before the
    // messages can be read.
    const unit = seiUnit(true, 1000, 0, &room);
    var escaped: [96]u8 = undefined;
    @memcpy(escaped[0..2], unit[0..2]);
    const len = 2 + escape(unit[2..], escaped[2..]);
    try testing.expect(len > unit.len);
    var out: [128]u8 = undefined;
    try testing.expectEqual(@as(u16, 1000), peakOf(true, packetOf(escaped[0..len], &out), 4, &scratch));
    // Two-byte lengths, as a track whose units are short says them.
    var short: [96]u8 = undefined;
    std.mem.writeInt(u16, short[0..2], @intCast(unit.len), .big);
    @memcpy(short[2..][0..unit.len], unit);
    try testing.expectEqual(@as(u16, 1000), peakOf(true, short[0 .. 2 + unit.len], 2, &scratch));
    // A length longer than the packet: read no further, and say nothing.
    var cut: [32]u8 = @splat(0);
    cut[3] = 200;
    try testing.expectEqual(@as(u16, 0), peakOf(true, &cut, 4, &scratch));
}

test "an hvcC record: its parameter set, and the SEI some carry" {
    // Version 1, two-byte lengths, two arrays: an SPS of 4 bytes, and a
    // prefix SEI unit.
    var room: [64]u8 = undefined;
    const unit = seiUnit(true, 1000, 0, &room);
    var record: [23 + 3 + 2 + 4 + 3 + 2 + 64]u8 = @splat(0);
    record[0] = 1;
    record[21] = 0x0D;
    record[22] = 2;
    @memcpy(record[23..32], &[_]u8{ hevc_nal.Type.sps, 0, 1, 0, 4, 0x42, 1, 2, 3 });
    var at: usize = 32;
    record[at] = hevc_nal.Type.prefix_sei;
    record[at + 1] = 0;
    record[at + 2] = 1;
    std.mem.writeInt(u16, record[at + 3 ..][0..2], @intCast(unit.len), .big);
    at += 5;
    @memcpy(record[at..][0..unit.len], unit);
    at += unit.len;
    const config = record[0..at];
    try testing.expectEqualSlices(u8, &.{ 0x42, 1, 2, 3 }, hevcSps(config).?);
    var scratch: [sei_room]u8 = undefined;
    try testing.expectEqual(@as(u16, 1000), configPeak(config, &scratch));
    // A record with no SEI array of its own - which is most of them.
    try testing.expectEqual(@as(u16, 0), configPeak(record[0..32], &scratch));
    // Not a record at all.
    try testing.expect(hevcSps(record[0..12]) == null);
    try testing.expectEqual(@as(u16, 0), configPeak(record[0..12], &scratch));
}

/// The first frame of an IVF file, and the one after it.
fn ivfFrames(ivf: []const u8) [2][]const u8 {
    const first = std.mem.readInt(u32, ivf[32..36], .little);
    const second_at = 44 + first;
    const second = std.mem.readInt(u32, ivf[second_at..][0..4], .little);
    return .{ ivf[44..][0..first], ivf[second_at + 12 ..][0..second] };
}

test "a VP9 key frame's colours, and a frame that is not one" {
    const frames = ivfFrames(@embedFile("../vp9/tests/alt.ivf"));
    // The clip says nothing of its colours: they are what its 104 rows
    // suggest.
    const plain = ofVp9(frames[0], 104).?;
    try testing.expect(plain.known);
    try testing.expectEqual(rtg.RTGYUV_BT601, plain.matrix);
    try testing.expectEqual(rtg.RTGYUV_BT709, plain.primaries);
    try testing.expectEqual(rtg.RTGYUV_LIMITED, plain.range);
    try testing.expectEqual(rtg.RTGYUV_SDR, plain.transfer);
    // The same frame made to say BT.2020 at full range: color_space and
    // color_range are the first four bits after the sync code.
    var wide: [64]u8 = undefined;
    @memcpy(&wide, frames[0][0..64]);
    wide[4] = 0xB0 | (wide[4] & 0x0F);
    const said = ofVp9(&wide, 104).?;
    try testing.expectEqual(rtg.RTGYUV_BT2020, said.matrix);
    try testing.expectEqual(rtg.RTGYUV_BT2020, said.primaries);
    try testing.expectEqual(rtg.RTGYUV_FULL, said.range);
    // An inter frame says nothing.
    try testing.expect(ofVp9(frames[1], 104) == null);
}

test "an AV1 temporal unit's sequence header, and the light its metadata says" {
    const unit = ivfFrames(@embedFile("../av1/tests/t1.ivf"))[0];
    var got: Colour = .{};
    readAv1(unit, 112, &got);
    try testing.expect(got.known);
    try testing.expectEqual(rtg.RTGYUV_BT601, got.matrix);
    try testing.expectEqual(rtg.RTGYUV_SDR, got.transfer);
    try testing.expectEqual(@as(u16, 0), got.peak);
    // Metadata OBUs: the mastering display at 1000 candelas, then the
    // film's brightest pixel at 400.
    const mdcv = [_]u8{ 0x2A, 25, METADATA_HDR_MDCV } ++ [_]u8{0} ** 16 ++ [_]u8{ 0x00, 0x03, 0xE8, 0x00 } ++ [_]u8{0} ** 4;
    const cll = [_]u8{ 0x2A, 5, METADATA_HDR_CLL, 0x01, 0x90, 0x00, 0x64 };
    readAv1(&(mdcv ++ cll), 112, &got);
    try testing.expectEqual(@as(u16, 400), got.peak);
    try testing.expect(got.known);
    // A sequence header after the first changes nothing; the light holds.
    readAv1(unit, 2160, &got);
    try testing.expectEqual(rtg.RTGYUV_BT601, got.matrix);
    try testing.expectEqual(@as(u16, 400), got.peak);
    // Bytes that are no OBUs.
    var none: Colour = .{};
    readAv1(&.{ 0xFF, 0xFF, 0xFF }, 112, &none);
    try testing.expect(!none.known);
}
