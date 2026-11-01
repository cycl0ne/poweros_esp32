// SPDX-License-Identifier: MIT
//! An Opus stream's packets (RFC 6716 3, 4.5): the TOC byte's mode -
//! SILK, CELT or both (hybrid) - bandwidth, frame size and channels; the
//! packet's frames, one to 48 of them; and each frame through SILK, CELT
//! or both, at 48 kHz.
//!
//! **Changing mode** is smoothed: a 5 ms CELT frame at the end of a SILK
//! frame or the start of one after CELT (redundancy) cross-fades the two,
//! and when there is none, the decoder conceals 5 ms of the old mode and
//! fades from it.
//!
//! **Output** is float, 1.0 full scale, the stream's gain applied; the
//! soft clipper bends what goes beyond 1.0 instead of cutting it off.

const celt = @import("celt.zig");
const silk = @import("silk.zig");
const tables = @import("celt_tables.zig");
const Range = @import("range.zig").Range;

pub const Mode = enum(u2) { none, silk_only, hybrid, celt_only };

pub const Bandwidth = enum(u3) { none, narrow, medium, wide, superwide, full };

pub const Error = error{
    /// The packet's framing does not add up.
    InvalidPacket,
    /// More samples than the buffer has room for.
    BufferTooSmall,
    /// A frame the decoder failed on.
    Internal,
};

/// The longest a packet plays: 120 ms.
pub const max_frame_size = 5760;

const f20 = 960;
const f10 = 480;
const f5 = 240;
const f2_5 = 120;

/// The packet's mode, from its TOC byte.
pub fn packetMode(toc: u8) Mode {
    if (toc & 0x80 != 0) return .celt_only;
    if (toc & 0x60 == 0x60) return .hybrid;
    return .silk_only;
}

pub fn packetBandwidth(toc: u8) Bandwidth {
    if (toc & 0x80 != 0) {
        const b = (toc >> 5) & 3;
        return @enumFromInt(if (b == 0) 1 else b + 2);
    }
    if (toc & 0x60 == 0x60) return if (toc & 0x10 != 0) .full else .superwide;
    return @enumFromInt(((toc >> 5) & 3) + 1);
}

/// The samples one frame of the packet plays at 48 kHz.
pub fn packetSamplesPerFrame(toc: u8) u32 {
    if (toc & 0x80 != 0) return (@as(u32, 48000) << @intCast((toc >> 3) & 3)) / 400;
    if (toc & 0x60 == 0x60) return if (toc & 0x08 != 0) 960 else 480;
    const s = (toc >> 3) & 3;
    if (s == 3) return 2880;
    return (@as(u32, 48000) << @intCast(s)) / 100;
}

pub fn packetChannels(toc: u8) u32 {
    return if (toc & 0x04 != 0) 2 else 1;
}

/// A packet's frames: where each starts and how long it is.
pub const Frames = struct {
    toc: u8,
    count: u32,
    /// Where the first frame starts.
    offset: u32,
    size: [48]u16,
    /// The whole packet's length with its padding, for the stream after
    /// it in a multistream packet.
    packet_len: u32,
};

fn parseSize(data: []const u8, size: *u16) ?u32 {
    if (data.len < 1) return null;
    if (data[0] < 252) {
        size.* = data[0];
        return 1;
    }
    if (data.len < 2) return null;
    size.* = 4 * @as(u16, data[1]) + data[0];
    return 2;
}

