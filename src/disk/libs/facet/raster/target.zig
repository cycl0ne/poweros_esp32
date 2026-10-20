// SPDX-License-Identifier: MPL-2.0
//! The Target: a surface drawn on a tile at a time.
//!
//! The tiles are squares of `tile_size` pixels over a rectangle of the
//! surface, the area. Their grid starts at the area's top left, moved left
//! to the start of a cache line, so that no two tiles share a line of the
//! surface: tiles written back on different cores never write the same
//! line, and the write-back of one never takes another's half-written
//! line with it. The tiles at the edges are cut to the area; nothing
//! outside it is read or written.
//!
//! A tile is drawn in a buffer of the part's own - its colour and its
//! depth, 24 KiB, which stays in the cache while the part works on it -
//! then its colour is copied into the surface. The buffer keeps colours
//! as 0xAARRGGBB, whatever the surface's order, which they are put in as
//! they are copied. The depth lives only
//! there: it starts cleared with each tile and is gone when the tile is
//! written back, so it costs no memory traffic at all.
//!
//! The tiles are handed on once all of them are in the surface, in a
//! second round shared out the same way. On the JH7110 handing on is the
//! L2's write-back of the tile's lines, one line after the other, and a
//! line just written is dirty: written back at once, every line of the
//! frame goes to memory that way, the cores taking turns with reading
//! the lines they write into and writing back the ones before. Handed on
//! after, a frame larger than the cache has already gone out by itself as
//! it was written, and a smaller one goes out in one stretch. A frame of
//! 1920 x 1080 filled through the tiles took 11.3 ms handed on tile by
//! tile and 8.5 ms after (FillRect: 7.7 ms); one of 800 x 600 3.2 and
//! 2.7 ms (FillRect: 2.8 ms).
//!
//! A tile is written back only when something was drawn into it this
//! frame, or when the frame starts cleared. One nothing touched in a frame
//! kept from the last is not read, not written and not handed on: its
//! write-back would be lines the display has to fetch again from memory
//! for nothing.

const sdk = @import("sdk");
const bins = @import("bins.zig");
const Header = bins.Header;

/// The side of a tile, in pixels.
pub const tile_size = 64;
const tile_pixels = tile_size * tile_size;

/// The most parts a frame's tiles are shared between: a buffer each.
pub const most_parts = 4;

/// The cache line a tile's rows start on.
const line_bytes = 64;

/// What a part of the work is: exec's ShareWork calls it with the data,
/// the part's number and how many there are.
pub const Work = sdk.exec.WorkFn;

/// What the target is given of the system.
pub const Host = struct {
    /// Passed to each of these as it is.
    context: ?*anyopaque = null,
    /// Calls `work(data, part, parts)` once for each of up to `parts`
    /// parts, each on a core of its own at once, and returns when all are
    /// done: how many parts there were. exec's ShareWork.
    share: *const fn (context: ?*anyopaque, work: Work, data: ?*anyopaque, parts: u32) u32,
    /// A rectangle of the surface was written: hand it on to whatever
    /// shows it. Called by the parts at once, for rectangles that never
    /// overlap. rtg's RefreshRect.
    hand_on: *const fn (context: ?*anyopaque, area: Rect) void,
    /// `bytes` of memory, or null.
    allocate: *const fn (context: ?*anyopaque, bytes: usize) ?[*]u8,
    /// Memory `allocate` gave, given back.
    free: *const fn (context: ?*anyopaque, memory: [*]u8, bytes: usize) void,
    /// Microseconds from any start, for `Stats` alone; none, and the times
    /// there stay 0.
    now: ?*const fn (context: ?*anyopaque) u64 = null,

    /// The parts done one after the other: a host with one core, or a
    /// test.
    pub fn oneAfterAnother(context: ?*anyopaque, work: Work, data: ?*anyopaque, parts: u32) u32 {
        _ = context;
        const count = @max(parts, 1);
        var part: u32 = 0;
        while (part < count) : (part += 1) work(data, part, count);
        return count;
    }
};

/// The order of a pixel's bytes in memory.
pub const Format = enum {
    /// Blue, green, red, alpha: 0xAARRGGBB as a 32-bit word.
    bgra32,
    /// Red, green, blue, alpha: 0xAABBGGRR as a 32-bit word.
    rgba32,

    /// A colour, 0xAARRGGBB, as this format's pixel.
    pub fn pack(format: Format, color: u32) u32 {
        return switch (format) {
            .bgra32 => color,
            .rgba32 => color & 0xFF00_FF00 | (color >> 16 & 0xFF) | (color & 0xFF) << 16,
        };
    }
};

