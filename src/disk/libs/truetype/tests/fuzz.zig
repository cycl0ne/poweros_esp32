// SPDX-License-Identifier: MIT
//! Host tests that hand truetype.library files that are not sound: fonts
//! with bytes changed, fonts cut short, and whatever a fuzzer makes of
//! them. A font comes from a share, a download or a mail, so every reader
//! of a font's bytes is run on such files here.
//!
//! Whatever a file says, a call may refuse it or answer nothing, and this
//! holds of it all the same (`Harness.exercise`):
//!
//! - It reads no byte past the file's end. A file is put where it ends at
//!   a page the host has closed to every access (`Arena`), so such a read
//!   ends the test run with a segmentation fault, whose trace names the
//!   function that read.
//! - It writes nothing outside the room it was given: the bytes after a
//!   name's room, the verbs and points after a glyph's, and the bytes
//!   after a rendered glyph's pixels stay as they were.
//! - What it answers is sound. A glyph is one the font has; a table
//!   handed out lies in the file; a name is whole characters of UTF-8 and
//!   ended; a glyph's verbs and points are counted right and fit the room
//!   the font's measures promise, or for a glyph of cubic curves the room
//!   it says it takes; an image rendered is a sound font
//!   image; a glyph rendered by its number is of the font's kind of
//!   pixels - coverage, or colour for a font of colour pictures - has a
//!   box no further out than a glyph reaches, and as many bytes as its
//!   box says, the same whatever room it was given.
//! - It ends. A table that sends a reader round in circles would keep the
//!   test run from ending.
//! - It leaves nothing allocated: exec has as much memory free after a
//!   file as before it.
//!
//! Two drivers hand over the files. One changes the fonts the tests build
//! and, when they are fetched, the real ones (`reference.zig`) by a fixed
//! sequence of random numbers: a few bytes or big-endian numbers a round,
//! most of them in the tables the library reads, and every so often the
//! file cut short. A test run so covers the same files every time, and a
//! failure is met again by running it again. The other is
//! `std.testing.fuzz`, which reads a file from a fuzzer when the tests are
//! built for one (`./zig build test --fuzz`), and otherwise runs the built
//! fonts, its corpus, as they are. The toolchain's Zig 0.16.0 does not
//! build the tests for a fuzzer - its test runner stops compiling there -
//! so the first driver is the one that changes files today.
//!
//! The closed page is the Linux kernel's, so the tests are skipped on
//! another host.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const truetype = sdk.truetype;
const utility = sdk.utility;
const vector = sdk.vector;
const builder = @import("builder.zig");
const reference = @import("reference.zig");
const built = @import("truetype.zig");
const cubic = @import("cff.zig");
const pictured = @import("strike.zig");
const varied = @import("variation.zig");

const testing = std.testing;
const linux = std.os.linux;
const Rig = built.Rig;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

/// The longest file handed over: longer than the longest font fetched.
const most_file = 32 * 1024 * 1024;

/// The longest file read from a fuzzer: longer than any font built here.
const most_input = 64 * 1024;

/// The most verbs, and the most points, a glyph's outline takes whatever
/// a font's `maxp` says: its two counts are 16 bits each, and a glyph is
/// read with one more of each.
const most_segments = 3 * 0x1_0000;

/// How many bytes, verbs or points after a room are watched for a write.
const watched = 16;

/// The heights a glyph is rendered at by its number, and the bytes the
/// largest glyph there is takes at the taller: one that reaches sixteen
/// lines to every side of where it is drawn, four bytes a pixel.
const glyph_heights = [_]u32{ 9, 1 };
const glyph_pixels = 512 * 1024;

/// What a watched byte holds, and a watched point.
const untouched: u8 = 0xAA;
const untouched_point: vector.Point = .{ .x = -12345.5, .y = 54321.25 };

