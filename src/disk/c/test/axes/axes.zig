// SPDX-License-Identifier: MIT
//! Axes: a variable font's axes and the places it names on them, printed
//! and drawn. Built against the SDK only.
//!
//!   Axes FILE/A,SIZE/K/N,TEXT/K,NOWINDOW/S,SHAPED/S
//!
//! FILE is a TrueType or OpenType file, read whole and opened with
//! truetype.library. It prints each axis - its tag, its name, its range
//! and its default - and then every place the font names (`FontInstance`),
//! the first nine of them; of a font that names none, the least, the
//! default and the largest value of its first axis. For each place the
//! font is opened there (`TTA_Axes`) and its coordinates, its x height
//! and cap height and the advance of its `n` are printed, in the font's
//! units.
//!
//! Then each place is rendered SIZE rows tall (32 without it) as a font
//! image, put on graphics' list with AddFont, opened by its name as any
//! font is, and a line drawn in it in a window on the default public
//! screen: the place's name and TEXT, or a line of Latin letters and
//! digits. The window stays until the close gadget or Ctrl-C; NOWINDOW
//! prints and stops there.
//!
//! With SHAPED the text is laid out by the font's tables at each place
//! (truetypeshaping.library's `ShapeText`): pairs kerned and marks set
//! on their letters as that place has them. Each place's run is printed
//! - how many glyphs and how wide, then each glyph with the byte of the
//! text it stands for, its advance and its offsets, in the font's units
//! - and the line is drawn glyph by glyph (`RenderGlyph`) behind the
//! place's name, each glyph at the point the advances before it lead to
//! plus its offsets. TEXT is UTF-8; without it the line is one of
//! kerned pairs and of marks on letters.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const truetype = sdk.truetype;
const truetypeshaping = sdk.truetypeshaping;
const fontimage = graphics.fontimage;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;
const TrueTypeShapingBase = sdk.interface.truetypeshaping.TrueTypeShapingBase;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const RastPort = graphics.RastPort;
const rdargs = dos.rdargs;

pub const COMMAND_NAME = "Axes";
const VERSION_STRING = "\x00$VER: Axes 1.1 (12.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,SIZE/K/N,TEXT/K,NOWINDOW/S,SHAPED/S";
const arg_file = 0;
const arg_size = 1;
const arg_text = 2;
const arg_nowindow = 3;
const arg_shaped = 4;

const MSG_NOLIBRARY = "No %s\n";
const MSG_OLDLIBRARY = "%s is older than 1.8\n";
const MSG_NOTFONT = "%s is not a font truetype.library reads\n";
const MSG_NOAXES = "%s has no axes\n";
const MSG_AXIS = "%s  %-16s %s%d.%02d to %s%d.%02d, default %s%d.%02d%s\n";
const MSG_MORE = "%d axes, the first %d read\n";
const MSG_PLACE = "%-20s at";
const MSG_COORDINATE = " %d";
const MSG_MEASURES = ": x height %d, cap height %d, n %d wide\n";
const MSG_NOTOPENED = "%s: not opened there\n";
const MSG_OLDSHAPING = "%s is older than 1.3\n";
const MSG_NOTSHAPED = "  not shaped\n";
const MSG_SHAPED = "  %u glyphs, %d wide\n";
const MSG_GLYPH = "    glyph %u, byte %u: advance %d, offset %d %d\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_NOSCREEN = "No screen\n";
const MSG_NOWINDOW = "No window\n";
const MSG_WAITING = "The close gadget or Ctrl-C closes the window\n";

/// The line drawn at each place when TEXT names none.
const sample = "Hamburgefonstiv 0123456789 ÄÖÜäöüß";

/// The line shaped at each place when TEXT names none: pairs a font
/// sets closer, and marks on letters that have no glyph with the mark.
const shaped_sample = "AVATAR Wave, To Type. LT Yo q\u{301} j\u{301} x\u{323} q\u{308}\u{304}";

/// The characters rendered of each place.
const rendered = [_]truetype.CodeRange{ .{ .first = 0x20, .last = 0x7E }, .{ .first = 0xA0, .last = 0x24F } };

/// At most this many axes are read, and this many places shown.
const max_axes = 8;
const max_places = 9;

/// A shaped line has at most this many glyphs, a glyph's coverage this
/// many bytes, and its pixels as they are laid over the window these.
const max_glyphs = 256;
const coverage_room = 32 * 1024;
const colour_room = 8 * coverage_room;

const default_rows = 32;
const margin = 8;
const gap = 4;

