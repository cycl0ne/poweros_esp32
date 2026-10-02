// SPDX-License-Identifier: MIT
//! Barcode encoders: a text as a row of modules, each a bar or a space of
//! the narrowest width, quiet zones not included.
//!
//! **Code 128** takes printable ASCII (32 to 126). A text of digits only,
//! an even count of them and at least four, is written in code set C, two
//! digits a symbol; anything else in code set B, a character a symbol.
//! The symbols are the start code, the text, the check symbol - the start
//! code's value plus each symbol's value times its place, modulo 103 - and
//! the stop code. Each symbol is six widths, bar first, eleven modules in
//! all; the stop code seven widths and thirteen.
//!
//! **EAN-13** takes 12 digits, to which the check digit is added, or 13
//! whose last is the right check digit. The first digit is not drawn: it
//! is the pattern of odd and even parity the next six are written in. A
//! start guard, six digits, a centre guard, six digits and an end guard:
//! 95 modules.

pub const max_modules = 11 * (max_text + 3) + 2;
pub const max_text = 80;

/// The six widths of each Code 128 symbol, 0 to 105, and the stop code's
/// seven.
const code128 = [106]*const [6]u8{
    "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212", "221213",
    "221312", "231212", "112232", "122132", "122231", "113222", "123122", "123221", "223211", "221132",
    "221231", "213212", "223112", "312131", "311222", "321122", "321221", "312212", "322112", "322211",
    "212123", "212321", "232121", "111323", "131123", "131321", "112313", "132113", "132311", "211313",
    "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121", "313121", "211331",
    "231131", "213113", "213311", "213131", "311123", "311321", "331121", "312113", "312311", "332111",
    "314111", "221411", "431111", "111224", "111422", "121124", "121421", "141122", "141221", "112214",
    "112412", "122114", "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111",
    "111242", "121142", "121241", "114212", "124112", "124211", "411212", "421112", "421211", "212141",
    "214121", "412121", "111143", "111341", "131141", "114113", "114311", "411113", "411311", "113141",
    "114131", "311141", "411131", "211412", "211214", "211232",
};
const code128_stop = "2331112";
const start_b = 104;
const start_c = 105;

/// The modules written so far: a byte each, 1 a bar.
pub const Row = struct {
    modules: []u8,
    len: usize = 0,

    fn widths(r: *Row, pattern: []const u8) void {
        var bar = true;
        for (pattern) |w| {
            for (0..w - '0') |_| {
                r.modules[r.len] = @intFromBool(bar);
                r.len += 1;
            }
            bar = !bar;
        }
    }

    fn bits(r: *Row, pattern: []const u8) void {
        for (pattern) |b| {
            r.modules[r.len] = @intFromBool(b == '1');
            r.len += 1;
        }
    }
};

fn allDigits(text: []const u8) bool {
    for (text) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// `text` as Code 128 into `modules` (`max_modules` long); the count, or
/// null for a text it cannot write.
pub fn code128Modules(text: []const u8, modules: []u8) ?usize {
    if (text.len == 0 or text.len > max_text) return null;
    var row = Row{ .modules = modules };
    const as_c = text.len >= 4 and text.len % 2 == 0 and allDigits(text);
    const start: u32 = if (as_c) start_c else start_b;
    row.widths(code128[start]);
    var check: u32 = start;
    var place: u32 = 1;
    if (as_c) {
        var i: usize = 0;
        while (i < text.len) : (i += 2) {
            const value: u32 = (text[i] - '0') * 10 + (text[i + 1] - '0');
            row.widths(code128[value]);
            check += value * place;
            place += 1;
        }
    } else {
        for (text) |c| {
            if (c < 32 or c > 126) return null;
            const value: u32 = c - 32;
            row.widths(code128[value]);
            check += value * place;
            place += 1;
        }
    }
    row.widths(code128[check % 103]);
    row.widths(code128_stop);
    return row.len;
}

const ean_l = [10]*const [7]u8{ "0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011" };
const ean_g = [10]*const [7]u8{ "0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111" };
const ean_r = [10]*const [7]u8{ "1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100" };
/// For each first digit, which of the left six are in G (1) rather than L.
const ean_parity = [10]*const [6]u8{ "000000", "001011", "001101", "001110", "010011", "011001", "011100", "010101", "010110", "011010" };

/// The check digit of an EAN-13's first twelve digits.
pub fn eanCheck(digits: []const u8) u8 {
    var sum: u32 = 0;
    for (digits[0..12], 0..) |d, i| sum += @as(u32, d - '0') * (if (i % 2 == 1) @as(u32, 3) else 1);
    return @intCast((10 - sum % 10) % 10);
}

/// `text` as EAN-13 into `modules`, its 13 digits into `full`; the count
/// (95), or null for a text that is not 12 digits or 13 with the right
/// check digit.
pub fn ean13Modules(text: []const u8, modules: []u8, full: *[13]u8) ?usize {
    if ((text.len != 12 and text.len != 13) or !allDigits(text)) return null;
    const check = eanCheck(text);
    if (text.len == 13 and text[12] - '0' != check) return null;
    @memcpy(full[0..12], text[0..12]);
    full[12] = '0' + check;
    var row = Row{ .modules = modules };
    row.bits("101");
    const parity = ean_parity[full[0] - '0'];
    for (1..7) |i| row.bits(if (parity[i - 1] == '1') ean_g[full[i] - '0'] else ean_l[full[i] - '0']);
    row.bits("01010");
    for (7..13) |i| row.bits(ean_r[full[i] - '0']);
    row.bits("101");
    return row.len;
}