/// Pages of the host's own with one after them that nothing may read or
/// write: a file placed here ends where that page begins.
pub const Arena = struct {
    memory: []align(std.heap.page_size_min) u8,
    /// Where the closed page begins.
    end: usize,

    pub fn init() !Arena {
        const page = std.heap.pageSize();
        const room = std.mem.alignForward(usize, most_file, page);
        const memory = try std.posix.mmap(null, room + page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        errdefer std.posix.munmap(memory);
        if (linux.errno(linux.mprotect(memory.ptr + room, page, .{})) != .SUCCESS) return error.NotClosed;
        // That it is closed is asked of the kernel: told to put a byte
        // there itself, it refuses, where a program's own access would
        // end the program.
        var open: [1]u8 = undefined;
        if (linux.errno(linux.getrandom(&open, 1, 0)) != .SUCCESS) return error.NothingToAskWith;
        if (linux.errno(linux.getrandom(memory.ptr + room, 1, 0)) != .FAULT) return error.NotClosed;
        return .{ .memory = memory, .end = room };
    }

    /// `bytes` copied to where they end at the closed page.
    pub fn place(arena: *const Arena, bytes: []const u8) []u8 {
        const file = arena.memory[arena.end - bytes.len .. arena.end];
        @memcpy(file, bytes);
        return file;
    }

    pub fn free(arena: *const Arena) void {
        std.posix.munmap(arena.memory);
    }
};

/// A font the tests build, as a fuzzer's corpus holds it: its length in
/// four bytes, the lowest first, and then its bytes, which is how
/// `Smith.slice` reads a file.
const Seed = struct {
    bytes: [4 + builder.File.room]u8,
    len: u32,

    fn set(seed: *Seed, source: []const u8) void {
        seed.len = @intCast(source.len);
        std.mem.writeInt(u32, seed.bytes[0..4], seed.len, .little);
        @memcpy(seed.bytes[4..][0..source.len], source);
    }

    /// The font.
    fn written(seed: *const Seed) []const u8 {
        return seed.bytes[4..][0..seed.len];
    }

    /// The font as the corpus holds it.
    fn entry(seed: *const Seed) []const u8 {
        return seed.bytes[0 .. 4 + seed.len];
    }
};

const seed_count = 16;

/// The fonts the tests build: between them every table the library reads
/// and every form of them it tells apart.
fn buildSeeds(seeds: *[seed_count]Seed) void {
    var next: usize = 0;

    // A glyph of curves, one made of another glyph, and kerning.
    var out: built.Out = .{};
    built.buildFont(&out);
    seeds[next].set(out.bytes[0..out.len]);
    next += 1;

    // Variation sequences, two character maps, names, `OS/2`, `post`.
    var file: builder.File = .{};
    builder.whole(&file);
    seeds[next].set(file.written());
    next += 1;

    // A character map of each other format, alone in its font.
    for ([_]u16{ 0, 6, 10, 12, 13 }) |format| {
        var cmap = builder.Cmap.init(1);
        cmap.begin(3, if (format >= 10) 10 else 1);
        switch (format) {
            0 => {
                var glyphs: [256]u8 = @splat(0);
                for ('A'..'H', 1..) |code, glyph| glyphs[code] = @intCast(glyph);
                cmap.bytes(&glyphs);
            },
            6 => cmap.run('A', &.{ 1, 2, 3, 4, 5, 6, 7 }),
            10 => cmap.longRun('A', &.{ 1, 2, 3, 4, 5, 6, 7 }),
            12 => cmap.groups(12, &.{ .{ .first = 'A', .last = 'D', .glyph = 1 }, .{ .first = 0x1F600, .last = 0x1F601, .glyph = 5 } }),
            else => cmap.groups(13, &.{ .{ .first = 'A', .last = 'H', .glyph = 2 }, .{ .first = 0x915, .last = 0x918, .glyph = 3 } }),
        }
        file = .{};
        _ = builder.font(&file, .{ .cmap = cmap.written() });
        seeds[next].set(file.written());
        next += 1;
    }

    var letters = builder.Cmap.init(1);
    letters.begin(3, 1);
    letters.segments(&.{
        .{ .first = 'A', .last = 'H', .delta = 1 -% @as(u16, 'A') },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });

    // A collection of two fonts.
    file = .{};
    builder.collection(&file, 2);
    builder.place(&file, 0, builder.font(&file, .{ .cmap = letters.written(), .glyphs = 9 }));
    builder.place(&file, 1, builder.font(&file, .{ .cmap = letters.written(), .glyphs = 12, .advance = 700, .style_bits = 1 }));
    seeds[next].set(file.written());
    next += 1;

    // A font of no outlines.
    file = .{};
    _ = builder.font(&file, .{ .cmap = letters.written(), .glyphs = 9, .outlines = false });
    seeds[next].set(file.written());
    next += 1;

    // Cubic outlines: lines, curves of every form, hints and masks,
    // numbers of every form and the operators that calculate, with
    // subroutines local and global, one in another. Its `maxp` names a
    // largest glyph smaller than its glyphs are.
    const nothing = builder.program("endchar");
    file = .{};
    cubic.build(&file, .{
        .glyphs = &.{
            nothing,
            builder.program("50 0 0 rmoveto 500 hlineto 700 vlineto -500 hlineto endchar"),
            builder.program("10 20 hstemhm 30 40 vstemhm hintmask #C0 100 100 rmoveto -107 callsubr -107 callgsubr cntrmask #40 -106 callsubr endchar"),
            builder.program("0 0 rmoveto 10 20 30 40 50 60 70 80 -90 -100 -110 -120 12 flex 10 20 30 40 50 60 70 80 90 100 110 flex1 30 40 50 60 70 80 90 hflex 5 6 7 8 9 10 11 12 13 hflex1 endchar"),
            builder.program("s:1000 f:2.5 rmoveto 3 4 add 5 mul 2 div 9 sqrt sub 1 put 1 get dup exch 2 1 roll 0 index 1 2 3 4 ifelse neg abs not and or eq random drop 7 8 rlineto endchar"),
            builder.program("100 hmoveto 100 vmoveto 10 20 30 40 50 60 70 80 rcurveline 10 20 30 40 50 60 rlinecurve 10 20 30 40 50 vvcurveto 10 20 30 40 50 hhcurveto 10 20 30 40 hvcurveto 10 20 30 40 vhcurveto endchar"),
        },
        .locals = &.{
            builder.program("10 20 30 40 50 60 rrcurveto -106 callgsubr return"),
            builder.program("-30 hlineto 40 vlineto return"),
        },
        .globals = &.{
            builder.program("100 0 rlineto return"),
            builder.program("0 100 rlineto -106 callsubr return"),
        },
    }, true);
    seeds[next].set(file.written());
    next += 1;

    // Many fonts under one set of glyphs, by ranges, each with
    // subroutines of its own; offsets of three bytes.
    const calls = builder.program("0 0 rmoveto -107 callsubr 0 500 rlineto endchar");
    file = .{};
    cubic.build(&file, .{
        .glyphs = &.{ nothing, calls, calls, calls, calls, builder.program("0 0 rmoveto 300 300 rlineto -300 hlineto endchar") },
        .fonts = &.{
            &.{builder.program("400 0 rlineto return")},
            &.{builder.program("0 400 -200 200 400 0 rrcurveto return")},
            &.{},
        },
        .select = &.{ 3, 0, 3, 0, 0, 0, 0, 2, 1, 0, 4, 2, 0, 6 },
        .off_size = 3,
    }, false);
    seeds[next].set(file.written());
    next += 1;

    // Pictures of coverage, their strike listing them in each of its
    // ways.
    file = .{};
    pictured.waysFont(&file);
    seeds[next].set(file.written());
    next += 1;

    // Two strikes, of 1 bit a pixel and of 4: pictures of packed rows,
    // and ones put together of other glyphs.
    file = .{};
    pictured.formsFont(&file);
    seeds[next].set(file.written());
    next += 1;

    // Pictures of colour: PNG files under each of their forms.
    file = .{};
    pictured.colourFont(&file);
    seeds[next].set(file.written());
    next += 1;

    // Variable fonts: bent axes, advances by a map and measures that
    // move; and advances by the glyphs' sides.
    file = .{};
    varied.standardFont(&file);
    seeds[next].set(file.written());
    next += 1;
    file = .{};
    varied.sidesFont(&file);
    seeds[next].set(file.written());
    next += 1;

    std.debug.assert(next == seed_count);
}

/// The characters asked for: the ends of each range a character map
/// tells apart, and characters the fonts here have.
const codes = [_]u32{
    0,       1,      0x20,     'A',       'B',         'H',         0xFF,    0x100,
    0x915,   0x918,  0xF020,   0xF041,    0xFFFF,      0x1_0000,    0x1F600, 0x1F601,
    0xE0100, 0xFE0F, 0x10FFFF, 0x11_0000, 0x7FFF_FFFF, 0xFFFF_FFFF,
};

/// The variation selectors asked for.
const selectors = [_]u32{ 0, 0xFE00, 0xFE0E, 0xFE0F, 0xE0100, 0xE01EF, 0x11_0000, 0xFFFF_FFFF };

/// The names asked for.
const names = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 13, 14, 16, 17, 25, 256, 0xFFFF, 0x1_0000, 0xFFFF_FFFF };

