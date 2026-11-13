// SPDX-License-Identifier: MIT
//! Syllables: what a character is in a script shaped by syllables, and
//! where the syllables of a run begin and end.
//!
//! A character has a category (`kindOf`): a consonant, a vowel, a vowel
//! sign, the sign that takes a consonant's vowel away, and so on, and a
//! position, where a sign of its kind stands around the base of its
//! syllable. The positions are in the order a syllable's parts are put
//! in before the font's forms are asked for.
//!
//! A run is cut into syllables by its categories (`number`): at each
//! start the longest sequence one of seven patterns takes is the
//! syllable, and of two patterns that take the same length the one
//! named first. The patterns are regular expressions over categories,
//! written out below (`consonantSyllable` and the ones beside it). They
//! are made into one automaton when the library is compiled: each
//! category named in a pattern is a spot, a spot has the set of spots
//! that may follow it, and the automaton's state is the set of spots
//! the sequence read so far may stand at. Reading a category keeps the
//! spots of the state that take it and goes on to all that follow
//! them; sets are bits, so a step is a few words of logic, and no table
//! of states is kept. A pattern has taken what was read when a spot it
//! may end at is among those kept.
//!
//! The categories are those of Devanagari, the Vedic signs and the
//! characters every script shares. The patterns leave out what only
//! other scripts have: a consonant of its own that is always a reph, a
//! sign between a consonant and its vowel sign, a vowel sign that
//! follows the modifier, a mark that shifts a consonant's register.

const _buffer = @import("_buffer.zig");
const Item = _buffer.Item;
const Buffer = _buffer.Buffer;

/// What a character is in its syllable.
pub const CATEGORY_OTHER: u8 = 0;
pub const CATEGORY_CONSONANT: u8 = 1;
pub const CATEGORY_VOWEL: u8 = 2;
pub const CATEGORY_NUKTA: u8 = 3;
/// The sign that takes a consonant's vowel away.
pub const CATEGORY_HALANT: u8 = 4;
pub const CATEGORY_NON_JOINER: u8 = 5;
pub const CATEGORY_JOINER: u8 = 6;
/// A vowel sign.
pub const CATEGORY_MATRA: u8 = 7;
/// A sign that changes the syllable's sound: anusvara, visarga,
/// candrabindu.
pub const CATEGORY_MODIFIER: u8 = 8;
/// A sign of tone or stress.
pub const CATEGORY_ACCENT: u8 = 9;
/// A character a sign may stand on in place of a consonant: a digit, a
/// dash, the no-break space.
pub const CATEGORY_PLACEHOLDER: u8 = 10;
pub const CATEGORY_DOTTED_CIRCLE: u8 = 11;
pub const CATEGORY_RA: u8 = 12;
pub const CATEGORY_SYMBOL: u8 = 13;
/// A consonant that is written on the one behind it.
pub const CATEGORY_STACKER: u8 = 14;
/// A modifier that is a syllable by itself: a raised digit.
pub const CATEGORY_MODIFIER_ALONE: u8 = 15;
const category_count = 16;

/// Where an item stands in its syllable, in the order the syllable is
/// put in.
pub const POSITION_START: u8 = 0;
pub const POSITION_RA_TO_REPH: u8 = 1;
pub const POSITION_PRE_MATRA: u8 = 2;
pub const POSITION_PRE_BASE: u8 = 3;
pub const POSITION_BASE: u8 = 4;
pub const POSITION_AFTER_MAIN: u8 = 5;
pub const POSITION_ABOVE: u8 = 6;
pub const POSITION_BEFORE_SUB: u8 = 7;
pub const POSITION_BELOW: u8 = 8;
pub const POSITION_AFTER_SUB: u8 = 9;
pub const POSITION_BEFORE_POST: u8 = 10;
pub const POSITION_POST: u8 = 11;
pub const POSITION_AFTER_POST: u8 = 12;
/// Modifiers and accents.
pub const POSITION_SIGNS: u8 = 13;
pub const POSITION_END: u8 = 14;

