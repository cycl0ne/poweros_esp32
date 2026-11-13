// SPDX-License-Identifier: MIT
//! The model of Devanagari: which forms the glyphs of a syllable take,
//! and the order they are drawn in.
//!
//! A syllable is written around its base, the consonant the others
//! lean on. The consonants before it stand as half forms, those behind
//! it below or behind; a ra with a halant at the syllable's start is
//! the reph, drawn above its end; the vowel sign that is written to the
//! left is spoken after the consonants it stands before. A font has the
//! forms as features of `GSUB`, and expects them asked for in a fixed
//! order, each for the glyphs it is meant for, with the glyphs in the
//! order it was made for. That is the work here, between the goes
//! through `GSUB` that `_shape.zig` makes:
//!
//!     rvrn                        the required feature with it
//!     ltra ltrm (rtla rtlm)
//!       - the syllables are numbered (`_syllable.zig`)
//!     locl ccmp
//!       - `arrange`: the base found, the syllable sorted by position,
//!         the forms marked
//!     nukt akhn rphf rkrf pref blwf abvf half pstf vatu cjct
//!                                 a go each
//!       - `finish`: the vowel sign before the base and the reph moved
//!         to where they are drawn
//!     init pres abvs blws psts haln, and all other features
//!
//! Up to `finish` a lookup's sequence stays within one syllable, and
//! the joiners are skipped only where the model says (`Apply.by_hand`).
//! `liga` is never applied: the script's ligatures are the conjuncts
//! above.
//!
//! **What the font decides.** Whether a consonant goes below or behind
//! the base is not in the character: it is asked of the font, as
//! whether `blwf`, `vatu`, `pstf` or `pref` have a rule for the
//! consonant with the halant (`Layout.wouldReplace`). In the same way a
//! ra and a halant are a reph only where `rphf` has a rule for the two.
//! A font whose script is listed under the older tag (`deva`, any tag
//! not ending in "2" or "3") was made for the halant behind the consonant it
//! joins, not before: for it the halant after the base is moved behind
//! the last consonant, a ra with a halant before the base takes its
//! form below, and rules count that ask for glyphs around.
//!
//! **Forms.** `rphf`, `pref`, `blwf`, `abvf`, `half`, `pstf` and `init`
//! hold only for the items marked for them (`Item.forms`), the others
//! for every glyph. A feature the font lacks, or the caller switched
//! off for the whole text, takes its part of the model with it: no
//! reph is looked for without `rphf`.

const sdk = @import("sdk");
const featureTag = sdk.truetypeshaping.featureTag;
const Feature = sdk.truetypeshaping.Feature;
const _buffer = @import("_buffer.zig");
const Buffer = _buffer.Buffer;
const Item = _buffer.Item;
const _plan = @import("_plan.zig");
const Layout = _plan.Layout;
const Wanted = _plan.Wanted;
const syl = @import("_syllable.zig");

/// The goes through `GSUB`, in order. The forms from `nukt` to `cjct`
/// are a go each, from `GO_FORMS` on.
pub const GO_VARIATIONS: u8 = 0;
pub const GO_DIRECTION: u8 = 1;
pub const GO_LANGUAGE: u8 = 2;
pub const GO_FORMS: u8 = 3;
pub const GO_REST: u8 = 14;
pub const go_count = 15;

/// What the model says of a feature: its go, the form whose items it
/// holds for (0: every glyph), whether its sequences stay in a syllable
/// and whether the joiners are the model's.
const Shape = struct {
    tag: u32,
    go: u8,
    form: u8 = 0,
    per_syllable: bool = true,
    by_hand: bool = true,
};

const rphf = featureTag("rphf");
const pref = featureTag("pref");
const blwf = featureTag("blwf");
const pstf = featureTag("pstf");
const vatu = featureTag("vatu");
const half = featureTag("half");

