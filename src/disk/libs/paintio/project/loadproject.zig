// SPDX-License-Identifier: MIT
//! LoadProject: a project read, or a picture of any format datatypes
//! reads, as a project.
//!
//! The file's first twelve bytes say which: `FORM` and `PNTG` are a
//! project, read here with iffparse.library - parsing stops at each of
//! the form's chunks, and a chunk this does not know is passed over -
//! and anything else goes to datatypes (`_picture.zig`). A layer's pixels
//! are unpacked by compression.library's Inflate straight into the
//! memory the layer keeps, and turned from the file's bytes into pixels
//! where they lie.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const iffparse = sdk.iffparse;
const compression = sdk.compression;
const paintio = sdk.paintio;
const DosBase = sdk.interface.dos.DosBase;
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const _base = @import("../paintio_base.zig");
const PaintIOBase = _base.PaintIOBase;
const _project = @import("_project.zig");
const _picture = @import("../picture/_picture.zig");

/// The bytes read from a body at a time, for Inflate.
const in_size = 16 * 1024;

/// Reads a project, or a picture as a project of one layer.
///
/// SYNOPSIS:
/// ```zig
/// fn LoadProject(base: *PaintIOBase, name: [*:0]const u8, project: *paintio.Project) i32
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `name`: the file: a project `SaveProject` wrote, or any picture
///   datatypes reads (PNG, ILBM, JPEG, GIF, ...).
/// - `project`: filled in; what it held before is not looked at.
///
/// RESULT:
/// 0 when the project is filled in, otherwise a dos error code: why the
/// file could not be read (`ERROR_OBJECT_NOT_FOUND`, say),
/// `ERROR_OBJECT_WRONG_TYPE` for a file that is neither a project nor a
/// picture, or a project that is damaged, `ERROR_OBJECT_TOO_LARGE` for a
/// picture with a side above `MAX_SIDE`, `ERROR_NO_FREE_STORE`, or
/// `ERROR_INVALID_RESIDENT_LIBRARY` when a library it needs cannot be
/// opened.
///
/// BEHAVIOR:
/// A project comes back as it was saved: its size, its layers from the
/// bottom with their names, opacity, flags, blend modes and masks, the
/// layer being painted, and its palette with the palette's ranges
/// (since 1.3); `kind` is `PIOKIND_PROJECT`. A picture comes back as a
/// project of one layer of the picture's size, unnamed and wholly
/// opaque, with `kind` `PIOKIND_PICTURE` and, when the file had one, its
/// palette - up to `MAX_PALETTE` colours, each wholly opaque. Pixels are
/// `0xAARRGGBB`, a picture's coverage in the alpha.
///
/// On a failure the project is empty: nothing of it is the caller's to
/// free, though `FreeProject` may still be called.
///
/// CONTEXT:
/// - Waits: yes, for the file system.
/// - Interrupts: not from an interrupt.
/// - Locks: none taken.
/// - Process: a Process; the file is opened on its behalf, and
///   datatypes reads a picture on it.
///
/// OWNERSHIP:
/// The layers, their pixels and their masks are allocated with
/// `AllocVec` and are the caller's, given back with `FreeProject`.
///
/// NOTES:
/// Each layer is the project's size, a row after another with nothing
/// between: four bytes a pixel, and a mask a byte a pixel. A picture is
/// read whole into memory by
/// its datatype first, so it takes about twice its pixels while it is
/// read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeProject`, `SaveProject`
///
/// EXAMPLES:
/// ```zig
/// var project = paintio.Project{};
/// const failure = pio.LoadProject("Work:sky.png", &project);
/// if (failure != 0) {
///     _ = dl.PrintFault(failure, "Work:sky.png");
///     return;
/// }
/// defer pio.FreeProject(&project);
/// ```
pub fn LoadProject(base: *PaintIOBase, name: [*:0]const u8, project: *paintio.Project) i32 {
    project.* = .{};
    const dl = base.dos_base;
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse return dl.IoErr();
    var start: [12]u8 = @splat(0);
    const got = dl.Read(file, &start, start.len);
    var failure: i32 = 0;
    if (got == start.len and isProject(&start)) {
        failure = read(base, file, project);
        _ = dl.Close(file);
    } else {
        _ = dl.Close(file);
        failure = _picture.load(base, name, project);
    }
    if (failure != 0) _base.iface(base).FreeProject(project);
    return failure;
}

