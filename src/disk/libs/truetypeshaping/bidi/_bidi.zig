// SPDX-License-Identifier: MIT
//! The bidirectional algorithm of Unicode's Annex 9: the level of each
//! character of a text, even for one read from left to right and odd
//! for one read from right to left, and the character a mirrored one is
//! drawn as.
//!
//! `resolve` needs nothing of the system but memory, so a tool on the
//! host resolves with the same code. It works on the characters of one
//! text at a time, cut into paragraphs after each paragraph separator:
//!
//!   - A paragraph's level is the one asked for, or by its first letter
//!     of a direction, past the isolates (P2, P3); left to right where it
//!     has none.
//!   - The embeddings, overrides and isolates (X1-X8) give each
//!     character its level, 125 deep; one past that is counted and
//!     undone by its own end, as the annex says. The embeddings, their
//!     ends and the boundary neutrals are taken out (X9).
//!   - The characters left are cut into isolating run sequences (X10),
//!     and in each the weak types are resolved (W1-W7), the paired
//!     brackets (N0, 63 deep), the neutrals (N1, N2) and the levels
//!     (I1, I2).
//!   - The separators, and the white space and isolates before one or at
//!     the paragraph's end, are put back at the paragraph's level (L1).
//!     A character taken out has the level of the one before it, or the
//!     paragraph's.
//!
//! Reordering (L2) is the caller's: it reverses each sequence of
//! characters at a level or above, from the highest level down to the
//! lowest odd one, among the glyphs it has made of them.

const sdk = @import("sdk");
const utf8 = sdk.utility.utf8;
const Memory = @import("../shape/_buffer.zig").Memory;
const _table = @import("_bidi_table.zig");

const L = _table.L;
const R = _table.R;
const AL = _table.AL;
const EN = _table.EN;
const ES = _table.ES;
const ET = _table.ET;
const AN = _table.AN;
const CS = _table.CS;
const NSM = _table.NSM;
const BN = _table.BN;
const B = _table.B;
const S = _table.S;
const WS = _table.WS;
const ON = _table.ON;
const LRE = _table.LRE;
const LRO = _table.LRO;
const RLE = _table.RLE;
const RLO = _table.RLO;
const PDF = _table.PDF;
const LRI = _table.LRI;
const RLI = _table.RLI;
const FSI = _table.FSI;
const PDI = _table.PDI;

/// The deepest an embedding goes.
pub const max_depth = 125;

/// The deepest paired brackets are found.
const bracket_depth = 63;

/// How the paragraphs' levels are found: left to right, right to left,
/// or each by its first letter of a direction.
pub const Base = enum { left_to_right, right_to_left, first_strong };

/// The class `char` has.
pub fn classOf(char: u32) u8 {
    const starts = &_table.starts;
    var low: usize = 0;
    var high: usize = starts.len;
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (starts[middle] >> 8 <= char) low = middle else high = middle;
    }
    return @truncate(starts[low]);
}

/// The character `char` is drawn as where it is read from right to left;
/// null for one that is not mirrored.
pub fn mirrorOf(char: u32) ?u32 {
    return pairedWith(&_table.mirrors, char);
}

/// The second of the pair `char` is the first of, in `pairs`.
fn pairedWith(pairs: []const u64, char: u32) ?u32 {
    var low: usize = 0;
    var high: usize = pairs.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const first: u32 = @intCast(pairs[middle] >> 21);
        if (first == char) return @intCast(pairs[middle] & 0x1F_FFFF);
        if (first < char) low = middle + 1 else high = middle;
    }
    return null;
}

/// The closing bracket `char` opens; null for one that opens none.
fn closingOf(char: u32) ?u32 {
    return pairedWith(&_table.brackets, char);
}

/// Whether `char` closes a bracket.
fn closes(char: u32) bool {
    for (_table.brackets) |pair| {
        if (pair & 0x1F_FFFF == char) return true;
    }
    return false;
}

/// The two angle brackets that are canonically the same as two others,
/// taken as those for pairing.
fn canonical(char: u32) u32 {
    return switch (char) {
        0x2329 => 0x3008,
        0x232A => 0x3009,
        else => char,
    };
}

