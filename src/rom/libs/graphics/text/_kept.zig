// SPDX-License-Identifier: MPL-2.0
//! The glyphs a font's `render` hook made, kept with the font.
//!
//! A font's image holds the glyphs it was built with. A font whose
//! builder can make more (`TextFont.render`) gets a store here when
//! `AddFont` takes it (`make`) and loses it when the font leaves the list
//! (`free`). A glyph the image lacks is asked of the hook the first time
//! a text wants it, and kept: its box and its pixels - or, for a glyph
//! the font does not have, the fact that there is none, so a text of
//! characters a font lacks asks once for each of them and not once each
//! time it is drawn.
//!
//! **Keys.** A glyph is kept under its code point, or under its number
//! in the font with `by_number` set. The two never meet: a code point
//! ends at 0x10FFFF.
//!
//! **Kept for as long as the font is on the list.** Entries are written
//! into blocks one after another and never moved, changed or freed
//! before the store is, so a glyph that was found stays where it is
//! while a text is drawn from it, with no lock held. Nothing is given
//! back while the font is in use: what a font has drawn once, it holds.
//!
//! **One task makes, any number read.** The store's lock is held from
//! finding a glyph absent to its entry being linked in, the hook's work
//! included, so a glyph is rendered once however many tasks want it at
//! the same moment. An entry is linked in whole, by one pointer written
//! last, and a reader walks the chains without the lock: it meets the
//! entry or it does not, never half of one.
//!
//! **The hook writes where the glyph stays.** It is handed the room left
//! in the newest block, behind the place of the entry's head, so the
//! pixels are written once. A glyph that needs more gets a block that
//! holds it, and the hook is asked a second time.
//!
//! **What the hook answers is checked**, as `AddFont` checks an image:
//! the kind is the image's, a row is at least the bytes its pixels take,
//! and the rows lie inside the bytes the hook said it wrote. An answer
//! that fails is kept as no glyph.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const exec = sdk.exec;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;

const fontimage = graphics.fontimage;
const Glyph = fontimage.Glyph;
const TextFont = graphics.TextFont;

/// Set in a key: the rest is a glyph's number in the font, not a code
/// point.
pub const by_number: u32 = 0x8000_0000;

/// How many chains the entries are spread over.
const chain_count = 128;

/// The smallest block entries are written into.
const least_block = 4096;
/// The largest a block is made for glyphs of the usual size; one glyph
/// that needs more gets a block of its own size.
const most_block = 64 * 1024;

/// What `Glyph.data` holds in an entry: the pixels are not in the
/// image's data but right behind the glyph. No glyph of an image
/// `fontimage.check` passed starts there.
const kept_data: u32 = 0xFFFF_FFFF;

/// An entry's `state`: the font has the glyph, and here it is.
const has_glyph: u32 = 1;
/// An entry's `state`: the font has no such glyph.
const no_glyph: u32 = 0;

/// A font's store: `TextFont.cache` points at one.
pub const Store = extern struct {
    /// Held by the task that is making an entry.
    lock: exec.SignalSemaphore,
    /// The newest block, the one entries are written into, and the
    /// older ones behind it.
    blocks: ?*Block,
    /// The entries, each on the chain its key falls on, newest first.
    chains: [chain_count]?*Kept,
};

/// A block of entries, written from the front.
const Block = extern struct {
    next: ?*Block,
    /// Bytes in the block, this head included: a multiple of eight.
    size: u32,
    /// Bytes taken, this head included: a multiple of eight.
    used: u32,
};

/// One entry. The glyph's pixels follow it.
const Kept = extern struct {
    /// The next on the chain. Written before the entry is linked in and
    /// never after.
    next: ?*Kept,
    /// The code point, or `by_number` and the glyph's number.
    key: u32,
    /// `has_glyph` or `no_glyph`.
    state: u32,
    /// The box and the advance; `data` is `kept_data`.
    glyph: Glyph,
};

comptime {
    // `pixelsOf` finds the pixels from the glyph alone.
    if (@offsetOf(Kept, "glyph") + @sizeOf(Glyph) != @sizeOf(Kept)) @compileError("the pixels must follow the glyph");
    if (@sizeOf(Kept) % 8 != 0 and @alignOf(Kept) == 8) @compileError("an entry's head must end on its alignment");
}

