// SPDX-License-Identifier: MPL-2.0
//! What the pattern calls share: the parser that makes a pattern into
//! tokens, the matcher that backtracks on a stack of frames, and the IoErr
//! they set on failure.
//!
//! A parsed pattern is the source's characters with every wildcard turned
//! into a token byte (`P_ANY` 0x80 to `P_STOP` 0x8B, sdk/libs/utility/
//! pattern.zig), NUL-terminated. The parser keeps the groups still open on
//! a stack at the far end of the output buffer, so it needs no memory of
//! its own; a pattern of `len` characters takes at most 2*len+2 bytes.
//!
//! The matcher runs the tokens forward and leaves a frame for every
//! choice it makes - how far `#?` reaches, which alternative, how many
//! instances of a repeat. When a run fails, the latest frame takes its
//! next choice and the run goes on from there. The frames are an explicit
//! stack, not the machine's: 16 on the caller's stack, then chunks of 64
//! from `AllocVec`, at most 1024 in all. A repeat tries every way its body
//! can match, and an instance that matches nothing ends it, so no pattern
//! loops. The pattern is only read, so any number of tasks may match
//! against one at once.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

const UtilityBase = @import("../utility.zig").UtilityBase;

const P_ANY = sdk.utility.pattern.P_ANY;
const P_SINGLE = sdk.utility.pattern.P_SINGLE;
const P_ORSTART = sdk.utility.pattern.P_ORSTART;
const P_ORNEXT = sdk.utility.pattern.P_ORNEXT;
const P_OREND = sdk.utility.pattern.P_OREND;
const P_NOT = sdk.utility.pattern.P_NOT;
const P_NOTEND = sdk.utility.pattern.P_NOTEND;
const P_NOTCLASS = sdk.utility.pattern.P_NOTCLASS;
const P_CLASS = sdk.utility.pattern.P_CLASS;
const P_REPBEG = sdk.utility.pattern.P_REPBEG;
const P_REPEND = sdk.utility.pattern.P_REPEND;
const P_STOP = sdk.utility.pattern.P_STOP;

/// What parsing and matching can fail with.
const Error = error{ BadTemplate, LineTooLong, TooManyLevels, NoFreeStore };

/// An error as its dos IoErr code.
///
/// INPUTS:
/// - `e` - the error.
fn code(e: Error) i32 {
    return switch (e) {
        error.BadTemplate => sdk.dos.ERROR_BAD_TEMPLATE,
        error.LineTooLong => sdk.dos.ERROR_LINE_TOO_LONG,
        error.TooManyLevels => sdk.dos.ERROR_TOO_MANY_LEVELS,
        error.NoFreeStore => sdk.dos.ERROR_NO_FREE_STORE,
    };
}

/// Whether a byte is a token. A pattern's source may not hold one.
///
/// INPUTS:
/// - `c` - the byte.
fn isToken(c: u8) bool {
    return c >= P_ANY and c <= P_STOP;
}

/// Whether `'` escapes a character: the wildcards and `'` itself.
///
/// INPUTS:
/// - `c` - the character after the `'`.
fn isWild(c: u8) bool {
    return switch (c) {
        '*', '~', '[', ']', '#', '?', '(', ')', '|', '%', '\'' => true,
        else => false,
    };
}

// --- parsing ---

