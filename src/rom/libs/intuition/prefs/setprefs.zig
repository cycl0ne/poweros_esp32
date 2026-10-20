// SPDX-License-Identifier: MPL-2.0
//! SetPrefs: the system's settings changed, and every window told.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const wn = intuition.windows;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _prefs = @import("_prefs.zig");
const _font = @import("../font/_font.zig");
const _input = @import("../input/_input.zig");
const _window = @import("../window/_window.zig");
const _screen = @import("../screen/_screen.zig");
const _misc = @import("../misc/_misc.zig");
const Window = _window.Window;
const Screen = _screen.Screen;
const Object = intuition.Object;
const ic = intuition.imageclass;

/// The system's settings changed.
///
/// SYNOPSIS:
/// ```zig
/// fn SetPrefs(ib: *IntuitionBase, tags: ?[*]const TagItem) bool
/// ```
///
/// SINCE: 1.0. LVO -472.
///
/// INPUTS:
/// - `ib` - intuition.library's base.
/// - `tags` - the settings to change, each an `IPREFS_` tag with its
///   value as the data. Null changes nothing.
///
/// RESULT:
/// True when every setting given was taken; false when one was not - a
/// value that means nothing, a fixed font that is proportional, no memory
/// for a style or a sound - and then that one keeps its value and the
/// rest are taken all the same.
///
/// BEHAVIOR:
/// Each setting takes effect at once and a setting left out keeps its
/// value:
///
/// - `IPREFS_DoubleClick`, milliseconds: the next press is measured by
///   it. 0 is refused.
/// - `IPREFS_ScreenFontHeight`, rows: the next screen opened without a
///   font of its own takes it. 0 is refused.
/// - `IPREFS_Keyboard`: when the keyboard on the screen comes up. A
///   value past `KEYBOARD_NEVER` is refused.
/// - `IPREFS_OffScreen`: whether a window may be moved partly past its
///   screen's edges, 0 or 1; anything else is refused. It holds from the
///   next move or size on: a window already past an edge stays there until
///   it is moved or sized.
/// - `IPREFS_WideGadgets`: whether the gadgets in the title bars are wide,
///   0 or 1; anything else is refused. Every screen's depth gadget and
///   every window's close, depth and zoom gadgets take the width at once,
///   and their bars are drawn again.
/// - `IPREFS_ScreenFont`, `IPREFS_DefaultFont`, `IPREFS_FixedFont`: the
///   fonts screens, windows and consoles opened from now on use, as
///   `SetSystemFonts` sets them; one not given keeps the font it has.
/// - `IPREFS_Pens`: the system's pens, as `SetScreenPens` with no screen
///   sets them - every screen without pens of its own is painted again.
/// - `IPREFS_Style`: the system's style, as `SetStyle` with no screen
///   sets it - every window it reaches is drawn again.
/// - `IPREFS_BeepFlash`: whether `DisplayBeep` flashes the display, 0 or
///   1; anything else is refused.
/// - `IPREFS_BeepSound`: the sound `DisplayBeep` plays, copied, or none
///   for null. One with no frames, a rate past `AUDIO_MAX_RATE`, other
///   than one or two channels or a volume past `AUDIO_VOLUME_MAX` is
///   refused. A beep still sounding is taken back first.
///
/// Every window that asked for `IDCMP_NEWPREFS` is told, whichever
/// screen it is on: a window that draws something the settings decide
/// reads them again and draws it anew.
///
/// CONTEXT:
/// - Waits: yes - for the fonts, the screen list and the layers it draws
///   in.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list and all it points to stay the caller's: intuition opens fonts
/// of its own and copies the pens, the style and the beep's sound.
///
/// NOTES:
/// - What `C:SetPrefs` calls at boot, from the files in `ENV:Sys`.
///
/// BUGS:
/// - A window whose title bar only just held its close, depth and zoom
///   gadgets when it opened has them overlap once they are made wide; a
///   window that opens too narrow for them goes without the zoom gadget.
///
/// SEE ALSO:
/// `GetPrefs`, `GetDefPrefs`, `SetStyle`, `SetScreenPens`,
/// `SetSystemFonts`
///
/// EXAMPLES:
/// ```zig
/// // A quicker double-click, and no keyboard on the screen.
/// _ = ib.SetPrefs(&[_]TagItem{
///     .{ .tag = intuition.IPREFS_DoubleClick, .data = 400 },
///     .{ .tag = intuition.IPREFS_Keyboard, .data = intuition.KEYBOARD_NEVER },
///     .{},
/// });
/// ```
pub fn SetPrefs(ib: *IntuitionBase, tags: ?[*]const TagItem) bool {
    const it = ib.iface();
    var taken = true;
    var told = false;
    // The fonts are set together: one given, the others as they are.
    var fonts_given = false;
    var fonts: [3]?*graphics.TextFont = @splat(null);
    var given: [3]bool = @splat(false);

    var walk: ?[*]const TagItem = tags;
    while (ib.utility_base.NextTagItem(&walk)) |item| {
        switch (item.tag) {
            intuition.IPREFS_DoubleClick => {
                const ms: u32 = @truncate(item.data);
                if (ms == 0) {
                    taken = false;
                    continue;
                }
                ib.double_seconds = ms / 1000;
                ib.double_micros = (ms % 1000) * 1000;
                told = true;
            },
            intuition.IPREFS_ScreenFontHeight => {
                if (item.data == 0) {
                    taken = false;
                    continue;
                }
                ib.font_height = @truncate(item.data);
                told = true;
            },
            intuition.IPREFS_Keyboard => {
                if (item.data > intuition.KEYBOARD_NEVER) {
                    taken = false;
                    continue;
                }
                ib.keyboard_mode = @truncate(item.data);
                told = true;
            },
            intuition.IPREFS_OffScreen => {
                if (item.data > 1) {
                    taken = false;
                    continue;
                }
                ib.off_screen = @truncate(item.data);
                told = true;
            },
            intuition.IPREFS_WideGadgets => {
                if (item.data > 1) {
                    taken = false;
                    continue;
                }
                if (item.data != ib.wide_gadgets) refit(ib, @truncate(item.data));
                told = true;
            },
            intuition.IPREFS_ScreenFont, intuition.IPREFS_DefaultFont, intuition.IPREFS_FixedFont => {
                const at = _prefs.whichFont(item.tag);
                fonts[at] = @ptrFromInt(item.data);
                given[at] = true;
                fonts_given = true;
            },
            intuition.IPREFS_BeepFlash => {
                if (item.data > 1) {
                    taken = false;
                    continue;
                }
                ib.beep_flash = @truncate(item.data);
            },
            intuition.IPREFS_BeepSound => {
                if (!_misc.setBeepSound(ib, @ptrFromInt(item.data))) taken = false;
            },
            intuition.IPREFS_Pens => it.SetScreenPens(null, @ptrFromInt(item.data)),
            intuition.IPREFS_Style => {
                if (!it.SetStyle(null, @ptrFromInt(item.data))) taken = false;
            },
            else => {},
        }
    }

    if (fonts_given) {
        // The ones not given, held for the call: opens of this call's own,
        // so that another task setting fonts meanwhile cannot close them
        // under it.
        var kept: [3]?*graphics.TextFont = @splat(null);
        defer for (kept) |font| if (font) |f| ib.graphics_base.CloseFont(f);
        ib.sys_base.ObtainSemaphoreShared(&ib.system_font_lock);
        for (ib.system_fonts, 0..) |font, at| {
            if (given[at]) continue;
            if (font) |f| kept[at] = _font.reopen(ib, f);
        }
        ib.sys_base.ReleaseSemaphore(&ib.system_font_lock);
        for (kept, 0..) |font, at| {
            if (!given[at]) fonts[at] = font;
        }
        const sf = intuition.screens;
        if (!it.SetSystemFonts(fonts[sf.SYSFONT_SCREEN], fonts[sf.SYSFONT_DEFAULT], fonts[sf.SYSFONT_FIXED])) taken = false;
    }
    if (told) _input.tellAll(ib, wn.IDCMP_NEWPREFS);
    return taken;
}

