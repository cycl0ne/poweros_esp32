// SPDX-License-Identifier: MIT
//! The "ch-fr" keymap: the Swiss layout with French on the keys (è, é, à plain). A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap ch-fr`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("ch-fr", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "§°¬¬",
        "1+|¡",
        "2\"@⅛",
        "3*#£",
        "4ç¼$",
        "5%½⅜",
        "6&¬⅝",
        "7/|⅞",
        "8(¢™",
        "9)]±",
        "0=}°",
        "'?\u{301}¿",
        "\u{302}\u{300}\u{303}\u{328}",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ@Ω",
        "wWſ§",
        "eE€E",
        "rR¶®",
        "tTŧŦ",
        "zZ←¥",
        "uU↓↑",
        "iI→ı",
        "oOœŒ",
        "pPþÞ",
        "èü[\u{30A}",
        "\u{308}!]\u{304}",
    },
    // the middle row, from the key at A
    .home = .{
        "aAæÆ",
        "sSßẞ",
        "dDðÐ",
        "fFđª",
        "gGŋŊ",
        "hHħĦ",
        "jJ",
        "kKĸ&",
        "lLłŁ",
        "éö\u{301}\u{30B}",
        "àä{\u{30C}",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "yY«<",
        "xX»>",
        "cC¢©",
        "vV„‚",
        "bB“‘",
        "nN”’",
        "mMµº",
        ",;•×",
        ".:·÷",
        "-_\u{323}\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "$£}\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>\\¦",
});

comptime {
    europe.publish(keymap);
}
