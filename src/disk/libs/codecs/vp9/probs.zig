// SPDX-License-Identifier: MIT
//! The probabilities a frame reads its blocks with, which the next frames
//! keep in four saved sets, and how often each value was read, which
//! adapts them once a frame is done (8.4).

const tables = @import("tables.zig");

pub const Probs = struct {
    tx8: [2][1]u8,
    tx16: [2][2]u8,
    tx32: [2][3]u8,
    coef: [4][2][2][6][6][3]u8,
    skip: [3]u8,
    inter_mode: [7][3]u8,
    interp_filter: [4][2]u8,
    is_inter: [4]u8,
    comp_mode: [5]u8,
    single_ref: [5][2]u8,
    comp_ref: [5]u8,
    y_mode: [4][9]u8,
    uv_mode: [10][9]u8,
    partition: [16][3]u8,
    mv_joint: [3]u8,
    mv_sign: [2]u8,
    mv_class: [2][10]u8,
    mv_class0_bit: [2]u8,
    mv_bits: [2][10]u8,
    mv_class0_fr: [2][2][3]u8,
    mv_fr: [2][3]u8,
    mv_class0_hp: [2]u8,
    mv_hp: [2]u8,

    /// The probabilities after a reset (10.5).
    pub const defaults: Probs = .{
        .tx8 = .{ .{tables.default_tx_probs[1][0][0]}, .{tables.default_tx_probs[1][1][0]} },
        .tx16 = .{ tables.default_tx_probs[2][0][0..2].*, tables.default_tx_probs[2][1][0..2].* },
        .tx32 = tables.default_tx_probs[3],
        .coef = tables.default_coef_probs,
        .skip = tables.default_skip_prob,
        .inter_mode = tables.default_inter_mode_probs,
        .interp_filter = tables.default_interp_filter_probs,
        .is_inter = tables.default_is_inter_prob,
        .comp_mode = tables.default_comp_mode_prob,
        .single_ref = tables.default_single_ref_prob,
        .comp_ref = tables.default_comp_ref_prob,
        .y_mode = tables.default_y_mode_probs,
        .uv_mode = tables.default_uv_mode_probs,
        .partition = tables.default_partition_probs,
        .mv_joint = tables.default_mv_joint_probs,
        .mv_sign = tables.default_mv_sign_prob,
        .mv_class = tables.default_mv_class_probs,
        .mv_class0_bit = tables.default_mv_class0_bit_prob,
        .mv_bits = tables.default_mv_bits_prob,
        .mv_class0_fr = tables.default_mv_class0_fr_probs,
        .mv_fr = tables.default_mv_fr_probs,
        .mv_class0_hp = tables.default_mv_class0_hp_prob,
        .mv_hp = tables.default_mv_hp_prob,
    };
};

/// How often each value of each element was read in each context (8.3).
pub const Counts = struct {
    intra_mode: [4][10]u32,
    uv_mode: [10][10]u32,
    partition: [16][4]u32,
    interp_filter: [4][3]u32,
    inter_mode: [7][4]u32,
    tx8: [2][2]u32,
    tx16: [2][3]u32,
    tx32: [2][4]u32,
    is_inter: [4][2]u32,
    comp_mode: [5][2]u32,
    single_ref: [5][2][2]u32,
    comp_ref: [5][2]u32,
    skip: [3][2]u32,
    mv_joint: [4]u32,
    mv_sign: [2][2]u32,
    mv_class: [2][11]u32,
    mv_class0_bit: [2][2]u32,
    mv_class0_fr: [2][2][4]u32,
    mv_class0_hp: [2][2]u32,
    mv_bits: [2][10][2]u32,
    mv_fr: [2][4]u32,
    mv_hp: [2][2]u32,
    /// Tokens as zero, one, more; and whether more came.
    token: [4][2][2][6][6][3]u32,
    more_coefs: [4][2][2][6][6][2]u32,

    pub fn clear(c: *Counts) void {
        const bytes: [*]u8 = @ptrCast(c);
        @memset(bytes[0..@sizeOf(Counts)], 0);
    }
};

const count_sat = 20;
const max_update_factor = 128;

/// `pre` moved towards the probability the counts show (8.4.1).
fn mergeProb(pre: u8, ct0: u32, ct1: u32, sat: u32, max_update: u32) u8 {
    const den: u64 = @as(u64, ct0) + ct1;
    const prob: u64 = if (den == 0) 128 else @max(1, @min(255, (@as(u64, ct0) * 256 + (den >> 1)) / den));
    const count: u64 = @min(den, sat);
    const factor = max_update * count / sat;
    return @intCast((@as(u64, pre) * (256 - factor) + prob * factor + 128) >> 8);
}

