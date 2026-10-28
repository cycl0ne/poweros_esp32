// SPDX-License-Identifier: MIT
//! The cover beside the song's names: the picture its tags hold, or one
//! lying beside the file - `cover.jpg`, `folder.jpg` and the like - read
//! through datatypes.library and scaled to fill a square, what overhangs
//! cut equally from both sides, so a wide picture shows its middle.
//!
//! A song's cover is read once, into a bitmap of its own as large as the
//! cover is ever shown (`Kept`), and shown from there at whatever size the
//! window gives it - so a window being sized never reads the picture
//! again. It is shown with round corners in a sunk edge, on the window's
//! ground: scaled down (`BitMapScale`) into a second bitmap, which then
//! fills a rounded square the way a tile fills a shape (`FILL_TILE`),
//! with smooth edges. Both bitmaps are in the format of the RastPort the
//! cover is shown in, which a scale between bitmaps needs.
//!
//! A picture the tags hold is read from memory (`DTST_MEMORY`), one beside
//! the song from its file, whose name is kept: where the cover came from
//! is what opens it again at its own size (big.zig). Without
//! datatypes.library, or with no picture, the square is the ground with a
//! note on it, faded into the ground as a picture that is not there.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const ic = intuition.imageclass;
const sc = intuition.screens;
const datatypes = sdk.datatypes;
const ac = sdk.audiocodec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Rect = graphics.Rect;
const RastPort = graphics.RastPort;
const Surface = sdk.rtg.Surface;
const PixelFormat = sdk.rtg.bitmaps.PixelFormat;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;

/// What reading a cover needs.
pub const Libraries = struct {
    sys: *ExecBase,
    dl: *DosBase,
    gb: *GraphicsBase,
    dt: ?*DataTypesBase,
};

/// What showing one needs besides: the screen's pens, and the note that
/// stands where there is no picture (media.image's `MEDIA_NOTE`), if it
/// could be made.
pub const Look = struct {
    ib: *IntuitionBase,
    dri: ?*sc.DrawInfo,
    note: ?*Object,

    fn pen(look: *const Look, which: usize, otherwise: graphics.Pen) graphics.Pen {
        const info = look.dri orelse return otherwise;
        if (which >= info.num_pens) return otherwise;
        return info.pens[which];
    }

    /// The note, half as large as the square `size` each way, in its
    /// middle.
    fn drawNote(look: *const Look, rp: *RastPort, size: i32) void {
        const note = look.note orelse return;
        const side = @divTrunc(size, 2);
        _ = look.ib.SetAttrsTagList(note, &[_]TagItem{
            .{ .tag = ic.IA_Width, .data = @intCast(side) },
            .{ .tag = ic.IA_Height, .data = @intCast(side) },
            .{},
        });
        look.ib.DrawImageState(rp, note, @divTrunc(size - side, 2), @divTrunc(size - side, 2), ic.IDS_DISABLED, look.dri);
    }
};

/// Pictures looked for beside a song whose tags hold none.
const beside = [_][*:0]const u8{ "cover.jpg", "folder.jpg", "front.jpg", "cover.png", "folder.png" };

/// How large a cover is kept, in pixels each way: the most it is shown.
pub const kept_size = 160;

/// Where the cover shown came from.
pub const From = enum { none, tags, beside };

/// What a picture is read from: the bytes the tags hold, or a file.
pub const Source = union(enum) {
    held: *const ac.AudioPicture,
    file: [*:0]const u8,
};

/// A picture datatype object of `source`, made with `attrs` besides;
/// null, with IoErr saying why, when it cannot be.
pub fn objectOf(dt: *DataTypesBase, source: Source, attrs: ?[*]const TagItem) ?*Object {
    const more: utility.Tag = if (attrs != null) utility.TAG_MORE else utility.TAG_DONE;
    return switch (source) {
        .held => |held| dt.NewDTObjectA(null, &[_]TagItem{
            .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_MEMORY },
            .{ .tag = dtc.DTA_Handle, .data = @intFromPtr(held.data) },
            .{ .tag = dtc.DTA_SourceSize, .data = held.size },
            .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
            .{ .tag = more, .data = @intFromPtr(attrs) },
        }),
        .file => |name| dt.NewDTObjectA(name, &[_]TagItem{
            .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
            .{ .tag = more, .data = @intFromPtr(attrs) },
        }),
    };
}

