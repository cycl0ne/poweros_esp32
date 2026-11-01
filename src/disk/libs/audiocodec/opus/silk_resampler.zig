// SPDX-License-Identifier: MIT
//! SILK's output from 8, 12 or 16 kHz up to 48 kHz, as libopus resamples
//! it: 2x by two chains of all-pass sections, then a 12-phase FIR filter
//! picks the samples between. The input is delayed by a few samples so
//! that SILK and CELT line up.

const fix = @import("silk_fix.zig");
const tables = @import("silk_tables.zig");

const order_fir_12 = 8;
const batch_ms = 10;

pub const Resampler = struct {
    s_iir: [6]i32 = @splat(0),
    s_fir: [order_fir_12]i16 = @splat(0),
    delay_buf: [48]i16 = @splat(0),
    batch_size: u32 = 0,
    inv_ratio_q16: i32 = 0,
    fs_in_khz: u32 = 0,
    input_delay: u32 = 0,

    /// From `fs_in_khz` (8, 12 or 16) to 48 kHz, the state cleared.
    pub fn init(r: *Resampler, fs_in_khz: u32) void {
        r.* = .{};
        r.input_delay = switch (fs_in_khz) {
            8 => 0,
            12 => 4,
            else => 7,
        };
        r.fs_in_khz = fs_in_khz;
        r.batch_size = fs_in_khz * batch_ms;
        const fs_in: i32 = @intCast(fs_in_khz * 1000);
        r.inv_ratio_q16 = @divTrunc(fs_in << 15, 48000) << 2;
        while (fix.smulww(r.inv_ratio_q16, 48000) < fs_in << 1) r.inv_ratio_q16 += 1;
    }

    /// `in` (at least 1 ms) to `out`, 48 / fs_in times as long.
    pub fn process(r: *Resampler, out: []i16, in: []const i16) void {
        const n = r.fs_in_khz - r.input_delay;
        @memcpy(r.delay_buf[r.input_delay..][0..n], in[0..n]);
        r.iirFir(out, r.delay_buf[0..r.fs_in_khz]);
        r.iirFir(out[48..], in[n .. in.len - r.input_delay]);
        @memcpy(r.delay_buf[0..r.input_delay], in[in.len - r.input_delay ..]);
    }

    fn iirFir(r: *Resampler, out_in: []i16, in_all: []const i16) void {
        var buf: [2 * 16 * batch_ms + order_fir_12]i16 = undefined;
        buf[0..order_fir_12].* = r.s_fir;
        var out = out_in;
        var in = in_all;
        while (true) {
            const n = @min(in.len, r.batch_size);
            up2Hq(&r.s_iir, buf[order_fir_12..], in[0..n]);
            const max_index_q16: i32 = @intCast(n << 17);
            var index_q16: i32 = 0;
            var o: usize = 0;
            while (index_q16 < max_index_q16) : (index_q16 += r.inv_ratio_q16) {
                const t: usize = @intCast(fix.smulwb(index_q16 & 0xFFFF, 12));
                const b = buf[@intCast(index_q16 >> 16)..];
                const f0 = &tables.resampler_frac_fir_12[t];
                const f1 = &tables.resampler_frac_fir_12[11 - t];
                var res_q15: i32 = fix.smulbb(b[0], f0[0]);
                res_q15 = fix.smlabb(res_q15, b[1], f0[1]);
                res_q15 = fix.smlabb(res_q15, b[2], f0[2]);
                res_q15 = fix.smlabb(res_q15, b[3], f0[3]);
                res_q15 = fix.smlabb(res_q15, b[4], f1[3]);
                res_q15 = fix.smlabb(res_q15, b[5], f1[2]);
                res_q15 = fix.smlabb(res_q15, b[6], f1[1]);
                res_q15 = fix.smlabb(res_q15, b[7], f1[0]);
                out[o] = fix.sat16(fix.rshiftRound(res_q15, 15));
                o += 1;
            }
            out = out[o..];
            in = in[n..];
            if (in.len == 0) {
                r.s_fir = buf[n << 1 ..][0..order_fir_12].*;
                return;
            }
            const tail = buf[n << 1 ..][0..order_fir_12].*;
            buf[0..order_fir_12].* = tail;
        }
    }
};

/// 2x upsampling: each output phase a chain of three all-pass sections.
fn up2Hq(s: *[6]i32, out: []i16, in: []const i16) void {
    const c0 = &tables.resampler_up2_hq_0;
    const c1 = &tables.resampler_up2_hq_1;
    for (in, 0..) |x, k| {
        const in32 = @as(i32, x) << 10;
        out[2 * k] = fix.sat16(fix.rshiftRound(allpass3(s[0..3], c0, in32), 10));
        out[2 * k + 1] = fix.sat16(fix.rshiftRound(allpass3(s[3..6], c1, in32), 10));
    }
}

fn allpass3(s: *[3]i32, c: *const [3]i16, in32: i32) i32 {
    var y = in32 -% s[0];
    var x = fix.smulwb(y, c[0]);
    const out1 = s[0] +% x;
    s[0] = in32 +% x;
    y = out1 -% s[1];
    x = fix.smulwb(y, c[1]);
    const out2 = s[1] +% x;
    s[1] = out1 +% x;
    y = out2 -% s[2];
    x = fix.smlawb(y, y, c[2]);
    const out3 = s[2] +% x;
    s[2] = out2 +% x;
    return out3;
}
