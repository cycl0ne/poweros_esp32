// SPDX-License-Identifier: MIT
//! The "hr" keymap: Croatia's layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap hr`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("hr", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "`~¬¬",
        "1!~\u{303}",
        "2\"\u{30C}ˇ",
        "3#^\u{302}",
        "4$\u{306}˘",
        "5%°\u{30A}",
        "6&\u{328}˛",
        "7/`\u{300}",
        "8(\u{307}˙",
        "9)\u{301}'",
        "0=\u{30B}˝",
        "'?\u{308}¨",
        "+*\u{327}¸",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ\\Ω",
        "wW|Ł",
        "eE€€",
        "rR¶®",
        "tTŧŦ",
        "zZ←¥",
        "uU↓↑",
        "iI→ı",
        "oOøØ",
        "pPþÞ",
        "šŠ÷\u{30A}",
        "đĐ×\u{304}",
    },
    // the middle row, from the key at A
    .home = .{
        "aAæÆ",
        "sS„»",
        "dD”«",
        "fF[ª",
        "gG]Ŋ",
        "hHħĦ",
        "jJ",
        "kKł&",
        "lLłŁ",
        "čČ\u{301}\u{30B}",
        "ćĆß\u{30C}",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "yY‘»",
        "xX’«",
        "cC¢©",
        "vV@`",
        "bB{'",
        "nN}´",
        "mM§º",
        ",;<×",
        ".:>÷",
        "-_\u{323}\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "žŽ¤\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>|¦",
    .decimal = ',',
});

comptime {
    europe.publish(keymap);
}
