// SPDX-License-Identifier: MIT
//! svgcompare: SVG files drawn on the host as svg.datatype draws them,
//! and compared with what another renderer drew - rsvg-convert's, which
//! is what the disk's icons are made with.
//!
//!   svgcompare [--size N|WxH] [--detail] [--hash] [--fonts DIR] [--out DIR [--zoom Z]] <file.svg> <drawn.png> ...
//!
//! Each SVG file is drawn N by N pixels (48 if not given), or W by H,
//! stretched to that as `rsvg-convert -w N -h N` stretches it, with svg.datatype's
//! own reading and drawing (`classes/datatypes/svg/`) and vector.library's
//! module: the same code as on the machine, the library's jump table
//! left out. The PNG beside it is the other renderer's picture.
//!
//! Text is drawn in the fonts of --fonts, a directory of font files -
//! resvg's tests' - each a family by the name it gives itself, and a
//! face of it chosen for a span as diskfont.library chooses one: the
//! generic families are resvg's tests' (Noto Serif, Noto Sans, Noto
//! Mono, Yellowtail, Sedgwick Ave Display), and the disk's `sans`,
//! `serif` and `mono` Noto's. The fonts are read by truetype.library's
//! own code and shaped by truetypeshaping.library's, and without
//! --fonts text is left out. A
//! picture of a `data:` address, or of a file an address names from the
//! SVG file's directory, is drawn when it is a PNG, a GIF, a JPEG the
//! disk's jpeg.datatype reads, or an SVG document.
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
const tt = @import("truetype");
const shaping = @import("shaping");
const truetype = sdk.truetype;
const tts = sdk.truetypeshaping;
const diskfont = sdk.diskfont;
const graphics = sdk.graphics;
const document = svg.document;
const decode = sdk.datatypes.png.decode;
const gif = @import("gif");
const lzw = @import("lzw");
const jpeg = @import("jpeg");
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
        bounds.* = module.bounds(pathOf(path), if (matrix) |given| given.* else .{}) orelse return false;
        return true;
    }
    pub fn FillPath(_: *Direct, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, rule: u32) i32 {
        return canvasOf(canvas).fill(pathOf(path), if (matrix) |given| given.* else .{}, paint, rule);
    }
    pub fn StrokePath(_: *Direct, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, stroke: *const vector.Stroke) i32 {
        return canvasOf(canvas).stroke(pathOf(path), if (matrix) |given| given.* else .{}, paint, stroke);
    }
    pub fn PushLayer(_: *Direct, canvas: *vector.Canvas, opacity: f32) i32 {
        return canvasOf(canvas).pushLayer(opacity);
    }
    pub fn PopLayer(_: *Direct, canvas: *vector.Canvas) void {
        canvasOf(canvas).popLayer();
    }
    pub fn PushClip(_: *Direct, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, rule: u32) i32 {
        return canvasOf(canvas).pushClip(pathOf(path), if (matrix) |given| given.* else .{}, rule);
    }
    pub fn PopClip(_: *Direct, canvas: *vector.Canvas) void {
        canvasOf(canvas).popClip();
    }
    pub fn BeginMask(_: *Direct, canvas: *vector.Canvas) i32 {
        return canvasOf(canvas).beginMask();
    }
    pub fn EndMask(_: *Direct, canvas: *vector.Canvas, kind: u32) i32 {
        return canvasOf(canvas).endMask(kind);
    }
    pub fn BlurLayer(_: *Direct, canvas: *vector.Canvas, deviation_x: f32, deviation_y: f32) i32 {
        return canvasOf(canvas).blurLayer(deviation_x, deviation_y);
    }
    pub fn PushBlendLayer(_: *Direct, canvas: *vector.Canvas, opacity: f32, mode: u32) i32 {
        return canvasOf(canvas).pushBlendLayer(opacity, mode);
    }
    pub fn FilterLayer(_: *Direct, canvas: *vector.Canvas, primitives: [*]const vector.FilterPrimitive, count: u32, region: *const vector.Rect) i32 {
        return canvasOf(canvas).filterLayer(primitives[0..count], region.*);
    }
    pub fn PathLength(_: *Direct, path: *const vector.Path, matrix: ?*const vector.Matrix) f32 {
        return module.measure.length(pathOf(path), if (matrix) |given| given.* else .{});
    }
    pub fn PathPointAt(_: *Direct, path: *const vector.Path, matrix: ?*const vector.Matrix, distance: f32, point: *vector.Point, angle: *f32) bool {
        const place = module.measure.pointAt(pathOf(path), if (matrix) |given| given.* else .{}, distance) orelse return false;
        point.* = place.point;
        angle.* = place.angle;
        return true;
    }
    pub fn PathVertices(_: *Direct, path: *const vector.Path, vertices: ?[*]vector.Vertex, room: u32) u32 {
        var no_room: [0]vector.Vertex = .{};
        const out: []vector.Vertex = if (vertices) |all| all[0..room] else &no_room;
        return module.measure.vertices(pathOf(path), out);
    }
    /// A canvas on the pens the tags give, as `CreateCanvasTagList`
    /// makes one.
    pub fn CreateCanvasTagList(_: *Direct, tags: ?[*]const sdk.utility.TagItem) ?*vector.Canvas {
        var width: u32 = 0;
        var height: u32 = 0;
        var pens: ?[*]sdk.graphics.Pen = null;
        var bytes_per_row: u32 = 0;
        var at = tags orelse return null;
        while (at[0].tag != sdk.utility.TAG_DONE) : (at += 1) {
            const data: u32 = @truncate(at[0].data);
            switch (at[0].tag) {
                vector.VCA_Width => width = data,
                vector.VCA_Height => height = data,
                vector.VCA_Pens => pens = @ptrFromInt(at[0].data),
                vector.VCA_BytesPerRow => bytes_per_row = data,
                else => {},
            }
        }
        const canvas = module.Canvas.create(memory, width, height) orelse return null;
        canvas.setPens(pens, if (bytes_per_row != 0) bytes_per_row else width * 4);
        return @ptrCast(canvas);
    }
    pub fn CreatePath(_: *Direct) ?*vector.Path {
        return @ptrCast(module.Path.create(memory) orelse return null);
    }
    pub fn DisposePath(_: *Direct, path: ?*vector.Path) void {
        if (path) |made| pathOf(made).destroy();
    }
    pub fn DisposeCanvas(_: *Direct, canvas: ?*vector.Canvas) void {
        if (canvas) |made| canvasOf(made).destroy();
    }
};

