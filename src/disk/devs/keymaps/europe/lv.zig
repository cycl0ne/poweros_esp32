// SPDX-License-Identifier: MIT
//! The "lv" keymap: Latvia's layout: the US one, with the Latvian letters on alt. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap lv`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("lv", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "`~´~",
        "1!¹¡",
        "2@²⅛",
        "3#³£",
        "4$€¢",
        "5%½⅜",
        "6^¾⅝",
        "7&{⅞",
        "8*[™",
        "9(]±",
        "0)}°",
        "-_\\¿",
        "=+–—",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQqQ",
        "wWwW",
        "eEēĒ",
        "rRŗŖ",
        "tTtT",
        "yYyY",
        "uUūŪ",
        "iIīĪ",
        "oOōŌ",
        "pPpP",
        "[{«“",
        "]}»”",
    },
    // the middle row, from the key at A
    .home = .{
        "aAāĀ",
        "sSšŠ",
        "dDdD",
        "fFfF",
        "gGģĢ",
        "hHhH",
        "jJjJ",
        "kKķĶ",
        "lLļĻ",
        ";:;:",
        "'\"“„",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZžŽ",
        "xXxX",
        "cCčČ",
        "vVvV",
        "bBbB",
        "nNņŅ",
        "mMmM",
        ",<•×",
        ".>·÷",
        "/?/˙",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "\\|`˘",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>|¦",
});

comptime {
    europe.publish(keymap);
}
