// SPDX-License-Identifier: MPL-2.0
//! A frame's memory and the tiles' lists of triangles.
//!
//! What the draws of a frame make - the triangles set up, ready to be
//! drawn, and the lists that say which tiles each touches - comes out of
//! an arena: chunks taken from the host as they are needed and kept for
//! the frames after, each frame starting again at the first. Nothing is
//! freed until the target is.
//!
//! A tile's list is blocks of triangles, the first taken when the tile
//! gets its first, more chained on when one fills up. The draws fill the
//! lists on the caller's task alone; the parts only read them, each its
//! own tile's.

const Host = @import("target.zig").Host;
const Tile = @import("target.zig").Tile;

/// Where a triangle set up for drawing starts: how to draw it, and the
/// pixels it can cover. The pipeline's own data follows.
pub const Header = struct {
    /// Draws the triangle's pixels in a tile: the pipeline's, made for it.
    raster: *const fn (tile: *const Tile, triangle: *const Header) void,
    /// Its bounding box cut to the area: the first column and row it can
    /// cover, and one past the last. Surface pixels.
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    /// Its edges: `edges[i]` is the one opposite vertex i, and a pixel is
    /// inside where all three are 0 or more (`Edge`).
    edges: [3]Edge,
    /// How it is drawn in the depth pre-pass (prepass.zig), for a
    /// triangle of a pipeline that asks for one; null for any other.
    prepass: ?*const Prepass = null,
};

/// A triangle drawn in two passes over a tile: its depth alone, first,
/// with the others' at the head of the tile's list; then its colour where
/// its depth is the one left, in the list's order.
pub const Prepass = struct {
    depth: *const fn (tile: *const Tile, triangle: *const Header) void,
    shade: *const fn (tile: *const Tile, triangle: *const Header) void,
};

/// An edge's function: `a * x + b * y + c` at pixel (x, y) - its centre -
/// is how far the pixel is inside, in 1/65536ths of a pixel's area, times
/// twice the edge's length. One across adds `a`, one down adds `b`. `c`
/// already leaves out a pixel exactly on an edge that is not a top or a
/// left one, so each pixel on a shared edge is drawn once.
pub const Edge = struct {
    a: i64,
    b: i64,
    c: i64,
    /// A row down in whole steps across and what is left over: `b` as
    /// `down_whole * |a| + down_part`, 0 <= down_part < |a|, for following
    /// where the edge crosses the rows (walk.zig). 0 and 0 for an edge
    /// along the rows, whose `a` is 0.
    down_whole: i64,
    down_part: i64,

    pub fn of(a: i64, b: i64, c: i64) Edge {
        if (a == 0) return .{ .a = a, .b = b, .c = c, .down_whole = 0, .down_part = 0 };
        const step: i64 = @intCast(@abs(a));
        const down_whole = @divFloor(b, step);
        return .{ .a = a, .b = b, .c = c, .down_whole = down_whole, .down_part = b - down_whole * step };
    }

    pub fn at(edge: Edge, x: i64, y: i64) i64 {
        return edge.a * x + edge.b * y + edge.c;
    }
};

/// Triangles of a tile: a block of them, and the next when it filled up.
pub const Block = struct {
    next: ?*Block = null,
    count: u32 = 0,
    triangles: [block_triangles]*const Header = undefined,
};

/// So a block is 256 bytes.
const block_triangles = 30;

/// A tile's list.
pub const List = struct {
    first: ?*Block = null,
    last: ?*Block = null,

    /// `triangle` added at the end; false when there is no memory for
    /// another block.
    pub fn add(list: *List, arena: *Arena, triangle: *const Header) bool {
        const block = if (list.last) |last| block: {
            if (last.count < block_triangles) break :block last;
            const more = arena.create(Block) orelse return false;
            more.* = .{};
            last.next = more;
            break :block more;
        } else block: {
            const first = arena.create(Block) orelse return false;
            first.* = .{};
            list.first = first;
            break :block first;
        };
        list.last = block;
        block.triangles[block.count] = triangle;
        block.count += 1;
        return true;
    }
};

/// The chunks of a frame's memory.
pub const Arena = struct {
    host: Host,
    /// Every chunk taken, in order, and the one being cut from.
    first: ?*Chunk = null,
    current: ?*Chunk = null,
    at: usize = 0,
    end: usize = 0,

    const Chunk = struct {
        next: ?*Chunk,
        bytes: usize,
    };

    /// The size of a chunk, unless something larger is asked for.
    const chunk_bytes = 64 * 1024;

    /// Every chunk free again for the next frame.
    pub fn reset(arena: *Arena) void {
        arena.current = null;
        arena.at = 0;
        arena.end = 0;
    }

    /// `bytes` aligned to `alignment`, or null.
    pub fn allocate(arena: *Arena, bytes: usize, alignment: usize) ?[*]u8 {
        var start = (arena.at + alignment - 1) & ~(alignment - 1);
        if (arena.current == null or start + bytes > arena.end) {
            const chunk = arena.nextChunk(bytes + alignment) orelse return null;
            arena.current = chunk;
            arena.at = @intFromPtr(chunk) + @sizeOf(Chunk);
            arena.end = @intFromPtr(chunk) + chunk.bytes;
            start = (arena.at + alignment - 1) & ~(alignment - 1);
        }
        arena.at = start + bytes;
        return @ptrFromInt(start);
    }

    pub fn create(arena: *Arena, comptime T: type) ?*T {
        return @ptrCast(@alignCast(arena.allocate(@sizeOf(T), @alignOf(T)) orelse return null));
    }

    pub fn alloc(arena: *Arena, comptime T: type, count: usize) ?[]T {
        const memory = arena.allocate(@sizeOf(T) * count, @alignOf(T)) orelse return null;
        return @as([*]T, @ptrCast(@alignCast(memory)))[0..count];
    }

    /// The chunk after the current one, kept from a frame before if it is
    /// large enough, else a new one. A kept one too small is skipped, and
    /// stays where it is.
    fn nextChunk(arena: *Arena, wanted: usize) ?*Chunk {
        var link = if (arena.current) |current| &current.next else &arena.first;
        while (link.*) |chunk| : (link = &chunk.next) {
            if (chunk.bytes - @sizeOf(Chunk) >= wanted) return chunk;
        }
        const bytes = @max(chunk_bytes, wanted + @sizeOf(Chunk));
        const memory = arena.host.allocate(arena.host.context, bytes) orelse return null;
        // The host's memory is aligned for a pointer at least.
        const chunk: *Chunk = @ptrCast(@alignCast(memory));
        chunk.* = .{ .next = null, .bytes = bytes };
        link.* = chunk;
        return chunk;
    }

    /// Every chunk given back.
    pub fn deinit(arena: *Arena) void {
        var next = arena.first;
        while (next) |chunk| {
            next = chunk.next;
            arena.host.free(arena.host.context, @ptrCast(chunk), chunk.bytes);
        }
        arena.* = .{ .host = arena.host };
    }
};
