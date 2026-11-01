// SPDX-License-Identifier: MIT
//! A CELT frame's band energies (RFC 6716 4.3.2), in log2 units: the
//! coarse part in steps of 6 dB, predicted from the frame before and the
//! band below and coded with a Laplace-like model; the fine part in the
//! bits the allocation gives; and the bits left at the end, one more for
//! the bands that rounded down.

const tables = @import("celt_tables.zig");
const Range = @import("range.zig").Range;
const alloc = @import("celt_alloc.zig");

/// A value of the Laplace-like distribution: `fs` the probability of 0
/// in 1/32768, `decay` how fast the rest falls off, in Q14.
fn laplace(dec: *Range, fs_in: u32, decay: u32) i32 {
    var fs = fs_in;
    var val: i32 = 0;
    var fl: u32 = 0;
    const fm = dec.decodeBin(15);
    if (fm >= fs) {
        val += 1;
        fl = fs;
        fs = (((32768 - 2 * 16 - fs) * (16384 - decay)) >> 15) + 1;
        while (fs > 1 and fm >= fl + 2 * fs) {
            fs *= 2;
            fl += fs;
            fs = ((fs - 2) * decay) >> 15;
            fs += 1;
            val += 1;
        }
        // Past that every value has the least probability.
        if (fs <= 1) {
            const di = (fm - fl) >> 1;
            val += @intCast(di);
            fl += 2 * di;
        }
        if (fm < fl + fs) {
            val = -val;
        } else {
            fl += fs;
        }
    }
    dec.update(fl, @min(fl + fs, 32768), 32768);
    return val;
}

/// The coarse energies of bands start to end into `old` (the frame
/// before's, which they are predicted from).
pub fn coarse(start: u32, end: u32, old: *[2 * tables.bands]f32, intra: bool, dec: *Range, channels: u32, lm: u32) void {
    const model = &tables.e_prob_model[lm][@intFromBool(intra)];
    var prev = [2]f32{ 0, 0 };
    const coef: f32 = if (intra) 0 else tables.pred_coef[lm];
    const beta: f32 = if (intra) tables.beta_intra else tables.beta_coef[lm];
    const budget: i32 = @intCast(dec.storage * 8);
    for (start..end) |i| {
        for (0..channels) |c| {
            const tell = dec.tell();
            var qi: i32 = undefined;
            if (budget - tell >= 15) {
                const pi = 2 * @as(usize, @min(i, 20));
                qi = laplace(dec, @as(u32, model[pi]) << 7, @as(u32, model[pi + 1]) << 6);
            } else if (budget - tell >= 2) {
                const v: i32 = @intCast(dec.icdf(&tables.small_energy_icdf, 2));
                qi = (v >> 1) ^ -(v & 1);
            } else if (budget - tell >= 1) {
                qi = -@as(i32, @intFromBool(dec.bitLogp(1)));
            } else {
                qi = -1;
            }
            const q: f32 = @floatFromInt(qi);
            const at = i + c * tables.bands;
            old[at] = @max(-9.0, old[at]);
            const tmp = coef * old[at] + prev[c] + q;
            old[at] = tmp;
            prev[c] = prev[c] + q - beta * q;
        }
    }
}

/// The fine energies: `fine_quant[i]` raw bits a band and channel.
pub fn fine(start: u32, end: u32, old: *[2 * tables.bands]f32, fine_quant: *const [tables.bands]i32, dec: *Range, channels: u32) void {
    for (start..end) |i| {
        if (fine_quant[i] <= 0) continue;
        for (0..channels) |c| {
            const q2 = dec.bits(@intCast(fine_quant[i]));
            const offset = (@as(f32, @floatFromInt(q2)) + 0.5) * @as(f32, @floatFromInt(@as(u32, 1) << @intCast(14 - fine_quant[i]))) * (1.0 / 16384.0) - 0.5;
            old[i + c * tables.bands] += offset;
        }
    }
}

/// The bits left after the shapes: one more fine bit for each band and
/// channel that has room, those that rounded down first.
pub fn finalise(start: u32, end: u32, old: *[2 * tables.bands]f32, fine_quant: *const [tables.bands]i32, fine_priority: *const [tables.bands]i32, bits_left_in: i32, dec: *Range, channels: u32) void {
    var bits_left = bits_left_in;
    const c_bits: i32 = @intCast(channels);
    for (0..2) |prio| {
        var i = start;
        while (i < end and bits_left >= c_bits) : (i += 1) {
            if (fine_quant[i] >= alloc.max_fine_bits or fine_priority[i] != prio) continue;
            for (0..channels) |c| {
                const q2 = dec.bits(1);
                const offset = (@as(f32, @floatFromInt(q2)) - 0.5) * @as(f32, @floatFromInt(@as(u32, 1) << @intCast(14 - fine_quant[i] - 1))) * (1.0 / 16384.0);
                old[i + c * tables.bands] += offset;
                bits_left -= 1;
            }
        }
    }
}
