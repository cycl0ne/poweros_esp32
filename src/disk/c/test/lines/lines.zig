// SPDX-License-Identifier: MIT
//! Lines: a trail of lines bouncing behind venetian blinds, in a window of
//! its own. Built against the SDK only.
//!
//!   Lines FRAMES/N,WIDTH/K/N,HEIGHT/K/N,LINES/K/N,NOBLINDS/S
//!
//! It opens a window on the default public screen and draws into it until
//! the close gadget is used, FRAMES frames have gone by, or Ctrl-C, and
//! then says how many it drew and how fast. WIDTH and HEIGHT are the size
//! of the part inside the border; the window may be sized afterwards and
//! the picture is rebuilt at the new size. LINES is how many lines the
//! trail has, 14 unless it says, from 1 to 64. NOBLINDS leaves the region
//! out, so the trail is drawn whole.
//!
//! The window has menus, held with the menu button: Project turns the
//! blinds on and off (right-Amiga B), starts the trail again (R) and quits
//! (Q); Colour draws the trail in the colour wheel or in one colour fading
//! behind the newest line; Width draws its lines 1 to 4 pixels wide; Lines
//! says how long the trail is. The last three each check the choice made,
//! and one choice rules the others out.
//!
//! A frame is drawn off the window, into a bitmap of the interior's size,
//! and put in the window in one BltBitMapRastPort. Drawn straight into the
//! window, every frame would show its own clearing: the background goes
//! down first and the lines after it, and the panel streams whatever is
//! there at that moment.
//!
//! Drawing off the window is also what keeps the blinds: a window's
//! RastPort carries the clip target list layers built for it, and a target
//! list is consulted instead of a clip region rather than as well as one -
//! whoever built the list folded the caller's clip into it. A region of
//! one's own therefore belongs on a RastPort that is one's own.
//!
//! What is in it:
//!
//! - the background, a RectFill in near-black
//! - the trail: LINES Move/Draw lines, each a step behind the one in
//!   front, their colours a turn of the wheel apart; the newest is drawn
//!   last, so it is on top
//! - the blinds: slats of the whole picture built with NewRegion and
//!   OrRectRegion, sliding down a pixel a frame, given to the RastPort
//!   with RPTAG_ClipRegion
//!
//! There is no trigonometry at run time: a sine table of 256 steps is
//! built by the compiler, and an angle here is a step of that table.

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
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const RastPort = graphics.RastPort;

pub const COMMAND_NAME = "Lines";
const VERSION_STRING = "\x00$VER: Lines 1.3 (22.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FRAMES/N,WIDTH/K/N,HEIGHT/K/N,LINES/K/N,NOBLINDS/S";
const arg_frames = 0;
const arg_width = 1;
const arg_height = 2;
const arg_lines = 3;
const arg_noblinds = 4;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display, or it shows another screen\n";
const MSG_NOWINDOW = "No window - the screen would not open one that size\n";
const MSG_NOSTAGE = "No room for a %dx%d picture - %s\n";
const MSG_NOTRAIL = "No memory for %u lines\n";
const MSG_RUNNING = "Lines %u lines, %dx%d - the close gadget or Ctrl-C stops it\n";
const MSG_DONE = "%d frames in %d.%02d s\n";
const MSG_RATE = "%d.%d frames a second\n";

/// The smallest interior worth drawing in, and what one is by default.
const min_width = 120;
const min_height = 80;
const default_width = 400;
const default_height = 260;

// --- the sine table -------------------------------------------------------

/// A turn in 256 steps, scaled to 1024. Built by the compiler, so nothing
/// at run time needs floating point.
const sine: [256]i32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]i32 = undefined;
    for (0..256) |i| {
        const angle = @as(f64, @floatFromInt(i)) * (2.0 * 3.14159265358979323846) / 256.0;
        table[i] = @intFromFloat(@round(@sin(angle) * 1024.0));
    }
    break :blk table;
};

fn sin(step: i32) i32 {
    return sine[@intCast(step & 255)];
}

/// `amount` times the sine of `step`.
fn wave(step: i32, amount: i32) i32 {
    return @divTrunc(sin(step) * amount, 1024);
}