/// The kind of a syllable, the lower four bits of `Item.syllable`.
pub const SYLLABLE_CONSONANT: u8 = 0;
pub const SYLLABLE_VOWEL: u8 = 1;
/// Signs on a placeholder or the dotted circle.
pub const SYLLABLE_STANDALONE: u8 = 2;
pub const SYLLABLE_SYMBOL: u8 = 3;
/// Signs with nothing to stand on.
pub const SYLLABLE_BROKEN: u8 = 4;
/// What is no syllable of the script.
pub const SYLLABLE_NONE: u8 = 5;

/// The forms a model asks of an item, the bits of `Item.forms`: each
/// stands for one feature of the font, which holds for the items the
/// model marks and no others.
pub const FORM_REPH: u8 = 0x01;
pub const FORM_PRE_BASE: u8 = 0x02;
pub const FORM_BELOW: u8 = 0x04;
pub const FORM_ABOVE: u8 = 0x08;
pub const FORM_HALF: u8 = 0x10;
pub const FORM_POST: u8 = 0x20;
pub const FORM_INITIAL: u8 = 0x40;

pub const Kind = struct {
    category: u8 = CATEGORY_OTHER,
    position: u8 = POSITION_END,
};

const Range = struct {
    first: u32,
    last: u32,
    kind: Kind,
};

fn range(first: u32, last: u32, category: u8, position: u8) Range {
    return .{ .first = first, .last = last, .kind = .{ .category = category, .position = position } };
}