/// The store of a font that has a `render` hook, made as the font goes
/// on the list. The caller holds the font list's lock.
///
/// INPUTS:
/// - `gb` - the library.
/// - `font` - the font, whose `cache` is set: to the store, or to null
///   for a font without a hook.
///
/// RESULT:
/// False without memory for the store.
pub fn make(gb: *GraphicsBase, font: *TextFont) bool {
    font.cache = null;
    if (font.render == null) return true;
    const sys = gb.sys_base;
    // The system's, not the caller's: the font outlives the task that
    // added it.
    const memory = sys.AllocVec(@sizeOf(Store), exec.MEMF_ANY | exec.MEMF_SYSTEM | exec.MEMF_CLEAR) orelse return false;
    const store: *Store = @ptrCast(@alignCast(memory));
    sys.InitSemaphore(&store.lock);
    font.cache = store;
    return true;
}

/// A font's store and every glyph in it given back, as the font leaves
/// the list. Nothing draws with the font any more: the caller holds the
/// font list's lock and nobody has the font open.
///
/// INPUTS:
/// - `gb` - the library.
/// - `font` - the font; one without a store is left as it is.
pub fn free(gb: *GraphicsBase, font: *TextFont) void {
    const store: *Store = @ptrCast(@alignCast(font.cache orelse return));
    font.cache = null;
    const sys = gb.sys_base;
    var at = store.blocks;
    while (at) |block| {
        at = block.next;
        sys.FreeVec(block);
    }
    sys.FreeVec(store);
}

/// The glyph a font's hook makes for a key, rendered now if this is the
/// first time it is wanted.
///
/// INPUTS:
/// - `gb` - the library.
/// - `font` - the font.
/// - `key` - a code point, or `by_number` and a glyph's number.
///
/// RESULT:
/// The glyph, good until the font leaves the list; `pixelsOf` finds its
/// pixels. Null for a font without a store, for a glyph the font does
/// not have, and for one that could not be made this time.
pub fn glyphFor(gb: *GraphicsBase, font: *const TextFont, key: u32) ?*const Glyph {
    const store: *Store = @ptrCast(@alignCast(font.cache orelse return null));
    if (find(store, key)) |entry| return glyphIn(entry);
    const sys = gb.sys_base;
    sys.ObtainSemaphore(&store.lock);
    defer sys.ReleaseSemaphore(&store.lock);
    // Another task may have made it while this one waited for the lock.
    if (find(store, key)) |entry| return glyphIn(entry);
    return glyphIn(render(gb, store, font, key) orelse return null);
}

/// Where a glyph's first row starts: in the font's image, or behind the
/// glyph for one of the store's.
///
/// INPUTS:
/// - `font` - the font the glyph is of.
/// - `glyph` - a glyph of its image, or one `glyphFor` gave for it.
pub fn pixelsOf(font: *const TextFont, glyph: *const Glyph) [*]const u8 {
    if (glyph.data != kept_data) return fontimage.pixelsOf(font.image, glyph);
    const bytes: [*]const u8 = @ptrCast(glyph);
    return bytes + @sizeOf(Glyph);
}

/// How many entries a font's store holds, the glyphs it does not have
/// among them. For the tests.
///
/// INPUTS:
/// - `font` - the font.
pub fn countOf(font: *const TextFont) u32 {
    const store: *Store = @ptrCast(@alignCast(font.cache orelse return 0));
    var count: u32 = 0;
    for (&store.chains) |*chain| {
        var at = chain.*;
        while (at) |entry| : (at = entry.next) count += 1;
    }
    return count;
}

fn glyphIn(entry: *const Kept) ?*const Glyph {
    return if (entry.state == has_glyph) &entry.glyph else null;
}

/// The chain a key falls on.
fn chainOf(key: u32) u32 {
    return (key *% 0x9E37_79B1) >> (32 - @ctz(@as(u32, chain_count)));
}

/// The entry of a key, if one is linked in. Needs no lock: a chain's
/// head is read once, and nothing behind it changes.
fn find(store: *const Store, key: u32) ?*const Kept {
    var at = @atomicLoad(?*Kept, &store.chains[chainOf(key)], .acquire);
    while (at) |entry| : (at = entry.next) {
        if (entry.key == key) return entry;
    }
    return null;
}

