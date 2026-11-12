// SPDX-License-Identifier: MIT
//! A text shaped: its characters read, split by script, and each stretch
//! taken through the stages of `_shape.zig`.
//!
//! Like `shape`, `shapeText` needs nothing of the system but memory and
//! what `Font` hands it, so a tool on the host shapes with the same code.
//!
//! The text is UTF-8; a byte that is none reads as U+FFFD. It is cut
//! into stretches of one script each (`stretchAt`): a character many
//! scripts share - a space, a digit, a comma - and a mark belong to the
//! stretch before them, and those a text starts with to its first. A
//! text of such characters alone is one stretch of no script, shaped by
//! what a font lists as `DFLT`.
//!
//! Each stretch is first made the characters the font draws it with
//! (`_normal.zig`): a character the font lacks taken apart, a
//! character's marks put in order, and a character and a mark put
//! together where the font has the two as one. Then it gets a buffer of
//! its own, a glyph for each of those characters; a character with a
//! variation selector behind it is the glyph the font has for the two,
//! where it has one, and the selector then is part of that glyph's
//! cluster. A glyph's cluster is the place in the text of the first
//! byte it came from.
//!
//! The features are the ones a text is shaped with unless told otherwise
//! (`defaults`, and two more by the direction), and behind them the
//! caller's. One of the defaults is left out where the caller's list
//! says something of its tag for the whole text.
//!
//! A stretch of a script with a model (`_indic.zig`) is shaped by its
//! syllables, unless the font's `GSUB` is read for it under a tag made
//! for no script in particular. Its features are the model's besides,
//! without the one the model never applies; its characters carry what
//! they are in a syllable (`_syllable.zig`) into the buffer, and are
//! taken apart by the model's rule (`List.model`). The model is told
//! whether the stretch before ended within a word (`Order.after_letter`):
//! the form of a word's first vowel sign depends on it.
//!
//! The stretches follow each other in the answer as they are drawn: from
//! the first to the last, or from the last to the first in a text read
//! from right to left.

const sdk = @import("sdk");
const utf8 = sdk.utility.utf8;
const truetypeshaping = sdk.truetypeshaping;
const Feature = truetypeshaping.Feature;
const ShapedGlyph = truetypeshaping.ShapedGlyph;
const ShapedRun = truetypeshaping.ShapedRun;
const _buffer = @import("_buffer.zig");
const Memory = _buffer.Memory;
const _shape = @import("_shape.zig");
const _scripts = @import("_scripts.zig");
const _normal = @import("_normal.zig");
const _plan = @import("_plan.zig");
const _indic = @import("_indic.zig");
const _syllable = @import("_syllable.zig");

const featureTag = truetypeshaping.featureTag;

/// The features a text is shaped with: the glyphs a variable font draws
/// instead; marks above and below; characters composed and taken apart;
/// the forms of a language; ligatures a script requires, those of its
/// context and the usual ones; forms by context; marks set on glyphs and
/// on marks; joined writing; distances; kerning.
const defaults = [_]u32{
    featureTag("rvrn"), featureTag("abvm"), featureTag("blwm"), featureTag("ccmp"),
    featureTag("locl"), featureTag("mark"), featureTag("mkmk"), featureTag("rlig"),
    featureTag("calt"), featureTag("clig"), featureTag("curs"), featureTag("dist"),
    featureTag("kern"), featureTag("liga"), featureTag("rclt"),
};

/// And by the way the text is read: its alternates and mirrored forms.
const forward = [_]u32{ featureTag("ltra"), featureTag("ltrm") };
const backward = [_]u32{ featureTag("rtla"), featureTag("rtlm") };

/// What a call asks for.
pub const Text = struct {
    memory: Memory,
    font: _shape.Font,
    bytes: []const u8,
    /// The text is read from right to left.
    backward: bool = false,
    language: u32 = 0,
    /// The caller's features.
    features: []const Feature = &.{},
};

/// A stretch of one script.
const Stretch = struct {
    end: usize,
    script: u8,
    chars: u32,
    /// Its last character.
    last: u32,
};

/// The stretch of one script that starts at `start`.
fn stretchAt(bytes: []const u8, start: usize) Stretch {
    var at = start;
    var script: u8 = _scripts.common;
    var chars: u32 = 0;
    var last: u32 = 0;
    while (at < bytes.len) {
        const read = utf8.read(bytes[at..]);
        const its = _scripts.scriptOf(read.char);
        if (its != _scripts.common and its != _scripts.inherited) {
            if (script == _scripts.common) {
                script = its;
            } else if (its != script) {
                break;
            }
        }
        at += read.length;
        chars += 1;
        last = read.char;
    }
    return .{ .end = at, .script = script, .chars = chars, .last = last };
}

/// Whether the caller's list says something of `tag` for the whole text.
fn named(features: []const Feature, tag: u32) bool {
    for (features) |feature| {
        if (feature.tag == tag and feature.first == 0 and feature.last == 0xFFFF_FFFF) return true;
    }
    return false;
}

/// A list of features and how many of its first are not the caller's.
const Merged = struct {
    features: []const Feature,
    own: u32,
};

