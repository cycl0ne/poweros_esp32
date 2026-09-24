// SPDX-License-Identifier: MIT
//! Plasma: a picture of colour numbers in a window of its own, its colours
//! running through it. Built against the SDK only.
//!
//!   Plasma FRAMES/N,WIDTH/K/N,HEIGHT/K/N
//!
//! It opens a window on the default public screen and draws into it until
//! the close gadget is used, FRAMES frames have gone by, or Ctrl-C. WIDTH
//! and HEIGHT are the size of the part inside the border; the window may be
//! sized, and the picture is made again at the new size.
//!
//! The picture is a byte a pixel - three waves added, across, down and
//! along the diagonal - and goes into the window through a table of 256
//! pens with WriteLUTPixelArray, the way an old game's chunky screen or a
//! decoder's indexed frame would. Each frame the table is turned a step and
//! the same bytes go down again, so the colours move while the picture does
//! not. Under it, a bar shows the whole table as it stands - a strip of
//! rgba32 pixels of the program's own, put down with WritePixelArray and
//! converted to the display's format on the way.
//!
//! Its menus, held with the menu button: Project pauses (right-Amiga P),
//! makes the waves themselves move as well (W), and quits (Q); Palette is
//! the table's colours - the wheel, fire, the sea, grey; Speed is how far
//! the table turns a frame. Each choice checks itself and unchecks the
//! others of its menu.
//!
//! A window's RastPort is drawn through with its layer held, since
//! graphics.library knows nothing of layers and cannot take it itself.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const LayersBase = sdk.interface.layers.LayersBase;
const wn = intuition.windows;
const mn = intuition.menus;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const Pen = graphics.Pen;
const RastPort = graphics.RastPort;
const PixelFormat = sdk.rtg.bitmaps.PixelFormat;

pub const COMMAND_NAME = "Plasma";
const VERSION_STRING = "\x00$VER: Plasma 1.0 (22.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FRAMES/N,WIDTH/K/N,HEIGHT/K/N";
const arg_frames = 0;
const arg_width = 1;
const arg_height = 2;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display, or it shows another screen\n";
const MSG_NOWINDOW = "No window - the screen would not open one that size\n";
const MSG_NOMEMORY = "No memory for a %dx%d picture\n";
const MSG_RUNNING = "Plasma %dx%d through 256 pens - the menu button for its menus, the close gadget or Ctrl-C stops it\n";
const MSG_DONE = "%d frames\n";

/// The smallest interior worth drawing in, and what one is by default.
const min_width = 96;
const min_height = 64;
const default_width = 320;
const default_height = 200;
/// How tall the bar showing the table is, under the picture.
const bar_height = 12;

// --- the waves ---------------------------------------------------------------

/// A turn in 256 steps, scaled to 127, built by the compiler.
const sine: [256]i32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]i32 = undefined;
    for (0..256) |i| {
        const angle = @as(f64, @floatFromInt(i)) * (2.0 * 3.14159265358979323846) / 256.0;
        table[i] = @intFromFloat(@round(@sin(angle) * 127.0));
    }
    break :blk table;
};

fn wave(step: i32) i32 {
    return sine[@intCast(step & 255)];
}

/// The picture: each byte three waves added and brought to 0..255, the
/// waves moved along by `phase`.
fn makePicture(picture: [*]u8, width: usize, height: usize, phase: i32) void {
    for (0..height) |y| {
        const yi: i32 = @intCast(y);
        for (0..width) |x| {
            const xi: i32 = @intCast(x);
            const sum = wave(xi * 2 + phase) + wave(yi * 3 - phase) + wave((xi + yi) * 2 + phase * 2) + 3 * 127;
            picture[y * width + x] = @intCast(@divTrunc(sum * 255, 6 * 127));
        }
    }
}

// --- the palettes --------------------------------------------------------------

const Palette = enum(u32) { wheel, fire, sea, grey };

/// Between two colours, `t` of 256 of the way.
fn mix(a: [3]i32, b: [3]i32, t: i32) Pen {
    var c: [3]i32 = undefined;
    for (0..3) |i| c[i] = a[i] + @divTrunc((b[i] - a[i]) * t, 256);
    return graphics.penRGB(@intCast(c[0]), @intCast(c[1]), @intCast(c[2]));
}

