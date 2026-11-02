// SPDX-License-Identifier: MIT
//! A dispatch, which every driver does the same: a compute function runs on
//! the cores whichever device draws, its groups shared between them.

const std = @import("std");
const sdk = @import("sdk");
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
    total: u64,
    resources: *const shader.Resources,
};

fn part(data: ?*anyopaque, number: u32, parts: u32) callconv(.c) void {
    const job: *const Job = @ptrCast(@alignCast(data.?));
    var at = job.total * number / parts;
    const end = job.total * (number + 1) / parts;
    while (at < end) : (at += 1) {
        const plane = @as(u64, job.count[0]) * job.count[1];
        const in_plane = at % plane;
        const groups = shader.Groups{
            .group = .{ @intCast(in_plane % job.count[0]), @intCast(in_plane / job.count[0]), @intCast(at / plane) },
            .count = job.count,
            .resources = job.resources,
        };
        job.function(&groups);
    }
}

/// The groups `count` says, of `pipeline`'s function; nothing if there is no
/// pipeline, or none along an axis. Back once all have run.
pub fn dispatch(sys: *ExecBase, pipeline: ?*const Pipeline, resources: *const shader.Resources, count: [3]u32, counters: *const _query.Counters) void {
    const function = (pipeline orelse return).compute orelse return;
    const total = @as(u64, count[0]) * count[1] * count[2];
    if (total == 0) return;
    // A compute function is called once for each group, so the calls a
    // statistics query counts are the groups.
    _query.add(counters.compute_invocations, total);
    var job = Job{ .function = function, .count = count, .total = total, .resources = resources };
    _ = sys.ShareWork(&part, &job, @intCast(@min(total, most_parts)));
}

/// A dispatch whose numbers are in a buffer: none where it ends before them.
pub fn dispatchIndirect(sys: *ExecBase, pipeline: ?*const Pipeline, resources: *const shader.Resources, command: *const _command.DispatchIndirect, counters: *const _query.Counters) void {
    const bytes = _buffer.bytes(command.buffer, command.offset, @sizeOf(facet.DispatchIndirectCommand)) orelse return;
    const given = std.mem.bytesToValue(facet.DispatchIndirectCommand, bytes);
    dispatch(sys, pipeline, resources, .{ given.x, given.y, given.z }, counters);
}