/// A colour round the wheel: `step` is 0..255 of a turn.
fn hue(step: i32) Pen {
    const r = 128 + wave(step, 127);
    const g = 128 + wave(step + 85, 127);
    const b = 128 + wave(step + 170, 127);
    return graphics.penRGB(@intCast(r), @intCast(g), @intCast(b));
}

// --- what moves -----------------------------------------------------------

/// How many lines the trail has unless LINES says, and the most it may.
const default_lines = 14;
const max_lines = 64;

const Line = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// The trail and the box it bounces in, and how it is drawn.
const Scene = struct {
    w: i32,
    h: i32,
    /// 0 the colour wheel, otherwise one of `fixed_colours`, from 1.
    colour: u32 = 0,
    /// How many pixels wide a line is.
    width: i32 = 1,
    /// The lines drawn, newest first: `length` of them, allocated for as
    /// many as LINES asked for.
    trail: [*]Line,
    length: usize,
    head: Line,
    velocity: [4]i32,

    fn init(s: *Scene, w: i32, h: i32) void {
        s.w = w;
        s.h = h;
        s.head = .{ .x0 = 10, .y0 = 10, .x1 = w - 10, .y1 = h - 10 };
        s.velocity = .{ 3, 2, -2, -3 };
        for (s.trail[0..s.length]) |*line| line.* = s.head;
    }

    /// One step: each end of the newest line moves and turns back at the
    /// edge, and the trail behind it is shifted along.
    fn step(s: *Scene) void {
        var ends = [4]*i32{ &s.head.x0, &s.head.y0, &s.head.x1, &s.head.y1 };
        for (&ends, 0..) |end, i| {
            end.* += s.velocity[i];
            const high = if (i % 2 == 0) s.w - 4 else s.h - 4;
            if (end.* < 4 or end.* > high) {
                s.velocity[i] = -s.velocity[i];
                end.* = @max(4, @min(high, end.*));
            }
        }
        var i: usize = s.length - 1;
        while (i > 0) : (i -= 1) s.trail[i] = s.trail[i - 1];
        s.trail[0] = s.head;
    }
};

// --- small helpers --------------------------------------------------------

fn set(gb: *GraphicsBase, rp: *RastPort, tag: u32, data: usize) void {
    const tags = [_]TagItem{ .{ .tag = tag, .data = data }, .{} };
    gb.SetRPAttrs(rp, &tags);
}

fn pen(gb: *GraphicsBase, rp: *RastPort, value: Pen) void {
    set(gb, rp, graphics.RPTAG_APen, value);
}

fn wattr(ib: *IntuitionBase, w: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(w, &ask);
    return value;
}

// --- the frame ------------------------------------------------------------

fn drawFrame(gb: *GraphicsBase, rp: *RastPort, s: *Scene, slats: ?*graphics.Region, t: i32) void {
    set(gb, rp, graphics.RPTAG_DrMd, graphics.DRMD_JAM1);
    pen(gb, rp, graphics.penRGB(0, 0, 16));
    gb.RectFill(rp, &.{ .max_x = s.w, .max_y = s.h });

    // Blinds: slats of the whole picture, sliding down a pixel a frame.
    if (slats) |region| {
        gb.ClearRegion(region);
        var y: i32 = @mod(t, 12) - 12;
        while (y < s.h) : (y += 12) {
            _ = gb.OrRectRegion(region, &.{
                .min_y = @max(0, y),
                .max_x = s.w,
                .max_y = @min(s.h, y + 8),
            });
        }
        set(gb, rp, graphics.RPTAG_ClipRegion, @intFromPtr(region));
    }

    // Back to front, so the newest line is on top.
    var i: usize = s.length;
    while (i > 0) {
        i -= 1;
        const line = s.trail[i];
        pen(gb, rp, colourOf(s, t, i));
        // A wide line is lines side by side, stepped across its length:
        // down for a line that runs more across than down, across for one
        // that runs more down.
        const across = @abs(line.x1 - line.x0) >= @abs(line.y1 - line.y0);
        var k: i32 = 0;
        while (k < s.width) : (k += 1) {
            const off = k - @divTrunc(s.width - 1, 2);
            const dx: i32 = if (across) 0 else off;
            const dy: i32 = if (across) off else 0;
            gb.Move(rp, line.x0 + dx, line.y0 + dy);
            gb.Draw(rp, line.x1 + dx, line.y1 + dy);
        }
    }
    if (slats != null) set(gb, rp, graphics.RPTAG_ClipRegion, 0);
}

