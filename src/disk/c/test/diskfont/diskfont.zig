// SPDX-License-Identifier: MIT
//! DiskFont: fonts opened through diskfont.library, and what it knows of.
//! Built against the SDK only.
//!
//!   DiskFont NAME,SIZE/N/M,DESIGNED/S,POINTS/S,LIST/S,GLYPHS/S,TEXT/K
//!
//! LIST prints every font AvailFonts finds - in memory, scaled, on the
//! disk - with its height and where it is.
//!
//! NAME with SIZEs opens each size with OpenDiskFont, FPF_DESIGNED when
//! DESIGNED is given, the sizes in points when POINTS is, prints what came back - its height, whether it was
//! drawn or scaled, loaded from a disk or in the ROM, and its kind of
//! pixels, and how long the open took - and draws a line in each in a window on the default public
//! screen, until the close gadget or Ctrl-C. The line is TEXT's when it
//! is given - in UTF-8, as the console types it - and a line of Latin
//! letters and digits otherwise.
//!
//! NAME with GLYPHS opens the family's outline and, for each SIZE or for
//! 16 rows, renders every glyph of it by its number with truetype.library
//! (RenderGlyph): it prints how many there are, how many have ink, the
//! bytes the largest takes and how long all of them took. Then it renders
//! a font image of that height and compares each glyph in it with the
//! same glyph by its number, byte for byte. No window is opened.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const diskfont = sdk.diskfont;
const truetype = sdk.truetype;
const fontimage = graphics.fontimage;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const RastPort = graphics.RastPort;
const rdargs = dos.rdargs;
const timer = sdk.devices.timer;

pub const COMMAND_NAME = "DiskFont";
const VERSION_STRING = "\x00$VER: DiskFont 1.5 (12.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME,SIZE/N/M,DESIGNED/S,POINTS/S,LIST/S,GLYPHS/S,TEXT/K";
const arg_name = 0;
const arg_size = 1;
const arg_designed = 2;
const arg_points = 3;
const arg_list = 4;
const arg_glyphs = 5;
const arg_text = 6;

const MSG_NOLIBRARY = "No %s\n";
const MSG_AVAIL = "%-24s %3d  %s\n";
const MSG_OPENED = "%s %d: got %d rows, %s, %s, %s, in %u us\n";
const MSG_NOFONT = "%s %d: none that will do\n";
const MSG_NOWINDOW = "No window\n";
const MSG_WAITING = "The close gadget or Ctrl-C closes the window\n";
const MSG_NOOUTLINE = "%s: no outline of that family\n";
const MSG_OLDLIBRARY = "%s is older than 1.5\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_NOTRENDERED = "%s %d: glyph %u answers %d\n";
const MSG_GLYPHS = "%s %d: %u glyphs rendered by number, %u with ink, the largest %u bytes, in %u us\n";
const MSG_SAME = "%s %d: %u of the image's %u glyphs are the same by number\n";

/// The line drawn in each font when TEXT names none.
const sample = "The quick brown fox - 0123456789 - ÄÖÜäöüß";

/// At most this many sizes at once.
const max_fonts = 12;

const margin = 8;
const gap = 4;

fn wattr(ib: *IntuitionBase, w: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(w, &ask);
    return value;
}

fn set(gb: *GraphicsBase, rp: *RastPort, tag: u32, data: usize) void {
    const tags = [_]TagItem{ .{ .tag = tag, .data = data }, .{} };
    gb.SetRPAttrs(rp, &tags);
}

fn kindName(kind: graphics.fontimage.Kind) [*:0]const u8 {
    return switch (kind) {
        .mono1 => "ink",
        .alpha4 => "coverage",
        .indexed8 => "colour",
        .rgba32 => "full colour",
        else => "?",
    };
}

/// Every font AvailFonts knows, printed.
/// The characters a font image is rendered of to compare glyphs with.
const compared = [_]truetype.CodeRange{ .{ .first = 0x20, .last = 0x7E }, .{ .first = 0xA0, .last = 0x24F } };

/// The room a glyph is rendered into.
const glyph_room = 256 * 1024;

/// The E-clock in microseconds, 0 without timer.device.
fn microseconds(timer_req: *timer.TimeRequest, timed: bool) u64 {
    if (!timed) return 0;
    const tb: *timer.TimerBase = @ptrCast(timer_req.node.device.?);
    var clock: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&clock);
    if (rate == 0) return 0;
    return clock.toTicks() * 1_000_000 / rate;
}

