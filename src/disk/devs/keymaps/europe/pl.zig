// SPDX-License-Identifier: MIT
//! The "pl" keymap: Poland's layout: the US one, with ą ć ę ł ń ó ś ź ż on alt. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap pl`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("pl", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "`~¬∨",
        "1!≠¡",
        "2@²¿",
        "3#³£",
        "4$¢¼",
        "5%€‰",
        "6^½∧",
        "7&§≈",
        "8*⋅¾",
        "9(«±",
        "0)»°",
        "-_–—",
        "=+\u{327}\u{328}",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQπΩ",
        "wWœŒ",
        "eEęĘ",
        "rR©®",
        "tTß™",
        "yY←¥",
        "uU↓↑",
        "iI→↔",
        "oOóÓ",
        "pPþÞ",
        "[{\u{308}\u{30A}",
        "]}\u{303}\u{304}",
    },
    // the middle row, from the key at A
    .home = .{
        "aAąĄ",
        "sSśŚ",
        "dDðÐ",
        "fFæÆ",
        "gGŋŊ",
        "hH’•",
        "jJəƏ",
        "kK…",
        "lLłŁ",
        ";:\u{301}\u{30B}",
        "'\"\u{302}\u{30C}",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZżŻ",
        "xXźŹ",
        "cCćĆ",
        "vV„‘",
        "bB”“",
        "nNńŃ",
        "mMμ∞",
        ",<≤×",
        ".>≥÷",
        "/?\u{323}\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "\\|\u{300}\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>|¦",
    .decimal = ',',
});

comptime {
    europe.publish(keymap);
}
