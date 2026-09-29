// SPDX-License-Identifier: MIT
//! The pixel-array methods: rows handed to the picture, rows handed back
//! out of it, and the picture made another size.
//!
//! Everything a format's class reads goes through `write`, in whatever
//! shape the file held - numbers into a palette, three bytes of colour,
//! four with coverage, or one of grey - and comes out as pens. Nothing
//! else in the class knows about those shapes, and a new one is a case
//! in `penOf` and another in `putPen`.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const pic = datatypes.pictureclass;
const picture = @import("picture.zig");
const Class = classes.Class;
const Object = classes.Object;
const Data = picture.Data;
const Base = gadgets.Base;

/// One pixel of a caller's row read as a pen. An index no palette
/// covers is black.
fn penOf(own: *const Data, from: [*]const u8, format: u32) graphics.Pen {
    const opaque_alpha: graphics.Pen = 0xFF << 24;
    return switch (format) {
        pic.PBPAFMT_RGB => opaque_alpha |
            @as(graphics.Pen, from[0]) << 16 | @as(graphics.Pen, from[1]) << 8 | from[2],
        pic.PBPAFMT_RGBA => @as(graphics.Pen, from[3]) << 24 |
            @as(graphics.Pen, from[0]) << 16 | @as(graphics.Pen, from[1]) << 8 | from[2],
        pic.PBPAFMT_ARGB => @as(graphics.Pen, from[0]) << 24 |
            @as(graphics.Pen, from[1]) << 16 | @as(graphics.Pen, from[2]) << 8 | from[3],
        pic.PBPAFMT_LUT8 => lookUp(own, from[0]),
        else => opaque_alpha |
            @as(graphics.Pen, from[0]) << 16 | @as(graphics.Pen, from[0]) << 8 | from[0],
    };
}

/// A palette entry as a pen, black when the palette does not reach that
/// far.
fn lookUp(own: *const Data, index: u8) graphics.Pen {
    const colors = own.palette orelse return 0xFF000000;
    if (index >= own.num_colors) return 0xFF000000;
    const color = colors[index];
    return 0xFF << 24 | @as(graphics.Pen, color.red) << 16 |
        @as(graphics.Pen, color.green) << 8 | color.blue;
}

/// A pen written into a caller's row in its shape. A palette is not
/// searched: a picture read back as `PBPAFMT_LUT8` answers the grey of
/// each pixel, since the pens it holds are no longer indices.
fn putPen(into: [*]u8, format: u32, pen: graphics.Pen) void {
    const red: u8 = @truncate(pen >> 16);
    const green: u8 = @truncate(pen >> 8);
    const blue: u8 = @truncate(pen);
    const alpha: u8 = @truncate(pen >> 24);
    switch (format) {
        pic.PBPAFMT_RGB => {
            into[0] = red;
            into[1] = green;
            into[2] = blue;
        },
        pic.PBPAFMT_RGBA => {
            into[0] = red;
            into[1] = green;
            into[2] = blue;
            into[3] = alpha;
        },
        pic.PBPAFMT_ARGB => {
            into[0] = alpha;
            into[1] = red;
            into[2] = green;
            into[3] = blue;
        },
        // Rec. 601's weights, in sixteenths of a sixteenth, so that
        // white comes back as 0xFF.
        else => into[0] = @truncate((@as(u32, red) * 77 + @as(u32, green) * 151 + @as(u32, blue) * 28) >> 8),
    }
}

/// The part of `msg`'s rectangle that is inside the picture. False when
/// none of it is.
fn clipped(own: *const Data, msg: *const pic.PdtBlitPixelArray, left: *u32, top: *u32, width: *u32, height: *u32) bool {
    if (own.pens == null) return false;
    const picture_width: u32 = own.bmh.width;
    const picture_height: u32 = own.bmh.height;
    if (msg.left >= picture_width or msg.top >= picture_height) return false;
    left.* = msg.left;
    top.* = msg.top;
    width.* = @min(msg.width, picture_width - msg.left);
    height.* = @min(msg.height, picture_height - msg.top);
    return width.* != 0 and height.* != 0;
}