/// A rectangle of pixels.
pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// The memory drawn into: its first pixel's first byte, the bytes from
/// one row to the next, its size, and the order of a pixel's bytes.
pub const Surface = struct {
    pixels: [*]u8,
    pitch: u32,
    width: u32,
    height: u32,
    format: Format,
};

/// What each frame starts with.
pub const Attachments = struct {
    color: Color = .{},
    depth: Depth = .{},

    pub const Color = struct {
        /// Cleared to `clear`, or what the surface holds.
        load: Load = .clear,
        /// 0xAARRGGBB.
        clear: u32 = 0xFF00_0000,
    };

    pub const Depth = struct {
        /// Whether triangles are tested against a depth: 16 bits a pixel,
        /// 0 nearest, set to `clear` as each tile starts.
        used: bool = false,
        clear: u16 = 0xFFFF,
    };

    pub const Load = enum { clear, keep };
};

/// What a frame came to.
pub const Finished = struct {
    /// Tiles drawn and written back.
    tiles: u32 = 0,
    /// The parts they were shared between.
    parts: u32 = 0,
};

/// What the draws of a frame came to.
pub const Stats = struct {
    /// Triangles the draws were given.
    triangles: u32 = 0,
    /// Those not drawn: wholly outside the view, facing away, with no
    /// area, or covering no pixel's centre in the area.
    dropped: u32 = 0,
    /// Those cut by the near plane or the guard band.
    cut: u32 = 0,
    /// Triangles set up, and places on the tiles' lists they took.
    set_up: u32 = 0,
    binned: u32 = 0,
    /// Time in the draws: transforming, cutting and setting up, and
    /// putting on the lists (`Host.now`).
    setup_us: u64 = 0,
    binning_us: u64 = 0,
};

/// A tile of the grid, between frames.
const TileState = struct {
    /// Something was drawn into it this frame.
    dirty: bool = false,
    /// The triangles that touch it.
    list: bins.List = .{},
};

/// A part's tile: its colour and depth, a cache line aligned, and the
/// pixels the depth pre-pass's second pass has shaded, a bit each, a row
/// a word.
const Buffer = extern struct {
    color: [tile_pixels]u32 align(line_bytes),
    depth: [tile_pixels]u16,
    shaded: [tile_size]u64,
};

/// The tile a part draws: its buffer, and where it lies on the surface.
pub const Tile = struct {
    buffer: *Buffer,
    /// The grid square's number, row by row.
    index: u32,
    /// The grid square's top left on the surface.
    x: u32,
    y: u32,
    /// The part of the square inside the area, from its top left: what is
    /// drawn, written back and handed on.
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,

    /// Pixels of a tile, from its top left.
    pub const Span = struct { left: u32, top: u32, right: u32, bottom: u32 };

    /// The part of a triangle's box within the tile's pixels, or null.
    pub inline fn span(tile: *const Tile, header: *const Header) ?Span {
        const x: i64 = tile.x;
        const y: i64 = tile.y;
        const left = @max(header.left - x, tile.left);
        const top = @max(header.top - y, tile.top);
        const right = @min(header.right - x, tile.right);
        const bottom = @min(header.bottom - y, tile.bottom);
        if (left >= right or top >= bottom) return null;
        return .{ .left = @intCast(left), .top = @intCast(top), .right = @intCast(right), .bottom = @intCast(bottom) };
    }

    /// Row `y` of the tile's colour, from its left.
    pub inline fn row(tile: *const Tile, y: u32) [*]u32 {
        return tile.buffer.color[y * tile_size ..].ptr;
    }

    /// Row `y` of the tile's depth, from its left.
    pub inline fn depthRow(tile: *const Tile, y: u32) [*]u16 {
        return tile.buffer.depth[y * tile_size ..].ptr;
    }
};

/// The grid of tiles over an area: its top left on the surface - moved
/// left to the start of a cache line - and its squares across and down.
const Grid = struct {
    x: u32,
    y: u32,
    columns: u32,
    rows: u32,

    fn over(surface: Surface, area: Rect) error{OutOfBounds}!Grid {
        if (area.width == 0 or area.height == 0) return error.OutOfBounds;
        if (@as(u64, area.x) + area.width > surface.width or @as(u64, area.y) + area.height > surface.height) return error.OutOfBounds;
        const across = line_bytes / 4;
        const x = area.x / across * across;
        return .{
            .x = x,
            .y = area.y,
            .columns = (area.x + area.width - x + tile_size - 1) / tile_size,
            .rows = (area.height + tile_size - 1) / tile_size,
        };
    }

    fn squares(grid: Grid) u32 {
        return grid.columns * grid.rows;
    }
};

