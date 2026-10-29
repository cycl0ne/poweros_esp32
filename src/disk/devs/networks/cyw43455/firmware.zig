// SPDX-License-Identifier: MIT
//! The files the chip runs, for cyw43455.device: its firmware, the board's
//! NVRAM - what the radio is wired to on this board - and the CLM blob,
//! the rules of which channels and powers each country allows. They are
//! in DEVS:networks/firmware/cyw43455/, which `scripts/fetch-cyw43455.sh`
//! fetches from Raspberry Pi's firmware package.
//!
//! **The NVRAM** is a text file of `key=value` lines and `#` comments. The
//! chip takes it as the strings alone, each ended by a NUL, the whole
//! padded with NULs to a word and followed by a word that says how many
//! words it is - in its low half, and inverted in its high half - which
//! is what Linux's brcmfmac makes of the same file (`nvramImage`).

const std = @import("std");

const dir = "DEVS:networks/firmware/cyw43455/";
pub const name_code = dir ++ "cyfmac43455-sdio.bin";
pub const name_clm = dir ++ "cyfmac43455-sdio.clm_blob";
pub const name_nvram = dir ++ "brcmfmac43455-sdio.txt";

/// What the image adds when the file has no board revision.
const default_boardrev = "boardrev=0xff";

/// How many bytes an image of `text` may need: the strings are no longer
/// than the text, and a default, the padding and the length word come
/// after.
pub fn imageBound(text: []const u8) usize {
    return text.len + default_boardrev.len + 1 + 4 + 4;
}

/// A character a key or a value may have: any printable one but `#`,
/// which starts a comment.
fn valueChar(c: u8) bool {
    return c >= 0x20 and c < 0x7F and c != '#';
}

/// The NVRAM image of `text` in `into`, which holds `imageBound(text)`
/// bytes: its length, a whole number of words.
pub fn nvramImage(text: []const u8, into: []u8) usize {
    var out: usize = 0;
    var boardrev = false;
    var at: usize = 0;
    while (at < text.len) {
        const c = text[at];
        if (c == '#') {
            at = endOfLine(text, at);
            continue;
        }
        if (!valueChar(c) or c == ' ') {
            at += 1;
            continue;
        }
        const start = at;
        while (at < text.len and valueChar(text[at]) and text[at] != ' ' and text[at] != '=') at += 1;
        if (at == text.len or text[at] != '=') {
            at = endOfLine(text, at);
            continue;
        }
        const key = text[start..at];
        at += 1;
        while (at < text.len and valueChar(text[at])) at += 1;
        if (std.mem.eql(u8, key, "RAW1")) continue;
        if (std.mem.startsWith(u8, key, "boardrev")) boardrev = true;
        const entry = text[start..at];
        @memcpy(into[out..][0..entry.len], entry);
        out += entry.len;
        into[out] = 0;
        out += 1;
    }
    if (!boardrev) {
        @memcpy(into[out..][0..default_boardrev.len], default_boardrev);
        out += default_boardrev.len;
        into[out] = 0;
        out += 1;
    }
    const padded = (out + 1 + 3) & ~@as(usize, 3);
    @memset(into[out..padded], 0);
    const words: u32 = @intCast(padded / 4);
    std.mem.writeInt(u32, into[padded..][0..4], (~words << 16) | (words & 0xFFFF), .little);
    return padded + 4;
}

/// Past the end of the line `at` is in.
fn endOfLine(text: []const u8, at: usize) usize {
    const newline = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return text.len;
    return newline + 1;
}