/// The single colours Colour offers, as 0xRRGGBB.
const fixed_colours = [_]u32{ 0xFF4040, 0x40FF40, 0x4080FF, 0xFFFFFF };

/// Line `i` of the trail's colour at frame `t`: round the wheel, or the
/// chosen colour, dimmer the further behind the newest it is.
fn colourOf(s: *const Scene, t: i32, i: usize) Pen {
    if (s.colour == 0) return hue(t * 3 + @as(i32, @intCast(i)) * 6);
    const rgb = fixed_colours[s.colour - 1];
    const length: u32 = @intCast(s.length);
    const keep: u32 = length - @as(u32, @intCast(i));
    const r = ((rgb >> 16) & 0xFF) * keep / length;
    const g = ((rgb >> 8) & 0xFF) * keep / length;
    const b = (rgb & 0xFF) * keep / length;
    return graphics.penRGB(@intCast(r), @intCast(g), @intCast(b));
}

// --- the menus ------------------------------------------------------------

const mn = intuition.menus;

/// Every item of the strip, which menu it is in, what it is.
const Entry = struct {
    word: [*:0]const u8,
    menu: u8,
    flags: u32 = 0,
    command: u8 = 0,
    /// For a choice: what it sets - a colour, a width, a length.
    value: u32 = 0,
};

const project = 0;
const colour_menu = 1;
const width_menu = 2;
const lines_menu = 3;
const titles = [_][*:0]const u8{ "Project", "Colour", "Width", "Lines" };

const choice = mn.CHECKIT;
const entries = [_]Entry{
    .{ .word = "Blinds", .menu = project, .flags = mn.CHECKIT | mn.MENUTOGGLE | mn.COMMSEQ, .command = 'B' },
    .{ .word = "Restart", .menu = project, .flags = mn.COMMSEQ, .command = 'R' },
    .{ .word = "Quit", .menu = project, .flags = mn.COMMSEQ, .command = 'Q' },
    .{ .word = "Rainbow", .menu = colour_menu, .flags = choice, .value = 0 },
    .{ .word = "Red", .menu = colour_menu, .flags = choice, .value = 1 },
    .{ .word = "Green", .menu = colour_menu, .flags = choice, .value = 2 },
    .{ .word = "Blue", .menu = colour_menu, .flags = choice, .value = 3 },
    .{ .word = "White", .menu = colour_menu, .flags = choice, .value = 4 },
    .{ .word = "1 pixel", .menu = width_menu, .flags = choice, .value = 1 },
    .{ .word = "2 pixels", .menu = width_menu, .flags = choice, .value = 2 },
    .{ .word = "3 pixels", .menu = width_menu, .flags = choice, .value = 3 },
    .{ .word = "4 pixels", .menu = width_menu, .flags = choice, .value = 4 },
    .{ .word = "1", .menu = lines_menu, .flags = choice, .value = 1 },
    .{ .word = "8", .menu = lines_menu, .flags = choice, .value = 8 },
    .{ .word = "14", .menu = lines_menu, .flags = choice, .value = 14 },
    .{ .word = "32", .menu = lines_menu, .flags = choice, .value = 32 },
    .{ .word = "64", .menu = lines_menu, .flags = choice, .value = 64 },
};
const blinds_entry = 0;
const restart_entry = 1;
const quit_entry = 2;

