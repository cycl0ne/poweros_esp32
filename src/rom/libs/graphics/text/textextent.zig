// SPDX-License-Identifier: MPL-2.0
//! TextExtent: how much room some text would take.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const advance = _text.advance;
const RastPort = _text.RastPort;
const _text = @import("_text.zig");

/// How much room some text would take.
///
/// SYNOPSIS:
/// ```zig
/// fn TextExtent(_: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32, out: *graphics.TextExtent) void
/// ```
///
/// SINCE: 0.14. LVO -168.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font and text style decide the answer.
/// - `string` - the characters.
/// - `count` - how many.
/// - `out` - where the answer goes. All zeroes with no font set, and the
///   error is then `GERR_NO_FONT`.
///
/// RESULT:
/// Nothing; the answer is in `out`.
///
/// BEHAVIOR:
/// `width` is how far `Text` would move the point - the same number
/// `TextLength` answers - and `extent` is where the ink lands **relative
/// to the current point**: above the line by the font's baseline and below
/// it by what is left. So a caller that wants to clear behind a line of
/// text moves the extent to where the text will go and fills that.
///
/// Half-open like every rectangle here, so the height is `max_y - min_y`
/// and there is no `+ 1` anywhere.
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
/// `TextFit`, `TextLength`, `Text`
///
/// EXAMPLES:
/// ```zig
/// // Clear the ground a line of text is about to go on.
/// var room: sdk.graphics.TextExtent = .{};
/// gb.TextExtent(rp, msg.ptr, msg.len, &room);
/// gb.RectFill(rp, &.{
///     .min_x = x + room.extent.min_x, .min_y = y + room.extent.min_y,
///     .max_x = x + room.extent.max_x, .max_y = y + room.extent.max_y,
/// });
/// gb.Move(rp, x, y);
/// gb.Text(rp, msg.ptr, msg.len);
/// ```
pub fn TextExtent(_: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32, out: *graphics.TextExtent) void {
    _ = string;
    rp.last_error = graphics.GERR_OK;
    const font = rp.font orelse {
        out.* = .{};
        rp.last_error = graphics.GERR_NO_FONT;
        return;
    };
    const width = advance(font, rp.text_style) * @as(i32, @intCast(count));
    const height: i32 = font.height;
    const base: i32 = font.baseline;
    out.* = .{
        .width = width,
        .height = height,
        // Where the ink lands from the point: up by the baseline, down by
        // what is left. Half-open, so the height is a subtraction.
        .extent = .{ .min_x = 0, .min_y = -base, .max_x = width, .max_y = height - base },
    };
}
