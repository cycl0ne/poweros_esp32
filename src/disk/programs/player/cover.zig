// SPDX-License-Identifier: MIT
//! The cover beside the song's names: the picture its tags hold, or one
//! lying beside the file - `cover.jpg`, `folder.jpg` and the like - read
//! through datatypes.library and scaled to fill a square, what overhangs
//! cut equally from both sides, so a wide picture shows its middle.
//!
//! A song's cover is read once, into a bitmap of its own as large as the
//! cover is ever shown (`Kept`), and shown from there at whatever size the
//! window gives it, scaled down (`BitMapScale`) - so a window being sized
//! never reads the picture again. The kept bitmap is in the format of the
//! RastPort it is shown in, which a scale between bitmaps needs.
//!
//! datatypes.library reads a picture from a file, so a picture held in
//! the tags is written to `T:` first, under a name of this task's own, and
//! the file deleted once it is read. The name ends as a file of its kind
//! does - `.jpg`, `.png` - because a picture's descriptor asks for that as
//! well as for its first bytes. Without datatypes.library, or with no
//! picture, the square is left dark.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const datatypes = sdk.datatypes;
const ac = sdk.audiocodec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const TagItem = sdk.utility.TagItem;
const Rect = graphics.Rect;
const RastPort = graphics.RastPort;
const Surface = sdk.rtg.Surface;
const PixelFormat = sdk.rtg.bitmaps.PixelFormat;
const pic = datatypes.pictureclass;

/// What drawing a cover needs.
pub const Libraries = struct {
    sys: *ExecBase,
    dl: *DosBase,
    gb: *GraphicsBase,
    dt: ?*DataTypesBase,
};

/// The ground where there is no cover, and round one that is not square.
const ground: graphics.Pen = 0xFF20_2028;

/// Pictures looked for beside a song whose tags hold none.
const beside = [_][*:0]const u8{ "cover.jpg", "folder.jpg", "front.jpg", "cover.png", "folder.png" };

/// How large a cover is kept, in pixels each way: the most it is shown.
pub const kept_size = 160;

/// The cover of the song shown, kept at `kept_size` - the picture, or the
/// dark ground where there is none.
pub const Kept = struct {
    bitmap: ?*Surface = null,
    rast_port: ?*RastPort = null,

    /// The song's picture read and kept: the one its tags hold, one beside
    /// it, or the ground. `friend` is a RastPort it is to be shown in. The
    /// bitmap is made the first time; without the memory nothing is kept
    /// and the cover is shown as the ground. Whether a picture was found.
    pub fn read(kept: *Kept, libs: Libraries, friend: *RastPort, picture: ?*const ac.AudioPicture, song: [*:0]const u8) bool {
        const gb = libs.gb;
        if (kept.bitmap == null) {
            kept.bitmap = gb.AllocBitMapTagList(&[_]TagItem{
                .{ .tag = graphics.BMTAG_Width, .data = kept_size },
                .{ .tag = graphics.BMTAG_Height, .data = kept_size },
                .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(friend) },
                .{},
            });
            const bitmap = kept.bitmap orelse return false;
            kept.rast_port = gb.CreateRastPortTagList(&[_]TagItem{
                .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(bitmap) },
                .{ .tag = graphics.RPTAG_Smooth, .data = 1 },
                .{},
            });
        }
        const rp = kept.rast_port orelse return false;
        fill(gb, rp, kept_size);
        const dt = libs.dt orelse return false;
        if (picture) |held| {
            if (fromTags(libs, dt, rp, kept_size, held)) return true;
        }
        return fromFolder(libs, dt, rp, kept_size, song);
    }

    /// The square `size` pixels each way at `rp`'s top left: what is kept,
    /// scaled to it, smoothly.
    pub fn show(kept: *const Kept, gb: *GraphicsBase, rp: *RastPort, size: i32) void {
        const bitmap = kept.bitmap orelse return fill(gb, rp, size);
        if (kept.rast_port == null) return fill(gb, rp, size);
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{} });
        gb.BitMapScale(bitmap, &.{ .max_x = kept_size, .max_y = kept_size }, rp, &.{ .max_x = size, .max_y = size });
    }

    pub fn free(kept: *Kept, gb: *GraphicsBase) void {
        gb.FreeRastPort(kept.rast_port);
        gb.FreeBitMap(kept.bitmap);
        kept.* = .{};
    }
};