fn isProject(start: *const [12]u8) bool {
    return _project.getWord(start[0..4]) == iffparse.ID_FORM and _project.getWord(start[8..12]) == paintio.ID_PNTG;
}

/// The project's form from the open file, its start already read past.
fn read(base: *PaintIOBase, file: *dos.FileHandle, project: *paintio.Project) i32 {
    const sys = base.sys_base;
    const dl = base.dos_base;
    if (dl.Seek(file, 0, dos.OFFSET_BEGINNING) < 0) return dl.IoErr();
    const ip_lib = sys.OpenLibrary(iffparse.IFFPARSENAME, 1) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY;
    defer sys.CloseLibrary(ip_lib);
    const cb_lib = sys.OpenLibrary(compression.COMPRESSIONNAME, 1) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY;
    defer sys.CloseLibrary(cb_lib);
    const ip: *IFFParseBase = @ptrCast(ip_lib);
    const cb: *CompressionBase = @ptrCast(cb_lib);
    const input = sys.AllocVec(in_size, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    defer sys.FreeVec(input);

    const iff = ip.AllocIFF() orelse return dos.ERROR_NO_FREE_STORE;
    defer ip.FreeIFF(iff);
    iff.stream = @intFromPtr(file);
    ip.InitIFFasDOS(iff);
    const opened = ip.OpenIFF(iff, iffparse.IFFF_READ);
    if (opened != 0) return _project.iffError(dl, opened);
    defer ip.CloseIFF(iff);
    const stops = [_]u32{
        paintio.ID_PNTG, paintio.ID_PHDR,
        paintio.ID_PNTG, paintio.ID_PALT,
        paintio.ID_PNTG, paintio.ID_LHDR,
        paintio.ID_PNTG, paintio.ID_BODY,
        paintio.ID_PNTG, paintio.ID_LMSK,
        paintio.ID_PNTG, paintio.ID_CYCL,
    };
    const stopped = ip.StopChunks(iff, &stops, stops.len / 2);
    if (stopped != 0) return _project.iffError(dl, stopped);

    // The layers whose pixels have been read: an LHDR is the next one's.
    var bodies: u32 = 0;
    while (true) {
        const parsed = ip.ParseIFF(iff, iffparse.IFFPARSE_SCAN);
        if (parsed == iffparse.IFFERR_EOF) break;
        if (parsed != 0) return _project.iffError(dl, parsed);
        const context = ip.CurrentChunk(iff) orelse return dos.ERROR_OBJECT_WRONG_TYPE;
        const size: usize = @intCast(@max(context.size, 0));
        switch (context.id) {
            paintio.ID_PHDR => {
                if (project.layers != null) return dos.ERROR_OBJECT_WRONG_TYPE;
                var header: [_project.header_size]u8 = undefined;
                if (ip.ReadChunkBytes(iff, &header, header.len) != header.len) return dos.ERROR_OBJECT_WRONG_TYPE;
                if (!_project.readHeader(&header, project)) return dos.ERROR_OBJECT_WRONG_TYPE;
                const count = project.layer_count;
                project.layer_count = 0;
                const memory = sys.AllocVec(@as(usize, count) * @sizeOf(paintio.Layer), exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
                const layers: [*]paintio.Layer = @ptrCast(@alignCast(memory));
                for (layers[0..count]) |*layer| layer.* = .{};
                project.layers = layers;
                project.layer_count = count;
            },
            paintio.ID_PALT => {
                const count = @min(size / 4, paintio.MAX_PALETTE);
                const bytes: [*]u8 = @ptrCast(&project.palette);
                const length: i32 = @intCast(count * 4);
                if (ip.ReadChunkBytes(iff, bytes, length) != length) return dos.ERROR_OBJECT_WRONG_TYPE;
                _project.fromFile(project.palette[0..count]);
                project.palette_count = @intCast(count);
            },
            paintio.ID_LHDR => {
                const layers = project.layers orelse return dos.ERROR_OBJECT_WRONG_TYPE;
                if (bodies >= project.layer_count) return dos.ERROR_OBJECT_WRONG_TYPE;
                var layer_header: [_project.layer_header_size]u8 = undefined;
                const length: i32 = @intCast(@min(size, layer_header.len));
                if (ip.ReadChunkBytes(iff, &layer_header, length) != length) return dos.ERROR_OBJECT_WRONG_TYPE;
                const pixels = layers[bodies].pixels;
                _project.readLayerHeader(layer_header[0..@intCast(length)], &layers[bodies]);
                layers[bodies].pixels = pixels;
            },
            paintio.ID_BODY => {
                const layers = project.layers orelse return dos.ERROR_OBJECT_WRONG_TYPE;
                if (bodies >= project.layer_count) return dos.ERROR_OBJECT_WRONG_TYPE;
                const count = @as(usize, project.width) * project.height;
                const memory = sys.AllocVec(count * 4, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
                const pixels: [*]u32 = @ptrCast(@alignCast(memory));
                layers[bodies].pixels = pixels;
                const failure = readBody(dl, ip, cb, iff, @ptrCast(pixels), count * 4, @ptrCast(input));
                if (failure != 0) return failure;
                _project.fromFile(pixels[0..count]);
                bodies += 1;
            },
            paintio.ID_CYCL => {
                const bytes: *[paintio.MAX_RANGES * 4]u8 = @ptrCast(&project.ranges);
                const length: i32 = @intCast(@min(size, bytes.len));
                if (ip.ReadChunkBytes(iff, bytes, length) != length) return dos.ERROR_OBJECT_WRONG_TYPE;
            },
            // The mask of the layer whose pixels came last.
            paintio.ID_LMSK => {
                const layers = project.layers orelse return dos.ERROR_OBJECT_WRONG_TYPE;
                if (bodies == 0 or layers[bodies - 1].mask != null) return dos.ERROR_OBJECT_WRONG_TYPE;
                const count = @as(usize, project.width) * project.height;
                const memory = sys.AllocVec(count, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
                const mask: [*]u8 = @ptrCast(memory);
                layers[bodies - 1].mask = mask;
                const failure = readBody(dl, ip, cb, iff, mask, count, @ptrCast(input));
                if (failure != 0) return failure;
            },
            else => {},
        }
    }
    if (project.layers == null or bodies != project.layer_count) return dos.ERROR_OBJECT_WRONG_TYPE;
    project.kind = paintio.PIOKIND_PROJECT;
    return 0;
}

/// A body's or a mask's zlib stream unpacked into `into`, which it must
/// fill exactly:
/// 0, or why not, as a dos code.
fn readBody(dl: *DosBase, ip: *IFFParseBase, cb: *CompressionBase, iff: *iffparse.IFFHandle, into: [*]u8, size: usize, input: [*]u8) i32 {
    var stream = compression.Stream{};
    if (cb.InitInflate(&stream, compression.FORMAT_ZLIB) != compression.COMPRESS_OK) return dos.ERROR_NO_FREE_STORE;
    defer cb.EndInflate(&stream);
    stream.next_out = into;
    stream.avail_out = @intCast(size);
    while (true) {
        if (stream.avail_in == 0) {
            const got = ip.ReadChunkBytes(iff, input, in_size);
            if (got < 0) return _project.iffError(dl, got);
            // The chunk ended before the stream did.
            if (got == 0) return dos.ERROR_OBJECT_WRONG_TYPE;
            stream.next_in = input;
            stream.avail_in = @intCast(got);
        }
        const result = cb.Inflate(&stream, compression.FLUSH_NONE);
        if (result == compression.COMPRESS_END) break;
        if (result == compression.COMPRESSERR_MEMORY) return dos.ERROR_NO_FREE_STORE;
        if (result != compression.COMPRESS_OK) return dos.ERROR_OBJECT_WRONG_TYPE;
        // Full, and more than the layer holds still coming.
        if (stream.avail_out == 0 and stream.avail_in != 0) {
            const again = cb.Inflate(&stream, compression.FLUSH_NONE);
            if (again == compression.COMPRESS_END) break;
            return dos.ERROR_OBJECT_WRONG_TYPE;
        }
    }
    return if (stream.total_out == size) 0 else dos.ERROR_OBJECT_WRONG_TYPE;
}
