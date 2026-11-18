// SPDX-License-Identifier: MIT
//! The "it" keymap: Italy's layout. A file of `DEVS:Keymaps`,
//! which keymap.library loads when FindKeyMap is asked for it
//! (`SetMap it`); what a key's characters say is in `_europe.zig`.

const europe = @import("_europe.zig");

pub const keymap = europe.Keymap("it", .{
    // the key left of 1, 1 to 0, and the two right of 0
    .numbers = .{
        "\\|¬¦",
        "1!¹¡",
        "2\"²\u{30B}",
        "3£³\u{303}",
        "4$¼⅛",
        "5%½⅜",
        "6&¬⅝",
        "7/{⅞",
        "8([™",
        "9)]±",
        "0=}\u{328}",
        "'?`¿",
        "ì^~\u{302}",
    },
    // the top letter row, from the key at Q
    .top = .{
        "qQ@Ω",
        "wWſ§",
        "eE€¢",
        "rR¶®",
        "tTŧŦ",
        "yY←¥",
        "uU↓↑",
        "iI→ı",
        "oOøØ",
        "pPþÞ",
        "èé[{",
        "+*]}",
    },
    // the middle row, from the key at A
    .home = .{
        "aAæÆ",
        "sSßẞ",
        "dDðÐ",
        "fFđª",
        "gGŋŊ",
        "hHħĦ",
        "jJ",
        "kKĸ&",
        "lLłŁ",
        "òç@\u{327}",
        "à°#\u{30A}",
    },
    // the bottom row, from the key at Z
    .bottom = .{
        "zZ«<",
        "xX»>",
        "cC¢©",
        "vV“‘",
        "bB”’",
        "nNñÑ",
        "mMµº",
        ",;\u{301}×",
        ".:·\u{308}",
        "-_\u{304}÷",
    },
    // the key left of Return on an ISO keyboard, and the US one's backslash key
    .hash = "ù§\u{300}\u{306}",
    // the key right of the left Shift on an ISO keyboard
    .angle = "<>«»",
});

comptime {
    europe.publish(keymap);
}