/// One parse. The output grows from the start of `dest`. The open groups
/// (P_ORSTART, P_REPBEG, P_NOT) wait on a stack growing down from its end,
/// each on the byte its end token will take; the last byte stays unused.
const Parser = struct {
    dest: []u8,
    out: usize = 0,
    /// The open groups are dest[top..end]; top == end: none.
    top: usize,
    end: usize,
    nocase: bool,
    /// The library, to put characters through `ToUpper` for `nocase`.
    utility: *sdk.interface.utility.UtilityBase,

    /// Adds a byte to the output.
    ///
    /// INPUTS:
    /// - `p` - the parse.
    /// - `c` - the byte.
    ///
    /// RESULT:
    /// `error.LineTooLong` when the output would reach the open groups.
    fn store(p: *Parser, c: u8) Error!void {
        if (p.out >= p.top) return error.LineTooLong;
        p.dest[p.out] = c;
        p.out += 1;
    }

    /// The innermost open group's token, or 0 for none.
    ///
    /// INPUTS:
    /// - `p` - the parse.
    fn open(p: *const Parser) u8 {
        return if (p.top == p.end) 0 else p.dest[p.top];
    }

    /// Opens a group: its token goes to the output and onto the stack.
    ///
    /// INPUTS:
    /// - `p` - the parse.
    /// - `t` - the group's token.
    fn push(p: *Parser, t: u8) Error!void {
        try p.store(t);
        if (p.out >= p.top) return error.LineTooLong;
        p.top -= 1;
        p.dest[p.top] = t;
    }

    /// An item is complete: the `#` and `~` waiting for one get their end
    /// tokens, innermost first.
    ///
    /// INPUTS:
    /// - `p` - the parse.
    fn close(p: *Parser) Error!void {
        while (true) {
            const t: u8 = switch (p.open()) {
                P_REPBEG => P_REPEND,
                P_NOT => P_NOTEND,
                else => return,
            };
            p.top += 1;
            try p.store(t);
        }
    }

    /// A character that stands for itself, through `ToUpper` for `nocase`, as
    /// a complete item.
    ///
    /// INPUTS:
    /// - `p` - the parse.
    /// - `c` - the character.
    fn literal(p: *Parser, c: u8) Error!void {
        try p.store(if (p.nocase) p.utility.ToUpper(c) else c);
        try p.close();
    }

    /// A token that is a complete item on its own.
    ///
    /// INPUTS:
    /// - `p` - the parse.
    /// - `t` - the token.
    fn token(p: *Parser, t: u8) Error!void {
        try p.store(t);
        try p.close();
    }

    /// A class, from after its `[`: P_CLASS or P_NOTCLASS, the characters,
    /// P_CLASS.
    ///
    /// INPUTS:
    /// - `p` - the parse.
    /// - `src` - the source position, moved past the `]`.
    ///
    /// RESULT:
    /// `error.BadTemplate` for a class without its `]` or with a token byte.
    fn class(p: *Parser, src: *[*]const u8) Error!void {
        var first = P_CLASS;
        if (src.*[0] == '~') {
            first = P_NOTCLASS;
            src.* += 1;
        }
        try p.store(first);
        while (true) {
            var c = src.*[0];
            src.* += 1;
            if (c == 0) return error.BadTemplate;
            if (c == ']') break;
            if (c == '\'') {
                c = src.*[0];
                src.* += 1;
                if (c == 0) return error.BadTemplate;
            }
            if (isToken(c)) return error.BadTemplate;
            try p.store(if (p.nocase) p.utility.ToUpper(c) else c);
        }
        try p.token(P_CLASS);
    }

    /// Parses the whole source.
    ///
    /// INPUTS:
    /// - `p` - the parse.
    /// - `source` - the pattern.
    /// - `wild_star` - whether `*` is a wildcard.
    ///
    /// RESULT:
    /// Whether the pattern has wildcards, or the error that stopped it.
    fn run(p: *Parser, source: [*:0]const u8, wild_star: bool) Error!bool {
        var wild = false;
        var src: [*]const u8 = source;
        while (true) {
            const c = src[0];
            src += 1;
            if (c == 0) break;
            if (isToken(c)) return error.BadTemplate;
            switch (c) {
                '?' => {
                    wild = true;
                    try p.token(P_SINGLE);
                },
                '*' => if (wild_star) {
                    wild = true;
                    try p.token(P_ANY);
                } else try p.literal('*'),
                '#' => {
                    wild = true;
                    if (src[0] == '?') {
                        src += 1;
                        try p.token(P_ANY);
                    } else try p.push(P_REPBEG);
                },
                // A trailing ~ is itself.
                '~' => if (src[0] == 0) try p.literal('~') else {
                    wild = true;
                    try p.push(P_NOT);
                },
                '(' => {
                    wild = true;
                    try p.push(P_ORSTART);
                },
                '|' => {
                    if (p.open() != P_ORSTART) return error.BadTemplate;
                    try p.store(P_ORNEXT);
                },
                ')' => {
                    if (p.open() != P_ORSTART) return error.BadTemplate;
                    p.top += 1;
                    try p.token(P_OREND);
                },
                '%' => {},
                '[' => {
                    wild = true;
                    try p.class(&src);
                },
                '\'' => if (isWild(src[0])) {
                    const escaped = src[0];
                    src += 1;
                    try p.literal(escaped);
                } else try p.literal('\''),
                else => try p.literal(c),
            }
        }
        try p.store(0);
        if (p.open() != 0) return error.BadTemplate;
        return wild;
    }
};

