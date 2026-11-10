// SPDX-License-Identifier: MIT
//! Character references - `&eacute;`, `&#233;`, `&#xE9;` - read into the
//! characters they stand for, and the bytes of Windows' code page 1252
//! that Latin-1 has as controls.
//!
//! **The names are HTML 4's 252 and `&apos;`**: Latin-1's characters,
//! the typographic ones and the Greek letters and symbols. Each takes a
//! `;` after it. Without one - or where the name and its `;` are none of
//! these - the longest of the names a page of the last century wrote
//! without it that the text starts with is read, in text and never in an
//! attribute, where `&copy=1` in a link's query is not a character.
//!
//! **A number is Unicode's**, except where a page means 1252 by it:
//! `&#150;` is a dash, as every browser reads it. Nothing, a surrogate or
//! a number past Unicode is U+FFFD.

/// What a reference stood for, and where it ended.
pub const Reference = struct { code: u32, end: usize };

/// The reference that starts at `text[at]`, an `&`; null when that `&`
/// is a character.
pub fn reference(text: []const u8, at: usize, in_attribute: bool) ?Reference {
    var end = at + 1;
    if (end < text.len and text[end] == '#') return number(text, end + 1);
    while (end < text.len and end - at <= 32 and isAlphanumeric(text[end])) end += 1;
    if (end == at + 1) return null;
    const name = text[at + 1 .. end];
    if (end < text.len and text[end] == ';') {
        if (named(name)) |code| return .{ .code = code, .end = end + 1 };
    }
    if (in_attribute) return null;
    // Not a name with its `;`: the longest of the old names it starts
    // with, `&notit;` the sign `not` and `it;`.
    var best: ?Reference = null;
    var best_length: usize = 0;
    for (latin1_names, 0..) |known, index| {
        if (known.len > best_length and startsWith(name, known)) {
            best = .{ .code = 0xA0 + @as(u32, @intCast(index)), .end = at + 1 + known.len };
            best_length = known.len;
        }
    }
    for (bare_names) |known| {
        if (known.name.len > best_length and startsWith(name, known.name)) {
            best = .{ .code = known.code, .end = at + 1 + known.name.len };
            best_length = known.name.len;
        }
    }
    return best;
}

/// `&#` and digits, decimal or `x` and hex, with or without the `;`.
fn number(text: []const u8, from: usize) ?Reference {
    var at = from;
    const hex = at < text.len and (text[at] == 'x' or text[at] == 'X');
    if (hex) at += 1;
    const digits_at = at;
    var code: u32 = 0;
    while (at < text.len) : (at += 1) {
        const char = text[at];
        const value: u32 = switch (char) {
            '0'...'9' => char - '0',
            'a'...'f' => if (hex) char - 'a' + 10 else break,
            'A'...'F' => if (hex) char - 'A' + 10 else break,
            else => break,
        };
        code = @min(code *| (if (hex) @as(u32, 16) else 10) +| value, 0x11_0000);
    }
    if (at == digits_at) return null;
    if (at < text.len and text[at] == ';') at += 1;
    if (code == 0 or code > 0x10_FFFF or (code >= 0xD800 and code <= 0xDFFF)) code = 0xFFFD;
    if (code >= 0x80 and code <= 0x9F) code = fromCp1252(@intCast(code));
    return .{ .code = code, .end = at };
}

/// The character a byte from 0x80 to 0x9F is in code page 1252; 0 for
/// the five it has none for.
pub fn fromCp1252(byte: u8) u32 {
    const table = [32]u16{
        0x20AC, 0,      0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0,      0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    };
    if (byte < 0x80 or byte > 0x9F) return byte;
    return table[byte - 0x80];
}

fn named(name: []const u8) ?u32 {
    for (latin1_names, 0..) |known, index| {
        if (same(name, known)) return 0xA0 + @as(u32, @intCast(index));
    }
    for (other_names) |known| {
        if (same(name, known.name)) return known.code;
    }
    return null;
}

/// Latin-1's from U+00A0 on, in order: the index is the character less
/// 0xA0.
const latin1_names = [96][]const u8{
    "nbsp",   "iexcl",  "cent",   "pound",  "curren", "yen",    "brvbar", "sect",
    "uml",    "copy",   "ordf",   "laquo",  "not",    "shy",    "reg",    "macr",
    "deg",    "plusmn", "sup2",   "sup3",   "acute",  "micro",  "para",   "middot",
    "cedil",  "sup1",   "ordm",   "raquo",  "frac14", "frac12", "frac34", "iquest",
    "Agrave", "Aacute", "Acirc",  "Atilde", "Auml",   "Aring",  "AElig",  "Ccedil",
    "Egrave", "Eacute", "Ecirc",  "Euml",   "Igrave", "Iacute", "Icirc",  "Iuml",
    "ETH",    "Ntilde", "Ograve", "Oacute", "Ocirc",  "Otilde", "Ouml",   "times",
    "Oslash", "Ugrave", "Uacute", "Ucirc",  "Uuml",   "Yacute", "THORN",  "szlig",
    "agrave", "aacute", "acirc",  "atilde", "auml",   "aring",  "aelig",  "ccedil",
    "egrave", "eacute", "ecirc",  "euml",   "igrave", "iacute", "icirc",  "iuml",
    "eth",    "ntilde", "ograve", "oacute", "ocirc",  "otilde", "ouml",   "divide",
    "oslash", "ugrave", "uacute", "ucirc",  "uuml",   "yacute", "thorn",  "yuml",
};

