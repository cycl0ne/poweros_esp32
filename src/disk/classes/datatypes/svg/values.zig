// SPDX-License-Identifier: MIT
//! What SVG's attributes and properties hold, read out of their text:
//! numbers, lengths, colours, paints, transforms, and the declarations of
//! a `style` attribute.
//!
//! **Lengths** are in user units, which are pixels: `px` and none, and
//! `pt`, `pc`, `mm`, `cm` and `in` at 96 to the inch, `em` as 16 and `ex`
//! as 8 of them, the size of no font. A percentage is of the viewport's
//! width, height, or the length SVG takes for neither - its diagonal
//! over the square root of two - and is turned into units by whoever
//! knows the viewport.
//!
//! **Colours** are CSS's: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`,
//! `rgb()` and `rgba()` in numbers or percentages, `hsl()` and `hsla()`,
//! the 148 names, `transparent`; `currentColor` is left to the caller.
//! Names are matched whatever their case.

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
const xml = @import("xml.zig");
const Matrix = vector.Matrix;
const Colour = vector.Colour;

/// Characters read one after another, spaces and commas between.
pub const Scanner = struct {
    text: []const u8,
    at: usize = 0,

    pub fn done(s: *Scanner) bool {
        s.skipSpace();
        return s.at >= s.text.len;
    }

    pub fn skipSpace(s: *Scanner) void {
        while (s.at < s.text.len and xml.isSpace(s.text[s.at])) s.at += 1;
    }

    /// Spaces, then one comma if there is one, then spaces.
    pub fn skipSeparator(s: *Scanner) void {
        s.skipSpace();
        if (s.at < s.text.len and s.text[s.at] == ',') s.at += 1;
        s.skipSpace();
    }

    /// A character, past spaces before it; false, and nothing moved,
    /// when it is not the next.
    pub fn take(s: *Scanner, c: u8) bool {
        s.skipSpace();
        if (s.at < s.text.len and s.text[s.at] == c) {
            s.at += 1;
            return true;
        }
        return false;
    }

    /// A number: a sign, digits with a point among them, an exponent.
    pub fn number(s: *Scanner) ?f32 {
        s.skipSpace();
        const t = s.text;
        var i = s.at;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
        const digits_start = i;
        while (i < t.len and isDigit(t[i])) i += 1;
        var any = i > digits_start;
        if (i < t.len and t[i] == '.') {
            i += 1;
            const after = i;
            while (i < t.len and isDigit(t[i])) i += 1;
            any = any or i > after;
        }
        if (!any) return null;
        if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
            var j = i + 1;
            if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
            const exponent_start = j;
            while (j < t.len and isDigit(t[j])) j += 1;
            if (j > exponent_start) i = j;
        }
        const value = parseFloat(t[s.at..i]) orelse return null;
        s.at = i;
        return value;
    }

    /// A word of letters, or of letters and `%`, right after what came
    /// before: a length's unit.
    pub fn unit(s: *Scanner) []const u8 {
        const start = s.at;
        while (s.at < s.text.len and (isLetter(s.text[s.at]) or s.text[s.at] == '%')) s.at += 1;
        return s.text[start..s.at];
    }

    /// A name: letters, digits and `-`.
    pub fn word(s: *Scanner) []const u8 {
        s.skipSpace();
        const start = s.at;
        while (s.at < s.text.len and (isLetter(s.text[s.at]) or isDigit(s.text[s.at]) or s.text[s.at] == '-')) s.at += 1;
        return s.text[start..s.at];
    }
};

/// A number as SVG writes it; the digits read here, so as not to need
/// a parser of the library's.
fn parseFloat(text: []const u8) ?f32 {
    var i: usize = 0;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    var mantissa: f64 = 0;
    var scale: i32 = 0;
    while (i < text.len and isDigit(text[i])) : (i += 1) mantissa = mantissa * 10 + @as(f64, @floatFromInt(text[i] - '0'));
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and isDigit(text[i])) : (i += 1) {
            mantissa = mantissa * 10 + @as(f64, @floatFromInt(text[i] - '0'));
            scale -= 1;
        }
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        var exponent_negative = false;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) {
            exponent_negative = text[i] == '-';
            i += 1;
        }
        var exponent: i32 = 0;
        while (i < text.len and isDigit(text[i])) : (i += 1) exponent = @min(exponent * 10 + (text[i] - '0'), 1000);
        scale += if (exponent_negative) -exponent else exponent;
    }
    var value = mantissa;
    if (scale > 0) {
        while (scale > 0) : (scale -= 1) value *= 10;
    } else if (scale < 0) {
        // Divided by one power, not many: 0.1 comes out as 0.1.
        var power: f64 = 1;
        while (scale < 0) : (scale += 1) {
            power *= 10;
            if (power > 1e300) break;
        }
        value /= power;
    }
    if (value > std.math.floatMax(f32)) return null;
    const result: f32 = @floatCast(value);
    return if (negative) -result else result;
}