/// Every glyph of `name`'s outline rendered by its number at each size
/// of `argv`, and each compared with a font image's where it has one.
fn glyphs(sys: *ExecBase, dl: *DosBase, dfb: *DiskfontBase, name: [*:0]const u8, argv: *const [7]usize) i32 {
    const tt_lib = sys.OpenLibrary(truetype.TRUETYPENAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{truetype.TRUETYPENAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(tt_lib);
    if (tt_lib.version == 1 and tt_lib.revision < 5) {
        _ = Printf(dl, MSG_OLDLIBRARY, .{truetype.TRUETYPENAME});
        return dos.RETURN_FAIL;
    }
    const tb: *TrueTypeBase = @ptrCast(tt_lib);
    const of = dfb.OpenOutlineFont(name, graphics.FS_NORMAL) orelse {
        _ = Printf(dl, MSG_NOOUTLINE, .{name});
        return dos.RETURN_WARN;
    };
    defer dfb.CloseOutlineFont(of);
    const outline = of.outline;
    const pixels: [*]u8 = @ptrCast(sys.AllocVec(glyph_room, exec.MEMF_ANY) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    });
    defer sys.FreeVec(pixels);
    var timer_req: timer.TimeRequest = .{};
    const timed = sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) == 0;
    defer if (timed) sys.CloseDevice(&timer_req.node);
    var metrics: truetype.FontMetrics = .{};
    tb.FontMetrics(outline, &metrics);

    var result: i32 = dos.RETURN_OK;
    const sizes = rdargs.multi(argv[arg_size]);
    for (0..@max(sizes.len, 1)) |nth| {
        const rows: u32 = if (sizes.len == 0) 16 else @intCast(rdargs.multiNumber(argv[arg_size], nth));
        var inked: u32 = 0;
        var largest: u32 = 0;
        const began = microseconds(&timer_req, timed);
        var glyph: u32 = 0;
        while (glyph < metrics.glyph_count) : (glyph += 1) {
            var image = truetype.GlyphImage{ .pixels = pixels, .room = glyph_room };
            const answer = tb.RenderGlyph(outline, glyph, rows, &image);
            if (answer != truetype.TRUETYPE_OK) {
                _ = Printf(dl, MSG_NOTRENDERED, .{ name, rows, glyph, answer });
                return dos.RETURN_WARN;
            }
            if (image.size != 0) inked += 1;
            largest = @max(largest, image.size);
        }
        const took: u32 = @intCast(microseconds(&timer_req, timed) - began);
        _ = Printf(dl, MSG_GLYPHS, .{ name, rows, metrics.glyph_count, inked, largest, took });

        const image = tb.RenderFontImage(outline, rows, &compared, compared.len) orelse continue;
        defer sys.FreeVec(image);
        var in_image: u32 = 0;
        var same: u32 = 0;
        for (compared) |range| {
            var code = range.first;
            while (code <= range.last) : (code += 1) {
                const expected = fontimage.find(image, code) orelse continue;
                in_image += 1;
                var one = truetype.GlyphImage{ .pixels = pixels, .room = glyph_room };
                if (tb.RenderGlyph(outline, tb.GlyphIndex(outline, code), rows, &one) != truetype.TRUETYPE_OK) continue;
                const box = one.glyph;
                if (box.width != expected.width or box.rows != expected.rows or box.top != expected.top or
                    box.left != expected.left or box.advance != expected.advance or box.pitch != expected.pitch) continue;
                const wanted = fontimage.pixelsOf(image, expected);
                var differs = false;
                for (0..one.size) |at| {
                    if (pixels[at] != wanted[at]) differs = true;
                }
                if (!differs) same += 1;
            }
        }
        _ = Printf(dl, MSG_SAME, .{ name, rows, same, in_image });
        if (same != in_image) result = dos.RETURN_WARN;
    }
    return result;
}

