// SPDX-License-Identifier: MIT
//! Numbers between JSON's text and doubles, both ways and exactly.
//!
//! **Read** (`toDouble`): most numbers a document holds - up to nineteen
//! digits, an exponent within 22 - are a whole number of up to 2^53
//! times an exact power of ten, which one multiplication or division
//! rounds correctly (`fastDouble`). Any other goes through a `Decimal`:
//! its digits, up to 800 of them, halved and doubled by powers of two
//! until it lies in [1/2, 1), then shifted by the 53 bits a double holds
//! and rounded once, to even on a tie (`Decimal.toBits`). 800 digits are
//! as many as any double's exact value has, so what is cut beyond them
//! only ever decides a tie, which `truncated` keeps.
//!
//! **Written** (`write`): a whole number below 2^53 as its digits.
//! Anything else is made a `Decimal` exactly - its mantissa shifted by
//! its exponent - and rounded to 1, 2, ... 17 significant digits until
//! the digits read back as the same double, 17 being always enough. The
//! digits are put down as JavaScript writes a number: plainly from
//! 10^-7 to 10^21, with an exponent outside that.

/// The most digits a `Decimal` keeps.
pub const max_digits = 800;

/// The longest text `write` makes.
pub const text_max = 32;

/// A decimal number: 0.`digits` × 10^`point`, each digit 0 to 9.
pub const Decimal = struct {
    digits: [max_digits]u8 = undefined,
    count: usize = 0,
    point: i32 = 0,
    /// Nonzero digits were cut off past `max_digits`.
    truncated: bool = false,

    /// The digits of a whole number.
    pub fn assign(d: *Decimal, whole: u64) void {
        var reversed: [24]u8 = undefined;
        var n: usize = 0;
        var left = whole;
        while (left > 0) : (n += 1) {
            reversed[n] = @intCast(left % 10);
            left /= 10;
        }
        d.count = 0;
        d.truncated = false;
        while (n > 0) {
            n -= 1;
            d.digits[d.count] = reversed[n];
            d.count += 1;
        }
        d.point = @intCast(d.count);
        d.trim();
    }

    /// The digits of a JSON number's text without its sign: digits, a
    /// point and more, an exponent.
    pub fn set(d: *Decimal, text: []const u8) void {
        d.count = 0;
        d.point = 0;
        d.truncated = false;
        var at: usize = 0;
        var seen_point = false;
        while (at < text.len) : (at += 1) {
            const char = text[at];
            if (char == '.') {
                seen_point = true;
                d.point = @intCast(d.count);
                continue;
            }
            if (char < '0' or char > '9') break;
            if (char == '0' and d.count == 0) {
                // A leading zero moves the point, and is no digit.
                d.point -= 1;
                continue;
            }
            if (d.count < max_digits) {
                d.digits[d.count] = char - '0';
                d.count += 1;
            } else if (char != '0') {
                d.truncated = true;
            }
        }
        if (!seen_point) d.point = @intCast(d.count);
        if (at < text.len and (text[at] == 'e' or text[at] == 'E')) {
            at += 1;
            var negative = false;
            if (at < text.len and (text[at] == '+' or text[at] == '-')) {
                negative = text[at] == '-';
                at += 1;
            }
            var exponent: i32 = 0;
            while (at < text.len and text[at] >= '0' and text[at] <= '9') : (at += 1) {
                if (exponent < 10000) exponent = exponent * 10 + (text[at] - '0');
            }
            d.point += if (negative) -exponent else exponent;
        }
        // A number of zeros only.
        if (d.count == 0) d.point = 0;
    }

    /// Trailing zeros taken off.
    fn trim(d: *Decimal) void {
        while (d.count > 0 and d.digits[d.count - 1] == 0) d.count -= 1;
        if (d.count == 0) d.point = 0;
    }

    /// The number times 2^`by`; divided for a negative `by`.
    pub fn shift(d: *Decimal, by: i32) void {
        if (d.count == 0) return;
        var left = by;
        while (left > max_shift) : (left -= max_shift) d.leftShift(max_shift);
        while (left < -max_shift) : (left += max_shift) d.rightShift(max_shift);
        if (left > 0) d.leftShift(@intCast(left));
        if (left < 0) d.rightShift(@intCast(-left));
    }

    /// The most a shift moves at once: a digit's 9 times 2^60 and a
    /// carry still fit 64 bits.
    const max_shift = 60;

    fn leftShift(d: *Decimal, by: u6) void {
        // How many digits the number grows by: the carry out of the top.
        var carry: u64 = 0;
        var read = d.count;
        while (read > 0) {
            read -= 1;
            carry = (carry + (@as(u64, d.digits[read]) << by)) / 10;
        }
        var grown: usize = 0;
        while (carry > 0) : (carry /= 10) grown += 1;

        read = d.count;
        var write_at = d.count + grown;
        var n: u64 = 0;
        while (read > 0) {
            read -= 1;
            n += @as(u64, d.digits[read]) << by;
            d.put(&write_at, n % 10);
            n /= 10;
        }
        while (n > 0) : (n /= 10) d.put(&write_at, n % 10);
        d.count = @min(d.count + grown, max_digits);
        d.point += @intCast(grown);
        d.trim();
    }

    /// A digit written one place lower than `at` - or, past the room,
    /// remembered as cut off when it is not 0.
    fn put(d: *Decimal, at: *usize, digit: u64) void {
        at.* -= 1;
        if (at.* < max_digits) {
            d.digits[at.*] = @intCast(digit);
        } else if (digit != 0) {
            d.truncated = true;
        }
    }

    fn rightShift(d: *Decimal, by: u6) void {
        var read: usize = 0;
        var write_at: usize = 0;
        // Enough leading digits for the first one out.
        var n: u64 = 0;
        while (n >> by == 0) : (read += 1) {
            if (read >= d.count) {
                if (n == 0) {
                    d.count = 0;
                    return;
                }
                while (n >> by == 0) {
                    n *= 10;
                    read += 1;
                }
                break;
            }
            n = n * 10 + d.digits[read];
        }
        d.point -= @as(i32, @intCast(read)) - 1;
        const mask = (@as(u64, 1) << by) - 1;
        while (read < d.count) : (read += 1) {
            const digit = n >> by;
            n &= mask;
            d.digits[write_at] = @intCast(digit);
            write_at += 1;
            n = n * 10 + d.digits[read];
        }
        while (n > 0) {
            const digit = n >> by;
            n &= mask;
            if (write_at < max_digits) {
                d.digits[write_at] = @intCast(digit);
                write_at += 1;
            } else if (digit > 0) {
                d.truncated = true;
            }
            n *= 10;
        }
        d.count = write_at;
        d.trim();
    }

    /// Whether rounding to `keep` digits goes up: a digit of 5 or more
    /// after them - exactly 5 and nothing after it to even.
    fn roundsUp(d: *const Decimal, keep: i32) bool {
        if (keep < 0 or keep >= d.count) return false;
        const at: usize = @intCast(keep);
        if (d.digits[at] == 5 and at + 1 == d.count) {
            if (d.truncated) return true;
            return at > 0 and d.digits[at - 1] % 2 == 1;
        }
        return d.digits[at] >= 5;
    }

    /// Rounded to `keep` significant digits, to the nearest, a tie to even.
    pub fn round(d: *Decimal, keep: usize) void {
        if (keep >= d.count) return;
        if (!d.roundsUp(@intCast(keep))) {
            d.count = keep;
            d.trim();
            return;
        }
        var at = keep;
        while (at > 0) {
            at -= 1;
            if (d.digits[at] < 9) {
                d.digits[at] += 1;
                d.count = at + 1;
                return;
            }
        }
        // All nines: a 1, one place higher.
        d.digits[0] = 1;
        d.count = 1;
        d.point += 1;
    }

    /// The whole part, rounded by what follows it; the largest u64 for
    /// a number too large.
    fn roundedWhole(d: *const Decimal) u64 {
        if (d.point > 20) return ~@as(u64, 0);
        var n: u64 = 0;
        var at: usize = 0;
        const whole: usize = @intCast(@max(d.point, 0));
        while (at < whole and at < d.count) : (at += 1) n = n * 10 + d.digits[at];
        while (at < whole) : (at += 1) n *= 10;
        if (d.roundsUp(d.point)) n += 1;
        return n;
    }

    /// The bits of the double nearest the number, without a sign; the
    /// number is changed on the way.
    pub fn toBits(d: *Decimal) u64 {
        const bias = -1023;
        const mantissa_bits = 52;
        const infinity: u64 = 0x7FF << mantissa_bits;
        if (d.count == 0) return 0;
        if (d.point > 310) return infinity;
        if (d.point < -330) return 0;
        // Halved or doubled into [1/2, 1), each step as many bits as keep
        // the first digit in place.
        const steps = [_]u8{ 1, 3, 6, 9, 13, 16, 19, 23, 26 };
        var exponent: i32 = 0;
        while (d.point > 0) {
            const n: i32 = if (d.point >= steps.len) 27 else steps[@intCast(d.point)];
            d.shift(-n);
            exponent += n;
        }
        while (d.point < 0 or (d.point == 0 and d.digits[0] < 5)) {
            const n: i32 = if (-d.point >= steps.len) 27 else steps[@intCast(-d.point)];
            d.shift(n);
            exponent -= n;
        }
        // [1/2, 1) is a double's [1, 2) one lower.
        exponent -= 1;
        // Below the least exponent: subnormal, the mantissa shifted down.
        if (exponent < bias + 1) {
            const n = bias + 1 - exponent;
            d.shift(-n);
            exponent += n;
        }
        if (exponent - bias >= 0x7FF) return infinity;
        d.shift(1 + mantissa_bits);
        var mantissa = d.roundedWhole();
        // Rounding up carried into another bit.
        if (mantissa == @as(u64, 2) << mantissa_bits) {
            mantissa >>= 1;
            exponent += 1;
            if (exponent - bias >= 0x7FF) return infinity;
        }
        if (mantissa & (@as(u64, 1) << mantissa_bits) == 0) exponent = bias;
        const biased: u64 = @intCast(exponent - bias);
        return (mantissa & ((@as(u64, 1) << mantissa_bits) - 1)) | (biased << mantissa_bits);
    }
};

