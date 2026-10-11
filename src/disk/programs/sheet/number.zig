// SPDX-License-Identifier: MIT
//! Numbers as Sheet reads and writes them: the text of a number typed
//! into a cell, and a number written back as text in at most a given
//! count of significant digits.
//!
//! A number is a double throughout. Reading gathers up to nineteen digits
//! into an integer and scales it by a power of ten once; writing finds the
//! decimal exponent from the double's own, rounds the number to the digits
//! wanted as an integer and puts the point into that integer's digits. The
//! powers of ten up to 10^22 are exact in a double, which is what keeps
//! both directions true to the last digit shown.

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

/// The most significant digits `format` writes: what a double holds
/// without inventing any.
pub const max_digits: u32 = 15;

/// Ten to the `power`, for any power a double reaches; past the exact
/// table, a product of exact steps.
pub fn tenTo(power: i32) f64 {
    var left: u32 = @abs(power);
    var result: f64 = 1;
    while (left > 22) : (left -= 22) result *= exact_tens[22];
    result *= exact_tens[left];
    return if (power < 0) 1 / result else result;
}

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

/// The number `text` says, or null when it says anything else. Spaces
/// round it are allowed, and a sign, a decimal point, an exponent (`1.5E3`)
/// and a percent sign at the end, which divides by a hundred. A number too
/// large for a double is no number.
pub fn parse(text: []const u8) ?f64 {
    var at: usize = 0;
    var end: usize = text.len;
    while (at < end and text[at] == ' ') at += 1;
    while (end > at and text[end - 1] == ' ') end -= 1;
    if (at == end) return null;
    var negative = false;
    if (text[at] == '+' or text[at] == '-') {
        negative = text[at] == '-';
        at += 1;
    }
    var percent = false;
    if (end > at and text[end - 1] == '%') {
        percent = true;
        end -= 1;
    }

    // The digits as one integer, and the power of ten it is scaled by.
    var mantissa: u64 = 0;
    var scale: i32 = 0;
    var digits: u32 = 0;
    var seen_point = false;
    while (at < end) : (at += 1) {
        const char = text[at];
        if (isDigit(char)) {
            digits += 1;
            if (mantissa <= (~@as(u64, 0) - 9) / 10) {
                mantissa = mantissa * 10 + (char - '0');
                if (seen_point) scale -= 1;
            } else if (!seen_point) {
                // A digit past what the integer holds still counts for the
                // magnitude in front of the point.
                scale += 1;
            }
        } else if (char == '.' and !seen_point) {
            seen_point = true;
        } else break;
    }
    if (digits == 0) return null;
    if (at < end and (text[at] == 'e' or text[at] == 'E')) {
        at += 1;
        var exponent_negative = false;
        if (at < end and (text[at] == '+' or text[at] == '-')) {
            exponent_negative = text[at] == '-';
            at += 1;
        }
        var exponent: i32 = 0;
        var exponent_digits: u32 = 0;
        while (at < end and isDigit(text[at])) : (at += 1) {
            exponent_digits += 1;
            if (exponent < 10_000) exponent = exponent * 10 + (text[at] - '0');
        }
        if (exponent_digits == 0) return null;
        scale += if (exponent_negative) -exponent else exponent;
    }
    if (at != end) return null;

    var value: f64 = @floatFromInt(mantissa);
    if (scale > 0) {
        value *= tenTo(scale);
    } else if (scale < 0) {
        // Divided by exact powers, so 0.1 comes out as the double nearest
        // a tenth rather than a tenth of a rounded reciprocal.
        var left: u32 = @abs(scale);
        while (left > 22) : (left -= 22) value /= exact_tens[22];
        value /= exact_tens[left];
    }
    if (percent) value /= 100;
    if (value - value != 0) return null;
    return if (negative) -value else value;
}

/// The digits of `value` into the end of `out`; the part used.
fn writeInteger(value: u64, out: []u8) []u8 {
    var left = value;
    var at = out.len;
    while (true) {
        at -= 1;
        out[at] = '0' + @as(u8, @intCast(left % 10));
        left /= 10;
        if (left == 0) break;
    }
    return out[at..];
}