const none: u32 = 0xFFFF_FFFF;

/// The work of one call, a block of memory cut into arrays of a
/// character each.
const Work = struct {
    chars: []u32,
    /// Where each character's bytes start in the text, and its class
    /// now and as it was.
    starts: []u32,
    classes: []u8,
    original: []u8,
    /// Each character's embedding level (X1-X8), and its level once
    /// resolved (I1, I2): the boundaries of a sequence go by the first.
    levels: []u8,
    resolved: []u8,
    /// An isolate's matching end (BD9), and an end's isolate; `none`.
    matching: []u32,
    /// The characters of an isolating run sequence, in their order; and
    /// a stack while the isolates are matched.
    sequence: []u32,
    /// The paired brackets of a sequence: their places in it.
    pairs: []Pair,
    /// Whether a character is in a sequence already.
    taken: []bool,
};

const Pair = struct { open: u32, close: u32 };

fn removed(class: u8) bool {
    return switch (class) {
        LRE, RLE, LRO, RLO, PDF, BN => true,
        else => false,
    };
}

fn isolates(class: u8) bool {
    return class == LRI or class == RLI or class == FSI;
}

/// The strong direction a class counts as for the neutrals: L, or R for
/// R, AN and EN; null for any other.
fn strongOf(class: u8) ?u8 {
    return switch (class) {
        L => L,
        R, AL, AN, EN => R,
        else => null,
    };
}

fn directionOf(level: u8) u8 {
    return if (level & 1 != 0) R else L;
}

/// Resolves the levels of `text` (UTF-8) into `levels`, a byte each: each
/// byte of a character gets its level. False without the memory.
pub fn resolve(memory: Memory, text: []const u8, base: Base, levels: []u8) bool {
    // How many characters.
    var count: usize = 0;
    var at: usize = 0;
    while (at < text.len) : (count += 1) at += utf8.read(text[at..]).length;
    if (count == 0) return true;

    const each = 4 + 4 + 1 + 1 + 1 + 1 + 4 + 4 + 1;
    const pair_room = count / 2 + 1;
    const block = memory.alloc(count * each + pair_room * @sizeOf(Pair) + 8) orelse return false;
    defer memory.free(block);
    var place: usize = 0;
    const words: [*]u32 = @ptrCast(@alignCast(block));
    const work: Work = .{
        .chars = words[0..count],
        .starts = words[count .. 2 * count],
        .matching = words[2 * count .. 3 * count],
        .sequence = words[3 * count .. 4 * count],
        .pairs = @as([*]Pair, @ptrCast(@alignCast(block + 16 * count)))[0..pair_room],
        .classes = block[16 * count + pair_room * @sizeOf(Pair) ..][0..count],
        .original = block[17 * count + pair_room * @sizeOf(Pair) ..][0..count],
        .levels = block[18 * count + pair_room * @sizeOf(Pair) ..][0..count],
        .resolved = block[19 * count + pair_room * @sizeOf(Pair) ..][0..count],
        .taken = @as([*]bool, @ptrCast(block + 20 * count + pair_room * @sizeOf(Pair)))[0..count],
    };
    at = 0;
    while (at < text.len) : (place += 1) {
        const read = utf8.read(text[at..]);
        work.chars[place] = read.char;
        work.starts[place] = @intCast(at);
        work.original[place] = classOf(read.char);
        at += read.length;
    }
    @memcpy(work.classes, work.original);
    @memset(work.taken, false);

    // Each paragraph ends after its separator.
    var start: usize = 0;
    while (start < count) {
        var end = start;
        while (end < count and work.original[end] != B) end += 1;
        if (end < count) end += 1;
        paragraph(&work, start, end, base);
        start = end;
    }

    for (0..count) |index| {
        const from = work.starts[index];
        const to = if (index + 1 < count) work.starts[index + 1] else text.len;
        @memset(levels[from..to], work.resolved[index]);
    }
    return true;
}

