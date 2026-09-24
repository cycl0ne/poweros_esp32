// SPDX-License-Identifier: MPL-2.0
//! AskSoftStyle: which styles can still be asked for.

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

/// Which styles can still be asked for.
///
/// SYNOPSIS:
/// ```zig
/// fn AskSoftStyle(_: *GraphicsBase, rp: *const RastPort) u32
/// ```
///
/// SINCE: 0.15. LVO -188.
///
/// INPUTS:
/// - `rp` - the RastPort, whose font is asked about.
///
/// RESULT:
/// The styles the RastPort's font was **not** already drawn with, so a
/// caller can offer only what will make a difference. 0 with no font.
///
/// BEHAVIOR:
/// A style the font was already drawn with cannot be applied again: a
/// font drawn extended would be widened twice.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It reads the caller's RastPort, which an interrupt does
///   not share.
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
/// `SetSoftStyle`, `FontExtent`
///
/// EXAMPLES:
/// ```zig
/// const can = gb.AskSoftStyle(rp);
/// ```
pub fn AskSoftStyle(_: *GraphicsBase, rp: *const RastPort) u32 {
    const font = rp.font orelse return 0;
    return softStyles(font);
}
