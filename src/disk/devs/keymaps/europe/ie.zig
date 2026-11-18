// SPDX-License-Identifier: MIT
//! The "ie" keymap: Ireland's layout: the United Kingdom's, with the vowels' acute accents on alt. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap ie`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("ie", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "`¬¦",
        "1!¡¹",
        "2\"™²",
        "3£©³",
        "4$€¢",
        "5%§†",
        "6^\u{302}‰",
        "7&¶⁊",
        "8*\u{308}•",
        "9(ª·",
        "0)º°",
        "-_–—",
        "=+≠±",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQœŒ",
        "wW\u{307}\u{307}",
        "eEéÉ",
        "rR®‰",
        "tTþÞ",
        "yY¥µ",
        "uUúÚ",
        "iIíÍ",
        "oOóÓ",
        "pP‚",
        "[{“”",
        "]}‘’",
    },
    // the middle row, from the key at A
    .home = .{
        "aAáÁ",
        "sSßẞ",
        "dDðÐ",
        "fFƒ",
        "gG©",
        "hH\u{307}\u{307}",
        "jJı¼",
        "kK\u{30A}½",
        "lL´¾",
        ";:…‡",
        "'@æÆ",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZ⟨⟩",
        "xX×∼",
        "cC\u{327}¸",
        "vV\u{30C}",
        "bB¨",
        "nN\u{303}",
        "mM¯",
        ",<≤„",
        ".>≥‚",
        "/?÷¿",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "#~«»",
    // the key right of the left Shift on an ISO keyboard
    .angle = "\\|\u{300}\u{301}",
});

comptime {
    europe.publish(keymap);
}
