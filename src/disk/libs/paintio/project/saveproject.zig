// SPDX-License-Identifier: MIT
//! SaveProject: a project written as a `FORM PNTG`.
//!
//! The form is made with iffparse.library on the open file: `PHDR`,
//! `PALT` when there is a palette, `CYCL` when a range turns, and an
//! `LHDR` and a `BODY` for each
//! layer from the bottom, and an `LMSK` after a layer with a mask. A body
//! or a mask goes a row at a time - the row turned into the file's bytes,
//! through compression.library's Deflate, and what comes out written
//! whenever its buffer is full - so the memory it takes is a row and a
//! buffer, whatever the picture's size.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const iffparse = sdk.iffparse;
const compression = sdk.compression;
const paintio = sdk.paintio;
const DosBase = sdk.interface.dos.DosBase;
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const PaintIOBase = @import("../paintio_base.zig").PaintIOBase;
const _project = @import("_project.zig");

/// The bytes Deflate fills before they are written.
const out_size = 32 * 1024;

/// Writes a project as a file of its own: every layer, the palette.
///
/// SYNOPSIS:
/// ```zig
/// fn SaveProject(base: *PaintIOBase, name: [*:0]const u8, project: *const paintio.Project) i32
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `name`: the file, made anew or written over.
/// - `project`: the size, the layers from the bottom with their pixels
///   and their masks, the layer being painted, the palette
///   (`palette_count` colours of `palette`) and its ranges. `kind` is not
///   written.
///
/// RESULT:
/// 0 when the file is written, otherwise a dos error code: why the file
/// could not be made or written (`ERROR_DISK_FULL`, say),
/// `ERROR_NO_FREE_STORE`, `ERROR_INVALID_RESIDENT_LIBRARY` when
/// iffparse.library or compression.library cannot be opened, or
/// `ERROR_BAD_NUMBER` for a project no file holds - a side of 0 or
/// above `MAX_SIDE`, no layers or more than `MAX_LAYERS`, a layer
/// without pixels, a current layer past the last, a palette of more
/// than `MAX_PALETTE`.
///
/// BEHAVIOR:
/// The file is an IFF `FORM PNTG` (`sdk.paintio` has its chunks): the
/// header, the palette when it has colours, its ranges when one turns
/// (since 1.3), and each layer's header and pixels, and its mask when it
/// has one, packed by Deflate in a zlib wrapping. A file that could not
/// be written whole is deleted, so a failure leaves no half a project
/// behind - nor the file that was there before.
///
/// CONTEXT:
/// - Waits: yes, for the file system.
/// - Interrupts: not from an interrupt.
/// - Locks: none taken.
/// - Process: a Process; the file is opened on its behalf.
///
/// OWNERSHIP:
/// The project and its pixels stay the caller's, and are only read.
///
/// NOTES:
/// `LoadProject` reads the file back. A chunk it does not know is passed
/// over, so a later version may add some.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LoadProject`, `SavePicture`
///
/// EXAMPLES:
/// ```zig
/// var layer = paintio.Layer{ .pixels = pixels };
/// var project = paintio.Project{ .width = 320, .height = 200, .layer_count = 1, .layers = @ptrCast(&layer) };
/// const failure = pio.SaveProject("Work:sky.paint", &project);
/// if (failure != 0) _ = dl.PrintFault(failure, "Work:sky.paint");
/// ```
pub fn SaveProject(base: *PaintIOBase, name: [*:0]const u8, project: *const paintio.Project) i32 {
    if (!_project.valid(project)) return dos.ERROR_BAD_NUMBER;
    const sys = base.sys_base;
    const dl = base.dos_base;
    const ip_lib = sys.OpenLibrary(iffparse.IFFPARSENAME, 1) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY;
    defer sys.CloseLibrary(ip_lib);
    const cb_lib = sys.OpenLibrary(compression.COMPRESSIONNAME, 1) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY;
    defer sys.CloseLibrary(cb_lib);
    const ip: *IFFParseBase = @ptrCast(ip_lib);
    const cb: *CompressionBase = @ptrCast(cb_lib);

    const file = dl.Open(name, dos.MODE_NEWFILE) orelse return dl.IoErr();
    var failure = write(base, ip, cb, file, project);
    if (!dl.Close(file) and failure == 0) failure = dl.IoErr();
    if (failure != 0) _ = dl.DeleteFile(name);
    return failure;
}