/// One place on the font's axes, and the font rendered there.
const Place = struct {
    label: [48:0]u8 = @splat(0),
    values: [max_axes]truetype.AxisValue = @splat(.{ .tag = 0, .value = 0 }),
    font_name: [8:0]u8 = @splat(0),
    image: ?*fontimage.FontImage = null,
    text_font: graphics.TextFont = undefined,
    added: bool = false,
    font: ?*graphics.TextFont = null,
    /// With SHAPED: the font opened there, and how wide its shaped line
    /// is and how tall a line, in the font's units.
    outline: ?*truetype.Outline = null,
    run_units: i32 = 0,
    line_units: i32 = 0,
};

/// What SHAPED works in: a line's glyphs, one glyph's coverage, and its
/// pixels.
const Work = struct {
    glyphs: [max_glyphs]truetypeshaping.ShapedGlyph,
    coverage: [coverage_room]u8,
    colour: [colour_room]u8,
};

/// Where a shaped line is drawn, and what with.
const Drawing = struct {
    tb: *TrueTypeBase,
    gb: *GraphicsBase,
    rp: *RastPort,
    outline: *truetype.Outline,
    rows: u32,
    line_units: i32,
    work: *Work,

    /// A length in the font's units as pixels of the line, to the
    /// nearest.
    fn toPixels(drawing: *const Drawing, units: i64) i32 {
        const line: i64 = drawing.line_units;
        if (line <= 0) return 0;
        return @intCast(@divFloor(units * drawing.rows * 2 + line, line * 2));
    }

    /// Draws the run in white from (x0, y0), the line's left and top:
    /// each glyph rendered by its number and laid over what is there by
    /// its coverage. A glyph whose picture `work` has no room for is
    /// left out.
    fn draw(drawing: *const Drawing, run: []const truetypeshaping.ShapedGlyph, x0: i32, y0: i32) void {
        const work = drawing.work;
        var pen_units: i64 = 0;
        for (run) |shaped| {
            const at_units = pen_units + shaped.x_offset;
            pen_units += shaped.advance;
            var image = truetype.GlyphImage{ .pixels = &work.coverage, .room = coverage_room };
            if (drawing.tb.RenderGlyph(drawing.outline, shaped.glyph, drawing.rows, &image) != truetype.TRUETYPE_OK) continue;
            if (image.size == 0) continue;
            const box = image.glyph;
            const width: usize = box.width;
            var source: [*]const u8 = &work.coverage;
            var pitch: u32 = box.pitch;
            switch (image.kind) {
                .alpha4 => {
                    if (width * box.rows * 4 > colour_room) continue;
                    for (0..box.rows) |row| {
                        for (0..width) |column| {
                            const pair = work.coverage[row * box.pitch + column / 2];
                            const covered: u8 = if (column & 1 == 0) pair >> 4 else pair & 0xF;
                            work.colour[(row * width + column) * 4 ..][0..4].* = .{ 255, 255, 255, covered * 17 };
                        }
                    }
                    source = &work.colour;
                    pitch = box.width * 4;
                },
                .rgba32 => {},
                else => continue,
            }
            const x = x0 + drawing.toPixels(at_units) + box.left;
            const y = y0 - drawing.toPixels(shaped.y_offset) + box.top;
            const area = graphics.Rect{ .min_x = x, .min_y = y, .max_x = x + box.width, .max_y = y + box.rows };
            drawing.gb.BlendPixelArray(drawing.rp, source, pitch, @intFromEnum(sdk.rtg.bitmaps.PixelFormat.rgba32), 0, 0, &area);
        }
    }
};

/// A value in hundredths, as the three arguments `%s%d.%02d` takes.
const Hundredths = struct {
    sign: [*:0]const u8,
    whole: u32,
    part: u32,

    fn of(value: f32) Hundredths {
        const scaled: i64 = @intFromFloat(@round(@as(f64, value) * 100));
        const size: u64 = @abs(scaled);
        return .{ .sign = if (scaled < 0) "-" else "", .whole = @intCast(size / 100), .part = @intCast(size % 100) };
    }
};

fn wattr(ib: *IntuitionBase, w: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const tags = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(w, &tags);
    return value;
}

fn set(gb: *GraphicsBase, rp: *RastPort, tag: u32, data: usize) void {
    const tags = [_]TagItem{ .{ .tag = tag, .data = data }, .{} };
    gb.SetRPAttrs(rp, &tags);
}

