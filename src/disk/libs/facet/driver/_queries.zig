// SPDX-License-Identifier: MIT
//! The query commands as both drivers play them: a pool reset, a timestamp
//! written, and the values copied into a buffer. What a query counts is
//! added where the work is done - a draw's numbers in the driver that plays
//! it, the tiles' in the rasterizer - and this is the rest of it.
//!
//! `Counting` is what a player keeps between CmdBeginQuery and CmdEndQuery:
//! the query, and the counters inside it worked out once, so that a draw
//! adds to an address rather than looking anything up.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const _command = @import("../command/_command.zig");
const _buffer = @import("../buffer/_buffer.zig");
const _base = @import("../facet_base.zig");
const _query = @import("../query/_query.zig");
const Pool = _query.Pool;

/// The query a player is counting into.
pub const Counting = struct {
    pool: *Pool,
    index: u32,
    counters: _query.Counters,
};

/// The queries a player counts into at once: an occlusion query and a
/// statistics query, Vulkan having no two of one type active together
/// (VUID-vkCmdBeginQuery-queryPool-01922), and what a draw adds to taken
/// from both. llvmpipe keeps every query begun in a list and bins each
/// into every tile (`active_queries`, lp_setup.c:1475-1483, taken out at
/// 1564-1577); here the list is a place for each type that counts (since
/// 1.117).
pub const Active = struct {
    occlusion: ?Counting = null,
    statistics: ?Counting = null,
    /// Each counter from the query that has it: an occlusion query's
    /// samples and a statistics query's stages are never the same.
    counters: _query.Counters = .{},

    /// `command`'s query begun beside the other: nothing for a pool that
    /// has nothing to begin, or a query past its last.
    pub fn begin(active: *Active, command: *const _command.BeginQuery) void {
        const counting = begun(command) orelse return;
        if (counting.pool.kind == .occlusion) active.occlusion = counting else active.statistics = counting;
        active.gather();
    }

    /// Query `index` of `pool` no longer counted into, where it was.
    pub fn end(active: *Active, pool: *const Pool, index: u32) void {
        for ([2]*?Counting{ &active.occlusion, &active.statistics }) |place| {
            const counting = place.* orelse continue;
            if (counting.pool == pool and counting.index == index) place.* = null;
        }
        active.gather();
    }

    /// Every query of `pool` no longer counted into: a reset of one being
    /// counted into, which Vulkan does not allow (VUID-vkCmdResetQueryPool-None-02841).
    pub fn forget(active: *Active, pool: *const Pool) void {
        for ([2]*?Counting{ &active.occlusion, &active.statistics }) |place| {
            const counting = place.* orelse continue;
            if (counting.pool == pool) place.* = null;
        }
        active.gather();
    }

    fn gather(active: *Active) void {
        active.counters = .{};
        for ([2]?Counting{ active.occlusion, active.statistics }) |place| {
            const counting = place orelse continue;
            inline for (@typeInfo(_query.Counters).@"struct".fields) |field| {
                if (@field(counting.counters, field.name)) |counter| @field(active.counters, field.name) = counter;
            }
        }
    }
};

/// What `command` begins, or null for a pool that has nothing to begin - a
/// timestamp pool - or a query past its last, which the player then says in
/// the log.
pub fn begun(command: *const _command.BeginQuery) ?Counting {
    const pool = command.pool;
    if (pool.kind != .occlusion and pool.kind != .pipeline_statistics) return null;
    if (command.query >= pool.count) return null;
    return .{ .pool = pool, .index = command.query, .counters = .of(pool, command.query) };
}

/// The query of `command` made available, whatever was being counted into.
pub fn ended(command: *const _command.EndQuery) void {
    _query.finish(command.pool, command.query);
}

/// A timestamp written, the clock read here - 0 without timer.device, as
/// `_base.now` reads it, and available all the same (CmdWriteTimestamp):
/// false for a pool of another kind or a query past its last, nothing
/// written.
pub fn stamped(base: *_base.FacetBase, command: *const _command.WriteTimestamp) bool {
    const at = _query.timeOf(command.pool, command.query) orelse return false;
    // Only this task writes it, and the flag `finish` sets is what carries
    // it to whoever reads it: there is no 64-bit atomic on every machine
    // the library runs on.
    at.* = _base.now(base);
    _query.finish(command.pool, command.query);
    return true;
}

/// The values of `command`'s queries written into its buffer: false where
/// they would not lie inside it, and nothing written.
pub fn copied(command: *const _command.CopyQueryResults) bool {
    const pool = command.pool;
    const count = @min(command.count, pool.count -| command.first);
    const wanted = _query.bytesFor(pool, count, command.stride, command.flags);
    const bytes = _buffer.bytes(command.destination, command.offset, wanted) orelse return false;
    if (bytes.len < wanted) return false;
    _ = _query.write(pool, command.first, count, bytes, command.stride, command.flags);
    return true;
}