/// The square `size` pixels each way at `rp`'s top left in the ground.
fn fill(gb: *GraphicsBase, rp: *RastPort, size: i32) void {
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = ground }, .{} });
    gb.RectFill(rp, &.{ .max_x = size, .max_y = size });
}

/// The picture the tags hold, through a file in T:.
fn fromTags(libs: Libraries, dt: *DataTypesBase, rp: *RastPort, size: i32, held: *const ac.AudioPicture) bool {
    const dl = libs.dl;
    var name: [48:0]u8 = @splat(0);
    const task: u32 = @truncate(@intFromPtr(libs.sys.FindTask(null)));
    const stream = exec.fmtStream(.{ task, extensionOf(held) });
    comptime exec.checkFormat("T:Player-cover-%x.%s", @TypeOf(.{ @as(u32, 0), extensionOf(held) }));
    _ = libs.sys.RawDoFmt("T:Player-cover-%x.%s", &stream, null, &name);
    const file = dl.Open(&name, dos.MODE_NEWFILE) orelse return false;
    const written = dl.Write(file, held.data, @intCast(held.size));
    _ = dl.Close(file);
    defer _ = dl.DeleteFile(&name);
    if (written != @as(isize, @intCast(held.size))) return false;
    return load(libs, dt, rp, size, &name);
}

/// What a file of the picture's kind is named with: by its first bytes,
/// else by its MIME type.
fn extensionOf(held: *const ac.AudioPicture) [*:0]const u8 {
    const bytes = held.data[0..held.size];
    if (bytes.len >= 4 and bytes[0] == 0x89 and bytes[1] == 'P' and bytes[2] == 'N' and bytes[3] == 'G') return "png";
    if (bytes.len >= 3 and bytes[0] == 'G' and bytes[1] == 'I' and bytes[2] == 'F') return "gif";
    if (bytes.len >= 2 and bytes[0] == 'B' and bytes[1] == 'M') return "bmp";
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return "jpg";
    const mime = held.mime;
    if (mime[6] == 'p' and mime[7] == 'n' and mime[8] == 'g') return "png";
    return "jpg";
}

/// A picture lying in the song's own drawer.
fn fromFolder(libs: Libraries, dt: *DataTypesBase, rp: *RastPort, size: i32, song: [*:0]const u8) bool {
    if (song[0] == 0) return false;
    const dl = libs.dl;
    var path: [dos.path_max + 1:0]u8 = @splat(0);
    var length: usize = 0;
    while (song[length] != 0 and length < dos.path_max) : (length += 1) path[length] = song[length];
    const drawer_end = @intFromPtr(dl.PathPart(&path)) - @intFromPtr(&path);
    for (beside) |candidate| {
        path[drawer_end] = 0;
        if (!dl.AddPart(&path, candidate, path.len)) continue;
        const lock = dl.Lock(&path, dos.SHARED_LOCK) orelse continue;
        dl.UnLock(lock);
        if (load(libs, dt, rp, size, &path)) return true;
    }
    return false;
}

/// The picture file `name` read and scaled into the square.
fn load(libs: Libraries, dt: *DataTypesBase, rp: *RastPort, size: i32, name: [*:0]const u8) bool {
    const object = dt.NewDTObjectA(name, &[_]TagItem{
        .{ .tag = datatypes.datatypesclass.DTA_GroupID, .data = datatypes.GID_PICTURE },
        .{},
    }) orelse return false;
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
    const source = Rect{
        .min_x = @divTrunc(width - side, 2),
        .min_y = @divTrunc(height - side, 2),
        .max_x = @divTrunc(width - side, 2) + side,
        .max_y = @divTrunc(height - side, 2) + side,
    };
    // The picture's pens are 0xAARRGGBB words: in memory blue first.
    libs.gb.ScalePixelArray(rp, @ptrFromInt(pixels), @intCast(pitch), @intFromEnum(PixelFormat.bgra32), &source, &.{ .max_x = size, .max_y = size });
    return true;
}
