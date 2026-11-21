// SPDX-License-Identifier: MPL-2.0
//! The texts last laid out in a font, kept with it.
//!
//! Laying a text out (`_shaped.layOut`) asks the fonts' `shape` hooks,
//! and for a script with many rules - Devanagari, Arabic - that takes
//! far longer than drawing the glyphs. The same few texts are laid out
//! over and over: a window's layout measures every label each time the
//! window changes size, and draws them after. So a font keeps the texts
//! last laid out in it (`keep`), and a text it has is copied out
//! (`copyOf`) instead of being shaped again.
//!
//! **Kept with the font they were laid out in**, in its store
//! (`_kept.Store`), and given back with it (`free`). A line names glyphs
//! and fonts: the font's own glyphs, which stay until it leaves the
//! list, and its fallbacks' and theirs, which its builder keeps for as
//! long as the font is on the list. A font with no store - one not on
//! the list - keeps nothing. The room for the lines is made the first
//! time a text is kept, so a font that never lays one out has none.
//!
//! **What is kept is what a later call would lay out.** A font's hooks
//! and its fallbacks are set before `AddFont` and never again, so a
//! text is laid out the same every time - except where a hook could not
//! answer for lack of memory: a glyph not made, a text not shaped. A
//! line laid out while that happened anywhere (`GraphicsBase.misses`)
//! is not kept, and the next call lays the text out again. Nor is a
//! text of more than `most_bytes` bytes.
//!
//! **How many.** At most `slot_count` lines and `most_kept` bytes a
//! font. A line that is used is marked, and room is made by a hand going
//! round the slots: a marked line loses its mark and is passed over, the
//! first unmarked one goes. So the lines a window measures again and
//! again stay, and one laid out once makes room for the next.
//!
//! **One lock**, the lines' own, held to find a line and copy it out or
//! to put one in - never while a hook shapes. The caller gets a copy of
//! its own (`_shaped.Line`), freed by `_shaped.free` like any other.

const sdk = @import("sdk");
const exec = sdk.exec;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const Store = @import("_kept.zig").Store;
const _shaped = @import("_shaped.zig");
const Placed = _shaped.Placed;
const Line = _shaped.Line;

/// How many lines a font keeps.
pub const slot_count = 128;
/// The most bytes a font's lines take together.
const most_kept = 128 * 1024;
/// The longest text that is kept, in bytes.
const most_bytes = 256;

/// A font's lines: `Store.lines` points at them once one is kept.
pub const Lines = extern struct {
    /// Held to find, copy out, put in or take out a line.
    lock: exec.SignalSemaphore,
    /// The lines, in no order; null where there is none.
    slots: [slot_count]?*Entry,
    /// The slot room is looked for in next.
    hand: u32,
    /// The bytes the lines take together.
    bytes: u32,
};

/// One line: its glyphs follow it, then its text.
const Entry = extern struct {
    /// The text's hash (`hashOf`).
    hash: u32,
    /// The text's length in bytes.
    length: u32,
    /// How many glyphs it was laid out into.
    count: u32,
    /// Bytes of the entry, this head included.
    size: u32,
    /// Set when the line is copied out, cleared by the hand as it
    /// passes.
    used: u32,
};

/// Where an entry's glyphs start: behind the head, on their alignment.
const glyphs_at: u32 = (@sizeOf(Entry) + @alignOf(Placed) - 1) / @alignOf(Placed) * @alignOf(Placed);

fn glyphsOf(entry: *Entry) [*]Placed {
    return @ptrFromInt(@intFromPtr(entry) + glyphs_at);
}

fn textOf(entry: *Entry) [*]u8 {
    return @ptrFromInt(@intFromPtr(entry) + glyphs_at + entry.count * @sizeOf(Placed));
}

/// A text's hash: FNV-1a over its bytes.
fn hashOf(bytes: []const u8) u32 {
    var hash: u32 = 0x811C_9DC5;
    for (bytes) |byte| hash = (hash ^ byte) *% 0x0100_0193;
    return hash;
}

/// The line of a text, if it is kept. The caller holds the lock.
fn find(lines: *Lines, hash: u32, bytes: []const u8) ?*Entry {
    for (&lines.slots) |slot| {
        const entry = slot orelse continue;
        if (entry.hash != hash or entry.length != bytes.len) continue;
        const text = textOf(entry);
        var same = true;
        for (bytes, 0..) |byte, at| {
            if (text[at] != byte) {
                same = false;
                break;
            }
        }
        if (same) return entry;
    }
    return null;
}