/// A number read: its double, and the whole number when its text is one
/// that fits 64 bits.
pub const Read = struct {
    number: f64,
    integer: ?i64 = null,
};

/// 10^0 to 10^22, each exact in a double.
const exact_tens = blk: {
    var table: [23]f64 = undefined;
    var value: f64 = 1;
    for (&table) |*slot| {
        slot.* = value;
        value *= 10;
    }
    break :blk table;
};

/// The number a JSON number's `text` writes, its grammar checked already.
/// `work` is room for a `Decimal`, asked for only when the number needs
/// one; null from it - no memory - makes this null.
pub fn toDouble(text: []const u8, context: anytype, comptime work: fn (@TypeOf(context)) ?*Decimal) ?Read {
    const negative = text.len > 0 and text[0] == '-';
    const unsigned = if (negative) text[1..] else text;
    var result = Read{ .number = 0 };
    result.integer = wholeOf(unsigned, negative);
    if (fastDouble(unsigned)) |number| {
        result.number = if (negative) -number else number;
        return result;
    }
    const decimal = work(context) orelse return null;
    decimal.set(unsigned);
    const bits = decimal.toBits() | (if (negative) @as(u64, 1) << 63 else 0);
    result.number = @bitCast(bits);
    return result;
}

/// The number when its text is a whole number of 64 bits, `negative` for
/// a minus before it; null for anything else.
fn wholeOf(text: []const u8, negative: bool) ?i64 {
    var magnitude: u64 = 0;
    const limit: u64 = if (negative) @as(u64, 1) << 63 else (@as(u64, 1) << 63) - 1;
    for (text) |char| {
        if (char < '0' or char > '9') return null;
        const digit: u64 = char - '0';
        if (magnitude > (limit - digit) / 10) return null;
        magnitude = magnitude * 10 + digit;
    }
    if (negative) return if (magnitude == @as(u64, 1) << 63) -9223372036854775807 - 1 else -@as(i64, @intCast(magnitude));
    return @intCast(magnitude);
}