const Named = struct { name: []const u8, code: u32 };

/// The old names read without a `;` besides Latin-1's.
const bare_names = [_]Named{
    .{ .name = "amp", .code = '&' }, .{ .name = "lt", .code = '<' },
    .{ .name = "gt", .code = '>' },  .{ .name = "quot", .code = '"' },
};

const other_names = [_]Named{
    .{ .name = "quot", .code = 34 },      .{ .name = "amp", .code = 38 },      .{ .name = "apos", .code = 39 },
    .{ .name = "lt", .code = 60 },        .{ .name = "gt", .code = 62 },       .{ .name = "OElig", .code = 338 },
    .{ .name = "oelig", .code = 339 },    .{ .name = "Scaron", .code = 352 },  .{ .name = "scaron", .code = 353 },
    .{ .name = "Yuml", .code = 376 },     .{ .name = "fnof", .code = 402 },    .{ .name = "circ", .code = 710 },
    .{ .name = "tilde", .code = 732 },    .{ .name = "Alpha", .code = 913 },   .{ .name = "Beta", .code = 914 },
    .{ .name = "Gamma", .code = 915 },    .{ .name = "Delta", .code = 916 },   .{ .name = "Epsilon", .code = 917 },
    .{ .name = "Zeta", .code = 918 },     .{ .name = "Eta", .code = 919 },     .{ .name = "Theta", .code = 920 },
    .{ .name = "Iota", .code = 921 },     .{ .name = "Kappa", .code = 922 },   .{ .name = "Lambda", .code = 923 },
    .{ .name = "Mu", .code = 924 },       .{ .name = "Nu", .code = 925 },      .{ .name = "Xi", .code = 926 },
    .{ .name = "Omicron", .code = 927 },  .{ .name = "Pi", .code = 928 },      .{ .name = "Rho", .code = 929 },
    .{ .name = "Sigma", .code = 931 },    .{ .name = "Tau", .code = 932 },     .{ .name = "Upsilon", .code = 933 },
    .{ .name = "Phi", .code = 934 },      .{ .name = "Chi", .code = 935 },     .{ .name = "Psi", .code = 936 },
    .{ .name = "Omega", .code = 937 },    .{ .name = "alpha", .code = 945 },   .{ .name = "beta", .code = 946 },
    .{ .name = "gamma", .code = 947 },    .{ .name = "delta", .code = 948 },   .{ .name = "epsilon", .code = 949 },
    .{ .name = "zeta", .code = 950 },     .{ .name = "eta", .code = 951 },     .{ .name = "theta", .code = 952 },
    .{ .name = "iota", .code = 953 },     .{ .name = "kappa", .code = 954 },   .{ .name = "lambda", .code = 955 },
    .{ .name = "mu", .code = 956 },       .{ .name = "nu", .code = 957 },      .{ .name = "xi", .code = 958 },
    .{ .name = "omicron", .code = 959 },  .{ .name = "pi", .code = 960 },      .{ .name = "rho", .code = 961 },
    .{ .name = "sigmaf", .code = 962 },   .{ .name = "sigma", .code = 963 },   .{ .name = "tau", .code = 964 },
    .{ .name = "upsilon", .code = 965 },  .{ .name = "phi", .code = 966 },     .{ .name = "chi", .code = 967 },
    .{ .name = "psi", .code = 968 },      .{ .name = "omega", .code = 969 },   .{ .name = "thetasym", .code = 977 },
    .{ .name = "upsih", .code = 978 },    .{ .name = "piv", .code = 982 },     .{ .name = "ensp", .code = 8194 },
    .{ .name = "emsp", .code = 8195 },    .{ .name = "thinsp", .code = 8201 }, .{ .name = "zwnj", .code = 8204 },
    .{ .name = "zwj", .code = 8205 },     .{ .name = "lrm", .code = 8206 },    .{ .name = "rlm", .code = 8207 },
    .{ .name = "ndash", .code = 8211 },   .{ .name = "mdash", .code = 8212 },  .{ .name = "lsquo", .code = 8216 },
    .{ .name = "rsquo", .code = 8217 },   .{ .name = "sbquo", .code = 8218 },  .{ .name = "ldquo", .code = 8220 },
    .{ .name = "rdquo", .code = 8221 },   .{ .name = "bdquo", .code = 8222 },  .{ .name = "dagger", .code = 8224 },
    .{ .name = "Dagger", .code = 8225 },  .{ .name = "bull", .code = 8226 },   .{ .name = "hellip", .code = 8230 },
    .{ .name = "permil", .code = 8240 },  .{ .name = "prime", .code = 8242 },  .{ .name = "Prime", .code = 8243 },
    .{ .name = "lsaquo", .code = 8249 },  .{ .name = "rsaquo", .code = 8250 }, .{ .name = "oline", .code = 8254 },
    .{ .name = "frasl", .code = 8260 },   .{ .name = "euro", .code = 8364 },   .{ .name = "image", .code = 8465 },
    .{ .name = "weierp", .code = 8472 },  .{ .name = "real", .code = 8476 },   .{ .name = "trade", .code = 8482 },
    .{ .name = "alefsym", .code = 8501 }, .{ .name = "larr", .code = 8592 },   .{ .name = "uarr", .code = 8593 },
    .{ .name = "rarr", .code = 8594 },    .{ .name = "darr", .code = 8595 },   .{ .name = "harr", .code = 8596 },
    .{ .name = "crarr", .code = 8629 },   .{ .name = "lArr", .code = 8656 },   .{ .name = "uArr", .code = 8657 },
    .{ .name = "rArr", .code = 8658 },    .{ .name = "dArr", .code = 8659 },   .{ .name = "hArr", .code = 8660 },
    .{ .name = "forall", .code = 8704 },  .{ .name = "part", .code = 8706 },   .{ .name = "exist", .code = 8707 },
    .{ .name = "empty", .code = 8709 },   .{ .name = "nabla", .code = 8711 },  .{ .name = "isin", .code = 8712 },
    .{ .name = "notin", .code = 8713 },   .{ .name = "ni", .code = 8715 },     .{ .name = "prod", .code = 8719 },
    .{ .name = "sum", .code = 8721 },     .{ .name = "minus", .code = 8722 },  .{ .name = "lowast", .code = 8727 },
    .{ .name = "radic", .code = 8730 },   .{ .name = "prop", .code = 8733 },   .{ .name = "infin", .code = 8734 },
    .{ .name = "ang", .code = 8736 },     .{ .name = "and", .code = 8743 },    .{ .name = "or", .code = 8744 },
    .{ .name = "cap", .code = 8745 },     .{ .name = "cup", .code = 8746 },    .{ .name = "int", .code = 8747 },
    .{ .name = "there4", .code = 8756 },  .{ .name = "sim", .code = 8764 },    .{ .name = "cong", .code = 8773 },
    .{ .name = "asymp", .code = 8776 },   .{ .name = "ne", .code = 8800 },     .{ .name = "equiv", .code = 8801 },
    .{ .name = "le", .code = 8804 },      .{ .name = "ge", .code = 8805 },     .{ .name = "sub", .code = 8834 },
    .{ .name = "sup", .code = 8835 },     .{ .name = "nsub", .code = 8836 },   .{ .name = "sube", .code = 8838 },
    .{ .name = "supe", .code = 8839 },    .{ .name = "oplus", .code = 8853 },  .{ .name = "otimes", .code = 8855 },
    .{ .name = "perp", .code = 8869 },    .{ .name = "sdot", .code = 8901 },   .{ .name = "lceil", .code = 8968 },
    .{ .name = "rceil", .code = 8969 },   .{ .name = "lfloor", .code = 8970 }, .{ .name = "rfloor", .code = 8971 },
    .{ .name = "lang", .code = 9001 },    .{ .name = "rang", .code = 9002 },   .{ .name = "loz", .code = 9674 },
    .{ .name = "spades", .code = 9824 },  .{ .name = "clubs", .code = 9827 },  .{ .name = "hearts", .code = 9829 },
    .{ .name = "diams", .code = 9830 },
};

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return same(text[0..prefix.len], prefix);
}