/// Along stops of a colour ramp, `n` of 256, there and back again so the
/// table joins up with itself when it is turned.
fn ramp(stops: []const [3]i32, n: i32) Pen {
    const folded = if (n < 128) n * 2 else (255 - n) * 2;
    const span = @divTrunc(256, @as(i32, @intCast(stops.len - 1)));
    const at: usize = @intCast(@min(@divTrunc(folded, span), @as(i32, @intCast(stops.len - 2))));
    return mix(stops[at], stops[at + 1], @min(255, @divTrunc((folded - @as(i32, @intCast(at)) * span) * 256, span)));
}

/// Colour number `n` of a palette.
fn colourOf(palette: Palette, n: i32) Pen {
    return switch (palette) {
        .wheel => graphics.penRGB(@intCast(128 + wave(n)), @intCast(128 + wave(n + 85)), @intCast(128 + wave(n + 170))),
        .fire => ramp(&.{ .{ 0, 0, 0 }, .{ 200, 0, 0 }, .{ 255, 160, 0 }, .{ 255, 255, 200 } }, n),
        .sea => ramp(&.{ .{ 0, 0, 40 }, .{ 0, 60, 200 }, .{ 0, 200, 220 }, .{ 230, 255, 255 } }, n),
        .grey => ramp(&.{ .{ 0, 0, 0 }, .{ 255, 255, 255 } }, n),
    };
}

// --- the menus -------------------------------------------------------------------

/// Every item of the strip: which menu it is in, what it is, and for a
/// choice what it sets.
const Entry = struct {
    word: [*:0]const u8,
    menu: u8,
    flags: u32 = 0,
    command: u8 = 0,
    value: u32 = 0,
};

const project_menu = 0;
const palette_menu = 1;
const speed_menu = 2;
const titles = [_][*:0]const u8{ "Project", "Palette", "Speed" };

const entries = [_]Entry{
    .{ .word = "Pause", .menu = project_menu, .flags = mn.CHECKIT | mn.MENUTOGGLE | mn.COMMSEQ, .command = 'P' },
    .{ .word = "Waves", .menu = project_menu, .flags = mn.CHECKIT | mn.MENUTOGGLE | mn.COMMSEQ, .command = 'W' },
    .{ .word = "Quit", .menu = project_menu, .flags = mn.COMMSEQ, .command = 'Q' },
    .{ .word = "Wheel", .menu = palette_menu, .flags = mn.CHECKIT, .value = @intFromEnum(Palette.wheel) },
    .{ .word = "Fire", .menu = palette_menu, .flags = mn.CHECKIT, .value = @intFromEnum(Palette.fire) },
    .{ .word = "Sea", .menu = palette_menu, .flags = mn.CHECKIT, .value = @intFromEnum(Palette.sea) },
    .{ .word = "Grey", .menu = palette_menu, .flags = mn.CHECKIT, .value = @intFromEnum(Palette.grey) },
    .{ .word = "Slow", .menu = speed_menu, .flags = mn.CHECKIT, .value = 1 },
    .{ .word = "Normal", .menu = speed_menu, .flags = mn.CHECKIT, .value = 3 },
    .{ .word = "Fast", .menu = speed_menu, .flags = mn.CHECKIT, .value = 8 },
};
const pause_entry = 0;
const waves_entry = 1;
const quit_entry = 2;

