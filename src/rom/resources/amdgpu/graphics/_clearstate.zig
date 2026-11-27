// SPDX-License-Identifier: MPL-2.0
//! The graphics pipe's clear state: the value each of its context
//! registers is cleared to, as the packets the RLC is given it in
//! (RLC_CSIB) - begun as clear state (PREAMBLE_CNTL), the context
//! control, the registers run by run (SET_CONTEXT_REG), the tile steering
//! override, ended as clear state, and CLEAR_STATE - as the vendor's
//! driver makes them for this block (gfx_v11_0_get_csb_buffer). The
//! values are the vendor's for it (gfx11_cs_data): 934 registers in 7 runs,
//! each 0 but the 78 `set` names, and the tile steering override 0, as
//! the vendor's driver has it on this block.

const amdgpu = @import("sdk").resources.amdgpu;

const PREAMBLE_CNTL: u32 = 0x4a;
const CONTEXT_CONTROL: u32 = 0x28;
const SET_CONTEXT_REG: u32 = 0x69;
const CLEAR_STATE: u32 = 0x12;
/// PREAMBLE_CNTL's begin and end of clear state.
const BEGIN_CLEAR_STATE: u32 = 2 << 28;
const END_CLEAR_STATE: u32 = 3 << 28;
/// CONTEXT_CONTROL's two words: the context's registers loaded and
/// shadowed as they are set.
const CONTEXT_CONTROL_ALL: u32 = 0x8000_0000;
/// The first context register, which SET_CONTEXT_REG counts from.
const context_first: u32 = 0xa000;
/// PA_SC_TILE_STEERING_OVERRIDE, a context register, and its value.
const PA_SC_TILE_STEERING_OVERRIDE: u32 = 0xa0d7;
const tile_steering_override: u32 = 0;

/// A run of context registers, from its first, each set in its own word.
const Run = struct { first: u32, count: u32 };
const runs = [_]Run{
    .{ .first = 0xa000, .count = 215 },
    .{ .first = 0xa0d8, .count = 272 },
    .{ .first = 0xa1f5, .count = 4 },
    .{ .first = 0xa1ff, .count = 158 },
    .{ .first = 0xa2a0, .count = 2 },
    .{ .first = 0xa2a3, .count = 1 },
    .{ .first = 0xa2a6, .count = 282 },
};