/// The hook asked for a glyph, and what it answers kept. The caller
/// holds the store's lock.
///
/// RESULT:
/// The entry: a glyph, or the fact that the font has none. Null when
/// nothing could be kept: no memory for a block, or the hook could not
/// make the glyph this time.
fn render(gb: *GraphicsBase, store: *Store, font: *const TextFont, key: u32) ?*const Kept {
    const hook = font.render orelse return null;
    const image = font.image;
    const usual = usualBytes(image);
    var need = usual;
    var asked: u32 = 0;
    while (asked < 2) : (asked += 1) {
        const block = blockWith(gb, store, need, usual) orelse return null;
        const entry: *Kept = @ptrFromInt(@intFromPtr(block) + block.used);
        const pixels: [*]u8 = @ptrFromInt(@intFromPtr(entry) + @sizeOf(Kept));
        const room = block.size - block.used - @sizeOf(Kept);
        var request = graphics.GlyphRequest{
            .which = key & ~by_number,
            .flags = if (key & by_number != 0) graphics.GLYPHREQ_NUMBER else 0,
            .pixels = pixels,
            .room = room,
        };
        switch (gb.utility_base.CallHookPkt(hook, @constCast(font), &request)) {
            graphics.GLYPH_OK => {
                const bytes = bytesOf(image, &request, room) orelse return keep(store, block, entry, key, null, 0);
                return keep(store, block, entry, key, &request.glyph, bytes);
            },
            graphics.GLYPH_NONE => return keep(store, block, entry, key, null, 0),
            graphics.GLYPH_ROOM => {
                // A glyph that fits and is said not to would be asked
                // for without end.
                if (request.size <= room) return null;
                need = request.size;
            },
            else => return null,
        }
    }
    return null;
}

/// The bytes a glyph of the image's height usually stays within: a box
/// as wide as the line is tall.
fn usualBytes(image: *const fontimage.FontImage) u32 {
    const bytes: u64 = @as(u64, fontimage.pitchOf(image.kind, image.height)) * image.height;
    const most: u64 = most_block / 4;
    return @intCast(if (bytes > most) most else bytes);
}

/// The newest block with room for an entry of `need` bytes of pixels:
/// the one there is, or a new one - of the size four usual glyphs take,
/// or the size this one needs.
fn blockWith(gb: *GraphicsBase, store: *Store, need: u32, usual: u32) ?*Block {
    const entry_bytes: u64 = @as(u64, @sizeOf(Kept)) + need;
    if (store.blocks) |block| {
        if (block.size - block.used >= entry_bytes) return block;
    }
    const head: u32 = eights(@sizeOf(Block));
    var size: u64 = 4 * (@as(u64, @sizeOf(Kept)) + usual);
    if (size < least_block) size = least_block;
    if (size < head + entry_bytes) size = head + entry_bytes;
    if (size > 0x4000_0000) return null;
    const whole: u32 = eights(@intCast(size));
    const memory = gb.sys_base.AllocVec(whole, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse return null;
    const block: *Block = @ptrCast(@alignCast(memory));
    block.* = .{ .next = store.blocks, .size = whole, .used = head };
    store.blocks = block;
    return block;
}

/// `bytes` up to the next multiple of eight.
fn eights(bytes: u32) u32 {
    return (bytes + 7) & ~@as(u32, 7);
}

/// How many bytes of pixels a hook's glyph holds, 0 for one without
/// ink; null for an answer that cannot be drawn from: another kind than
/// the image's, rows shorter than their pixels, or rows past the bytes
/// the hook wrote.
fn bytesOf(image: *const fontimage.FontImage, request: *const graphics.GlyphRequest, room: u32) ?u32 {
    if (request.kind != image.kind) return null;
    const glyph = &request.glyph;
    if (glyph.width == 0 or glyph.rows == 0) return 0;
    if (glyph.pitch < fontimage.pitchOf(image.kind, glyph.width)) return null;
    const bytes: u32 = @as(u32, glyph.pitch) * glyph.rows;
    if (bytes > request.size or request.size > room) return null;
    return bytes;
}

/// An entry written at its place in the block and linked in: the glyph
/// with `bytes` of pixels behind it, or - `made` null - no glyph.
fn keep(store: *Store, block: *Block, entry: *Kept, key: u32, made: ?*const Glyph, bytes: u32) *const Kept {
    const chain = &store.chains[chainOf(key)];
    entry.* = .{ .next = chain.*, .key = key, .state = no_glyph, .glyph = .{ .data = kept_data } };
    if (made) |glyph| {
        entry.state = has_glyph;
        entry.glyph = glyph.*;
        entry.glyph.data = kept_data;
        if (bytes == 0) {
            entry.glyph.width = 0;
            entry.glyph.rows = 0;
            entry.glyph.pitch = 0;
        }
    }
    block.used = eights(block.used + @sizeOf(Kept) + bytes);
    // Last, and whole: from here a reader without the lock finds it.
    @atomicStore(?*Kept, chain, entry, .release);
    return entry;
}