/// Parses a pattern into tokens. On failure `dest` holds an empty pattern,
/// when it has a byte.
///
/// INPUTS:
/// - `ub` - the library, called through for `ToUpper`.
/// - `source` - the pattern.
/// - `dest` - the output buffer.
/// - `nocase` - puts the pattern's characters through `ToUpper`.
/// - `wild_star` - whether `*` is a wildcard.
///
/// RESULT:
/// Whether the pattern has wildcards, or `error.BadTemplate` or
/// `error.LineTooLong`.
fn parse(ub: *UtilityBase, source: [*:0]const u8, dest: []u8, nocase: bool, wild_star: bool) Error!bool {
    if (dest.len == 0) return error.LineTooLong;
    var p: Parser = .{ .dest = dest, .top = dest.len - 1, .end = dest.len - 1, .nocase = nocase, .utility = ub.iface() };
    return p.run(source, wild_star) catch |e| {
        dest[0] = 0;
        return e;
    };
}

// --- matching ---

/// Frames on the caller's stack, before any chunk is allocated.
const local_frames = 16;
/// Frames in one chunk from `AllocVec`.
const chunk_frames = 64;
/// Frames at most, all together: 20 bytes a frame on the chip, so at most
/// 20 KiB.
const max_frames = 1024;

/// The choice a frame stands for.
const Kind = enum(u8) {
    /// `#?` (or `~x` after x failed): the rest at `str`, then one further.
    any,
    /// `#x`, x one character or one class (`aux`): the rest at `str`,
    /// then after one more x.
    single,
    /// `~x`: x and the rest, from `str`; if they match, `~x` doesn't.
    not,
    /// `(a|b)`: the alternative at `pat`, from `str`.
    alt,
    /// `#(...)`: no instance (stage 0), then instances (stage 1) from
    /// `str`; its P_REPEND is `aux`.
    rep,
    /// An instance of the repeat `outer` ended: the rest runs; if it
    /// fails, the instance tries its other ways.
    cont,
};

/// One choice the matcher made, and what it needs to take the next one.
const Frame = struct {
    kind: Kind,
    stage: u8 = 0,
    pat: [*]const u8,
    str: [*]const u8,
    aux: [*]const u8 = undefined,
    /// rep: the repeat active before it; cont: the repeat whose instance
    /// ended.
    outer: ?*Frame = null,
};

/// A block of frames from `AllocVec`, on a list that grows as the stack
/// does and is kept until the match ends.
const Chunk = struct {
    prev: ?*Chunk,
    next: ?*Chunk = null,
    frames: [chunk_frames]Frame = undefined,
};