/// The title bars' gadgets made wide (`wide` 1) or narrow (0) on every
/// screen and window, and the bars drawn again: a screen's depth gadget,
/// a window's close, depth and zoom gadgets. The setting changes under
/// the screen list's lock, so nothing draws a bar between the new width
/// and its images. An image draws itself afresh at its new size, so
/// nothing is made or freed.
fn refit(ib: *IntuitionBase, wide: u32) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    ib.wide_gadgets = wide;
    var screens = ib.screen_list.head;
    while (screens) |sn| : (screens = sn.succ) {
        if (sn.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(sn));
        if (s.depth_image) |image| {
            s.depth_width = _screen.depthWidth(s.bar_height, wide != 0);
            setWidth(ib, image, s.depth_width);
            _screen.drawBar(ib, s);
        }
        var windows = s.windows.head;
        while (windows) |n| : (windows = n.succ) {
            if (n.succ == null) break;
            const w: *Window = @ptrCast(@alignCast(n));
            if (w.close_image) |image| setWidth(ib, image, _window.closeWidthOf(w));
            if (w.depth_image) |image| setWidth(ib, image, _window.depthWidthOf(w));
            if (w.zoom_image) |image| setWidth(ib, image, _window.depthWidthOf(w));
            _window.drawBorder(ib, w);
        }
    }
}

fn setWidth(ib: *IntuitionBase, image: *Object, width: i32) void {
    _ = ib.iface().SetAttrsTagList(image, &[_]TagItem{ .{ .tag = ic.IA_Width, .data = @intCast(width) }, .{} });
}
