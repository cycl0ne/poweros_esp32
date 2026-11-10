// SPDX-License-Identifier: MIT
//! A dispatch's configuration as the compute shader dispatcher reads it:
//! v3dv's cmd_buffer_create_csd_job (v3dv_cmd_buffer.c:4344-4461) of a
//! compute program, its workgroups packed into supergroups as
//! v3d_csd_choose_workgroups_per_supergroup packs them (v3d_util.c:32-99).
//! The engine writes the words (`Engine.dispatch`; since 1.195).

const std = @import("std");

/// The bit fields of the words, Mesa's (v3d_csd.h:27-41).
pub const wg_count_shift = 16;
pub const batches_per_sg_m1_shift = 12;
pub const wgs_per_sg_shift = 8;
pub const wg_size_shift = 0;
pub const propagate_nans: u32 = 1 << 2;
pub const single_seg: u32 = 1 << 1;
pub const threading: u32 = 1 << 0;

/// The most invocations a group of the CSD's holds: V3D_MAX_CSD_WG_SIZE
/// (v3d_limits.h:82).
pub const most_invocations: u32 = 256;

/// What a dispatch is made of: the program's, and the dispatch's count of
/// workgroups.
pub const Dispatch = struct {
    count: [3]u32,
    local_size: [3]u16,
    can_use_supergroups: bool,
    threads: u8,
    single_seg: bool,
    /// The program's address and its uniforms'.
    program: u32,
    uniforms: u32,
    /// The V3D's version as Mesa's devinfo->ver has it, ten times the
    /// major and the minor (v3d_device_info.c:65-68; 71 for a BCM2712's),
    /// and HUB_IDENT3's IP revision, devinfo->rev (:106): from 7.1.6 the
    /// count of batches is written as it is, before it less one.
    version: u32,
    revision: u32,
    /// The program waits at a barrier (prog_data's has_control_barrier),
    /// and the QPUs, devinfo's qpu_count: a supergroup of a TSY barrier
    /// takes no more than half their threads (since 1.203).
    has_tsy_barrier: bool = false,
    qpus: u32 = 0,
};

/// The workgroups a supergroup holds, of at most 16, the one that leaves
/// the fewest of a batch's 16 lanes unused: v3d_csd_choose_workgroups_
/// per_supergroup (v3d_util.c:32-99). A program that waits at a TSY
/// barrier stalls its QPU threads until the whole supergroup has come to
/// it, so its supergroup holds no more batches than half the QPUs'
/// threads, that two at least run at once (:56-67; since 1.203).
pub fn workgroupsPerSupergroup(can_use_supergroups: bool, has_tsy_barrier: bool, qpus: u32, threads: u32, num_wgs: u64, wg_size: u32) u32 {
    if (!can_use_supergroups) return 1;
    // A workgroup of a multiple of 16 fills its batches already.
    if (wg_size % 16 == 0) return 1;
    // 16 workgroups at most, each of wg_size lanes, 16 to a batch.
    var max_batches_per_sg: u32 = wg_size;
    var max_wgs_per_sg: u32 = 16;
    if (has_tsy_barrier) {
        const max_qpu_threads = qpus * threads;
        max_batches_per_sg = @min(max_batches_per_sg, max_qpu_threads / 2);
        max_wgs_per_sg = max_batches_per_sg * 16 / wg_size;
    }
    var best: u32 = 1;
    var best_unused: u32 = 16;
    var wgs_per_sg: u32 = 1;
    while (wgs_per_sg <= max_wgs_per_sg) : (wgs_per_sg += 1) {
        // No more than the dispatch has.
        if (wgs_per_sg > num_wgs) return best;
        const unused = (16 - ((wgs_per_sg * wg_size) % 16)) & 0x0f;
        if (unused == 0) return wgs_per_sg;
        if (unused < best_unused) {
            best = wgs_per_sg;
            best_unused = unused;
        }
    }
    return best;
}