/// The strip, linked in place: a menu's choices each rule out the others
/// of the same menu.
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
            // A choice rules out every other item of its menu.
            const all: u32 = (@as(u32, 1) << count_of[entry.menu]) - 1;
            strip.items[i] = .{
                .top = @as(i32, at) * row,
                .width = width,
                .height = row,
                .flags = mn.ITEMTEXT | mn.ITEMENABLED | mn.HIGHCOMP | entry.flags,
                .mutual_exclude = if (entry.menu != project) all & ~(@as(u32, 1) << at) else 0,
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

    fn indexOf(strip: *Strip, item: *intuition.MenuItem) usize {
        for (&strip.items, 0..) |*each, i| {
            if (each == item) return i;
        }
        return entries.len;
    }
};

/// The picture is drawn off the window: a bitmap of the interior's size and
/// a RastPort on it, which is where the clip region can be used.
const Stage = struct {
    surface: *rtg.Surface,
    rp: *RastPort,
    w: i32,
    h: i32,

    fn make(gb: *GraphicsBase, friend: *RastPort, w: i32, h: i32, why: *i32) ?Stage {
        const tags = [_]TagItem{
            .{ .tag = graphics.BMTAG_Width, .data = @intCast(w) },
            .{ .tag = graphics.BMTAG_Height, .data = @intCast(h) },
            .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(friend) },
            .{ .tag = graphics.BMTAG_ErrorPtr, .data = @intFromPtr(why) },
            .{},
        };
        const surface = gb.AllocBitMapTagList(&tags) orelse return null;
        const on = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} };
        const rp = gb.CreateRastPortTagList(&on) orelse {
            gb.FreeBitMap(surface);
            return null;
        };
        return .{ .surface = surface, .rp = rp, .w = w, .h = h };
    }

    fn free(stage: Stage, gb: *GraphicsBase) void {
        gb.FreeRastPort(stage.rp);
        gb.FreeBitMap(stage.surface);
    }
};

