// SPDX-License-Identifier: MIT
//! The "dk" keymap: Denmark's layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap dk`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("dk", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "½§¾¶",
        "1!¡¹",
        "2\"@²",
        "3#£³",
        "4¤$¼",
        "5%½¢",
        "6&¥⅝",
        "7/{÷",
        "8([«",
        "9)]»",
        "0=}°",
        "+?±¿",
        "\u{301}\u{300}|¦",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ@Ω",
        "wWſ§",
        "eE€¢",
        "rR®®",
        "tTþÞ",
        "yY←¥",
        "uU↓↑",
        "iI→ı",
        "oOœŒ",
        "pPþÞ",
        "åÅ\u{308}\u{30A}",
        "\u{308}\u{302}\u{303}\u{30C}",
    },
    // the middle row, from the key at A
    .home = .{
        "aAªº",
        "sSßẞ",
        "dDðÐ",
        "fFđª",
        "gGŋŊ",
        "hHħĦ",
        "jJ",
        "kKĸ&",
        "lLłŁ",
        "æÆ\u{301}\u{30B}",
        "øØ\u{302}\u{30C}",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZ«<",
        "xX»>",
        "cC©©",
        "vV„‚",
        "bB“‘",
        "nN”’",
        "mMµº",
        ",;\u{327}\u{328}",
        ".:·\u{307}",
        "-_\u{323}\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "'*\u{30B}×",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>\\¬",
    .decimal = ',',
});

comptime {
    europe.publish(keymap);
}