/// The frames: `local` first, then chunks, kept until the match ends so
/// pointers to frames stay good.
const Stack = struct {
    sys: *ExecBase,
    local: [local_frames]Frame = undefined,
    /// The chunk with the top frame; null: `local`.
    chunk: ?*Chunk = null,
    first: ?*Chunk = null,
    /// Frames in the current storage, and in all.
    count: usize = 0,
    total: usize = 0,

    /// The frames of the current storage: `local` or the current chunk.
    ///
    /// INPUTS:
    /// - `s` - the stack.
    fn frames(s: *Stack) []Frame {
        return if (s.chunk) |c| &c.frames else &s.local;
    }

    /// Adds a frame, moving to the next chunk when the current storage is
    /// full.
    ///
    /// INPUTS:
    /// - `s` - the stack.
    /// - `frame` - the frame.
    ///
    /// RESULT:
    /// The frame in its place, `error.TooManyLevels` at `max_frames`, or
    /// `error.NoFreeStore` without memory for a chunk.
    fn push(s: *Stack, frame: Frame) Error!*Frame {
        if (s.total == max_frames) return error.TooManyLevels;
        if (s.count == s.frames().len) {
            const next = if (s.chunk) |c| c.next else s.first;
            s.chunk = next orelse try s.grow();
            s.count = 0;
        }
        const slot = &s.frames()[s.count];
        slot.* = frame;
        s.count += 1;
        s.total += 1;
        return slot;
    }

    /// Allocates the next chunk and links it behind the current one.
    ///
    /// INPUTS:
    /// - `s` - the stack, whose `sys` it allocates from.
    fn grow(s: *Stack) Error!*Chunk {
        const block = s.sys.AllocVec(@sizeOf(Chunk), exec.MEMF_ANY) orelse return error.NoFreeStore;
        const c: *Chunk = @ptrCast(@alignCast(block));
        c.* = .{ .prev = s.chunk };
        if (s.chunk) |current| current.next = c else s.first = c;
        return c;
    }

    /// The latest frame.
    ///
    /// INPUTS:
    /// - `s` - the stack; not empty.
    fn top(s: *Stack) *Frame {
        return &s.frames()[s.count - 1];
    }

    /// Drops the latest frame. A chunk that empties stays allocated, for the
    /// next push.
    ///
    /// INPUTS:
    /// - `s` - the stack; not empty.
    fn pop(s: *Stack) void {
        s.count -= 1;
        s.total -= 1;
        if (s.count == 0) {
            if (s.chunk) |c| {
                s.chunk = c.prev;
                s.count = s.frames().len;
            }
        }
    }

    /// Gives back every chunk.
    ///
    /// INPUTS:
    /// - `s` - the stack.
    fn deinit(s: *Stack) void {
        var c = s.first;
        while (c) |it| {
            c = it.next;
            s.sys.FreeVec(it);
        }
    }
};

/// Whether a class takes a character.
///
/// INPUTS:
/// - `class` - the class, after its P_CLASS or P_NOTCLASS.
/// - `c` - the character; 0 is never taken.
/// - `negate` - true for P_NOTCLASS.
fn inClass(class: [*]const u8, c: u8, negate: bool) bool {
    if (c == 0) return false;
    var p = class;
    var found = false;
    while (p[0] != P_CLASS and p[0] != 0) {
        if (p[1] == '-' and p[2] != P_CLASS and p[2] != 0) {
            if (c >= p[0] and c <= p[2]) found = true;
            p += 3;
        } else {
            if (c == p[0]) found = true;
            p += 1;
        }
    }
    return found != negate;
}

/// Where a class ends: past its closing P_CLASS.
///
/// INPUTS:
/// - `class` - the class, after its opening token.
fn classEnd(class: [*]const u8) [*]const u8 {
    var p = class;
    while (p[0] != 0) {
        const c = p[0];
        p += 1;
        if (c == P_CLASS) break;
    }
    return p;
}

/// Past the P_OREND of the group an alternative is in.
///
/// INPUTS:
/// - `from` - somewhere in the alternative.
fn groupEnd(from: [*]const u8) [*]const u8 {
    var p = from;
    var nest: usize = 0;
    while (p[0] != 0) {
        const c = p[0];
        p += 1;
        if (c == P_ORSTART) {
            nest += 1;
        } else if (c == P_OREND) {
            if (nest == 0) break;
            nest -= 1;
        }
    }
    return p;
}

