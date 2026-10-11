// SPDX-License-Identifier: MIT
//! Formulas: the text of a cell that starts with `=`, read into code that
//! works it out.
//!
//! A formula is read in one pass from left to right (a shunting yard) into
//! postfix code: each operand is an instruction that pushes a value, each
//! operator and function an instruction that takes its operands off the
//! top and pushes the answer. Working the code out needs a stack of values
//! and no recursion, however deeply the formula nests, which matters on a
//! program's stack of 16 KiB.
//!
//! What a formula may say:
//!
//!   numbers      12, 1.5, 2E3, 15%
//!   text         "in quotes", "" for a quote inside
//!   TRUE, FALSE
//!   references   B7, $B$7 (the $ keeps a part when the formula is copied)
//!   ranges       A1:C4, in a function's arguments
//!   operators    - (negation), % (a hundredth), ^, * /, + -, & (joins
//!                text), = <> < > <= >= - in that order of binding, each
//!                left to right
//!   functions    the names in `functions`, with their arguments in
//!                parentheses, split by commas
//!
//! The same reading drives `rewrite`, which moves the references in a
//! formula's text as it is copied, or as rows and columns are put in and
//! taken out: the text keeps its spacing and its case, and only the
//! references change.

const number = @import("number.zig");

/// The sheet's size: rows 1 to 9999 and columns A to IV.
pub const max_rows: u32 = 9999;
pub const max_cols: u32 = 256;

/// The longest text a cell holds.
pub const max_input: u32 = 255;

/// A reference: a cell, and which of its parts stay when the formula is
/// copied (`$`).
pub const Ref = struct {
    row: u32,
    col: u32,
    row_fixed: bool = false,
    col_fixed: bool = false,
};

// --- names ------------------------------------------------------------------

/// The letters of column `col`: A to Z, then AA to IV. Written into
/// `out`; the text.
pub fn columnName(col: u32, out: *[2]u8) []const u8 {
    if (col < 26) {
        out[0] = 'A' + @as(u8, @intCast(col));
        return out[0..1];
    }
    out[0] = 'A' + @as(u8, @intCast(col / 26 - 1));
    out[1] = 'A' + @as(u8, @intCast(col % 26));
    return out[0..2];
}

/// The name of a cell, `B7`, written into `out`; the text.
pub fn cellName(row: u32, col: u32, out: *[8]u8) []const u8 {
    var letters: [2]u8 = undefined;
    const column = columnName(col, &letters);
    @memcpy(out[0..column.len], column);
    var digits: [4]u8 = undefined;
    var left = row + 1;
    var at: usize = digits.len;
    while (true) {
        at -= 1;
        digits[at] = '0' + @as(u8, @intCast(left % 10));
        left /= 10;
        if (left == 0) break;
    }
    const count = digits.len - at;
    @memcpy(out[column.len..][0..count], digits[at..]);
    return out[0 .. column.len + count];
}

fn isLetter(char: u8) bool {
    return (char >= 'A' and char <= 'Z') or (char >= 'a' and char <= 'z');
}

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 32 else char;
}

/// A reference at the start of `text` and how many bytes it takes, or
/// null: one or two letters, a row number, a `$` in front of either, and
/// nothing after that would make it a longer word. A place off the sheet
/// is no reference.
pub fn readRef(text: []const u8) ?struct { ref: Ref, len: usize } {
    var at: usize = 0;
    var ref = Ref{ .row = 0, .col = 0 };
    if (at < text.len and text[at] == '$') {
        ref.col_fixed = true;
        at += 1;
    }
    const letters_at = at;
    while (at < text.len and isLetter(text[at])) at += 1;
    const letters = at - letters_at;
    if (letters < 1 or letters > 2) return null;
    var col: u32 = upper(text[letters_at]) - 'A';
    if (letters == 2) col = (col + 1) * 26 + (upper(text[letters_at + 1]) - 'A');
    if (at < text.len and text[at] == '$') {
        ref.row_fixed = true;
        at += 1;
    }
    const digits_at = at;
    var row: u32 = 0;
    while (at < text.len and isDigit(text[at])) : (at += 1) {
        if (row <= max_rows) row = row * 10 + (text[at] - '0');
    }
    if (at == digits_at or text[digits_at] == '0') return null;
    if (at < text.len and (isLetter(text[at]) or isDigit(text[at]) or text[at] == '_')) return null;
    if (row > max_rows or col >= max_cols) return null;
    ref.row = row - 1;
    ref.col = col;
    return .{ .ref = ref, .len = at };
}

