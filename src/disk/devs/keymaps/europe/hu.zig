// SPDX-License-Identifier: MIT
//! The "hu" keymap: the Hungarian QWERTZ layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap hu`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("hu", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "0§¬¬",
        "1'~\u{303}",
        "2\"\u{30C}ˇ",
        "3+^\u{302}",
        "4!\u{306}˘",
        "5%\u{30A}°",
        "6/\u{328}˛",
        "7=`\u{300}",
        "8(\u{307}˙",
        "9)\u{301}´",
        "öÖ\u{30B}˝",
        "üÜ\u{308}¨",
        "óÓ\u{327}¸",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ\\Ω",
        "wW|§",
        "eEÄE",
        "rR¶®",
        "tTŧŦ",
        "zZ–¥",
        "uU€↑",
        "iIÍí",
        "oO„Ø",
        "pP”Þ",
        "őŐ÷\u{30A}",
        "úÚ×\u{304}",
    },
    // the middle row, from the key at A
    .home = .{
        "aAäÄ",
        "sSđẞ",
        "dDĐÐ",
        "fF[ª",
        "gG]Ŋ",
        "hHħĦ",
        "jJíÍ",
        "kKł&",
        "lLŁŁ",
        "éÉ$¢",
        "áÁßẞ",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "yY><",
        "xX#>",
        "cC&©",
        "vV@‚",
        "bB{‘",
        "nN}’",
        "mM<º",
        ",?;×",
        ".:>÷",
        "-_*\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "űŰ¤\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "íÍ<>",
    .decimal = ',',
});

comptime {
    europe.publish(keymap);
}