/// Which of the viewport's sides a percentage is of.
pub const Axis = enum { x, y, other };

/// A length: a number of units, or a percentage still to be taken of
/// the viewport.
pub const Length = struct {
    value: f32,
    percent: bool = false,

    /// In units, `viewport` being the viewport's width and height.
    pub fn resolve(l: Length, axis: Axis, viewport: [2]f32) f32 {
        if (!l.percent) return l.value;
        const of = switch (axis) {
            .x => viewport[0],
            .y => viewport[1],
            .other => @sqrt((viewport[0] * viewport[0] + viewport[1] * viewport[1]) / 2),
        };
        return l.value / 100 * of;
    }
};

/// A length out of the scanner, its unit with it.
pub fn lengthAt(s: *Scanner) ?Length {
    const n = s.number() orelse return null;
    const u = s.unit();
    if (u.len == 0 or eqlLower(u, "px")) return .{ .value = n };
    if (eqlLower(u, "%")) return .{ .value = n, .percent = true };
    const per: f32 = if (eqlLower(u, "pt"))
        96.0 / 72.0
    else if (eqlLower(u, "pc"))
        16
    else if (eqlLower(u, "mm"))
        96.0 / 25.4
    else if (eqlLower(u, "cm"))
        96.0 / 2.54
    else if (eqlLower(u, "in"))
        96
    else if (eqlLower(u, "em"))
        16
    else if (eqlLower(u, "ex"))
        8
    else
        return null;
    return .{ .value = n * per };
}

/// A whole value that is one length, or null.
pub fn length(text: []const u8) ?Length {
    var s = Scanner{ .text = text };
    const l = lengthAt(&s) orelse return null;
    return if (s.done()) l else null;
}

/// A whole value that is one number, or null.
pub fn number(text: []const u8) ?f32 {
    var s = Scanner{ .text = text };
    const n = s.number() orelse return null;
    return if (s.done()) n else null;
}

/// A number or a percentage, as a fraction: a stop's offset, an
/// opacity. Held to 0 to 1.
pub fn fraction(text: []const u8) ?f32 {
    var s = Scanner{ .text = text };
    var n = s.number() orelse return null;
    if (s.take('%')) n /= 100;
    if (!s.done()) return null;
    return clamp01(n);
}

pub fn clamp01(v: f32) f32 {
    return if (v > 0) @min(v, 1) else 0;
}

// --- colours ------------------------------------------------------------------

/// A colour, or null when the text is none. `currentColor` is null as
/// well: the caller knows the colour it stands for.
pub fn colour(text_in: []const u8) ?Colour {
    const text = trim(text_in);
    if (text.len == 0) return null;
    if (text[0] == '#') return hexColour(text[1..]);
    var s = Scanner{ .text = text };
    const name = s.word();
    if (s.take('(')) {
        const rgb = eqlLower(name, "rgb") or eqlLower(name, "rgba");
        const hsl = eqlLower(name, "hsl") or eqlLower(name, "hsla");
        if (!rgb and !hsl) return null;
        var v: [4]f32 = .{ 0, 0, 0, 1 };
        var percent: [4]bool = .{ false, false, false, false };
        var n: usize = 0;
        while (n < 4) : (n += 1) {
            if (n > 0) {
                s.skipSpace();
                if (s.at < s.text.len and (s.text[s.at] == ',' or s.text[s.at] == '/')) s.at += 1;
            }
            if (s.take(')')) break;
            v[n] = s.number() orelse return null;
            if (hsl and n == 0) _ = s.unit(); // "deg"
            percent[n] = s.take('%');
        } else if (!s.take(')')) return null;
        if (n < 3) return null;
        const alpha = clamp01(if (percent[3]) v[3] / 100 else v[3]);
        if (rgb) {
            var c: [3]f32 = undefined;
            for (0..3) |i| c[i] = clamp01(if (percent[i]) v[i] / 100 else v[i] / 255);
            return .{ .r = c[0], .g = c[1], .b = c[2], .a = alpha };
        }
        return fromHsl(v[0], clamp01(v[1] / 100), clamp01(v[2] / 100), alpha);
    }
    if (!s.done()) return null;
    if (eqlLower(name, "transparent")) return .{ .a = 0 };
    var lower: [24]u8 = undefined;
    if (name.len > lower.len) return null;
    for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const rgb = named.get(lower[0..name.len]) orelse return null;
    return fromRgb(rgb, 1);
}