/// A reference written as text, its `$`s as it has them.
pub fn writeRef(ref: Ref, out: *[10]u8) []const u8 {
    var used: usize = 0;
    if (ref.col_fixed) {
        out[0] = '$';
        used = 1;
    }
    var letters: [2]u8 = undefined;
    const column = columnName(ref.col, &letters);
    @memcpy(out[used..][0..column.len], column);
    used += column.len;
    if (ref.row_fixed) {
        out[used] = '$';
        used += 1;
    }
    var name: [8]u8 = undefined;
    const whole = cellName(ref.row, 0, &name);
    // The row's digits are what follows the one letter of column A.
    @memcpy(out[used..][0 .. whole.len - 1], whole[1..]);
    used += whole.len - 1;
    return out[0..used];
}

// --- functions --------------------------------------------------------------

pub const Func = enum(u8) {
    sum,
    average,
    min,
    max,
    count,
    counta,
    product,
    abs,
    sqrt,
    round,
    int,
    mod,
    power,
    exp,
    ln,
    log10,
    sin,
    cos,
    tan,
    pi,
    @"if",
    @"and",
    @"or",
    not,
    len,
    upper,
    lower,
};

/// No limit to the arguments.
const many: u8 = 255;

/// The functions by name, with how many arguments each takes.
pub const functions = [_]struct { name: []const u8, func: Func, min: u8, max: u8 }{
    .{ .name = "SUM", .func = .sum, .min = 1, .max = many },
    .{ .name = "AVERAGE", .func = .average, .min = 1, .max = many },
    .{ .name = "MIN", .func = .min, .min = 1, .max = many },
    .{ .name = "MAX", .func = .max, .min = 1, .max = many },
    .{ .name = "COUNT", .func = .count, .min = 1, .max = many },
    .{ .name = "COUNTA", .func = .counta, .min = 1, .max = many },
    .{ .name = "PRODUCT", .func = .product, .min = 1, .max = many },
    .{ .name = "ABS", .func = .abs, .min = 1, .max = 1 },
    .{ .name = "SQRT", .func = .sqrt, .min = 1, .max = 1 },
    .{ .name = "ROUND", .func = .round, .min = 1, .max = 2 },
    .{ .name = "INT", .func = .int, .min = 1, .max = 1 },
    .{ .name = "MOD", .func = .mod, .min = 2, .max = 2 },
    .{ .name = "POWER", .func = .power, .min = 2, .max = 2 },
    .{ .name = "EXP", .func = .exp, .min = 1, .max = 1 },
    .{ .name = "LN", .func = .ln, .min = 1, .max = 1 },
    .{ .name = "LOG10", .func = .log10, .min = 1, .max = 1 },
    .{ .name = "SIN", .func = .sin, .min = 1, .max = 1 },
    .{ .name = "COS", .func = .cos, .min = 1, .max = 1 },
    .{ .name = "TAN", .func = .tan, .min = 1, .max = 1 },
    .{ .name = "PI", .func = .pi, .min = 0, .max = 0 },
    .{ .name = "IF", .func = .@"if", .min = 2, .max = 3 },
    .{ .name = "AND", .func = .@"and", .min = 1, .max = many },
    .{ .name = "OR", .func = .@"or", .min = 1, .max = many },
    .{ .name = "NOT", .func = .not, .min = 1, .max = 1 },
    .{ .name = "LEN", .func = .len, .min = 1, .max = 1 },
    .{ .name = "UPPER", .func = .upper, .min = 1, .max = 1 },
    .{ .name = "LOWER", .func = .lower, .min = 1, .max = 1 },
};

