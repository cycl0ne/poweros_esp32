// SPDX-License-Identifier: MIT
//! Working out a formula: its code run over a stack of values.
//!
//! `evaluate` reads the formula's text into code (`formula.compile`) and
//! runs it: an operand pushes a value, an operator or a function takes
//! its operands off the top and pushes its answer. The cells the formula
//! names are asked of a context the caller hands in - `cellValue` for one
//! cell, `eachInRange` for the cells of a range that hold something - so
//! the same code serves the sheet and its tests.
//!
//! Values keep to a spreadsheet's rules. An error in an operand is the
//! answer, whatever the operator. Arithmetic takes an empty cell as 0, a
//! truth value as 1 or 0 and a text that reads as a number as that number;
//! any other text is `#VALUE!`. The functions over many values (SUM,
//! AVERAGE, ...) take the numbers of a range and pass over its texts,
//! truth values and empty cells - and a reference counts as a range of one
//! cell, while a value written into the formula itself counts as given.
//! Text joined with `&` and the text functions' answers are kept in the
//! scratch block, so a formula's answer is good until the next one is
//! worked out.

const formula = @import("formula.zig");
const number = @import("number.zig");

const Op = formula.Op;
const Func = formula.Func;

/// What a value can be wrong with, as a spreadsheet shows it.
pub const Error = enum(u8) {
    div0,
    value,
    ref,
    name,
    num,
    circular,
    syntax,
};

/// How an error is shown in its cell.
pub fn errorText(err: Error) []const u8 {
    return switch (err) {
        .div0 => "#DIV/0!",
        .value => "#VALUE!",
        .ref => "#REF!",
        .name => "#NAME?",
        .num => "#NUM!",
        .circular => "#CIRC!",
        .syntax => "#SYNTAX!",
    };
}

pub const Kind = enum(u8) { empty, number, text, boolean, err, range };

pub const Value = struct {
    kind: Kind = .empty,
    /// The number, or a truth value's 1 or 0.
    number: f64 = 0,
    text: []const u8 = "",
    err: Error = .value,
    /// A range's corners, the first the smaller.
    row: u16 = 0,
    col: u16 = 0,
    row2: u16 = 0,
    col2: u16 = 0,
    /// Read from a cell rather than written into the formula.
    from_cell: bool = false,

    pub fn ofNumber(value: f64) Value {
        if (value - value != 0) return ofError(.num);
        return .{ .kind = .number, .number = value };
    }

    pub fn ofError(err: Error) Value {
        return .{ .kind = .err, .err = err };
    }

    pub fn ofBoolean(truth: bool) Value {
        return .{ .kind = .boolean, .number = if (truth) 1 else 0 };
    }

    pub fn ofText(text: []const u8) Value {
        return .{ .kind = .text, .text = text };
    }
};

/// The room a formula is worked out in: its code, its stack of values and
/// the text it makes. Allocated once and used for every formula in turn.
pub const Scratch = struct {
    ops: [256]Op = undefined,
    values: [64]Value = undefined,
    text: [1024]u8 = undefined,
    text_used: usize = 0,

    /// Room for `length` bytes of text, or null when there is none left.
    fn room(scratch: *Scratch, length: usize) ?[]u8 {
        if (scratch.text.len - scratch.text_used < length) return null;
        const part = scratch.text[scratch.text_used..][0..length];
        scratch.text_used += length;
        return part;
    }
};

// --- turning values into what an operator wants -----------------------------

fn isSpace(char: u8) bool {
    return char == ' ';
}

/// A value as a number, or the error it is.
pub fn toNumber(value: Value) union(enum) { ok: f64, err: Error } {
    return switch (value.kind) {
        .number, .boolean => .{ .ok = value.number },
        .empty => .{ .ok = 0 },
        .text => if (number.parse(value.text)) |parsed| .{ .ok = parsed } else .{ .err = .value },
        .err => .{ .err = value.err },
        .range => .{ .err = .value },
    };
}