/// The strip, linked in place: each choice of Palette and Speed rules out
/// the others of its menu.
const Strip = struct {
    texts: [entries.len]intuition.IntuiText,
    items: [entries.len]intuition.MenuItem,
    menus: [titles.len]intuition.Menu,

    fn make(strip: *Strip, ib: *IntuitionBase, dri: *intuition.DrawInfo) void {
        const row: i32 = 10;
        const width: i32 = 110;
        var last: [titles.len]?*intuition.MenuItem = @splat(null);
        var place: [titles.len]u5 = @splat(0);
        var first_of: [titles.len]usize = @splat(0);
        var count_of: [titles.len]u5 = @splat(0);
        for (entries, 0..) |entry, i| {
            if (count_of[entry.menu] == 0) first_of[entry.menu] = i;
            count_of[entry.menu] += 1;
        }
        for (entries, 0..) |entry, i| {
            strip.texts[i] = .{
                .front_pen = dri.pens[intuition.screens.BARDETAILPEN],
                .left = if (entry.flags & mn.CHECKIT != 0) mn.CHECKWIDTH else 4,
                .top = 1,
                .text = entry.word,
            };
            const at = place[entry.menu];
            place[entry.menu] += 1;
            const all: u32 = (@as(u32, 1) << count_of[entry.menu]) - 1;
            strip.items[i] = .{
                .top = @as(i32, at) * row,
                .width = width,
                .height = row,
                .flags = mn.ITEMTEXT | mn.ITEMENABLED | mn.HIGHCOMP | entry.flags,
                .mutual_exclude = if (entry.menu != project_menu) all & ~(@as(u32, 1) << at) else 0,
                .item_fill = &strip.texts[i],
                .command = entry.command,
            };
            if (last[entry.menu]) |before| before.next_item = &strip.items[i];
            last[entry.menu] = &strip.items[i];
        }
        var left: i32 = 0;
        for (titles, 0..) |title, m| {
            const measure = intuition.IntuiText{ .text = title, .font = dri.font };
            const title_width = ib.IntuiTextLength(&measure) + 8;
            strip.menus[m] = .{
                .left = left,
                .width = title_width,
                .name = title,
                .first_item = &strip.items[first_of[m]],
                .next_menu = if (m + 1 < titles.len) &strip.menus[m + 1] else null,
            };
            left += title_width + 8;
        }
    }

    /// Check the choice of `menu` whose value is `value`, and no other.
    fn check(strip: *Strip, menu: u8, value: u32) void {
        for (entries, 0..) |entry, i| {
            if (entry.menu != menu) continue;
            if (entry.value == value) strip.items[i].flags |= mn.CHECKED else strip.items[i].flags &= ~mn.CHECKED;
        }
    }

    /// The value of the choice of `menu` that is checked, or `otherwise`.
    fn checked(strip: *const Strip, menu: u8, otherwise: u32) u32 {
        for (entries, 0..) |entry, i| {
            if (entry.menu == menu and strip.items[i].flags & mn.CHECKED != 0) return entry.value;
        }
        return otherwise;
    }

    fn isChecked(strip: *const Strip, index: usize) bool {
        return strip.items[index].flags & mn.CHECKED != 0;
    }

    fn indexOf(strip: *Strip, item: *intuition.MenuItem) usize {
        for (&strip.items, 0..) |*each, i| {
            if (each == item) return i;
        }
        return entries.len;
    }
};

// --- the pictures ------------------------------------------------------------------

/// The picture and the bar under it, for an interior of one size.
const Pictures = struct {
    picture: [*]u8,
    bar: [*]u8,
    width: usize,
    height: usize,

    /// Both for an interior `width` by `height`: the picture takes all of it
    /// but the bar. Null without memory.
    fn make(sys: *ExecBase, width: i32, height: i32) ?Pictures {
        const w: usize = @intCast(width);
        const h: usize = @intCast(height - bar_height);
        const picture = sys.AllocVec(w * h, exec.MEMF_ANY) orelse return null;
        const bar = sys.AllocVec(w * bar_height * 4, exec.MEMF_ANY) orelse {
            sys.FreeVec(picture);
            return null;
        };
        return .{ .picture = @ptrCast(picture), .bar = @ptrCast(bar), .width = w, .height = h };
    }

    fn free(p: Pictures, sys: *ExecBase) void {
        sys.FreeVec(p.bar);
        sys.FreeVec(p.picture);
    }

    /// The bar: the table left to right, as rgba32 - bytes r, g, b, a.
    fn fillBar(p: Pictures, table: *const [256]Pen) void {
        for (0..p.width) |x| {
            const pen = table[x * 256 / p.width];
            for (0..bar_height) |y| {
                const at = p.bar + (y * p.width + x) * 4;
                at[0] = @truncate(pen >> 16);
                at[1] = @truncate(pen >> 8);
                at[2] = @truncate(pen);
                at[3] = 0xFF;
            }
        }
    }
};