fn isAlphanumeric(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or (char >= '0' and char <= '9');
}

const std = @import("std");
const testing = std.testing;

fn expectCode(text: []const u8, code: u32, length: usize) !void {
    const got = reference(text, 0, false).?;
    try testing.expectEqual(code, got.code);
    try testing.expectEqual(length, got.end);
}

test "names, numbers and the old names without their ;" {
    try expectCode("&eacute;", 0xE9, 8);
    try expectCode("&nbsp;x", 0xA0, 6);
    try expectCode("&mdash;", 0x2014, 7);
    try expectCode("&apos;", '\'', 6);
    try expectCode("&#233;", 0xE9, 6);
    try expectCode("&#xe9;", 0xE9, 6);
    try expectCode("&#X20AC", 0x20AC, 7);
    try expectCode("&#150;", 0x2013, 6);
    try expectCode("&#0;", 0xFFFD, 4);
    try expectCode("&#xD800;", 0xFFFD, 8);
    try expectCode("&amp more", '&', 4);
    try expectCode("&copy2026", 0xA9, 5);
    try expectCode("&notin", 0xAC, 4);
    try testing.expect(reference("&nosuch;", 0, false) == null);
    try expectCode("&notit;", 0xAC, 4);
    try testing.expect(reference("& x", 0, false) == null);
    try testing.expect(reference("&#;", 0, false) == null);
    // In an attribute a name needs its `;`.
    try testing.expect(reference("&copy=1", 0, true) == null);
    try testing.expectEqual(@as(u32, '&'), reference("&amp;", 0, true).?.code);
    try testing.expectEqual(@as(u32, 0x201C), fromCp1252(0x93));
    try testing.expectEqual(@as(u32, 0), fromCp1252(0x81));
}