/// The room a name is asked into.
const rooms = [_]u32{ 0, 1, 2, 7, 256 };

/// The tables asked for beside the ones the file's directory names.
const tags = [_]u32{
    truetype.tableTag("cmap"), truetype.tableTag("glyf"), truetype.tableTag("GSUB"),
    truetype.tableTag("zzzz"), 0,                         0xFFFF_FFFF,
};

/// The characters rendered.
const ranges = [_]truetype.CodeRange{
    .{ .first = 'A', .last = 'H' },
    .{ .first = 0x915, .last = 0x918 },
    .{ .first = 0x1F600, .last = 0x1F601 },
};

/// The styles a font says it is drawn in.
const styles: graphics.FontStyle = graphics.FSF_BOLD | graphics.FSF_ITALIC;

/// `glyph` among the glyphs asked about, once, while there is room.
fn note(glyphs: []u32, known: *usize, glyph: u32) void {
    if (known.* == glyphs.len) return;
    if (std.mem.indexOfScalar(u32, glyphs[0..known.*], glyph) != null) return;
    glyphs[known.*] = glyph;
    known.* += 1;
}

/// What GlyphSegments answered, and what it counted.
const Read = struct {
    answer: i32,
    verb_count: u32,
    point_count: u32,
};

/// What the tests share: the library up, the place a file is put, and
/// the room its answers are read into.
const Harness = struct {
    rig: Rig,
    arena: Arena,
    verbs: []u8,
    points: []vector.Point,
    /// The room a glyph is rendered into by its number: every byte of it
    /// `untouched` between two calls.
    pixels: []u8,
    /// A fuzzer's file, before it is placed.
    input: []u8,
    seeds: *[seed_count]Seed,
    /// How many files were handed over, how many fonts the library opened
    /// of them, how many outlines it read, how many images it rendered
    /// and how many glyphs with ink by their numbers: what tells a run
    /// that met the readers from one whose files were all refused at the
    /// door.
    files: u32 = 0,
    opened: u32 = 0,
    outlines: u32 = 0,
    images: u32 = 0,
    inked: u32 = 0,
    /// How many fonts were opened away from their default.
    placed: u32 = 0,

    /// Where the room comes from. It is kept for as long as a test runs,
    /// so it is not the testing allocator's, which a fuzzing run checks
    /// for leaks after every file.
    const allocator = std.heap.page_allocator;

    fn up() !Harness {
        const arena = try Arena.init();
        errdefer arena.free();
        const verbs = try allocator.alloc(u8, most_segments + watched);
        errdefer allocator.free(verbs);
        const points = try allocator.alloc(vector.Point, most_segments + watched);
        errdefer allocator.free(points);
        const pixels = try allocator.alloc(u8, glyph_pixels + watched);
        errdefer allocator.free(pixels);
        @memset(pixels, untouched);
        const input = try allocator.alloc(u8, most_input);
        errdefer allocator.free(input);
        const seeds = try allocator.create([seed_count]Seed);
        errdefer allocator.destroy(seeds);
        buildSeeds(seeds);
        return .{ .rig = try Rig.up(), .arena = arena, .verbs = verbs, .points = points, .pixels = pixels, .input = input, .seeds = seeds };
    }

    /// Everything given back, and nothing of the library's left behind.
    fn down(harness: *Harness) !void {
        allocator.destroy(harness.seeds);
        allocator.free(harness.input);
        allocator.free(harness.pixels);
        allocator.free(harness.points);
        allocator.free(harness.verbs);
        harness.arena.free();
        try harness.rig.down();
    }

    /// One file through every reader of a font's bytes. `file` ends at
    /// the arena's closed page.
    fn exercise(harness: *Harness, file: []const u8) !void {
        const sys = harness.rig.sys;
        const tb = harness.rig.tb;
        const size: u32 = @intCast(file.len);
        harness.files += 1;

        // What tells a font from a collection, read before any call.
        const count = truetype.fontCount(file);
        if (truetype.isTrueType(file)) try testing.expectEqual(@as(u32, 1), count);
        try testing.expect(truetype.styleOf(file) & ~styles == 0);

        const free = sys.AvailMem(sdk.exec.MEMF_ANY);
        var first_opened = false;
        const indices = [_]u32{ 0, 1, 2, 3, count -% 1, count, 0x7FFF_FFFF, 0xFFFF_FFFF };
        for (indices, 0..) |index, nth| {
            // Each number once.
            if (std.mem.indexOfScalar(u32, indices[0..nth], index) != null) continue;
            const directory = truetype.fontDirectory(file, index);
            if (directory) |start| {
                try testing.expect(index < count);
                try testing.expect(start <= file.len and file.len - start >= 12);
            }
            const list = [_]utility.TagItem{
                .{ .tag = truetype.TTA_FontIndex, .data = index },
                .{ .tag = utility.TAG_DONE, .data = 0 },
            };
            const outline = tb.OpenOutline(file.ptr, size, &list) orelse continue;
            defer tb.CloseOutline(outline);
            if (index == 0) first_opened = true;
            harness.opened += 1;
            try harness.use(outline, file, directory orelse return error.OpenedWithoutDirectory);
        }
        // Without a number it is the first font.
        const plain = tb.OpenOutline(file.ptr, size, null);
        var axes: [axis_room]truetype.Axis = undefined;
        const axis_count = if (plain) |outline| @min(tb.FontAxes(outline, &axes, axes.len), axes.len) else 0;
        tb.CloseOutline(plain);
        try testing.expectEqual(first_opened, plain != null);

        // A variable font at the ends of its axes and between them, as
        // far as its file says where they are.
        for ([_]f32{ 1.0, 0.0, 0.625 }) |along| {
            if (axis_count == 0) break;
            var values: [axis_room]truetype.AxisValue = undefined;
            for (values[0..axis_count], axes[0..axis_count]) |*value, axis| {
                value.* = .{ .tag = axis.tag, .value = axis.minimum + (axis.maximum - axis.minimum) * along };
            }
            const list = [_]utility.TagItem{
                .{ .tag = truetype.TTA_Axes, .data = @intFromPtr(&values) },
                .{ .tag = truetype.TTA_AxisCount, .data = axis_count },
                .{ .tag = utility.TAG_DONE, .data = 0 },
            };
            const outline = tb.OpenOutline(file.ptr, size, &list) orelse return error.NotOpenedAtAPlace;
            defer tb.CloseOutline(outline);
            harness.placed += 1;
            try harness.use(outline, file, truetype.fontDirectory(file, 0) orelse return error.OpenedWithoutDirectory);
        }
        try testing.expectEqual(free, sys.AvailMem(sdk.exec.MEMF_ANY));
    }

    /// Every call that takes an outline, on one the library opened of the
    /// font of `file` whose table directory is at `directory`.
    fn use(harness: *Harness, outline: *truetype.Outline, file: []const u8, directory: u32) !void {
        const tb = harness.rig.tb;
        var metrics: truetype.FontMetrics = .{};
        tb.FontMetrics(outline, &metrics);
        try testing.expect(metrics.units_per_em != 0);
        try testing.expect(metrics.ascender > metrics.descender);
        try testing.expect(metrics.most_verbs <= most_segments and metrics.most_points <= most_segments);
        try testing.expect(metrics.style & ~styles == 0);
        const glyph_count = metrics.glyph_count;

        // The glyphs asked about: the first, the last, the ones past the
        // last, and every one a character or a sequence is drawn with.
        var glyphs: [64]u32 = undefined;
        var known: usize = 0;
        for ([_]u32{ 0, 1, 2, 3, glyph_count / 2, glyph_count -% 1, glyph_count, 0xFFFF, 0x1_0000, 0xFFFF_FFFF }) |glyph| note(&glyphs, &known, glyph);
        for (codes) |code| {
            const glyph = tb.GlyphIndex(outline, code);
            try testing.expect(glyph == 0 or glyph < glyph_count);
            note(&glyphs, &known, glyph);
            for (selectors) |selector| {
                const variant = tb.GlyphVariant(outline, code, selector);
                try testing.expect(variant == 0 or variant < glyph_count);
                note(&glyphs, &known, variant);
            }
        }

        // Whether the font has outlines or pictures at all: its first
        // glyph is rendered, or the font has none to render. Either way
        // the call says what its pixels would be.
        var first = truetype.GlyphImage{ .pixels = harness.pixels.ptr, .room = 0, .kind = .mono1 };
        const drawable = tb.RenderGlyph(outline, 0, 1, &first) != truetype.TRUETYPEERR_GLYPH;
        const kind = first.kind;
        try testing.expect(kind == .alpha4 or kind == .rgba32);

        // Whether its outlines are of cubic curves: such a font does not
        // say how large its glyphs are.
        var length: u32 = 0;
        const curved = tb.FontTable(outline, 0x676C_7966, &length) == null and tb.FontTable(outline, 0x4346_4620, &length) != null;

        try harness.readNames(outline);
        try harness.readAxes(outline);
        try harness.readTables(outline, file, directory);
        for (glyphs[0..known], 0..) |glyph, nth| {
            try harness.readGlyph(outline, &metrics, glyph, curved);
            try harness.renderGlyph(outline, glyph, glyph < glyph_count and drawable, kind);
            _ = tb.Kerning(outline, glyph, glyphs[(nth + 1) % known]);
        }
        try harness.render(outline, 9);
        try harness.render(outline, 1);
    }

    /// The axes, the coordinates and the named instances into each
    /// room: counted the same whatever the room, a coordinate within its
    /// range, and nothing written after the room.
    fn readAxes(harness: *Harness, outline: *truetype.Outline) !void {
        const tb = harness.rig.tb;
        const axis_rooms = [_]u32{ 0, 1, 2, 33, axis_room - 4 };
        const count = tb.FontAxes(outline, null, 0);
        try testing.expect(count <= 0xFFFF);

        const marked = truetype.Axis{ .tag = 0xAAAA_AAAA, .minimum = 1, .default = 2, .maximum = 3, .value = 4, .name = 5, .hidden = true };
        var axes: [axis_room]truetype.Axis = undefined;
        for (axis_rooms) |room| {
            axes = @splat(marked);
            try testing.expectEqual(count, tb.FontAxes(outline, &axes, room));
            for (axes[@min(room, count)..]) |axis| try testing.expectEqual(marked, axis);
        }

        var coords: [axis_room]i16 = undefined;
        try testing.expectEqual(count, tb.FontCoordinates(outline, null, 9));
        for (axis_rooms) |room| {
            coords = @splat(0x5555);
            try testing.expectEqual(count, tb.FontCoordinates(outline, &coords, room));
            for (coords[0..@min(room, count)]) |coord| try testing.expect(coord >= -16384 and coord <= 16384);
            for (coords[@min(room, count)..]) |coord| try testing.expectEqual(@as(i16, 0x5555), coord);
        }

        const marked_value = truetype.AxisValue{ .tag = 0xAAAA_AAAA, .value = 7 };
        var values: [axis_room]truetype.AxisValue = undefined;
        for ([_]u32{ 0, 1, 2, 3, 7, 0xFFFF, 0xFFFF_FFFF }) |number| {
            const name = tb.FontInstance(outline, number, null, 9);
            if (count == 0) try testing.expectEqual(@as(u32, 0), name);
            for (axis_rooms) |room| {
                values = @splat(marked_value);
                try testing.expectEqual(name, tb.FontInstance(outline, number, &values, room));
                const written = if (name == 0) 0 else @min(room, count);
                for (values[written..]) |value| try testing.expectEqual(marked_value, value);
            }
        }
    }

    /// Each name into each room: ended within it, whole characters, and
    /// nothing written after it.
    fn readNames(harness: *Harness, outline: *truetype.Outline) !void {
        const tb = harness.rig.tb;
        var text: [256 + watched]u8 = undefined;
        for (names) |name| {
            var takes: ?u32 = null;
            for (rooms) |room| {
                @memset(&text, untouched);
                const needed = tb.FontName(outline, name, &text, room);
                // It takes the same whatever the room.
                if (takes) |before| try testing.expectEqual(before, needed);
                takes = needed;
                if (room != 0) {
                    const length = std.mem.indexOfScalar(u8, text[0..room], 0) orelse return error.NameNotEnded;
                    try testing.expect(length <= needed);
                    if (needed < room) try testing.expectEqual(@as(usize, needed), length);
                    try testing.expect(std.unicode.utf8ValidateSlice(text[0..length]));
                }
                for (text[room..]) |byte| try testing.expectEqual(untouched, byte);
            }
        }
    }

    /// Each table the font's directory names, and some it does not: one
    /// handed out lies in the file, first byte to last.
    fn readTables(harness: *Harness, outline: *truetype.Outline, file: []const u8, directory: u32) !void {
        const tb = harness.rig.tb;
        const low = @intFromPtr(file.ptr);
        const start: usize = directory;
        // The directory is read here with the file's length in hand.
        const listed: usize = @min(64, std.mem.readInt(u16, file[start + 4 ..][0..2], .big));
        var sum: u8 = 0;
        for (0..listed + tags.len) |nth| {
            var tag: u32 = undefined;
            if (nth < listed) {
                const record = start + 12 + nth * 16;
                if (record > file.len or file.len - record < 4) continue;
                tag = std.mem.readInt(u32, file[record..][0..4], .big);
            } else {
                tag = tags[nth - listed];
            }
            var length: u32 = 0xAAAA_AAAA;
            const table = tb.FontTable(outline, tag, &length) orelse {
                try testing.expectEqual(@as(u32, 0), length);
                continue;
            };
            const at = @intFromPtr(table);
            try testing.expect(at >= low and at - low <= file.len and file.len - (at - low) >= length);
            if (length != 0) sum +%= table[0] +% table[length - 1];
        }
        std.mem.doNotOptimizeAway(sum);
    }

    /// One glyph's measures and its outline, into the room the font's
    /// measures promise and into less. `curved` says that the font's
    /// outlines are of cubic curves.
    fn readGlyph(harness: *Harness, outline: *truetype.Outline, metrics: *const truetype.FontMetrics, glyph: u32, curved: bool) !void {
        const tb = harness.rig.tb;
        const has = glyph < metrics.glyph_count;

        var measures: truetype.GlyphMetrics = .{ .advance = 1, .left_bearing = 1, .x_min = 1, .y_min = 1, .x_max = 1, .y_max = 1 };
        try testing.expectEqual(has, tb.GlyphMetrics(outline, glyph, &measures));
        if (!has) try testing.expectEqual(truetype.GlyphMetrics{}, measures);
        // Its advance alone is the same, and never less than nothing.
        const advance = tb.GlyphAdvance(outline, glyph);
        try testing.expect(advance >= 0);
        try testing.expectEqual(measures.advance, advance);

        // The room the font's measures promise is enough for any glyph;
        // one of cubic curves may take more, says how much, and is read
        // into that.
        var whole = try harness.segments(outline, glyph, metrics.most_verbs, metrics.most_points);
        if (curved and whole.answer == truetype.TRUETYPEERR_ROOM) {
            try testing.expect(whole.verb_count <= most_segments and whole.point_count <= most_segments);
            const again = try harness.segments(outline, glyph, whole.verb_count, whole.point_count);
            try testing.expectEqual(truetype.TRUETYPE_OK, again.answer);
            try testing.expectEqual(whole.verb_count, again.verb_count);
            try testing.expectEqual(whole.point_count, again.point_count);
            whole = again;
        }
        try testing.expect(whole.answer != truetype.TRUETYPEERR_ROOM);
        if (!has) try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, whole.answer);
        if (whole.answer == truetype.TRUETYPE_OK and whole.verb_count != 0) harness.outlines += 1;

        // Less is refused when it is not enough, with what it takes.
        for ([_]u32{ 0, 1, 5 }) |room| {
            const cut = try harness.segments(outline, glyph, room, room);
            if (whole.answer != truetype.TRUETYPE_OK) {
                try testing.expectEqual(whole.answer, cut.answer);
                continue;
            }
            const fits = whole.verb_count <= room and whole.point_count <= room;
            try testing.expectEqual(if (fits) truetype.TRUETYPE_OK else truetype.TRUETYPEERR_ROOM, cut.answer);
            try testing.expectEqual(whole.verb_count, cut.verb_count);
            try testing.expectEqual(whole.point_count, cut.point_count);
        }
    }

    /// A glyph's outline read into room for `verb_room` verbs and
    /// `point_room` points: nothing written after the room, and what was
    /// written counted right.
    fn segments(harness: *Harness, outline: *truetype.Outline, glyph: u32, verb_room: u32, point_room: u32) !Read {
        const verbs = harness.verbs;
        const points = harness.points;
        @memset(verbs[verb_room..][0..watched], untouched);
        @memset(points[point_room..][0..watched], untouched_point);
        var out: truetype.Segments = .{
            .verbs = verbs.ptr,
            .points = points.ptr,
            .verb_room = verb_room,
            .point_room = point_room,
            .verb_count = 0xAAAA,
            .point_count = 0xAAAA,
        };
        const answer = harness.rig.tb.GlyphSegments(outline, glyph, &out);
        for (verbs[verb_room..][0..watched]) |verb| try testing.expectEqual(untouched, verb);
        for (points[point_room..][0..watched]) |point| try testing.expect(point.x == untouched_point.x and point.y == untouched_point.y);

        switch (answer) {
            truetype.TRUETYPE_OK => {
                try testing.expect(out.verb_count <= verb_room and out.point_count <= point_room);
                // Each contour a move, its lines and curves, and a close;
                // the points are the ones the verbs take.
                var moves: u32 = 0;
                var closes: u32 = 0;
                var taken: u32 = 0;
                for (verbs[0..out.verb_count]) |verb| switch (verb) {
                    vector.SEG_MOVE => {
                        try testing.expectEqual(moves, closes);
                        moves += 1;
                        taken += 1;
                    },
                    vector.SEG_LINE => {
                        try testing.expectEqual(moves, closes + 1);
                        taken += 1;
                    },
                    vector.SEG_QUAD => {
                        try testing.expectEqual(moves, closes + 1);
                        taken += 2;
                    },
                    vector.SEG_CUBIC => {
                        try testing.expectEqual(moves, closes + 1);
                        taken += 3;
                    },
                    vector.SEG_CLOSE => {
                        try testing.expectEqual(moves, closes + 1);
                        closes += 1;
                    },
                    else => return error.NoVerb,
                };
                try testing.expectEqual(moves, closes);
                try testing.expectEqual(out.point_count, taken);
                for (points[0..out.point_count]) |point| try testing.expect(std.math.isFinite(point.x) and std.math.isFinite(point.y));
            },
            truetype.TRUETYPEERR_ROOM => try testing.expect(out.verb_count > verb_room or out.point_count > point_room),
            truetype.TRUETYPEERR_GLYPH, truetype.TRUETYPEERR_NOMEM => {
                try testing.expectEqual(@as(u32, 0), out.verb_count);
                try testing.expectEqual(@as(u32, 0), out.point_count);
            },
            else => return error.NoSuchAnswer,
        }
        return .{ .answer = answer, .verb_count = out.verb_count, .point_count = out.point_count };
    }

    /// One glyph rendered by its number, at each height into room for
    /// the largest glyph there is and into less. `has` says whether the
    /// font has outlines or pictures and a glyph of that number: such a
    /// glyph is rendered whatever its data says, and any other refused.
    /// Its pixels are of the font's `kind`, its box lies within a glyph's
    /// reach, its bytes are what the box says, the same whatever the
    /// room, and written only where they fit; no byte after them is
    /// written.
    fn renderGlyph(harness: *Harness, outline: *truetype.Outline, glyph: u32, has: bool, kind: fontimage.Kind) !void {
        const tb = harness.rig.tb;
        const pixels = harness.pixels;
        for (glyph_heights) |rows| {
            var whole = truetype.GlyphImage{ .pixels = pixels.ptr, .room = glyph_pixels, .size = 1, .kind = .mono1 };
            const answer = tb.RenderGlyph(outline, glyph, rows, &whole);
            try testing.expectEqual(kind, whole.kind);
            if (!has) {
                try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, answer);
                try testing.expectEqual(@as(u32, 0), whole.size);
                try testing.expectEqual(fontimage.Glyph{}, whole.glyph);
                for (pixels[0..watched]) |byte| try testing.expectEqual(untouched, byte);
                continue;
            }
            try testing.expectEqual(truetype.TRUETYPE_OK, answer);
            const box = whole.glyph;
            const size = whole.size;
            try testing.expectEqual(@as(u32, 0), box.data);
            try testing.expectEqual(fontimage.pitchOf(kind, box.width), @as(u32, box.pitch));
            try testing.expectEqual(@as(u32, box.pitch) * box.rows, size);
            try testing.expect(size <= glyph_pixels);
            try testing.expect((box.width == 0) == (box.rows == 0));
            try testing.expect(box.advance >= 0);
            // Sixteen lines to every side, and a pixel for the edge.
            const reach: i32 = @intCast(rows * 16 + 1);
            try testing.expect(box.left >= -reach and box.left + @as(i32, box.width) <= reach);
            try testing.expect(box.top >= -reach and box.top + @as(i32, box.rows) <= reach);
            for (pixels[size..][0..watched]) |byte| try testing.expectEqual(untouched, byte);
            if (box.width != 0) {
                harness.inked += 1;
                // A row of an odd width ends in half a byte of nothing.
                if (kind == .alpha4 and box.width & 1 == 1) {
                    for (0..box.rows) |y| try testing.expectEqual(@as(u8, 0), pixels[(y + 1) * box.pitch - 1] & 0x0F);
                }
            }
            @memset(pixels[0..size], untouched);

            // Less room: the same glyph, written when it fits.
            for ([_]u32{ 0, 1, size -| 1 }) |room| {
                var cut = truetype.GlyphImage{ .pixels = pixels.ptr, .room = room, .size = 1, .kind = .mono1 };
                const fits = size <= room;
                try testing.expectEqual(if (fits) truetype.TRUETYPE_OK else truetype.TRUETYPEERR_ROOM, tb.RenderGlyph(outline, glyph, rows, &cut));
                try testing.expectEqual(size, cut.size);
                try testing.expectEqual(box, cut.glyph);
                const written = if (fits) size else 0;
                for (pixels[written..][0..watched]) |byte| try testing.expectEqual(untouched, byte);
                @memset(pixels[0..written], untouched);
            }
        }
        // A line of no rows, or too tall, whatever the glyph.
        for ([_]u32{ 0, 4097, 0xFFFF_FFFF }) |rows| {
            var none = truetype.GlyphImage{ .pixels = pixels.ptr, .room = glyph_pixels, .size = 1, .kind = .mono1 };
            try testing.expectEqual(truetype.TRUETYPEERR_ROWS, tb.RenderGlyph(outline, glyph, rows, &none));
            try testing.expectEqual(@as(u32, 0), none.size);
            try testing.expectEqual(fontimage.Glyph{}, none.glyph);
            for (pixels[0..watched]) |byte| try testing.expectEqual(untouched, byte);
        }
    }

    /// A font image of `rows` rows, when the library renders one: sound,
    /// and of that height.
    fn render(harness: *Harness, outline: *truetype.Outline, rows: u32) !void {
        const image = harness.rig.tb.RenderFontImage(outline, rows, &ranges, ranges.len) orelse return;
        defer harness.rig.sys.FreeVec(image);
        const block: [*]const u8 = @ptrCast(image);
        try testing.expect(fontimage.check(block, image.size));
        try testing.expect(fontimage.sound(block, image.size));
        try testing.expectEqual(rows, @as(u32, image.height));
        for (ranges) |range| {
            var code = range.first;
            while (code <= range.last) : (code += 1) _ = fontimage.find(image, code);
        }
        harness.images += 1;
    }

    /// `source` as it is, then `rounds` times with a few changes made to
    /// it, every sixteenth time cut short instead.
    fn mutate(harness: *Harness, random: std.Random, source: []const u8, rounds: u32) !void {
        const file = harness.arena.place(source);
        try harness.exercise(file);
        if (source.len < 4) return;
        const targets = Targets.of(source);
        var changes: [4]Change = undefined;
        for (0..rounds) |round| {
            if (round % 16 == 15) {
                const length = cutOf(random, &targets, source.len);
                try harness.exercise(harness.arena.place(source[0..length]));
                // The whole of it again, where the cut one was.
                _ = harness.arena.place(source);
                continue;
            }
            const count = random.intRangeAtMost(usize, 1, changes.len);
            for (changes[0..count]) |*change| change.* = alter(random, &targets, file);
            try harness.exercise(file);
            // Taken back last first: one may lie over another.
            var left = count;
            while (left != 0) {
                left -= 1;
                const change = &changes[left];
                @memcpy(file[change.at..][0..change.len], change.before[0..change.len]);
            }
        }
    }

    /// One file read from a fuzzer.
    fn one(harness: *Harness, smith: *testing.Smith) anyerror!void {
        const length = smith.slice(harness.input);
        try harness.exercise(harness.arena.place(harness.input[0..length]));
    }
};