/// The probabilities of a tree's nodes from node `i` down; how often the
/// node was passed (8.4.2).
fn mergeProbs(tree: tables.Tree, i: usize, probs: []u8, counts: []const u32, sat: u32, max_update: u32) u32 {
    const s = tree[i];
    const left = if (s <= 0) counts[@intCast(-s)] else mergeProbs(tree, @intCast(s), probs, counts, sat, max_update);
    const r = tree[i + 1];
    const right = if (r <= 0) counts[@intCast(-r)] else mergeProbs(tree, @intCast(r), probs, counts, sat, max_update);
    probs[i >> 1] = mergeProb(probs[i >> 1], left, right, sat, max_update);
    return left + right;
}

fn adaptProbs(tree: tables.Tree, probs: []u8, counts: []const u32) void {
    _ = mergeProbs(tree, 0, probs, counts, count_sat, max_update_factor);
}

fn adaptProb(prob: *u8, counts: [2]u32) void {
    prob.* = mergeProb(prob.*, counts[0], counts[1], count_sat, max_update_factor);
}

/// The coefficient probabilities adapted (8.4.3): `p` holds the ones the
/// frame started from.
pub fn adaptCoef(p: *Probs, c: *const Counts, intra: bool, last_was_key: bool) void {
    const update: u32 = if (intra) 112 else if (last_was_key) 128 else 112;
    for (&p.coef, &c.token, &c.more_coefs) |*pt, *ct, *cm| {
        for (pt, ct, cm) |*pi, *ci, *mi| {
            for (pi, ci, mi) |*pj, *cj, *mj| {
                for (pj, cj, mj, 0..) |*pk, *ck, *mk, k| {
                    const contexts: usize = if (k == 0) 3 else 6;
                    for (pk[0..contexts], ck[0..contexts], mk[0..contexts]) |*pl, n, m| {
                        pl[2] = mergeProb(pl[2], n[1], n[2], 24, update);
                        pl[1] = mergeProb(pl[1], n[0], n[1] + n[2], 24, update);
                        pl[0] = mergeProb(pl[0], m[0], m[1], 24, update);
                    }
                }
            }
        }
    }
}

/// The other probabilities adapted (8.4.4).
pub fn adaptNoncoef(p: *Probs, c: *const Counts, switchable: bool, tx_select: bool, allow_hp: bool) void {
    for (&p.is_inter, c.is_inter) |*q, n| adaptProb(q, n);
    for (&p.comp_mode, c.comp_mode) |*q, n| adaptProb(q, n);
    for (&p.comp_ref, c.comp_ref) |*q, n| adaptProb(q, n);
    for (&p.single_ref, c.single_ref) |*q, n| {
        adaptProb(&q[0], n[0]);
        adaptProb(&q[1], n[1]);
    }
    for (&p.inter_mode, &c.inter_mode) |*q, *n| adaptProbs(&tables.inter_mode_tree, q, n);
    for (&p.y_mode, &c.intra_mode) |*q, *n| adaptProbs(&tables.intra_mode_tree, q, n);
    for (&p.uv_mode, &c.uv_mode) |*q, *n| adaptProbs(&tables.intra_mode_tree, q, n);
    for (&p.partition, &c.partition) |*q, *n| adaptProbs(&tables.partition_tree, q, n);
    for (&p.skip, c.skip) |*q, n| adaptProb(q, n);
    if (switchable) {
        for (&p.interp_filter, &c.interp_filter) |*q, *n| adaptProbs(&tables.interp_filter_tree, q, n);
    }
    if (tx_select) {
        for (0..2) |i| {
            adaptProb(&p.tx8[i][0], c.tx8[i]);
            adaptProbs(&tables.tx_size_16_tree, &p.tx16[i], &c.tx16[i]);
            adaptProbs(&tables.tx_size_32_tree, &p.tx32[i], &c.tx32[i]);
        }
    }
    adaptProbs(&tables.mv_joint_tree, &p.mv_joint, &c.mv_joint);
    for (0..2) |i| {
        adaptProb(&p.mv_sign[i], c.mv_sign[i]);
        adaptProbs(&tables.mv_class_tree, &p.mv_class[i], &c.mv_class[i]);
        adaptProb(&p.mv_class0_bit[i], c.mv_class0_bit[i]);
        for (&p.mv_bits[i], c.mv_bits[i]) |*q, n| adaptProb(q, n);
        for (&p.mv_class0_fr[i], &c.mv_class0_fr[i]) |*q, *n| adaptProbs(&tables.mv_fr_tree, q, n);
        adaptProbs(&tables.mv_fr_tree, &p.mv_fr[i], &c.mv_fr[i]);
        if (allow_hp) {
            adaptProb(&p.mv_class0_hp[i], c.mv_class0_hp[i]);
            adaptProb(&p.mv_hp[i], c.mv_hp[i]);
        }
    }
}