/// A value as text in the scratch block (a number in up to 15 digits,
/// TRUE or FALSE, an empty cell as nothing), or the error it is.
fn toText(scratch: *Scratch, value: Value) union(enum) { ok: []const u8, err: Error } {
    switch (value.kind) {
        .text => return .{ .ok = value.text },
        .empty => return .{ .ok = "" },
        .boolean => return .{ .ok = if (value.number != 0) "TRUE" else "FALSE" },
        .number => {
            var digits: [32]u8 = undefined;
            const text = number.format(value.number, number.max_digits, &digits);
            const kept = scratch.room(text.len) orelse return .{ .err = .value };
            @memcpy(kept, text);
            return .{ .ok = kept };
        },
        .err => return .{ .err = value.err },
        .range => return .{ .err = .value },
    }
}

/// A value as a truth: a number other than 0, or the error it is. Text
/// that is not TRUE or FALSE is no truth.
fn toTruth(value: Value) union(enum) { ok: bool, err: Error } {
    return switch (value.kind) {
        .number, .boolean => .{ .ok = value.number != 0 },
        .empty => .{ .ok = false },
        .text => if (sameWord(value.text, "TRUE")) .{ .ok = true } else if (sameWord(value.text, "FALSE")) .{ .ok = false } else .{ .err = .value },
        .err => .{ .err = value.err },
        .range => .{ .err = .value },
    };
}

fn upperOf(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 32 else char;
}

