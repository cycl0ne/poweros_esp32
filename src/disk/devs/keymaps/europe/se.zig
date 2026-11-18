// SPDX-License-Identifier: MIT
//! The "se" keymap: Sweden's layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap se`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("se", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "§½¶¾",
        "1!¡¹",
        "2\"@²",
        "3#£³",
        "4¤$¼",
        "5%€‰",
        "6&¥√",
        "7/{÷",
        "8([«",
        "9)]»",
        "0=}°",
        "+?\\¿",
        "\u{301}\u{300}±¬",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQωΩ",
        "wWσΣ",
        "eE€¢",
        "rR®™",
        "tTþÞ",
        "yY←¥",
        "uU↓↑",
        "iI→ı",
        "oOœŒ",
        "pPπΠ",
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
        "kKĸ†",
        "lLłŁ",
        "öÖøØ",
        "äÄæÆ",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZ«<",
        "xX»>",
        "cC©🄯",
        "vV„‚",
        "bB“‘",
        "nN”’",
        "mMµº",
        ",;\u{327}\u{328}",
        ".:·…",
        "-_\u{323}\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "'*´×",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>|¦",
    .decimal = ',',
});

comptime {
    europe.publish(keymap);
}
