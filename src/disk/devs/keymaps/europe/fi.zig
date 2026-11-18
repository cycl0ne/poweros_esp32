// SPDX-License-Identifier: MIT
//! The "fi" keymap: Finland's layout: Sweden's, with the letters of the Sami languages on alt. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap fi`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("fi", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "§½",
        "1!\x00¡",
        "2\"@”",
        "3#£»",
        "4¤$«",
        "5%‰“",
        "6&‚„",
        "7/{",
        "8([<",
        "9)]>",
        "0=}°",
        "+?\\¿",
        "\u{301}\u{300}\u{327}\u{328}",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQqQ",
        "wWwW",
        "eE€",
        "rRrR",
        "tTþÞ",
        "yYyY",
        "uUuU",
        "iIı|",
        "oOœŒ",
        "pP",
        "åÅ\u{30B}\u{30A}",
        "\u{308}\u{302}\u{303}\u{304}",
    },
    // the middle row, from the key at A
    .home = .{
        "aAəƏ",
        "sSßẞ",
        "dDðÐ",
        "fFfF",
        "gGgG",
        "hHhH",
        "jJjJ",
        "kKĸ",
        "lL",
        "öÖøØ",
        "äÄæÆ",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZʒƷ",
        "xX×·",
        "cCcC",
        "vVvV",
        "bBbB",
        "nNŋŊ",
        "mMµ—",
        ",;’‘",
        ".:\u{323}\u{307}",
        "-_–\u{326}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "'*\u{30C}\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>|¦",
    .decimal = ',',
});

comptime {
    europe.publish(keymap);
}
