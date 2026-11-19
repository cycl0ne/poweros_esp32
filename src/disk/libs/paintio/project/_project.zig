// SPDX-License-Identifier: MIT
//! The project file's parts that need no file: `PHDR` and `LHDR` made
//! and read, pixels turned into the file's bytes and back, and iffparse's
//! and compression's failures said as dos error codes.
//!
//! A pixel is `0xAARRGGBB`; in the file, and in the rows datatypes is
//! handed (`PBPAFMT_ARGB`), it is the bytes alpha, red, green and blue,
//! which is the number written big-endian. Both ways go a byte at a time,
//! so they are the same on any core.

const sdk = @import("sdk");
const dos = sdk.dos;
const iffparse = sdk.iffparse;
const paintio = sdk.paintio;
const DosBase = sdk.interface.dos.DosBase;

/// `PHDR`'s size: four numbers.
pub const header_size = 16;
/// `LHDR`'s largest size: the opacity, the flags, two bytes of 0, and a
/// name without its NUL.
pub const layer_header_size = 4 + paintio.NAME_SIZE - 1;

fn putWord(into: []u8, value: u32) void {
    into[0] = @truncate(value >> 24);
    into[1] = @truncate(value >> 16);
    into[2] = @truncate(value >> 8);
    into[3] = @truncate(value);
}

pub fn getWord(from: []const u8) u32 {
    return @as(u32, from[0]) << 24 | @as(u32, from[1]) << 16 | @as(u32, from[2]) << 8 | from[3];
}

/// Whether a project is one the file can hold: a size from 1 to
/// `MAX_SIDE` each way, 1 to `MAX_LAYERS` layers with pixels, the one
/// painted among them, and a palette that fits.
pub fn valid(project: *const paintio.Project) bool {
    if (project.width == 0 or project.width > paintio.MAX_SIDE) return false;
    if (project.height == 0 or project.height > paintio.MAX_SIDE) return false;
    if (project.layer_count == 0 or project.layer_count > paintio.MAX_LAYERS) return false;
    if (project.current >= project.layer_count) return false;
    if (project.palette_count > paintio.MAX_PALETTE) return false;
    const layers = project.layers orelse return false;
    for (layers[0..project.layer_count]) |layer| if (layer.pixels == null) return false;
    return true;
}

pub fn headerBytes(project: *const paintio.Project, into: *[header_size]u8) void {
    putWord(into[0..4], project.width);
    putWord(into[4..8], project.height);
    putWord(into[8..12], project.layer_count);
    putWord(into[12..16], project.current);
}

/// `PHDR` into the project's size, layer count and current layer. False
/// for a header no project has.
pub fn readHeader(bytes: []const u8, project: *paintio.Project) bool {
    if (bytes.len < header_size) return false;
    const width = getWord(bytes[0..4]);
    const height = getWord(bytes[4..8]);
    const count = getWord(bytes[8..12]);
    const current = getWord(bytes[12..16]);
    if (width == 0 or width > paintio.MAX_SIDE or height == 0 or height > paintio.MAX_SIDE) return false;
    if (count == 0 or count > paintio.MAX_LAYERS or current >= count) return false;
    project.width = width;
    project.height = height;
    project.layer_count = count;
    project.current = current;
    return true;
}

/// `LHDR` for a layer; its length.
pub fn layerHeaderBytes(layer: *const paintio.Layer, into: *[layer_header_size]u8) usize {
    into[0] = layer.opacity;
    into[1] = layer.flags;
    into[2] = 0;
    into[3] = 0;
    var length: usize = 0;
    while (length < paintio.NAME_SIZE - 1 and layer.name[length] != 0) : (length += 1) into[4 + length] = layer.name[length];
    return 4 + length;
}

/// `LHDR` into a layer: what is there of it, the name cut to its room.
pub fn readLayerHeader(bytes: []const u8, layer: *paintio.Layer) void {
    layer.* = .{};
    if (bytes.len < 4) return;
    layer.opacity = bytes[0];
    layer.flags = bytes[1];
    const length = @min(bytes.len - 4, paintio.NAME_SIZE - 1);
    for (bytes[4..][0..length], 0..) |byte, at| {
        if (byte == 0) break;
        layer.name[at] = byte;
    }
}

/// Pixels as the file's bytes: alpha, red, green, blue each.
pub fn toFile(pixels: []const u32, into: [*]u8) void {
    for (pixels, 0..) |pixel, at| putWord(into[at * 4 ..][0..4], pixel);
}

/// The file's bytes, read into the pixels' own memory, made pixels where
/// they lie.
pub fn fromFile(pixels: []u32) void {
    for (pixels) |*pixel| {
        const bytes: *const [4]u8 = @ptrCast(pixel);
        pixel.* = getWord(bytes);
    }
}

/// An iffparse failure as a dos code: what dos said went wrong when it
/// was the file. A read that came back short with nothing wrong is a
/// file that ends before its chunks do: one of the wrong type, as a
/// mangled form is.
pub fn iffError(dl: *DosBase, code: i32) i32 {
    return switch (code) {
        iffparse.IFFERR_NOMEM => dos.ERROR_NO_FREE_STORE,
        iffparse.IFFERR_READ, iffparse.IFFERR_WRITE, iffparse.IFFERR_SEEK => blk: {
            const failure = dl.IoErr();
            if (failure != 0) break :blk failure;
            break :blk if (code == iffparse.IFFERR_READ) dos.ERROR_OBJECT_WRONG_TYPE else dos.ERROR_SEEK_ERROR;
        },
        else => dos.ERROR_OBJECT_WRONG_TYPE,
    };
}