fn hexColour(digits: []const u8) ?Colour {
    var v: [8]u8 = undefined;
    if (digits.len != 3 and digits.len != 4 and digits.len != 6 and digits.len != 8) return null;
    for (digits, 0..) |c, i| v[i] = hexDigit(c) orelse return null;
    return switch (digits.len) {
        3 => fromRgb(@as(u32, v[0]) * 0x110000 + @as(u32, v[1]) * 0x1100 + @as(u32, v[2]) * 0x11, 1),
        4 => fromRgb(@as(u32, v[0]) * 0x110000 + @as(u32, v[1]) * 0x1100 + @as(u32, v[2]) * 0x11, @as(f32, @floatFromInt(v[3] * 0x11)) / 255),
        6 => fromRgb(hexValue(v[0..6]), 1),
        else => fromRgb(hexValue(v[0..6]), @as(f32, @floatFromInt(v[6] * 16 + v[7])) / 255),
    };
}

fn hexValue(v: []const u8) u32 {
    var n: u32 = 0;
    for (v) |d| n = n * 16 + d;
    return n;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn fromRgb(rgb: u32, alpha: f32) Colour {
    return .{
        .r = @as(f32, @floatFromInt((rgb >> 16) & 0xFF)) / 255,
        .g = @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255,
        .b = @as(f32, @floatFromInt(rgb & 0xFF)) / 255,
        .a = alpha,
    };
}

fn fromHsl(hue_degrees: f32, saturation: f32, lightness: f32, alpha: f32) Colour {
    const hue = (hue_degrees - 360 * @floor(hue_degrees / 360)) / 60;
    const chroma = (1 - @abs(2 * lightness - 1)) * saturation;
    const x = chroma * (1 - @abs(hue - 2 * @floor(hue / 2) - 1));
    const m = lightness - chroma / 2;
    const rgb: [3]f32 = if (hue < 1) .{ chroma, x, 0 } else if (hue < 2) .{ x, chroma, 0 } else if (hue < 3) .{ 0, chroma, x } else if (hue < 4) .{ 0, x, chroma } else if (hue < 5) .{ x, 0, chroma } else .{ chroma, 0, x };
    return .{ .r = clamp01(rgb[0] + m), .g = clamp01(rgb[1] + m), .b = clamp01(rgb[2] + m), .a = alpha };
}

/// CSS's colour names.
const named = std.StaticStringMap(u32).initComptime(.{
    .{ "aliceblue", 0xF0F8FF },         .{ "antiquewhite", 0xFAEBD7 },         .{ "aqua", 0x00FFFF },
    .{ "aquamarine", 0x7FFFD4 },        .{ "azure", 0xF0FFFF },                .{ "beige", 0xF5F5DC },
    .{ "bisque", 0xFFE4C4 },            .{ "black", 0x000000 },                .{ "blanchedalmond", 0xFFEBCD },
    .{ "blue", 0x0000FF },              .{ "blueviolet", 0x8A2BE2 },           .{ "brown", 0xA52A2A },
    .{ "burlywood", 0xDEB887 },         .{ "cadetblue", 0x5F9EA0 },            .{ "chartreuse", 0x7FFF00 },
    .{ "chocolate", 0xD2691E },         .{ "coral", 0xFF7F50 },                .{ "cornflowerblue", 0x6495ED },
    .{ "cornsilk", 0xFFF8DC },          .{ "crimson", 0xDC143C },              .{ "cyan", 0x00FFFF },
    .{ "darkblue", 0x00008B },          .{ "darkcyan", 0x008B8B },             .{ "darkgoldenrod", 0xB8860B },
    .{ "darkgray", 0xA9A9A9 },          .{ "darkgreen", 0x006400 },            .{ "darkgrey", 0xA9A9A9 },
    .{ "darkkhaki", 0xBDB76B },         .{ "darkmagenta", 0x8B008B },          .{ "darkolivegreen", 0x556B2F },
    .{ "darkorange", 0xFF8C00 },        .{ "darkorchid", 0x9932CC },           .{ "darkred", 0x8B0000 },
    .{ "darksalmon", 0xE9967A },        .{ "darkseagreen", 0x8FBC8F },         .{ "darkslateblue", 0x483D8B },
    .{ "darkslategray", 0x2F4F4F },     .{ "darkslategrey", 0x2F4F4F },        .{ "darkturquoise", 0x00CED1 },
    .{ "darkviolet", 0x9400D3 },        .{ "deeppink", 0xFF1493 },             .{ "deepskyblue", 0x00BFFF },
    .{ "dimgray", 0x696969 },           .{ "dimgrey", 0x696969 },              .{ "dodgerblue", 0x1E90FF },
    .{ "firebrick", 0xB22222 },         .{ "floralwhite", 0xFFFAF0 },          .{ "forestgreen", 0x228B22 },
    .{ "fuchsia", 0xFF00FF },           .{ "gainsboro", 0xDCDCDC },            .{ "ghostwhite", 0xF8F8FF },
    .{ "gold", 0xFFD700 },              .{ "goldenrod", 0xDAA520 },            .{ "gray", 0x808080 },
    .{ "grey", 0x808080 },              .{ "green", 0x008000 },                .{ "greenyellow", 0xADFF2F },
    .{ "honeydew", 0xF0FFF0 },          .{ "hotpink", 0xFF69B4 },              .{ "indianred", 0xCD5C5C },
    .{ "indigo", 0x4B0082 },            .{ "ivory", 0xFFFFF0 },                .{ "khaki", 0xF0E68C },
    .{ "lavender", 0xE6E6FA },          .{ "lavenderblush", 0xFFF0F5 },        .{ "lawngreen", 0x7CFC00 },
    .{ "lemonchiffon", 0xFFFACD },      .{ "lightblue", 0xADD8E6 },            .{ "lightcoral", 0xF08080 },
    .{ "lightcyan", 0xE0FFFF },         .{ "lightgoldenrodyellow", 0xFAFAD2 }, .{ "lightgray", 0xD3D3D3 },
    .{ "lightgreen", 0x90EE90 },        .{ "lightgrey", 0xD3D3D3 },            .{ "lightpink", 0xFFB6C1 },
    .{ "lightsalmon", 0xFFA07A },       .{ "lightseagreen", 0x20B2AA },        .{ "lightskyblue", 0x87CEFA },
    .{ "lightslategray", 0x778899 },    .{ "lightslategrey", 0x778899 },       .{ "lightsteelblue", 0xB0C4DE },
    .{ "lightyellow", 0xFFFFE0 },       .{ "lime", 0x00FF00 },                 .{ "limegreen", 0x32CD32 },
    .{ "linen", 0xFAF0E6 },             .{ "magenta", 0xFF00FF },              .{ "maroon", 0x800000 },
    .{ "mediumaquamarine", 0x66CDAA },  .{ "mediumblue", 0x0000CD },           .{ "mediumorchid", 0xBA55D3 },
    .{ "mediumpurple", 0x9370DB },      .{ "mediumseagreen", 0x3CB371 },       .{ "mediumslateblue", 0x7B68EE },
    .{ "mediumspringgreen", 0x00FA9A }, .{ "mediumturquoise", 0x48D1CC },      .{ "mediumvioletred", 0xC71585 },
    .{ "midnightblue", 0x191970 },      .{ "mintcream", 0xF5FFFA },            .{ "mistyrose", 0xFFE4E1 },
    .{ "moccasin", 0xFFE4B5 },          .{ "navajowhite", 0xFFDEAD },          .{ "navy", 0x000080 },
    .{ "oldlace", 0xFDF5E6 },           .{ "olive", 0x808000 },                .{ "olivedrab", 0x6B8E23 },
    .{ "orange", 0xFFA500 },            .{ "orangered", 0xFF4500 },            .{ "orchid", 0xDA70D6 },
    .{ "palegoldenrod", 0xEEE8AA },     .{ "palegreen", 0x98FB98 },            .{ "paleturquoise", 0xAFEEEE },
    .{ "palevioletred", 0xDB7093 },     .{ "papayawhip", 0xFFEFD5 },           .{ "peachpuff", 0xFFDAB9 },
    .{ "peru", 0xCD853F },              .{ "pink", 0xFFC0CB },                 .{ "plum", 0xDDA0DD },
    .{ "powderblue", 0xB0E0E6 },        .{ "purple", 0x800080 },               .{ "rebeccapurple", 0x663399 },
    .{ "red", 0xFF0000 },               .{ "rosybrown", 0xBC8F8F },            .{ "royalblue", 0x4169E1 },
    .{ "saddlebrown", 0x8B4513 },       .{ "salmon", 0xFA8072 },               .{ "sandybrown", 0xF4A460 },
    .{ "seagreen", 0x2E8B57 },          .{ "seashell", 0xFFF5EE },             .{ "sienna", 0xA0522D },
    .{ "silver", 0xC0C0C0 },            .{ "skyblue", 0x87CEEB },              .{ "slateblue", 0x6A5ACD },
    .{ "slategray", 0x708090 },         .{ "slategrey", 0x708090 },            .{ "snow", 0xFFFAFA },
    .{ "springgreen", 0x00FF7F },       .{ "steelblue", 0x4682B4 },            .{ "tan", 0xD2B48C },
    .{ "teal", 0x008080 },              .{ "thistle", 0xD8BFD8 },              .{ "tomato", 0xFF6347 },
    .{ "turquoise", 0x40E0D0 },         .{ "violet", 0xEE82EE },               .{ "wheat", 0xF5DEB3 },
    .{ "white", 0xFFFFFF },             .{ "whitesmoke", 0xF5F5F5 },           .{ "yellow", 0xFFFF00 },
    .{ "yellowgreen", 0x9ACD32 },
});

/// What a `fill` or a `stroke` paints in.
pub const Paint = union(enum) {
    none,
    colour: Colour,
    /// The `color` property's.
    current,
    /// A gradient by its id, and what to paint if there is none by it.
    url: struct { id: []const u8, fallback: Fallback },

    pub const Fallback = union(enum) { none, colour: Colour, current, absent };
};

/// A `fill` or `stroke` value; null for one that is not, which leaves
/// the property as it was.
pub fn paint(text_in: []const u8) ?Paint {
    const text = trim(text_in);
    if (eqlLower(text, "none")) return .none;
    if (eqlLower(text, "currentcolor")) return .current;
    if (text.len > 4 and eqlLower(text[0..4], "url(")) {
        const close = std.mem.indexOfScalar(u8, text, ')') orelse return null;
        var id = trim(text[4..close]);
        if (id.len >= 2 and (id[0] == '"' or id[0] == '\'') and id[id.len - 1] == id[0]) id = id[1 .. id.len - 1];
        if (id.len < 2 or id[0] != '#') return null;
        const rest = trim(text[close + 1 ..]);
        const fallback: Paint.Fallback = if (rest.len == 0)
            .absent
        else if (eqlLower(rest, "none"))
            .none
        else if (eqlLower(rest, "currentcolor"))
            .current
        else if (colour(rest)) |c| .{ .colour = c } else .absent;
        return .{ .url = .{ .id = id[1..], .fallback = fallback } };
    }
    return .{ .colour = colour(text) orelse return null };
}

// --- transforms ---------------------------------------------------------------

/// A `transform` or `gradientTransform` list, its parts applied right to
/// left as SVG has them; null for one in error, which SVG draws as none.
pub fn transform(text: []const u8) ?Matrix {
    var s = Scanner{ .text = text };
    var m = Matrix{};
    while (true) {
        s.skipSeparator();
        if (s.at >= s.text.len) return m;
        const name = s.word();
        if (!s.take('(')) return null;
        var v: [6]f32 = undefined;
        var n: usize = 0;
        while (!s.take(')')) {
            if (n == 6) return null;
            if (n > 0) s.skipSeparator();
            v[n] = s.number() orelse return null;
            n += 1;
        }
        const pi: f32 = 3.14159265;
        const part: Matrix = if (xml.eql(name, "matrix") and n == 6)
            .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3], .e = v[4], .f = v[5] }
        else if (xml.eql(name, "translate") and (n == 1 or n == 2))
            Matrix.translate(v[0], if (n == 2) v[1] else 0)
        else if (xml.eql(name, "scale") and (n == 1 or n == 2))
            Matrix.scale(v[0], if (n == 2) v[1] else v[0])
        else if (xml.eql(name, "rotate") and n == 1)
            Matrix.rotate(v[0])
        else if (xml.eql(name, "rotate") and n == 3)
            Matrix.translate(v[1], v[2]).then(Matrix.rotate(v[0])).then(Matrix.translate(-v[1], -v[2]))
        else if (xml.eql(name, "skewX") and n == 1)
            .{ .c = @tan(v[0] * pi / 180) }
        else if (xml.eql(name, "skewY") and n == 1)
            .{ .b = @tan(v[0] * pi / 180) }
        else
            return null;
        m = m.then(part);
    }
}