/// How far apart the caller's rows are: what it said, or one row's worth
/// when it said nothing.
fn pitchOf(msg: *const pic.PdtBlitPixelArray) u32 {
    if (msg.bytes_per_row != 0) return msg.bytes_per_row;
    return msg.width * pic.formatBytes(msg.format);
}

/// `PDTM_WRITEPIXELARRAY`: rows of the caller's given to the picture.
///
/// The rows are converted to pens as they are copied, so the caller's
/// memory is its own again the moment the method answers.
pub fn write(base: *Base, cl: *Class, o: *Object, msg: *pic.PdtBlitPixelArray) usize {
    _ = base;
    const own = classes.instData(Data, cl, o);
    var left: u32 = 0;
    var top: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    if (!clipped(own, msg, &left, &top, &width, &height)) return 0;
    const pens = own.pens.?;
    const pitch = pitchOf(msg);
    const step = pic.formatBytes(msg.format);
    const row_pens = own.bytes_per_row / @sizeOf(graphics.Pen);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const from = msg.pixel_data + y * pitch;
        const into = pens + (top + y) * row_pens + left;
        var x: u32 = 0;
        while (x < width) : (x += 1) into[x] = penOf(own, from + x * step, msg.format);
    }
    return 1;
}

/// `PDTM_READPIXELARRAY`: rows of the picture given back in the caller's
/// shape.
pub fn read(base: *Base, cl: *Class, o: *Object, msg: *pic.PdtBlitPixelArray) usize {
    _ = base;
    const own = classes.instData(Data, cl, o);
    var left: u32 = 0;
    var top: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    if (!clipped(own, msg, &left, &top, &width, &height)) return 0;
    const pens = own.pens.?;
    const pitch = pitchOf(msg);
    const step = pic.formatBytes(msg.format);
    const row_pens = own.bytes_per_row / @sizeOf(graphics.Pen);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const from = pens + (top + y) * row_pens + left;
        const into = msg.pixel_data + y * pitch;
        var x: u32 = 0;
        while (x < width) : (x += 1) putPen(into + x * step, msg.format, from[x]);
    }
    return 1;
}

/// `PDTM_SCALE`: the picture itself made another size, nearest pixel,
/// and the old one given back.
///
/// It is not how a picture is drawn scaled - `PDTA_Scale` does that
/// without a second copy - but how a program says the picture is to be
/// that size from now on.
pub fn scale(base: *Base, cl: *Class, o: *Object, new_width: u32, new_height: u32) bool {
    const sys = base.sys_base;
    const own = classes.instData(Data, cl, o);
    const from = own.pens orelse return false;
    if (new_width == 0 or new_height == 0) return false;
    const old_width: u32 = own.bmh.width;
    const old_height: u32 = own.bmh.height;
    if (new_width == old_width and new_height == old_height) return true;

    const count = new_width * new_height;
    if (count / new_width != new_height or count > (1 << 28)) return false;
    const memory = sys.AllocVec(count * @sizeOf(graphics.Pen), exec.MEMF_ANY) orelse return false;
    const into: [*]graphics.Pen = @ptrCast(@alignCast(memory));
    const old_row = own.bytes_per_row / @sizeOf(graphics.Pen);
    var y: u32 = 0;
    while (y < new_height) : (y += 1) {
        const source_y = y * old_height / new_height;
        const row = from + source_y * old_row;
        const target = into + y * new_width;
        var x: u32 = 0;
        while (x < new_width) : (x += 1) target[x] = row[x * old_width / new_width];
    }
    sys.FreeVec(from);
    own.pens = into;
    own.pen_count = count;
    own.bytes_per_row = new_width * @sizeOf(graphics.Pen);
    own.bmh.width = @truncate(new_width);
    own.bmh.height = @truncate(new_height);
    return true;
}