fn wattr(ib: *IntuitionBase, w: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(w, &ask);
    return value;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const frames: u32 = if (argv[arg_frames] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_frames])).*) else 0;
    const want_w: i32 = if (argv[arg_width] != 0) @as(*const i32, @ptrFromInt(argv[arg_width])).* else default_width;
    const want_h: i32 = if (argv[arg_height] != 0) @as(*const i32, @ptrFromInt(argv[arg_height])).* else default_height;

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);
    const lay_lib = sys.OpenLibrary(sdk.layers.LAYERSNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{sdk.layers.LAYERSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(lay_lib);
    const lb: *LayersBase = @ptrCast(lay_lib);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_WARN;
    };
    defer ib.UnlockPubScreen(null, screen);

    const window_tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 120 },
        .{ .tag = wn.WA_Top, .data = 80 },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(@max(min_width, want_w)) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(@max(min_height, want_h) + bar_height) },
        .{ .tag = wn.WA_MinWidth, .data = min_width },
        .{ .tag = wn.WA_MinHeight, .data = min_height },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Plasma") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_MENUPICK },
        .{},
    };
    const w = ib.OpenWindowTagList(&window_tags) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(w);
    const rp: *RastPort = @ptrFromInt(wattr(ib, w, wn.WA_RastPort));
    const layer: *sdk.layers.Layer = @ptrFromInt(wattr(ib, w, wn.WA_Layer));
    const port: *exec.MsgPort = @ptrFromInt(wattr(ib, w, wn.WA_UserPort));

    const dri = ib.GetScreenDrawInfo(screen);
    defer ib.FreeScreenDrawInfo(screen, dri);
    var strip: Strip = undefined;
    strip.make(ib, dri);
    strip.check(palette_menu, @intFromEnum(Palette.wheel));
    strip.check(speed_menu, 3);
    _ = ib.SetMenuStrip(w, &strip.menus[0]);
    defer ib.ClearMenuStrip(w);

    var inner_w: i32 = @intCast(wattr(ib, w, wn.WA_InnerWidth));
    var inner_h: i32 = @intCast(wattr(ib, w, wn.WA_InnerHeight));
    var pictures = Pictures.make(sys, inner_w, inner_h) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{ inner_w, inner_h });
        return dos.RETURN_FAIL;
    };
    defer pictures.free(sys);
    makePicture(pictures.picture, pictures.width, pictures.height, 0);
    _ = Printf(dl, MSG_RUNNING, .{ inner_w, inner_h - bar_height });

    var table: [256]Pen = undefined;
    var palette: Palette = .wheel;
    var speed: i32 = 3;
    var turn: i32 = 0;
    var phase: i32 = 0;
    var drawn: u32 = 0;
    var running = true;
    while (running and (frames == 0 or drawn < frames)) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
        while (sys.GetMsg(port)) |m| {
            const im: *intuition.IntuiMessage = @ptrCast(@alignCast(m));
            const class = im.class;
            const code = im.code;
            sys.ReplyMsg(m);
            if (class == wn.IDCMP_CLOSEWINDOW) running = false;
            if (class != wn.IDCMP_MENUPICK) continue;
            var number = code;
            while (number != mn.MENUNULL) {
                const item = ib.ItemAddress(&strip.menus[0], number) orelse break;
                if (strip.indexOf(item) == quit_entry) running = false;
                number = item.next_select;
            }
            palette = @enumFromInt(strip.checked(palette_menu, @intFromEnum(palette)));
            speed = @intCast(strip.checked(speed_menu, @intCast(speed)));
        }
        if (!running) break;

        // A window sized wants pictures of the new size.
        const now_w: i32 = @intCast(wattr(ib, w, wn.WA_InnerWidth));
        const now_h: i32 = @intCast(wattr(ib, w, wn.WA_InnerHeight));
        if (now_w != inner_w or now_h != inner_h) {
            pictures.free(sys);
            inner_w = now_w;
            inner_h = now_h;
            pictures = Pictures.make(sys, inner_w, inner_h) orelse {
                _ = Printf(dl, MSG_NOMEMORY, .{ inner_w, inner_h });
                return dos.RETURN_FAIL;
            };
            makePicture(pictures.picture, pictures.width, pictures.height, phase);
        }

        const paused = strip.isChecked(pause_entry);
        if (!paused) {
            turn +%= speed;
            if (strip.isChecked(waves_entry)) {
                phase +%= 1;
                makePicture(pictures.picture, pictures.width, pictures.height, phase);
            }
        }
        for (&table, 0..) |*pen, n| pen.* = colourOf(palette, (@as(i32, @intCast(n)) + turn) & 255);
        pictures.fillBar(&table);

        const left: i32 = @intCast(wattr(ib, w, wn.WA_BorderLeft));
        const top: i32 = @intCast(wattr(ib, w, wn.WA_BorderTop));
        const width: i32 = @intCast(pictures.width);
        const height: i32 = @intCast(pictures.height);
        lb.LockLayer(layer);
        gb.WriteLUTPixelArray(rp, pictures.picture, @intCast(pictures.width), &table, 0, 0, &.{
            .min_x = left,
            .min_y = top,
            .max_x = left + width,
            .max_y = top + height,
        });
        gb.WritePixelArray(rp, pictures.bar, @intCast(pictures.width * 4), @intFromEnum(PixelFormat.rgba32), 0, 0, &.{
            .min_x = left,
            .min_y = top + height,
            .max_x = left + width,
            .max_y = top + height + bar_height,
        });
        lb.UnlockLayer(layer);
        drawn += 1;
        dl.Delay(1);
    }
    _ = Printf(dl, MSG_DONE, .{drawn});
    return dos.RETURN_OK;
}
