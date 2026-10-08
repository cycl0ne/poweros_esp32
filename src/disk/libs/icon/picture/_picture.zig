// SPDX-License-Identifier: MIT
//! An icon's picture: an icon file's PNG decoded once into four bytes a
//! pixel, and shared by every icon that shows it.
//!
//! **One block holds it all**: the `Picture` - whose first field is the
//! `IconImage` a `DiskObject` points at - then the file's chunks after
//! `IHDR` but `icOn`, then the pixels. The chunks are kept so that
//! `PutDiskObject` writes the picture back as it was read, with only the
//! fields new; they are the compressed picture, a few KiB.
//!
//! **A picture counts its users**, under a spinlock in the base: a
//! default's picture is held by the base and by every icon made from it,
//! and goes with the last.
//!
//! The file is decoded with the SDK's PNG decoder (`sdk.datatypes.png`):
//! the `IDAT` chunks joined, unpacked whole, each row's filter undone
//! against the row above, and its pixels spread out to red, green, blue
//! and coverage - into the picture's rows directly, or through one row
//! for the seven passes of an interlaced file.

const sdk = @import("sdk");
const exec = sdk.exec;
const icon = sdk.icon;
const iconfile = icon.file;
const decode = sdk.datatypes.png.decode;
const inflate = sdk.datatypes.png.inflate;
const IconBase = @import("../icon_base.zig").IconBase;

/// What a picture is checked by when an icon hands one back: an image
/// that is not one of these was not made here.
const MAGIC: u32 = 0x49434F4E;

/// `IHDR` as a whole chunk: 13 bytes and the 12 round them.
pub const HEADER_BYTES = 25;

pub const Picture = extern struct {
    /// What `DiskObject.image` points at.
    image: icon.IconImage,
    magic: u32 = MAGIC,
    /// How many hold it: the base for a default, and each icon.
    users: u32 = 1,
    /// `IHDR` whole, and the size of the chunks after it, which follow
    /// this struct.
    header: [HEADER_BYTES]u8 = @splat(0),
    pad: [3]u8 = .{ 0, 0, 0 },
    kept_size: u32 = 0,

    /// The chunks after `IHDR`, `icOn` left out: what is written back.
    pub fn kept(picture: *const Picture) []const u8 {
        const start: [*]const u8 = @ptrCast(picture);
        return start[@sizeOf(Picture)..][0..picture.kept_size];
    }
};

pub const Error = error{
    /// Not a PNG, or one this cannot read.
    WrongType,
    /// More than `PICTURE_MAX` pixels either way.
    TooLarge,
    NoMemory,
};

/// The picture behind an icon's image; null for an image not made here.
pub fn ofImage(image: *const icon.IconImage) ?*Picture {
    const picture: *Picture = @constCast(@fieldParentPtr("image", image));
    return if (picture.magic == MAGIC) picture else null;
}

