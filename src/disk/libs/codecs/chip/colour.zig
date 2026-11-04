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
//! opened - with the very parsers the software modules use
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

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
// The decoders' own parsers, as their modules hand them out: a file
// belongs to one module, and these are built and tested as the software
// codecs' cores.
const h264core = @import("h264core");
const hevccore = @import("hevccore");
const h264_params = h264core.params;
const h264_nal = h264core.nal;
const h264_bits = h264core.bits;
const hevc_params = hevccore.params;
const hevc_nal = hevccore.nal;
const hevc_bits = hevccore.bits;

/// What a picture's numbers mean, as `RtgYuv` says it.
pub const Colour = struct {
    matrix: u8 = rtg.RTGYUV_BT709,
    transfer: u8 = rtg.RTGYUV_SDR,
    primaries: u8 = rtg.RTGYUV_BT709,
    range: u8 = rtg.RTGYUV_LIMITED,
    /// False where nothing could be read: the frame falls back to the
    /// matrix the picture's height suggests, as it always did.
    known: bool = false,
};

/// The VUI's matrices, curves and primaries (H.264 Table E-5 and the
/// like, H.265 Table E.5), by the numbers both standards share.
const MC_BT_709 = 1;
const MC_BT_470_B_G = 5;
const MC_BT_601 = 6;
const MC_FCC = 4;
const MC_SMPTE_240 = 7;
const MC_BT_2020_NCL = 9;
const MC_BT_2020_CL = 10;
const TR_PQ = 16;
const TR_HLG = 18;
const CP_BT_2020 = 9;
const CP_P3_DCI = 11;
const CP_P3_D65 = 12;

fn matrixOf(matrix: u8, height: u32) u8 {
    return switch (matrix) {
        MC_BT_709 => rtg.RTGYUV_BT709,
        MC_FCC, MC_BT_470_B_G, MC_BT_601, MC_SMPTE_240 => rtg.RTGYUV_BT601,
        MC_BT_2020_NCL, MC_BT_2020_CL => rtg.RTGYUV_BT2020,
        else => if (height >= 720) rtg.RTGYUV_BT709 else rtg.RTGYUV_BT601,
    };
}

fn transferOf(transfer: u8) u8 {
    return switch (transfer) {
        TR_PQ => rtg.RTGYUV_PQ,
        TR_HLG => rtg.RTGYUV_HLG,
        else => rtg.RTGYUV_SDR,
    };
}

fn primariesOf(primaries: u8) u8 {
    return switch (primaries) {
        CP_BT_2020 => rtg.RTGYUV_BT2020,
        CP_P3_DCI, CP_P3_D65 => rtg.RTGYUV_P3,
        else => rtg.RTGYUV_BT709,
    };
}

/// The colours the setup record's SPS says, for a picture `height` rows
/// high; what it does not say is what it would have been guessed to be.
/// `hevc` tells an hvcC record from an avcC one.
pub fn of(sys: *ExecBase, hevc: bool, config: []const u8, height: u32) Colour {
    const unit = (if (hevc) hevcSps(config) else avcSps(config)) orelse return .{};
    // The unit without its header, unescaped: a parameter set is small,
    // and this happens once a stream.
    const payload = unit[if (hevc) 2 else 1 ..];
    if (payload.len == 0) return .{};
    const room: [*]u8 = @ptrCast(sys.AllocVec(@intCast(payload.len), exec.MEMF_ANY) orelse return .{});
    defer sys.FreeVec(room);
    const rbsp = room[0..payload.len];
    return if (hevc) hevcColour(sys, rbsp[0..hevc_nal.unescape(payload, rbsp)], height) else avcColour(sys, rbsp[0..h264_nal.unescape(payload, rbsp)], height);
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

/// The first sequence parameter set of an hvcC record (8.3.3), with its
/// two-byte header still on it: the arrays are walked for the one whose
/// units are of type 33.
fn hevcSps(config: []const u8) ?[]const u8 {
    if (config.len < 23 or config[0] != 1) return null;
    const arrays = config[22];
    var at: usize = 23;
    for (0..arrays) |_| {
        if (at + 3 > config.len) return null;
        const kind = config[at] & 0x3F;
        const count = be16(config[at + 1 ..]);
        at += 3;
        for (0..count) |_| {
            if (at + 2 > config.len) return null;
            const length = be16(config[at..]);
            at += 2;
            if (at + length > config.len) return null;
            if (kind == hevc_nal.Type.sps and length > 2) return config[at..][0..length];
            at += length;
        }
    }
    return null;
}