/// Where in a font a change is aimed: its table directories and a
/// collection's header, and the tables the library reads.
const Targets = struct {
    directories: [5]Span = undefined,
    directory_count: usize = 0,
    tables: [64]Span = undefined,
    table_count: usize = 0,

    const Span = struct {
        at: usize,
        len: usize,
    };

    /// The tables the library reads.
    const read = [_]*const [4]u8{ "CBDT", "CBLC", "cmap", "CFF ", "EBDT", "EBLC", "glyf", "head", "hhea", "hmtx", "kern", "loca", "maxp", "name", "OS/2", "post" };

    /// The targets of `source`, a sound font or collection.
    fn of(source: []const u8) Targets {
        var targets: Targets = .{};
        const count = truetype.fontCount(source);
        if (count != 0 and !truetype.isTrueType(source)) {
            const header: usize = @min(source.len, 12 + 4 * @as(usize, count));
            targets.directories[0] = .{ .at = 0, .len = header };
            targets.directory_count = 1;
        }
        for (0..@min(count, 4)) |index| {
            const start: usize = truetype.fontDirectory(source, @intCast(index)) orelse continue;
            const listed: usize = std.mem.readInt(u16, source[start + 4 ..][0..2], .big);
            const length: usize = @min(12 + listed * 16, source.len - start);
            targets.directories[targets.directory_count] = .{ .at = start, .len = length };
            targets.directory_count += 1;
            for (0..listed) |nth| {
                const record = start + 12 + nth * 16;
                if (record + 16 > source.len) break;
                const known = for (read) |name| {
                    if (std.mem.eql(u8, name, source[record..][0..4])) break true;
                } else false;
                if (!known) continue;
                const at: usize = std.mem.readInt(u32, source[record + 8 ..][0..4], .big);
                const len: usize = std.mem.readInt(u32, source[record + 12 ..][0..4], .big);
                if (len == 0 or at > source.len or source.len - at < len) continue;
                if (targets.table_count == targets.tables.len) break;
                targets.tables[targets.table_count] = .{ .at = at, .len = len };
                targets.table_count += 1;
            }
        }
        return targets;
    }
};

