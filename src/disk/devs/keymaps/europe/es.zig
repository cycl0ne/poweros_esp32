// SPDX-License-Identifier: MIT
//! The "es" keymap: Spain's layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap es`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("es", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "ºª\\\\",
        "1!|¡",
        "2\"@⅛",
        "3·#£",
        "4$~$",
        "5%½⅜",
        "6&¬⅝",
        "7/{⅞",
        "8([™",
        "9)]±",
        "0=}°",
        "'?\\¿",
        "¡¿\u{327}\u{328}",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ@Ω",
        "wWſ§",
        "eE€¢",
        "rR¶®",
        "tTŧŦ",
        "yY←¥",
        "uU↓↑",
        "iI→ı",
        "oOøØ",
        "pPþÞ",
        "\u{300}\u{302}[\u{30C}",
        "+*]\u{304}",
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
        "ñÑ\u{303}\u{30A}",
        "\u{301}\u{308}{\u{30B}",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZ«<",
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
    .hash = "çÇ}\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>|¦",
});

comptime {
    europe.publish(keymap);
}