const shapes = [_]Shape{
    .{ .tag = featureTag("rvrn"), .go = GO_VARIATIONS, .per_syllable = false, .by_hand = false },
    .{ .tag = featureTag("ltra"), .go = GO_DIRECTION, .per_syllable = false, .by_hand = false },
    .{ .tag = featureTag("ltrm"), .go = GO_DIRECTION, .per_syllable = false, .by_hand = false },
    .{ .tag = featureTag("rtla"), .go = GO_DIRECTION, .per_syllable = false, .by_hand = false },
    .{ .tag = featureTag("rtlm"), .go = GO_DIRECTION, .per_syllable = false, .by_hand = false },
    .{ .tag = featureTag("locl"), .go = GO_LANGUAGE, .by_hand = false },
    .{ .tag = featureTag("ccmp"), .go = GO_LANGUAGE, .by_hand = false },
    .{ .tag = featureTag("nukt"), .go = GO_FORMS },
    .{ .tag = featureTag("akhn"), .go = GO_FORMS + 1 },
    .{ .tag = rphf, .go = GO_FORMS + 2, .form = syl.FORM_REPH },
    .{ .tag = featureTag("rkrf"), .go = GO_FORMS + 3 },
    .{ .tag = pref, .go = GO_FORMS + 4, .form = syl.FORM_PRE_BASE },
    .{ .tag = blwf, .go = GO_FORMS + 5, .form = syl.FORM_BELOW },
    .{ .tag = featureTag("abvf"), .go = GO_FORMS + 6, .form = syl.FORM_ABOVE },
    .{ .tag = half, .go = GO_FORMS + 7, .form = syl.FORM_HALF },
    .{ .tag = pstf, .go = GO_FORMS + 8, .form = syl.FORM_POST },
    .{ .tag = vatu, .go = GO_FORMS + 9 },
    .{ .tag = featureTag("cjct"), .go = GO_FORMS + 10 },
    .{ .tag = featureTag("init"), .go = GO_REST, .form = syl.FORM_INITIAL },
    .{ .tag = featureTag("pres"), .go = GO_REST },
    .{ .tag = featureTag("abvs"), .go = GO_REST },
    .{ .tag = featureTag("blws"), .go = GO_REST },
    .{ .tag = featureTag("psts"), .go = GO_REST },
    .{ .tag = featureTag("haln"), .go = GO_REST },
};

/// The features the model asks for itself, from `nukt` on: the ones
/// before are asked for of any text.
pub const own_tags: [17]u32 = made: {
    var tags: [17]u32 = undefined;
    for (&tags, shapes[7..]) |*tag, shape| tag.* = shape.tag;
    break :made tags;
};

/// The halant, the sign that takes a consonant's vowel away and joins
/// it to the next.
pub const halant: u32 = 0x094D;

/// The feature the model never applies.
pub const left_out = featureTag("liga");

/// Whether a script, by the first tag fonts list it under, is one the
/// model shapes.
pub fn ofScript(first: u32) bool {
    return first == featureTag("dev2");
}

/// Whether a font whose `GSUB` is read for the script tagged `script`
/// is shaped by the model: one made for no script in particular is
/// not.
pub fn chosen(script: u32) bool {
    return script != featureTag("DFLT") and script != featureTag("latn");
}