// --- a style attribute ----------------------------------------------------------

/// A `style` attribute's declarations, `name: value;` one at a time,
/// comments passed over and `!important` left off.
pub const Declarations = struct {
    text: []const u8,
    at: usize = 0,

    pub const Declaration = struct { name: []const u8, value: []const u8 };

    pub fn next(d: *Declarations) ?Declaration {
        while (d.at < d.text.len) {
            const end = d.endOfDeclaration();
            const one = d.text[d.at..end];
            d.at = if (end < d.text.len) end + 1 else end;
            const colon = std.mem.indexOfScalar(u8, one, ':') orelse continue;
            const name = trim(withoutComments(one[0..colon]));
            var value = trim(withoutComments(one[colon + 1 ..]));
            if (std.mem.lastIndexOfScalar(u8, value, '!')) |bang| {
                if (eqlLower(trim(value[bang + 1 ..]), "important")) value = trim(value[0..bang]);
            }
            if (name.len == 0) continue;
            return .{ .name = name, .value = value };
        }
        return null;
    }

    /// The `;` that ends the declaration, not one inside quotes, brackets
    /// or a comment.
    fn endOfDeclaration(d: *const Declarations) usize {
        var i = d.at;
        var quote: u8 = 0;
        var depth: u32 = 0;
        while (i < d.text.len) : (i += 1) {
            const c = d.text[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == '(') {
                depth += 1;
            } else if (c == ')') {
                depth -|= 1;
            } else if (c == '/' and i + 1 < d.text.len and d.text[i + 1] == '*') {
                i = if (std.mem.indexOfPos(u8, d.text, i + 2, "*/")) |close| close + 1 else d.text.len;
            } else if (c == ';' and depth == 0) return i;
        }
        return d.text.len;
    }
};

