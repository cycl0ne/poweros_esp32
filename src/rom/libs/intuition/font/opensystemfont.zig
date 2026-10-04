// SPDX-License-Identifier: MPL-2.0
//! OpenSystemFont: one of the system's fonts, opened.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _font = @import("_font.zig");

/// One of the system's fonts, opened.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenSystemFont(ib: *IntuitionBase, which: u32) ?*graphics.TextFont
/// ```
///
/// SINCE: 0.19. LVO -460.
///
/// INPUTS:
/// - `which` - `SYSFONT_SCREEN`, `SYSFONT_DEFAULT` or `SYSFONT_FIXED`;
///   anything else is `SYSFONT_DEFAULT`.
///
/// RESULT:
/// The font, open, or null only when not even the ROM's can be opened.
///
/// BEHAVIOR:
/// The font `SetSystemFonts` last set for `which`, or pospaz from the ROM
/// at the height intuition starts with when none was set - or when the one
/// set cannot be opened again. What screens, windows and consoles are
/// opened with when they name no font; a program laying out text to match
/// them asks for the same.
///
/// CONTEXT:
/// - Waits: yes, while the fonts are being changed.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds it open: `CloseFont` it. A later `SetSystemFonts`
/// does not take it away.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetSystemFonts`, `SA_SysFont`, `WA_SysFont`
///
/// EXAMPLES:
/// ```zig
/// const font = ib.OpenSystemFont(sdk.intuition.screens.SYSFONT_FIXED) orelse return;
/// defer gb.CloseFont(font);
/// ```
pub fn OpenSystemFont(ib: *IntuitionBase, which: u32) ?*graphics.TextFont {
    const sys = ib.sys_base;
    const slot: usize = if (which < ib.system_fonts.len) which else intuition.screens.SYSFONT_DEFAULT;
    sys.ObtainSemaphoreShared(&ib.system_font_lock);
    const set = ib.system_fonts[slot];
    const opened = if (set) |font| _font.reopen(ib, font) else null;
    sys.ReleaseSemaphore(&ib.system_font_lock);
    return opened orelse _font.romFont(ib);
}