fn sameName(word: []const u8, name: []const u8) bool {
    if (word.len != name.len) return false;
    for (word, name) |char, wanted| {
        if (upper(char) != wanted) return false;
    }
    return true;
}

fn functionNamed(word: []const u8) ?usize {
    for (functions, 0..) |entry, index| {
        if (sameName(word, entry.name)) return index;
    }
    return null;
}

// --- reading ----------------------------------------------------------------

pub const Code = enum(u8) {
    /// Pushes `number`.
    number,
    /// Pushes the text between the quotes at `start`, `len` bytes, its
    /// doubled quotes still doubled.
    text,
    /// Pushes TRUE or FALSE (`number` 1 or 0).
    boolean,
    /// Pushes the value of the cell at `row`, `col`.
    ref,
    /// Pushes the range `row`, `col` to `row2`, `col2`.
    range,
    /// Pushes the error a reference to a deleted cell is.
    bad_ref,
    neg,
    percent,
    pow,
    mul,
    div,
    add,
    sub,
    concat,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    /// Takes `count` arguments and pushes `func`'s answer.
    call,
};

/// One instruction of a formula's code.
pub const Op = struct {
    code: Code,
    func: Func = .sum,
    count: u8 = 0,
    row: u16 = 0,
    col: u16 = 0,
    row2: u16 = 0,
    col2: u16 = 0,
    start: u16 = 0,
    len: u16 = 0,
    number: f64 = 0,
};

/// How strongly an operator binds; all bind left to right.
fn precedence(code: Code) u8 {
    return switch (code) {
        .neg => 7,
        .percent => 6,
        .pow => 5,
        .mul, .div => 4,
        .add, .sub => 3,
        .concat => 2,
        .eq, .ne, .lt, .gt, .le, .ge => 1,
        else => 0,
    };
}

const TokenKind = enum { number, text, ref, range, bad_ref, name, op, open, close, comma, end, bad };

const Token = struct {
    kind: TokenKind,
    start: usize,
    len: usize,
    ref: Ref = .{ .row = 0, .col = 0 },
    ref2: Ref = .{ .row = 0, .col = 0 },
    number: f64 = 0,
    op: Code = .add,
};

