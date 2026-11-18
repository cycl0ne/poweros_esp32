// SPDX-License-Identifier: MIT
//! The "tr" keymap: the Turkish Q layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap tr`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("tr", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "\"é<°",
        "1!>¡",
        "2'£²",
        "3^#³",
        "4+$¼",
        "5%½⅜",
        "6&¾",
        "7/{",
        "8([",
        "9)]±",
        "0=}°",
        "*?\\¿",
        "-_|",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ@Ω",
        "wW",
        "eE€",
        "rR¶®",
        "tT₺",
        "yY←¥",
        "uUûÛ",
        "ıIîÎ",
        "oOôÔ",
        "pP",
        "ğĞ\u{308}\u{30A}",
        "üÜ~\u{304}",
    },
    // the middle row, from the key at A
    .home = .{
        "aAâÂ",
        "sSß",
        "dD",
        "fFª",
        "gG",
        "hH",
        "jJ",
        "kK",
        "lL",
        "şŞ´\u{301}",
        "iİ'\u{30C}",
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
        "öÖ×",
        "çÇ·÷",
        ".:\u{307}\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = ",;`\u{300}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>|¦",
    .decimal = ',',
});

comptime {
    europe.publish(keymap);
}