/// The level of the first letter of a direction from `from` to `to`, past
/// the isolates; null for none.
fn firstStrong(work: *const Work, from: usize, to: usize) ?u8 {
    var depth: usize = 0;
    for (work.original[from..to]) |class| {
        if (isolates(class)) {
            depth += 1;
        } else if (class == PDI) {
            if (depth > 0) depth -= 1;
        } else if (depth == 0) {
            if (class == L) return 0;
            if (class == R or class == AL) return 1;
        }
    }
    return null;
}

const Entry = struct { level: u8, override: u8, isolate: bool };

fn paragraph(work: *const Work, start: usize, end: usize, base: Base) void {
    const original = work.original;
    const classes = work.classes;
    const levels = work.levels;

    // The isolates' matching ends (BD9), a stack in `sequence`.
    var stacked: usize = 0;
    for (start..end) |index| {
        work.matching[index] = none;
        const class = original[index];
        if (isolates(class)) {
            work.sequence[stacked] = @intCast(index);
            stacked += 1;
        } else if (class == PDI and stacked > 0) {
            stacked -= 1;
            const opener = work.sequence[stacked];
            work.matching[opener] = @intCast(index);
            work.matching[index] = opener;
        }
    }

    const level: u8 = switch (base) {
        .left_to_right => 0,
        .right_to_left => 1,
        .first_strong => firstStrong(work, start, end) orelse 0,
    };

    // X1-X8.
    var stack: [max_depth + 2]Entry = undefined;
    stack[0] = .{ .level = level, .override = ON, .isolate = false };
    var depth: usize = 1;
    var overflow_isolates: usize = 0;
    var overflow_embeddings: usize = 0;
    var valid_isolates: usize = 0;
    for (start..end) |index| {
        const class = original[index];
        const top = stack[depth - 1];
        switch (class) {
            RLE, LRE, RLO, LRO => {
                const odd = class == RLE or class == RLO;
                const next: u8 = if (odd) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                levels[index] = top.level;
                if (next <= max_depth and overflow_isolates == 0 and overflow_embeddings == 0) {
                    const override: u8 = if (class == RLO) R else if (class == LRO) L else ON;
                    stack[depth] = .{ .level = next, .override = override, .isolate = false };
                    depth += 1;
                } else if (overflow_isolates == 0) {
                    overflow_embeddings += 1;
                }
            },
            RLI, LRI, FSI => {
                levels[index] = top.level;
                if (top.override != ON) classes[index] = top.override;
                const to = if (work.matching[index] != none) work.matching[index] else end;
                const odd = class == RLI or (class == FSI and firstStrong(work, index + 1, to) == 1);
                const next: u8 = if (odd) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                if (next <= max_depth and overflow_isolates == 0 and overflow_embeddings == 0) {
                    valid_isolates += 1;
                    stack[depth] = .{ .level = next, .override = ON, .isolate = true };
                    depth += 1;
                } else {
                    overflow_isolates += 1;
                }
            },
            PDI => {
                if (overflow_isolates > 0) {
                    overflow_isolates -= 1;
                } else if (valid_isolates > 0) {
                    overflow_embeddings = 0;
                    while (!stack[depth - 1].isolate) depth -= 1;
                    depth -= 1;
                    valid_isolates -= 1;
                }
                const now = stack[depth - 1];
                levels[index] = now.level;
                if (now.override != ON) classes[index] = now.override;
            },
            PDF => {
                levels[index] = top.level;
                if (overflow_isolates > 0) {
                    // Inside an isolate past the deepest: nothing.
                } else if (overflow_embeddings > 0) {
                    overflow_embeddings -= 1;
                } else if (!top.isolate and depth >= 2) {
                    depth -= 1;
                }
            },
            B => levels[index] = level,
            BN => levels[index] = top.level,
            else => {
                levels[index] = top.level;
                if (top.override != ON) classes[index] = top.override;
            },
        }
    }

    // X10: the isolating run sequences, each a level run and those its
    // isolates' ends continue it with.
    for (start..end) |first| {
        if (removed(original[first]) or work.taken[first]) continue;
        var length: usize = 0;
        var from = first;
        while (true) {
            const run_level = levels[from];
            var last = from;
            var index = from;
            while (index < end) : (index += 1) {
                if (removed(original[index])) continue;
                if (levels[index] != run_level) break;
                work.sequence[length] = @intCast(index);
                length += 1;
                work.taken[index] = true;
                last = index;
            }
            if (isolates(original[last]) and work.matching[last] != none) {
                from = work.matching[last];
                continue;
            }
            break;
        }
        sequence(work, work.sequence[0..length], start, end, level);
    }

    // A character taken out has the level of the one before it.
    const resolved = work.resolved;
    var before = level;
    for (start..end) |index| {
        if (removed(original[index])) resolved[index] = before else before = resolved[index];
    }

    // L1: separators, and white space and isolates before one or at the
    // end, at the paragraph's level.
    var trailing = true;
    var index = end;
    while (index > start) {
        index -= 1;
        const class = original[index];
        if (class == B or class == S) {
            resolved[index] = level;
            trailing = true;
        } else if (trailing and (class == WS or isolates(class) or class == PDI or removed(class))) {
            resolved[index] = level;
        } else {
            trailing = false;
        }
    }
}

