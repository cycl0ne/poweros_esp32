// SPDX-License-Identifier: MIT
//! Descriptions: the words ParseIX knows, and how it reads them.
//!
//! A description is words separated by spaces, tabs, commas or new
//! lines, in this order, each part but the last optional:
//!
//!   [class] {[-]qualifier} [[-]upstroke] [key or button]
//!
//! A class names the kind of event (RAWKEY when none is given). A
//! qualifier is one that must be held, or with `-` in front one that
//! does not matter; `shift`, `caps` and `alt` stand for either of a pair.
//! `upstroke` matches the key going up instead of down, `-upstroke`
//! either. Last comes the key - a name below, or the one character it
//! types - or for RAWMOUSE the button. Case does not matter.

const sdk = @import("sdk");
const ie = sdk.devices.inputevent;
const kbd = sdk.devices.keyboard;
const cx = sdk.commodities;

pub const Keyword = struct { word: []const u8, id: u32 };

pub const classes = [_]Keyword{
    .{ .word = "ACTIVEWINDOW", .id = ie.IECLASS_ACTIVEWINDOW },
    .{ .word = "DISKINSERTED", .id = ie.IECLASS_DISKINSERTED },
    .{ .word = "DISKREMOVED", .id = ie.IECLASS_DISKREMOVED },
    .{ .word = "EVENT", .id = ie.IECLASS_EVENT },
    .{ .word = "INACTIVEWINDOW", .id = ie.IECLASS_INACTIVEWINDOW },
    .{ .word = "NEWPOINTERPOS", .id = ie.IECLASS_NEWPOINTERPOS },
    .{ .word = "NEWPREFS", .id = ie.IECLASS_NEWPREFS },
    .{ .word = "RAWKEY", .id = ie.IECLASS_RAWKEY },
    .{ .word = "RAWMOUSE", .id = ie.IECLASS_RAWMOUSE },
    .{ .word = "TIMER", .id = ie.IECLASS_TIMER },
    .{ .word = "TOUCH", .id = ie.IECLASS_TOUCH },
    .{ .word = "USB", .id = ie.IECLASS_USB },
};

pub const qualifiers = [_]Keyword{
    .{ .word = "CAPSLOCK", .id = ie.IEQUALIFIER_CAPSLOCK },
    .{ .word = "CAPS_LOCK", .id = ie.IEQUALIFIER_CAPSLOCK },
    .{ .word = "CONTROL", .id = ie.IEQUALIFIER_CONTROL },
    .{ .word = "CTRL", .id = ie.IEQUALIFIER_CONTROL },
    .{ .word = "LALT", .id = ie.IEQUALIFIER_LALT },
    .{ .word = "LBUTTON", .id = ie.IEQUALIFIER_LEFTBUTTON },
    .{ .word = "LCOMMAND", .id = ie.IEQUALIFIER_LCOMMAND },
    .{ .word = "LEFTBUTTON", .id = ie.IEQUALIFIER_LEFTBUTTON },
    .{ .word = "LEFT_ALT", .id = ie.IEQUALIFIER_LALT },
    .{ .word = "LEFT_BUTTON", .id = ie.IEQUALIFIER_LEFTBUTTON },
    .{ .word = "LEFT_COMMAND", .id = ie.IEQUALIFIER_LCOMMAND },
    .{ .word = "LEFT_SHIFT", .id = ie.IEQUALIFIER_LSHIFT },
    .{ .word = "LSHIFT", .id = ie.IEQUALIFIER_LSHIFT },
    .{ .word = "MBUTTON", .id = ie.IEQUALIFIER_MIDBUTTON },
    .{ .word = "MIDBUTTON", .id = ie.IEQUALIFIER_MIDBUTTON },
    .{ .word = "MIDDLEBUTTON", .id = ie.IEQUALIFIER_MIDBUTTON },
    .{ .word = "MIDDLE_BUTTON", .id = ie.IEQUALIFIER_MIDBUTTON },
    .{ .word = "NUMERICPAD", .id = ie.IEQUALIFIER_NUMERICPAD },
    .{ .word = "NUMERIC_PAD", .id = ie.IEQUALIFIER_NUMERICPAD },
    .{ .word = "NUMPAD", .id = ie.IEQUALIFIER_NUMERICPAD },
    .{ .word = "NUM_PAD", .id = ie.IEQUALIFIER_NUMERICPAD },
    .{ .word = "RALT", .id = ie.IEQUALIFIER_RALT },
    .{ .word = "RBUTTON", .id = ie.IEQUALIFIER_RBUTTON },
    .{ .word = "RCOMMAND", .id = ie.IEQUALIFIER_RCOMMAND },
    .{ .word = "RELATIVEMOUSE", .id = ie.IEQUALIFIER_RELATIVEMOUSE },
    .{ .word = "REPEAT", .id = ie.IEQUALIFIER_REPEAT },
    .{ .word = "RIGHTBUTTON", .id = ie.IEQUALIFIER_RBUTTON },
    .{ .word = "RIGHT_ALT", .id = ie.IEQUALIFIER_RALT },
    .{ .word = "RIGHT_BUTTON", .id = ie.IEQUALIFIER_RBUTTON },
    .{ .word = "RIGHT_COMMAND", .id = ie.IEQUALIFIER_RCOMMAND },
    .{ .word = "RIGHT_SHIFT", .id = ie.IEQUALIFIER_RSHIFT },
    .{ .word = "RSHIFT", .id = ie.IEQUALIFIER_RSHIFT },
};

