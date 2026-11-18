// SPDX-License-Identifier: MIT
//! The "nl" keymap: the US layout with the accents on alt, which the Netherlands type on. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap nl`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("nl", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "`~\u{300}\u{303}",
        "1!¹¡",
        "2@²\u{30B}",
        "3#³\u{304}",
        "4$¤£",
        "5%€\u{327}",
        "6^\u{302}¼",
        "7&\x00½",
        "8*\u{328}¾",
        "9(‘\u{306}",
        "0)’\u{30A}",
        "-_¥\u{323}",
        "=+×÷",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQäÄ",
        "wWåÅ",
        "eEéÉ",
        "rRëË",
        "tTþÞ",
        "yYüÜ",
        "uUúÚ",
        "iIíÍ",
        "oOóÓ",
        "pPöÖ",
        "[{«“",
        "]}»”",
    },
    // the middle row, from the key at A
    .home = .{
        "aAáÁ",
        "sSß§",
        "dDðÐ",
        "fFfF",
        "gGgG",
        "hHhH",
        "jJïÏ",
        "kKœŒ",
        "lLøØ",
        ";:¶°",
        "'\"\u{301}\u{308}",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZæÆ",
        "xXœŒ",
        "cC©¢",
        "vV®™",
        "bB·",
        "nNñÑ",
        "mMµ±",
        ",<çÇ",
        ".>\u{307}\u{30C}",
        "/?¿",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "\\|¬¦",
    // the key right of the left Shift on an ISO keyboard
    .angle = "\\|\\|",
});

comptime {
    europe.publish(keymap);
}