/// A change made to a file, and what was there before it.
const Change = struct {
    at: usize,
    len: usize,
    before: [4]u8,
};

/// Where a change is made: mostly in a table the library reads, half of
/// those in the table's first bytes, where its header is; sometimes in a
/// table directory; sometimes anywhere.
fn placeOf(random: std.Random, targets: *const Targets, length: usize) usize {
    const aim = random.uintLessThan(u8, 10);
    if (aim < 8 and targets.table_count != 0) {
        const table = targets.tables[random.uintLessThan(usize, targets.table_count)];
        const reach: usize = if (random.boolean()) @min(table.len, 512) else table.len;
        return table.at + random.uintLessThan(usize, reach);
    }
    if (aim < 9 and targets.directory_count != 0) {
        const directory = targets.directories[random.uintLessThan(usize, targets.directory_count)];
        return directory.at + random.uintLessThan(usize, directory.len);
    }
    return random.uintLessThan(usize, length);
}

/// One change to `file`: a byte, or a big-endian number of two or four
/// bytes, set to an end of its range, to a neighbour of what it was, to
/// the file's length, with one bit turned, or to anything.
fn alter(random: std.Random, targets: *const Targets, file: []u8) Change {
    const width: usize = switch (random.uintLessThan(u8, 10)) {
        0...3 => 1,
        4...7 => 2,
        else => 4,
    };
    const at = @min(placeOf(random, targets, file.len), file.len - width);
    var change: Change = .{ .at = at, .len = width, .before = @splat(0) };
    @memcpy(change.before[0..width], file[at..][0..width]);

    const bits: u5 = @intCast(width * 8 - 1);
    const top: u32 = @as(u32, 0xFFFF_FFFF) >> (31 - bits);
    var old: u32 = 0;
    for (file[at..][0..width]) |byte| old = old << 8 | byte;
    const value: u32 = top & switch (random.uintLessThan(u8, 12)) {
        0 => 0,
        1 => 1,
        2 => top,
        3 => top - 1,
        4 => top / 2,
        5 => top / 2 + 1,
        6 => old +% 1,
        7 => old -% 1,
        8 => @as(u32, @intCast(file.len)),
        9 => old ^ (@as(u32, 1) << random.uintAtMost(u5, bits)),
        else => random.int(u32),
    };
    for (file[at..][0..width], 0..) |*byte, nth| {
        const shift: u5 = @intCast((width - 1 - nth) * 8);
        byte.* = @truncate(value >> shift);
    }
    return change;
}