/// The frames of `data`; `self_delimited` when the last frame's length is
/// coded too (every stream but the last of a multistream packet).
pub fn parsePacket(data: []const u8, self_delimited: bool) Error!Frames {
    if (data.len == 0) return error.InvalidPacket;
    var f: Frames = .{ .toc = data[0], .count = 0, .offset = 0, .size = undefined, .packet_len = 0 };
    const framesize = packetSamplesPerFrame(data[0]);
    var at: usize = 1;
    var len: i32 = @intCast(data.len - 1);
    var last_size: i32 = len;
    var cbr = false;
    var pad: i32 = 0;
    switch (data[0] & 3) {
        0 => f.count = 1,
        1 => {
            f.count = 2;
            cbr = true;
            if (!self_delimited) {
                if (len & 1 != 0) return error.InvalidPacket;
                last_size = @divTrunc(len, 2);
                f.size[0] = @intCast(@min(last_size, 0xFFFF));
            }
        },
        2 => {
            f.count = 2;
            const bytes = parseSize(data[at..], &f.size[0]) orelse return error.InvalidPacket;
            len -= @intCast(bytes);
            if (f.size[0] > len) return error.InvalidPacket;
            at += bytes;
            last_size = len - f.size[0];
        },
        else => {
            if (len < 1) return error.InvalidPacket;
            const ch = data[at];
            at += 1;
            f.count = ch & 0x3F;
            if (f.count == 0 or framesize * f.count > max_frame_size) return error.InvalidPacket;
            len -= 1;
            if (ch & 0x40 != 0) {
                while (true) {
                    if (len <= 0) return error.InvalidPacket;
                    const p = data[at];
                    at += 1;
                    len -= 1;
                    const tmp: i32 = if (p == 255) 254 else p;
                    len -= tmp;
                    pad += tmp;
                    if (p != 255) break;
                }
            }
            if (len < 0) return error.InvalidPacket;
            cbr = ch & 0x80 == 0;
            if (!cbr) {
                last_size = len;
                for (0..f.count - 1) |i| {
                    const bytes = parseSize(data[at..], &f.size[i]) orelse return error.InvalidPacket;
                    len -= @intCast(bytes);
                    if (f.size[i] > len) return error.InvalidPacket;
                    at += bytes;
                    last_size -= @as(i32, @intCast(bytes)) + f.size[i];
                }
                if (last_size < 0) return error.InvalidPacket;
            } else if (!self_delimited) {
                last_size = @divTrunc(len, @as(i32, @intCast(f.count)));
                if (last_size * @as(i32, @intCast(f.count)) != len) return error.InvalidPacket;
                for (0..f.count - 1) |i| f.size[i] = @intCast(@min(last_size, 0xFFFF));
            }
        },
    }
    const last = f.count - 1;
    if (self_delimited) {
        const bytes = parseSize(data[at..], &f.size[last]) orelse return error.InvalidPacket;
        len -= @intCast(bytes);
        if (f.size[last] > len) return error.InvalidPacket;
        at += bytes;
        if (cbr) {
            if (@as(i32, f.size[last]) * @as(i32, @intCast(f.count)) > len) return error.InvalidPacket;
            for (0..last) |i| f.size[i] = f.size[last];
        } else if (@as(i32, @intCast(bytes)) + f.size[last] > last_size) return error.InvalidPacket;
    } else {
        if (last_size > 1275) return error.InvalidPacket;
        f.size[last] = @intCast(last_size);
    }
    f.offset = @intCast(at);
    var end = at;
    for (f.size[0..f.count]) |s| end += s;
    f.packet_len = @intCast(@as(i32, @intCast(end)) + pad);
    return f;
}

/// Room for one frame's SILK output, the old mode's last 5 ms and a
/// redundant frame.
const Scratch = struct {
    pcm_silk: [2 * 2880]i16,
    transition: [2 * f5]f32,
    redundant: [2 * f5]f32,
};

