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
//! Each stretch gets a buffer of its own. A character becomes one glyph,
//! and a character with a variation selector behind it the glyph the
//! font has for the two, where it has one; the selector then is part of
//! that glyph's cluster. A glyph's cluster is the place in the text of
//! the first byte it came from.
//!
//! The features are the ones a text is shaped with unless told otherwise
//! (`defaults`, and two more by the direction), and behind them the
//! caller's. One of the defaults is left out where the caller's list
//! says something of its tag for the whole text.
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
};

/// The stretch of one script that starts at `start`.
fn stretchAt(bytes: []const u8, start: usize) Stretch {
    var at = start;
    var script: u8 = _scripts.common;
    var chars: u32 = 0;
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
    }
    return .{ .end = at, .script = script, .chars = chars };
}

/// Whether the caller's list says something of `tag` for the whole text.
fn named(features: []const Feature, tag: u32) bool {
    for (features) |feature| {
        if (feature.tag == tag and feature.first == 0 and feature.last == 0xFFFF_FFFF) return true;
    }
    return false;
}

/// Writes the features the text is shaped with to `merged`: the defaults
/// the caller's list leaves standing, then the caller's. Answers how
/// many.
fn merge(text: *const Text, merged: []Feature) usize {
    var count: usize = 0;
    const by_direction = if (text.backward) &backward else &forward;
    for ([_][]const u32{ &defaults, by_direction }) |tags| {
        for (tags) |tag| {
            if (named(text.features, tag)) continue;
            merged[count] = .{ .tag = tag };
            count += 1;
        }
    }
    for (text.features) |feature| {
        merged[count] = feature;
        count += 1;
    }
    return count;
}

/// Fills `buffer` with the glyphs of the characters of `text` from
/// `start` up to `end`.
fn fill(text: *const Text, start: usize, end: usize, buffer: *_buffer.Buffer) void {
    const font = &text.font;
    const bytes = text.bytes;
    var at = start;
    while (at < end) {
        const read = utf8.read(bytes[at..end]);
        var item: _buffer.Item = .{
            .glyph = 0,
            .cluster = @intCast(at),
            .mask = 0,
            .class = _scripts.classOf(read.char),
            .flags = _scripts.flagsOf(read.char),
        };
        at += read.length;
        if (at < end) {
            const behind = utf8.read(bytes[at..end]);
            if (_scripts.selects(behind.char)) {
                if (font.variantFn) |variantFn| item.glyph = variantFn(font.context, read.char, behind.char);
                if (item.glyph != 0) at += behind.length;
            }
        }
        if (item.glyph == 0) {
            if (font.glyphFn) |glyphFn| item.glyph = glyphFn(font.context, read.char);
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
    const room = defaults.len + forward.len + text.features.len;
    const block = memory.alloc(room * @sizeOf(Feature)) orelse return truetypeshaping.TTSERR_NOMEM;
    defer memory.free(block);
    const merged_block: [*]Feature = @ptrCast(@alignCast(block));
    const merged = merged_block[0..merge(text, merged_block[0..room])];

    var order: _shape.Order = .{
        .memory = memory,
        .font = text.font,
        .language = text.language,
        .backward = text.backward,
        .features = merged,
        .text = true,
        .unturned = true,
    };
    const shaped = run.glyphs[0..run.room];
    var count: u32 = 0;
    var start: usize = 0;
    while (start < text.bytes.len) {
        const stretch = stretchAt(text.bytes, start);
        const tags = _scripts.tagsOf(stretch.script);
        order.script = tags.first;
        order.other_script = tags.other;
        var buffer = _buffer.Buffer.init(memory, stretch.chars) orelse return truetypeshaping.TTSERR_NOMEM;
        defer buffer.deinit();
        fill(text, start, stretch.end, &buffer);
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
