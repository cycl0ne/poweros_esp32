// SPDX-License-Identifier: MIT
//! A dispatch, which every driver does the same: a compute function runs on
//! the cores whichever device draws, its groups shared between them.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const shader = facet.shader;
const ExecBase = sdk.interface.exec.ExecBase;
const _command = @import("../command/_command.zig");
const _buffer = @import("../buffer/_buffer.zig");
const Pipeline = @import("../pipeline/_pipeline.zig").Pipeline;
const _query = @import("../query/_query.zig");

/// The most parts a dispatch is cut into, whatever the cores.
const most_parts = 16;

const Job = struct {
    function: shader.ComputeFn,
    count: [3]u32,
    /// The invocations a group holds, as the pipeline's entry declared them:
    /// the function makes them itself, in the one call it gets.
    local: [3]u32,
    total: u64,
    resources: *const shader.Resources,
    /// What a group's invocations share: `shared_bytes` for each worker, one
    /// after the other. Null where the function shares nothing, or where the
    /// memory could not be found.
    shared: ?[*]u8 = null,
    shared_bytes: u32 = 0,
};

fn part(data: ?*anyopaque, number: u32, parts: u32) callconv(.c) void {
    const job: *const Job = @ptrCast(@alignCast(data.?));
    var at = job.total * number / parts;
    const end = job.total * (number + 1) / parts;
    // This worker's own shared memory: no other worker is in it, so a group
    // finds what the group before it on this worker left, and the first
    // finds it cleared.
    const shared = if (job.shared) |block| block + number * job.shared_bytes else null;
    while (at < end) : (at += 1) {
        const plane = @as(u64, job.count[0]) * job.count[1];
        const in_plane = at % plane;
        const groups = shader.Groups{
            .group = .{ @intCast(in_plane % job.count[0]), @intCast(in_plane / job.count[0]), @intCast(at / plane) },
            .count = job.count,
            .resources = job.resources,
            .shared = shared,
            .local = job.local,
            .shared_bytes = if (shared == null) 0 else job.shared_bytes,
        };
        job.function(&groups);
    }
}

/// The groups `count` says, of `pipeline`'s function; nothing if there is no
/// pipeline, or none along an axis. Back once all have run.
pub fn dispatch(sys: *ExecBase, pipeline: ?*const Pipeline, resources: *const shader.Resources, count: [3]u32, counters: *const _query.Counters) void {
    const made = pipeline orelse return;
    const function = made.compute orelse return;
    const total = @as(u64, count[0]) * count[1] * count[2];
    if (total == 0) return;
    const parts: u32 = @intCast(@min(total, most_parts));
    // A compute function is called once for each group, whatever a group
    // holds; what a statistics query counts is the invocations, which is the
    // groups times what each holds.
    const holds = @as(u64, made.local[0]) * made.local[1] * made.local[2];
    _query.add(counters.compute_invocations, total * holds);
    var job = Job{ .function = function, .count = count, .local = made.local, .total = total, .resources = resources };
    // The memory a group's invocations share: a block for each worker, given
    // back as the dispatch ends. Memory that could not be found leaves the
    // groups to run with none rather than not at all.
    if (made.shared > 0) {
        if (sys.AllocVec(@as(usize, made.shared) * parts, exec.MEMF_CLEAR)) |block| {
            job.shared = @ptrCast(block);
            job.shared_bytes = made.shared;
        }
    }
    defer if (job.shared) |block| sys.FreeVec(block);
    _ = sys.ShareWork(&part, &job, parts);
}

test "every dispatch the limits admit is one whose groups can be counted" {
    // The groups are counted in 64 bits, and each part's first and last
    // are that count times the parts it is cut into: the largest dispatch
    // `max_compute_work_group_count` admits has to leave that room. Until
    // 1.128 it was 2^32 - 1 on each axis, 2^96 groups.
    const most = @import("../instance/_instance.zig").limits.max_compute_work_group_count;
    const groups = @as(u128, most[0]) * most[1] * most[2];
    try std.testing.expect(groups * most_parts <= std.math.maxInt(u64));
}

/// A dispatch whose numbers are in a buffer: none where it ends before them.
pub fn dispatchIndirect(sys: *ExecBase, pipeline: ?*const Pipeline, resources: *const shader.Resources, command: *const _command.DispatchIndirect, counters: *const _query.Counters) void {
    const bytes = _buffer.bytes(command.buffer, command.offset, @sizeOf(facet.DispatchIndirectCommand)) orelse return;
    const given = std.mem.bytesToValue(facet.DispatchIndirectCommand, bytes);
    dispatch(sys, pipeline, resources, .{ given.x, given.y, given.z }, counters);
}