pub const Target = struct {
    host: Host,
    surface: Surface,
    area: Rect,
    attachments: Attachments,
    /// The grid: its top left on the surface, and its squares across and
    /// down.
    grid_x: u32,
    grid_y: u32,
    columns: u32,
    rows: u32,
    /// The squares, row by row.
    tiles: []TileState,
    /// A buffer for each part.
    buffers: *[most_parts]Buffer,
    /// The squares a frame draws, in the order they are handed out, and
    /// the next to hand out.
    order: []u32,
    count: u32 = 0,
    next: u32 = 0,
    /// The colour cleared to, in the surface's format.
    clear_pixel: u32 = 0,
    /// The frame's memory, and the triangles set up by the draw under way
    /// and not yet on the tiles' lists.
    arena: bins.Arena,
    pending: []*const Header = &.{},
    pending_count: u32 = 0,
    stats: Stats = .{},
    /// The block everything above lives in, as `allocate` gave it, and the
    /// squares it has room for.
    memory: [*]u8,
    memory_bytes: usize,
    room: u32,

    /// A target over `area` of `surface`, which has to lie inside it.
    pub fn init(host: Host, surface: Surface, area: Rect, attachments: Attachments) error{ OutOfMemory, OutOfBounds }!Target {
        const grid = try Grid.over(surface, area);
        var target = Target{
            .host = host,
            .surface = surface,
            .area = area,
            .attachments = attachments,
            .grid_x = grid.x,
            .grid_y = grid.y,
            .columns = grid.columns,
            .rows = grid.rows,
            .tiles = &.{},
            .buffers = undefined,
            .order = &.{},
            .arena = .{ .host = host },
            .memory = undefined,
            .memory_bytes = 0,
            .room = 0,
        };
        try target.lay(grid.squares());
        return target;
    }

    /// The target moved onto `area` of `surface`, which may be another, and
    /// given `attachments`: its buffers and its frame's memory kept, its
    /// grid laid again - in its block while that has room for the squares,
    /// else in a larger one. Between frames.
    pub fn moveTo(target: *Target, surface: Surface, area: Rect, attachments: Attachments) error{ OutOfMemory, OutOfBounds }!void {
        const grid = try Grid.over(surface, area);
        if (grid.squares() > target.room) try target.lay(grid.squares());
        target.surface = surface;
        target.area = area;
        target.attachments = attachments;
        target.grid_x = grid.x;
        target.grid_y = grid.y;
        target.columns = grid.columns;
        target.rows = grid.rows;
        target.tiles = target.tiles.ptr[0..grid.squares()];
        target.order = target.order.ptr[0..grid.squares()];
    }

    /// A block for the buffers and `squares` squares, in place of the one
    /// there was: the buffers, the squares and their order laid out in it.
    fn lay(target: *Target, squares: u32) error{OutOfMemory}!void {
        const host = target.host;
        const buffers_bytes = @sizeOf([most_parts]Buffer);
        const tiles_bytes = squares * @sizeOf(TileState);
        const order_bytes = squares * @sizeOf(u32);
        const bytes = line_bytes + buffers_bytes + tiles_bytes + order_bytes;
        const memory = host.allocate(host.context, bytes) orelse return error.OutOfMemory;
        if (target.memory_bytes != 0) host.free(host.context, target.memory, target.memory_bytes);
        var at = (@intFromPtr(memory) + line_bytes - 1) / line_bytes * line_bytes;
        target.buffers = @ptrFromInt(at);
        at += buffers_bytes;
        target.tiles = @as([*]TileState, @ptrFromInt(at))[0..squares];
        at += tiles_bytes;
        target.order = @as([*]u32, @ptrFromInt(at))[0..squares];
        target.memory = memory;
        target.memory_bytes = bytes;
        target.room = squares;
    }

    pub fn deinit(target: *Target) void {
        target.arena.deinit();
        target.host.free(target.host.context, target.memory, target.memory_bytes);
        target.* = undefined;
    }

    /// A frame begun: as the attachments say, every tile cleared or every
    /// tile kept, and nothing drawn yet.
    pub fn begin(target: *Target) void {
        const cleared = target.attachments.color.load == .clear;
        for (target.tiles) |*state| state.* = .{ .dirty = cleared };
        target.clear_pixel = target.attachments.color.clear;
        target.arena.reset();
        target.pending = &.{};
        target.pending_count = 0;
        target.stats = .{};
    }

    /// Microseconds, if the host can tell.
    pub fn now(target: *const Target) u64 {
        const clock = target.host.now orelse return 0;
        return clock(target.host.context);
    }

    /// The area's left, top, right and bottom, the last two one past it.
    pub fn areaBounds(target: *const Target) [4]i32 {
        const area = target.area;
        return .{ @intCast(area.x), @intCast(area.y), @intCast(area.x + area.width), @intCast(area.y + area.height) };
    }

    /// A triangle set up, to go on the tiles' lists at the end of the draw.
    pub fn addPending(target: *Target, triangle: *const Header) error{OutOfMemory}!void {
        if (target.pending_count == target.pending.len) {
            const more = target.arena.alloc(*const Header, @max(256, target.pending.len * 2)) orelse return error.OutOfMemory;
            @memcpy(more[0..target.pending_count], target.pending[0..target.pending_count]);
            target.pending = more;
        }
        target.pending[target.pending_count] = triangle;
        target.pending_count += 1;
        target.stats.set_up += 1;
    }

    /// The triangles set up from `first` on put on the list of every tile
    /// they touch: every tile of the box, but those wholly outside one of
    /// the edges.
    pub fn bin(target: *Target, first: u32) error{OutOfMemory}!void {
        defer target.pending_count = first;
        for (target.pending[first..target.pending_count]) |triangle| {
            const first_column: u32 = (@as(u32, @intCast(triangle.left)) - target.grid_x) / tile_size;
            const last_column: u32 = (@as(u32, @intCast(triangle.right - 1)) - target.grid_x) / tile_size;
            const first_row: u32 = (@as(u32, @intCast(triangle.top)) - target.grid_y) / tile_size;
            const last_row: u32 = (@as(u32, @intCast(triangle.bottom - 1)) - target.grid_y) / tile_size;
            var tile_row = first_row;
            while (tile_row <= last_row) : (tile_row += 1) {
                var column = first_column;
                while (column <= last_column) : (column += 1) {
                    if (!touches(triangle, target.grid_x + column * tile_size, target.grid_y + tile_row * tile_size)) continue;
                    const state = &target.tiles[tile_row * target.columns + column];
                    if (!state.list.add(&target.arena, triangle)) return error.OutOfMemory;
                    state.dirty = true;
                    target.stats.binned += 1;
                }
            }
        }
    }

    /// The frame drawn: every tile with something to do drawn in a part's
    /// buffer and written into the surface, then each handed on, the
    /// tiles shared out between the cores both times.
    pub fn finish(target: *Target) Finished {
        var count: u32 = 0;
        for (target.tiles, 0..) |state, index| {
            if (!state.dirty) continue;
            target.order[count] = @intCast(index);
            count += 1;
        }
        if (count == 0) return .{};
        target.count = count;
        const wanted = @min(count, most_parts);
        @atomicStore(u32, &target.next, 0, .release);
        const parts = target.host.share(target.host.context, &drawTiles, target, wanted);
        @atomicStore(u32, &target.next, 0, .release);
        _ = target.host.share(target.host.context, &handOnTiles, target, wanted);
        return .{ .tiles = count, .parts = parts };
    }

    /// The square `index` as part `part`'s tile.
    fn tileAt(target: *Target, index: u32, part: u32) Tile {
        const x = target.grid_x + index % target.columns * tile_size;
        const y = target.grid_y + index / target.columns * tile_size;
        const area = target.area;
        return .{
            .buffer = &target.buffers[part],
            .index = index,
            .x = x,
            .y = y,
            .left = @max(x, area.x) - x,
            .top = @max(y, area.y) - y,
            .right = @min(x + tile_size, area.x + area.width) - x,
            .bottom = @min(y + tile_size, area.y + area.height) - y,
        };
    }

    /// One tile: started as the attachments say, drawn, and written into
    /// the surface.
    fn drawTile(target: *Target, tile: *const Tile) void {
        const buffer = tile.buffer;
        switch (target.attachments.color.load) {
            .clear => @memset(&buffer.color, target.clear_pixel),
            .keep => target.load(tile),
        }
        if (target.attachments.depth.used) @memset(&buffer.depth, target.attachments.depth.clear);
        const state = &target.tiles[tile.index];
        // The triangles at the head of the list that ask for the depth
        // pre-pass are shaded where their depth was left, the rest as
        // ever.
        const lead = prepass(tile, &state.list);
        var drawn: usize = 0;
        var block = state.list.first;
        while (block) |each| : (block = each.next) {
            for (each.triangles[0..each.count]) |triangle| {
                if (drawn < lead) triangle.prepass.?.shade(tile, triangle) else triangle.raster(tile, triangle);
                drawn += 1;
            }
        }
        target.store(tile);
    }

    /// The depth pre-pass's first pass (prepass.zig): the depth of the
    /// triangles at the head of a tile's list whose pipelines ask for it,
    /// drawn alone; how many they are.
    fn prepass(tile: *const Tile, list: *const bins.List) usize {
        var lead: usize = 0;
        var block = list.first;
        walk: while (block) |each| : (block = each.next) {
            for (each.triangles[0..each.count]) |triangle| {
                const passes = triangle.prepass orelse break :walk;
                passes.depth(tile, triangle);
                lead += 1;
            }
        }
        if (lead != 0) tile.buffer.shaded = @splat(0);
        return lead;
    }

    /// The part of a tile inside the area, handed on.
    fn handOn(target: *Target, tile: *const Tile) void {
        target.host.hand_on(target.host.context, .{
            .x = tile.x + tile.left,
            .y = tile.y + tile.top,
            .width = tile.right - tile.left,
            .height = tile.bottom - tile.top,
        });
    }

    /// The surface under the tile, into its buffer.
    fn load(target: *Target, tile: *const Tile) void {
        const surface = target.surface;
        var row = tile.top;
        while (row < tile.bottom) : (row += 1) {
            const from: [*]const u32 = @ptrCast(@alignCast(surface.pixels + @as(usize, tile.y + row) * surface.pitch));
            const into = tile.buffer.color[row * tile_size ..];
            copy(surface.format, into[tile.left..tile.right], from[tile.x + tile.left .. tile.x + tile.right]);
        }
    }

    /// The tile's buffer, into the surface.
    fn store(target: *Target, tile: *const Tile) void {
        const surface = target.surface;
        var row = tile.top;
        while (row < tile.bottom) : (row += 1) {
            const into: [*]u32 = @ptrCast(@alignCast(surface.pixels + @as(usize, tile.y + row) * surface.pitch));
            const from = tile.buffer.color[row * tile_size ..];
            copy(surface.format, into[tile.x + tile.left .. tile.x + tile.right], from[tile.left..tile.right]);
        }
    }
};