/// A piece of a declaration with a comment at its ends left off; one in
/// its middle is rare enough to be left as it is.
fn withoutComments(text: []const u8) []const u8 {
    var t = trim(text);
    while (t.len >= 4 and t[0] == '/' and t[1] == '*') {
        const close = std.mem.indexOf(u8, t, "*/") orelse return "";
        t = trim(t[close + 2 ..]);
    }
    while (std.mem.indexOf(u8, t, "/*")) |open| {
        if (std.mem.indexOfPos(u8, t, open, "*/") == null) {
            t = trim(t[0..open]);
            break;
        }
        if (std.mem.endsWith(u8, t, "*/")) t = trim(t[0..open]) else break;
    }
    return t;
}

// --- small things -----------------------------------------------------------------

pub fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and xml.isSpace(text[start])) start += 1;
    while (end > start and xml.isSpace(text[end - 1])) end -= 1;
    return text[start..end];
}

/// Equal, ignoring case; `lower` written in lower case.
pub fn eqlLower(text: []const u8, lower: []const u8) bool {
    if (text.len != lower.len) return false;
    for (text, lower) |a, b| if (std.ascii.toLower(a) != b) return false;
    return true;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

fn expectColour(want: u32, alpha: f32, got: ?Colour) !void {
    const c = got orelse return error.NoColour;
    try testing.expectApproxEqAbs(fromRgb(want, alpha).r, c.r, 0.003);
    try testing.expectApproxEqAbs(fromRgb(want, alpha).g, c.g, 0.003);
    try testing.expectApproxEqAbs(fromRgb(want, alpha).b, c.b, 0.003);
    try testing.expectApproxEqAbs(alpha, c.a, 0.003);
}

test "numbers, lengths in every unit, fractions" {
    try testing.expectEqual(@as(?f32, 48), number("48.000000"));
    try testing.expectEqual(@as(?f32, -0.5), number(" -.5 "));
    try testing.expectApproxEqAbs(@as(f32, 1.5e-3), number("1.5e-3").?, 1e-9);
    try testing.expectEqual(@as(?f32, null), number("1 2"));
    try testing.expectEqual(@as(f32, 48), length("48.000000px").?.value);
    try testing.expectEqual(@as(f32, 96), length("1in").?.value);
    try testing.expectApproxEqAbs(@as(f32, 37.795), length("1cm").?.value, 0.01);
    try testing.expectEqual(@as(f32, 16), length("12pt").?.value);
    const half = length("50%").?;
    try testing.expect(half.percent);
    try testing.expectEqual(@as(f32, 30), half.resolve(.y, .{ 100, 60 }));
    try testing.expectEqual(@as(?Length, null), length("3furlongs"));
    try testing.expectEqual(@as(?f32, 0.25), fraction("25%"));
    try testing.expectEqual(@as(?f32, 1), fraction("7"));
}

test "colours: hex, functions, names, transparent" {
    try expectColour(0xFF0000, 1, colour("#f00"));
    try expectColour(0x204A87, 1, colour("#204a87"));
    try expectColour(0x112233, 0x44.0 / 255.0, colour("#11223344"));
    try expectColour(0x0A141E, 1, colour("rgb(10, 20, 30)"));
    try expectColour(0x808080, 0.5, colour("rgba(50%,50%,50%,0.5)"));
    try expectColour(0x00FF00, 1, colour("hsl(120, 100%, 50%)"));
    try expectColour(0x2E3436, 1, colour("#2e3436"));
    try expectColour(0x000000, 1, colour(" Black "));
    try expectColour(0x663399, 1, colour("rebeccapurple"));
    try testing.expectEqual(@as(f32, 0), colour("transparent").?.a);
    try testing.expect(colour("currentColor") == null);
    try testing.expect(colour("#12") == null);
    try testing.expect(colour("notacolour") == null);
}

test "paints: none, a colour, currentColor, a gradient with and without a fallback" {
    try testing.expect(paint("none").? == .none);
    try testing.expect(paint("currentColor").? == .current);
    const url = paint("url(#linearGradient5060)").?.url;
    try testing.expectEqualStrings("linearGradient5060", url.id);
    try testing.expect(url.fallback == .absent);
    const with = paint("url('#g') red").?.url;
    try testing.expectEqualStrings("g", with.id);
    try expectColour(0xFF0000, 1, with.fallback.colour);
    try testing.expect(paint("bogus") == null);
}

test "transforms: a list applied right to left, and one in error" {
    const m = transform("translate(10,20) scale(2)").?;
    try testing.expectEqual(vector.Point{ .x = 12, .y = 22 }, m.apply(.{ .x = 1, .y = 1 }));
    const r = transform("rotate(90 10 10)").?;
    const p = r.apply(.{ .x = 20, .y = 10 });
    try testing.expectApproxEqAbs(@as(f32, 10), p.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), p.y, 0.001);
    const full = transform("matrix(-2.774389,0,0,1.969706,112.7623,-872.8854)").?;
    try testing.expectApproxEqAbs(@as(f32, -2.774389), full.a, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -872.8854), full.f, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1), transform("skewX(45)").?.c, 1e-5);
    try testing.expect(transform("translate(1,2") == null);
    try testing.expect(transform("spin(3)") == null);
    try testing.expect(transform("").?.isIdentity());
}

test "a style attribute's declarations, comments and !important left off" {
    var d = Declarations{ .text = "fill:#fff; /* x */ stroke : url(#a;b) ;opacity:0.5 !important;;bad" };
    const first = d.next().?;
    try testing.expectEqualStrings("fill", first.name);
    try testing.expectEqualStrings("#fff", first.value);
    const second = d.next().?;
    try testing.expectEqualStrings("stroke", second.name);
    try testing.expectEqualStrings("url(#a;b)", second.value);
    const third = d.next().?;
    try testing.expectEqualStrings("opacity", third.name);
    try testing.expectEqualStrings("0.5", third.value);
    try testing.expect(d.next() == null);
}