/// A picture made from an icon file's bytes, with one user.
pub fn make(base: *IconBase, file: []const u8) Error!*Picture {
    const sys = base.sys_base;
    const info = decode.readInfo(file) catch return Error.WrongType;
    if (info.width > iconfile.PICTURE_MAX or info.height > iconfile.PICTURE_MAX) return Error.TooLarge;
    const header = iconfile.headerChunk(file) catch return Error.WrongType;
    if (header.len != HEADER_BYTES) return Error.WrongType;
    const kept_size = iconfile.keptSize(file) catch return Error.WrongType;

    const pixels_at = (@sizeOf(Picture) + kept_size + 3) & ~@as(usize, 3);
    const pixel_bytes = @as(usize, info.width) * info.height * 4;
    const memory = sys.AllocVec(pixels_at + pixel_bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return Error.NoMemory;
    const bytes: [*]u8 = @ptrCast(memory);
    const picture: *Picture = @ptrCast(@alignCast(memory));
    picture.* = .{
        .image = .{ .width = info.width, .height = info.height, .pixels = bytes + pixels_at },
        .kept_size = @intCast(kept_size),
    };
    @memcpy(&picture.header, header);
    iconfile.keepChunks(file, bytes[@sizeOf(Picture)..][0..kept_size]) catch {
        sys.FreeVec(memory);
        return Error.WrongType;
    };
    unpack(base, file, info, (bytes + pixels_at)[0..pixel_bytes]) catch |failure| {
        sys.FreeVec(memory);
        return failure;
    };
    return picture;
}

/// One more user.
pub fn hold(base: *IconBase, picture: *Picture) void {
    const sys = base.sys_base;
    sys.AcquireLock(&base.users_lock);
    picture.users += 1;
    sys.ReleaseLock(&base.users_lock);
}

/// One user fewer; the last frees it.
pub fn release(base: *IconBase, picture: *Picture) void {
    const sys = base.sys_base;
    sys.AcquireLock(&base.users_lock);
    picture.users -= 1;
    const last = picture.users == 0;
    sys.ReleaseLock(&base.users_lock);
    if (last) sys.FreeVec(picture);
}

/// What the decoder needs besides the file, in one block so that it costs
/// the caller's stack nothing: an icon is read on whatever stack the
/// program that asks has.
const Work = struct {
    stream: inflate.Work = .{},
    palette: decode.Palette = .{},
};

/// The file's pixels, red, green, blue and coverage, into `pixels`.
fn unpack(base: *IconBase, file: []const u8, info: decode.Info, pixels: []u8) Error!void {
    const sys = base.sys_base;
    const work_memory = sys.AllocVec(@sizeOf(Work), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return Error.NoMemory;
    defer sys.FreeVec(work_memory);
    const work: *Work = @ptrCast(@alignCast(work_memory));
    work.* = .{};

    var plte: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat_length: usize = 0;
    var walk = decode.Walk.start(file) catch return Error.WrongType;
    while (walk.next() catch return Error.WrongType) |chunk| {
        switch (chunk.id) {
            decode.ID_PLTE => plte = chunk.data,
            decode.ID_TRNS => trns = chunk.data,
            decode.ID_IDAT => idat_length += chunk.data.len,
            decode.ID_IEND => break,
            else => {},
        }
    }
    if (idat_length == 0) return Error.WrongType;
    decode.readPalette(info, &work.palette, plte, trns) catch return Error.WrongType;

    // The compressed stream is the IDAT chunks joined.
    const joined_memory = sys.AllocVec(idat_length, exec.MEMF_ANY) orelse return Error.NoMemory;
    defer sys.FreeVec(joined_memory);
    const joined: [*]u8 = @ptrCast(joined_memory);
    var at: usize = 0;
    walk = decode.Walk.start(file) catch return Error.WrongType;
    while (walk.next() catch return Error.WrongType) |chunk| {
        if (chunk.id != decode.ID_IDAT) continue;
        @memcpy(joined[at..][0..chunk.data.len], chunk.data);
        at += chunk.data.len;
    }

    // Unpacked whole: every row with the filter byte in front of it.
    const raw_size = decode.rawSize(info);
    const raw_memory = sys.AllocVec(raw_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return Error.NoMemory;
    defer sys.FreeVec(raw_memory);
    const raw: [*]u8 = @ptrCast(raw_memory);
    const written = inflate.uncompress(&work.stream, joined[0..idat_length], raw[0..raw_size]) catch return Error.WrongType;
    if (written != raw_size) return Error.WrongType;

    // The row a pass's first row is undone against: zeroes. And one row
    // of colour, for a pass whose pixels are not next to one another.
    const first_row = info.rowBytes(info.width);
    const spare_memory = sys.AllocVec(first_row + info.width * 4, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return Error.NoMemory;
    defer sys.FreeVec(spare_memory);
    const spare: [*]u8 = @ptrCast(spare_memory);
    const empty = spare[0..first_row];
    const colour = spare[first_row..][0 .. info.width * 4];

    if (info.interlace == 0) {
        try walkPass(info, work, raw[0..raw_size], empty, colour, pixels, .{ 0, 0, 1, 1 }, info.width, info.height);
        return;
    }
    var offset: usize = 0;
    for (0..decode.passes.len) |pass| {
        const size = decode.passSize(info, pass);
        if (size.width == 0 or size.height == 0) continue;
        const bytes = @as(usize, size.height) * (1 + info.rowBytes(size.width));
        try walkPass(info, work, raw[offset..][0..bytes], empty, colour, pixels, decode.passes[pass], size.width, size.height);
        offset += bytes;
    }
}

/// One pass of rows: each undone against the one above it, read as
/// colour and put at its place in `pixels`. `place` is where the pass
/// starts and how far apart its pixels are, across and down.
fn walkPass(info: decode.Info, work: *Work, raw: []u8, empty: []const u8, colour: []u8, pixels: []u8, place: [4]u32, width: u32, height: u32) Error!void {
    const stride = info.rowBytes(width);
    const pixel = info.pixelBytes();
    const pitch = @as(usize, info.width) * 4;
    var above: []const u8 = empty[0..stride];
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const at = @as(usize, y) * (1 + stride);
        const row = raw[at + 1 ..][0..stride];
        decode.unfilter(raw[at], row, if (y == 0) empty[0..stride] else above, pixel) catch return Error.WrongType;
        const top = place[1] + y * place[3];
        const line = pixels[top * pitch ..][0..pitch];
        if (place[2] == 1) {
            decode.expand(info, &work.palette, row, width, line[place[0] * 4 ..][0 .. width * 4]);
        } else {
            decode.expand(info, &work.palette, row, width, colour[0 .. width * 4]);
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const left = (place[0] + x * place[2]) * 4;
                @memcpy(line[left..][0..4], colour[x * 4 ..][0..4]);
            }
        }
        above = row;
    }
}