/// Words for either of a pair: the synonym, and the qualifiers it stands
/// for.
pub const Synonym = struct { word: []const u8, id: u32, mask: u32 };
pub const synonyms = [_]Synonym{
    .{ .word = "ALT", .id = cx.IXSYM_ALT, .mask = cx.IXSYM_ALTMASK },
    .{ .word = "CAPS", .id = cx.IXSYM_CAPS, .mask = cx.IXSYM_CAPSMASK },
    .{ .word = "SHIFT", .id = cx.IXSYM_SHIFT, .mask = cx.IXSYM_SHIFTMASK },
};

pub const upstroke = "UPSTROKE";

/// The keys that type no character, or one a name says better.
pub const keys = [_]Keyword{
    .{ .word = "BACKSPACE", .id = kbd.RAWKEY_BACKSPACE },
    .{ .word = "BREAK", .id = 0x6E },
    .{ .word = "COMMA", .id = 0x38 },
    .{ .word = "CURSOR_DOWN", .id = kbd.RAWKEY_DOWN },
    .{ .word = "CURSOR_LEFT", .id = kbd.RAWKEY_LEFT },
    .{ .word = "CURSOR_RIGHT", .id = kbd.RAWKEY_RIGHT },
    .{ .word = "CURSOR_UP", .id = kbd.RAWKEY_UP },
    .{ .word = "DEL", .id = kbd.RAWKEY_DEL },
    .{ .word = "DELETE", .id = kbd.RAWKEY_DEL },
    .{ .word = "DOWN", .id = kbd.RAWKEY_DOWN },
    .{ .word = "END", .id = kbd.RAWKEY_END },
    .{ .word = "ENTER", .id = kbd.RAWKEY_KP_ENTER },
    .{ .word = "ESC", .id = kbd.RAWKEY_ESC },
    .{ .word = "ESCAPE", .id = kbd.RAWKEY_ESC },
    .{ .word = "F1", .id = kbd.RAWKEY_F1 },
    .{ .word = "F2", .id = kbd.RAWKEY_F1 + 1 },
    .{ .word = "F3", .id = kbd.RAWKEY_F1 + 2 },
    .{ .word = "F4", .id = kbd.RAWKEY_F1 + 3 },
    .{ .word = "F5", .id = kbd.RAWKEY_F1 + 4 },
    .{ .word = "F6", .id = kbd.RAWKEY_F1 + 5 },
    .{ .word = "F7", .id = kbd.RAWKEY_F1 + 6 },
    .{ .word = "F8", .id = kbd.RAWKEY_F1 + 7 },
    .{ .word = "F9", .id = kbd.RAWKEY_F1 + 8 },
    .{ .word = "F10", .id = kbd.RAWKEY_F10 },
    .{ .word = "F11", .id = kbd.RAWKEY_F11 },
    .{ .word = "F12", .id = kbd.RAWKEY_F12 },
    .{ .word = "HELP", .id = kbd.RAWKEY_HELP },
    .{ .word = "HOME", .id = kbd.RAWKEY_HOME },
    .{ .word = "INSERT", .id = kbd.RAWKEY_INSERT },
    .{ .word = "LEFT", .id = kbd.RAWKEY_LEFT },
    .{ .word = "PAGE_DOWN", .id = kbd.RAWKEY_PAGEDOWN },
    .{ .word = "PAGE_UP", .id = kbd.RAWKEY_PAGEUP },
    .{ .word = "PAUSE", .id = 0x6E },
    .{ .word = "RETURN", .id = kbd.RAWKEY_RETURN },
    .{ .word = "RIGHT", .id = kbd.RAWKEY_RIGHT },
    .{ .word = "SPACE", .id = kbd.RAWKEY_SPACE },
    .{ .word = "SPACEBAR", .id = kbd.RAWKEY_SPACE },
    .{ .word = "TAB", .id = kbd.RAWKEY_TAB },
    .{ .word = "UP", .id = kbd.RAWKEY_UP },
};