/// A copy of the line a font keeps for a text, or null when it keeps
/// none - or there is no memory for the copy, and the text is laid out
/// as if it kept none.
///
/// INPUTS:
/// - `gb` - the library.
/// - `store` - the store of the font the text is in.
/// - `bytes` - the text.
///
/// OWNERSHIP:
/// The caller hands the copy to `_shaped.free`.
pub fn copyOf(gb: *GraphicsBase, store: *Store, bytes: []const u8) ?Line {
    if (bytes.len > most_bytes) return null;
    const lines = @atomicLoad(?*Lines, &store.lines, .acquire) orelse return null;
    const hash = hashOf(bytes);
    const sys = gb.sys_base;
    sys.ObtainSemaphore(&lines.lock);
    defer sys.ReleaseSemaphore(&lines.lock);
    const entry = find(lines, hash, bytes) orelse return null;
    entry.used = 1;
    const block = sys.AllocVec(@max(entry.count, 1) * @sizeOf(Placed), exec.MEMF_ANY) orelse return null;
    const placed: [*]Placed = @ptrCast(@alignCast(block));
    @memcpy(placed[0..entry.count], glyphsOf(entry)[0..entry.count]);
    return .{ .placed = placed[0..entry.count], .block = block };
}

/// A text's line kept with its font, unless it is too long, there is no
/// memory, or another task kept it first.
///
/// INPUTS:
/// - `gb` - the library.
/// - `store` - the store of the font the text is in.
/// - `bytes` - the text.
/// - `placed` - the glyphs it was laid out into.
pub fn keep(gb: *GraphicsBase, store: *Store, bytes: []const u8, placed: []const Placed) void {
    if (bytes.len > most_bytes) return;
    const whole: u64 = @as(u64, glyphs_at) + @as(u64, placed.len) * @sizeOf(Placed) + bytes.len;
    if (whole > most_kept) return;
    const size: u32 = @intCast((whole + 7) & ~@as(u64, 7));
    const lines = linesOf(gb, store) orelse return;
    const sys = gb.sys_base;
    // The system's, not the caller's: the font outlives the task.
    const memory = sys.AllocVec(size, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse return;
    const entry: *Entry = @ptrCast(@alignCast(memory));
    entry.* = .{ .hash = hashOf(bytes), .length = @intCast(bytes.len), .count = @intCast(placed.len), .size = size, .used = 0 };
    @memcpy(glyphsOf(entry)[0..placed.len], placed);
    @memcpy(textOf(entry)[0..bytes.len], bytes);

    sys.ObtainSemaphore(&lines.lock);
    defer sys.ReleaseSemaphore(&lines.lock);
    // Another task may have kept it while this one laid it out.
    if (find(lines, entry.hash, bytes) != null) {
        sys.FreeVec(memory);
        return;
    }
    const slot = roomFor(gb, lines, size);
    lines.slots[slot] = entry;
    lines.bytes += size;
}

/// A font's lines, made the first time one is kept. Null without
/// memory for them.
fn linesOf(gb: *GraphicsBase, store: *Store) ?*Lines {
    if (@atomicLoad(?*Lines, &store.lines, .acquire)) |lines| return lines;
    const sys = gb.sys_base;
    const memory = sys.AllocVec(@sizeOf(Lines), exec.MEMF_ANY | exec.MEMF_SYSTEM | exec.MEMF_CLEAR) orelse return null;
    const made: *Lines = @ptrCast(@alignCast(memory));
    sys.InitSemaphore(&made.lock);
    // Two tasks may make them at once: the first to set them wins.
    if (@cmpxchgStrong(?*Lines, &store.lines, null, made, .acq_rel, .acquire)) |first| {
        sys.FreeVec(memory);
        return first;
    }
    return made;
}

/// The slot a line of `size` bytes goes in, the lines in the way given
/// back. The caller holds the lock, and `size` is at most `most_kept`.
///
/// Each turn clears a mark, gives a line back, or passes an empty slot:
/// within two rounds every line is gone and the room is there.
fn roomFor(gb: *GraphicsBase, lines: *Lines, size: u32) u32 {
    while (true) {
        const at = lines.hand;
        lines.hand = (at + 1) % slot_count;
        if (lines.slots[at]) |entry| {
            if (entry.used != 0) {
                entry.used = 0;
                continue;
            }
            lines.slots[at] = null;
            lines.bytes -= entry.size;
            gb.sys_base.FreeVec(entry);
        }
        if (lines.bytes + size <= most_kept) return at;
    }
}

/// A font's lines given back, as its store is. Nothing lays a text out
/// in the font any more.
///
/// INPUTS:
/// - `gb` - the library.
/// - `store` - the font's store.
pub fn free(gb: *GraphicsBase, store: *Store) void {
    const lines = store.lines orelse return;
    store.lines = null;
    const sys = gb.sys_base;
    for (&lines.slots) |slot| {
        if (slot) |entry| sys.FreeVec(entry);
    }
    sys.FreeVec(lines);
}

/// How many lines a font keeps. For the tests.
///
/// INPUTS:
/// - `store` - the font's store.
pub fn countOf(store: *const Store) u32 {
    const lines = store.lines orelse return 0;
    var count: u32 = 0;
    for (&lines.slots) |slot| {
        if (slot != null) count += 1;
    }
    return count;
}
