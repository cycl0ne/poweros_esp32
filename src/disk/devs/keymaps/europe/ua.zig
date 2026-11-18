// SPDX-License-Identifier: MIT
//! The "ua" keymap: the Ukrainian layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap ua`); what a key's characters say is in `_europe.zig`.
//!
//! Alt types what the key types on the US layout, with shift too, and
//! control makes that letter's control character: one keymap is the
//! whole system's, and a command, a path and the line that sets another
//! keymap have to be typable while this one is set.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("ua", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "'ʼ`~",
        "1!1!",
        "2\"2@",
        "3№3#",
        "4;4$",
        "5%5%",
        "6:6^",
        "7?7&",
        "8*8*",
        "9(9(",
        "0)0)",
        "-_-_",
        "=+=+",
    },
    // the top letter row, from the key at Q
    .top = .{
        "йЙqQ",
        "цЦwW",
        "уУeE",
        "кКrR",
        "еЕtT",
        "нНyY",
        "гГuU",
        "шШiI",
        "щЩoO",
        "зЗpP",
        "хХ[{",
        "їЇ]}",
    },
    // the middle row, from the key at A
    .home = .{
        "фФaA",
        "іІsS",
        "вВdD",
        "аАfF",
        "пПgG",
        "рРhH",
        "оОjJ",
        "лЛkK",
        "дДlL",
        "жЖ;:",
        "єЄ'\"",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "яЯzZ",
        "чЧxX",
        "сСcC",
        "мМvV",
        "иИbB",
        "тТnN",
        "ьЬmM",
        "бБ,<",
        "юЮ.>",
        ".,/?",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "ґҐ\\|",
    // the key right of the left Shift on an ISO keyboard
    .angle = "/|<>",
});

comptime {
    europe.publish(keymap);
}