/// The words of a formula, one at a time.
const Lexer = struct {
    text: []const u8,
    at: usize,

    fn skipSpaces(lexer: *Lexer) void {
        while (lexer.at < lexer.text.len and lexer.text[lexer.at] == ' ') lexer.at += 1;
    }

    fn peekChar(lexer: *Lexer) u8 {
        lexer.skipSpaces();
        return if (lexer.at < lexer.text.len) lexer.text[lexer.at] else 0;
    }

    fn next(lexer: *Lexer) Token {
        lexer.skipSpaces();
        const text = lexer.text;
        const start = lexer.at;
        if (start >= text.len) return .{ .kind = .end, .start = start, .len = 0 };
        const char = text[start];

        // A number: digits and a point, an exponent after them.
        if (isDigit(char) or (char == '.' and start + 1 < text.len and isDigit(text[start + 1]))) {
            var at = start;
            while (at < text.len and (isDigit(text[at]) or text[at] == '.')) at += 1;
            if (at < text.len and (text[at] == 'e' or text[at] == 'E')) {
                var exponent_at = at + 1;
                if (exponent_at < text.len and (text[exponent_at] == '+' or text[exponent_at] == '-')) exponent_at += 1;
                if (exponent_at < text.len and isDigit(text[exponent_at])) {
                    at = exponent_at;
                    while (at < text.len and isDigit(text[at])) at += 1;
                }
            }
            lexer.at = at;
            const value = number.parse(text[start..at]) orelse return .{ .kind = .bad, .start = start, .len = at - start };
            return .{ .kind = .number, .start = start, .len = at - start, .number = value };
        }

        // Text in quotes, a doubled quote standing for one.
        if (char == '"') {
            var at = start + 1;
            while (at < text.len) {
                if (text[at] == '"') {
                    if (at + 1 < text.len and text[at + 1] == '"') {
                        at += 2;
                        continue;
                    }
                    lexer.at = at + 1;
                    return .{ .kind = .text, .start = start, .len = at + 1 - start };
                }
                at += 1;
            }
            lexer.at = text.len;
            return .{ .kind = .bad, .start = start, .len = text.len - start };
        }

        // A reference, or two joined into a range.
        if (char == '$' or isLetter(char)) {
            if (readRef(text[start..])) |first| {
                lexer.at = start + first.len;
                const after = lexer.at;
                if (lexer.peekChar() == ':') {
                    const colon = lexer.at;
                    lexer.at += 1;
                    lexer.skipSpaces();
                    if (readRef(text[lexer.at..])) |second| {
                        lexer.at += second.len;
                        return .{ .kind = .range, .start = start, .len = lexer.at - start, .ref = first.ref, .ref2 = second.ref };
                    }
                    lexer.at = colon;
                    return .{ .kind = .bad, .start = colon, .len = 1 };
                }
                lexer.at = after;
                return .{ .kind = .ref, .start = start, .len = first.len, .ref = first.ref };
            }
            if (char == '$') {
                lexer.at = start + 1;
                return .{ .kind = .bad, .start = start, .len = 1 };
            }
            var at = start;
            while (at < text.len and (isLetter(text[at]) or isDigit(text[at]) or text[at] == '_' or text[at] == '.')) at += 1;
            lexer.at = at;
            return .{ .kind = .name, .start = start, .len = at - start };
        }

        // What a deleted cell's reference became.
        if (char == '#') {
            const word = "#REF!";
            if (text.len - start >= word.len and sameName(text[start..][0..word.len], word)) {
                lexer.at = start + word.len;
                return .{ .kind = .bad_ref, .start = start, .len = word.len };
            }
            lexer.at = start + 1;
            return .{ .kind = .bad, .start = start, .len = 1 };
        }

        lexer.at = start + 1;
        const second: u8 = if (start + 1 < text.len) text[start + 1] else 0;
        const kind_op: ?Code = switch (char) {
            '+' => .add,
            '-' => .sub,
            '*' => .mul,
            '/' => .div,
            '^' => .pow,
            '&' => .concat,
            '%' => .percent,
            '=' => .eq,
            '<' => if (second == '>') .ne else if (second == '=') .le else .lt,
            '>' => if (second == '=') .ge else .gt,
            else => null,
        };
        if (kind_op) |code| {
            if (code == .ne or code == .le or code == .ge) lexer.at += 1;
            return .{ .kind = .op, .start = start, .len = lexer.at - start, .op = code };
        }
        return switch (char) {
            '(' => .{ .kind = .open, .start = start, .len = 1 },
            ')' => .{ .kind = .close, .start = start, .len = 1 },
            ',' => .{ .kind = .comma, .start = start, .len = 1 },
            else => .{ .kind = .bad, .start = start, .len = 1 },
        };
    }
};

/// What can be wrong with a formula's text.
pub const Problem = enum {
    none,
    /// Something where it does not belong: `at` says where.
    syntax,
    /// A name that is no function and no reference.
    unknown_name,
    /// A function given too few or too many arguments.
    arguments,
    /// A parenthesis without its partner.
    parentheses,
    /// More than the code or the stack has room for.
    too_long,
};

pub const Compiled = struct {
    /// The instructions written, when there is no problem.
    count: usize = 0,
    problem: Problem = .none,
    /// Where in the text the problem was found.
    at: usize = 0,
};

