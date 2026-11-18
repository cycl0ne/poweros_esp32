// SPDX-License-Identifier: MIT
//! The "be" keymap: Belgium's AZERTY layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap be`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("be", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "²³¬¬",
        "&1|¡",
        "é2@⅛",
        "\"3#£",
        "'4¼$",
        "(5½⅜",
        "§6^⅝",
        "è7{⅞",
        "!8[™",
        "ç9{±",
        "à0}°",
        ")°\\¿",
        "-_\u{327}\u{328}",
    },
    // the top letter row, from the key at Q
    .top = .{
        "aA@Ω",
        "zZſ§",
        "eE€¢",
        "rR¶®",
        "tTŧŦ",
        "yY←¥",
        "uU↓↑",
        "iI→ı",
        "oOœŒ",
        "pPþÞ",
        "\u{302}\u{308}[\u{30A}",
        "$*]\u{304}",
    },
    // the middle row, from the key at A
    .home = .{
        "qQæÆ",
        "sSßẞ",
        "dDðÐ",
        "fFđª",
        "gGŋŊ",
        "hHħĦ",
        "jJ",
        "kKĸ&",
        "lLłŁ",
        "mM\u{301}\u{30B}",
        "ù%\u{301}\u{30C}",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "wW«<",
        "xX»>",
        "cC¢©",
        "vV„‚",
        "bB“‘",
        "nN”’",
        ",?\u{327}º",
        ";.•×",
        ":/·÷",
        "=+\u{303}\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "µ£\u{300}\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>\\\\",
});

comptime {
    europe.publish(keymap);
}