fn list(sys: *ExecBase, dl: *DosBase, dfb: *DiskfontBase) void {
    var size: u32 = 1024;
    while (true) {
        const buffer = sys.AllocVec(size, exec.MEMF_ANY) orelse return;
        defer sys.FreeVec(buffer);
        const more = dfb.AvailFonts(buffer, size, diskfont.AFF_MEMORY | diskfont.AFF_DISK | diskfont.AFF_SCALED);
        if (more != 0) {
            size += more;
            continue;
        }
        const header: *const diskfont.AvailFontsHeader = @ptrCast(@alignCast(buffer));
        for (diskfont.availEntries(header)) |entry| {
            const where: [*:0]const u8 = if (entry.type & diskfont.AFF_DISK != 0)
                "disk"
            else if (entry.type & diskfont.AFF_SCALED != 0)
                "memory, scaled"
            else
                "memory";
            _ = Printf(dl, MSG_AVAIL, .{ entry.attr.name, @as(u32, entry.attr.y_size), where });
        }
        return;
    }
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [7]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const df_lib = sys.OpenLibrary(diskfont.DISKFONTNAME, diskfont.DISKFONT_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{diskfont.DISKFONTNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(df_lib);
    const dfb: *DiskfontBase = @ptrCast(df_lib);

    if (argv[arg_list] != 0) list(sys, dl, dfb);
    const name = rdargs.string(argv[arg_name]) orelse return dos.RETURN_OK;
    if (argv[arg_glyphs] != 0) return glyphs(sys, dl, dfb, name, &argv);

    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);

    var fonts: [max_fonts]?*graphics.TextFont = @splat(null);
    var count: usize = 0;
    defer for (fonts[0..count]) |font| if (font) |f| gb.CloseFont(f);
    const sizes = rdargs.multi(argv[arg_size]);
    var flags: graphics.FontFlags = if (argv[arg_designed] != 0) graphics.FPF_DESIGNED else 0;
    if (argv[arg_points] != 0) flags |= graphics.FPF_POINTS;
    // How long each open takes, by the E-clock when timer.device is there.
    var timer_req: timer.TimeRequest = .{};
    const timed = sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) == 0;
    defer if (timed) sys.CloseDevice(&timer_req.node);
    for (0..@min(sizes.len, max_fonts)) |i| {
        const rows: u16 = @intCast(rdargs.multiNumber(argv[arg_size], i));
        var clock: timer.EClockVal = .{};
        var rate: u32 = 0;
        var began: u64 = 0;
        if (timed) {
            const tb: *timer.TimerBase = @ptrCast(timer_req.node.device.?);
            rate = tb.ReadEClock(&clock);
            began = clock.toTicks();
        }
        const font = dfb.OpenDiskFont(&.{ .name = name, .y_size = rows, .flags = flags });
        var took: u32 = 0;
        if (timed and rate != 0) {
            const tb: *timer.TimerBase = @ptrCast(timer_req.node.device.?);
            _ = tb.ReadEClock(&clock);
            took = @intCast((clock.toTicks() - began) * 1_000_000 / rate);
        }
        fonts[count] = font;
        count += 1;
        const got = font orelse {
            _ = Printf(dl, MSG_NOFONT, .{ name, @as(u32, rows) });
            continue;
        };
        const image = got.image;
        const made: [*:0]const u8 = if (image.flags & graphics.FPF_DESIGNED != 0) "drawn" else "scaled";
        const from: [*:0]const u8 = if (got.flags & graphics.FPF_ROMFONT != 0) "ROM" else if (got.flags & graphics.FPF_DISKFONT != 0) "disk" else "memory";
        _ = Printf(dl, MSG_OPENED, .{ name, @as(u32, rows), @as(u32, image.height), made, from, kindName(image.kind), took });
    }

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const screen = ib.LockPubScreen(null) orelse return dos.RETURN_WARN;
    defer ib.UnlockPubScreen(null, screen);

    // The line: TEXT's, up to its NUL, or the sample.
    var line: []const u8 = sample;
    if (rdargs.string(argv[arg_text])) |text| {
        var length: usize = 0;
        while (text[length] != 0) length += 1;
        line = text[0..length];
    }
    // A RastPort of its own measures each line before the window is open.
    const measure = gb.CreateRastPortTagList(null) orelse return dos.RETURN_FAIL;
    defer gb.FreeRastPort(measure);
    var inner_w: i32 = 0;
    var inner_h: i32 = margin;
    for (fonts[0..count]) |font| {
        const f = font orelse continue;
        graphics.SetFont(gb, measure, f);
        inner_w = @max(inner_w, gb.TextLength(measure, line.ptr, @intCast(line.len)));
        inner_h += @as(i32, f.image.height) + gap;
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
        .{ .tag = wn.WA_Title, .data = @intFromPtr("DiskFont") },
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
    set(gb, rp, graphics.RPTAG_APen, graphics.penRGB(160, 160, 160));
    gb.RectFill(rp, &.{ .min_x = left, .min_y = top, .max_x = left + shown_w - 1, .max_y = top + shown_h - 1 });
    set(gb, rp, graphics.RPTAG_DrMd, graphics.DRMD_JAM1);
    set(gb, rp, graphics.RPTAG_APen, graphics.penRGB(255, 255, 255));

    var y: i32 = top + margin;
    for (fonts[0..count]) |font| {
        const f = font orelse continue;
        graphics.SetFont(gb, rp, f);
        gb.Move(rp, left + margin, y + @as(i32, f.image.baseline));
        gb.Text(rp, line.ptr, @intCast(line.len));
        y += @as(i32, f.image.height) + gap;
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