/// The level of the character before `index` in the paragraph, past
/// those taken out; `level` for none.
fn levelBefore(work: *const Work, index: usize, start: usize, level: u8) u8 {
    var at = index;
    while (at > start) {
        at -= 1;
        if (!removed(work.original[at])) return work.levels[at];
    }
    return level;
}

fn levelAfter(work: *const Work, index: usize, end: usize, level: u8) u8 {
    var at = index + 1;
    while (at < end) : (at += 1) {
        if (!removed(work.original[at])) return work.levels[at];
    }
    return level;
}

/// Resolves the types and levels of one isolating run sequence (W1-I2).
fn sequence(work: *const Work, places: []const u32, start: usize, end: usize, level: u8) void {
    const classes = work.classes;
    const original = work.original;
    const first = places[0];
    const last = places[places.len - 1];
    const own = work.levels[first];
    const sos = directionOf(@max(own, levelBefore(work, first, start, level)));
    const after = if (isolates(original[last])) level else levelAfter(work, last, end, level);
    const eos = directionOf(@max(own, after));
    const embedding = directionOf(own);

    // W1: a mark takes the type before it; after an isolate or its end,
    // a neutral's.
    var previous = sos;
    for (places) |place| {
        if (classes[place] == NSM) {
            classes[place] = if (isolates(previous) or previous == PDI) ON else previous;
        }
        previous = classes[place];
    }
    // W2, W3: a European number after an Arabic letter is an Arabic
    // number; the letter then is R.
    var strong = sos;
    for (places) |place| {
        const class = classes[place];
        if (class == L or class == R or class == AL) strong = class;
        if (class == EN and strong == AL) classes[place] = AN;
    }
    for (places) |place| {
        if (classes[place] == AL) classes[place] = R;
    }
    // W4: one separator between two numbers of a kind is of their kind.
    if (places.len >= 3) {
        for (1..places.len - 1) |at| {
            const class = classes[places[at]];
            const before = classes[places[at - 1]];
            const behind = classes[places[at + 1]];
            if (class == ES and before == EN and behind == EN) {
                classes[places[at]] = EN;
            } else if (class == CS and before == behind and (before == EN or before == AN)) {
                classes[places[at]] = before;
            }
        }
    }
    // W5: terminators beside a European number are of it.
    var at: usize = 0;
    while (at < places.len) {
        if (classes[places[at]] != ET) {
            at += 1;
            continue;
        }
        var stop = at;
        while (stop < places.len and classes[places[stop]] == ET) stop += 1;
        const by_number = (at > 0 and classes[places[at - 1]] == EN) or (stop < places.len and classes[places[stop]] == EN);
        if (by_number) {
            for (places[at..stop]) |place| classes[place] = EN;
        }
        at = stop;
    }
    // W6: the separators and terminators left are neutrals.
    for (places) |place| {
        switch (classes[place]) {
            ES, ET, CS => classes[place] = ON,
            else => {},
        }
    }
    // W7: a European number after a letter read from left to right is
    // read so too.
    strong = sos;
    for (places) |place| {
        const class = classes[place];
        if (class == L or class == R) strong = class;
        if (class == EN and strong == L) classes[place] = L;
    }

    brackets(work, places, sos, embedding);

    // N1, N2: neutrals between two of one direction take it, any others
    // the embedding's.
    at = 0;
    while (at < places.len) {
        if (!neutral(classes[places[at]])) {
            at += 1;
            continue;
        }
        var stop = at;
        while (stop < places.len and neutral(classes[places[stop]])) stop += 1;
        const before = if (at == 0) sos else strongOf(classes[places[at - 1]]) orelse embedding;
        const behind = if (stop == places.len) eos else strongOf(classes[places[stop]]) orelse embedding;
        const direction = if (before == behind) before else embedding;
        for (places[at..stop]) |place| classes[place] = direction;
        at = stop;
    }

    // I1, I2.
    for (places) |place| {
        const class = classes[place];
        var resolved = own;
        if (own & 1 == 0) {
            if (class == R) resolved = own + 1 else if (class == AN or class == EN) resolved = own + 2;
        } else if (class == L or class == EN or class == AN) {
            resolved = own + 1;
        }
        work.resolved[place] = resolved;
    }
}

