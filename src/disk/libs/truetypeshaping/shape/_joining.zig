// SPDX-License-Identifier: MIT
//! The joining model: the forms the letters of Arabic and of the other
//! scripts whose letters join take, and the goes through `GSUB` that
//! apply them.
//!
//! **The forms.** Each character has a joining type
//! (`_joining_table.zig`): it joins on both sides, only to the
//! character before it, only to the one after, makes those round it
//! join (the tatweel, the zero width joiner), is passed over (a mark),
//! or joins none. A letter joins its neighbour where both are willing
//! on the side they share, the marks between them passed over; it then
//! takes the form for where it stands in the join: alone (`isol`), at
//! its end (`fina`), in its middle (`medi`) or at its start (`init`).
//! Syriac's Alaph and its Dalath and Rish have three forms of their own
//! by what stands before them (`fin2`, `fin3`, `med2`). The forms are
//! found by the state table Unicode's chapter on Arabic describes, one
//! state for what the letter before is willing to do; a character a
//! stretch starts with has none before it, one it ends with none after.
//!
//! The forms are the bits of `Item.forms`, and each form's feature
//! holds for the items with its bit and no others (`plan`).
//!
//! **The goes.** The features are applied in goes, every lookup of one
//! go before any of the next, a go's lookups in the order the font
//! lists them: the variations; the forms by direction and the
//! fractions; the stretching glyphs (`stch`); the composed characters
//! and the forms of the language; each joining form a go of its own, in
//! the order above; the ligatures the script requires; in Arabic the
//! presentation forms (`_forms.zig`) and then the forms by context, in
//! the other scripts the forms by context with the required ligatures;
//! and the rest. So a form is chosen before the ligatures that are made
//! of forms, whatever order a font's lookups are in.
//!
//! **The stretch.** A character drawn across the word behind it -
//! Syriac's abbreviation mark (U+070F) - is made a sequence of pieces by
//! the font's `stch` lookup: those of an even place in it drawn once,
//! those of an odd place repeated. Once the glyphs have their places
//! (`stretch`), the pieces are repeated as often as fills the width of
//! the word behind - its letters of no case, marks, numbers and symbols
//! (`wordOf`) - and drawn over that word, taking no advance of their
//! own: the pieces repeated once more and pushed together where that
//! fits better than a gap, the whole in the middle of the word, and no
//! stretch of more than 256 glyphs.

const sdk = @import("sdk");
const featureTag = sdk.truetypeshaping.featureTag;
const _plan = @import("_plan.zig");
const _buffer = @import("_buffer.zig");
const _table = @import("_joining_table.zig");
const Font = @import("_shape.zig").Font;
const Wanted = _plan.Wanted;
const Buffer = _buffer.Buffer;

/// The forms, the bits of `Item.forms`.
pub const FORM_ISOL: u8 = 0x01;
pub const FORM_FINA: u8 = 0x02;
pub const FORM_FIN2: u8 = 0x04;
pub const FORM_FIN3: u8 = 0x08;
pub const FORM_MEDI: u8 = 0x10;
pub const FORM_MED2: u8 = 0x20;
pub const FORM_INIT: u8 = 0x40;

/// The goes, in the order they are applied.
pub const GO_VARIATIONS: u8 = 0;
pub const GO_DIRECTION: u8 = 1;
pub const GO_STRETCH: u8 = 2;
pub const GO_LANGUAGE: u8 = 3;
/// The joining forms, a go each from here on, in `forms`' order.
pub const GO_FORMS: u8 = 4;
pub const GO_REQUIRED: u8 = GO_FORMS + forms.len;
/// The forms by context: in Arabic a go after the presentation forms
/// (`_forms.zig`), elsewhere with the ligatures the script requires.
pub const GO_CONTEXT: u8 = GO_REQUIRED + 1;
pub const GO_REST: u8 = GO_CONTEXT + 1;
pub const go_count: u8 = GO_REST + 1;

const Form = struct { tag: u32, form: u8 };

/// The joining forms' features, in the order of their goes.
const forms = [_]Form{
    .{ .tag = featureTag("isol"), .form = FORM_ISOL },
    .{ .tag = featureTag("fina"), .form = FORM_FINA },
    .{ .tag = featureTag("fin2"), .form = FORM_FIN2 },
    .{ .tag = featureTag("fin3"), .form = FORM_FIN3 },
    .{ .tag = featureTag("medi"), .form = FORM_MEDI },
    .{ .tag = featureTag("med2"), .form = FORM_MED2 },
    .{ .tag = featureTag("init"), .form = FORM_INIT },
};

