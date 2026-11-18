// SPDX-License-Identifier: MIT
//! The "ro" keymap: Romania's layout: the US one, with ă â î ș ț on alt. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap ro`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("ro", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "`~",
        "1!\u{303}",
        "2@\u{30C}",
        "3#\u{302}",
        "4$\u{306}",
        "5%\u{30A}",
        "6^\u{328}",
        "7&\u{300}",
        "8*\u{307}",
        "9(\u{301}",
        "0)\u{30B}",
        "-_\u{308}–",
        "=+\u{327}±",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQâÂ",
        "wWßẞ",
        "eE€",
        "rR",
        "tTțȚ",
        "yY",
        "uU",
        "iIîÎ",
        "oO",
        "pP§",
        "[{„",
        "]}”",
    },
    // the middle row, from the key at A
    .home = .{
        "aAăĂ",
        "sSșȘ",
        "dDđĐ",
        "fF",
        "gG",
        "hH",
        "jJ",
        "kK",
        "lLłŁ",
        ";:",
        "'\"",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZ",
        "xX",
        "cC©",
        "vV",
        "bB",
        "nN",
        "mM",
        ",<«",
        ".>»",
        "/?",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "\\|",
    // the key right of the left Shift on an ISO keyboard
    .angle = "\\||¦",
});

comptime {
    europe.publish(keymap);
}
