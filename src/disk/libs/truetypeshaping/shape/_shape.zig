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
//!   - Each glyph is sorted by `GDEF`.
//!   - `GSUB`'s lookups for the features, in the order the table lists
//!     them.
//!   - Each glyph's advance, from the font.
//!   - `GPOS`'s lookups, likewise, and the offsets of what they attached
//!     worked out.
//!   - A run read from right to left is turned around: the answer is in
//!     the order it is drawn.

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

/// What a font gives the shaping: its tables, of no length where it has
/// none, and its glyphs' advances.
pub const Font = struct {
    gdef: Table = Table.none,
    gsub: Table = Table.none,
    gpos: Table = Table.none,
    context: *anyopaque,
    advanceFn: *const fn (context: *anyopaque, glyph: u32) i32,
};

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

/// Applies the lookups `table` has for the features to the buffer.
fn stage(
    memory: Memory,
    table: Table,
    kind: _match.Kind,
    script: u32,
    language: u32,
    wanted: []const _plan.Wanted,
    gdef: *const Gdef,
    buffer: *Buffer,
    places: [*]u32,
    backward: bool,
) i32 {
    const layout = _plan.Layout.init(table, script, language);
    var none: [0]_plan.Entry = .{};
    const count = layout.collect(wanted, &none);
    if (count == 0) return truetypeshaping.TTS_OK;
    const block = memory.alloc(@as(usize, count) * @sizeOf(_plan.Entry)) orelse return truetypeshaping.TTSERR_NOMEM;
    defer memory.free(block);
    const all: [*]_plan.Entry = @ptrCast(@alignCast(block));
    const entries = all[0..count];
    _ = layout.collect(wanted, entries);
    const kept = _plan.arrange(entries);
    var apply: _match.Apply = .{
        .buffer = buffer,
        .gdef = gdef,
        .kind = kind,
        .lookups = layout.lookups,
        .backward = backward,
        .places = places,
        .work = workFor(buffer.len),
    };
    for (entries[0..kept]) |entry| {
        _lookup.run(&apply, entry.lookup, entry.mask, entry.value);
        if (buffer.failed) return truetypeshaping.TTSERR_NOMEM;
        if (apply.work == 0) break;
    }
    return truetypeshaping.TTS_OK;
}

/// Shapes the glyphs in `buffer` - each with its number and its cluster,
/// in the order they are read - with `font`, for `script` and
/// `language`, by `features`. `backward` says the run is read from right
/// to left. Answers `TTS_OK` with the buffer holding the shaped run in
/// the order it is drawn, or one of the `TTSERR_` numbers.
pub fn shape(
    memory: Memory,
    font: Font,
    script: u32,
    language: u32,
    backward: bool,
    features: []const Feature,
    buffer: *Buffer,
) i32 {
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
        gdef.classify(item, _buffer.CLASS_NONE);
    }
    var result = stage(memory, font.gsub, .substitute, script, language, wanted, &gdef, buffer, places, backward);
    if (result != truetypeshaping.TTS_OK) return result;
    for (buffer.slice()) |*item| item.advance = font.advanceFn(font.context, item.glyph);
    result = stage(memory, font.gpos, .position, script, language, wanted, &gdef, buffer, places, backward);
    if (result != truetypeshaping.TTS_OK) return result;
    _gpos.finish(buffer, backward);
    if (backward) buffer.reverse();
    return truetypeshaping.TTS_OK;
}
