// SPDX-License-Identifier: MIT
//! The "fr" keymap: France's AZERTY layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap fr`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("fr", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "²~¬¬",
        "&1¹¡",
        "é2~⅛",
        "\"3#£",
        "'4{$",
        "(5[⅜",
        "-6|⅝",
        "è7`⅞",
        "_8\\™",
        "ç9^±",
        "à0@°",
        ")°]¿",
        "=+}\u{328}",
    },
    // the top letter row, from the key at Q
    .top = .{
        "aAæÆ",
        "zZ«<",
        "eE€¢",
        "rR¶®",
        "tTŧŦ",
        "yY←¥",
        "uU↓↑",
        "iI→ı",
        "oOøØ",
        "pPþÞ",
        "\u{302}\u{308}\u{308}\u{30A}",
        "$£¤\u{304}",
    },
    // the middle row, from the key at A
    .home = .{
        "qQ@Ω",
        "sSßẞ",
        "dDðÐ",
        "fFđª",
        "gGŋŊ",
        "hHħĦ",
        "jJ",
        "kKĸ&",
        "lLłŁ",
        "mMµº",
        "ù%\u{302}\u{30C}",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "wWłŁ",
        "xX»>",
        "cC¢©",
        "vV„‚",
        "bB“‘",
        "nN”’",
        ",?\u{301}\u{30B}",
        ";.•×",
        ":/·÷",
        "!§\u{323}\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "*µ\u{300}\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>|¦",
});

comptime {
    europe.publish(keymap);
}
