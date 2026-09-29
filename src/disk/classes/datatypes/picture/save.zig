// SPDX-License-Identifier: MIT
//! `DTM_WRITE`: the picture written out as an IFF ILBM.
//!
//! One form, with a `BMHD` saying what it is, a `CMAP` when the file it
//! came from had a palette, a `GRAB` when it has a hot spot, and a
//! `BODY` of 24 or 32 planes - red, green and blue from the top bit
//! down, and coverage after them when the picture has any. The planes
//! are written as they are, without ByteRun1: a picture of pens is
//! already four times the size of the file it came from, and a reader
//! that takes ILBM at all takes an uncompressed one.
//!
//! Anything other than `DTWM_IFF` is left to the subclass: a format's
//! class that can write its own file answers `DTWM_RAW` itself and lets
//! this one answer the rest.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const gadgets = sdk.gadgets;
const iffparse = sdk.iffparse;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const picture = @import("picture.zig");
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const Class = classes.Class;
const Object = classes.Object;
const Data = picture.Data;
const Base = gadgets.Base;

/// A 16-bit number as the file holds it, high byte first.
fn putWord(into: []u8, value: u16) void {
    into[0] = @truncate(value >> 8);
    into[1] = @truncate(value);
}

/// The header as `BMHD` holds it: big-endian, and the shape the picture
/// is written in rather than the one it was read in.
fn headerBytes(own: *const Data, planes: u8, into: *[20]u8) void {
    putWord(into[0..2], own.bmh.width);
    putWord(into[2..4], own.bmh.height);
    putWord(into[4..6], @bitCast(own.bmh.left));
    putWord(into[6..8], @bitCast(own.bmh.top));
    into[8] = planes;
    into[9] = if (planes == 32) pic.mskHasAlpha else pic.mskNone;
    into[10] = pic.cmpNone;
    into[11] = 0;
    putWord(into[12..14], own.bmh.transparent);
    into[14] = if (own.bmh.x_aspect != 0) own.bmh.x_aspect else 1;
    into[15] = if (own.bmh.y_aspect != 0) own.bmh.y_aspect else 1;
    putWord(into[16..18], @bitCast(own.bmh.page_width));
    putWord(into[18..20], @bitCast(own.bmh.page_height));
}

/// One row of pens turned into the planes the file holds: plane 0 is the
/// lowest bit of blue, and the planes run upwards through green, red and
/// coverage. `into` is `planes * stride` bytes and is written whole.
fn rowPlanes(row: [*]const graphics.Pen, width: u32, planes: u32, stride: u32, into: [*]u8) void {
    @memset(into[0 .. planes * stride], 0);
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        const pen = row[x];
        // The channels in the order the planes run: blue lowest.
        const channels = [4]u8{
            @truncate(pen),
            @truncate(pen >> 8),
            @truncate(pen >> 16),
            @truncate(pen >> 24),
        };
        const byte = x >> 3;
        const bit: u3 = @truncate(7 - (x & 7));
        var plane: u32 = 0;
        while (plane < planes) : (plane += 1) {
            const channel = channels[plane >> 3];
            if (channel & (@as(u8, 1) << @truncate(plane & 7)) != 0) {
                into[plane * stride + byte] |= @as(u8, 1) << bit;
            }
        }
    }
}

/// `DTM_WRITE`: the picture as a `FORM ILBM` on the caller's open file.
pub fn write(base: *Base, cl: *Class, o: *Object, msg: *dtc.DtWrite) usize {
    const own = classes.instData(Data, cl, o);
    if (msg.mode != dtc.DTWM_IFF) return 0;
    const file = msg.file orelse return 0;
    const pens = own.pens orelse return 0;
    const ip: *IFFParseBase = @ptrCast(base.opened[1] orelse return 0);
    const sys = base.sys_base;

    const width: u32 = own.bmh.width;
    const height: u32 = own.bmh.height;
    const planes: u32 = if (picture.hasCoverage(own)) 32 else 24;
    // A plane's row is whole words, as the format has it.
    const stride: u32 = ((width + 15) / 16) * 2;

    const line = sys.AllocVec(planes * stride, exec.MEMF_ANY) orelse return 0;
    defer sys.FreeVec(line);
    const line_bytes: [*]u8 = @ptrCast(line);

    const iff = ip.AllocIFF() orelse return 0;
    defer ip.FreeIFF(iff);
    iff.stream = @intFromPtr(file);
    ip.InitIFFasDOS(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_WRITE) != 0) return 0;
    defer ip.CloseIFF(iff);

    if (ip.PushChunk(iff, pic.ID_ILBM, iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN) != 0) return 0;

    var header: [20]u8 = @splat(0);
    headerBytes(own, @truncate(planes), &header);
    if (ip.PushChunk(iff, 0, pic.ID_BMHD, header.len) != 0) return 0;
    _ = ip.WriteChunkBytes(iff, &header, header.len);
    _ = ip.PopChunk(iff);

    if (own.palette) |colors| {
        if (own.num_colors != 0) {
            const bytes: i32 = @intCast(own.num_colors * @sizeOf(pic.ColorRegister));
            if (ip.PushChunk(iff, 0, pic.ID_CMAP, bytes) == 0) {
                _ = ip.WriteChunkBytes(iff, colors, bytes);
                _ = ip.PopChunk(iff);
            }
        }
    }

    if (own.grab.x != 0 or own.grab.y != 0) {
        var grab: [4]u8 = @splat(0);
        putWord(grab[0..2], @truncate(@as(u32, @bitCast(own.grab.x))));
        putWord(grab[2..4], @truncate(@as(u32, @bitCast(own.grab.y))));
        if (ip.PushChunk(iff, 0, pic.ID_GRAB, grab.len) == 0) {
            _ = ip.WriteChunkBytes(iff, &grab, grab.len);
            _ = ip.PopChunk(iff);
        }
    }

    if (ip.PushChunk(iff, 0, pic.ID_BODY, iffparse.IFFSIZE_UNKNOWN) != 0) return 0;
    const row_pens = own.bytes_per_row / @sizeOf(graphics.Pen);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        rowPlanes(pens + y * row_pens, width, planes, stride, line_bytes);
        if (ip.WriteChunkBytes(iff, line_bytes, @intCast(planes * stride)) < 0) return 0;
    }
    _ = ip.PopChunk(iff);
    _ = ip.PopChunk(iff);
    return 1;
}