/// A row between a tile's buffer, 0xAARRGGBB, and a surface in `format`:
/// red and blue swapped on the way for rgba32, which is its own undoing.
fn copy(format: Format, into: []u32, from: []const u32) void {
    switch (format) {
        .bgra32 => @memcpy(into, from),
        .rgba32 => for (into, from) |*pixel, color| {
            pixel.* = format.pack(color);
        },
    }
}

/// A part of the drawing: tiles taken one at a time, while there are any,
/// and drawn in the part's own buffer.
fn drawTiles(data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void {
    _ = parts;
    const target: *Target = @ptrCast(@alignCast(data.?));
    while (true) {
        const at = @atomicRmw(u32, &target.next, .Add, 1, .monotonic);
        if (at >= target.count) return;
        const tile = target.tileAt(target.order[at], part);
        target.drawTile(&tile);
    }
}

/// A part of the handing on: the same, the tiles handed on.
fn handOnTiles(data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void {
    _ = parts;
    const target: *Target = @ptrCast(@alignCast(data.?));
    while (true) {
        const at = @atomicRmw(u32, &target.next, .Add, 1, .monotonic);
        if (at >= target.count) return;
        const tile = target.tileAt(target.order[at], part);
        target.handOn(&tile);
    }
}

/// Whether any pixel of the square at (x, y) is inside all three of the
/// triangle's edges: for each, its most inside corner is.
fn touches(triangle: *const Header, x: u32, y: u32) bool {
    for (triangle.edges) |edge| {
        const corner_x: i64 = if (edge.a > 0) x + tile_size - 1 else x;
        const corner_y: i64 = if (edge.b > 0) y + tile_size - 1 else y;
        if (edge.at(corner_x, corner_y) < 0) return false;
    }
    return true;
}
