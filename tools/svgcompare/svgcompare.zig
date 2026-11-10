// SPDX-License-Identifier: MIT
//! svgcompare: SVG files drawn on the host as svg.datatype draws them,
//! and compared with what another renderer drew - rsvg-convert's, which
//! is what the disk's icons are made with.
//!
//!   svgcompare [--size N] [--detail] [--hash] [--out DIR [--zoom Z]] <file.svg> <drawn.png> ...
//!
//! Each SVG file is drawn N by N pixels (48 if not given), stretched to
//! that as `rsvg-convert -w N -h N` stretches it, with svg.datatype's
//! own reading and drawing (`classes/datatypes/svg/`) and vector.library's
//! module: the same code as on the machine, the library's jump table
//! left out. The PNG beside it is the other renderer's picture.
//!
//! The two are compared premultiplied - a channel times its coverage -
//! so that the colour of what is nearly clear does not count for more
//! than it shows. A line a file says how far apart they are: the mean of
//! every channel's difference and the largest, both as a share of full,
//! and how many pixels are more than a quarter apart somewhere. A file
//! is close enough when its mean is under 1 % and no pixel is more than
//! a quarter apart; the others are listed again at the end.
//!
//! --detail says where a file's largest difference is, and the two
//! colours there. --hash prints the pens of each drawing hashed as
//! `C:test/DTTime` hashes a picture's (FNV-1a, 64 bits, over the pens as
//! little-endian words), so a picture made on a machine can be held
//! against this drawing to the bit. With --out, every file's comparison is written there as a PNG, the
//! three side by side: this drawing, the other one, and the difference
//! four times over, each pixel Z by Z (1 if not given) to be seen.
//!
//! scripts/svg-compare.sh draws the Tango release's files with
//! rsvg-convert and runs this over them.

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
const module = @import("vector");
const svg = @import("svg");
const document = svg.document;
const decode = sdk.datatypes.png.decode;
const Io = std.Io;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("svgcompare: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// vector.library's calls by their names, straight onto its module, for
/// `svg.draw` to call as it calls the library.
const Direct = struct {
    fn pathOf(path: anytype) switch (@TypeOf(path)) {
        *vector.Path => *module.Path,
        *const vector.Path => *const module.Path,
        else => @compileError("a vector.Path pointer"),
    } {
        return @ptrCast(@alignCast(path));
    }

    fn canvasOf(canvas: *vector.Canvas) *module.Canvas {
        return @ptrCast(@alignCast(canvas));
    }

    pub fn ClearPath(_: *Direct, path: *vector.Path) void {
        pathOf(path).clear();
    }
    pub fn MoveTo(_: *Direct, path: *vector.Path, x: f32, y: f32) void {
        pathOf(path).moveTo(.{ .x = x, .y = y });
    }
    pub fn LineTo(_: *Direct, path: *vector.Path, x: f32, y: f32) void {
        pathOf(path).lineTo(.{ .x = x, .y = y });
    }
    pub fn ClosePath(_: *Direct, path: *vector.Path) void {
        pathOf(path).close();
    }
    pub fn AddRect(_: *Direct, path: *vector.Path, rect: *const vector.Rect, rx: f32, ry: f32) void {
        module.shapes.addRect(pathOf(path), rect.*, rx, ry);
    }
    pub fn AddEllipse(_: *Direct, path: *vector.Path, cx: f32, cy: f32, rx: f32, ry: f32) void {
        module.shapes.addEllipse(pathOf(path), .{ .x = cx, .y = cy }, rx, ry);
    }
    pub fn AddPathData(_: *Direct, path: *vector.Path, text: [*]const u8, length: u32) i32 {
        return module.pathdata.add(pathOf(path), text[0..length]);
    }
    pub fn AddSegments(_: *Direct, path: *vector.Path, verbs: [*]const u8, verb_count: u32, points: [*]const vector.Point, point_count: u32) i32 {
        return pathOf(path).addSegments(verbs[0..verb_count], points[0..point_count]);
    }
    pub fn PathBounds(_: *Direct, path: *const vector.Path, matrix: ?*const vector.Matrix, bounds: *vector.Rect) bool {
        bounds.* = module.bounds(pathOf(path), if (matrix) |m| m.* else .{}) orelse return false;
        return true;
    }
    pub fn FillPath(_: *Direct, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, rule: u32) i32 {
        return canvasOf(canvas).fill(pathOf(path), if (matrix) |m| m.* else .{}, paint, rule);
    }
    pub fn StrokePath(_: *Direct, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, stroke: *const vector.Stroke) i32 {
        return canvasOf(canvas).stroke(pathOf(path), if (matrix) |m| m.* else .{}, paint, stroke);
    }
    pub fn PushLayer(_: *Direct, canvas: *vector.Canvas, opacity: f32) i32 {
        return canvasOf(canvas).pushLayer(opacity);
    }
    pub fn PopLayer(_: *Direct, canvas: *vector.Canvas) void {
        canvasOf(canvas).popLayer();
    }
};

/// The module's memory from the host's.
const memory = module.Memory{ .allocFn = hostAlloc, .freeFn = hostFree };

fn hostAlloc(_: ?*anyopaque, bytes: usize) ?[*]align(8) u8 {
    const block = std.heap.page_allocator.alignedAlloc(u8, .@"8", bytes) catch return null;
    return block.ptr;
}

fn hostFree(_: ?*anyopaque, block: [*]align(8) u8, bytes: usize) void {
    std.heap.page_allocator.free(block[0..bytes]);
}

/// A picture as bytes of red, green, blue and coverage.
const Picture = struct {
    width: u32,
    height: u32,
    rgba: []u8,
};

/// `text` drawn `size` by `size`; null when it is not SVG.
fn drawSvg(gpa: std.mem.Allocator, text: []u8, size: u32) !?Picture {
    const counts = document.count(text) orelse return null;
    const bytes = document.bytesFor(counts);
    const block = try gpa.alignedAlloc(u8, .@"8", @max(bytes, 8));
    defer gpa.free(block);
    const doc = document.build(text, counts, block[0..bytes]);
    const pens = try gpa.alloc(sdk.graphics.Pen, @as(usize, size) * size);
    defer gpa.free(pens);
    @memset(pens, 0);
    const canvas = module.Canvas.create(memory, size, size) orelse return error.OutOfMemory;
    defer canvas.destroy();
    canvas.setPens(pens.ptr, size * 4);
    const path = module.Path.create(memory) orelse return error.OutOfMemory;
    defer path.destroy();
    const work = try gpa.create(svg.Work);
    defer gpa.destroy(work);
    const intrinsic = svg.intrinsic(&doc);
    var direct = Direct{};
    svg.draw(&direct, &doc, @ptrCast(canvas), @ptrCast(path), work, svg.baseMatrix(intrinsic, size, size), intrinsic.viewport);
    const rgba = try gpa.alloc(u8, pens.len * 4);
    for (pens, 0..) |pen, i| {
        rgba[i * 4 + 0] = @truncate(pen >> 16);
        rgba[i * 4 + 1] = @truncate(pen >> 8);
        rgba[i * 4 + 2] = @truncate(pen);
        rgba[i * 4 + 3] = @truncate(pen >> 24);
    }
    return .{ .width = size, .height = size, .rgba = rgba };
}

/// FNV-1a, 64 bits, over the pens - 0xAARRGGBB - as little-endian
/// words: `C:test/DTTime`'s hash of a picture.
fn pensHash(rgba: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        for ([4]u8{ rgba[i + 2], rgba[i + 1], rgba[i], rgba[i + 3] }) |byte| {
            h ^= byte;
            h *%= 0x100000001b3;
        }
    }
    return h;
}