/// The features the model adds to a text's: the joining forms, and the
/// stretching glyphs.
pub const own_tags: [forms.len + 1]u32 = made: {
    var tags: [forms.len + 1]u32 = undefined;
    for (tags[0..forms.len], forms) |*tag, form| tag.* = form.tag;
    tags[forms.len] = featureTag("stch");
    break :made tags;
};

/// What a glyph is of a stretch (`Item.stretch`), in the low bits: none;
/// one that was already made of another before `stch`'s go, and is none;
/// a piece drawn once; a piece repeated. And `STRETCH_WORD` on a glyph a
/// stretch is drawn over (`wordOf`).
const STRETCH_NONE: u8 = 0;
const STRETCH_BEFORE: u8 = 1;
const STRETCH_ONCE: u8 = 2;
const STRETCH_REPEATED: u8 = 3;
const STRETCH_KIND: u8 = 0x03;
pub const STRETCH_WORD: u8 = 0x80;

/// The most glyphs a stretch is drawn with, its pieces and their
/// repeats: a thin piece over a wide word stays a line of some hundred
/// glyphs.
const stretch_glyphs = 256;

/// `STRETCH_WORD` for a character a stretch is drawn over, 0 for any
/// other: a letter of no case, a mark, a number, a symbol, one of no
/// character or for private use.
pub fn wordOf(char: u32) u8 {
    return switch (sdk.utility.unicode.class(char)) {
        .unassigned, .private, .letter, .mark, .digit, .number, .symbol => STRETCH_WORD,
        else => 0,
    };
}

/// The features of the goes before and after the forms.
const early = [_]struct { tag: u32, go: u8 }{
    .{ .tag = featureTag("rvrn"), .go = GO_VARIATIONS },
    .{ .tag = featureTag("ltra"), .go = GO_DIRECTION },
    .{ .tag = featureTag("ltrm"), .go = GO_DIRECTION },
    .{ .tag = featureTag("rtla"), .go = GO_DIRECTION },
    .{ .tag = featureTag("rtlm"), .go = GO_DIRECTION },
    .{ .tag = featureTag("frac"), .go = GO_DIRECTION },
    .{ .tag = featureTag("numr"), .go = GO_DIRECTION },
    .{ .tag = featureTag("dnom"), .go = GO_DIRECTION },
    .{ .tag = featureTag("stch"), .go = GO_STRETCH },
    .{ .tag = featureTag("ccmp"), .go = GO_LANGUAGE },
    .{ .tag = featureTag("locl"), .go = GO_LANGUAGE },
    .{ .tag = featureTag("rlig"), .go = GO_REQUIRED },
    .{ .tag = featureTag("rclt"), .go = GO_CONTEXT },
    .{ .tag = featureTag("calt"), .go = GO_CONTEXT },
};

/// The scripts whose letters join, by the first tag fonts list them
/// under: those whose characters ArabicShaping.txt gives a type.
const scripts = [_]u32{
    featureTag("arab"), featureTag("syrc"), featureTag("mong"), featureTag("nko "),
    featureTag("phag"), featureTag("mand"), featureTag("mani"), featureTag("phlp"),
    featureTag("adlm"), featureTag("rohg"), featureTag("sogd"), featureTag("ougr"),
    featureTag("chrs"),
};

/// Whether a script, by the first tag fonts list it under, is one whose
/// letters join.
pub fn ofScript(first: u32) bool {
    for (scripts) |script| {
        if (script == first) return true;
    }
    return false;
}

/// How `char` joins its neighbours: one of `_joining_table`'s types.
pub fn typeOf(char: u32) u8 {
    const starts = &_table.starts;
    var low: usize = 0;
    var high: usize = starts.len;
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (starts[middle] >> 8 <= char) low = middle else high = middle;
    }
    return @truncate(starts[low]);
}

/// Gives each of `wanted` its go, in a text of the script tagged
/// `script`. The first `own` are the model's and the text's defaults: a
/// joining form of them holds for the items of its form and no others.
pub fn plan(wanted: []Wanted, own: usize, script: u32) void {
    for (wanted, 0..) |*want, index| {
        want.go = GO_REST;
        for (early) |entry| {
            if (entry.tag == want.tag) want.go = entry.go;
        }
        if (want.go == GO_CONTEXT and script != featureTag("arab")) want.go = GO_REQUIRED;
        for (forms, 0..) |form, place| {
            if (form.tag != want.tag) continue;
            want.go = GO_FORMS + @as(u8, @intCast(place));
            if (index < own) {
                want.mask = 0;
                want.forms = form.form;
            }
        }
    }
}