/// A tag's four letters, NUL-terminated.
fn lettersOf(tag: u32) [4:0]u8 {
    return .{ @truncate(tag >> 24), @truncate(tag >> 16), @truncate(tag >> 8), @truncate(tag) };
}

/// `text` into `out` from `at`, cut to what `out` has room for; where it
/// ends.
fn append(out: []u8, at: usize, text: []const u8) usize {
    const count = @min(text.len, out.len - at);
    @memcpy(out[at..][0..count], text[0..count]);
    return at + count;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const path = rdargs.string(argv[arg_file]) orelse return dos.RETURN_FAIL;
    var rows: u32 = default_rows;
    if (rdargs.number(argv[arg_size])) |asked| rows = @intCast(@max(8, @min(asked, 200)));

    var length: usize = 0;
    const file = dl.ReadFile(path, 0xFFFF_FFFF, exec.MEMF_ANY, &length) orelse {
        _ = dl.PrintFault(dl.IoErr(), path);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(file);
    const bytes: [*]const u8 = @ptrCast(file);
    const size: u32 = @intCast(length);

    const tt_lib = sys.OpenLibrary(truetype.TRUETYPENAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{truetype.TRUETYPENAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(tt_lib);
    if (tt_lib.version == 1 and tt_lib.revision < 8) {
        _ = Printf(dl, MSG_OLDLIBRARY, .{truetype.TRUETYPENAME});
        return dos.RETURN_FAIL;
    }
    const tb: *TrueTypeBase = @ptrCast(tt_lib);

    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);

    // The line: TEXT's, up to its NUL, or the sample.
    var text: []const u8 = if (argv[arg_shaped] != 0) shaped_sample else sample;
    if (rdargs.string(argv[arg_text])) |given| {
        var given_len: usize = 0;
        while (given[given_len] != 0) given_len += 1;
        text = given[0..given_len];
    }

    // SHAPED: the library that lays the line out, and room to work in.
    var shaper: ?*TrueTypeShapingBase = null;
    var shaper_lib: ?@TypeOf(tt_lib) = null;
    var work: ?*Work = null;
    defer {
        if (work) |room| sys.FreeVec(room);
        if (shaper_lib) |opened| sys.CloseLibrary(opened);
    }
    if (argv[arg_shaped] != 0) {
        const shaping_lib = sys.OpenLibrary(truetypeshaping.TRUETYPESHAPINGNAME, truetypeshaping.TRUETYPESHAPING_VERSION) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{truetypeshaping.TRUETYPESHAPINGNAME});
            return dos.RETURN_FAIL;
        };
        shaper_lib = shaping_lib;
        shaper = @ptrCast(shaping_lib);
        if (shaping_lib.version == 1 and shaping_lib.revision < 3) {
            _ = Printf(dl, MSG_OLDSHAPING, .{truetypeshaping.TRUETYPESHAPINGNAME});
            return dos.RETURN_FAIL;
        }
        work = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(Work), exec.MEMF_ANY) orelse {
            _ = Printf(dl, MSG_NOMEMORY, .{});
            return dos.RETURN_FAIL;
        }));
    }

    var places: [max_places]Place = @splat(.{});
    var count: usize = 0;
    var axis_count: u32 = 0;
    {
        const outline = tb.OpenOutline(bytes, size, null) orelse {
            _ = Printf(dl, MSG_NOTFONT, .{path});
            return dos.RETURN_FAIL;
        };
        defer tb.CloseOutline(outline);

        // The axes.
        var axes: [max_axes]truetype.Axis = undefined;
        const axis_total = tb.FontAxes(outline, &axes, max_axes);
        if (axis_total == 0) {
            _ = Printf(dl, MSG_NOAXES, .{path});
            return dos.RETURN_WARN;
        }
        axis_count = if (axis_total > max_axes) max_axes else axis_total;
        if (axis_total > max_axes) _ = Printf(dl, MSG_MORE, .{ axis_total, axis_count });
        for (axes[0..axis_count]) |axis| {
            const letters = lettersOf(axis.tag);
            var name: [32:0]u8 = @splat(0);
            _ = tb.FontName(outline, axis.name, &name, name.len);
            const least = Hundredths.of(axis.minimum);
            const middle = Hundredths.of(axis.default);
            const most = Hundredths.of(axis.maximum);
            _ = Printf(dl, MSG_AXIS, .{
                @as([*:0]const u8, &letters), @as([*:0]const u8, &name),
                least.sign,                   least.whole,
                least.part,                   most.sign,
                most.whole,                   most.part,
                middle.sign,                  middle.whole,
                middle.part,                  @as([*:0]const u8, if (axis.hidden) ", hidden" else ""),
            });
        }

        // The places the font names.
        while (count < max_places) {
            const place = &places[count];
            const name = tb.FontInstance(outline, @intCast(count), &place.values, max_axes);
            if (name == 0) break;
            if (tb.FontName(outline, name, &place.label, place.label.len) == 0) _ = append(&place.label, 0, "unnamed");
            count += 1;
        }
        // None: the ends of the first axis and its default, the others
        // at theirs.
        if (count == 0) {
            const first = axes[0];
            const stops = [_]f32{ first.minimum, first.default, first.maximum };
            const letters = lettersOf(first.tag);
            for (stops, 0..) |stop, nth| {
                if (nth != 0 and stop == stops[nth - 1]) continue;
                const place = &places[count];
                for (axes[0..axis_count], 0..) |axis, i| place.values[i] = .{ .tag = axis.tag, .value = axis.default };
                place.values[0].value = stop;
                const at = append(&place.label, 0, &letters);
                _ = append(&place.label, at, switch (nth) {
                    0 => " least",
                    1 => " default",
                    else => " most",
                });
                count += 1;
            }
        }
    }

    defer for (places[0..count]) |*place| {
        if (place.font) |font| gb.CloseFont(font);
        if (place.added) _ = gb.RemFont(&place.text_font);
        if (place.image) |image| sys.FreeVec(image);
        if (place.outline) |outline| tb.CloseOutline(outline);
    };

    // The font at each place: what it measures there, and a size of it.
    const draw = argv[arg_nowindow] == 0;
    for (places[0..count], 0..) |*place, number| {
        const tags = [_]TagItem{
            .{ .tag = truetype.TTA_Axes, .data = @intFromPtr(&place.values) },
            .{ .tag = truetype.TTA_AxisCount, .data = axis_count },
            .{},
        };
        const label: [*:0]const u8 = &place.label;
        const outline = tb.OpenOutline(bytes, size, &tags) orelse {
            _ = Printf(dl, MSG_NOTOPENED, .{label});
            continue;
        };
        // SHAPED draws from the outline; without it it is closed here.
        if (shaper != null) place.outline = outline;
        defer if (shaper == null) tb.CloseOutline(outline);
        var coordinates: [max_axes]i16 = @splat(0);
        _ = tb.FontCoordinates(outline, &coordinates, max_axes);
        var measures: truetype.FontMetrics = .{};
        tb.FontMetrics(outline, &measures);
        _ = Printf(dl, MSG_PLACE, .{label});
        for (coordinates[0..axis_count]) |coordinate| _ = Printf(dl, MSG_COORDINATE, .{@as(i32, coordinate)});
        _ = Printf(dl, MSG_MEASURES, .{ measures.x_height, measures.cap_height, tb.GlyphAdvance(outline, tb.GlyphIndex(outline, 'n')) });
        if (shaper) |sb| {
            const room = work.?;
            var run: truetypeshaping.ShapedRun = .{ .glyphs = &room.glyphs, .room = max_glyphs };
            if (sb.ShapeText(outline, text.ptr, @intCast(text.len), truetypeshaping.TTS_LEFT_TO_RIGHT, truetypeshaping.TTS_LANGUAGE_DEFAULT, null, &run) != truetypeshaping.TTS_OK) {
                _ = Printf(dl, MSG_NOTSHAPED, .{});
            } else {
                var run_units: i32 = 0;
                for (room.glyphs[0..run.count]) |shaped| run_units +|= shaped.advance;
                place.run_units = run_units;
                place.line_units = measures.ascender - measures.descender;
                _ = Printf(dl, MSG_SHAPED, .{ run.count, run_units });
                for (room.glyphs[0..run.count]) |shaped| {
                    _ = Printf(dl, MSG_GLYPH, .{ shaped.glyph, shaped.cluster, shaped.advance, shaped.x_offset, shaped.y_offset });
                }
            }
        }
        if (!draw) continue;

        const image = tb.RenderFontImage(outline, rows, &rendered, rendered.len) orelse {
            _ = Printf(dl, MSG_NOMEMORY, .{});
            continue;
        };
        place.image = image;
        _ = append(&place.font_name, 0, "axes-");
        place.font_name[5] = '0' + @as(u8, @intCast(number));
        place.text_font = .{ .node = .{ .name = &place.font_name }, .image = image, .flags = graphics.FPF_DISKFONT };
        if (!gb.AddFont(&place.text_font)) continue;
        place.added = true;
        place.font = gb.OpenFont(&.{ .name = &place.font_name, .y_size = image.height });
    }
    if (!draw) return dos.RETURN_OK;

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_WARN;
    };
    defer ib.UnlockPubScreen(null, screen);

    // Each place's line: its name, then the text - with SHAPED the name
    // only, and the shaped line behind it. A RastPort of its own
    // measures them before the window is open.
    var lines: [max_places][200]u8 = undefined;
    var line_lens: [max_places]usize = @splat(0);
    var label_widths: [max_places]i32 = @splat(0);
    const measure = gb.CreateRastPortTagList(null) orelse return dos.RETURN_FAIL;
    defer gb.FreeRastPort(measure);
    var inner_w: i32 = 0;
    var inner_h: i32 = margin;
    for (places[0..count], 0..) |*place, i| {
        const font = place.font orelse continue;
        var label_len: usize = 0;
        while (place.label[label_len] != 0) label_len += 1;
        var at = append(&lines[i], 0, place.label[0..label_len]);
        at = append(&lines[i], at, "  ");
        line_lens[i] = if (shaper == null) append(&lines[i], at, text) else at;
        graphics.SetFont(gb, measure, font);
        label_widths[i] = gb.TextLength(measure, &lines[i], @intCast(line_lens[i]));
        var line_w = label_widths[i];
        if (place.line_units > 0) {
            line_w += @intCast(@divFloor(@as(i64, place.run_units) * rows, place.line_units) + 1);
        }
        inner_w = @max(inner_w, line_w);
        inner_h += @as(i32, font.image.height) + gap;
    }
    if (inner_w == 0) return dos.RETURN_WARN;
    inner_w += 2 * margin;
    inner_h += margin - gap;

    const window_tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 20 },
        .{ .tag = wn.WA_Top, .data = 30 },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(inner_w) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(inner_h) },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Axes") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_SmartRefresh, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{},
    };
    const w = ib.OpenWindowTagList(&window_tags) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(w);

    const rp: *RastPort = @ptrFromInt(wattr(ib, w, wn.WA_RastPort));
    const left: i32 = @intCast(wattr(ib, w, wn.WA_BorderLeft));
    const top: i32 = @intCast(wattr(ib, w, wn.WA_BorderTop));
    const shown_w: i32 = @intCast(wattr(ib, w, wn.WA_InnerWidth));
    const shown_h: i32 = @intCast(wattr(ib, w, wn.WA_InnerHeight));

    set(gb, rp, graphics.RPTAG_APen, graphics.penRGB(0, 0, 0));
    gb.RectFill(rp, &.{ .min_x = left, .min_y = top, .max_x = left + shown_w, .max_y = top + shown_h });
    set(gb, rp, graphics.RPTAG_DrMd, graphics.DRMD_JAM1);
    set(gb, rp, graphics.RPTAG_APen, graphics.penRGB(255, 255, 255));

    var y: i32 = top + margin;
    for (places[0..count], 0..) |*place, i| {
        const font = place.font orelse continue;
        graphics.SetFont(gb, rp, font);
        gb.Move(rp, left + margin, y + @as(i32, font.image.baseline));
        gb.Text(rp, &lines[i], @intCast(line_lens[i]));
        if (shaper) |sb| shaped_line: {
            // Shaped again, as it was to be printed: one line's glyphs
            // are kept at a time.
            const room = work.?;
            const outline = place.outline orelse break :shaped_line;
            var run: truetypeshaping.ShapedRun = .{ .glyphs = &room.glyphs, .room = max_glyphs };
            if (sb.ShapeText(outline, text.ptr, @intCast(text.len), truetypeshaping.TTS_LEFT_TO_RIGHT, truetypeshaping.TTS_LANGUAGE_DEFAULT, null, &run) != truetypeshaping.TTS_OK) break :shaped_line;
            const drawing = Drawing{ .tb = tb, .gb = gb, .rp = rp, .outline = outline, .rows = rows, .line_units = place.line_units, .work = room };
            drawing.draw(room.glyphs[0..run.count], left + margin + label_widths[i], y);
        }
        y += @as(i32, font.image.height) + gap;
    }

    _ = Printf(dl, MSG_WAITING, .{});
    var open = true;
    while (open) {
        const got = ib.WaitIMsg(w, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        while (ib.GetIMsg(w)) |im| {
            const class = im.class;
            ib.ReplyIMsg(im);
            if (class == wn.IDCMP_CLOSEWINDOW) open = false;
        }
    }
    return dos.RETURN_OK;
}