/// One operator waiting on the stack.
const Waiting = struct {
    kind: enum { op, open, call },
    code: Code = .add,
    func: u8 = 0,
    count: u8 = 0,
};

/// The deepest the operators may nest while a formula is read.
const max_waiting = 48;

/// The code of the formula in `text` (from its `=`, which is skipped)
/// written into `out`.
pub fn compile(text: []const u8, out: []Op) Compiled {
    var lexer = Lexer{ .text = text, .at = if (text.len > 0 and text[0] == '=') 1 else 0 };
    var waiting: [max_waiting]Waiting = undefined;
    var depth: usize = 0;
    var count: usize = 0;
    var expect_operand = true;

    const Emit = struct {
        fn op(into: []Op, used: *usize, made: Op) bool {
            if (used.* == into.len) return false;
            into[used.*] = made;
            used.* += 1;
            return true;
        }
    };

    while (true) {
        const token = lexer.next();
        const fail = Compiled{ .problem = .syntax, .at = token.start };
        const full = Compiled{ .problem = .too_long, .at = token.start };
        if (expect_operand) {
            switch (token.kind) {
                .number => {
                    if (!Emit.op(out, &count, .{ .code = .number, .number = token.number })) return full;
                    expect_operand = false;
                },
                .text => {
                    if (!Emit.op(out, &count, .{ .code = .text, .start = @intCast(token.start + 1), .len = @intCast(token.len - 2) })) return full;
                    expect_operand = false;
                },
                .ref => {
                    if (!Emit.op(out, &count, .{ .code = .ref, .row = @intCast(token.ref.row), .col = @intCast(token.ref.col) })) return full;
                    expect_operand = false;
                },
                .range => {
                    const made = Op{
                        .code = .range,
                        .row = @intCast(@min(token.ref.row, token.ref2.row)),
                        .col = @intCast(@min(token.ref.col, token.ref2.col)),
                        .row2 = @intCast(@max(token.ref.row, token.ref2.row)),
                        .col2 = @intCast(@max(token.ref.col, token.ref2.col)),
                    };
                    if (!Emit.op(out, &count, made)) return full;
                    expect_operand = false;
                },
                .bad_ref => {
                    if (!Emit.op(out, &count, .{ .code = .bad_ref })) return full;
                    expect_operand = false;
                },
                .name => {
                    const word = text[token.start..][0..token.len];
                    if (lexer.peekChar() == '(') {
                        const index = functionNamed(word) orelse return .{ .problem = .unknown_name, .at = token.start };
                        _ = lexer.next();
                        if (depth == max_waiting) return full;
                        waiting[depth] = .{ .kind = .call, .func = @intCast(index) };
                        depth += 1;
                    } else if (sameName(word, "TRUE") or sameName(word, "FALSE")) {
                        if (!Emit.op(out, &count, .{ .code = .boolean, .number = if (sameName(word, "TRUE")) 1 else 0 })) return full;
                        expect_operand = false;
                    } else return .{ .problem = .unknown_name, .at = token.start };
                },
                .open => {
                    if (depth == max_waiting) return full;
                    waiting[depth] = .{ .kind = .open };
                    depth += 1;
                },
                .op => switch (token.op) {
                    .sub => {
                        if (depth == max_waiting) return full;
                        waiting[depth] = .{ .kind = .op, .code = .neg };
                        depth += 1;
                    },
                    .add => {},
                    else => return fail,
                },
                // A function with nothing between its parentheses.
                .close => {
                    if (depth == 0 or waiting[depth - 1].kind != .call or waiting[depth - 1].count != 0) return fail;
                    depth -= 1;
                    const entry = functions[waiting[depth].func];
                    if (entry.min != 0) return .{ .problem = .arguments, .at = token.start };
                    if (!Emit.op(out, &count, .{ .code = .call, .func = entry.func, .count = 0 })) return full;
                    expect_operand = false;
                },
                .end => return .{ .problem = .syntax, .at = token.start },
                else => return fail,
            }
            continue;
        }

        switch (token.kind) {
            .op => {
                const code = token.op;
                if (code == .percent) {
                    // Applied to what is just before it, after a negation.
                    while (depth > 0 and waiting[depth - 1].kind == .op and precedence(waiting[depth - 1].code) > precedence(code)) {
                        depth -= 1;
                        if (!Emit.op(out, &count, .{ .code = waiting[depth].code })) return full;
                    }
                    if (!Emit.op(out, &count, .{ .code = .percent })) return full;
                    continue;
                }
                while (depth > 0 and waiting[depth - 1].kind == .op and precedence(waiting[depth - 1].code) >= precedence(code)) {
                    depth -= 1;
                    if (!Emit.op(out, &count, .{ .code = waiting[depth].code })) return full;
                }
                if (depth == max_waiting) return full;
                waiting[depth] = .{ .kind = .op, .code = code };
                depth += 1;
                expect_operand = true;
            },
            .comma, .close => {
                while (depth > 0 and waiting[depth - 1].kind == .op) {
                    depth -= 1;
                    if (!Emit.op(out, &count, .{ .code = waiting[depth].code })) return full;
                }
                if (depth == 0) return .{ .problem = .parentheses, .at = token.start };
                const top = &waiting[depth - 1];
                if (token.kind == .comma) {
                    if (top.kind != .call) return fail;
                    if (top.count == 254) return full;
                    top.count += 1;
                    expect_operand = true;
                    continue;
                }
                depth -= 1;
                if (top.kind == .call) {
                    const entry = functions[top.func];
                    const given = top.count + 1;
                    if (given < entry.min or given > entry.max) return .{ .problem = .arguments, .at = token.start };
                    if (!Emit.op(out, &count, .{ .code = .call, .func = entry.func, .count = given })) return full;
                }
            },
            .end => {
                while (depth > 0) {
                    depth -= 1;
                    if (waiting[depth].kind != .op) return .{ .problem = .parentheses, .at = token.start };
                    if (!Emit.op(out, &count, .{ .code = waiting[depth].code })) return full;
                }
                if (count == 0) return .{ .problem = .syntax, .at = token.start };
                return .{ .count = count };
            },
            else => return fail,
        }
    }
}