/// The characters that are something in a syllable, in order.
const ranges = [_]Range{
    range(0x002D, 0x002D, CATEGORY_PLACEHOLDER, POSITION_BASE),
    range(0x0030, 0x0039, CATEGORY_PLACEHOLDER, POSITION_BASE),
    range(0x00A0, 0x00A0, CATEGORY_PLACEHOLDER, POSITION_BASE),
    range(0x00B2, 0x00B3, CATEGORY_MODIFIER_ALONE, POSITION_SIGNS),
    range(0x00D7, 0x00D7, CATEGORY_PLACEHOLDER, POSITION_BASE),
    range(0x0900, 0x0903, CATEGORY_MODIFIER, POSITION_SIGNS),
    range(0x0904, 0x0914, CATEGORY_VOWEL, POSITION_BASE),
    range(0x0915, 0x092F, CATEGORY_CONSONANT, POSITION_BASE),
    range(0x0930, 0x0930, CATEGORY_RA, POSITION_BASE),
    range(0x0931, 0x0939, CATEGORY_CONSONANT, POSITION_BASE),
    range(0x093A, 0x093B, CATEGORY_MATRA, POSITION_AFTER_SUB),
    range(0x093C, 0x093C, CATEGORY_NUKTA, POSITION_END),
    range(0x093D, 0x093D, CATEGORY_SYMBOL, POSITION_SIGNS),
    range(0x093E, 0x093E, CATEGORY_MATRA, POSITION_AFTER_SUB),
    range(0x093F, 0x093F, CATEGORY_MATRA, POSITION_PRE_MATRA),
    range(0x0940, 0x094C, CATEGORY_MATRA, POSITION_AFTER_SUB),
    range(0x094D, 0x094D, CATEGORY_HALANT, POSITION_BELOW),
    range(0x094E, 0x094E, CATEGORY_MATRA, POSITION_PRE_MATRA),
    range(0x094F, 0x094F, CATEGORY_MATRA, POSITION_AFTER_SUB),
    range(0x0951, 0x0952, CATEGORY_ACCENT, POSITION_SIGNS),
    range(0x0953, 0x0954, CATEGORY_MODIFIER, POSITION_SIGNS),
    range(0x0955, 0x0957, CATEGORY_MATRA, POSITION_AFTER_SUB),
    range(0x0958, 0x095F, CATEGORY_CONSONANT, POSITION_BASE),
    range(0x0960, 0x0961, CATEGORY_VOWEL, POSITION_BASE),
    range(0x0962, 0x0963, CATEGORY_MATRA, POSITION_AFTER_SUB),
    range(0x0966, 0x096F, CATEGORY_PLACEHOLDER, POSITION_BASE),
    range(0x0972, 0x0977, CATEGORY_VOWEL, POSITION_BASE),
    range(0x0978, 0x097F, CATEGORY_CONSONANT, POSITION_BASE),
    range(0x1CD0, 0x1CD2, CATEGORY_ACCENT, POSITION_SIGNS),
    range(0x1CD4, 0x1CE8, CATEGORY_ACCENT, POSITION_SIGNS),
    range(0x1CE9, 0x1CEC, CATEGORY_SYMBOL, POSITION_SIGNS),
    range(0x1CED, 0x1CED, CATEGORY_ACCENT, POSITION_SIGNS),
    range(0x1CEE, 0x1CF1, CATEGORY_SYMBOL, POSITION_SIGNS),
    range(0x1CF2, 0x1CF3, CATEGORY_CONSONANT, POSITION_BASE),
    range(0x1CF4, 0x1CF4, CATEGORY_ACCENT, POSITION_SIGNS),
    range(0x1CF5, 0x1CF6, CATEGORY_STACKER, POSITION_BASE),
    range(0x1CF7, 0x1CF9, CATEGORY_ACCENT, POSITION_SIGNS),
    range(0x1CFA, 0x1CFA, CATEGORY_PLACEHOLDER, POSITION_BASE),
    range(0x200C, 0x200C, CATEGORY_NON_JOINER, POSITION_END),
    range(0x200D, 0x200D, CATEGORY_JOINER, POSITION_END),
    range(0x2010, 0x2015, CATEGORY_PLACEHOLDER, POSITION_BASE),
    range(0x2022, 0x2022, CATEGORY_PLACEHOLDER, POSITION_BASE),
    range(0x2074, 0x2074, CATEGORY_MODIFIER_ALONE, POSITION_SIGNS),
    range(0x2082, 0x2084, CATEGORY_MODIFIER_ALONE, POSITION_SIGNS),
    range(0x25CC, 0x25CC, CATEGORY_DOTTED_CIRCLE, POSITION_BASE),
    range(0x25FB, 0x25FE, CATEGORY_PLACEHOLDER, POSITION_BASE),
    range(0xA8E0, 0xA8F1, CATEGORY_ACCENT, POSITION_SIGNS),
    range(0xA8F2, 0xA8F7, CATEGORY_SYMBOL, POSITION_SIGNS),
    range(0xA8FE, 0xA8FE, CATEGORY_VOWEL, POSITION_BASE),
    range(0xA8FF, 0xA8FF, CATEGORY_MATRA, POSITION_AFTER_SUB),
};

/// What `char` is in a syllable, and where a sign of its kind stands.
pub fn kindOf(char: u32) Kind {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = ranges[middle];
        if (char < entry.first) {
            high = middle;
        } else if (char > entry.last) {
            low = middle + 1;
        } else {
            return entry.kind;
        }
    }
    return .{};
}

/// The bit of a category in a set of categories.
pub fn bit(category: u8) u16 {
    return @as(u16, 1) << @intCast(category);
}

/// Whether `item` is of one of `categories`. A ligature is of none:
/// what it was made of no longer says what it is.
pub fn isOneOf(item: *const Item, categories: u16) bool {
    if (item.flags & _buffer.ITEM_LIGATED != 0) return false;
    return bit(item.category) & categories != 0;
}

/// What a syllable's signs stand around: a consonant of any kind, a
/// vowel, a placeholder, the dotted circle.
pub const consonants: u16 = bit(CATEGORY_CONSONANT) | bit(CATEGORY_STACKER) | bit(CATEGORY_RA) |
    bit(CATEGORY_VOWEL) | bit(CATEGORY_PLACEHOLDER) | bit(CATEGORY_DOTTED_CIRCLE);
pub const joiners: u16 = bit(CATEGORY_JOINER) | bit(CATEGORY_NON_JOINER);