/// How long a file cut short is: mostly at an end of a table the library
/// reads, give or take a few bytes; often within the first bytes, where
/// the directory is; sometimes anywhere.
fn cutOf(random: std.Random, targets: *const Targets, length: usize) usize {
    const aim = random.uintLessThan(u8, 10);
    var cut: usize = undefined;
    if (aim < 5 and targets.table_count != 0) {
        const table = targets.tables[random.uintLessThan(usize, targets.table_count)];
        const edge = if (random.boolean()) table.at else table.at + table.len;
        cut = edge + random.uintLessThan(usize, 9) -| 4;
    } else if (aim < 8) {
        cut = random.uintLessThan(usize, @min(length, 1024));
    } else {
        cut = random.uintLessThan(usize, length);
    }
    return @min(cut, length - 1);
}

/// How many axes of a font are asked for, and set.
const axis_room = 40;

/// How many times each built font is changed, and each fetched one.
const built_rounds = 5000;
const fetched_rounds = 3000;

test "truetype: built fonts with bytes changed and cut short" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var harness = try Harness.up();
    var numbers = std.Random.DefaultPrng.init(0x7472_7565);
    for (harness.seeds) |*seed| try harness.mutate(numbers.random(), seed.written(), built_rounds);
    // The changes left most of the files fonts the library reads.
    try testing.expect(harness.opened >= harness.files / 2);
    try testing.expect(harness.outlines >= harness.files);
    try testing.expect(harness.images >= harness.files / 2);
    try testing.expect(harness.inked >= harness.files);
    // And the variable ones were read away from their default.
    try testing.expect(harness.placed >= built_rounds);
    try harness.down();
}

test "truetype: fetched fonts with bytes changed and cut short" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var harness = try Harness.up();
    var numbers = std.Random.DefaultPrng.init(0x4F54_544F);
    var fetched: u32 = 0;
    for (reference.fonts, 0..) |font, nth| {
        // A collection is listed once for each of its fonts there are
        // values for, and read once.
        if (nth != 0 and std.mem.eql(u8, font.file, reference.fonts[nth - 1].file)) continue;
        const bytes = reference.read(font) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);
        try harness.mutate(numbers.random(), bytes, fetched_rounds);
        fetched += 1;
    }
    try testing.expect(harness.opened >= harness.files / 2);
    try harness.down();
    if (fetched == 0) return error.SkipZigTest;
}

test "truetype: files from a fuzzer, and the built fonts as they are" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var harness = try Harness.up();
    var corpus: [seed_count][]const u8 = undefined;
    for (harness.seeds, &corpus) |*seed, *entry| entry.* = seed.entry();
    try testing.fuzz(&harness, Harness.one, .{ .corpus = &corpus });
    try harness.down();
}