/// A PNG of one pass - what rsvg-convert writes - as RGBA.
fn readPng(gpa: std.mem.Allocator, file: []const u8) !Picture {
    const info = try decode.readInfo(file);
    if (info.interlace != 0) return error.Interlaced;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    var plte: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var walk = try decode.Walk.start(file);
    while (try walk.next()) |chunk| switch (chunk.id) {
        decode.ID_PLTE => plte = chunk.data,
        decode.ID_TRNS => trns = chunk.data,
        decode.ID_IDAT => try joined.appendSlice(gpa, chunk.data),
        decode.ID_IEND => break,
        else => {},
    };
    var palette = decode.Palette{};
    try decode.readPalette(info, &palette, plte, trns);
    var reader: Io.Reader = .fixed(joined.items);
    var raw: Io.Writer.Allocating = .init(gpa);
    defer raw.deinit();
    var unpacker: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
    _ = try unpacker.reader.streamRemaining(&raw.writer);
    const stride = info.rowBytes(info.width);
    const rows = raw.written();
    if (rows.len < @as(usize, info.height) * (stride + 1)) return error.Truncated;
    const zero = try gpa.alloc(u8, stride);
    defer gpa.free(zero);
    @memset(zero, 0);
    const rgba = try gpa.alloc(u8, @as(usize, info.width) * info.height * 4);
    for (0..info.height) |y| {
        const row = rows[y * (stride + 1) ..][0 .. stride + 1];
        const above = if (y == 0) zero else rows[(y - 1) * (stride + 1) + 1 ..][0..stride];
        try decode.unfilter(row[0], row[1..], above, info.pixelBytes());
        decode.expand(info, &palette, row[1..], info.width, rgba[y * info.width * 4 ..][0 .. info.width * 4]);
    }
    return .{ .width = info.width, .height = info.height, .rgba = rgba };
}