/// RAWMOUSE's buttons.
pub const buttons = [_]Keyword{
    .{ .word = "MOUSE_LEFTPRESS", .id = ie.IECODE_LBUTTON },
    .{ .word = "MOUSE_MIDDLEPRESS", .id = ie.IECODE_MBUTTON },
    .{ .word = "MOUSE_RIGHTPRESS", .id = ie.IECODE_RBUTTON },
    .{ .word = "MOUSE_WHEEL", .id = ie.IECODE_WHEEL },
};

/// The keypad's keys, for a description with a keypad qualifier: the
/// character on each.
pub const keypad = [_]Keyword{
    .{ .word = "(", .id = 0x5A },
    .{ .word = ")", .id = 0x5B },
    .{ .word = "*", .id = 0x5D },
    .{ .word = "+", .id = 0x5E },
    .{ .word = "-", .id = kbd.RAWKEY_KP_MINUS },
    .{ .word = ".", .id = 0x3C },
    .{ .word = "/", .id = 0x5C },
    .{ .word = "0", .id = 0x0F },
    .{ .word = "1", .id = 0x1D },
    .{ .word = "2", .id = 0x1E },
    .{ .word = "3", .id = 0x1F },
    .{ .word = "4", .id = 0x2D },
    .{ .word = "5", .id = 0x2E },
    .{ .word = "6", .id = 0x2F },
    .{ .word = "7", .id = 0x3D },
    .{ .word = "8", .id = 0x3E },
    .{ .word = "9", .id = 0x3F },
};

/// The id of `token` in `table`, case not mattering, or null.
pub fn lookup(table: []const Keyword, token: []const u8) ?u32 {
    for (table) |k| {
        if (same(k.word, token)) return k.id;
    }
    return null;
}

/// Whether two words are the same, case not mattering.
pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (upper(x) != upper(y)) return false;
    }
    return true;
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn separator(c: u8) bool {
    return c == ' ' or c == '\t' or c == ',' or c == '\n';
}

/// A description's words, one at a time.
pub const Words = struct {
    text: [*:0]const u8,
    at: usize = 0,

    /// The next word, or null at the end.
    pub fn next(words: *Words) ?[]const u8 {
        while (separator(words.text[words.at])) words.at += 1;
        const start = words.at;
        while (words.text[words.at] != 0 and !separator(words.text[words.at])) words.at += 1;
        if (words.at == start) return null;
        return words.text[start..words.at];
    }
};