/// The number at once, when its digits make a whole number of at most
/// 2^53 and its power of ten is exact: one rounding, the right one. Null
/// for any other.
fn fastDouble(text: []const u8) ?f64 {
    var mantissa: u64 = 0;
    var digits: u32 = 0;
    var power: i32 = 0;
    var at: usize = 0;
    var after_point = false;
    while (at < text.len) : (at += 1) {
        const char = text[at];
        if (char == '.') {
            after_point = true;
            continue;
        }
        if (char < '0' or char > '9') break;
        if (mantissa == 0 and char == '0') {
            if (after_point) power -= 1;
            continue;
        }
        if (digits == 19) return null;
        mantissa = mantissa * 10 + (char - '0');
        digits += 1;
        if (after_point) power -= 1;
    }
    if (at < text.len) {
        // The exponent: the grammar has its digits.
        at += 1;
        var negative = false;
        if (text[at] == '+' or text[at] == '-') {
            negative = text[at] == '-';
            at += 1;
        }
        var exponent: i32 = 0;
        while (at < text.len) : (at += 1) {
            if (exponent > 1000) return null;
            exponent = exponent * 10 + (text[at] - '0');
        }
        power += if (negative) -exponent else exponent;
    }
    if (mantissa == 0) return 0;
    if (mantissa > @as(u64, 1) << 53) return null;
    var value: f64 = @floatFromInt(mantissa);
    if (power < 0) {
        if (power < -22) return null;
        return value / exact_tens[@intCast(-power)];
    }
    if (power > 22) {
        // A few of the power's tens taken into the mantissa while it
        // stays exact.
        const over = power - 22;
        if (over > 15) return null;
        const scale: u64 = @intFromFloat(exact_tens[@intCast(over)]);
        if (mantissa > (@as(u64, 1) << 53) / scale) return null;
        value = @floatFromInt(mantissa * scale);
        return value * exact_tens[22];
    }
    return value * exact_tens[@intCast(power)];
}

