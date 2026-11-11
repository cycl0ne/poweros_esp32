// SPDX-License-Identifier: MPL-2.0
//! TextFit: how much of a text fits in the room given.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _text = @import("_text.zig");
const RastPort = rastport.RastPort;
const utf8 = sdk.utility.utf8;

/// How much of a text fits in the room given.
///
/// SYNOPSIS:
/// ```zig
/// fn TextFit(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32, out: *graphics.TextExtent, constraining: ?*const graphics.TextExtent, direction: i32, width: i32, height: i32) u32
/// ```
///
/// SINCE: 0.14, UTF-8 since 0.38, fallback fonts since 0.40, glyphs made
/// when wanted since 0.41. LVO -172.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font and text style decide the answer.
/// - `string` - the text, UTF-8, as `Text` takes it; with
///   `TEXT_BACKWARD`, its **last** byte.
/// - `count` - its length in bytes.
/// - `out` - the room the part that fits takes, as `TextExtent` gives
///   it.
/// - `constraining` - a box to fit inside, or null.
/// - `direction` - `TEXT_FORWARD`, or `TEXT_BACKWARD`, which is how a line
///   is trimmed from its end.
/// - `width` - above 0, overrides the box's width.
/// - `height` - above 0, overrides the box's height.
///
/// RESULT:
/// How many bytes fit - whole characters, never part of one - and `out`
/// filled for those. 0 when the font is
/// taller than the room - a character cut off across the middle is not a
/// character that fits - and 0 with no font set, where the error is
/// `GERR_NO_FONT`.
///
/// BEHAVIOR:
/// The text is walked a character at a time, from its start forward or
/// from its end back (a byte that is no UTF-8 a character of its own, as
/// `Text` draws it), and a character fits while everything up to it -
/// ink and paper, as `TextExtent` measures it - is no wider than the
/// room. Backward, what fits is the tail of the string, and `out` is the
/// extent of that tail. A character drawn from a fallback font takes the
/// room of that glyph. A glyph the font's hook makes (`TextFont.render`)
/// is made here when this is the first call to want it, as `Text` makes
/// it.
///
/// This is what a label does when its box is too small for it: ask how
/// much fits, draw that, and put an ellipsis after it.
///
/// CONTEXT:
/// - Waits: only for a font that makes glyphs, while another task makes
///   one of the same font.
/// - Interrupts: no. It reads the caller's RastPort, which an interrupt does
///   not share.
/// - Locks: none needed; no spinlock may be held with a font that makes
///   glyphs.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing the caller has to free. A glyph made for the measuring is
/// the library's, kept with the font.
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
    if (room_h >= 0 and font.image.height > room_h) return 0;

    // How the glyphs of the font the last character was drawn from are
    // put on the line: the RastPort's font until a fallback has one.
    var look = _text.lookOf(font, font, rp.text_style);
    const backward = direction < 0;
    if (count == 0) {
        graphics_lib.TextExtent(@ptrCast(rp), string, 0, out);
        return 0;
    }
    // Backward, the string points at the last byte and the walk goes down
    // from the end.
    const bytes = if (backward) (string - (count - 1))[0..count] else string[0..count];
    var room = _text.Measure{};
    var fits: u32 = 0;
    while (fits < count) {
        const char = if (backward) utf8.readLast(bytes[0 .. count - fits]) else utf8.read(bytes[fits..]);
        const found = _text.glyphOf(gb, font, char.char);
        if (found.font != look.font) look = _text.lookOf(font, found.font, rp.text_style);
        const next = if (backward)
            _text.growBack(room, found.glyph, look.extra, look.smear, look.lean)
        else
            _text.grow(room, found.glyph, look.extra, look.smear, look.lean);
        if (room_w >= 0 and next.max_x - next.min_x > room_w) break;
        room = next;
        fits += @intCast(char.length);
    }
    const first = if (backward) bytes.ptr + (count - fits) else string;
    graphics_lib.TextExtent(@ptrCast(rp), first, fits, out);
    return fits;
}