/// Writes the features the text is shaped with to `merged`: the defaults
/// the caller's list leaves standing, then the caller's. With
/// `by_model`, the list of a stretch a script's model shapes: the
/// model's features are defaults too, and the one it never applies is
/// left out, the caller's as well.
fn merge(text: *const Text, merged: []Feature, by_model: bool) Merged {
    var count: u32 = 0;
    const by_direction = if (text.backward) &backward else &forward;
    const of_model: []const u32 = if (by_model) &_indic.own_tags else &.{};
    for ([_][]const u32{ &defaults, by_direction, of_model }) |tags| {
        for (tags) |tag| {
            if (by_model and tag == _indic.left_out) continue;
            if (named(text.features, tag)) continue;
            merged[count] = .{ .tag = tag };
            count += 1;
        }
    }
    const own = count;
    for (text.features) |feature| {
        if (by_model and feature.tag == _indic.left_out) continue;
        merged[count] = feature;
        count += 1;
    }
    return .{ .features = merged[0..count], .own = own };
}

/// Whether a character counts as part of a word: a letter, a mark, or
/// one that is not drawn.
fn inWord(char: u32) bool {
    return switch (sdk.utility.unicode.class(char)) {
        .unassigned, .format, .private, .upper, .lower, .title, .letter, .mark => true,
        else => false,
    };
}

/// Fills `buffer` with the glyphs of the stretch's characters in
/// `list`. The buffer was made with the room.
fn fill(list: *const _normal.List, buffer: *_buffer.Buffer) void {
    for (list.slice()) |entry| {
        const hidden: u8 = if (entry.hidden) _buffer.ITEM_HIDDEN else 0;
        var item: _buffer.Item = .{
            .glyph = entry.glyph,
            .cluster = entry.cluster,
            .mask = 0,
            .class = _scripts.classOf(entry.char),
            .flags = _scripts.flagsOf(entry.char) | hidden,
            .space = entry.space,
        };
        if (list.model) {
            // What the model goes by: the character's part in a
            // syllable, and whether a word goes on through it.
            const kind = _syllable.kindOf(entry.char);
            item.category = kind.category;
            item.position = kind.position;
            if (inWord(entry.char)) item.flags |= _buffer.ITEM_LETTER;
        }
        buffer.append(item);
    }
}

/// Shapes `text` into `run`, whose `glyphs` has room for `room` of them.
/// Answers `TTS_OK` with the shaped glyphs in the order they are drawn
/// and their number in `count`; `TTSERR_ROOM` with the number there
/// would be; or another of the `TTSERR_` numbers, with `count` as it
/// was.
pub fn shapeText(text: *const Text, run: *ShapedRun) i32 {
    const memory = text.memory;
    // Two lists: the one of any stretch, and the one of a stretch a
    // script's model shapes.
    const room = defaults.len + forward.len + _indic.own_tags.len + text.features.len;
    const block = memory.alloc(2 * room * @sizeOf(Feature)) orelse return truetypeshaping.TTSERR_NOMEM;
    defer memory.free(block);
    const merged_block: [*]Feature = @ptrCast(@alignCast(block));
    const merged = merge(text, merged_block[0..room], false);
    const for_model = merge(text, merged_block[room .. 2 * room], true);

    var order: _shape.Order = .{
        .memory = memory,
        .font = text.font,
        .language = text.language,
        .backward = text.backward,
        .features = merged.features,
        .text = true,
        .unturned = true,
    };
    const shaped = run.glyphs[0..run.room];
    var count: u32 = 0;
    var start: usize = 0;
    var after_letter = false;
    while (start < text.bytes.len) {
        const stretch = stretchAt(text.bytes, start);
        const tags = _scripts.tagsOf(stretch.script);
        order.script = tags.first;
        order.other_script = tags.other;
        // A font made for no script in particular is not the model's.
        var by_model = false;
        if (_indic.ofScript(tags.first)) {
            const layout = _plan.Layout.init(text.font.gsub, tags.first, tags.other, text.language, text.font.coords);
            by_model = _indic.chosen(layout.script);
        }
        const its = if (by_model) for_model else merged;
        order.features = its.features;
        order.own = its.own;
        order.model = by_model;
        order.after_letter = after_letter;
        after_letter = inWord(stretch.last);
        var list = _normal.List.init(memory, &text.font, stretch.chars) orelse return truetypeshaping.TTSERR_NOMEM;
        defer list.deinit();
        list.model = by_model;
        list.fill(text.bytes, start, stretch.end);
        if (list.failed) return truetypeshaping.TTSERR_NOMEM;
        var buffer = _buffer.Buffer.init(memory, list.len) orelse return truetypeshaping.TTSERR_NOMEM;
        defer buffer.deinit();
        fill(&list, &buffer);
        const result = _shape.shape(&order, &buffer);
        if (result != truetypeshaping.TTS_OK) return result;
        for (buffer.slice()) |item| {
            if (count < shaped.len) {
                shaped[count] = .{
                    .glyph = item.glyph,
                    .cluster = item.cluster,
                    .advance = item.advance,
                    .x_offset = item.x_offset,
                    .y_offset = item.y_offset,
                };
            }
            count +|= 1;
        }
        start = stretch.end;
    }
    run.count = count;
    if (count > shaped.len) return truetypeshaping.TTSERR_ROOM;
    if (text.backward and count > 1) {
        var low: usize = 0;
        var high: usize = count - 1;
        while (low < high) : ({
            low += 1;
            high -= 1;
        }) {
            const kept = shaped[low];
            shaped[low] = shaped[high];
            shaped[high] = kept;
        }
    }
    return truetypeshaping.TTS_OK;
}
