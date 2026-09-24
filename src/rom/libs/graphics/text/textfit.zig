// SPDX-License-Identifier: MPL-2.0
//! TextFit: how many characters fit in the room given.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _text = @import("_text.zig");
const RastPort = rastport.RastPort;
const advance = _text.advance;

/// How many characters fit in the room given.
///
/// SYNOPSIS:
/// ```zig
/// fn TextFit(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32, out: *graphics.TextExtent, constraining: ?*const graphics.TextExtent, direction: i32, width: i32, height: i32) u32
/// ```
///
/// SINCE: 0.14. LVO -172.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font and text style decide the answer.
/// - `string` - the characters; with `TEXT_BACKWARD`, the **last** of them.
/// - `count` - how many there are.
/// - `out` - the room the characters that fit take, as `TextExtent` gives
///   it.
/// - `constraining` - a box to fit inside, or null.
/// - `direction` - `TEXT_FORWARD`, or `TEXT_BACKWARD`, which is how a line
///   is trimmed from its end.
/// - `width` - above 0, overrides the box's width.
/// - `height` - above 0, overrides the box's height.
///
/// RESULT:
/// How many characters fit, and `out` filled for those. 0 when the font is
/// taller than the room - a character cut off across the middle is not a
/// character that fits - and 0 with no font set, where the error is
/// `GERR_NO_FONT`.
///
/// BEHAVIOR:
/// Every character of the fonts in this ROM is the same width, so this is
/// a division today. It takes the direction anyway, and is a call rather
/// than a sum the caller does, because a font that is not fixed-width will
/// need to walk the string and callers should not change when one arrives.
///
/// This is what a label does when its box is too small for it: ask how
/// much fits, draw that, and put an ellipsis after it.
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
/// `TextExtent`, `Text`
///
/// EXAMPLES:
/// ```zig
/// var room: graphics.TextExtent = .{};
/// const fits = gb.TextFit(rp, label.ptr, label.len, &room, null, graphics.TEXT_FORWARD, box_width, 0);
/// gb.Text(rp, label.ptr, fits);
/// ```
pub fn TextFit(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32, out: *graphics.TextExtent, constraining: ?*const graphics.TextExtent, direction: i32, width: i32, height: i32) u32 {
    const graphics_lib = gb.iface();
    // The direction decides which characters fit, not how many, while
    // every character is the same width. It is taken now so that a font
    // that is not fixed-width can walk the string without the call
    // changing under its callers.
    _ = direction;
    rp.last_error = graphics.GERR_OK;
    out.* = .{};
    const font = rp.font orelse {
        rp.last_error = graphics.GERR_NO_FONT;
        return 0;
    };

    // A box to fit inside, then either measurement given outright. Given
    // outright wins, which is what lets a caller reuse a box and narrow it.
    var room_w: i32 = -1;
    var room_h: i32 = -1;
    if (constraining) |box| {
        room_w = box.width;
        room_h = box.height;
    }
    if (width > 0) room_w = width;
    if (height > 0) room_h = height;

    // Too short for one line of it: nothing fits, not even part of a
    // character, because a character cut off across the middle is not a
    // character that fits.
    if (room_h >= 0 and font.height > room_h) return 0;

    const step = advance(font, rp.text_style);
    var fits: u32 = count;
    if (room_w >= 0 and step > 0) {
        const room: u32 = @intCast(@divTrunc(room_w, step));
        if (room < fits) fits = room;
    }
    graphics_lib.TextExtent(@ptrCast(rp), string, fits, out);
    return fits;
}