fn ticksOf(date: dos.DateStamp) u32 {
    return @intCast((date.days * 1440 + date.minute) * 60 * 50 + date.tick);
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

    const frames: u32 = if (argv[arg_frames] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_frames])).*) else 0;
    const want_w: i32 = if (argv[arg_width] != 0) @as(*const i32, @ptrFromInt(argv[arg_width])).* else default_width;
    const want_h: i32 = if (argv[arg_height] != 0) @as(*const i32, @ptrFromInt(argv[arg_height])).* else default_height;
    const want_lines: i32 = if (argv[arg_lines] != 0) @as(*const i32, @ptrFromInt(argv[arg_lines])).* else default_lines;
    const lines: usize = @intCast(@max(1, @min(max_lines, want_lines)));

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
        .{ .tag = wn.WA_Left, .data = 80 },
        .{ .tag = wn.WA_Top, .data = 60 },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(@max(min_width, want_w)) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(@max(min_height, want_h)) },
        // Squeezed onto a screen smaller than the size asked for, and moved
        // to fit, rather than not opening at all.
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_MinWidth, .data = min_width },
        .{ .tag = wn.WA_MinHeight, .data = min_height },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Lines") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        // Smart refresh, so what a window in front covers is kept and this
        // one is never asked to draw it again: the picture it would draw is
        // the one of the frame it is on now, and nothing older exists.
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_NEWSIZE | wn.IDCMP_MENUPICK },
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

    var why: i32 = 0;
    var inner_w: i32 = @intCast(wattr(ib, w, wn.WA_InnerWidth));
    var inner_h: i32 = @intCast(wattr(ib, w, wn.WA_InnerHeight));
    var stage = Stage.make(gb, rp, inner_w, inner_h, &why) orelse {
        _ = Printf(dl, MSG_NOSTAGE, .{ inner_w, inner_h, gb.GraphicsErrorText(why) });
        return dos.RETURN_FAIL;
    };
    defer stage.free(gb);

    // The region is made either way, so the blinds can be turned on from
    // the menu; NOBLINDS only says whether they start on.
    const region = gb.NewRegion();
    defer gb.DisposeRegion(region);
    var blinds = argv[arg_noblinds] == 0;

    // Room for the longest trail the menu offers, so a longer one never
    // needs more.
    const trail = sys.AllocVec(max_lines * @sizeOf(Line), exec.MEMF_ANY) orelse {
        _ = Printf(dl, MSG_NOTRAIL, .{@as(u32, max_lines)});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(trail);
    var scene: Scene = .{ .w = 0, .h = 0, .trail = @ptrCast(@alignCast(trail)), .length = lines, .head = undefined, .velocity = undefined };
    scene.init(inner_w, inner_h);

    const dri = ib.GetScreenDrawInfo(screen);
    defer ib.FreeScreenDrawInfo(screen, dri);
    var strip: Strip = undefined;
    strip.make(ib, dri);
    if (blinds) strip.items[blinds_entry].flags |= mn.CHECKED;
    strip.check(colour_menu, 0);
    strip.check(width_menu, 1);
    strip.check(lines_menu, @intCast(lines));
    _ = ib.SetMenuStrip(w, &strip.menus[0]);
    defer ib.ClearMenuStrip(w);

    _ = Printf(dl, MSG_RUNNING, .{ @as(u32, @intCast(lines)), inner_w, inner_h });

    var started: dos.DateStamp = .{};
    _ = dl.DateStamp(&started);

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
            // Each item picked, along the chain. The checkmarks say what
            // is chosen now, so they are read after.
            var number = code;
            while (number != mn.MENUNULL) {
                const item = ib.ItemAddress(&strip.menus[0], number) orelse break;
                switch (strip.indexOf(item)) {
                    restart_entry => scene.init(inner_w, inner_h),
                    quit_entry => running = false,
                    else => {},
                }
                number = item.next_select;
            }
            blinds = strip.items[blinds_entry].flags & mn.CHECKED != 0;
            scene.colour = strip.checked(colour_menu, 0);
            scene.width = @intCast(strip.checked(width_menu, 1));
            const length: usize = strip.checked(lines_menu, @intCast(scene.length));
            // A longer trail starts its new lines where the newest is.
            while (scene.length < length) : (scene.length += 1) scene.trail[scene.length] = scene.head;
            scene.length = length;
        }
        if (!running) break;

        // A window that was sized wants a picture of the new size, and a
        // trail that bounces in it. The old one is let go first, so the two
        // are never held at once.
        const now_w: i32 = @intCast(wattr(ib, w, wn.WA_InnerWidth));
        const now_h: i32 = @intCast(wattr(ib, w, wn.WA_InnerHeight));
        if (now_w != inner_w or now_h != inner_h) {
            stage.free(gb);
            inner_w = now_w;
            inner_h = now_h;
            stage = Stage.make(gb, rp, inner_w, inner_h, &why) orelse {
                _ = Printf(dl, MSG_NOSTAGE, .{ inner_w, inner_h, gb.GraphicsErrorText(why) });
                return dos.RETURN_FAIL;
            };
            scene.init(inner_w, inner_h);
        }

        drawFrame(gb, stage.rp, &scene, if (blinds) region else null, @intCast(drawn));

        // The finished picture into the window, at the corner the border
        // leaves. A task drawing into a layer holds that layer's lock: the
        // walking happens inside graphics.library, which knows nothing of
        // layers and cannot take it.
        const left: i32 = @intCast(wattr(ib, w, wn.WA_BorderLeft));
        const top: i32 = @intCast(wattr(ib, w, wn.WA_BorderTop));
        lb.LockLayer(layer);
        gb.BltBitMapRastPort(stage.surface, 0, 0, rp, left, top, stage.w, stage.h);
        lb.UnlockLayer(layer);

        scene.step();
        drawn += 1;
        // A tick to spare for everything else: the console that reads the
        // Ctrl-C among them.
        dl.Delay(1);
    }

    var ended: dos.DateStamp = .{};
    _ = dl.DateStamp(&ended);
    const ticks = ticksOf(ended) -% ticksOf(started);
    _ = Printf(dl, MSG_DONE, .{ drawn, ticks / 50, (ticks % 50) * 2 });
    if (ticks != 0) {
        const tenths = drawn * 500 / ticks;
        _ = Printf(dl, MSG_RATE, .{ tenths / 10, tenths % 10 });
    }
    return dos.RETURN_OK;
}
