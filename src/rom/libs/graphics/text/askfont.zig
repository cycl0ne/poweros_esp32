// SPDX-License-Identifier: MPL-2.0
//! AskFont: the RastPort's font, described.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");
const RastPort = _text.RastPort;

/// The RastPort's font, described.
///
/// SYNOPSIS:
/// ```zig
/// fn AskFont(_: *GraphicsBase, rp: *RastPort, text_attr: *graphics.TextAttr) void
/// ```
///
/// SINCE: 0.19. LVO -284.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `text_attr` - where the answer goes: the font's name, its height,
///   the styles it was drawn with, and its flags - how it was made and
///   where it came from. No tags.
///
/// RESULT:
/// Nothing; the answer is in `text_attr`. With no font set, the name is
/// "", the rest 0, and the error is `GERR_NO_FONT`.
///
/// BEHAVIOR:
/// What comes back is what `OpenFont` needs to open the same font again,
/// so a font can be handed on as a description - to a window opened
/// later, or another RastPort - rather than as a pointer someone must
/// keep open. The name points into the font; copy it if the font may
/// close first.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It reads the caller's RastPort, which an interrupt
///   does not share.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The name is the font's, for as long as the font
/// is open.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenFont`, `WeighTAMatch`, `RPTAG_Font`
///
/// EXAMPLES:
/// ```zig
/// var same: sdk.graphics.TextAttr = undefined;
/// gb.AskFont(rp, &same);
/// const again = gb.OpenFont(&same);
/// ```
pub fn AskFont(_: *GraphicsBase, rp: *RastPort, text_attr: *graphics.TextAttr) void {
    rp.last_error = graphics.GERR_OK;
    const font = rp.font orelse {
        text_attr.* = .{ .name = "", .y_size = 0 };
        rp.last_error = graphics.GERR_NO_FONT;
        return;
    };
    text_attr.* = _text.attrOf(font);
}