pub const Decoder = struct {
    channels: u32,
    celt: celt.Celt,
    silk: silk.Decoder,
    silk_ctl: silk.Control,
    /// The OpusHead's output gain, Q8 dB.
    decode_gain: i16,
    stream_channels: u32,
    bandwidth: Bandwidth,
    mode: Mode,
    prev_mode: Mode,
    frame_size: u32,
    prev_redundancy: bool,
    last_packet_duration: u32,
    softclip_mem: [2]f32,
    /// The range coder's final state of the last frame, as an encoder
    /// reports it.
    range_final: u32,
    scratch: Scratch,

    /// Ready for a stream of `channels` (1 or 2).
    pub fn init(d: *Decoder, channels: u32) void {
        d.channels = channels;
        celt.init(&d.celt, channels);
        d.silk.init();
        d.silk_ctl = .{ .channels_api = channels, .channels_internal = channels, .internal_sample_rate = 16000, .payload_size_ms = 20 };
        d.decode_gain = 0;
        d.reset();
    }

    /// Everything the packets left behind forgotten, as after a seek.
    pub fn reset(d: *Decoder) void {
        celt.reset(&d.celt);
        d.silk.reset();
        d.stream_channels = d.channels;
        d.bandwidth = .none;
        d.mode = .none;
        d.prev_mode = .none;
        d.frame_size = 960;
        d.prev_redundancy = false;
        d.last_packet_duration = 0;
        d.softclip_mem = .{ 0, 0 };
        d.range_final = 0;
    }

    /// One frame of `audiosize` samples to `pcm`, or the concealment of
    /// up to `frame_size` when `data` is null.
    fn decodeFrame(d: *Decoder, data_in: ?[]const u8, pcm: []f32, frame_size_in: u32) Error!u32 {
        const cc = d.channels;
        var frame_size: u32 = @min(frame_size_in, max_frame_size);
        var data = data_in;
        var len: u32 = if (data) |b| @intCast(b.len) else 0;
        // A TOC alone (DTX) or nothing: conceal, no more than the TOC said.
        if (len <= 1) {
            data = null;
            frame_size = @min(frame_size, d.frame_size);
        }

        var audiosize: u32 = undefined;
        var mode: Mode = undefined;
        var bandwidth: Bandwidth = undefined;
        var dec: Range = undefined;
        if (data) |b| {
            audiosize = d.frame_size;
            mode = d.mode;
            bandwidth = d.bandwidth;
            dec = Range.init(b);
        } else {
            audiosize = frame_size;
            // The concealment goes on in the last mode (CELT after a
            // redundant frame).
            mode = if (d.prev_redundancy) .celt_only else d.prev_mode;
            bandwidth = .none;
            if (mode == .none) {
                @memset(pcm[0 .. audiosize * cc], 0);
                return audiosize;
            }
            // Only 2.5, 5, 10 and 20 ms are concealed.
            if (audiosize > f20) {
                var done: u32 = 0;
                while (done < audiosize) {
                    done += try d.decodeFrame(null, pcm[done * cc ..], @min(audiosize - done, f20));
                }
                return frame_size;
            } else if (audiosize < f20) {
                if (audiosize > f10) {
                    audiosize = f10;
                } else if (mode != .silk_only and audiosize > f5 and audiosize < f10) {
                    audiosize = f5;
                }
            }
        }

        var transition = false;
        if (data != null and d.prev_mode != .none and
            ((mode == .celt_only and d.prev_mode != .celt_only and !d.prev_redundancy) or
                (mode != .celt_only and d.prev_mode == .celt_only)))
        {
            transition = true;
        }
        const pcm_transition = &d.scratch.transition;
        if (transition and mode == .celt_only) {
            _ = try d.decodeFrame(null, pcm_transition, @min(f5, audiosize));
        }
        if (audiosize > frame_size) return error.BufferTooSmall;
        frame_size = audiosize;

        // SILK.
        const pcm_silk = &d.scratch.pcm_silk;
        if (mode != .celt_only) {
            if (d.prev_mode == .celt_only) d.silk.reset();
            d.silk_ctl.payload_size_ms = @max(10, 1000 * audiosize / 48000);
            if (data != null) {
                d.silk_ctl.channels_internal = d.stream_channels;
                d.silk_ctl.internal_sample_rate = if (mode == .silk_only) switch (bandwidth) {
                    .narrow => 8000,
                    .medium => 12000,
                    else => 16000,
                } else 16000;
            }
            const lost: silk.Lost = if (data == null) .lost else .normal;
            var decoded: u32 = 0;
            while (decoded < frame_size) {
                const out = pcm_silk[decoded * cc ..];
                const n = d.silk.decode(&d.silk_ctl, lost, decoded == 0, &dec, out) orelse blk: {
                    if (lost != .lost) return error.Internal;
                    // A concealment that fails is silence.
                    @memset(out[0 .. (frame_size - decoded) * cc], 0);
                    break :blk frame_size - decoded;
                };
                decoded += n;
            }
        }

        // A redundant CELT frame at the end of a SILK or hybrid one.
        var redundancy = false;
        var celt_to_silk = false;
        var redundancy_bytes: u32 = 0;
        if (mode != .celt_only and data != null and
            dec.tell() + 17 + 20 * @as(i32, @intFromBool(mode == .hybrid)) <= 8 * @as(i32, @intCast(len)))
        {
            redundancy = if (mode == .hybrid) dec.bitLogp(12) else true;
            if (redundancy) {
                celt_to_silk = dec.bitLogp(1);
                // At least two bytes: the check above saw to it.
                redundancy_bytes = if (mode == .hybrid)
                    dec.uint(256) + 2
                else
                    len - @as(u32, @intCast((dec.tell() + 7) >> 3));
                if (redundancy_bytes > len or @as(i32, @intCast((len - redundancy_bytes) * 8)) < dec.tell()) {
                    len = 0;
                    redundancy_bytes = 0;
                    redundancy = false;
                } else {
                    len -= redundancy_bytes;
                }
                // Its bytes are not this frame's raw bits.
                dec.storage -%= redundancy_bytes;
            }
        }
        const start_band: u32 = if (mode != .celt_only) 17 else 0;
        if (redundancy) transition = false;
        if (transition and mode != .celt_only) {
            _ = try d.decodeFrame(null, pcm_transition, @min(f5, audiosize));
        }

        if (bandwidth != .none) {
            d.celt.end = switch (bandwidth) {
                .narrow => 13,
                .medium, .wide => 17,
                .superwide => 19,
                else => 21,
            };
        }
        d.celt.stream_channels = d.stream_channels;

        const bytes = data orelse &[_]u8{};
        var redundant_rng: u32 = 0;
        const redundant = &d.scratch.redundant;
        if (redundancy and celt_to_silk) {
            // Decoded even when the CELT state is stale (the frame before
            // was not CELT), for the final range.
            d.celt.start = 0;
            _ = celt.decode(&d.celt, bytes[len..][0..redundancy_bytes], redundant, f5, null);
            redundant_rng = d.celt.rng;
        }
        d.celt.start = start_band;

        var celt_ok = true;
        if (mode != .silk_only) {
            const celt_frame_size = @min(f20, frame_size);
            // No state carried over from a frame of another mode.
            if (mode != d.prev_mode and d.prev_mode != .none and !d.prev_redundancy) celt.reset(&d.celt);
            celt_ok = celt.decode(&d.celt, if (data != null) bytes[0..len] else null, pcm.ptr, celt_frame_size, if (data != null) &dec else null);
        } else {
            @memset(pcm[0 .. frame_size * cc], 0);
            // From hybrid to SILK the MDCT fades out by a silent frame.
            if (d.prev_mode == .hybrid and !(redundancy and celt_to_silk and d.prev_redundancy)) {
                d.celt.start = 0;
                const silence = [2]u8{ 0xFF, 0xFF };
                _ = celt.decode(&d.celt, &silence, pcm.ptr, f2_5, null);
            }
        }

        if (mode != .celt_only) {
            for (0..frame_size * cc) |i| pcm[i] += (1.0 / 32768.0) * @as(f32, @floatFromInt(pcm_silk[i]));
        }

        if (redundancy and !celt_to_silk) {
            // SILK to CELT: the redundant frame fades in over the last
            // 2.5 ms.
            celt.reset(&d.celt);
            d.celt.start = 0;
            _ = celt.decode(&d.celt, bytes[len..][0..redundancy_bytes], redundant, f5, null);
            redundant_rng = d.celt.rng;
            const at = cc * (frame_size - f2_5);
            smoothFade(pcm[at..], redundant[cc * f2_5 ..], pcm[at..], cc);
        }
        // CELT to SILK: the redundant frame's first half, then a fade -
        // unless the frame before was not CELT.
        if (redundancy and celt_to_silk and (d.prev_mode != .silk_only or d.prev_redundancy)) {
            @memcpy(pcm[0 .. cc * f2_5], redundant[0 .. cc * f2_5]);
            smoothFade(redundant[cc * f2_5 ..], pcm[cc * f2_5 ..], pcm[cc * f2_5 ..], cc);
        }
        if (transition) {
            if (audiosize >= f5) {
                @memcpy(pcm[0 .. cc * f2_5], pcm_transition[0 .. cc * f2_5]);
                smoothFade(pcm_transition[cc * f2_5 ..], pcm[cc * f2_5 ..], pcm[cc * f2_5 ..], cc);
            } else {
                // Too short for a clean change; the best there is.
                smoothFade(pcm_transition, pcm, pcm, cc);
            }
        }

        if (d.decode_gain != 0) {
            const gain = @exp2(6.48814081e-4 * @as(f32, @floatFromInt(d.decode_gain)));
            for (pcm[0 .. frame_size * cc]) |*s| s.* *= gain;
        }

        d.range_final = if (len <= 1) 0 else dec.rng ^ redundant_rng;
        d.prev_mode = mode;
        d.prev_redundancy = redundancy and !celt_to_silk;
        if (!celt_ok) return error.Internal;
        return audiosize;
    }

    /// The packet's frames to `pcm` (room for `frame_size` samples a
    /// channel); the samples a channel. `soft_clip` bends the peaks.
    pub fn decode(d: *Decoder, data: []const u8, pcm: []f32, frame_size: u32, self_delimited: bool, soft_clip: bool) Error!struct { samples: u32, packet_len: u32 } {
        const f = try parsePacket(data, self_delimited);
        const per_frame = packetSamplesPerFrame(f.toc);
        if (f.count * per_frame > frame_size) return error.BufferTooSmall;
        d.mode = packetMode(f.toc);
        d.bandwidth = packetBandwidth(f.toc);
        d.frame_size = per_frame;
        d.stream_channels = packetChannels(f.toc);

        var at: usize = f.offset;
        var samples: u32 = 0;
        for (f.size[0..f.count]) |size| {
            samples += try d.decodeFrame(data[at..][0..size], pcm[samples * d.channels ..], frame_size - samples);
            at += size;
        }
        d.last_packet_duration = samples;
        d.finish(pcm, samples, soft_clip);
        return .{ .samples = samples, .packet_len = f.packet_len };
    }

    /// `frame_size` samples (a multiple of 2.5 ms) of concealment, for a
    /// packet lost.
    pub fn decodeLost(d: *Decoder, pcm: []f32, frame_size: u32, soft_clip: bool) Error!u32 {
        var count: u32 = 0;
        while (count < frame_size) count += try d.decodeFrame(null, pcm[count * d.channels ..], frame_size - count);
        d.last_packet_duration = count;
        d.finish(pcm, count, soft_clip);
        return count;
    }

    fn finish(d: *Decoder, pcm: []f32, samples: u32, soft_clip: bool) void {
        if (soft_clip) {
            softClip(pcm[0 .. samples * d.channels], d.channels, &d.softclip_mem);
        } else {
            d.softclip_mem = .{ 0, 0 };
        }
    }
};