/// The next alternative of a group, if there is one.
///
/// INPUTS:
/// - `from` - the start of the current alternative.
fn nextAlternative(from: [*]const u8) ?[*]const u8 {
    var p = from;
    var nest: usize = 0;
    while (p[0] != 0) {
        const c = p[0];
        p += 1;
        if (c == P_ORSTART) {
            nest += 1;
        } else if (c == P_OREND) {
            if (nest == 0) return null;
            nest -= 1;
        } else if (c == P_ORNEXT and nest == 0) {
            return p;
        }
    }
    return null;
}

/// Past the P_NOTEND of `~x`; the pattern's end if there is none.
///
/// INPUTS:
/// - `from` - the start of `x`.
fn notEnd(from: [*]const u8) [*]const u8 {
    var p = from;
    var nest: usize = 0;
    while (p[0] != 0) {
        const c = p[0];
        p += 1;
        if (c == P_NOT) {
            nest += 1;
        } else if (c == P_NOTEND) {
            if (nest == 0) break;
            nest -= 1;
        }
    }
    return p;
}

/// The P_REPEND of a repeat, or null for a pattern that has none.
///
/// INPUTS:
/// - `body` - the start of the repeat's body.
fn repEnd(body: [*]const u8) ?[*]const u8 {
    var p = body;
    var nest: usize = 0;
    while (true) : (p += 1) {
        switch (p[0]) {
            0 => return null,
            P_REPBEG => nest += 1,
            P_REPEND => {
                if (nest == 0) return p;
                nest -= 1;
            },
            else => {},
        }
    }
}

/// Whether a repeat's body is one character or one class, so that each
/// instance is one character long and needs no frame of its own.
///
/// INPUTS:
/// - `body` - the start of the body.
/// - `end` - its P_REPEND.
fn isSingle(body: [*]const u8, end: [*]const u8) bool {
    const t = body[0];
    if (t == P_CLASS or t == P_NOTCLASS) return classEnd(body + 1) == end;
    return !isToken(t) and body + 1 == end;
}