/// The power of ten at or just below `magnitude` (positive): the number of
/// places its first digit is from the point.
fn exponentOf(magnitude: f64) i32 {
    // The binary exponent times log10(2) is right or one too low or high;
    // the exact powers settle it.
    const bits: u64 = @bitCast(magnitude);
    const binary: i32 = @as(i32, @intCast((bits >> 52) & 0x7FF)) - 1023;
    var exponent: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(binary)) * 0.30102999566398120));
    while (exponent > -330 and tenTo(exponent) > magnitude) exponent -= 1;
    while (exponent < 310 and tenTo(exponent + 1) <= magnitude) exponent += 1;
    return exponent;
}

/// The text of `value` in at most `digits` significant digits (1 to 15),
/// written into `out`: plain while the number is at least 0.00001 and has
/// no more digits in front of its point than `digits`, with an exponent
/// otherwise (`1.5E+20`, `2E-07`). Zeros at the end of the decimals are
/// left off, and the point with them. The text is a part of `out`.
pub fn format(value: f64, digits: u32, out: *[32]u8) []const u8 {
    if (value - value != 0) {
        const word = "#NUM!";
        @memcpy(out[0..word.len], word);
        return out[0..word.len];
    }
    if (value == 0) {
        out[0] = '0';
        return out[0..1];
    }
    const wanted: u32 = if (digits < 1) 1 else if (digits > max_digits) max_digits else digits;
    const magnitude = @abs(value);
    var exponent = exponentOf(magnitude);
    var used: usize = 0;
    if (value < 0) {
        out[0] = '-';
        used = 1;
    }
    var scratch: [24]u8 = undefined;

    if (exponent >= -5 and exponent < @as(i32, @intCast(wanted))) {
        // Plain: the number rounded to `decimals` places as an integer.
        const decimals: u32 = @intCast(@as(i32, @intCast(wanted)) - 1 - exponent);
        const scaled: u64 = @intFromFloat(@round(magnitude * tenTo(@intCast(decimals))));
        const text = writeInteger(scaled, &scratch);
        // The digits in front of the point, at least a 0.
        if (text.len > decimals) {
            const whole = text[0 .. text.len - decimals];
            @memcpy(out[used..][0..whole.len], whole);
            used += whole.len;
        } else {
            out[used] = '0';
            used += 1;
        }
        // The decimals, with the zeros the integer has no digits for in
        // front, and without the zeros at the end.
        var fraction: [24]u8 = undefined;
        const lead = if (text.len < decimals) decimals - text.len else 0;
        @memset(fraction[0..lead], '0');
        const tail = if (text.len > decimals) text[text.len - decimals ..] else text;
        @memcpy(fraction[lead..][0..tail.len], tail);
        var length: usize = decimals;
        while (length > 0 and fraction[length - 1] == '0') length -= 1;
        if (length > 0) {
            out[used] = '.';
            used += 1;
            @memcpy(out[used..][0..length], fraction[0..length]);
            used += length;
        }
        return out[0..used];
    }

    // With an exponent: the first digit, the point, the rest.
    var mantissa = if (exponent < -300) (magnitude * 1e100) / tenTo(exponent + 100) else magnitude / tenTo(exponent);
    if (mantissa < 1) mantissa = 1;
    var scaled: u64 = @intFromFloat(@round(mantissa * tenTo(@intCast(wanted - 1))));
    if (scaled >= @as(u64, @intFromFloat(tenTo(@intCast(wanted))))) {
        scaled /= 10;
        exponent += 1;
    }
    const text = writeInteger(scaled, &scratch);
    out[used] = text[0];
    used += 1;
    var length = text.len;
    while (length > 1 and text[length - 1] == '0') length -= 1;
    if (length > 1) {
        out[used] = '.';
        used += 1;
        @memcpy(out[used..][0 .. length - 1], text[1..length]);
        used += length - 1;
    }
    out[used] = 'E';
    out[used + 1] = if (exponent < 0) '-' else '+';
    used += 2;
    const power: u64 = @abs(exponent);
    if (power < 10) {
        out[used] = '0';
        used += 1;
    }
    const power_text = writeInteger(power, &scratch);
    @memcpy(out[used..][0..power_text.len], power_text);
    used += power_text.len;
    return out[0..used];
}
