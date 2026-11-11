// SPDX-License-Identifier: MIT
//! The run a call shapes: its glyphs, and what the shaping knows of each.
//!
//! A `Buffer` is one block of items, allocated for the call and freed
//! before it answers. A substitution that makes more glyphs of one, or
//! one of several, moves the items behind it (`replace`); the block grows
//! when it must, up to a limit that depends on the run's length, so a
//! font whose lookups feed each other cannot grow a run without end. Past
//! the limit a substitution that needs room does not happen (`full`);
//! without the memory to grow, the call fails (`failed`).
//!
//! Besides its number, its cluster and its place, an item carries what
//! the lookups ask about each other's work: the kind of glyph it is, the
//! ligature it is a part of or sits on, and what it is attached to.

/// Where a call's scratch memory comes from.
pub const Memory = struct {
    context: *anyopaque,
    allocFn: *const fn (context: *anyopaque, bytes: usize) ?[*]u8,
    freeFn: *const fn (context: *anyopaque, block: [*]u8) void,

    pub fn alloc(memory: Memory, bytes: usize) ?[*]u8 {
        return memory.allocFn(memory.context, bytes);
    }

    pub fn free(memory: Memory, block: [*]u8) void {
        memory.freeFn(memory.context, block);
    }
};

/// The kinds of glyph a font's `GDEF` sorts its glyphs into.
pub const CLASS_NONE: u8 = 0;
pub const CLASS_BASE: u8 = 1;
pub const CLASS_LIGATURE: u8 = 2;
pub const CLASS_MARK: u8 = 3;
pub const CLASS_COMPONENT: u8 = 4;

/// How an item is attached to another.
pub const ATTACH_NONE: u8 = 0;
pub const ATTACH_MARK: u8 = 1;
pub const ATTACH_CURSIVE: u8 = 2;

/// What happened to an item.
pub const ITEM_SUBSTITUTED: u8 = 0x01;
pub const ITEM_LIGATED: u8 = 0x02;
pub const ITEM_MULTIPLIED: u8 = 0x04;

/// One glyph of the run.
pub const Item = struct {
    glyph: u32,
    cluster: u32,
    /// The features that hold for it, a bit each.
    mask: u32,
    advance: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    /// How many items away the one it is attached to is; 0 for none.
    attach_chain: i32 = 0,
    /// The ligature it is, or is a part of or sits on; 0 for none.
    ligature: u16 = 0,
    /// Which part of the ligature a mark sits on, counted from 1, or
    /// which glyph of a sequence one glyph became, counted from 0.
    part: u8 = 0,
    /// How many parts a ligature made here has; 0 for any other glyph.
    parts: u8 = 0,
    class: u8 = CLASS_NONE,
    /// The class of mark `GDEF` sorts it into.
    mark_class: u8 = 0,
    attach_type: u8 = ATTACH_NONE,
    flags: u8 = 0,

    /// Which part of a ligature it sits on; 0 for a ligature itself.
    pub fn partOn(item: *const Item) u32 {
        return if (item.parts != 0) 0 else item.part;
    }

    /// How many parts it counts as in a ligature made of it.
    pub fn partCount(item: *const Item) u32 {
        return if (item.class == CLASS_LIGATURE and item.parts != 0) item.parts else 1;
    }
};

/// The shortest limit a run's growth has, and how many glyphs a run may
/// grow to for each it started with.
const least_limit = 16384;
const growth = 64;

