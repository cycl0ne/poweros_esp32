// SPDX-License-Identifier: MIT
//! The "ee" keymap: Estonia's layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap ee`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("ee", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "\u{30C}\u{303}•·",
        "1!¹¡",
        "2\"@⅛",
        "3#££",
        "4¤$$",
        "5%€⅜",
        "6&¬⅝",
        "7/{⅞",
        "8([™",
        "9)]±",
        "0=}°",
        "+?\\¿",
        "\u{301}\u{300}`\u{327}",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ@Ω",
        "wWßΣ",
        "eE€¢",
        "rR¶®",
        "tTŧŦ",
        "yY←¥",
        "uU↓↑",
        "iI→ı",
        "oOøØ",
        "pPþÞ",
        "üÜ\u{308}\u{30A}",
        "õÕ§\u{304}",
    },
    // the middle row, from the key at A
    .home = .{
        "aAæÆ",
        "sSšŠ",
        "dDðÐ",
        "fFđª",
        "gGŋŊ",
        "hHħĦ",
        "jJ",
        "kKĸ&",
        "lLłŁ",
        "öÖ\u{301}\u{30B}",
        "äÄ^\u{302}",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZžŽ",
        "xX»«",
        "cC¢©",
        "vV„‚",
        "bB“‘",
        "nN”’",
        "mMµº",
        ",;<×",
        ".:>÷",
        "-_|\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "'*½\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>|¦",
});

comptime {
    europe.publish(keymap);
}