/// The cover of the song shown, kept at `kept_size`, and where it came
/// from.
pub const Kept = struct {
    bitmap: ?*Surface = null,
    rast_port: ?*RastPort = null,
    /// The kept cover scaled to the size it is shown at, its top left:
    /// the tile the rounded square is filled with.
    shown: ?*Surface = null,
    shown_port: ?*RastPort = null,
    from: From = .none,
    /// The file beside the song the cover was read from, when it was.
    path: [dos.path_max + 1:0]u8 = @splat(0),

    /// The song's picture read and kept: the one its tags hold, one beside
    /// it, or none. `friend` is a RastPort it is to be shown in. The
    /// bitmaps are made the first time; without the memory for them
    /// nothing is kept and the note is shown. Whether a picture was found.
    pub fn read(kept: *Kept, libs: Libraries, friend: *RastPort, picture: ?*const ac.AudioPicture, song: [*:0]const u8) bool {
        kept.from = .none;
        if (kept.bitmap == null) {
            kept.bitmap = square(libs.gb, friend);
            kept.rast_port = portOnto(libs.gb, kept.bitmap);
            kept.shown = square(libs.gb, friend);
            kept.shown_port = portOnto(libs.gb, kept.shown);
        }
        const rp = kept.rast_port orelse return false;
        if (kept.shown_port == null) return false;
        const dt = libs.dt orelse return false;
        if (picture) |held| {
            if (load(dt, libs.gb, rp, .{ .held = held })) {
                kept.from = .tags;
                return true;
            }
        }
        if (fromFolder(libs, dt, rp, song, &kept.path)) {
            kept.from = .beside;
            return true;
        }
        return false;
    }

    /// The cover `size` pixels each way at `rp`'s top left, on the
    /// screen's ground, its corners round and its edge sunk: what is kept,
    /// smoothly scaled, or the note where nothing is.
    pub fn show(kept: *const Kept, gb: *GraphicsBase, rp: *RastPort, size: i32, look: Look) void {
        const ground = look.pen(sc.BACKGROUNDPEN, 0xFFAA_AAAA);
        const box = Rect{ .max_x = size, .max_y = size };
        const radius: u32 = @intCast(@max(4, @divTrunc(size, 16)));
        gb.SetRPAttrs(rp, &[_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = ground },
            .{ .tag = graphics.RPTAG_Smooth, .data = 1 },
            .{},
        });
        gb.RectFill(rp, &box);
        if (!kept.showPicture(gb, rp, &box, radius)) look.drawNote(rp, size);
        gb.DrawRoundBevel(rp, &box, radius, look.pen(sc.SHADOWPEN, 0xFF00_0000), look.pen(sc.SHINEPEN, 0xFFFF_FFFF));
    }

    /// The kept picture in the rounded square `box`: false when there is
    /// none.
    fn showPicture(kept: *const Kept, gb: *GraphicsBase, rp: *RastPort, box: *const Rect, radius: u32) bool {
        if (kept.from == .none) return false;
        const bitmap = kept.bitmap orelse return false;
        const shown = kept.shown orelse return false;
        const shown_port = kept.shown_port orelse return false;
        gb.BitMapScale(bitmap, &.{ .max_x = kept_size, .max_y = kept_size }, shown_port, box);
        // The tile is anchored where the RastPort starts, as the square
        // is: each pixel of the square is the picture's own.
        const tile = graphics.FillStyle{ .kind = graphics.FILL_TILE, .tile = shown };
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FillStyle, .data = @intFromPtr(&tile) }, .{} });
        gb.FillRoundRect(rp, box, radius);
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FillStyle, .data = 0 }, .{} });
        return true;
    }

    /// Where the cover shown can be read again, at its own size; null when
    /// it came from the tags, whose bytes are the stream's, or from
    /// nowhere.
    pub fn file(kept: *const Kept) ?[*:0]const u8 {
        return if (kept.from == .beside) &kept.path else null;
    }

    pub fn free(kept: *Kept, gb: *GraphicsBase) void {
        gb.FreeRastPort(kept.shown_port);
        gb.FreeBitMap(kept.shown);
        gb.FreeRastPort(kept.rast_port);
        gb.FreeBitMap(kept.bitmap);
        kept.* = .{};
    }
};

