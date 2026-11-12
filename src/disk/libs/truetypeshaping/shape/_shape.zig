// SPDX-License-Identifier: MIT
//! A run shaped: the stages a call takes it through.
//!
//! `shape` works on a buffer the caller filled with the run's glyphs in
//! the order they are read, and on a font's three tables as bytes. It
//! needs nothing of the system but memory, so a tool on the host shapes
//! with the same code.
//!
//! The stages, in their order:
//!
//!   - Each glyph gets the bits of the features that hold for it. A
//!     feature that holds for the whole run, and whose tag the list has
//!     once, shares one bit with all such; every other feature gets a bit
//!     of its own, of which there are 31. Where two features of one tag
//!     hold for a glyph, the later one's bit replaces the earlier one's.
//!   - Each glyph is sorted by `GDEF`; where the font does not sort its
//!     glyphs, a glyph keeps the kind the caller gave it.
//!   - `GSUB`'s lookups for the features, in the order the table lists
//!     them.
//!   - Each glyph's advance, from the font.
//!   - `GPOS`'s lookups, likewise, and the offsets of what they attached
//!     worked out.
//!   - A run read from right to left is turned around: the answer is in
//!     the order it is drawn.
//!
//! A variable font is shaped at the place on its axes the caller says
//! with the font's coordinates (`Font.coords`): the features a table
//! replaces under conditions on the axes are the ones for that place,
//! and the kernings and anchors `GPOS` varies are what they are there
//! (`_variation.zig`). The advances are the caller's to give for the
//! place.
//!
//! A run that is a text (`Order.text`) goes through more:
//!
//!   - `GSUB` is applied in two goes: first the lookups of `rvrn`, which
//!     picks the glyphs a variable font draws in their stead, with what
//!     the language requires; then those of every other feature. A
//!     lookup of the second go so finds the glyphs the first one left.
//!   - After `GSUB` the characters a text does not show are taken out,
//!     unless a lookup made something of them. The bytes of one fall to
//!     the glyph drawn before it, which in a run read from right to left
//!     is the one behind it in the text.
//!   - A space of a set width that is drawn with the font's space glyph
//!     gets its width in place of that glyph's advance, unless a lookup
//!     made a ligature of it.
//!   - After `GPOS`, where the language has no `kern` feature there, the
//!     font's `kern` table sets pairs closer or apart: each glyph the
//!     feature holds for and the next one that is no mark, the left of
//!     the two taking the value on its advance.
//!   - Then a mark's advance is 0. In a font without `GPOS`, read from
//!     left to right, the mark moves back by what its advance was, onto
//!     the glyph before it.

const sdk = @import("sdk");
const truetypeshaping = sdk.truetypeshaping;
const Feature = truetypeshaping.Feature;
const _tables = @import("_tables.zig");
const Table = _tables.Table;
const _buffer = @import("_buffer.zig");
const Buffer = _buffer.Buffer;
const Memory = _buffer.Memory;
const Gdef = @import("_gdef.zig").Gdef;
const _match = @import("_match.zig");
const _lookup = @import("_lookup.zig");
const _plan = @import("_plan.zig");
const _gpos = @import("_gpos.zig");
const _normal = @import("_normal.zig");

/// What a font gives the shaping: its tables, of no length where it has
/// none, its place on its axes, and its glyphs' advances there. A text
/// asks it for more: the glyph of a character, the one of a character
/// with a selector behind it (0 where the font has none for the two),
/// its `kern` table, and how many units its em has, by which a space
/// the font lacks gets its width.
pub const Font = struct {
    gdef: Table = Table.none,
    gsub: Table = Table.none,
    gpos: Table = Table.none,
    /// A variable font's place: a coordinate an axis, in 14 bits of
    /// fraction, -16384 to 16384. Empty for a font at its default, and
    /// for one that has no axes.
    coords: []const i16 = &.{},
    context: *anyopaque,
    advanceFn: *const fn (context: *anyopaque, glyph: u32) i32,
    /// What the font's `kern` table has for two glyphs side by side, the
    /// left one first; null where the call does not ask.
    kerningFn: ?*const fn (context: *anyopaque, left: u32, right: u32) i32 = null,
    glyphFn: ?*const fn (context: *anyopaque, char: u32) u32 = null,
    variantFn: ?*const fn (context: *anyopaque, char: u32, selector: u32) u32 = null,
    /// How many of the font's units an em has.
    emFn: ?*const fn (context: *anyopaque) u32 = null,
};