/// What `write` works in: the double's exact digits, and a rounding of
/// them that is tried.
pub const Work = struct {
    exact: Decimal = .{},
    tried: Decimal = .{},
    check: Decimal = .{},
};

/// A finite double as the shortest JSON text that reads back as it, into
/// `into`. `work` is asked for room when the number is not a small whole
/// one; null from it makes this null.
pub fn write(number: f64, into: *[text_max]u8, context: anytype, comptime work: fn (@TypeOf(context)) ?*Work) ?[]const u8 {
    const bits: u64 = @bitCast(number);
    const negative = bits >> 63 != 0;
    const magnitude_bits = bits & ~(@as(u64, 1) << 63);
    var length: usize = 0;
    if (negative) {
        into[0] = '-';
        length = 1;
    }
    if (magnitude_bits == 0) {
        into[length] = '0';
        return into[0 .. length + 1];
    }
    const magnitude: f64 = @bitCast(magnitude_bits);
    if (magnitude < 9007199254740992.0 and @floor(magnitude) == magnitude) return writeWhole(@intFromFloat(number), into);
    const room = work(context) orelse return null;
    const exponent_bits: u32 = @intCast(magnitude_bits >> 52);
    const fraction = magnitude_bits & ((@as(u64, 1) << 52) - 1);
    const mantissa = if (exponent_bits == 0) fraction else fraction | (@as(u64, 1) << 52);
    const exponent: i32 = if (exponent_bits == 0) -1022 else @as(i32, @intCast(exponent_bits)) - 1023;
    room.exact.assign(mantissa);
    room.exact.shift(exponent - 52);
    var keep: usize = 1;
    while (keep < 17) : (keep += 1) {
        copyInto(&room.tried, &room.exact);
        room.tried.round(keep);
        copyInto(&room.check, &room.tried);
        if (room.check.toBits() == magnitude_bits) break;
    }
    if (keep == 17) {
        copyInto(&room.tried, &room.exact);
        room.tried.round(17);
    }
    return put(into, length, &room.tried);
}