/// A set of spots, a bit each.
const words = 4;
const Set = [words]u32;
const none: Set = @splat(0);
const max_spots = words * 32;

fn both(one: Set, other: Set) Set {
    var made: Set = undefined;
    for (&made, one, other) |*word, left, right| word.* = left | right;
    return made;
}

/// A piece of a pattern: whether it takes nothing at all, and the
/// spots it may begin and end at.
const Part = struct {
    empty: bool,
    first: Set,
    last: Set,
};

/// The spots of the patterns as they are written down: which
/// categories each takes, and which spots may follow it.
const Builder = struct {
    count: usize = 0,
    takes: [max_spots]u16 = @splat(0),
    follow: [max_spots]Set = @splat(none),

    /// One item of any of `categories`.
    fn one(builder: *Builder, categories: u16) Part {
        const spot = builder.count;
        builder.count += 1;
        builder.takes[spot] = categories;
        var set = none;
        set[spot / 32] = @as(u32, 1) << @intCast(spot % 32);
        return .{ .empty = false, .first = set, .last = set };
    }

    /// `before`, then `behind`.
    fn then(builder: *Builder, before: Part, behind: Part) Part {
        builder.lead(before.last, behind.first);
        return .{
            .empty = before.empty and behind.empty,
            .first = if (before.empty) both(before.first, behind.first) else before.first,
            .last = if (behind.empty) both(before.last, behind.last) else behind.last,
        };
    }

    /// Every spot of `from` may be followed by every spot of `to`.
    fn lead(builder: *Builder, from: Set, to: Set) void {
        for (0..builder.count) |spot| {
            if (from[spot / 32] >> @intCast(spot % 32) & 1 == 0) continue;
            builder.follow[spot] = both(builder.follow[spot], to);
        }
    }

    /// The parts one behind the other.
    fn row(builder: *Builder, parts: []const Part) Part {
        var made = parts[0];
        for (parts[1..]) |part| made = builder.then(made, part);
        return made;
    }

    /// `part` any number of times, or not at all.
    fn many(builder: *Builder, part: Part) Part {
        builder.lead(part.last, part.first);
        return .{ .empty = true, .first = part.first, .last = part.last };
    }
};

/// One of the parts.
fn either(parts: []const Part) Part {
    var made = parts[0];
    for (parts[1..]) |part| {
        made = .{
            .empty = made.empty or part.empty,
            .first = both(made.first, part.first),
            .last = both(made.last, part.last),
        };
    }
    return made;
}

/// `part`, or nothing.
fn maybe(part: Part) Part {
    return .{ .empty = true, .first = part.first, .last = part.last };
}

// The patterns. Each is a function, since a piece named in two places
// is two sets of spots.

fn consonant(builder: *Builder) Part {
    return builder.one(bit(CATEGORY_CONSONANT) | bit(CATEGORY_RA));
}

fn nuktas(builder: *Builder) Part {
    return maybe(builder.row(&.{ builder.one(bit(CATEGORY_NUKTA)), maybe(builder.one(bit(CATEGORY_NUKTA))) }));
}

fn anyJoiner(builder: *Builder) Part {
    return builder.one(bit(CATEGORY_JOINER) | bit(CATEGORY_NON_JOINER));
}

fn reph(builder: *Builder) Part {
    return builder.row(&.{ builder.one(bit(CATEGORY_RA)), builder.one(bit(CATEGORY_HALANT)) });
}

fn modifier(builder: *Builder) Part {
    return builder.one(bit(CATEGORY_MODIFIER) | bit(CATEGORY_MODIFIER_ALONE));
}

/// A consonant with its nuktas.
fn fullConsonant(builder: *Builder) Part {
    return builder.row(&.{ consonant(builder), maybe(builder.one(bit(CATEGORY_JOINER))), nuktas(builder) });
}