/// The seven words of the dispatch, CFG0 to CFG6, or null where it has no
/// workgroup along an axis (cmd_buffer_dispatch, v3dv_cmd_buffer.c:4472;
/// v3d_csd_job_run, v3d_sched.c:340-349), or more batches than a word
/// counts, or a group of more invocations than the CSD takes, 256
/// (since 1.195). The base workgroup is the uniforms' (QUNIFORM_WORK_GROUP_BASE),
/// so the offsets of CFG0 to CFG2 are 0, as v3dv leaves them.
pub fn configuration(dispatch: Dispatch) ?[7]u32 {
    const count = dispatch.count;
    if (count[0] == 0 or count[1] == 0 or count[2] == 0) return null;
    if (count[0] > 0xffff or count[1] > 0xffff or count[2] > 0xffff) return null;
    const num_wgs = @as(u64, count[0]) * count[1] * count[2];
    const size = dispatch.local_size;
    const wg_size = @as(u32, size[0]) * size[1] * size[2];
    // CFG3 holds a group's size in 8 bits, 0 for 256: V3D_MAX_CSD_WG_SIZE
    // (v3d_limits.h:82), v3dv's maxComputeWorkGroupInvocations
    // (v3dv_device.c:1146).
    if (wg_size == 0 or wg_size > most_invocations) return null;
    const wgs_per_sg = workgroupsPerSupergroup(dispatch.can_use_supergroups, dispatch.has_tsy_barrier, dispatch.qpus, dispatch.threads, num_wgs, wg_size);
    const batches_per_sg = std.math.divCeil(u32, wgs_per_sg * wg_size, 16) catch unreachable;
    const whole_sgs = num_wgs / wgs_per_sg;
    const rem_wgs = num_wgs - whole_sgs * wgs_per_sg;
    const num_batches = batches_per_sg * whole_sgs + (std.math.divCeil(u64, rem_wgs * wg_size, 16) catch unreachable);
    // V3D 7.1.6 and later count the batches as they are, before it one
    // less (v3dv_cmd_buffer.c:4413-4419).
    const older = dispatch.version < 71 or (dispatch.version == 71 and dispatch.revision < 6);
    const written = if (older) num_batches - 1 else num_batches;
    const batches = std.math.cast(u32, written) orelse return null;
    if (batches == std.math.maxInt(u32)) return null;
    var program = dispatch.program;
    if (dispatch.single_seg) program |= single_seg;
    if (dispatch.threads == 4) program |= threading;
    // A bit 7.1 has made reserved (v3dv_cmd_buffer.c:4430-4432).
    if (dispatch.version < 71) program |= propagate_nans;
    return .{
        count[0] << wg_count_shift,
        count[1] << wg_count_shift,
        count[2] << wg_count_shift,
        (wgs_per_sg & 0xf) << wgs_per_sg_shift | (batches_per_sg - 1) << batches_per_sg_m1_shift | (wg_size & 0xff) << wg_size_shift,
        batches,
        program,
        dispatch.uniforms,
    };
}

const testing = std.testing;

test "a workgroup of a multiple of 16 invocations is a supergroup alone, as is one of a program that may not share" {
    try testing.expectEqual(@as(u32, 1), workgroupsPerSupergroup(true, false, 0, 4, 100, 16));
    try testing.expectEqual(@as(u32, 1), workgroupsPerSupergroup(true, false, 0, 4, 100, 256));
    try testing.expectEqual(@as(u32, 1), workgroupsPerSupergroup(false, false, 0, 4, 100, 3));
}

test "smaller workgroups are packed until a batch's 16 lanes are full, or the fewest are left unused, and no more than the dispatch has" {
    // 4 of 4 fill 16 lanes; 2 of 8; 16 of 1.
    try testing.expectEqual(@as(u32, 4), workgroupsPerSupergroup(true, false, 0, 4, 100, 4));
    try testing.expectEqual(@as(u32, 2), workgroupsPerSupergroup(true, false, 0, 4, 100, 8));
    try testing.expectEqual(@as(u32, 16), workgroupsPerSupergroup(true, false, 0, 4, 100, 1));
    // 3 invocations: 16 of them fill three batches. Of a dispatch of 12,
    // 5, of 15 lanes, leave the fewest unused; of 3, 3 at most.
    try testing.expectEqual(@as(u32, 16), workgroupsPerSupergroup(true, false, 0, 4, 100, 3));
    try testing.expectEqual(@as(u32, 5), workgroupsPerSupergroup(true, false, 0, 4, 12, 3));
    try testing.expectEqual(@as(u32, 3), workgroupsPerSupergroup(true, false, 0, 4, 3, 3));
    // 24 invocations: 2 of them fill three batches.
    try testing.expectEqual(@as(u32, 2), workgroupsPerSupergroup(true, false, 0, 4, 100, 24));
}

test "a program that waits at a TSY barrier: its supergroup of no more batches than half the QPUs' threads, the rest as before" {
    // 3 invocations on 2 QPUs of 2 threads: 2 batches, 10 workgroups at
    // most, of which 5 leave 1 lane unused, where 16 would fill three.
    try testing.expectEqual(@as(u32, 5), workgroupsPerSupergroup(true, true, 2, 2, 100, 3));
    try testing.expectEqual(@as(u32, 16), workgroupsPerSupergroup(true, false, 2, 2, 100, 3));
    // 8 QPUs of 4 threads leave the 3 batches 16 workgroups take.
    try testing.expectEqual(@as(u32, 16), workgroupsPerSupergroup(true, true, 8, 4, 100, 3));
    // 24 invocations on 1 QPU of 2 threads: one batch, no workgroup more
    // than the first, where 2 would fill three.
    try testing.expectEqual(@as(u32, 1), workgroupsPerSupergroup(true, true, 1, 2, 100, 24));
    try testing.expectEqual(@as(u32, 2), workgroupsPerSupergroup(true, false, 1, 2, 100, 24));
    // A program that may not share, or of a multiple of 16, alone still.
    try testing.expectEqual(@as(u32, 1), workgroupsPerSupergroup(false, true, 8, 4, 100, 3));
    try testing.expectEqual(@as(u32, 1), workgroupsPerSupergroup(true, true, 8, 4, 100, 32));
}