/// A register of the runs whose value is not 0.
const Set = struct { register: u32, value: u32 };
const set = [_]Set{
    .{ .register = 0xa00d, .value = 0x4000_4000 }, // PA_SC_SCREEN_SCISSOR_BR
    .{ .register = 0xa01f, .value = 0x0015_0055 }, // DB_RMI_L2_CACHE_CONTROL
    .{ .register = 0xa081, .value = 0x8000_0000 }, // PA_SC_WINDOW_SCISSOR_TL
    .{ .register = 0xa082, .value = 0x4000_4000 }, // PA_SC_WINDOW_SCISSOR_BR
    .{ .register = 0xa083, .value = 0x0000_ffff }, // PA_SC_CLIPRECT_RULE
    .{ .register = 0xa085, .value = 0x4000_4000 }, // PA_SC_CLIPRECT_0_BR
    .{ .register = 0xa087, .value = 0x4000_4000 }, // PA_SC_CLIPRECT_1_BR
    .{ .register = 0xa089, .value = 0x4000_4000 }, // PA_SC_CLIPRECT_2_BR
    .{ .register = 0xa08b, .value = 0x4000_4000 }, // PA_SC_CLIPRECT_3_BR
    .{ .register = 0xa08c, .value = 0xaa99_aaaa }, // PA_SC_EDGERULE
    .{ .register = 0xa08e, .value = 0xffff_ffff }, // CB_TARGET_MASK
    .{ .register = 0xa08f, .value = 0xffff_ffff }, // CB_SHADER_MASK
    .{ .register = 0xa090, .value = 0x8000_0000 }, // PA_SC_GENERIC_SCISSOR_TL
    .{ .register = 0xa091, .value = 0x4000_4000 }, // PA_SC_GENERIC_SCISSOR_BR
    .{ .register = 0xa094, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_0_TL
    .{ .register = 0xa095, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_0_BR
    .{ .register = 0xa096, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_1_TL
    .{ .register = 0xa097, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_1_BR
    .{ .register = 0xa098, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_2_TL
    .{ .register = 0xa099, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_2_BR
    .{ .register = 0xa09a, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_3_TL
    .{ .register = 0xa09b, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_3_BR
    .{ .register = 0xa09c, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_4_TL
    .{ .register = 0xa09d, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_4_BR
    .{ .register = 0xa09e, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_5_TL
    .{ .register = 0xa09f, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_5_BR
    .{ .register = 0xa0a0, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_6_TL
    .{ .register = 0xa0a1, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_6_BR
    .{ .register = 0xa0a2, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_7_TL
    .{ .register = 0xa0a3, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_7_BR
    .{ .register = 0xa0a4, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_8_TL
    .{ .register = 0xa0a5, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_8_BR
    .{ .register = 0xa0a6, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_9_TL
    .{ .register = 0xa0a7, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_9_BR
    .{ .register = 0xa0a8, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_10_TL
    .{ .register = 0xa0a9, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_10_BR
    .{ .register = 0xa0aa, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_11_TL
    .{ .register = 0xa0ab, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_11_BR
    .{ .register = 0xa0ac, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_12_TL
    .{ .register = 0xa0ad, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_12_BR
    .{ .register = 0xa0ae, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_13_TL
    .{ .register = 0xa0af, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_13_BR
    .{ .register = 0xa0b0, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_14_TL
    .{ .register = 0xa0b1, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_14_BR
    .{ .register = 0xa0b2, .value = 0x8000_0000 }, // PA_SC_VPORT_SCISSOR_15_TL
    .{ .register = 0xa0b3, .value = 0x4000_4000 }, // PA_SC_VPORT_SCISSOR_15_BR
    .{ .register = 0xa0b5, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_0
    .{ .register = 0xa0b7, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_1
    .{ .register = 0xa0b9, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_2
    .{ .register = 0xa0bb, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_3
    .{ .register = 0xa0bd, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_4
    .{ .register = 0xa0bf, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_5
    .{ .register = 0xa0c1, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_6
    .{ .register = 0xa0c3, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_7
    .{ .register = 0xa0c5, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_8
    .{ .register = 0xa0c7, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_9
    .{ .register = 0xa0c9, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_10
    .{ .register = 0xa0cb, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_11
    .{ .register = 0xa0cd, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_12
    .{ .register = 0xa0cf, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_13
    .{ .register = 0xa0d1, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_14
    .{ .register = 0xa0d3, .value = 0x3f80_0000 }, // PA_SC_VPORT_ZMAX_15
    .{ .register = 0xa104, .value = 0x0055_0055 }, // CB_RMI_GL2_CACHE_CONTROL
    .{ .register = 0xa10c, .value = 0x0100_0000 }, // DB_STENCILREFMASK
    .{ .register = 0xa10d, .value = 0x0100_0000 }, // DB_STENCILREFMASK_BF
    .{ .register = 0xa1b6, .value = 0x0000_0002 }, // SPI_PS_IN_CONTROL
    .{ .register = 0xa204, .value = 0x0009_0000 }, // PA_CL_CLIP_CNTL
    .{ .register = 0xa205, .value = 0x0000_0004 }, // PA_SU_SC_MODE_CNTL
    .{ .register = 0xa2f7, .value = 0x0000_1000 }, // PA_SC_LINE_CNTL
    .{ .register = 0xa2f9, .value = 0x0000_0005 }, // PA_SU_VTX_CNTL
    .{ .register = 0xa2fa, .value = 0x3f80_0000 }, // PA_CL_GB_VERT_CLIP_ADJ
    .{ .register = 0xa2fb, .value = 0x3f80_0000 }, // PA_CL_GB_VERT_DISC_ADJ
    .{ .register = 0xa2fc, .value = 0x3f80_0000 }, // PA_CL_GB_HORZ_CLIP_ADJ
    .{ .register = 0xa2fd, .value = 0x3f80_0000 }, // PA_CL_GB_HORZ_DISC_ADJ
    .{ .register = 0xa30e, .value = 0xffff_ffff }, // PA_SC_AA_MASK_X0Y0_X1Y0
    .{ .register = 0xa30f, .value = 0xffff_ffff }, // PA_SC_AA_MASK_X0Y1_X1Y1
    .{ .register = 0xa311, .value = 0x0000_0003 }, // PA_SC_BINNER_CNTL_0
    .{ .register = 0xa313, .value = 0x0010_0000 }, // PA_SC_CONSERVATIVE_RASTERIZATION_CNTL
};

/// The packets, as the RLC reads them: 960 words.
pub const words: [wordCount()]u32 = make();

fn wordCount() usize {
    var count: usize = 2 + 3 + 3 + 2 + 2;
    for (runs) |run| count += 2 + run.count;
    return count;
}

fn packet(op: u32, count: u32) u32 {
    return amdgpu.GPUPACKET | op << amdgpu.GPUPACKET_OP_SHIFT | count << amdgpu.GPUPACKET_COUNT_SHIFT;
}

fn make() [wordCount()]u32 {
    @setEvalBranchQuota(20_000);
    var made: [wordCount()]u32 = @splat(0);
    var at: usize = 0;
    const begin = [_]u32{
        packet(PREAMBLE_CNTL, 0),
        BEGIN_CLEAR_STATE,
        packet(CONTEXT_CONTROL, 1),
        CONTEXT_CONTROL_ALL,
        CONTEXT_CONTROL_ALL,
    };
    for (begin) |value| {
        made[at] = value;
        at += 1;
    }
    for (runs) |run| {
        made[at] = packet(SET_CONTEXT_REG, run.count);
        made[at + 1] = run.first - context_first;
        for (set) |one| {
            if (one.register >= run.first and one.register < run.first + run.count) made[at + 2 + one.register - run.first] = one.value;
        }
        at += 2 + run.count;
    }
    const end = [_]u32{
        packet(SET_CONTEXT_REG, 1),
        PA_SC_TILE_STEERING_OVERRIDE - context_first,
        tile_steering_override,
        packet(PREAMBLE_CNTL, 0),
        END_CLEAR_STATE,
        packet(CLEAR_STATE, 0),
        0,
    };
    for (end) |value| {
        made[at] = value;
        at += 1;
    }
    return made;
}

test "the clear state as the vendor's driver makes it for this block" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(usize, 960), words.len);
    try testing.expectEqual(@as(u32, 0xc000_4a00), words[0]);
    try testing.expectEqual(@as(u32, 0x2000_0000), words[1]);
    try testing.expectEqual(@as(u32, 0xc001_2800), words[2]);
    // The first run: its header, its offset, then PA_SC_SCREEN_SCISSOR_BR
    // the 14th of its registers.
    try testing.expectEqual(@as(u32, 0xc0d7_6900), words[5]);
    try testing.expectEqual(@as(u32, 0), words[6]);
    try testing.expectEqual(@as(u32, 0x4000_4000), words[7 + 0xd]);
    try testing.expectEqual(@as(u32, 0), words[7 + 0xc]);
    // The last register set in the last run, which ends seven words
    // before the end - PA_SC_CONSERVATIVE_RASTERIZATION_CNTL - then the
    // tile steering override and the end.
    try testing.expectEqual(@as(u32, 0x0010_0000), words[words.len - 7 - 282 + (0xa313 - 0xa2a6)]);
    try testing.expectEqual(@as(u32, 0xc001_6900), words[words.len - 7]);
    try testing.expectEqual(@as(u32, 0xd7), words[words.len - 6]);
    try testing.expectEqual(@as(u32, 0x3000_0000), words[words.len - 3]);
    try testing.expectEqual(@as(u32, 0xc000_1200), words[words.len - 2]);
    var nonzero: usize = 0;
    for (words) |value| nonzero += @intFromBool(value != 0);
    // Every set register, the twelve packets' headers, the runs' offsets
    // but the first, the context control's two words, the begin and the
    // end of clear state, and the steering override's offset.
    try testing.expectEqual(set.len + 12 + (runs.len - 1) + 2 + 2 + 1, nonzero);
}