fn matraGroup(builder: *Builder) Part {
    return builder.row(&.{
        builder.many(anyJoiner(builder)),
        builder.one(bit(CATEGORY_MATRA)),
        maybe(builder.one(bit(CATEGORY_NUKTA))),
        maybe(builder.one(bit(CATEGORY_HALANT))),
    });
}

/// A syllable's modifiers and accents.
fn signs(builder: *Builder) Part {
    return builder.row(&.{
        maybe(builder.row(&.{
            maybe(anyJoiner(builder)),
            modifier(builder),
            maybe(modifier(builder)),
            maybe(builder.one(bit(CATEGORY_NON_JOINER))),
        })),
        builder.many(builder.one(bit(CATEGORY_ACCENT))),
    });
}

fn halantGroup(builder: *Builder) Part {
    return builder.row(&.{
        maybe(anyJoiner(builder)),
        builder.one(bit(CATEGORY_HALANT)),
        maybe(builder.row(&.{ builder.one(bit(CATEGORY_JOINER)), maybe(builder.one(bit(CATEGORY_NUKTA))) })),
    });
}

fn lastHalantGroup(builder: *Builder) Part {
    return either(&.{
        halantGroup(builder),
        builder.row(&.{ builder.one(bit(CATEGORY_HALANT)), builder.one(bit(CATEGORY_NON_JOINER)) }),
    });
}

/// What follows a syllable's first consonant: further consonants, each
/// joined by a halant, then a last halant or vowel signs, then signs.
fn rest(builder: *Builder) Part {
    return builder.row(&.{
        builder.many(builder.row(&.{ halantGroup(builder), fullConsonant(builder) })),
        either(&.{ lastHalantGroup(builder), builder.many(matraGroup(builder)) }),
        signs(builder),
    });
}

fn consonantSyllable(builder: *Builder) Part {
    return builder.row(&.{ maybe(builder.one(bit(CATEGORY_STACKER))), fullConsonant(builder), rest(builder) });
}

fn vowelSyllable(builder: *Builder) Part {
    return builder.row(&.{
        maybe(reph(builder)),
        builder.one(bit(CATEGORY_VOWEL)),
        nuktas(builder),
        either(&.{ builder.one(bit(CATEGORY_JOINER)), rest(builder) }),
    });
}

fn standaloneSyllable(builder: *Builder) Part {
    return builder.row(&.{
        either(&.{
            builder.row(&.{ maybe(builder.one(bit(CATEGORY_STACKER))), builder.one(bit(CATEGORY_PLACEHOLDER)) }),
            builder.row(&.{ maybe(reph(builder)), builder.one(bit(CATEGORY_DOTTED_CIRCLE)) }),
        }),
        nuktas(builder),
        rest(builder),
    });
}

fn symbolSyllable(builder: *Builder) Part {
    return builder.row(&.{ builder.one(bit(CATEGORY_SYMBOL)), maybe(builder.one(bit(CATEGORY_NUKTA))), signs(builder) });
}

fn modifierAlone(builder: *Builder) Part {
    return builder.one(bit(CATEGORY_MODIFIER_ALONE));
}

fn brokenSyllable(builder: *Builder) Part {
    return builder.row(&.{ maybe(reph(builder)), nuktas(builder), rest(builder) });
}

fn anything(builder: *Builder) Part {
    return builder.one(0xFFFF);
}

/// The kind of syllable each pattern finds, in the patterns' order: of
/// two that take the same length the earlier one is the syllable.
const pattern_kinds = [_]u8{
    SYLLABLE_CONSONANT,
    SYLLABLE_VOWEL,
    SYLLABLE_STANDALONE,
    SYLLABLE_SYMBOL,
    SYLLABLE_NONE,
    SYLLABLE_BROKEN,
    SYLLABLE_NONE,
};

const Machine = struct {
    /// The spots a syllable may begin at.
    first: Set,
    /// The spots that take a category.
    takes: [category_count]Set,
    /// The spots that may follow a spot.
    follow: [max_spots]Set,
    /// The spots a pattern may end at.
    ends: [pattern_kinds.len]Set,
};

