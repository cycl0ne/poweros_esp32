// SPDX-License-Identifier: MIT
//! The "sk" keymap: the Slovak QWERTZ layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap sk`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("sk", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        ";\u{30A}`~",
        "+1!\u{303}",
        "ľ2@\u{30C}",
        "š3#\u{302}",
        "č4$\u{306}",
        "ť5%\u{30A}",
        "ž6^\u{328}",
        "ý7&\u{300}",
        "á8*\u{307}",
        "í9{\u{301}",
        "é0}\u{30B}",
        "=%\\\u{308}",
        "\u{301}\u{30C}\u{304}\u{327}",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ\\Ω",
        "wW|§",
        "eE€E",
        "rR¶®",
        "tTŧŦ",
        "zZ←¥",
        "uU↓↑",
        "iI→ı",
        "oOøØ",
        "pPþÞ",
        "ú/[÷",
        "ä(]×",
    },
    // the middle row, from the key at A
    .home = .{
        "aA~Æ",
        "sSđẞ",
        "dDĐÐ",
        "fF[ª",
        "gG]Ŋ",
        "hH`Ħ",
        "jJ'",
        "kKł&",
        "lLŁŁ",
        "ô\"$\u{30B}",
        "§!'ß",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "yY°<",
        "xX#>",
        "cC&©",
        "vV@‚",
        "bB{‘",
        "nN}’",
        "mM^º",
        ",?<×",
        ".:>÷",
        "-_*\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "ň)\\|",
    // the key right of the left Shift on an ISO keyboard
    .angle = "\\|/¦",
});

comptime {
    europe.publish(keymap);
}