test "a dispatch's words: the counts in the top halves of the first three, the supergroups and batches, the program's address with its bits, and its uniforms'" {
    const base = Dispatch{ .count = .{ 3, 2, 1 }, .local_size = .{ 16, 1, 1 }, .can_use_supergroups = true, .threads = 4, .single_seg = false, .program = 0x1000_0000, .uniforms = 0x2000_0040, .version = 71, .revision = 7 };
    const words = configuration(base).?;
    try testing.expectEqual(@as(u32, 3 << 16), words[0]);
    try testing.expectEqual(@as(u32, 2 << 16), words[1]);
    try testing.expectEqual(@as(u32, 1 << 16), words[2]);
    // One workgroup a supergroup, one batch each, 16 invocations.
    try testing.expectEqual(@as(u32, 1 << 8 | 0 << 12 | 16), words[3]);
    // Six workgroups, a batch each, counted as they are on 7.1.7.
    try testing.expectEqual(@as(u32, 6), words[4]);
    try testing.expectEqual(@as(u32, 0x1000_0000 | threading), words[5]);
    try testing.expectEqual(@as(u32, 0x2000_0040), words[6]);
    // Before 7.1.6 one less; two threads not THREADING; a program that
    // never switches threads in one segment.
    var older = base;
    older.revision = 5;
    older.threads = 2;
    older.single_seg = true;
    const old = configuration(older).?;
    try testing.expectEqual(@as(u32, 5), old[4]);
    try testing.expectEqual(@as(u32, 0x1000_0000 | single_seg), old[5]);
    // A V3D before 7.1 at whatever revision, as a Pi 4's 4.2, which
    // propagates NaNs too.
    var four = base;
    four.version = 42;
    const pi4 = configuration(four).?;
    try testing.expectEqual(@as(u32, 5), pi4[4]);
    try testing.expectEqual(@as(u32, 0x1000_0000 | threading | propagate_nans), pi4[5]);
}

test "workgroups of 3 invocations, 5 to a supergroup of one batch: the last supergroup of what is left, and 256 invocations a size of 0" {
    var dispatch = Dispatch{ .count = .{ 12, 1, 1 }, .local_size = .{ 3, 1, 1 }, .can_use_supergroups = true, .threads = 4, .single_seg = false, .program = 0, .uniforms = 0, .version = 71, .revision = 7 };
    const words = configuration(dispatch).?;
    // 5 a supergroup, 15 lanes: one batch each.
    try testing.expectEqual(@as(u32, 5 << 8 | 0 << 12 | 3), words[3]);
    // Two whole supergroups and 2 workgroups left, 6 lanes: 3 batches.
    try testing.expectEqual(@as(u32, 3), words[4]);
    // 16 workgroups a supergroup are written 0.
    dispatch.local_size = .{ 1, 1, 1 };
    dispatch.count = .{ 32, 1, 1 };
    const ones = configuration(dispatch).?;
    try testing.expectEqual(@as(u32, 0 << 8 | 0 << 12 | 1), ones[3]);
    try testing.expectEqual(@as(u32, 2), ones[4]);
    // 256 invocations: 16 batches, the size 0.
    dispatch.local_size = .{ 16, 16, 1 };
    dispatch.count = .{ 2, 1, 1 };
    const most = configuration(dispatch).?;
    try testing.expectEqual(@as(u32, 1 << 8 | 15 << 12 | 0), most[3]);
    try testing.expectEqual(@as(u32, 32), most[4]);
}

test "no workgroup along an axis is no dispatch, nor is a count the 16 bits do not hold, nor a group of no invocation or of more than 256" {
    var dispatch = Dispatch{ .count = .{ 0, 1, 1 }, .local_size = .{ 1, 1, 1 }, .can_use_supergroups = true, .threads = 4, .single_seg = false, .program = 0, .uniforms = 0, .version = 71, .revision = 7 };
    try testing.expectEqual(@as(?[7]u32, null), configuration(dispatch));
    dispatch.count = .{ 1, 1, 0 };
    try testing.expectEqual(@as(?[7]u32, null), configuration(dispatch));
    dispatch.count = .{ 65536, 1, 1 };
    try testing.expectEqual(@as(?[7]u32, null), configuration(dispatch));
    dispatch.count = .{ 65535, 1, 1 };
    try testing.expect(configuration(dispatch) != null);
    dispatch.local_size = .{ 16, 16, 2 };
    try testing.expectEqual(@as(?[7]u32, null), configuration(dispatch));
    dispatch.local_size = .{ 0, 1, 1 };
    try testing.expectEqual(@as(?[7]u32, null), configuration(dispatch));
    dispatch.local_size = .{ 16, 16, 1 };
    try testing.expect(configuration(dispatch) != null);
}