fn copyInto(into: *Decimal, from: *const Decimal) void {
    @memcpy(into.digits[0..from.count], from.digits[0..from.count]);
    into.count = from.count;
    into.point = from.point;
    into.truncated = from.truncated;
}

/// The digits put down after `length` bytes already in `into`: plainly
/// for a point from -6 to 21, with an exponent beyond.
fn put(into: *[text_max]u8, start: usize, digits: *const Decimal) []const u8 {
    var length = start;
    const count: i32 = @intCast(digits.count);
    const point = digits.point;
    if (count <= point and point <= 21) {
        for (digits.digits[0..digits.count]) |digit| append(into, &length, '0' + digit);
        var zeros = point - count;
        while (zeros > 0) : (zeros -= 1) append(into, &length, '0');
    } else if (0 < point and point <= 21) {
        for (digits.digits[0..digits.count], 0..) |digit, at| {
            if (at == point) append(into, &length, '.');
            append(into, &length, '0' + digit);
        }
    } else if (-6 < point and point <= 0) {
        append(into, &length, '0');
        append(into, &length, '.');
        var zeros = -point;
        while (zeros > 0) : (zeros -= 1) append(into, &length, '0');
        for (digits.digits[0..digits.count]) |digit| append(into, &length, '0' + digit);
    } else {
        append(into, &length, '0' + digits.digits[0]);
        if (digits.count > 1) {
            append(into, &length, '.');
            for (digits.digits[1..digits.count]) |digit| append(into, &length, '0' + digit);
        }
        append(into, &length, 'e');
        const exponent = point - 1;
        append(into, &length, if (exponent < 0) '-' else '+');
        var magnitude: u32 = @intCast(if (exponent < 0) -exponent else exponent);
        var reversed: [4]u8 = undefined;
        var n: usize = 0;
        while (true) {
            reversed[n] = @intCast('0' + magnitude % 10);
            n += 1;
            magnitude /= 10;
            if (magnitude == 0) break;
        }
        while (n > 0) {
            n -= 1;
            append(into, &length, reversed[n]);
        }
    }
    return into[0..length];
}

fn append(into: *[text_max]u8, length: *usize, char: u8) void {
    if (length.* < into.len) into[length.*] = char;
    length.* += 1;
}

/// A whole number's digits, a minus before a negative one, into `into`.
pub fn writeWhole(integer: i64, into: *[text_max]u8) []const u8 {
    var length: usize = 0;
    var magnitude: u64 = @abs(integer);
    if (integer < 0) {
        into[0] = '-';
        length = 1;
    }
    var reversed: [20]u8 = undefined;
    var n: usize = 0;
    while (true) {
        reversed[n] = @intCast('0' + magnitude % 10);
        n += 1;
        magnitude /= 10;
        if (magnitude == 0) break;
    }
    while (n > 0) {
        n -= 1;
        into[length] = reversed[n];
        length += 1;
    }
    return into[0..length];
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

fn testDecimal(room: *Decimal) ?*Decimal {
    return room;
}

fn testWork(room: *Work) ?*Work {
    return room;
}

fn readBack(text: []const u8) !f64 {
    var room: Decimal = .{};
    const got = toDouble(text, &room, testDecimal) orelse return error.NoRoom;
    return got.number;
}

fn written(number: f64, into: *[text_max]u8) ![]const u8 {
    var room: Work = .{};
    return write(number, into, &room, testWork) orelse error.NoRoom;
}

test "numbers read to the nearest double, on the fast way and the slow" {
    const cases = [_][]const u8{
        "0",                "-0",                      "1",                                               "3.6",
        "-273.15",          "1e22",                    "1e23",                                            "123456789012345678901234567890",
        "0.1",              "2.2250738585072014e-308", "4.9e-324",                                        "1.7976931348623157e308",
        "9007199254740993", "0.30000000000000004",     "1E+2",                                            "12.5e-3",
        "2.5e-325",         "1e400",                   "0.000000000000000000000000000000000000000000001", "7.2057594037927933e16",
        "89255.0e-22",      "1448997445238699",
    };
    for (cases) |text| {
        const expected = try std.fmt.parseFloat(f64, text);
        const got = try readBack(text);
        try testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(got)));
    }
}