fn lowerOf(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

fn sameWord(text: []const u8, word: []const u8) bool {
    if (text.len != word.len) return false;
    for (text, word) |char, wanted| {
        if (upperOf(char) != wanted) return false;
    }
    return true;
}

/// Two values in order: numbers before texts before truth values, texts
/// without regard to case; an empty cell is what the other side is when it
/// is nothing - 0, "" or FALSE. -1, 0 or 1.
fn compare(left_given: Value, right_given: Value) i32 {
    var left = left_given;
    var right = right_given;
    if (left.kind == .empty) left = emptyLike(right);
    if (right.kind == .empty) right = emptyLike(left);
    const left_rank = rankOf(left.kind);
    const right_rank = rankOf(right.kind);
    if (left_rank != right_rank) return if (left_rank < right_rank) -1 else 1;
    if (left.kind == .text) {
        const shorter = @min(left.text.len, right.text.len);
        for (left.text[0..shorter], right.text[0..shorter]) |left_char, right_char| {
            const one = upperOf(left_char);
            const other = upperOf(right_char);
            if (one != other) return if (one < other) -1 else 1;
        }
        if (left.text.len == right.text.len) return 0;
        return if (left.text.len < right.text.len) -1 else 1;
    }
    if (left.number == right.number) return 0;
    return if (left.number < right.number) -1 else 1;
}

fn emptyLike(other: Value) Value {
    return switch (other.kind) {
        .text => Value.ofText(""),
        .boolean => Value.ofBoolean(false),
        else => Value.ofNumber(0),
    };
}

fn rankOf(kind: Kind) u8 {
    return switch (kind) {
        .text => 1,
        .boolean => 2,
        else => 0,
    };
}

// --- arithmetic ---------------------------------------------------------------

/// `base` to the power `exponent`: a whole exponent by multiplying, any
/// other through exp and ln, which a negative base has no answer for.
pub fn power(base: f64, exponent: f64) Value {
    if (base == 0) {
        if (exponent > 0) return Value.ofNumber(0);
        if (exponent == 0) return Value.ofError(.num);
        return Value.ofError(.div0);
    }
    if (exponent == @floor(exponent) and @abs(exponent) <= 4096) {
        var left: u32 = @intFromFloat(@abs(exponent));
        var factor = base;
        var result: f64 = 1;
        while (left != 0) : (left >>= 1) {
            if (left & 1 != 0) result *= factor;
            factor *= factor;
        }
        return Value.ofNumber(if (exponent < 0) 1 / result else result);
    }
    if (base < 0) return Value.ofError(.num);
    return Value.ofNumber(@exp(exponent * @log(base)));
}

/// `value` rounded to `places` decimals, halves away from zero; a
/// negative count rounds to tens, hundreds, ...
fn roundTo(value: f64, places: f64) f64 {
    const whole: i32 = @intFromFloat(@max(-15, @min(15, @trunc(places))));
    const scale = number.tenTo(whole);
    return @round(value * scale) / scale;
}

fn binary(scratch: *Scratch, code: formula.Code, a: Value, b: Value) Value {
    switch (code) {
        .concat => {
            const left = switch (toText(scratch, a)) {
                .ok => |text| text,
                .err => |err| return Value.ofError(err),
            };
            const right = switch (toText(scratch, b)) {
                .ok => |text| text,
                .err => |err| return Value.ofError(err),
            };
            if (left.len + right.len > formula.max_input) return Value.ofError(.value);
            const joined = scratch.room(left.len + right.len) orelse return Value.ofError(.value);
            @memcpy(joined[0..left.len], left);
            @memcpy(joined[left.len..], right);
            return Value.ofText(joined);
        },
        .eq, .ne, .lt, .gt, .le, .ge => {
            if (a.kind == .err) return a;
            if (b.kind == .err) return b;
            if (a.kind == .range or b.kind == .range) return Value.ofError(.value);
            const order = compare(a, b);
            return Value.ofBoolean(switch (code) {
                .eq => order == 0,
                .ne => order != 0,
                .lt => order < 0,
                .gt => order > 0,
                .le => order <= 0,
                else => order >= 0,
            });
        },
        else => {},
    }
    const left = switch (toNumber(a)) {
        .ok => |value| value,
        .err => |err| return Value.ofError(err),
    };
    const right = switch (toNumber(b)) {
        .ok => |value| value,
        .err => |err| return Value.ofError(err),
    };
    return switch (code) {
        .add => Value.ofNumber(left + right),
        .sub => Value.ofNumber(left - right),
        .mul => Value.ofNumber(left * right),
        .div => if (right == 0) Value.ofError(.div0) else Value.ofNumber(left / right),
        .pow => power(left, right),
        else => Value.ofError(.value),
    };
}

// --- functions over many values ---------------------------------------------

/// What SUM, AVERAGE, MIN, MAX, COUNT, COUNTA, PRODUCT, AND and OR gather
/// from their arguments.
const Gather = struct {
    func: Func,
    sum: f64 = 0,
    product: f64 = 1,
    least: f64 = 0,
    most: f64 = 0,
    numbers: u32 = 0,
    filled: u32 = 0,
    truths: u32 = 0,
    all_true: bool = true,
    any_true: bool = false,
    err: ?Error = null,

    fn takeNumber(gather: *Gather, value: f64) void {
        if (gather.numbers == 0 or value < gather.least) gather.least = value;
        if (gather.numbers == 0 or value > gather.most) gather.most = value;
        gather.numbers += 1;
        gather.sum += value;
        gather.product *= value;
        gather.takeTruth(value != 0);
    }

    fn takeTruth(gather: *Gather, truth: bool) void {
        gather.truths += 1;
        if (truth) gather.any_true = true else gather.all_true = false;
    }

    fn takeError(gather: *Gather, err: Error) void {
        gather.filled += 1;
        // COUNT and COUNTA count; an error is no number, and is something.
        if (gather.func == .count or gather.func == .counta) return;
        if (gather.err == null) gather.err = err;
    }

    /// A cell of a range, or one a reference names: its numbers count,
    /// its texts and truth values only as something there.
    pub fn visit(gather: *Gather, value: Value) void {
        switch (value.kind) {
            .number => {
                gather.filled += 1;
                gather.takeNumber(value.number);
            },
            .text => gather.filled += 1,
            .boolean => {
                gather.filled += 1;
                if (gather.func == .@"and" or gather.func == .@"or") gather.takeTruth(value.number != 0);
            },
            .err => gather.takeError(value.err),
            .empty, .range => {},
        }
    }

    /// A value written into the formula: a truth value counts as 1 or 0,
    /// a text as the number it reads as.
    fn given(gather: *Gather, value: Value) void {
        switch (value.kind) {
            .number, .boolean => {
                gather.filled += 1;
                gather.takeNumber(value.number);
            },
            .text => {
                gather.filled += 1;
                if (number.parse(value.text)) |parsed| {
                    gather.takeNumber(parsed);
                } else if (gather.func != .count and gather.func != .counta) {
                    if (gather.err == null) gather.err = .value;
                }
            },
            .err => gather.takeError(value.err),
            .empty, .range => {},
        }
    }

    fn answer(gather: *Gather) Value {
        if (gather.err) |err| return Value.ofError(err);
        return switch (gather.func) {
            .sum => Value.ofNumber(gather.sum),
            .average => if (gather.numbers == 0) Value.ofError(.div0) else Value.ofNumber(gather.sum / @as(f64, @floatFromInt(gather.numbers))),
            .min => Value.ofNumber(if (gather.numbers == 0) 0 else gather.least),
            .max => Value.ofNumber(if (gather.numbers == 0) 0 else gather.most),
            .count => Value.ofNumber(@floatFromInt(gather.numbers)),
            .counta => Value.ofNumber(@floatFromInt(gather.filled)),
            .product => Value.ofNumber(if (gather.numbers == 0) 0 else gather.product),
            .@"and" => if (gather.truths == 0) Value.ofError(.value) else Value.ofBoolean(gather.all_true),
            .@"or" => if (gather.truths == 0) Value.ofError(.value) else Value.ofBoolean(gather.any_true),
            else => Value.ofError(.value),
        };
    }
};

fn numberArg(value: Value) union(enum) { ok: f64, err: Value } {
    return switch (toNumber(value)) {
        .ok => |parsed| .{ .ok = parsed },
        .err => |err| .{ .err = Value.ofError(err) },
    };
}

fn call(context: anytype, scratch: *Scratch, func: Func, args: []const Value) Value {
    switch (func) {
        .sum, .average, .min, .max, .count, .counta, .product, .@"and", .@"or" => {
            var gather = Gather{ .func = func };
            for (args) |arg| {
                if (arg.kind == .range) {
                    context.eachInRange(arg.row, arg.col, arg.row2, arg.col2, &gather);
                } else if (arg.from_cell) {
                    gather.visit(arg);
                } else gather.given(arg);
            }
            return gather.answer();
        },
        .pi => return Value.ofNumber(3.14159265358979323846),
        .@"if" => {
            const truth = switch (toTruth(args[0])) {
                .ok => |truth| truth,
                .err => |err| return Value.ofError(err),
            };
            const chosen = if (truth) args[1] else if (args.len > 2) args[2] else return Value.ofBoolean(false);
            if (chosen.kind == .range) return Value.ofError(.value);
            // An empty cell chosen is shown as 0, as a formula naming it is.
            if (chosen.kind == .empty) return Value.ofNumber(0);
            return chosen;
        },
        .not => return switch (toTruth(args[0])) {
            .ok => |truth| Value.ofBoolean(!truth),
            .err => |err| Value.ofError(err),
        },
        .len, .upper, .lower => {
            const text = switch (toText(scratch, args[0])) {
                .ok => |text| text,
                .err => |err| return Value.ofError(err),
            };
            if (func == .len) return Value.ofNumber(@floatFromInt(text.len));
            const changed = scratch.room(text.len) orelse return Value.ofError(.value);
            for (text, changed) |char, *into| into.* = if (func == .upper) upperOf(char) else lowerOf(char);
            return Value.ofText(changed);
        },
        else => {},
    }
    // The rest take numbers: the first, and for some a second.
    const first = switch (numberArg(args[0])) {
        .ok => |value| value,
        .err => |err| return err,
    };
    const second: f64 = if (args.len > 1) switch (numberArg(args[1])) {
        .ok => |value| value,
        .err => |err| return err,
    } else 0;
    return switch (func) {
        .abs => Value.ofNumber(@abs(first)),
        .sqrt => if (first < 0) Value.ofError(.num) else Value.ofNumber(@sqrt(first)),
        .round => Value.ofNumber(roundTo(first, second)),
        .int => Value.ofNumber(@floor(first)),
        .mod => if (second == 0) Value.ofError(.div0) else Value.ofNumber(first - second * @floor(first / second)),
        .power => power(first, second),
        .exp => Value.ofNumber(@exp(first)),
        .ln => if (first <= 0) Value.ofError(.num) else Value.ofNumber(@log(first)),
        .log10 => if (first <= 0) Value.ofError(.num) else Value.ofNumber(@log10(first)),
        .sin => Value.ofNumber(@sin(first)),
        .cos => Value.ofNumber(@cos(first)),
        .tan => Value.ofNumber(@tan(first)),
        else => Value.ofError(.value),
    };
}

// --- running the code -------------------------------------------------------

/// The text between a formula's quotes, its doubled quotes made single, in
/// the scratch block.
fn literal(scratch: *Scratch, quoted: []const u8) ?[]const u8 {
    var doubled: usize = 0;
    var at: usize = 0;
    while (at < quoted.len) : (at += 1) {
        if (quoted[at] == '"') {
            doubled += 1;
            at += 1;
        }
    }
    if (doubled == 0) return quoted;
    const text = scratch.room(quoted.len - doubled) orelse return null;
    var used: usize = 0;
    at = 0;
    while (at < quoted.len) : (at += 1) {
        text[used] = quoted[at];
        used += 1;
        if (quoted[at] == '"') at += 1;
    }
    return text;
}

/// What the formula `text` (from its `=`) works out to, its cells asked of
/// `context`:
///
///   context.cellValue(row: u32, col: u32) Value
///   context.eachInRange(row, col, row2, col2: u16, gather: anytype) void
///       - each cell of the range that holds something handed to
///         `gather.visit(value)`
///
/// A text answer lives in `scratch`, or in the formula's text or a cell's,
/// until the next formula is worked out.
pub fn evaluate(context: anytype, scratch: *Scratch, text: []const u8) Value {
    scratch.text_used = 0;
    const compiled = formula.compile(text, &scratch.ops);
    if (compiled.problem != .none) {
        return Value.ofError(if (compiled.problem == .unknown_name) .name else .syntax);
    }
    const values = &scratch.values;
    var depth: usize = 0;
    for (scratch.ops[0..compiled.count]) |op| {
        var pushed: Value = undefined;
        switch (op.code) {
            .number => pushed = Value.ofNumber(op.number),
            .boolean => pushed = Value.ofBoolean(op.number != 0),
            .text => pushed = Value.ofText(literal(scratch, text[op.start..][0..op.len]) orelse return Value.ofError(.value)),
            .ref => {
                pushed = context.cellValue(op.row, op.col);
                pushed.from_cell = true;
            },
            .range => pushed = .{ .kind = .range, .row = op.row, .col = op.col, .row2 = op.row2, .col2 = op.col2 },
            .bad_ref => pushed = Value.ofError(.ref),
            .neg, .percent => {
                if (depth < 1) return Value.ofError(.syntax);
                const operand = switch (toNumber(values[depth - 1])) {
                    .ok => |value| value,
                    .err => |err| {
                        values[depth - 1] = Value.ofError(err);
                        continue;
                    },
                };
                values[depth - 1] = Value.ofNumber(if (op.code == .neg) -operand else operand / 100);
                continue;
            },
            .call => {
                if (depth < op.count) return Value.ofError(.syntax);
                const args = values[depth - op.count .. depth];
                const answer = call(context, scratch, op.func, args);
                depth -= op.count;
                pushed = answer;
            },
            else => {
                if (depth < 2) return Value.ofError(.syntax);
                const answer = binary(scratch, op.code, values[depth - 2], values[depth - 1]);
                depth -= 2;
                pushed = answer;
            },
        }
        if (depth == values.len) return Value.ofError(.value);
        values[depth] = pushed;
        depth += 1;
    }
    if (depth != 1) return Value.ofError(.syntax);
    var result = values[0];
    result.from_cell = false;
    return switch (result.kind) {
        // A formula that only names a range has no one value.
        .range => Value.ofError(.value),
        // One that names an empty cell shows 0.
        .empty => Value.ofNumber(0),
        else => result,
    };
}