/// Sorts `wanted` by go, those of one go keeping their order.
pub fn inGoes(wanted: []Wanted) void {
    for (wanted, 0..) |want, index| {
        var place = index;
        while (place > 0 and wanted[place - 1].go > want.go) : (place -= 1) wanted[place] = wanted[place - 1];
        wanted[place] = want;
    }
}

/// What a state does with a letter of a type: the form the letter
/// before it gets (0: it keeps its own), the letter's own form, and the
/// next state.
const Step = struct { before: u8, own: u8, next: u8 };

/// The table's columns: joining none, on the left, on the right, on
/// both sides, Alaph, Dalath and Rish.
fn columnOf(kind: u8) usize {
    return switch (kind) {
        _table.left => 1,
        _table.right => 2,
        _table.dual, _table.causing => 3,
        _table.alaph => 4,
        _table.dalath_rish => 5,
        else => 0,
    };
}

fn step(before: u8, own: u8, next: u8) Step {
    return .{ .before = before, .own = own, .next = next };
}

/// The states: 0, the letter before joins none; 1, it joins none on
/// this side (one joining on the right, or Alaph alone); 2, it stands
/// alone and is willing to join; 3, it ends a join and is willing to go
/// on; 4, an Alaph ending a join; 5, an Alaph of `fin2` or `fin3`; 6, a
/// Dalath or a Rish.
const states = [7][6]Step{
    .{ step(0, 0, 0), step(0, FORM_ISOL, 2), step(0, FORM_ISOL, 1), step(0, FORM_ISOL, 2), step(0, FORM_ISOL, 1), step(0, FORM_ISOL, 6) },
    .{ step(0, 0, 0), step(0, FORM_ISOL, 2), step(0, FORM_ISOL, 1), step(0, FORM_ISOL, 2), step(0, FORM_FIN2, 5), step(0, FORM_ISOL, 6) },
    .{ step(0, 0, 0), step(0, FORM_ISOL, 2), step(FORM_INIT, FORM_FINA, 1), step(FORM_INIT, FORM_FINA, 3), step(FORM_INIT, FORM_FINA, 4), step(FORM_INIT, FORM_FINA, 6) },
    .{ step(0, 0, 0), step(0, FORM_ISOL, 2), step(FORM_MEDI, FORM_FINA, 1), step(FORM_MEDI, FORM_FINA, 3), step(FORM_MEDI, FORM_FINA, 4), step(FORM_MEDI, FORM_FINA, 6) },
    .{ step(0, 0, 0), step(0, FORM_ISOL, 2), step(FORM_MED2, FORM_ISOL, 1), step(FORM_MED2, FORM_ISOL, 2), step(FORM_MED2, FORM_FIN2, 5), step(FORM_MED2, FORM_ISOL, 6) },
    .{ step(0, 0, 0), step(0, FORM_ISOL, 2), step(FORM_ISOL, FORM_ISOL, 1), step(FORM_ISOL, FORM_ISOL, 2), step(FORM_ISOL, FORM_FIN2, 5), step(FORM_ISOL, FORM_ISOL, 6) },
    .{ step(0, 0, 0), step(0, FORM_ISOL, 2), step(0, FORM_ISOL, 1), step(0, FORM_ISOL, 2), step(0, FORM_FIN3, 5), step(0, FORM_ISOL, 6) },
};

/// The forms of a stretch's letters, found one character after another
/// in the order they are read.
pub const State = struct {
    state: u8 = 0,
    /// The place of the last character that was not passed over.
    before: ?usize = null,

    /// Gives `items[index]`, the item of the character `char`, its form,
    /// and the letter before it the form it takes by it.
    pub fn next(state: *State, char: u32, items: []_buffer.Item, index: usize) void {
        const item = &items[index];
        item.forms = 0;
        const kind = typeOf(char);
        if (kind == _table.transparent) return;
        const taken = states[state.state][columnOf(kind)];
        if (taken.before != 0) {
            if (state.before) |place| items[place].forms = taken.before;
        }
        item.forms = taken.own;
        state.before = index;
        state.state = taken.next;
    }
};

/// Before `stch`'s go: the glyphs already made of another are told from
/// those its lookups will make.
pub fn beforeStretch(buffer: *Buffer) void {
    for (buffer.slice()) |*item| {
        const kind = if (item.flags & _buffer.ITEM_MULTIPLIED != 0) STRETCH_BEFORE else STRETCH_NONE;
        item.stretch = (item.stretch & STRETCH_WORD) | kind;
    }
}

