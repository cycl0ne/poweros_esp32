// SPDX-License-Identifier: MPL-2.0
//! SetSystemFonts: the fonts screens, windows and consoles use from now on.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _font = @import("_font.zig");

/// The fonts screens, windows and consoles use from now on.
///
/// SYNOPSIS:
/// ```zig
/// fn SetSystemFonts(ib: *IntuitionBase, screen_font: ?*graphics.TextFont, default_font: ?*graphics.TextFont, fixed_font: ?*graphics.TextFont) bool
/// ```
///
/// SINCE: 0.19. LVO -456.
///
/// INPUTS:
/// - `screen_font` - title bars and menus of screens opened from now on.
/// - `default_font` - text in windows and gadgets that name none.
/// - `fixed_font` - consoles; must be fixed-width.
///
/// Each may be null: pospaz from the ROM again.
///
/// RESULT:
/// True when set. False when `fixed_font` is proportional, or a font
/// could not be opened, and then nothing changes.
///
/// BEHAVIOR:
/// Intuition opens each font itself and keeps it open until the next
/// call, so the caller closes its own opens as soon as this returns.
/// Screens and windows already open keep the fonts they were made with:
/// their layout was worked out for those. The next screen, window and
/// console takes the new ones - and the default public screen when it is
/// next opened.
///
/// Every window that asked for `IDCMP_NEWPREFS` is told, since the fonts
/// are a setting like any other and a window that draws in one may want
/// to draw again. A screen already open keeps the font it opened with.
///
/// CONTEXT:
/// - Waits: yes, while another task reads the fonts.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The fonts stay the caller's to close; intuition holds opens of its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenSystemFont`, `SetPrefs`, `diskfont.library/OpenDiskFont`
///
/// EXAMPLES:
/// ```zig
/// const font = dfb.OpenDiskFont(&.{ .name = "spleen.font", .y_size = 10, .flags = sdk.graphics.FPF_POINTS });
/// _ = ib.SetSystemFonts(font, font, font);
/// if (font) |f| gb.CloseFont(f);
/// ```
pub fn SetSystemFonts(ib: *IntuitionBase, screen_font: ?*graphics.TextFont, default_font: ?*graphics.TextFont, fixed_font: ?*graphics.TextFont) bool {
    const gb = ib.graphics_base;
    const sys = ib.sys_base;
    if (fixed_font) |fixed| {
        if (fixed.image.flags & graphics.FPF_PROPORTIONAL != 0) return false;
    }
    const given = [3]?*graphics.TextFont{ default_font, screen_font, fixed_font };
    var held: [3]?*graphics.TextFont = @splat(null);
    for (given, &held) |font, *hold| {
        const f = font orelse continue;
        hold.* = _font.reopen(ib, f) orelse {
            for (held) |taken| if (taken) |t| gb.CloseFont(t);
            return false;
        };
    }
    sys.ObtainSemaphore(&ib.system_font_lock);
    const old = ib.system_fonts;
    ib.system_fonts = held;
    sys.ReleaseSemaphore(&ib.system_font_lock);
    for (old) |font| if (font) |f| gb.CloseFont(f);
    // The fonts are a setting like any other: a window that draws in one
    // hears that it changed and can draw again.
    @import("../input/_input.zig").tellAll(ib, sdk.intuition.windows.IDCMP_NEWPREFS);
    return true;
}
