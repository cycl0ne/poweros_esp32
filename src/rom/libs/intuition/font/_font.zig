// SPDX-License-Identifier: MPL-2.0
//! The system's fonts: which font screens, windows and consoles use when
//! they are given none.
//!
//! There are three (`SYSFONT_*`): the screen font for title bars and
//! menus, the default font for text in windows and gadgets, and the fixed
//! font for consoles, which is always fixed-width. Each is a font held
//! open in the base, or null for pospaz from the ROM at intuition's
//! height (`font_height`), which is also what stands in when a font set
//! cannot be opened again. A program that sets them (C:FontPrefs) opens
//! them first - intuition, in the ROM, cannot reach diskfont.library -
//! and hands them over with `SetSystemFonts`.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// A font's own description, which opens it - or one exactly like it -
/// again.
pub fn attrOf(font: *const graphics.TextFont) graphics.TextAttr {
    return .{
        .name = font.node.name orelse "",
        .y_size = font.image.height,
        .style = font.image.style,
        .flags = font.image.flags | font.flags,
    };
}

/// A font opened once more, for another holder.
pub fn reopen(ib: *IntuitionBase, font: *const graphics.TextFont) ?*graphics.TextFont {
    const attr = attrOf(font);
    return ib.graphics_base.OpenFont(&attr);
}

/// Pospaz from the ROM at intuition's height, opened.
pub fn romFont(ib: *IntuitionBase) ?*graphics.TextFont {
    return ib.graphics_base.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = @intCast(ib.font_height) });
}