pub const Buffer = struct {
    memory: Memory,
    items: [*]Item,
    len: u32,
    room: u32,
    /// The most items the run may grow to.
    limit: u32,
    /// The number the last ligature made got.
    ligatures: u16 = 0,
    /// A substitution was left out for the limit.
    full: bool = false,
    /// The block could not grow.
    failed: bool = false,

    /// A buffer for a run of `count` glyphs, with none in it yet. Null
    /// without the memory.
    pub fn init(memory: Memory, count: u32) ?Buffer {
        const room = count + count / 2 + 8;
        const block = memory.alloc(@as(usize, room) * @sizeOf(Item)) orelse return null;
        const grown = @as(u64, count) * growth;
        return .{
            .memory = memory,
            .items = @ptrCast(@alignCast(block)),
            .len = 0,
            .room = room,
            .limit = if (grown < least_limit) least_limit else if (grown > 0x00FF_FFFF) 0x00FF_FFFF else @intCast(grown),
        };
    }

    pub fn deinit(buffer: *Buffer) void {
        buffer.memory.free(@ptrCast(buffer.items));
    }

    pub fn slice(buffer: *const Buffer) []Item {
        return buffer.items[0..buffer.len];
    }

    /// Adds an item at the end. The buffer was made with the room.
    pub fn append(buffer: *Buffer, item: Item) void {
        if (buffer.len >= buffer.room) return;
        buffer.items[buffer.len] = item;
        buffer.len += 1;
    }

    /// Makes `put` items of the `taken` items at `at`: the items behind
    /// them move, and the new ones are copies of the first taken, for the
    /// caller to change. False, and nothing changed, when the run may not
    /// grow further or there is not the memory.
    pub fn replace(buffer: *Buffer, at: u32, taken: u32, put: u32) bool {
        if (at >= buffer.len or taken == 0 or taken > buffer.len - at or put == 0) return false;
        const rest = buffer.len - at - taken;
        if (put > taken) {
            const more = put - taken;
            if (more > buffer.limit or buffer.len > buffer.limit - more) {
                buffer.full = true;
                return false;
            }
            if (!buffer.grow(buffer.len + more)) return false;
        }
        const first = buffer.items[at];
        if (put != taken and rest != 0) {
            const from = buffer.items[at + taken ..][0..rest];
            const to = buffer.items[at + put ..][0..rest];
            if (put > taken) {
                var index = rest;
                while (index > 0) {
                    index -= 1;
                    to[index] = from[index];
                }
            } else {
                for (to, from) |*target, source| target.* = source;
            }
        }
        for (buffer.items[at..][0..put]) |*item| item.* = first;
        buffer.len = buffer.len - taken + put;
        return true;
    }

    /// Room for `needed` items.
    fn grow(buffer: *Buffer, needed: u32) bool {
        if (needed <= buffer.room) return true;
        var room = buffer.room;
        while (room < needed) room += room / 2 + 8;
        const block = buffer.memory.alloc(@as(usize, room) * @sizeOf(Item)) orelse {
            buffer.failed = true;
            return false;
        };
        const items: [*]Item = @ptrCast(@alignCast(block));
        for (items[0..buffer.len], buffer.items[0..buffer.len]) |*target, source| target.* = source;
        buffer.memory.free(@ptrCast(buffer.items));
        buffer.items = items;
        buffer.room = room;
        return true;
    }

    /// Takes the items at `places` out of the run. The places rise.
    pub fn remove(buffer: *Buffer, places: []const u32) void {
        if (places.len == 0 or places[0] >= buffer.len) return;
        var kept = places[0];
        var taken: usize = 0;
        var index = places[0];
        while (index < buffer.len) : (index += 1) {
            if (taken < places.len and places[taken] == index) {
                taken += 1;
                continue;
            }
            buffer.items[kept] = buffer.items[index];
            kept += 1;
        }
        buffer.len = kept;
    }

    /// Gives the items from `start` up to `end` the lowest cluster among
    /// them, and with them the neighbours that shared a cluster with the
    /// first or the last of them.
    pub fn mergeClusters(buffer: *Buffer, start: u32, end: u32) void {
        if (end > buffer.len or start >= end or end - start < 2) return;
        const items = buffer.items;
        var lowest = items[start].cluster;
        for (items[start + 1 .. end]) |item| {
            if (item.cluster < lowest) lowest = item.cluster;
        }
        var from = start;
        var to = end;
        if (lowest != items[to - 1].cluster) {
            while (to < buffer.len and items[to - 1].cluster == items[to].cluster) to += 1;
        }
        if (lowest != items[from].cluster) {
            while (from > 0 and items[from - 1].cluster == items[from].cluster) from -= 1;
        }
        for (items[from..to]) |*item| item.cluster = lowest;
    }

    /// Before the item at `at` is taken out: when no neighbour has its
    /// cluster, the glyphs before it take it over, or else the one behind.
    pub fn giveCluster(buffer: *Buffer, at: u32) void {
        if (at >= buffer.len) return;
        const items = buffer.items;
        const cluster = items[at].cluster;
        if (at + 1 < buffer.len and items[at + 1].cluster == cluster) return;
        if (at > 0) {
            const before = items[at - 1].cluster;
            if (before == cluster or before < cluster) return;
            var index = at;
            while (index > 0 and items[index - 1].cluster == before) {
                index -= 1;
                items[index].cluster = cluster;
            }
            return;
        }
        buffer.mergeClusters(at, at + 2);
    }

    /// A number for a ligature about to be made; never 0.
    pub fn nextLigature(buffer: *Buffer) u16 {
        buffer.ligatures +%= 1;
        if (buffer.ligatures == 0) buffer.ligatures = 1;
        return buffer.ligatures;
    }

    /// Turns the run around, each item's attachment with it.
    pub fn reverse(buffer: *Buffer) void {
        if (buffer.len < 2) return;
        var low: u32 = 0;
        var high: u32 = buffer.len - 1;
        while (low < high) : ({
            low += 1;
            high -= 1;
        }) {
            const kept = buffer.items[low];
            buffer.items[low] = buffer.items[high];
            buffer.items[high] = kept;
        }
        for (buffer.slice()) |*item| item.attach_chain = -item.attach_chain;
    }
};
