// SPDX-License-Identifier: MIT
//! The "lt" keymap: Lithuania's layout: the Lithuanian letters on the number row. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap lt`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("lt", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "`~´¬",
        "ąĄ1!",
        "čČ2@",
        "ęĘ3#",
        "ėĖ4$",
        "įĮ5%",
        "šŠ6^",
        "ųŲ7&",
        "ūŪ8*",
        "„(9(",
        "“)0)",
        "-_–¿",
        "žŽ=+",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ@Ω",
        "wWſ§",
        "eE€£",
        "rR¶®",
        "tTŧŦ",
        "yY←¥",
        "uU↓↑",
        "iI→ı",
        "oOøØ",
        "pPþÞ",
        "[{\u{308}\u{30A}",
        "]}\u{303}\u{304}",
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
        ";:\u{301}\u{30B}",
        "'\"\u{302}\u{30C}",
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
        ",<•×",
        ".>·÷",
        "/?\u{323}\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "\\|\u{300}\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "–€|¦",
});

comptime {
    europe.publish(keymap);
}