/// A bitmap `kept_size` each way in `friend`'s format, or null.
fn square(gb: *GraphicsBase, friend: *RastPort) ?*Surface {
    return gb.AllocBitMapTagList(&[_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = kept_size },
        .{ .tag = graphics.BMTAG_Height, .data = kept_size },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(friend) },
        .{},
    });
}

/// A RastPort drawing smoothly onto `bitmap`, or null.
fn portOnto(gb: *GraphicsBase, bitmap: ?*Surface) ?*RastPort {
    return gb.CreateRastPortTagList(&[_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(bitmap orelse return null) },
        .{ .tag = graphics.RPTAG_Smooth, .data = 1 },
        .{},
    });
}

/// A picture lying in the song's own drawer, its name left in `path`.
fn fromFolder(libs: Libraries, dt: *DataTypesBase, rp: *RastPort, song: [*:0]const u8, path: *[dos.path_max + 1:0]u8) bool {
    if (song[0] == 0) return false;
    const dl = libs.dl;
    @memset(path, 0);
    var length: usize = 0;
    while (song[length] != 0 and length < dos.path_max) : (length += 1) path[length] = song[length];
    const drawer_end = @intFromPtr(dl.PathPart(path)) - @intFromPtr(path);
    for (beside) |candidate| {
        path[drawer_end] = 0;
        if (!dl.AddPart(path, candidate, path.len)) continue;
        const lock = dl.Lock(path, dos.SHARED_LOCK) orelse continue;
        dl.UnLock(lock);
        if (load(dt, libs.gb, rp, .{ .file = path })) return true;
    }
    return false;
}

/// The picture read and scaled into the kept square.
fn load(dt: *DataTypesBase, gb: *GraphicsBase, rp: *RastPort, source: Source) bool {
    const object = objectOf(dt, source, null) orelse return false;
    defer dt.DisposeDTObject(object);
    var header: usize = 0;
    var pixels: usize = 0;
    var pitch: usize = 0;
    _ = dt.GetDTAttrsA(object, &[_]TagItem{
        .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&header) },
        .{ .tag = pic.PDTA_Pixels, .data = @intFromPtr(&pixels) },
        .{ .tag = pic.PDTA_BytesPerRow, .data = @intFromPtr(&pitch) },
        .{},
    });
    if (header == 0 or pixels == 0) return false;
    const shape: *const pic.BitMapHeader = @ptrFromInt(header);
    const width: i32 = shape.width;
    const height: i32 = shape.height;
    if (width == 0 or height == 0) return false;
    // The largest square in the middle of the picture, scaled to fill.
    const side = @min(width, height);
    const source_area = Rect{
        .min_x = @divTrunc(width - side, 2),
        .min_y = @divTrunc(height - side, 2),
        .max_x = @divTrunc(width - side, 2) + side,
        .max_y = @divTrunc(height - side, 2) + side,
    };
    // The picture's pens are 0xAARRGGBB words: in memory blue first.
    gb.ScalePixelArray(rp, @ptrFromInt(pixels), @intCast(pitch), @intFromEnum(PixelFormat.bgra32), &source_area, &.{ .max_x = kept_size, .max_y = kept_size });
    return true;
}