/// After it: each glyph its lookups made of another is a piece, drawn
/// once at an even place of its sequence and repeated at an odd one.
pub fn afterStretch(buffer: *Buffer) void {
    for (buffer.slice()) |*item| {
        const kind = if (item.stretch & STRETCH_KIND == STRETCH_BEFORE or item.flags & _buffer.ITEM_MULTIPLIED == 0)
            STRETCH_NONE
        else if (item.part % 2 == 1) STRETCH_REPEATED else STRETCH_ONCE;
        item.stretch = (item.stretch & STRETCH_WORD) | kind;
    }
}

fn kindOf(item: *const _buffer.Item) u8 {
    return item.stretch & STRETCH_KIND;
}

fn isPiece(item: *const _buffer.Item) bool {
    return kindOf(item) == STRETCH_ONCE or kindOf(item) == STRETCH_REPEATED;
}

/// Whether a glyph is of the word a stretch is drawn over (`wordOf`).
fn inWord(item: *const _buffer.Item) bool {
    return !isPiece(item) and item.stretch & STRETCH_WORD != 0;
}

/// The pieces of each stretch repeated to the width of the word behind
/// them and drawn over it, once the glyphs have their places and before
/// the run is turned to the order it is drawn in; `backward` for a run
/// read from right to left, in which the word behind is drawn left of
/// the stretch. A stretch whose repeats the run has no room for is left
/// as the font made it.
pub fn stretch(font: *const Font, buffer: *Buffer, backward: bool) void {
    var start: u32 = 0;
    while (start < buffer.len) {
        if (!isPiece(&buffer.items[start])) {
            start += 1;
            continue;
        }
        var end = start;
        var once_width: i64 = 0;
        var repeated_width: i64 = 0;
        var repeated_count: i64 = 0;
        while (end < buffer.len and isPiece(&buffer.items[end])) : (end += 1) {
            const item = &buffer.items[end];
            const width = font.advanceFn(font.context, item.glyph);
            if (kindOf(item) == STRETCH_REPEATED) {
                repeated_width += width;
                repeated_count += 1;
            } else once_width += width;
        }
        var word_width: i64 = 0;
        var behind = end;
        while (behind < buffer.len and inWord(&buffer.items[behind])) : (behind += 1) word_width += buffer.items[behind].advance;

        // How many more times each repeated piece is drawn, how much two
        // of them overlap, and what of the word they leave uncovered.
        var copies: i64 = 0;
        const remaining = word_width - once_width;
        if (remaining > repeated_width and repeated_width > 0) copies = @divTrunc(remaining, repeated_width) - 1;
        var overlap: i64 = 0;
        var margin = remaining - repeated_width * (copies + 1);
        if (margin > 0 and repeated_count > 0) {
            copies += 1;
            const excess = (copies + 1) * repeated_width - remaining;
            if (excess > 0) {
                overlap = @divTrunc(excess, copies * repeated_count);
                margin = 0;
            }
        }
        const pieces: i64 = end - start;
        const most: i64 = if (repeated_count > 0 and pieces < stretch_glyphs) @divTrunc(stretch_glyphs - pieces, repeated_count) else 0;
        copies = @min(copies, most);

        const added: u64 = @intCast(copies * repeated_count);
        if (added > buffer.limit or buffer.len > buffer.limit - added) {
            start = end;
            continue;
        }
        // From where the stretch is, half the margin into the word.
        const half: i32 = @intCast(@max(-0x4000_0000, @min(0x4000_0000, @divTrunc(margin, 2))));
        const pushed: i32 = @intCast(@min(0x4000_0000, overlap));
        var x_offset: i32 = if (backward) -half else half;
        var at = start;
        var left = end - start;
        while (left > 0) : (left -= 1) {
            const width = font.advanceFn(font.context, buffer.items[at].glyph);
            const repeat: u32 = if (kindOf(&buffer.items[at]) == STRETCH_REPEATED) @intCast(1 + copies) else 1;
            if (repeat > 1 and !buffer.replace(at, 1, repeat)) return;
            for (buffer.items[at..][0..repeat], 0..) |*copy, count| {
                copy.advance = 0;
                copy.stretch = STRETCH_NONE;
                if (backward) {
                    x_offset -|= width;
                    if (count > 0) x_offset +|= pushed;
                }
                copy.x_offset = x_offset;
                if (!backward) {
                    x_offset +|= width;
                    if (count > 0) x_offset -|= pushed;
                }
            }
            at += repeat;
        }
        start = at;
    }
}