/// One match: the frames, and the repeat an instance is running in.
const Matcher = struct {
    stack: Stack,
    nocase: bool,
    /// The library, to put characters through `ToUpper` for `nocase`.
    utility: *sdk.interface.utility.UtilityBase,
    /// The repeat whose P_REPEND ends an instance now.
    rep: ?*Frame = null,

    /// A character of the string, through `ToUpper` for `nocase`.
    ///
    /// INPUTS:
    /// - `m` - the match.
    /// - `c` - the character.
    fn fold(m: *const Matcher, c: u8) u8 {
        return if (m.nocase) m.utility.ToUpper(c) else c;
    }

    /// Whether a one-character item - a literal or a class - takes a
    /// character.
    ///
    /// INPUTS:
    /// - `m` - the match.
    /// - `item` - the item.
    /// - `c` - the character of the string.
    fn takes(m: *const Matcher, item: [*]const u8, c: u8) bool {
        const t = item[0];
        if (t == P_CLASS or t == P_NOTCLASS) return inClass(item + 1, m.fold(c), t == P_NOTCLASS);
        return c != 0 and m.fold(c) == t;
    }

    /// Moves a frame's string position on to where the rest of the pattern
    /// can start: a literal or a class first has to take the character there.
    ///
    /// INPUTS:
    /// - `m` - the match.
    /// - `f` - the frame; its `str` moves.
    ///
    /// RESULT:
    /// False when there is no such place.
    fn skip(m: *const Matcher, f: *Frame) bool {
        const t = f.pat[0];
        if (t == 0 or (isToken(t) and t != P_CLASS and t != P_NOTCLASS)) return true;
        while (!m.takes(f.pat, f.str[0])) {
            if (f.str[0] == 0) return false;
            f.str += 1;
        }
        return true;
    }

    /// Runs the pattern until it matches to the end or fails, leaving a frame
    /// for every choice it made.
    ///
    /// INPUTS:
    /// - `m` - the match.
    /// - `from_pat` - where in the pattern to start.
    /// - `from_str` - where in the string to start.
    ///
    /// RESULT:
    /// Whether this run matched, or the error of a frame it could not take.
    fn forward(m: *Matcher, from_pat: [*]const u8, from_str: [*]const u8) Error!bool {
        var pat = from_pat;
        var str = from_str;
        while (true) {
            const t = pat[0];
            pat += 1;
            if (!isToken(t)) {
                if (t == 0) return str[0] == 0;
                if (str[0] == 0 or m.fold(str[0]) != t) return false;
                str += 1;
                continue;
            }
            switch (t) {
                P_SINGLE => {
                    if (str[0] == 0) return false;
                    str += 1;
                },
                P_ANY => {
                    if (pat[0] == 0) return true;
                    const f = try m.stack.push(.{ .kind = .any, .pat = pat, .str = str });
                    if (!m.skip(f)) {
                        m.stack.pop();
                        return false;
                    }
                    str = f.str;
                },
                P_CLASS, P_NOTCLASS => {
                    if (!inClass(pat, m.fold(str[0]), t == P_NOTCLASS)) return false;
                    pat = classEnd(pat);
                    str += 1;
                },
                P_NOT => _ = try m.stack.push(.{ .kind = .not, .pat = pat, .str = str }),
                P_ORSTART => _ = try m.stack.push(.{ .kind = .alt, .pat = pat, .str = str }),
                // An alternative matched: on after its group.
                P_ORNEXT => pat = groupEnd(pat),
                P_OREND, P_NOTEND => {},
                P_REPBEG => {
                    const end = repEnd(pat) orelse return false;
                    const kind: Kind = if (isSingle(pat, end)) .single else .rep;
                    if (kind == .single) {
                        _ = try m.stack.push(.{ .kind = .single, .pat = end + 1, .str = str, .aux = pat });
                    } else {
                        _ = try m.stack.push(.{ .kind = .rep, .pat = pat, .str = str, .aux = end, .outer = m.rep });
                    }
                    pat = end + 1; // no instance first
                },
                P_REPEND => {
                    const active = m.rep orelse continue;
                    if (pat - 1 != active.aux) continue;
                    if (str == active.str) return false; // an empty instance
                    _ = try m.stack.push(.{ .kind = .cont, .pat = pat, .str = str, .outer = active });
                    m.rep = active.outer;
                    pat = active.pat - 1; // the repeat again, from here
                },
                else => return true, // P_STOP, which the parser never makes
            }
        }
    }

    /// Matches the whole string: runs forward, and on each failure takes the
    /// latest frame's next choice, until a run matches or no choice is left.
    ///
    /// INPUTS:
    /// - `m` - the match.
    /// - `pattern` - the tokens.
    /// - `string` - the string.
    fn run(m: *Matcher, pattern: [*]const u8, string: [*]const u8) Error!bool {
        var pat = pattern;
        var str = string;
        next: while (true) {
            var ok = try m.forward(pat, str);
            // A run ended: the latest choice decides.
            while (m.stack.total > 0) {
                const f = m.stack.top();
                switch (f.kind) {
                    .any => {
                        if (ok or f.str[0] == 0) {
                            m.stack.pop();
                            continue;
                        }
                        f.str += 1;
                        if (!m.skip(f)) {
                            m.stack.pop();
                            continue;
                        }
                        pat = f.pat;
                        str = f.str;
                        continue :next;
                    },
                    .single => {
                        if (ok or !m.takes(f.aux, f.str[0])) {
                            m.stack.pop();
                            continue;
                        }
                        f.str += 1;
                        pat = f.pat;
                        str = f.str;
                        continue :next;
                    },
                    .not => {
                        if (ok) {
                            ok = false;
                            m.stack.pop();
                            continue;
                        }
                        // x failed: `~x` is `#?` before what follows it.
                        const rest = notEnd(f.pat);
                        if (rest[0] == 0) {
                            ok = true;
                            m.stack.pop();
                            continue;
                        }
                        f.kind = .any;
                        f.pat = rest;
                        if (!m.skip(f)) {
                            m.stack.pop();
                            continue;
                        }
                        pat = f.pat;
                        str = f.str;
                        continue :next;
                    },
                    .alt => {
                        if (ok) {
                            m.stack.pop();
                            continue;
                        }
                        const other = nextAlternative(f.pat) orelse {
                            m.stack.pop();
                            continue;
                        };
                        f.pat = other;
                        pat = other;
                        str = f.str;
                        continue :next;
                    },
                    .rep => {
                        if (!ok and f.stage == 0) {
                            f.stage = 1;
                            m.rep = f;
                            pat = f.pat;
                            str = f.str;
                            continue :next;
                        }
                        if (f.stage == 1) m.rep = f.outer;
                        m.stack.pop();
                    },
                    .cont => {
                        m.rep = f.outer;
                        m.stack.pop();
                    },
                }
            }
            return ok;
        }
    }
};