// --- moving references ------------------------------------------------------

/// What happens to the references of a formula.
pub const Move = union(enum) {
    /// The formula copied this far: each part without a `$` moves by it.
    offset: struct { rows: i32, cols: i32 },
    /// `count` rows or columns put in before `at`: whatever is at or after
    /// it moves on by `count`, `$` or not.
    insert: struct { columns: bool, at: u32, count: u32 },
    /// `count` rows or columns from `at` taken out: what was in them is
    /// gone (`#REF!`), what was after them moves back by `count`, and a
    /// range shrinks by what it lost.
    delete: struct { columns: bool, at: u32, count: u32 },
};

/// One coordinate moved by an insert or a delete; null when it was in what
/// was deleted.
fn moveIndex(index: u32, columns_axis: bool, move: Move) ?u32 {
    switch (move) {
        .insert => |insert| {
            if (insert.columns != columns_axis or index < insert.at) return index;
            return index + insert.count;
        },
        .delete => |delete| {
            if (delete.columns != columns_axis or index < delete.at) return index;
            if (index < delete.at + delete.count) return null;
            return index - delete.count;
        },
        .offset => unreachable,
    }
}

/// A reference moved, or null when it now points off the sheet or at what
/// was deleted.
fn moveRef(ref: Ref, move: Move) ?Ref {
    var moved = ref;
    switch (move) {
        .offset => |offset| {
            if (!ref.row_fixed) {
                const row = @as(i64, ref.row) + offset.rows;
                if (row < 0 or row >= max_rows) return null;
                moved.row = @intCast(row);
            }
            if (!ref.col_fixed) {
                const col = @as(i64, ref.col) + offset.cols;
                if (col < 0 or col >= max_cols) return null;
                moved.col = @intCast(col);
            }
        },
        .insert, .delete => {
            moved.row = moveIndex(ref.row, false, move) orelse return null;
            moved.col = moveIndex(ref.col, true, move) orelse return null;
            if (moved.row >= max_rows or moved.col >= max_cols) return null;
        },
    }
    return moved;
}