/// Fonts and pictures for `svg.draw`, as svg.datatype has them from
/// diskfont.library, truetype.library, truetypeshaping.library and
/// datatypes.library: the faces of Liberation's files, read by
/// truetype.library's code and shaped by truetypeshaping.library's, and
/// PNGs.
const Sources = struct {
    io: Io,
    /// Liberation's directory; null for no text.
    fonts: ?[]const u8,
    /// The directory of the SVG file being drawn, which the relative
    /// addresses of its pictures start at.
    directory: []const u8 = ".",
    opened: std.ArrayList(Opened) = .empty,
    files: ?[]const FontFile = null,

    /// One font file of --fonts, as diskfont.library lists it: the
    /// family its fonts give themselves, how heavy and how wide it is
    /// drawn, and whether it leans.
    const FontFile = struct {
        family: []const u8,
        bytes: []const u8,
        weight: u16,
        stretch: u16,
        italic: bool,
    };

    /// The faces opened, by the family and what was asked.
    const Opened = struct {
        family: []const u8,
        want: svg.Want,
        face: ?*diskfont.OutlineFont,
    };

    /// The generic families as resvg's tests set them.
    const generics = [_][]const u8{ "Noto Serif", "Noto Sans", "Noto Mono", "Yellowtail", "Sedgwick Ave Display" };
    /// The disk's own names of the three, a disk without the others'
    /// fallen back to.
    const disk_families = [_]struct { font: []const u8, family: []const u8 }{
        .{ .font = "serif", .family = "Noto Serif" },
        .{ .font = "sans", .family = "Noto Sans" },
        .{ .font = "mono", .family = "Noto Mono" },
    };

    fn fontOf(outline: *truetype.Outline) *const tt.outline.Font {
        return @ptrCast(@alignCast(outline));
    }

    /// The font files of --fonts, read the first time they are asked
    /// for.
    fn fontFiles(s: *Sources) []const FontFile {
        if (s.files) |files| return files;
        s.files = &.{};
        const dir_path = s.fonts orelse return &.{};
        const gpa = std.heap.page_allocator;
        var list: std.ArrayList(FontFile) = .empty;
        var dir = Io.Dir.cwd().openDir(s.io, dir_path, .{ .iterate = true }) catch return &.{};
        defer dir.close(s.io);
        var it = dir.iterate();
        while (it.next(s.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".ttf") and !std.mem.endsWith(u8, entry.name, ".otf")) continue;
            const bytes = dir.readFileAlloc(s.io, entry.name, gpa, .limited(32 << 20)) catch continue;
            const font = gpa.create(tt.outline.Font) catch continue;
            if (!tt.outline.open(font, bytes.ptr, @intCast(bytes.len), 0, null, 0)) continue;
            var called: [64]u8 = undefined;
            var len = tt.names.nameOf(font, truetype.TTNAME_TYPO_FAMILY, &called, called.len);
            if (len == 0) len = tt.names.nameOf(font, truetype.TTNAME_FAMILY, &called, called.len);
            if (len == 0) continue;
            const family = gpa.dupe(u8, called[0..@min(len, called.len - 1)]) catch continue;
            list.append(gpa, .{
                .family = family,
                .bytes = bytes,
                .weight = font.weight,
                .stretch = font.stretch,
                .italic = font.style & graphics.FSF_ITALIC != 0,
            }) catch continue;
        }
        s.files = list.items;
        return list.items;
    }

    /// A family by its fonts' name, as diskfont.library's `FindFamily`
    /// finds it: its name and ".font".
    pub fn FindFamily(s: *Sources, name: [*:0]const u8, into: [*]u8, size: u32) bool {
        const asked = std.mem.span(name);
        for (s.fontFiles()) |file| {
            if (std.ascii.eqlIgnoreCase(file.family, asked)) return named(file.family, into, size);
        }
        return false;
    }

    /// The generic families resvg's tests are drawn with.
    pub fn GenericFamily(_: *Sources, generic: u32, into: [*]u8, size: u32) bool {
        if (generic >= generics.len) return false;
        return named(generics[generic], into, size);
    }

    fn named(family: []const u8, into: [*]u8, size: u32) bool {
        const suffix = ".font";
        if (size < family.len + suffix.len + 1) return false;
        @memcpy(into[0..family.len], family);
        @memcpy(into[family.len..][0..suffix.len], suffix);
        into[family.len + suffix.len] = 0;
        return true;
    }

    /// A family's face nearest `want`, as diskfont.library's
    /// `OpenOutlineFontTagList` chooses it, opened once and kept.
    pub fn OpenFace(s: *Sources, name: [*:0]const u8, want: *const svg.Want) ?*diskfont.OutlineFont {
        const n = std.mem.span(name);
        for (s.opened.items) |o| {
            if (o.want.same(want) and std.mem.eql(u8, o.family, n)) return o.face;
        }
        const gpa = std.heap.page_allocator;
        const face = s.load(n, want);
        s.opened.append(gpa, .{ .family = gpa.dupe(u8, n) catch return null, .want = want.*, .face = face }) catch return null;
        return face;
    }

    fn load(s: *Sources, name: []const u8, want: *const svg.Want) ?*diskfont.OutlineFont {
        const gpa = std.heap.page_allocator;
        if (s.fonts == null) return null;
        for (fallbacks) |family| {
            if (!std.mem.eql(u8, family.font, name)) continue;
            const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ s.fonts.?, family.file }) catch return null;
            const bytes = Io.Dir.cwd().readFileAlloc(s.io, path, gpa, .limited(16 << 20)) catch return null;
            return outlineOf(bytes, want, 400);
        }
        var family = if (std.mem.endsWith(u8, name, ".font")) name[0 .. name.len - 5] else name;
        for (disk_families) |own| {
            if (std.mem.eql(u8, own.font, family)) family = own.family;
        }
        // CSS's choice: the nearest width, the slant, the nearest weight.
        var best: ?*const FontFile = null;
        var best_rank: u64 = 0;
        for (s.fontFiles()) |*file| {
            if (!std.ascii.eqlIgnoreCase(file.family, family)) continue;
            const rank = rankOf(want, file);
            if (best != null and rank >= best_rank) continue;
            best = file;
            best_rank = rank;
        }
        const file = best orelse return null;
        return outlineOf(file.bytes, want, file.weight);
    }

    fn rankOf(want: *const svg.Want, file: *const FontFile) u64 {
        const stretch: u64 = stretchRank(want.stretch, file.stretch);
        const slant: u64 = if (file.italic == want.italic) 0 else 1;
        const weight: u64 = weightRank(want.weight, file.weight);
        return (stretch << 34) | (slant << 33) | weight;
    }

    fn stretchRank(asked: u16, have: u16) u32 {
        if (have == asked) return 0;
        if ((have < asked) == (asked <= 1000)) return distance(asked, have);
        return 0x10000 + distance(asked, have);
    }

    fn weightRank(asked: u16, have: u16) u32 {
        if (asked >= 400 and asked <= 500) {
            if (have >= asked and have <= 500) return distance(asked, have);
            if (have < asked) return 0x1000 + distance(asked, have);
            return 0x2000 + distance(asked, have);
        }
        if (asked < 400) return if (have <= asked) distance(asked, have) else 0x1000 + distance(asked, have);
        return if (have >= asked) distance(asked, have) else 0x1000 + distance(asked, have);
    }

    fn distance(a: u16, b: u16) u32 {
        return if (a > b) a - b else b - a;
    }

    /// A font file's bytes read as an outline, a variable one set where
    /// `want` asks - the weight and width first, then its own values,
    /// the later winning - and told bold and italic as diskfont.library
    /// tells them.
    fn outlineOf(bytes: []const u8, want: *const svg.Want, weight: u16) ?*diskfont.OutlineFont {
        const gpa = std.heap.page_allocator;
        var listed: [svg.max_axes + 1]truetype.AxisValue = undefined;
        const listed_count = want.axesInto(&listed);
        var values: [svg.max_axes + 3]truetype.AxisValue = undefined;
        values[0] = .{ .tag = truetype.tableTag("wght"), .value = @floatFromInt(want.weight) };
        values[1] = .{ .tag = truetype.tableTag("wdth"), .value = @as(f32, @floatFromInt(want.stretch)) / 10 };
        var count: usize = 2;
        for (listed[0..listed_count]) |one| {
            const at = for (values[0..count], 0..) |have, index| {
                if (have.tag == one.tag) break index;
            } else count;
            values[at] = one;
            if (at == count) count += 1;
        }
        const font = gpa.create(tt.outline.Font) catch return null;
        if (!tt.outline.open(font, bytes.ptr, @intCast(bytes.len), 0, &values, @intCast(count))) return null;
        var style = font.style & graphics.FSF_ITALIC;
        const axes = font.vary.axis_count;
        var drawn_weight = weight;
        for (0..axes) |index| {
            const axis = tt.variation.axisOf(font, @intCast(index));
            if (axis.tag == truetype.tableTag("wght")) drawn_weight = font.weight;
            if (axis.tag == truetype.tableTag("slnt") and axis.value != 0) style |= graphics.FSF_ITALIC;
            if (axis.tag == truetype.tableTag("ital") and axis.value >= 0.5) style |= graphics.FSF_ITALIC;
        }
        if (drawn_weight >= 600) style |= graphics.FSF_BOLD;
        const outline = gpa.create(diskfont.OutlineFont) catch return null;
        outline.* = .{ .outline = @ptrCast(font), .style = style };
        return outline;
    }

    pub fn FontAxes(_: *Sources, outline: *truetype.Outline, axes: ?[*]truetype.Axis, room: u32) u32 {
        const font = fontOf(outline);
        const count = font.vary.axis_count;
        if (axes) |into| {
            var index: u32 = 0;
            while (index < count and index < room) : (index += 1) into[index] = tt.variation.axisOf(font, index);
        }
        return count;
    }

    pub fn CloseFace(_: *Sources, _: *diskfont.OutlineFont) void {}

    /// The families a character is looked for in that its font lacks,
    /// as a disk's font.prefs might name them, each one of the test
    /// fonts.
    const fallbacks = [_]struct { font: []const u8, file: []const u8 }{
        .{ .font = "devanagari.font", .file = "NotoSansDevanagari-Regular.ttf" },
        .{ .font = "cjk-jp.font", .file = "MPLUS1p-Regular.ttf" },
        .{ .font = "arabic.font", .file = "Amiri-Regular.ttf" },
        .{ .font = "malayalam.font", .file = "NotoSansMalayalam-Regular.ttf" },
    };

    pub fn FallbackFamily(_: *Sources, index: u32, name: [*]u8, size: u32) bool {
        if (index >= fallbacks.len) return false;
        const family = fallbacks[index].font;
        if (size < family.len + 1) return false;
        @memcpy(name[0..family.len], family);
        name[family.len] = 0;
        return true;
    }
    pub fn GlyphIndex(_: *Sources, outline: *truetype.Outline, code: u32) u32 {
        return tt.outline.glyphIndex(fontOf(outline), code);
    }
    /// English, as the tests are drawn for.
    pub fn UserLanguage(_: *Sources, index: u32) ?[*:0]const u8 {
        return if (index == 0) "en" else null;
    }

    /// A block's length is kept in the 16 bytes before it.
    const block_header = 16;

    fn allocate(_: *anyopaque, bytes: usize) ?[*]u8 {
        const block = std.heap.page_allocator.alignedAlloc(u8, .@"16", bytes + block_header) catch return null;
        const length: *usize = @ptrCast(block.ptr);
        length.* = block.len;
        return block.ptr + block_header;
    }
    fn release(_: *anyopaque, block: [*]u8) void {
        const start: [*]align(16) u8 = @alignCast(block - block_header);
        const length: *usize = @ptrCast(start);
        std.heap.page_allocator.free(start[0..length.*]);
    }
    fn fontIn(context: *anyopaque) *const tt.outline.Font {
        return @ptrCast(@alignCast(context));
    }
    fn advanceOf(context: *anyopaque, glyph: u32) i32 {
        return tt.outline.advanceOf(fontIn(context), glyph);
    }
    fn kerningOf(context: *anyopaque, left: u32, right: u32) i32 {
        return tt.outline.kerningOf(fontIn(context), left, right);
    }
    fn glyphOf(context: *anyopaque, char: u32) u32 {
        return tt.outline.glyphIndex(fontIn(context), char);
    }
    fn variantOf(context: *anyopaque, char: u32, selector: u32) u32 {
        return tt.outline.glyphVariant(fontIn(context), char, selector);
    }
    fn tableOf(font: *const tt.outline.Font, comptime letters: *const [4]u8) []const u8 {
        const table = tt.outline.findTableByTag(font, truetype.tableTag(letters)) orelse return &.{};
        return (font.data + table.at)[0..table.len];
    }

    /// A text shaped as truetypeshaping.library's `ShapeText` shapes it,
    /// with the font's tables and what truetype.library's code reads
    /// from it.
    pub fn ShapeText(_: *Sources, outline: *truetype.Outline, text: []const u8, direction: u32, language: u32, features: ?[*]const tts.Feature, run: *tts.ShapedRun) i32 {
        const font = fontOf(outline);
        const context: *anyopaque = @ptrCast(@constCast(font));
        var feature_count: usize = 0;
        if (features) |list| {
            while (list[feature_count].tag != 0) feature_count += 1;
        }
        const request: shaping.text.Text = .{
            .memory = .{ .context = context, .allocFn = allocate, .freeFn = release },
            .font = .{
                .gdef = .{ .bytes = tableOf(font, "GDEF") },
                .gsub = .{ .bytes = tableOf(font, "GSUB") },
                .gpos = .{ .bytes = tableOf(font, "GPOS") },
                .context = context,
                .advanceFn = advanceOf,
                .kerningFn = kerningOf,
                .glyphFn = glyphOf,
                .variantFn = variantOf,
            },
            .bytes = text,
            .backward = direction == tts.TTS_RIGHT_TO_LEFT,
            .language = language,
            .features = if (features) |list| list[0..feature_count] else &.{},
        };
        return shaping.text.shapeText(&request, run);
    }
    /// A text's bidirectional levels as truetypeshaping.library's
    /// `BidiLevels` finds them.
    pub fn BidiLevels(_: *Sources, text: []const u8, direction: u32, levels: []u8) i32 {
        const base: shaping.bidi.Base = switch (direction) {
            tts.TTS_LEFT_TO_RIGHT => .left_to_right,
            tts.TTS_RIGHT_TO_LEFT => .right_to_left,
            else => .first_strong,
        };
        var context: u8 = 0;
        const lender: shaping.buffer.Memory = .{ .context = &context, .allocFn = allocate, .freeFn = release };
        if (!shaping.bidi.resolve(lender, text, base, levels)) return tts.TTSERR_NOMEM;
        return tts.TTS_OK;
    }
    pub fn GlyphMetrics(_: *Sources, outline: *truetype.Outline, glyph: u32, metrics: *truetype.GlyphMetrics) bool {
        const font = fontOf(outline);
        metrics.* = .{};
        if (glyph >= font.glyph_count) return false;
        const box = tt.outline.boxOf(font, glyph);
        metrics.* = .{
            .advance = tt.outline.advanceOf(font, glyph),
            .left_bearing = tt.outline.leftBearingOf(font, glyph),
            .x_min = box[0],
            .y_min = box[1],
            .x_max = box[2],
            .y_max = box[3],
        };
        return true;
    }
    pub fn GlyphVerticalMetrics(s: *Sources, outline: *truetype.Outline, glyph: u32, metrics: *truetype.VerticalMetrics) bool {
        const font = fontOf(outline);
        metrics.* = .{};
        var box: truetype.GlyphMetrics = undefined;
        if (!s.GlyphMetrics(outline, glyph, &box)) return false;
        var measures: truetype.FontMetrics = undefined;
        s.FontMetrics(outline, &measures);
        metrics.* = tt.vertical.measure(font, glyph, &box, &measures);
        return true;
    }
    pub fn GlyphSegments(_: *Sources, outline: *truetype.Outline, glyph: u32, out: *truetype.Segments) i32 {
        const font = fontOf(outline);
        out.verb_count = 0;
        out.point_count = 0;
        if (glyph >= font.glyph_count) return truetype.TRUETYPEERR_GLYPH;
        const gpa = std.heap.page_allocator;
        const points = gpa.alloc(tt.outline.Point, font.max_points + 1) catch return truetype.TRUETYPEERR_NOMEM;
        defer gpa.free(points);
        const ends = gpa.alloc(u32, font.max_contours + 1) catch return truetype.TRUETYPEERR_NOMEM;
        defer gpa.free(ends);
        const flags = gpa.alloc(u8, font.max_points + 1) catch return truetype.TRUETYPEERR_NOMEM;
        defer gpa.free(flags);
        var c = tt.outline.Contours{ .points = points, .ends = ends, .flags = flags };
        // A varied glyph reads its deltas in room of their own.
        const scratch = gpa.alignedAlloc(u8, .of(f32), if (tt.outline.isVaried(font)) tt.variation.Scratch.bytes(font.max_points + 1) else 0) catch return truetype.TRUETYPEERR_NOMEM;
        defer gpa.free(scratch);
        if (scratch.len != 0) c.vary = tt.variation.Scratch.within(scratch.ptr, font.max_points + 1);
        if (!tt.outline.contours(font, glyph, &c, .{ 1, 0, 0, 1, 0, 0 }, 0)) return truetype.TRUETYPEERR_GLYPH;
        return tt.segments.write(&c, out);
    }
    pub fn FontMetrics(_: *Sources, outline: *truetype.Outline, metrics: *truetype.FontMetrics) void {
        const font = fontOf(outline);
        const most = tt.segments.mostOf(font);
        metrics.* = .{
            .units_per_em = font.units_per_em,
            .glyph_count = font.glyph_count,
            .ascender = font.ascender,
            .descender = font.descender,
            .line_gap = font.line_gap,
            .x_height = font.x_height,
            .cap_height = font.cap_height,
            .underline_position = font.underline_position,
            .underline_thickness = font.underline_thickness,
            .strikeout_position = font.strikeout_position,
            .strikeout_thickness = font.strikeout_thickness,
            .subscript_offset = font.subscript_offset,
            .superscript_offset = font.superscript_offset,
            .most_verbs = most[0],
            .most_points = most[1],
            .style = font.style,
            .weight = font.weight,
            .stretch = font.stretch,
        };
    }

    pub fn GlyphPaints(_: *Sources, outline: *truetype.Outline, glyph: u32, steps: ?[*]truetype.PaintStep, room: u32) u32 {
        const font = fontOf(outline);
        if (glyph >= font.glyph_count) return 0;
        return tt.colour.stepsOf(font, glyph, steps, room);
    }
    pub fn GlyphPicture(_: *Sources, outline: *truetype.Outline, glyph: u32, picture: *truetype.Picture) bool {
        picture.* = tt.picture.pictureOf(fontOf(outline), glyph) orelse return false;
        return true;
    }
    pub fn GlyphDocument(_: *Sources, outline: *truetype.Outline, glyph: u32, glyph_document: *truetype.Document) bool {
        glyph_document.* = tt.document.documentOf(fontOf(outline), glyph) orelse return false;
        return true;
    }

    /// Room for a glyph the drawing's work block is too short for.
    pub fn AllocRoom(_: *Sources, bytes: usize) ?svg.Room {
        return std.heap.page_allocator.alignedAlloc(u8, .of(vector.Point), bytes) catch null;
    }
    pub fn FreeRoom(_: *Sources, room: svg.Room) void {
        std.heap.page_allocator.free(room);
    }

    /// The picture of a `data:` address, or of the file an address
    /// names from the SVG file's directory: an SVG document's text, or
    /// pens.
    pub fn OpenImage(s: *Sources, href: []const u8) ?svg.Image {
        const gpa = std.heap.page_allocator;
        if (svg.data.payloadOf(href)) |payload| {
            const room = gpa.alloc(u8, svg.data.payloadMost(payload)) catch return null;
            defer gpa.free(room);
            return imageOf(svg.data.decodePayload(payload, room) orelse return null);
        }
        const place = svg.address.placeOf(href) orelse return null;
        var path_room: [4096]u8 = undefined;
        const path = svg.address.hostPath(place, s.directory, &path_room) orelse return null;
        const bytes = Io.Dir.cwd().readFileAlloc(s.io, path, gpa, .limited(64 << 20)) catch return null;
        defer gpa.free(bytes);
        return imageOf(bytes);
    }

    /// The bytes an address holds, as `OpenImage` reads them.
    pub fn OpenFile(s: *Sources, href: []const u8) ?svg.Bytes {
        const gpa = std.heap.page_allocator;
        if (svg.data.payloadOf(href)) |payload| {
            const room = gpa.alloc(u8, svg.data.payloadMost(payload)) catch return null;
            const bytes = svg.data.decodePayload(payload, room) orelse {
                gpa.free(room);
                return null;
            };
            const kept = gpa.dupe(u8, bytes) catch null;
            gpa.free(room);
            return .{ .bytes = kept orelse return null };
        }
        const place = svg.address.placeOf(href) orelse return null;
        var path_room: [4096]u8 = undefined;
        const path = svg.address.hostPath(place, s.directory, &path_room) orelse return null;
        const bytes = Io.Dir.cwd().readFileAlloc(s.io, path, gpa, .limited(64 << 20)) catch return null;
        return .{ .bytes = bytes };
    }
    pub fn CloseFile(_: *Sources, file: svg.Bytes) void {
        std.heap.page_allocator.free(file.bytes);
    }

    /// The picture a file in memory is, as `OpenImage` gives one.
    pub fn OpenImageBytes(_: *Sources, bytes: []const u8) ?svg.Image {
        return imageOf(bytes);
    }

    /// The picture `bytes` are: an SVG document, unpacked when packed,
    /// as the datatype gives one, or a PNG, GIF or JPEG as pens.
    fn imageOf(bytes: []const u8) ?svg.Image {
        const gpa = std.heap.page_allocator;
        if (bytes.len >= 2 and bytes[0] == 0x1F and bytes[1] == 0x8B) {
            var reader: Io.Reader = .fixed(bytes);
            var whole: Io.Writer.Allocating = .init(gpa);
            var unpacker: std.compress.flate.Decompress = .init(&reader, .gzip, &.{});
            _ = unpacker.reader.streamRemaining(&whole.writer) catch return null;
            const unpacked = whole.toOwnedSlice() catch return null;
            if (!svg.document.startsSvg(unpacked)) return null;
            return .{ .document = unpacked, .handle = null };
        }
        if (svg.document.startsSvg(bytes)) {
            const copy = gpa.dupe(u8, bytes) catch return null;
            return .{ .document = copy, .handle = null };
        }
        const picture = readPng(gpa, bytes) catch readGif(gpa, bytes) catch readJpeg(gpa, bytes) catch return null;
        defer gpa.free(picture.rgba);
        const pens = gpa.alloc(graphics.Pen, @as(usize, picture.width) * picture.height) catch return null;
        for (pens, 0..) |*pen, i| {
            const p = picture.rgba[i * 4 ..][0..4];
            pen.* = @as(u32, p[3]) << 24 | @as(u32, p[0]) << 16 | @as(u32, p[1]) << 8 | p[2];
        }
        return .{ .pens = pens.ptr, .width = picture.width, .height = picture.height, .bytes_per_row = picture.width * 4, .handle = @ptrCast(pens.ptr) };
    }
    pub fn CloseImage(_: *Sources, image: svg.Image) void {
        const gpa = std.heap.page_allocator;
        if (image.document) |text| return gpa.free(text);
        const pens: [*]graphics.Pen = @ptrCast(@alignCast(image.handle.?));
        std.heap.page_allocator.free(pens[0 .. @as(usize, image.width) * image.height]);
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
fn drawSvg(gpa: std.mem.Allocator, sources: *Sources, file_text: []u8, width: u32, height: u32) !?Picture {
    // A DOCTYPE's entities put in, as the datatype does.
    var text = file_text;
    if (svg.entity.declared(text)) |declared| {
        if (svg.entity.expandedSize(text, &declared)) |size| {
            const grown = try gpa.alloc(u8, size);
            text = svg.entity.expand(file_text, &declared, grown);
        }
    }
    defer if (text.ptr != file_text.ptr) gpa.free(text);
    const counts = document.count(text) orelse return null;
    const bytes = document.bytesFor(counts);
    const block = try gpa.alignedAlloc(u8, .@"8", @max(bytes, 8));
    defer gpa.free(block);
    const doc = document.build(text, counts, block[0..bytes]);
    const pens = try gpa.alloc(sdk.graphics.Pen, @as(usize, width) * height);
    defer gpa.free(pens);
    @memset(pens, 0);
    const canvas = module.Canvas.create(memory, width, height) orelse return error.OutOfMemory;
    defer canvas.destroy();
    canvas.setPens(pens.ptr, width * 4);
    const path = module.Path.create(memory) orelse return error.OutOfMemory;
    defer path.destroy();
    const work = try gpa.create(svg.Work);
    defer gpa.destroy(work);
    const intrinsic = svg.intrinsic(&doc);
    var direct = Direct{};
    svg.draw(&direct, sources, &doc, @ptrCast(canvas), .{ width, height }, @ptrCast(path), work, svg.baseMatrix(intrinsic, width, height), intrinsic.viewport);
    const rgba = try gpa.alloc(u8, pens.len * 4);
    for (pens, 0..) |pen, i| {
        rgba[i * 4 + 0] = @truncate(pen >> 16);
        rgba[i * 4 + 1] = @truncate(pen >> 8);
        rgba[i * 4 + 2] = @truncate(pen);
        rgba[i * 4 + 3] = @truncate(pen >> 24);
    }
    return .{ .width = width, .height = height, .rgba = rgba };
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
/// A GIF's first picture on its screen, what it leaves clear clear.
fn readGif(gpa: std.mem.Allocator, file: []const u8) !Picture {
    const screen = try gif.readScreen(file);
    const picture = (try gif.readFirst(file, screen)) orelse return error.NoPicture;
    const compressed = try gpa.alloc(u8, try gif.blockBytes(file, picture.data_at));
    defer gpa.free(compressed);
    const got = gif.gatherBlocks(file, picture.data_at, compressed);
    const indices = try gpa.alloc(u8, @as(usize, picture.width) * picture.height);
    defer gpa.free(indices);
    @memset(indices, 0);
    const work = try gpa.create(lzw.Work);
    defer gpa.destroy(work);
    work.* = .{};
    const written = lzw.decode(work, picture.min_code_size, compressed[0..got], indices) catch indices.len;
    const rgba = try gpa.alloc(u8, @as(usize, screen.width) * screen.height * 4);
    @memset(rgba, 0);
    var row: u32 = 0;
    while (row < written / picture.width) : (row += 1) {
        const y = picture.top + gif.rowOf(picture, row);
        if (y >= screen.height) continue;
        for (0..picture.width) |column| {
            const x = picture.left + column;
            if (x >= screen.width) continue;
            const index = indices[row * picture.width + column];
            if (picture.transparent == index or @as(usize, index) * 3 + 2 >= picture.palette.len) continue;
            const at = rgba[(@as(usize, y) * screen.width + x) * 4 ..][0..4];
            at.* = .{ picture.palette[@as(usize, index) * 3], picture.palette[@as(usize, index) * 3 + 1], picture.palette[@as(usize, index) * 3 + 2], 0xFF };
        }
    }
    return .{ .width = screen.width, .height = screen.height, .rgba = rgba };
}

/// A JPEG as the disk's jpeg.datatype reads one, each pixel's colour
/// from the nearest sample of each plane.
fn readJpeg(gpa: std.mem.Allocator, file: []const u8) !Picture {
    const work = try gpa.create(jpeg.Work);
    defer gpa.destroy(work);
    work.* = .{};
    try jpeg.readHeaders(file, work);
    var planes: [4]?[]u8 = @splat(null);
    defer for (planes) |plane| if (plane) |held| gpa.free(held);
    for (work.component[0..work.count], 0..) |*component, index| {
        component.stride = jpeg.planeStride(work, component);
        component.lines = jpeg.planeLines(work, component);
        const plane = try gpa.alloc(u8, @as(usize, component.stride) * component.lines);
        @memset(plane, 0);
        planes[index] = plane;
        component.plane = plane.ptr;
    }
    try jpeg.readScan(file, work);
    const rgba = try gpa.alloc(u8, @as(usize, work.width) * work.height * 4);
    for (0..work.height) |y| {
        for (0..work.width) |x| {
            var sample: [3]u8 = undefined;
            for (work.component[0..@min(work.count, 3)], 0..) |*component, index| {
                const across = @min(x * component.across / work.max_across, component.stride - 1);
                const down = @min(y * component.down / work.max_down, component.lines - 1);
                sample[index] = component.plane[down * component.stride + across];
            }
            const at = rgba[(y * work.width + x) * 4 ..][0..4];
            if (work.count < 3) {
                at.* = .{ sample[0], sample[0], sample[0], 0xFF };
            } else {
                jpeg.toRGB(sample[0], sample[1], sample[2], at[0..3]);
                at[3] = 0xFF;
            }
        }
    }
    return .{ .width = work.width, .height = work.height, .rgba = rgba };
}

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
    var width: u32 = 48;
    var height: u32 = 48;
    var out_dir: ?[]const u8 = null;
    var zoom: u32 = 1;
    var detail = false;
    var hash = false;
    var fonts: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--size") and i + 1 < args.len) {
            i += 1;
            // N by N, or W by H: a picture of another shape at the size
            // `C:test/DTTime WIDTH W HEIGHT H` makes it.
            var sides = std.mem.splitScalar(u8, args[i], 'x');
            width = std.fmt.parseInt(u32, sides.first(), 10) catch fatal("{s}: not a size", .{args[i]});
            height = if (sides.next()) |h| std.fmt.parseInt(u32, h, 10) catch fatal("{s}: not a size", .{args[i]}) else width;
        } else if (std.mem.eql(u8, args[i], "--detail")) {
            detail = true;
        } else if (std.mem.eql(u8, args[i], "--hash")) {
            hash = true;
        } else if (std.mem.eql(u8, args[i], "--fonts") and i + 1 < args.len) {
            i += 1;
            fonts = args[i];
        } else if (std.mem.eql(u8, args[i], "--zoom") and i + 1 < args.len) {
            i += 1;
            zoom = std.fmt.parseInt(u32, args[i], 10) catch fatal("{s}: not a zoom", .{args[i]});
            if (zoom == 0 or zoom > 16) fatal("{s}: a zoom of 1 to 16", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else try files.append(arena, args[i]);
    }
    if (files.items.len == 0 or files.items.len % 2 != 0 or width == 0 or width > 4096 or height == 0 or height > 4096) {
        fatal("usage: svgcompare [--size N|WxH] [--out DIR] <file.svg> <drawn.png> ...", .{});
    }
    const cwd = Io.Dir.cwd();
    var sources = Sources{ .io = io, .fonts = fonts };
    var close: u32 = 0;
    var failed: std.ArrayList([]const u8) = .empty;
    var mean_sum: f64 = 0;
    var pair: usize = 0;
    while (pair < files.items.len) : (pair += 2) {
        const svg_path = files.items[pair];
        const png_path = files.items[pair + 1];
        const name = std.fs.path.stem(svg_path);
        sources.directory = std.fs.path.dirname(svg_path) orelse ".";
        const text = cwd.readFileAlloc(io, svg_path, gpa, .limited(16 << 20)) catch |e| fatal("{s}: {t}", .{ svg_path, e });
        defer gpa.free(text);
        const ours = (try drawSvg(gpa, &sources, text, width, height)) orelse {
            std.debug.print("{s:<40} not SVG to this reader\n", .{name});
            try failed.append(arena, name);
            continue;
        };
        defer gpa.free(ours.rgba);
        const reference = cwd.readFileAlloc(io, png_path, gpa, .limited(64 << 20)) catch |e| fatal("{s}: {t}", .{ png_path, e });
        defer gpa.free(reference);
        const theirs = readPng(gpa, reference) catch |e| fatal("{s}: {t}", .{ png_path, e });
        defer gpa.free(theirs.rgba);
        if (theirs.width != width or theirs.height != height) fatal("{s}: {d}x{d}, not {d}x{d}", .{ png_path, theirs.width, theirs.height, width, height });
        var side: ?[]u8 = null;
        if (out_dir != null) {
            side = try gpa.alloc(u8, @as(usize, width) * height * 3 * 4);
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
            const x = d.at % width;
            const y = d.at / width;
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
            const shown = try zoomed(gpa, side.?, width * 3, height, zoom);
            defer if (zoom != 1) gpa.free(shown);
            try writePng(gpa, io, path, width * 3 * zoom, height * zoom, shown);
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