/// 2.5 ms from `in1` to `in2`, by the CELT window squared.
fn smoothFade(in1: []const f32, in2: []const f32, out: []f32, channels: u32) void {
    for (0..channels) |c| {
        for (0..f2_5) |i| {
            const w = tables.window[i] * tables.window[i];
            const at = i * channels + c;
            out[at] = w * in2[at] + (1.0 - w) * in1[at];
        }
    }
}

/// Peaks beyond full scale bent below it: each stretch between zero
/// crossings around one scaled by x + a x^2, continuing into the next
/// call.
pub fn softClip(x: []f32, channels: u32, mem: *[2]f32) void {
    const n = x.len / channels;
    if (n == 0) return;
    for (x) |*s| s.* = @max(-2.0, @min(2.0, s.*));
    for (0..channels) |c| {
        var a = mem[c];
        // The last frame's curve finished first.
        for (0..n) |i| {
            const v = x[i * channels + c];
            if (v * a >= 0) break;
            x[i * channels + c] = v + a * v * v;
        }
        var curr: usize = 0;
        const x0 = x[c];
        while (true) {
            var i = curr;
            while (i < n) : (i += 1) {
                const v = x[i * channels + c];
                if (v > 1 or v < -1) break;
            }
            if (i == n) {
                a = 0;
                break;
            }
            var peak_pos = i;
            var start = i;
            var end = i;
            const xi = x[i * channels + c];
            var maxval = @abs(xi);
            while (start > 0 and xi * x[(start - 1) * channels + c] >= 0) start -= 1;
            while (end < n and xi * x[end * channels + c] >= 0) {
                if (@abs(x[end * channels + c]) > maxval) {
                    maxval = @abs(x[end * channels + c]);
                    peak_pos = end;
                }
                end += 1;
            }
            // Clipped before the first zero crossing.
            const special = start == 0 and xi * x[c] >= 0;
            a = (maxval - 1) / (maxval * maxval);
            a += a * 2.4e-7;
            if (xi > 0) a = -a;
            for (start..end) |k| {
                const v = x[k * channels + c];
                x[k * channels + c] = v + a * v * v;
            }
            if (special and peak_pos >= 2) {
                // A ramp from the first sample to the peak, so the frame
                // does not jump at its start.
                var offset = x0 - x[c];
                const delta = offset / @as(f32, @floatFromInt(peak_pos));
                for (curr..peak_pos) |k| {
                    offset -= delta;
                    const at = k * channels + c;
                    x[at] = @max(-1.0, @min(1.0, x[at] + offset));
                }
            }
            curr = end;
            if (curr == n) break;
        }
        mem[c] = a;
    }
}

/// A float sample to 16 bits, rounded to the nearest (ties to even).
pub inline fn toInt16(x: f32) i16 {
    const v = @max(-32768.0, @min(32767.0, x * 32768.0));
    // Adding 1.5 * 2^23 leaves no fraction bits: the FPU rounds.
    const r = (v + 12582912.0) - 12582912.0;
    return @intFromFloat(r);
}