fn neutral(class: u8) bool {
    return switch (class) {
        B, S, WS, ON, LRI, RLI, FSI, PDI => true,
        else => false,
    };
}

/// N0: the paired brackets of a sequence take the direction of what is
/// inside them, by the embedding's where both are there.
fn brackets(work: *const Work, places: []const u32, sos: u8, embedding: u8) void {
    const classes = work.classes;
    // BD16: the pairs, by a stack of the open ones.
    var open: [bracket_depth]struct { closing: u32, at: u32 } = undefined;
    var depth: usize = 0;
    var count: usize = 0;
    find: for (places, 0..) |place, at| {
        if (classes[place] != ON) continue;
        const char = work.chars[place];
        if (closingOf(char)) |closing| {
            if (depth == bracket_depth) break :find;
            open[depth] = .{ .closing = canonical(closing), .at = @intCast(at) };
            depth += 1;
        } else if (closes(char)) {
            var level = depth;
            while (level > 0) {
                level -= 1;
                if (open[level].closing != canonical(char)) continue;
                if (count < work.pairs.len) {
                    work.pairs[count] = .{ .open = open[level].at, .close = @intCast(at) };
                    count += 1;
                }
                depth = level;
                break;
            }
        }
    }
    const pairs = work.pairs[0..count];
    // In the order of the opening brackets.
    for (1..@max(pairs.len, 1)) |index| {
        const pair = pairs[index];
        var to = index;
        while (to > 0 and pairs[to - 1].open > pair.open) : (to -= 1) pairs[to] = pairs[to - 1];
        pairs[to] = pair;
    }
    const opposite = if (embedding == L) R else L;
    for (pairs) |pair| {
        var same = false;
        var other = false;
        for (places[pair.open + 1 .. pair.close]) |place| {
            const strong = strongOf(classes[place]) orelse continue;
            if (strong == embedding) same = true else other = true;
        }
        var direction: u8 = undefined;
        if (same) {
            direction = embedding;
        } else if (other) {
            var context = sos;
            var at = pair.open;
            while (at > 0) {
                at -= 1;
                if (strongOf(classes[places[at]])) |strong| {
                    context = strong;
                    break;
                }
            }
            direction = if (context == opposite) opposite else embedding;
        } else continue;
        setBracket(work, places, pair.open, direction);
        setBracket(work, places, pair.close, direction);
    }
}

/// Gives the bracket at `at` in the sequence its direction, and the
/// marks behind it that were marks before W1 as well.
fn setBracket(work: *const Work, places: []const u32, at: usize, direction: u8) void {
    work.classes[places[at]] = direction;
    var behind = at + 1;
    while (behind < places.len and work.original[places[behind]] == NSM) : (behind += 1) {
        work.classes[places[behind]] = direction;
    }
}