/// How far apart two pictures of one size are.
const Difference = struct {
    mean: f64,
    largest: u32,
    far: u32,
    /// Where the largest is.
    at: usize = 0,

    fn closeEnough(d: Difference) bool {
        return d.mean < 1.0 and d.largest <= 64;
    }
};

fn premultiplied(rgba: []const u8, i: usize, channel: usize) u32 {
    const a: u32 = rgba[i * 4 + 3];
    if (channel == 3) return a;
    return (@as(u32, rgba[i * 4 + channel]) * a + 127) / 255;
}

fn compare(ours: Picture, theirs: Picture, side: ?[]u8) Difference {
    var sum: u64 = 0;
    var largest: u32 = 0;
    var far: u32 = 0;
    var at: usize = 0;
    const pixels = @as(usize, ours.width) * ours.height;
    for (0..pixels) |i| {
        var most: u32 = 0;
        for (0..4) |c| {
            const a = premultiplied(ours.rgba, i, c);
            const b = premultiplied(theirs.rgba, i, c);
            const d = if (a > b) a - b else b - a;
            sum += d;
            most = @max(most, d);
        }
        if (most > largest) {
            largest = most;
            at = i;
        }
        if (most > 64) far += 1;
        if (side) |out| {
            // The three side by side, the difference four times over.
            const w = ours.width;
            const x = i % w;
            const y = i / w;
            const row = out[y * w * 3 * 4 ..];
            @memcpy(row[x * 4 ..][0..4], ours.rgba[i * 4 ..][0..4]);
            @memcpy(row[(w + x) * 4 ..][0..4], theirs.rgba[i * 4 ..][0..4]);
            const shown: u8 = @intCast(@min(most * 4, 255));
            row[(2 * w + x) * 4 ..][0..4].* = .{ shown, shown, shown, 255 };
        }
    }
    return .{
        .mean = @as(f64, @floatFromInt(sum)) * 100 / (@as(f64, @floatFromInt(pixels)) * 4 * 255),
        .largest = largest,
        .far = far,
        .at = at,
    };
}

/// Each pixel `zoom` by `zoom`; the same block for a zoom of 1.
fn zoomed(gpa: std.mem.Allocator, rgba: []u8, width: u32, height: u32, zoom: u32) ![]u8 {
    if (zoom == 1) return rgba;
    const out = try gpa.alloc(u8, @as(usize, width) * height * zoom * zoom * 4);
    const w = width * zoom;
    for (0..height * zoom) |y| {
        for (0..w) |x| {
            const from = ((y / zoom) * width + x / zoom) * 4;
            @memcpy(out[(y * w + x) * 4 ..][0..4], rgba[from..][0..4]);
        }
    }
    return out;
}

/// A PNG of RGBA, its rows kept as they are (filter 0) and stored, not
/// compressed: for looking at, not for keeping.
fn writePng(gpa: std.mem.Allocator, io: Io, path: []const u8, width: u32, height: u32, rgba: []const u8) !void {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..height) |y| {
        try raw.append(gpa, 0);
        try raw.appendSlice(gpa, rgba[y * width * 4 ..][0 .. width * 4]);
    }
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var at: usize = 0;
    while (true) {
        const n: u16 = @intCast(@min(raw.items.len - at, 65535));
        const last = at + n == raw.items.len;
        try z.append(gpa, if (last) 1 else 0);
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, n)));
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~n)));
        try z.appendSlice(gpa, raw.items[at..][0..n]);
        at += n;
        if (last) break;
    }
    try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, &decode.signature);
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8..13].* = .{ 8, 6, 0, 0, 0 };
    try putChunk(gpa, &out, "IHDR", &header);
    try putChunk(gpa, &out, "IDAT", z.items);
    try putChunk(gpa, &out, "IEND", &.{});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