/// A range's corners moved together: a delete takes the deleted rows or
/// columns out of the range and keeps the rest; null when nothing of it is
/// left, or a corner is off the sheet.
fn moveRange(first: Ref, second: Ref, move: Move) ?[2]Ref {
    switch (move) {
        .offset, .insert => {
            const moved_first = moveRef(first, move) orelse return null;
            const moved_second = moveRef(second, move) orelse return null;
            return .{ moved_first, moved_second };
        },
        .delete => |delete| {
            var corners = [2]Ref{ first, second };
            // The low corner and the high corner along the deleted axis.
            const first_is_low = if (delete.columns) first.col <= second.col else first.row <= second.row;
            const low = &corners[if (first_is_low) 0 else 1];
            const high = &corners[if (first_is_low) 1 else 0];
            const low_index = if (delete.columns) low.col else low.row;
            const high_index = if (delete.columns) high.col else high.row;
            const end = delete.at + delete.count;
            if (low_index >= delete.at and high_index < end) return null;
            const new_low = if (low_index < delete.at) low_index else if (low_index < end) delete.at else low_index - delete.count;
            const new_high = if (high_index < delete.at) high_index else if (high_index < end) delete.at - 1 else high_index - delete.count;
            if (delete.columns) {
                low.col = new_low;
                high.col = new_high;
                low.row = moveIndex(low.row, false, move).?;
                high.row = moveIndex(high.row, false, move).?;
            } else {
                low.row = new_low;
                high.row = new_high;
                low.col = moveIndex(low.col, true, move).?;
                high.col = moveIndex(high.col, true, move).?;
            }
            return corners;
        },
    }
}

/// `text`, a formula, with its references moved, written into `out`; the
/// text, or null when it does not fit. A reference that has nowhere left
/// to point is written `#REF!`. Text that is no formula is copied as it
/// is.
pub fn rewrite(text: []const u8, move: Move, out: []u8) ?[]const u8 {
    var used: usize = 0;
    const Put = struct {
        fn bytes(into: []u8, at: *usize, what: []const u8) bool {
            if (into.len - at.* < what.len) return false;
            @memcpy(into[at.*..][0..what.len], what);
            at.* += what.len;
            return true;
        }
    };
    if (text.len == 0 or text[0] != '=') {
        if (!Put.bytes(out, &used, text)) return null;
        return out[0..used];
    }
    var lexer = Lexer{ .text = text, .at = 1 };
    var copied: usize = 0;
    while (true) {
        const token = lexer.next();
        if (token.kind == .end) break;
        if (token.kind != .ref and token.kind != .range) continue;
        // What came before the reference, as it was.
        if (!Put.bytes(out, &used, text[copied..token.start])) return null;
        copied = token.start + token.len;
        var written: [10]u8 = undefined;
        if (token.kind == .ref) {
            const moved = moveRef(token.ref, move) orelse {
                if (!Put.bytes(out, &used, "#REF!")) return null;
                continue;
            };
            if (!Put.bytes(out, &used, writeRef(moved, &written))) return null;
            continue;
        }
        const corners = moveRange(token.ref, token.ref2, move) orelse {
            if (!Put.bytes(out, &used, "#REF!")) return null;
            continue;
        };
        if (!Put.bytes(out, &used, writeRef(corners[0], &written))) return null;
        if (!Put.bytes(out, &used, ":")) return null;
        if (!Put.bytes(out, &used, writeRef(corners[1], &written))) return null;
    }
    if (!Put.bytes(out, &used, text[copied..])) return null;
    return out[0..used];
}