/// Matches a string against parsed tokens.
///
/// INPUTS:
/// - `ub` - the library: its `sys_base` for the frames' memory, and itself
///   for `ToUpper`.
/// - `pattern` - the tokens.
/// - `string` - the string.
/// - `nocase` - puts the string's characters through `ToUpper`.
///
/// RESULT:
/// Whether the whole string matches, or `error.TooManyLevels` or
/// `error.NoFreeStore`.
///
/// OWNERSHIP:
/// The chunks taken are given back before it returns.
fn match(ub: *UtilityBase, pattern: [*:0]const u8, string: [*:0]const u8, nocase: bool) Error!bool {
    var m: Matcher = .{ .stack = .{ .sys = ub.sys_base }, .nocase = nocase, .utility = ub.iface() };
    defer m.stack.deinit();
    return m.run(pattern, string);
}

/// `ParsePattern` and `ParsePatternNoCase`: a parse, with its error as
/// IoErr.
///
/// INPUTS:
/// - `ub` - the library, whose base holds the WildStar setting.
/// - `source` - the pattern.
/// - `dest` - the output buffer.
/// - `size` - its bytes.
/// - `nocase` - puts the pattern's characters through `ToUpper`.
///
/// RESULT:
/// 1 with wildcards, 0 without, -1 on failure.
pub fn parseWith(ub: *UtilityBase, source: [*:0]const u8, dest: [*]u8, size: usize, nocase: bool) isize {
    const wild = parse(ub, source, dest[0..size], nocase, ub.wild_star) catch |e| {
        setIoErr(ub, code(e));
        return -1;
    };
    return @intFromBool(wild);
}

/// `MatchPattern` and `MatchPatternNoCase`: a match, with its error as
/// IoErr.
///
/// INPUTS:
/// - `ub` - the library.
/// - `pattern` - the tokens.
/// - `string` - the string.
/// - `nocase` - puts the string's characters through `ToUpper`.
///
/// RESULT:
/// Whether the string matches; false also on failure.
pub fn matchWith(ub: *UtilityBase, pattern: [*:0]const u8, string: [*:0]const u8, nocase: bool) bool {
    return match(ub, pattern, string, nocase) catch |e| {
        setIoErr(ub, code(e));
        return false;
    };
}

/// Sets the IoErr of the calling process (`pr_Result2`), as dos's SetIoErr
/// does. A plain task has none, and is left alone.
///
/// INPUTS:
/// - `ub` - the library, whose `sys_base` finds the caller.
/// - `error_code` - the code.
fn setIoErr(ub: *UtilityBase, error_code: i32) void {
    const task = ub.sys_base.FindTask(null) orelse return;
    if (task.node.type != .process) return;
    const proc: *sdk.dos.Process = @fieldParentPtr("task", task);
    proc.result2 = error_code;
}