test "a whole number's text is kept exactly when it fits 64 bits" {
    var room: Decimal = .{};
    try testing.expectEqual(@as(?i64, 9007199254740993), toDouble("9007199254740993", &room, testDecimal).?.integer);
    try testing.expectEqual(@as(?i64, -9223372036854775808), toDouble("-9223372036854775808", &room, testDecimal).?.integer);
    try testing.expectEqual(@as(?i64, null), toDouble("9223372036854775808", &room, testDecimal).?.integer);
    try testing.expectEqual(@as(?i64, null), toDouble("1.0", &room, testDecimal).?.integer);
}

test "numbers written in the fewest digits that read back the same" {
    var into: [text_max]u8 = undefined;
    const cases = [_]struct { number: f64, text: []const u8 }{
        .{ .number = 0, .text = "0" },
        .{ .number = -0.0, .text = "-0" },
        .{ .number = 3.6, .text = "3.6" },
        .{ .number = -273.15, .text = "-273.15" },
        .{ .number = 0.30000000000000004, .text = "0.30000000000000004" },
        .{ .number = 1e21, .text = "1e+21" },
        .{ .number = 1e20, .text = "100000000000000000000" },
        .{ .number = 123456789, .text = "123456789" },
        .{ .number = 0.000001, .text = "0.000001" },
        .{ .number = 0.0000001, .text = "1e-7" },
        .{ .number = 5e-324, .text = "5e-324" },
        .{ .number = 1.7976931348623157e308, .text = "1.7976931348623157e+308" },
        .{ .number = 2.5, .text = "2.5" },
        .{ .number = 9007199254740993.0, .text = "9007199254740992" },
    };
    for (cases) |case| try testing.expectEqualStrings(case.text, try written(case.number, &into));
}

test "a thousand doubles written and read back are the same doubles" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    var into: [text_max]u8 = undefined;
    var count: usize = 0;
    while (count < 1000) : (count += 1) {
        const bits = prng.random().int(u64);
        const number: f64 = @bitCast(bits);
        if (std.math.isNan(number) or std.math.isInf(number)) continue;
        const text = try written(number, &into);
        const back = try readBack(text);
        try testing.expectEqual(bits, @as(u64, @bitCast(back)));
        // And as short as the shortest there is.
        var shortest: [64]u8 = undefined;
        const theirs = try std.fmt.bufPrint(&shortest, "{e}", .{number});
        try testing.expectEqual(significantDigits(theirs), significantDigits(text));
    }
}

/// How many digits a number's text has from its first nonzero one to its
/// last nonzero one, its exponent aside.
fn significantDigits(text: []const u8) usize {
    var first: ?usize = null;
    var last: usize = 0;
    var n: usize = 0;
    for (text) |char| {
        if (char == 'e') break;
        if (char < '0' or char > '9') continue;
        if (char != '0') {
            if (first == null) first = n;
            last = n;
        }
        n += 1;
    }
    return if (first) |at| last - at + 1 else 0;
}

test "whole numbers written exactly" {
    var into: [text_max]u8 = undefined;
    try testing.expectEqualStrings("-9223372036854775808", writeWhole(-9223372036854775808, &into));
    try testing.expectEqualStrings("0", writeWhole(0, &into));
    try testing.expectEqualStrings("42", writeWhole(42, &into));
}
