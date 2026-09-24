// SPDX-License-Identifier: MPL-2.0
//! GraphicsErrorText: what a GERR_ code means, in words.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _rastport = @import("../rastport/_rastport.zig");
const RastPort = _rastport.RastPort;

/// What a GERR_ code means, in words.
///
/// SYNOPSIS:
/// ```zig
/// fn GraphicsErrorText(_: *GraphicsBase, code: i32) [*:0]const u8
/// ```
///
/// SINCE: 0.7. LVO -196.
///
/// INPUTS:
/// - `code` - a `GERR_` code, as `RPTAG_LastError`, `RPTAG_ErrorPtr` or
///   `BMTAG_ErrorPtr` gave it.
///
/// RESULT:
/// A NUL-terminated string in the ROM, never null. A code this library
/// does not know is "unknown error" rather than nothing, so a caller can
/// print the answer without checking it first.
///
/// BEHAVIOR:
/// The text is the library's rather than the caller's, because the codes
/// grow with the library: a program built against an older SDK still
/// prints something true about a code that arrived after it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It is a lookup in the ROM and touches nothing.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The string is the ROM's and lasts for ever. It is not to be freed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetRPAttrs`, `CreateRastPortTagList`, `AllocBitMapTagList`
///
/// EXAMPLES:
/// ```zig
/// // Why a RastPort could not be had.
/// var why: i32 = 0;
/// const tags = [_]TagItem{
///     .{ .tag = sdk.graphics.RPTAG_ErrorPtr, .data = @intFromPtr(&why) },
///     .{},
/// };
/// const rp = gb.CreateRastPortTagList(&tags) orelse {
///     Printf(dl, "no RastPort: %s\n", .{gb.GraphicsErrorText(why)});
///     return;
/// };
///
/// // And why a drawing call did nothing.
/// gb.BltRastPort(src, rp, &area, 0, 0);
/// var err: i32 = 0;
/// const ask = [_]TagItem{
///     .{ .tag = sdk.graphics.RPTAG_LastError, .data = @intFromPtr(&err) },
///     .{},
/// };
/// gb.GetRPAttrs(rp, &ask);
/// ```
pub fn GraphicsErrorText(_: *GraphicsBase, code: i32) [*:0]const u8 {
    return switch (code) {
        graphics.GERR_OK => "no error",
        graphics.GERR_NO_MEMORY => "out of memory",
        graphics.GERR_NO_DISPLAY => "no display, and no buffer was named",
        graphics.GERR_BAD_FORMAT => "the pixel format cannot be used for this",
        graphics.GERR_BAD_SIZE => "the width or the height is zero",
        graphics.GERR_NO_FONT => "the RastPort has no font set",
        else => "unknown error",
    };
}