fn putChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), id: *const [4]u8, data: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try out.appendSlice(gpa, &length);
    try out.appendSlice(gpa, id);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(id);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(gpa, &sum);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(arena);
    var size: u32 = 48;
    var out_dir: ?[]const u8 = null;
    var zoom: u32 = 1;
    var detail = false;
    var hash = false;
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--size") and i + 1 < args.len) {
            i += 1;
            size = std.fmt.parseInt(u32, args[i], 10) catch fatal("{s}: not a size", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--detail")) {
            detail = true;
        } else if (std.mem.eql(u8, args[i], "--hash")) {
            hash = true;
        } else if (std.mem.eql(u8, args[i], "--zoom") and i + 1 < args.len) {
            i += 1;
            zoom = std.fmt.parseInt(u32, args[i], 10) catch fatal("{s}: not a zoom", .{args[i]});
            if (zoom == 0 or zoom > 16) fatal("{s}: a zoom of 1 to 16", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else try files.append(arena, args[i]);
    }
    if (files.items.len == 0 or files.items.len % 2 != 0 or size == 0 or size > 4096) {
        fatal("usage: svgcompare [--size N] [--out DIR] <file.svg> <drawn.png> ...", .{});
    }
    const cwd = Io.Dir.cwd();
    var close: u32 = 0;
    var failed: std.ArrayList([]const u8) = .empty;
    var mean_sum: f64 = 0;
    var pair: usize = 0;
    while (pair < files.items.len) : (pair += 2) {
        const svg_path = files.items[pair];
        const png_path = files.items[pair + 1];
        const name = std.fs.path.stem(svg_path);
        const text = cwd.readFileAlloc(io, svg_path, gpa, .limited(16 << 20)) catch |e| fatal("{s}: {t}", .{ svg_path, e });
        defer gpa.free(text);
        const ours = (try drawSvg(gpa, text, size)) orelse {
            std.debug.print("{s:<40} not SVG to this reader\n", .{name});
            try failed.append(arena, name);
            continue;
        };
        defer gpa.free(ours.rgba);
        const reference = cwd.readFileAlloc(io, png_path, gpa, .limited(64 << 20)) catch |e| fatal("{s}: {t}", .{ png_path, e });
        defer gpa.free(reference);
        const theirs = readPng(gpa, reference) catch |e| fatal("{s}: {t}", .{ png_path, e });
        defer gpa.free(theirs.rgba);
        if (theirs.width != size or theirs.height != size) fatal("{s}: {d}x{d}, not {d}x{d}", .{ png_path, theirs.width, theirs.height, size, size });
        var side: ?[]u8 = null;
        if (out_dir != null) {
            side = try gpa.alloc(u8, @as(usize, size) * size * 3 * 4);
        }
        defer if (side) |s| gpa.free(s);
        const d = compare(ours, theirs, side);
        mean_sum += d.mean;
        const ok = d.closeEnough();
        if (ok) close += 1 else try failed.append(arena, name);
        std.debug.print("{s:<40} mean {d:>5.2} %  largest {d:>5.1} %  {d:>5} pixels a quarter apart  {s}\n", .{
            name,
            d.mean,
            @as(f64, @floatFromInt(d.largest)) * 100 / 255,
            d.far,
            if (ok) "close" else "FAR",
        });
        if (hash) std.debug.print("    pens {x:0>16}\n", .{pensHash(ours.rgba)});
        if (detail and d.largest > 64) {
            const x = d.at % size;
            const y = d.at / size;
            std.debug.print("    largest at {d},{d}: ours {x:0>2}{x:0>2}{x:0>2}/{x:0>2}, theirs {x:0>2}{x:0>2}{x:0>2}/{x:0>2}\n", .{
                x,                         y,
                ours.rgba[d.at * 4],       ours.rgba[d.at * 4 + 1],
                ours.rgba[d.at * 4 + 2],   ours.rgba[d.at * 4 + 3],
                theirs.rgba[d.at * 4],     theirs.rgba[d.at * 4 + 1],
                theirs.rgba[d.at * 4 + 2], theirs.rgba[d.at * 4 + 3],
            });
        }
        if (out_dir) |dir| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}.png", .{ dir, name });
            const shown = try zoomed(gpa, side.?, size * 3, size, zoom);
            defer if (zoom != 1) gpa.free(shown);
            try writePng(gpa, io, path, size * 3 * zoom, size * zoom, shown);
        }
    }
    const count = files.items.len / 2;
    std.debug.print("\n{d} of {d} close enough, mean of the means {d:.2} %\n", .{ close, count, mean_sum / @as(f64, @floatFromInt(count)) });
    if (failed.items.len != 0) {
        std.debug.print("not close enough:", .{});
        for (failed.items) |name| std.debug.print(" {s}", .{name});
        std.debug.print("\n", .{});
    }
}