/// What a call asks for.
pub const Order = struct {
    memory: Memory,
    font: Font,
    /// The script's tag, and the other one of a script that has two,
    /// tried where a table does not list the first; 0 for none.
    script: u32 = 0,
    other_script: u32 = 0,
    language: u32 = 0,
    /// The run is read from right to left.
    backward: bool = false,
    features: []const Feature = &.{},
    /// The run is a text: see the file's head.
    text: bool = false,
    /// The run is left in the order it is read, for a caller that turns
    /// several around as one.
    unturned: bool = false,
};

/// What every stage of a call works with.
const Call = struct {
    order: *const Order,
    gdef: *const Gdef,
    buffer: *Buffer,
    places: [*]u32,
};

const variations_tag = truetypeshaping.featureTag("rvrn");
const kerning_tag = truetypeshaping.featureTag("kern");

/// The bits a call has for features of their own.
const own_bits = 31;

/// How much work a table may do on a run of `length` glyphs
/// (`Apply.spend`): 65536 pieces a glyph, and a million for a short run.
fn workFor(length: u32) u32 {
    const work = @as(u64, length) * 0x0001_0000;
    return if (work < 0x0010_0000) 0x0010_0000 else if (work > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(work);
}

/// Whether `features` has the tag of its entry `index` in another entry
/// too.
fn tagTwice(features: []const Feature, index: usize) bool {
    for (features, 0..) |feature, other| {
        if (other != index and feature.tag == features[index].tag) return true;
    }
    return false;
}

/// Gives each of `features` its bit, in `wanted`. False when there are
/// more that need one of their own than there are bits.
fn assignBits(features: []const Feature, wanted: []_plan.Wanted) bool {
    var used: u32 = 0;
    for (features, wanted, 0..) |feature, *want, index| {
        want.* = .{ .tag = feature.tag, .mask = 0, .value = feature.value };
        if (feature.value == 0) continue;
        if (feature.first == 0 and feature.last == 0xFFFF_FFFF and !tagTwice(features, index)) {
            want.mask = _plan.whole_run;
            continue;
        }
        if (used >= own_bits) return false;
        used += 1;
        want.mask = @as(u32, 1) << @intCast(used);
    }
    return true;
}

/// The bits of a glyph of the cluster `cluster`.
fn maskOf(features: []const Feature, wanted: []const _plan.Wanted, cluster: u32) u32 {
    var mask: u32 = _plan.whole_run;
    for (features, wanted, 0..) |feature, want, index| {
        if (want.mask == _plan.whole_run) continue;
        if (cluster < feature.first or cluster > feature.last) continue;
        for (wanted[0..index]) |earlier| {
            if (earlier.tag == feature.tag) mask &= ~earlier.mask;
        }
        mask |= want.mask;
    }
    return mask;
}

/// Applies the lookups `table` has for the features `wanted` to the
/// buffer - with `required`, those the language requires before them.
fn stage(call: *const Call, table: Table, kind: _match.Kind, wanted: []const _plan.Wanted, required: bool) i32 {
    const order = call.order;
    const buffer = call.buffer;
    const layout = _plan.Layout.init(table, order.script, order.other_script, order.language, order.font.coords);
    var none: [0]_plan.Entry = .{};
    const count = layout.collect(wanted, required, &none);
    if (count == 0) return truetypeshaping.TTS_OK;
    const block = order.memory.alloc(@as(usize, count) * @sizeOf(_plan.Entry)) orelse return truetypeshaping.TTSERR_NOMEM;
    defer order.memory.free(block);
    const all: [*]_plan.Entry = @ptrCast(@alignCast(block));
    const entries = all[0..count];
    _ = layout.collect(wanted, required, entries);
    const kept = _plan.arrange(entries);
    var apply: _match.Apply = .{
        .buffer = buffer,
        .gdef = call.gdef,
        .kind = kind,
        .lookups = layout.lookups,
        .backward = order.backward,
        .places = call.places,
        .place = .{ .coords = order.font.coords, .store = call.gdef.store },
        .work = workFor(buffer.len),
    };
    for (entries[0..kept]) |entry| {
        _lookup.run(&apply, entry.lookup, entry.mask, entry.value);
        if (buffer.failed) return truetypeshaping.TTSERR_NOMEM;
        if (apply.work == 0) break;
    }
    return truetypeshaping.TTS_OK;
}

/// Moves the entries of `rvrn` to the front of `wanted`, the others
/// keeping their order. Answers how many there are.
fn variationsFirst(wanted: []_plan.Wanted) usize {
    var early: usize = 0;
    for (wanted, 0..) |want, index| {
        if (want.tag != variations_tag) continue;
        var place = index;
        while (place > early) : (place -= 1) wanted[place] = wanted[place - 1];
        wanted[early] = want;
        early += 1;
    }
    return early;
}

/// The font's `kern` table applied to a text, where `GPOS` has no `kern`
/// feature for the language: the pairs are taken as they are drawn, and
/// the left glyph of a pair takes the value on its advance.
fn kernByTable(order: *const Order, wanted: []const _plan.Wanted, buffer: *Buffer) void {
    const kerningFn = order.font.kerningFn orelse return;
    var mask: u32 = 0;
    for (wanted) |want| {
        if (want.tag == kerning_tag and want.value != 0) mask |= want.mask;
    }
    if (mask == 0) return;
    const layout = _plan.Layout.init(order.font.gpos, order.script, order.other_script, order.language, order.font.coords);
    if (layout.has(kerning_tag)) return;
    const items = buffer.slice();
    // `drawn` counts the glyphs from the left; the buffer is in the order
    // read.
    var drawn: usize = 0;
    while (drawn < items.len) {
        const left = &items[if (order.backward) items.len - 1 - drawn else drawn];
        drawn += 1;
        if (left.mask & mask == 0) continue;
        var other = drawn;
        while (other < items.len) : (other += 1) {
            const right = &items[if (order.backward) items.len - 1 - other else other];
            if (right.class == _buffer.CLASS_MARK) continue;
            if (right.mask & mask == 0) break;
            left.advance +|= kerningFn(order.font.context, left.glyph, right.glyph);
            drawn = other;
            break;
        }
    }
}

/// Shapes the glyphs in `buffer` - each with its number and its cluster,
/// in the order they are read - as `order` says. Answers `TTS_OK` with
/// the buffer holding the shaped run in the order it is drawn, or one of
/// the `TTSERR_` numbers.
pub fn shape(order: *const Order, buffer: *Buffer) i32 {
    const memory = order.memory;
    const font = &order.font;
    const features = order.features;
    const places_size = _match.nesting_limit * _match.context_limit * @sizeOf(u32);
    const block = memory.alloc(places_size + features.len * @sizeOf(_plan.Wanted)) orelse return truetypeshaping.TTSERR_NOMEM;
    defer memory.free(block);
    const places: [*]u32 = @ptrCast(@alignCast(block));
    const wanted_block: [*]_plan.Wanted = @ptrCast(@alignCast(block + places_size));
    const wanted = wanted_block[0..features.len];
    if (!assignBits(features, wanted)) return truetypeshaping.TTSERR_FEATURES;

    const gdef = Gdef.init(font.gdef);
    for (buffer.slice()) |*item| {
        item.mask = maskOf(features, wanted, item.cluster);
        gdef.classify(item, item.class);
    }
    const call: Call = .{ .order = order, .gdef = &gdef, .buffer = buffer, .places = places };
    // The masks are set: the entries need not stand beside their
    // features any longer.
    const early = if (order.text) variationsFirst(wanted) else wanted.len;
    var result = stage(&call, font.gsub, .substitute, wanted[0..early], true);
    if (result != truetypeshaping.TTS_OK) return result;
    if (order.text) {
        result = stage(&call, font.gsub, .substitute, wanted[early..], false);
        if (result != truetypeshaping.TTS_OK) return result;
        buffer.removeIgnorables(order.backward);
    }
    for (buffer.slice()) |*item| {
        item.advance = font.advanceFn(font.context, item.glyph);
        if (item.space != 0 and item.flags & _buffer.ITEM_LIGATED == 0) {
            item.advance = _normal.spaceAdvance(font, item.space, item.advance);
        }
    }
    result = stage(&call, font.gpos, .position, wanted, true);
    if (result != truetypeshaping.TTS_OK) return result;
    if (order.text) {
        kernByTable(order, wanted, buffer);
        const hangs_back = !order.backward and font.gpos.empty();
        for (buffer.slice()) |*item| {
            if (item.class != _buffer.CLASS_MARK) continue;
            if (hangs_back) item.x_offset -|= item.advance;
            item.advance = 0;
        }
    }
    _gpos.finish(buffer, order.backward);
    if (order.backward and !order.unturned) buffer.reverse();
    return truetypeshaping.TTS_OK;
}
