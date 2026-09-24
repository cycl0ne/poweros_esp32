// SPDX-License-Identifier: MPL-2.0
//! SetSoftStyle: sets the styles, keeping only what will make a difference.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _text = @import("_text.zig");
const RastPort = rastport.RastPort;
const softStyles = _text.softStyles;

/// Sets the styles, keeping only what will make a difference.
///
/// SYNOPSIS:
/// ```zig
/// fn SetSoftStyle(_: *GraphicsBase, rp: *RastPort, style: u32, enable: u32) u32
/// ```
///
/// SINCE: 0.15. LVO -192.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `style` - what is wanted.
/// - `enable` - which of those the caller will allow, so a menu can offer
///   bold and italic and refuse the rest without knowing the font.
///
/// RESULT:
/// What the style became: `style & enable`, less anything the font already
/// has. `RPTAG_TextStyle` sets it without the masking, for a caller that
/// has already asked.
///
/// BEHAVIOR:
/// The style is drawn, not stored in the font: bold, italic, underlined
/// and extended are applied as each character is drawn.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It changes the caller's RastPort, which an interrupt
///   does not share.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AskSoftStyle`, `Text`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.SetSoftStyle(rp, graphics.FSF_BOLD, gb.AskSoftStyle(rp));
/// ```
pub fn SetSoftStyle(_: *GraphicsBase, rp: *RastPort, style: u32, enable: u32) u32 {
    const font = rp.font orelse return 0;
    rp.text_style = @truncate(style & enable & softStyles(font));
    return rp.text_style;
}