const machine: Machine = make: {
    @setEvalBranchQuota(200_000);
    var builder: Builder = .{};
    const patterns = [pattern_kinds.len]Part{
        consonantSyllable(&builder),
        vowelSyllable(&builder),
        standaloneSyllable(&builder),
        symbolSyllable(&builder),
        modifierAlone(&builder),
        brokenSyllable(&builder),
        anything(&builder),
    };
    var made: Machine = .{
        .first = none,
        .takes = @splat(none),
        .follow = builder.follow,
        .ends = undefined,
    };
    for (patterns, 0..) |pattern, index| {
        made.first = both(made.first, pattern.first);
        made.ends[index] = pattern.last;
    }
    for (0..builder.count) |spot| {
        for (0..category_count) |category| {
            if (builder.takes[spot] >> category & 1 == 0) continue;
            made.takes[category][spot / 32] |= @as(u32, 1) << @intCast(spot % 32);
        }
    }
    break :make made;
};

const Found = struct {
    length: u32,
    kind: u8,
};

/// The syllable `items` begins with: the longest any pattern takes.
fn find(items: []const Item) Found {
    var found: Found = .{ .length = 1, .kind = SYLLABLE_NONE };
    var state = machine.first;
    var length: u32 = 0;
    for (items) |item| {
        const takes = &machine.takes[item.category & (category_count - 1)];
        var kept: Set = undefined;
        var any: u32 = 0;
        for (&kept, state, takes) |*word, held, taking| {
            word.* = held & taking;
            any |= word.*;
        }
        if (any == 0) break;
        length += 1;
        for (machine.ends, pattern_kinds) |ends, kind| {
            var ended: u32 = 0;
            for (kept, ends) |held, ending| ended |= held & ending;
            if (ended == 0) continue;
            found = .{ .length = length, .kind = kind };
            break;
        }
        state = none;
        for (kept, 0..) |held, index| {
            var left = held;
            while (left != 0) {
                const spot = index * 32 + @ctz(left);
                left &= left - 1;
                for (&state, machine.follow[spot]) |*word, following| word.* |= following;
            }
        }
    }
    return found;
}

/// The dotted circle, which stands in for the letter a sign has none of.
pub const dotted_circle: u32 = 0x25CC;

/// Puts the glyph `circle` - the font's dotted circle - before every
/// syllable that is not whole, a sign with no letter to stand on. The
/// circle is the syllable's first glyph and its base, of the syllable's
/// number and kind and of its first sign's cluster. False
/// without the memory to grow; a run that may not grow further keeps
/// the syllables it could not mend as they are. `items` are numbered.
pub fn mend(buffer: *Buffer, circle: u32) bool {
    if (circle == 0) return true;
    const kind = kindOf(dotted_circle);
    var at: u32 = 0;
    while (at < buffer.len) {
        const syllable = buffer.slice()[at].syllable;
        var end = at;
        while (end < buffer.len and buffer.slice()[end].syllable == syllable) end += 1;
        if (syllable & 0xF == SYLLABLE_BROKEN) {
            if (!buffer.replace(at, 1, 2)) {
                if (buffer.failed) return false;
                break;
            }
            // A glyph of its own: nothing of the item it was copied
            // from but where it is and the features that hold there.
            const stand = &buffer.slice()[at];
            stand.* = .{
                .glyph = circle,
                .cluster = stand.cluster,
                .mask = stand.mask,
                .category = kind.category,
                .position = kind.position,
                .syllable = syllable,
            };
            end += 1;
        }
        at = end;
    }
    return true;
}

/// Gives every item the syllable it is in: syllables are numbered from
/// 1 to 15 and from 1 again, so two that touch never have one number.
pub fn number(items: []Item) void {
    var serial: u8 = 1;
    var at: usize = 0;
    while (at < items.len) {
        const found = find(items[at..]);
        for (items[at..][0..found.length]) |*item| item.syllable = serial << 4 | found.kind;
        serial = if (serial == 15) 1 else serial + 1;
        at += found.length;
    }
}
