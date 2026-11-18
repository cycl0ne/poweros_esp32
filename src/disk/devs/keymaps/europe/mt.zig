// SPDX-License-Identifier: MIT
//! The "mt" keymap: Malta's layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap mt`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("mt", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "ċĊ`¬",
        "1!¹¡",
        "2\"²⅛",
        "3€££",
        "4$€¼",
        "5%½⅜",
        "6^\u{302}\u{302}",
        "7&{⅞",
        "8*[™",
        "9(]±",
        "0)}°",
        "-_\\¿",
        "=+\u{327}\u{328}",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ@Ω",
        "wWſ§",
        "eEèÈ",
        "rR¶®",
        "tTŧŦ",
        "yY←¥",
        "uUùÙ",
        "iIìÌ",
        "oOòÒ",
        "pPþÞ",
        "ġĠ[{",
        "ħĦ]}",
    },
    // the middle row, from the key at A
    .home = .{
        "aAàÀ",
        "sSßẞ",
        "dDðÐ",
        "fFđª",
        "gGŋŊ",
        "hHħĦ",
        "jJ",
        "kKĸ&",
        "lLłŁ",
        ";:\u{301}\u{30B}",
        "'@\u{302}\u{30C}",
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
        ",<•×",
        ".>·÷",
        "/?\u{323}\u{307}",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "#~\u{300}\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "żŻ\\|",
});

comptime {
    europe.publish(keymap);
}