/// The form onto the open file: 0, or why not.
fn write(base: *PaintIOBase, ip: *IFFParseBase, cb: *CompressionBase, file: *dos.FileHandle, project: *const paintio.Project) i32 {
    const sys = base.sys_base;
    const dl = base.dos_base;
    const row_bytes = @as(usize, project.width) * 4;
    const row = sys.AllocVec(row_bytes, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    defer sys.FreeVec(row);
    const out = sys.AllocVec(out_size, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    defer sys.FreeVec(out);

    const iff = ip.AllocIFF() orelse return dos.ERROR_NO_FREE_STORE;
    defer ip.FreeIFF(iff);
    iff.stream = @intFromPtr(file);
    ip.InitIFFasDOS(iff);
    const opened = ip.OpenIFF(iff, iffparse.IFFF_WRITE);
    if (opened != 0) return _project.iffError(dl, opened);
    defer ip.CloseIFF(iff);

    var failure = ip.PushChunk(iff, paintio.ID_PNTG, iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN);
    if (failure != 0) return _project.iffError(dl, failure);

    var header: [_project.header_size]u8 = undefined;
    _project.headerBytes(project, &header);
    failure = chunk(ip, iff, paintio.ID_PHDR, &header);
    if (failure != 0) return _project.iffError(dl, failure);

    if (project.palette_count != 0) {
        var palette: [paintio.MAX_PALETTE * 4]u8 = undefined;
        _project.toFile(project.palette[0..project.palette_count], &palette);
        failure = chunk(ip, iff, paintio.ID_PALT, palette[0 .. project.palette_count * 4]);
        if (failure != 0) return _project.iffError(dl, failure);
    }

    for (project.ranges) |range| {
        if (range.speed == 0) continue;
        const ranges: *const [paintio.MAX_RANGES * 4]u8 = @ptrCast(&project.ranges);
        failure = chunk(ip, iff, paintio.ID_CYCL, ranges);
        if (failure != 0) return _project.iffError(dl, failure);
        break;
    }

    const layers = project.layers.?;
    for (layers[0..project.layer_count]) |*layer| {
        var layer_header: [_project.layer_header_size]u8 = undefined;
        const length = _project.layerHeaderBytes(layer, &layer_header);
        failure = chunk(ip, iff, paintio.ID_LHDR, layer_header[0..length]);
        if (failure != 0) return _project.iffError(dl, failure);
        const body = writeBody(dl, ip, cb, iff, .{ .pixels = layer.pixels.? }, project.width, project.height, @ptrCast(row), @ptrCast(out));
        if (body != 0) return body;
        if (layer.mask) |mask| {
            const masked = writeBody(dl, ip, cb, iff, .{ .mask = mask }, project.width, project.height, @ptrCast(row), @ptrCast(out));
            if (masked != 0) return masked;
        }
    }
    failure = ip.PopChunk(iff);
    if (failure != 0) return _project.iffError(dl, failure);
    return 0;
}

/// A chunk of known bytes: 0, or iffparse's error.
fn chunk(ip: *IFFParseBase, iff: *iffparse.IFFHandle, id: u32, bytes: []const u8) i32 {
    const size: i32 = @intCast(bytes.len);
    const pushed = ip.PushChunk(iff, 0, id, size);
    if (pushed != 0) return pushed;
    const written = ip.WriteChunkBytes(iff, bytes.ptr, size);
    if (written != size) return if (written < 0) written else iffparse.IFFERR_WRITE;
    return ip.PopChunk(iff);
}

/// What a packed chunk holds: a layer's pixels, or its mask.
const Rows = union(enum) {
    pixels: [*]const u32,
    mask: [*]const u8,
};

/// A layer's `BODY`, or its `LMSK`: 0, or why not, as a dos code.
fn writeBody(dl: *DosBase, ip: *IFFParseBase, cb: *CompressionBase, iff: *iffparse.IFFHandle, rows: Rows, width: u32, height: u32, row: [*]u8, out: [*]u8) i32 {
    var stream = compression.Stream{};
    if (cb.InitDeflate(&stream, compression.FORMAT_ZLIB, compression.LEVEL_DEFAULT) != compression.COMPRESS_OK) return dos.ERROR_NO_FREE_STORE;
    defer cb.EndDeflate(&stream);
    const id = switch (rows) {
        .pixels => paintio.ID_BODY,
        .mask => paintio.ID_LMSK,
    };
    const pushed = ip.PushChunk(iff, 0, id, iffparse.IFFSIZE_UNKNOWN);
    if (pushed != 0) return _project.iffError(dl, pushed);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const start = @as(usize, y) * width;
        const bytes = switch (rows) {
            .pixels => |pixels| blk: {
                _project.toFile(pixels[start..][0..width], row);
                break :blk row[0 .. @as(usize, width) * 4];
            },
            .mask => |mask| mask[start..][0..width],
        };
        const flush = if (y + 1 == height) compression.FLUSH_FINISH else compression.FLUSH_NONE;
        const failure = deflate(dl, ip, cb, iff, &stream, bytes, flush, out);
        if (failure != 0) return failure;
    }
    const popped = ip.PopChunk(iff);
    return if (popped != 0) _project.iffError(dl, popped) else 0;
}

/// `bytes` through Deflate, what comes out written as it fills the
/// buffer; with `FLUSH_FINISH`, until the stream has ended. 0, or why
/// not, as a dos code.
fn deflate(dl: *DosBase, ip: *IFFParseBase, cb: *CompressionBase, iff: *iffparse.IFFHandle, stream: *compression.Stream, bytes: []const u8, flush: u32, out: [*]u8) i32 {
    stream.next_in = bytes.ptr;
    stream.avail_in = @intCast(bytes.len);
    while (true) {
        stream.next_out = out;
        stream.avail_out = out_size;
        const left = stream.avail_in;
        const result = cb.Deflate(stream, flush);
        const made: i32 = @intCast(out_size - stream.avail_out);
        if (made != 0) {
            const written = ip.WriteChunkBytes(iff, out, made);
            if (written != made) return _project.iffError(dl, if (written < 0) written else iffparse.IFFERR_WRITE);
        }
        if (result == compression.COMPRESS_END) return 0;
        if (result != compression.COMPRESS_OK) return dos.ERROR_NO_FREE_STORE;
        // Everything taken and room left over: Deflate has done what it
        // will for now - unless the stream is to end.
        if (stream.avail_in == 0 and stream.avail_out != 0 and flush != compression.FLUSH_FINISH) return 0;
        // Room, input and nothing done is a stream that will not go on.
        if (made == 0 and stream.avail_in == left) return dos.ERROR_NO_FREE_STORE;
    }
}