/// Gives each of `wanted` its go and what the model says of its
/// feature; one the model does not know is of the last go, like in any
/// text. The first `own` are the model's: those for a form hold for
/// the items marked and no others.
pub fn plan(wanted: []Wanted, own: usize) void {
    for (wanted, 0..) |*want, index| {
        want.go = GO_REST;
        for (shapes) |shape| {
            if (shape.tag != want.tag) continue;
            want.go = shape.go;
            want.per_syllable = shape.per_syllable;
            want.by_hand = shape.by_hand;
            if (index < own and shape.form != 0) {
                want.mask = 0;
                want.forms = shape.form;
            }
            break;
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

pub const Model = struct {
    /// The font's `GSUB`, as read for the stretch.
    layout: *const Layout,
    /// The glyph of the halant; 0 where the font has none, and then no
    /// consonant is asked about.
    virama: u32,
    /// The font is of the older kind.
    old: bool,
    /// The features asked of the font that are neither missing nor
    /// switched off.
    reph: bool,
    pre_base: bool,
    below: bool,
    post: bool,
    below_ra: bool,
    /// The caller asked for `pref` for the whole text: every item
    /// counts as marked for it.
    pre_base_all: bool,
    /// The bits of the caller's `half` for parts of the text, which a
    /// non-joiner takes off like the form.
    half_bits: u32,

    /// The model for a font: `layout` its `GSUB`, `features` what is
    /// asked for and `wanted` the same after `plan`, in the same
    /// order, `virama` its glyph for the halant.
    pub fn init(layout: *const Layout, features: []const Feature, wanted: []const Wanted, virama: u32) Model {
        var half_bits: u32 = 0;
        var pre_base_all = false;
        for (wanted) |want| {
            if (want.tag == half and want.mask != _plan.whole_run) half_bits |= want.mask;
            if (want.tag == pref and want.mask == _plan.whole_run) pre_base_all = true;
        }
        return .{
            .layout = layout,
            .virama = virama,
            .old = layout.script & 0xFF != '2' and layout.script & 0xFF != '3',
            .reph = active(layout, features, rphf),
            .pre_base = active(layout, features, pref),
            .below = active(layout, features, blwf),
            .post = active(layout, features, pstf),
            .below_ra = active(layout, features, vatu),
            .pre_base_all = pre_base_all,
            .half_bits = half_bits,
        };
    }

    /// Whether the font has the feature and it is asked for somewhere:
    /// an entry for the whole text says so for all before it, one for
    /// a part only switches it on.
    fn active(layout: *const Layout, features: []const Feature, tag: u32) bool {
        if (!layout.has(tag)) return false;
        var on = false;
        for (features) |feature| {
            if (feature.tag != tag) continue;
            if (feature.first == 0 and feature.last == 0xFFFF_FFFF) {
                on = feature.value != 0;
            } else if (feature.value != 0) {
                on = true;
            }
        }
        return on;
    }

    fn markedPreBase(model: *const Model, item: *const Item) bool {
        return model.pre_base_all or item.forms & syl.FORM_PRE_BASE != 0;
    }

    fn would(model: *const Model, on: bool, tag: u32, glyphs: []const u32) bool {
        return on and model.layout.wouldReplace(tag, glyphs, !model.old);
    }

    /// Where a consonant stands to the base, by what the font has for
    /// it with the halant before or behind.
    fn positionOf(model: *const Model, consonant: u32) u8 {
        const glyphs = [3]u32{ model.virama, consonant, model.virama };
        if (model.would(model.below, blwf, glyphs[0..2]) or model.would(model.below, blwf, glyphs[1..3]) or
            model.would(model.below_ra, vatu, glyphs[0..2]) or model.would(model.below_ra, vatu, glyphs[1..3]))
        {
            return syl.POSITION_BELOW;
        }
        if (model.would(model.post, pstf, glyphs[0..2]) or model.would(model.post, pstf, glyphs[1..3])) return syl.POSITION_POST;
        if (model.would(model.pre_base, pref, glyphs[0..2]) or model.would(model.pre_base, pref, glyphs[1..3])) return syl.POSITION_POST;
        return syl.POSITION_BASE;
    }

    /// Before the forms: every syllable's base found, its items sorted
    /// by where they stand to it, and marked for the forms they may
    /// take. False without the memory.
    pub fn arrange(model: *const Model, buffer: *Buffer) bool {
        const items = buffer.slice();
        if (model.virama != 0) {
            for (items) |*item| {
                if (item.position == syl.POSITION_BASE) item.position = model.positionOf(item.glyph);
            }
        }
        var longest: u32 = 0;
        var start: u32 = 0;
        while (start < items.len) {
            const end = syllableEnd(items, start);
            if (end - start > longest) longest = end - start;
            start = end;
        }
        if (longest == 0) return true;
        const block = buffer.memory.alloc(@as(usize, longest) * @sizeOf(Item)) orelse return false;
        defer buffer.memory.free(block);
        const aside_block: [*]Item = @ptrCast(@alignCast(block));
        const aside = aside_block[0..longest];
        start = 0;
        while (start < items.len) {
            const end = syllableEnd(items, start);
            switch (items[start].syllable & 0x0F) {
                syl.SYLLABLE_CONSONANT, syl.SYLLABLE_VOWEL, syl.SYLLABLE_STANDALONE, syl.SYLLABLE_BROKEN => {
                    model.arrangeSyllable(buffer, start, end, aside);
                },
                else => {},
            }
            start = end;
        }
        return true;
    }

    fn arrangeSyllable(model: *const Model, buffer: *Buffer, start: u32, end: u32, aside: []Item) void {
        const items = buffer.items;

        // A ra and a halant at the start are a reph where the font
        // makes one of them and another consonant follows to carry it.
        var base = end;
        var has_reph = false;
        var limit = start;
        if (model.reph and start + 3 <= end and !isJoiner(&items[start + 2])) {
            const pair = [2]u32{ items[start].glyph, items[start + 1].glyph };
            if (model.would(true, rphf, &pair)) {
                limit += 2;
                while (limit < end and isJoiner(&items[limit])) limit += 1;
                base = start;
                has_reph = true;
            }
        }

        // The base: from the end, the first consonant that has no form
        // below or behind - one behind counts only before one below -
        // or else the first consonant there is.
        var seen_below = false;
        var at = end;
        while (true) {
            at -= 1;
            const item = &items[at];
            if (isConsonant(item)) {
                if (item.position != syl.POSITION_BELOW and (item.position != syl.POSITION_POST or seen_below)) {
                    base = at;
                    break;
                }
                if (item.position == syl.POSITION_BELOW) seen_below = true;
                base = at;
            } else if (start < at and item.category == syl.CATEGORY_JOINER and items[at - 1].category == syl.CATEGORY_HALANT) {
                // A halant with a joiner ends the search: what is
                // before is a half form asked for.
                break;
            }
            if (at <= limit) break;
        }
        if (has_reph and base == start and limit - base <= 2) has_reph = false;

        for (items[start..base]) |*item| item.position = @min(syl.POSITION_PRE_BASE, item.position);
        if (base < end) items[base].position = syl.POSITION_BASE;
        if (has_reph) items[start].position = syl.POSITION_RA_TO_REPH;

        // The older kind of font: the first halant after the base goes
        // behind the last consonant.
        if (model.old) {
            at = base + 1;
            while (at < end) : (at += 1) {
                if (items[at].category != syl.CATEGORY_HALANT) continue;
                var last = end - 1;
                while (last > at and !isConsonant(&items[last])) last -= 1;
                if (items[last].category != syl.CATEGORY_HALANT and last > at) {
                    moveBehind(items, at, last);
                }
                break;
            }
        }

        // Joiners, nuktas and halants go with the item before them.
        var last_position = syl.POSITION_START;
        at = start;
        while (at < end) : (at += 1) {
            const item = &items[at];
            if (syl.bit(item.category) & (syl.joiners | syl.bit(syl.CATEGORY_NUKTA) | syl.bit(syl.CATEGORY_HALANT)) != 0) {
                item.position = last_position;
                if (item.category == syl.CATEGORY_HALANT and item.position == syl.POSITION_PRE_MATRA) {
                    var before = at;
                    while (before > start) : (before -= 1) {
                        if (items[before - 1].position != syl.POSITION_PRE_MATRA) {
                            item.position = items[before - 1].position;
                            break;
                        }
                    }
                }
            } else if (item.position != syl.POSITION_SIGNS) {
                last_position = item.position;
            }
        }

        // A consonant behind the base owns what stands between the
        // consonant or vowel sign before it and itself.
        var last = base;
        at = base + 1;
        while (at < end) : (at += 1) {
            if (isConsonant(&items[at])) {
                for (items[last + 1 .. at]) |*between| {
                    if (between.position < syl.POSITION_SIGNS) between.position = items[at].position;
                }
                last = at;
            } else if (items[at].category == syl.CATEGORY_MATRA) {
                last = at;
            }
        }

        // Sorted by position, each item remembering where it was: the
        // syllable's number makes room for that.
        const kept = items[start].syllable;
        for (items[start..end], 0..) |*item, place| item.syllable = @truncate(place);
        sortByPosition(items[start..end], aside);

        // The base again; and the vowel signs to its left, which the
        // sort left in the order written, are turned to the order
        // drawn: the last written first, each with what hangs on it.
        var first_left = end;
        var last_left = end;
        base = end;
        at = start;
        while (at < end) : (at += 1) {
            if (items[at].position == syl.POSITION_BASE) {
                base = at;
                break;
            }
            if (items[at].position == syl.POSITION_PRE_MATRA) {
                if (first_left == end) first_left = at;
                last_left = at;
            }
        }
        if (first_left < last_left) {
            reverse(items[first_left .. last_left + 1]);
            var from = first_left;
            at = first_left;
            while (at <= last_left) : (at += 1) {
                if (items[at].category != syl.CATEGORY_MATRA) continue;
                reverse(items[from .. at + 1]);
                from = at + 1;
            }
        }

        // What changed places from the base on is one cluster.
        if (model.old or end - start > 127) {
            buffer.mergeClusters(base, end);
        } else {
            at = base;
            while (at < end) : (at += 1) {
                if (items[at].syllable == 255) continue;
                var lowest = at;
                var highest = at;
                var other = start + items[at].syllable;
                while (other != at) {
                    lowest = @min(lowest, other);
                    highest = @max(highest, other);
                    const next = start + items[other].syllable;
                    items[other].syllable = 255;
                    other = next;
                }
                buffer.mergeClusters(@max(base, lowest), highest + 1);
            }
        }
        for (items[start..end]) |*item| item.syllable = kept;

        // The forms.
        at = start;
        while (at < end and items[at].position == syl.POSITION_RA_TO_REPH) : (at += 1) items[at].forms |= syl.FORM_REPH;
        const before_base: u8 = if (model.old) syl.FORM_HALF else syl.FORM_HALF | syl.FORM_BELOW;
        for (items[start..base]) |*item| item.forms |= before_base;
        if (base < end) {
            for (items[base + 1 .. end]) |*item| item.forms |= syl.FORM_BELOW | syl.FORM_ABOVE | syl.FORM_POST;
        }
        if (model.old) {
            at = start;
            while (at + 1 < base) : (at += 1) {
                if (items[at].category != syl.CATEGORY_RA or items[at + 1].category != syl.CATEGORY_HALANT) continue;
                if (at + 2 != base and items[at + 2].category == syl.CATEGORY_JOINER) continue;
                items[at].forms |= syl.FORM_BELOW;
                items[at + 1].forms |= syl.FORM_BELOW;
            }
        }
        if (model.pre_base and base + 2 < end) {
            at = base + 1;
            while (at + 1 < end) : (at += 1) {
                const pair = [2]u32{ items[at].glyph, items[at + 1].glyph };
                if (!model.would(true, pref, &pair)) continue;
                items[at].forms |= syl.FORM_PRE_BASE;
                items[at + 1].forms |= syl.FORM_PRE_BASE;
                break;
            }
        }

        // A non-joiner keeps the consonant before it whole.
        at = start + 1;
        while (at < end) : (at += 1) {
            if (!isJoiner(&items[at])) continue;
            const keeps_whole = items[at].category == syl.CATEGORY_NON_JOINER;
            var back = at;
            while (true) {
                back -= 1;
                if (keeps_whole) {
                    items[back].forms &= ~syl.FORM_HALF;
                    items[back].mask &= ~model.half_bits;
                }
                if (back <= start or isConsonant(&items[back])) break;
            }
        }
    }

    /// After the forms: in every syllable, the vowel sign written left
    /// of the base, the reph and a consonant's form before the base go
    /// to where they are drawn. `after_letter` says that the text
    /// before the run ends in the middle of a word.
    pub fn finish(model: *const Model, buffer: *Buffer, after_letter: bool) void {
        var start: u32 = 0;
        while (start < buffer.len) {
            const end = syllableEnd(buffer.slice(), start);
            model.finishSyllable(buffer, start, end, after_letter);
            start = end;
        }
    }

    fn finishSyllable(model: *const Model, buffer: *Buffer, start: u32, end: u32, after_letter: bool) void {
        const items = buffer.items;
        const stops = syl.bit(syl.CATEGORY_MATRA) | syl.bit(syl.CATEGORY_HALANT);

        // A halant a rule took into a ligature and gave back again is
        // a halant as before.
        if (model.virama != 0) {
            for (items[start..end]) |*item| {
                if (item.glyph != model.virama) continue;
                if (item.flags & _buffer.ITEM_LIGATED == 0 or item.flags & _buffer.ITEM_MULTIPLIED == 0) continue;
                item.category = syl.CATEGORY_HALANT;
                item.flags &= ~(_buffer.ITEM_LIGATED | _buffer.ITEM_MULTIPLIED);
            }
        }

        // The base again. A consonant marked for the form before the
        // base that did not take it is the base, or what follows its
        // halants.
        var try_pre_base = model.pre_base;
        var base = start;
        while (base < end) : (base += 1) {
            if (items[base].position < syl.POSITION_BASE) continue;
            if (try_pre_base and base + 1 < end) {
                var at = base + 1;
                while (at < end) : (at += 1) {
                    if (!model.markedPreBase(&items[at])) continue;
                    if (!(items[at].flags & _buffer.ITEM_SUBSTITUTED != 0 and ligatedWhole(&items[at]))) {
                        base = at;
                        while (base < end and isHalant(&items[base])) base += 1;
                        if (base < end) items[base].position = syl.POSITION_BASE;
                        try_pre_base = false;
                    }
                    break;
                }
                if (base == end) break;
            }
            if (start < base and items[base].position > syl.POSITION_BASE) base -= 1;
            break;
        }
        if (base == end and start < base and syl.isOneOf(&items[base - 1], syl.bit(syl.CATEGORY_JOINER))) base -= 1;
        if (base < end) {
            while (start < base and syl.isOneOf(&items[base], syl.bit(syl.CATEGORY_NUKTA) | syl.bit(syl.CATEGORY_HALANT))) base -= 1;
        }

        // The vowel signs left of the base stand at the syllable's
        // start. They go behind the last halant before the base that
        // still stands - before the half forms it did not make stay
        // whole consonants - unless a joiner follows that halant.
        if (start + 1 < end and start < base) {
            var target: u32 = if (base == end) base - 2 else base - 1;
            while (true) {
                while (target > start and !syl.isOneOf(&items[target], stops)) target -= 1;
                if (isHalant(&items[target]) and items[target].position != syl.POSITION_PRE_MATRA) {
                    if (target + 1 < end and items[target + 1].category == syl.CATEGORY_JOINER and target > start) {
                        target -= 1;
                        continue;
                    }
                } else {
                    target = start;
                }
                break;
            }
            if (start < target and items[target].position != syl.POSITION_PRE_MATRA) {
                var at = target;
                while (at > start) : (at -= 1) {
                    if (items[at - 1].position != syl.POSITION_PRE_MATRA) continue;
                    const from = at - 1;
                    if (from < base and base <= target) base -= 1;
                    moveBehind(items, from, target);
                    buffer.mergeClusters(target, @min(end, base + 1));
                    target -= 1;
                }
            } else {
                for (start..base) |at| {
                    if (items[at].position != syl.POSITION_PRE_MATRA) continue;
                    buffer.mergeClusters(@intCast(at), @min(end, base + 1));
                    break;
                }
            }
        }

        // The reph, a ligature by now, goes behind the first halant
        // before the base that still stands, or else to the end of the
        // syllable, before its signs.
        if (start + 1 < end and items[start].position == syl.POSITION_RA_TO_REPH and ligatedWhole(&items[start])) {
            var target = start + 1;
            while (target < base and !isHalant(&items[target])) target += 1;
            if (target < base and isHalant(&items[target])) {
                if (target + 1 < base and isJoiner(&items[target + 1])) target += 1;
            } else {
                target = end - 1;
                while (target > start and items[target].position == syl.POSITION_SIGNS) target -= 1;
                // Before a halant that ends the syllable behind a vowel
                // sign, so that the reph stands with the sign.
                if (isHalant(&items[target])) {
                    var at = base + 1;
                    while (at < target) : (at += 1) {
                        if (items[at].category == syl.CATEGORY_MATRA) target -= 1;
                    }
                }
            }
            buffer.mergeClusters(start, target + 1);
            moveBehind(items, start, target);
            if (start < base and base <= target) base -= 1;
        }

        // A consonant that took its form before the base goes there:
        // behind the last vowel sign or halant before the base.
        if (try_pre_base and base + 1 < end) {
            var at = base + 1;
            while (at < end) : (at += 1) {
                if (!model.markedPreBase(&items[at])) continue;
                if (ligatedWhole(&items[at])) {
                    var target = base;
                    while (target > start and !syl.isOneOf(&items[target - 1], stops)) target -= 1;
                    if (target > start and isHalant(&items[target - 1])) {
                        if (target < end and isJoiner(&items[target])) target += 1;
                    }
                    buffer.mergeClusters(target, at + 1);
                    moveBefore(items, at, target);
                    if (target <= base and base < at) base += 1;
                }
                break;
            }
        }

        // A vowel sign at the start of a word may have a form of its
        // own there.
        if (items[start].position == syl.POSITION_PRE_MATRA) {
            const in_word = if (start == 0) after_letter else items[start - 1].flags & _buffer.ITEM_LETTER != 0;
            if (!in_word) items[start].forms |= syl.FORM_INITIAL;
        }
    }
};

/// A ligature that no rule took apart again.
fn ligatedWhole(item: *const Item) bool {
    return item.flags & _buffer.ITEM_LIGATED != 0 and item.flags & _buffer.ITEM_MULTIPLIED == 0;
}

/// The item at `from` goes to `to` behind it; those between move up.
fn moveBehind(items: [*]Item, from: u32, to: u32) void {
    const moved = items[from];
    var place = from;
    while (place < to) : (place += 1) items[place] = items[place + 1];
    items[to] = moved;
}

/// The item at `from` goes to `to` before it; those between move back.
fn moveBefore(items: [*]Item, from: u32, to: u32) void {
    const moved = items[from];
    var place = from;
    while (place > to) : (place -= 1) items[place] = items[place - 1];
    items[to] = moved;
}

fn isConsonant(item: *const Item) bool {
    return syl.isOneOf(item, syl.consonants);
}

fn isJoiner(item: *const Item) bool {
    return syl.isOneOf(item, syl.joiners);
}

fn isHalant(item: *const Item) bool {
    return syl.isOneOf(item, syl.bit(syl.CATEGORY_HALANT));
}

/// Where the syllable that starts at `start` ends.
fn syllableEnd(items: []const Item, start: u32) u32 {
    var end = start + 1;
    while (end < items.len and items[end].syllable == items[start].syllable) end += 1;
    return end;
}

fn reverse(items: []Item) void {
    if (items.len < 2) return;
    var low: usize = 0;
    var high: usize = items.len - 1;
    while (low < high) : ({
        low += 1;
        high -= 1;
    }) {
        const kept = items[low];
        items[low] = items[high];
        items[high] = kept;
    }
}

/// Sorts `items` by position, those of one position keeping their
/// order. `aside` has room for them.
fn sortByPosition(items: []Item, aside: []Item) void {
    var starts: [syl.POSITION_END + 2]u32 = @splat(0);
    for (items) |item| starts[@min(item.position, syl.POSITION_END) + 1] += 1;
    for (1..starts.len) |position| starts[position] += starts[position - 1];
    for (items) |item| {
        const position = @min(item.position, syl.POSITION_END);
        aside[starts[position]] = item;
        starts[position] += 1;
    }
    @memcpy(items, aside[0..items.len]);
}
