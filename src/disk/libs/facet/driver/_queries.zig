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

/// A timestamp written, the clock read here: false for a pool of another
/// kind or a query past its last, nothing written.
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
