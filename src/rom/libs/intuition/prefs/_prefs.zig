// SPDX-License-Identifier: MPL-2.0
//! The settings intuition keeps for the whole system, read and changed a
//! tag at a time (`IPREFS_`).
//!
//! The library holds each where it uses it - the double-click time is two
//! numbers the input code reads on every press, the screen font height is
//! what a screen opens with, the fonts, the pens and the style each in a
//! place of their own - rather than in a structure. `answer` writes the
//! ones a list asks for, as they are now or as the system starts; the
//! three calls in this folder are each a walk over a list.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const sc = intuition.screens;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("../screen/_screen.zig");

/// How far apart two presses may be and still be one double-click, as
/// the library is born.
pub const default_double_seconds: u32 = 1;
pub const default_double_micros: u32 = 500_000;

/// The double-click time as one number of milliseconds.
pub fn milliseconds(seconds: u32, micros: u32) u32 {
    return seconds * 1000 + micros / 1000;
}

/// Each tag of `tags` that asks for a setting answered: its data is where
/// the value goes. `born` answers what the system starts with instead of
/// what it has now. How many were written; a tag that is not a setting,
/// or one that cannot be read back (`IPREFS_Style`), is passed over.
pub fn answer(ib: *IntuitionBase, tags: ?[*]const TagItem, born: bool) u32 {
    const it = ib.iface();
    var count: u32 = 0;
    var walk: ?[*]const TagItem = tags;
    while (ib.utility_base.NextTagItem(&walk)) |item| {
        if (item.data == 0) continue;
        switch (item.tag) {
            intuition.IPREFS_DoubleClick => @as(*u32, @ptrFromInt(item.data)).* = if (born)
                milliseconds(default_double_seconds, default_double_micros)
            else
                milliseconds(ib.double_seconds, ib.double_micros),
            intuition.IPREFS_ScreenFontHeight => @as(*u32, @ptrFromInt(item.data)).* = if (born) _screen.default_font_height else ib.font_height,
            intuition.IPREFS_Keyboard => @as(*u32, @ptrFromInt(item.data)).* = if (born) intuition.KEYBOARD_AUTO else ib.keyboard_mode,
            intuition.IPREFS_ScreenFont, intuition.IPREFS_DefaultFont, intuition.IPREFS_FixedFont => {
                const into: *?*graphics.TextFont = @ptrFromInt(item.data);
                into.* = if (born)
                    ib.graphics_base.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = _screen.default_font_height })
                else
                    it.OpenSystemFont(whichFont(item.tag));
            },
            intuition.IPREFS_Pens => {
                const into: *[sc.NUMDRIPENS]graphics.Pen = @ptrFromInt(item.data);
                if (born) {
                    into.* = _screen.default_pens;
                } else {
                    ib.sys_base.AcquireLock(&ib.look_lock);
                    into.* = ib.system_pens;
                    ib.sys_base.ReleaseLock(&ib.look_lock);
                }
            },
            else => continue,
        }
        count += 1;
    }
    return count;
}

/// The system font a font tag names (`SYSFONT_`).
pub fn whichFont(tag: utility.Tag) u32 {
    return switch (tag) {
        intuition.IPREFS_ScreenFont => sc.SYSFONT_SCREEN,
        intuition.IPREFS_FixedFont => sc.SYSFONT_FIXED,
        else => sc.SYSFONT_DEFAULT,
    };
}
