// SPDX-License-Identifier: MIT
//! The picture in the window: the weather at a place now, its next 24
//! hours and the three days after today, drawn into the canvas gadget.
//!
//! **How it is made.** Everything but the words is drawn with
//! vector.library onto pens of the program's own, the canvas's size
//! (`draw.zig`): the sky (`sky.zig`), the panes of frosted glass the
//! rest sits on, the pictures of the weather with one soft shadow under
//! them all, the curve of the hours' temperatures and the bars of their
//! chance of rain, the days' ranges. The pens are put onto the canvas's
//! RastPort in one WritePixelArray, and the words written over them with
//! graphics.library, each over a shadow of its own, in fonts made from
//! the screen's at the picture's scale (diskfont.library; the screen's
//! own font without it).
//!
//! **The layout** is made for 760 by 520 pixels and scaled by how much
//! of that the canvas has across and down, whichever is less: each
//! height and each font scales with it, the panes widen with the canvas.
//!
//!   - the place, and its date and time; on the right, how the last
//!     question went and whose the data are;
//!   - the weather now: its picture, the temperature, the words for it,
//!     how warm it feels and today's high and low; beside it a pane of
//!     humidity, wind, precipitation, sunrise and sunset;
//!   - the next 24 hours: the temperature as a curve, a mark and a
//!     picture every third hour, the chance of rain as bars;
//!   - a pane for each of the next three days: its name, picture, high
//!     and low and chance of rain, and a bar of its range on the scale
//!     of all three.
//!
//! Before there is a forecast, a picture and the words of how the
//! question goes are shown in the middle.
//!
//! **While the window is sized** nothing is drawn anew: the first step
//! keeps the last picture aside, words and all, and each step shows it
//! stretched to the canvas's new size (`stretch`). The sizing's end makes
//! the picture anew at the size it ended at.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const vector = sdk.vector;
const locale = sdk.locale;
const rtg = sdk.rtg;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const VectorBase = sdk.interface.vector.VectorBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const Object = intuition.Object;
const cv = sdk.gadgets.canvas;
const sc = intuition.screens;
const strings = @import("strings");
const Id = strings.Id;
const Text = locale.Strings(strings);
const forecast = @import("forecast.zig");
const Forecast = forecast.Forecast;
const Place = forecast.Place;
const draw = @import("draw.zig");
const sky = @import("sky.zig");
const Brush = draw.Brush;
const rgb = draw.rgb;

/// The size the layout is made for.
const design_width: f32 = 760;
const design_height: f32 = 520;

/// What the window has to show.
pub const Shown = struct {
    /// The forecast, once there is one.
    forecast: ?*const Forecast = null,
    place: *const Place,
    /// How the last question went, said at the top right - or, with no
    /// forecast, in the middle.
    status: [*:0]const u8,
};

/// The fonts the words are written in, at one scale.
const Fonts = struct {
    /// The temperature now.
    big: ?*graphics.TextFont = null,
    /// The place, and a day's high.
    title: ?*graphics.TextFont = null,
    /// The weather's words, a day's name.
    medium: ?*graphics.TextFont = null,
    /// Everything else.
    small: ?*graphics.TextFont = null,
};

const white: u32 = 0xFFFFFF;

pub const View = struct {
    sys: *ExecBase,
    gb: *GraphicsBase,
    ib: *IntuitionBase,
    vb: *VectorBase,
    dfb: ?*DiskfontBase,
    text: *const Text,
    gadget: *Object,
    window: *intuition.Window,
    /// The screen's font: what is written in without diskfont.library.
    screen_font: ?*graphics.TextFont,
    path: *vector.Path,

    rp: *graphics.RastPort = undefined,
    width: i32 = 0,
    height: i32 = 0,
    pens: ?[*]Pen = null,
    pens_size: usize = 0,
    canvas: ?*vector.Canvas = null,
    fonts: Fonts = .{},
    /// The scale the fonts were made at, in hundredths.
    fonts_scale: u32 = 0,
    /// The last picture made, kept aside while the window is sized, and
    /// its size.
    still: ?*rtg.Surface = null,
    still_width: i32 = 0,
    still_height: i32 = 0,

    pub fn free(view: *View) void {
        view.dropStill();
        view.closeFonts();
        view.vb.DisposeCanvas(view.canvas);
        view.canvas = null;
        if (view.pens) |pens| view.sys.FreeVec(pens);
        view.pens = null;
        view.vb.DisposePath(view.path);
    }

    /// The picture made as big as the gadget's box, and the pens and the
    /// canvas to match; false without the memory. A sizing is over: the
    /// picture kept aside for it goes.
    pub fn fit(view: *View) bool {
        view.dropStill();
        _ = view.ib.SetGadgetAttrsTagList(view.gadget, view.window, &[_]TagItem{
            .{ .tag = cv.CANVAS_Width, .data = 0 },
            .{ .tag = cv.CANVAS_Height, .data = 0 },
            .{},
        });
        var value: usize = 0;
        _ = view.ib.GetAttr(cv.CANVAS_RastPort, view.gadget, &value);
        view.rp = @ptrFromInt(value);
        _ = view.ib.GetAttr(cv.CANVAS_Width, view.gadget, &value);
        const width: i32 = @intCast(@max(value, 1));
        _ = view.ib.GetAttr(cv.CANVAS_Height, view.gadget, &value);
        const height: i32 = @intCast(@max(value, 1));
        if (width == view.width and height == view.height and view.canvas != null) return true;
        view.width = width;
        view.height = height;
        view.vb.DisposeCanvas(view.canvas);
        view.canvas = null;
        const wanted: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * @sizeOf(Pen);
        if (wanted != view.pens_size) {
            if (view.pens) |pens| view.sys.FreeVec(pens);
            view.pens = @ptrCast(@alignCast(view.sys.AllocVec(wanted, exec.MEMF_ANY)));
            view.pens_size = if (view.pens != null) wanted else 0;
        }
        const pens = view.pens orelse return false;
        view.canvas = view.vb.CreateCanvasTagList(&[_]TagItem{
            .{ .tag = vector.VCA_Pens, .data = @intFromPtr(pens) },
            .{ .tag = vector.VCA_Width, .data = @intCast(width) },
            .{ .tag = vector.VCA_Height, .data = @intCast(height) },
            .{},
        });
        return view.canvas != null;
    }

    /// A step of a sizing: the last picture shown stretched to the gadget's
    /// box, nothing drawn anew. The first step keeps the picture aside -
    /// the canvas still holds it at its size - and without the memory for
    /// that, each step shows what fits of it, as the canvas keeps it.
    pub fn stretch(view: *View) void {
        if (view.still == null and view.canvas != null) {
            var value: usize = 0;
            _ = view.ib.GetAttr(cv.CANVAS_BitMap, view.gadget, &value);
            if (value != 0) {
                const picture: *const rtg.Surface = @ptrFromInt(value);
                view.still = view.gb.AllocBitMapTagList(&[_]TagItem{
                    .{ .tag = graphics.BMTAG_Width, .data = @intCast(view.width) },
                    .{ .tag = graphics.BMTAG_Height, .data = @intCast(view.height) },
                    .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(view.rp) },
                    .{},
                });
                if (view.still) |still| {
                    _ = view.gb.BltBitMap(picture, 0, 0, still, 0, 0, view.width, view.height);
                    view.still_width = view.width;
                    view.still_height = view.height;
                }
            }
        }
        _ = view.ib.SetGadgetAttrsTagList(view.gadget, view.window, &[_]TagItem{
            .{ .tag = cv.CANVAS_Width, .data = 0 },
            .{ .tag = cv.CANVAS_Height, .data = 0 },
            .{},
        });
        var value: usize = 0;
        _ = view.ib.GetAttr(cv.CANVAS_RastPort, view.gadget, &value);
        view.rp = @ptrFromInt(value);
        const still = view.still orelse return view.ib.QueueGadgetRefresh(view.gadget);
        _ = view.ib.GetAttr(cv.CANVAS_Width, view.gadget, &value);
        const width: i32 = @intCast(@max(value, 1));
        _ = view.ib.GetAttr(cv.CANVAS_Height, view.gadget, &value);
        const height: i32 = @intCast(@max(value, 1));
        view.gb.BitMapScale(still, &.{ .max_x = view.still_width, .max_y = view.still_height }, view.rp, &.{ .max_x = width, .max_y = height });
        view.ib.QueueGadgetRefresh(view.gadget);
    }

    fn dropStill(view: *View) void {
        view.gb.FreeBitMap(view.still);
        view.still = null;
    }

    // --- the fonts ------------------------------------------------------------------

    fn closeFonts(view: *View) void {
        // The RastPort let go of them first.
        if (view.width > 0) {
            if (view.screen_font) |font| graphics.SetFont(view.gb, view.rp, font);
        }
        inline for (.{ &view.fonts.big, &view.fonts.title, &view.fonts.medium, &view.fonts.small }) |slot| {
            if (slot.*) |font| view.gb.CloseFont(font);
            slot.* = null;
        }
        view.fonts_scale = 0;
    }

    /// The fonts made for `scale`, when they are not already.
    fn fontsFor(view: *View, scale: f32) void {
        const hundredths: u32 = @intFromFloat(scale * 100);
        if (hundredths == view.fonts_scale) return;
        view.closeFonts();
        view.fonts_scale = hundredths;
        const fonts = view.dfb orelse return;
        const system = view.ib.OpenSystemFont(sc.SYSFONT_DEFAULT) orelse return;
        defer view.gb.CloseFont(system);
        const name = system.node.name orelse return;
        const sizes = [_]struct { slot: *?*graphics.TextFont, rows: f32, style: graphics.FontStyle }{
            .{ .slot = &view.fonts.big, .rows = 84, .style = 0 },
            .{ .slot = &view.fonts.title, .rows = 26, .style = graphics.FSF_BOLD },
            .{ .slot = &view.fonts.medium, .rows = 18, .style = graphics.FSF_BOLD },
            .{ .slot = &view.fonts.small, .rows = 14, .style = 0 },
        };
        for (sizes) |size| {
            const rows: u16 = @intFromFloat(@max(size.rows * scale, 9));
            size.slot.* = fonts.OpenDiskFont(&.{ .name = name, .y_size = rows, .style = size.style });
        }
    }

    // --- the picture ------------------------------------------------------------------

    /// Everything drawn, and the gadget asked to show it. In a sizing - an
    /// answer come in the middle of one - at the size the window has now.
    pub fn show(view: *View, shown: Shown) void {
        if (view.still != null and !view.fit()) return;
        const canvas = view.canvas orelse return;
        const pens = view.pens orelse return;
        const width: f32 = @floatFromInt(view.width);
        const height: f32 = @floatFromInt(view.height);
        const scale = @min(@max(@min(width / design_width, height / design_height), 0.5), 3);
        view.fontsFor(scale);
        const brush = Brush{ .vb = view.vb, .canvas = canvas, .path = view.path };
        var writer = Writer{ .view = view, .scale = scale };

        if (shown.forecast) |seen| {
            const layout = Layout.of(width, height, scale);
            const now = &seen.now;
            const kind = forecast.skyOf(now.code);
            sky.background(&brush, kind, now.day, width, height);
            view.panes(&brush, layout);
            view.pictures(&brush, layout, seen, .shadow);
            view.pictures(&brush, layout, seen, .picture);
            view.hourCurve(&brush, layout, seen);
            view.glyphs(&brush, layout, seen);
            view.ranges(&brush, layout, seen);
            view.putDown(pens);
            writer.header(layout, shown);
            writer.now(layout, seen);
            writer.details(layout, seen);
            writer.hours(layout, seen);
            writer.days(layout, seen);
        } else {
            sky.background(&brush, .few_clouds, true, width, height);
            const size = 170 * scale;
            const box = sky.Box{ .x = (width - size) / 2, .y = height / 2 - size * 0.85, .size = size };
            if (brush.layer(0.35)) {
                sky.picture(&brush, .few_clouds, true, .{ .x = box.x + 3 * scale, .y = box.y + 6 * scale, .size = size }, .shadow);
                brush.blur(5 * scale);
                brush.drop();
            }
            sky.picture(&brush, .few_clouds, true, box, .picture);
            view.putDown(pens);
            writer.centred(view.fonts.medium, shown.status, width / 2, height / 2 + size * 0.3, 1);
            writer.centred(view.fonts.small, view.text.get(.MSG_SOURCE), width / 2, height - 28 * scale, 0.75);
        }
        view.ib.QueueGadgetRefresh(view.gadget);
    }

    fn putDown(view: *View, pens: [*]Pen) void {
        view.gb.WritePixelArray(view.rp, @ptrCast(pens), @intCast(view.width * @sizeOf(Pen)), @intFromEnum(rtg.PixelFormat.bgra32), 0, 0, &.{
            .max_x = view.width,
            .max_y = view.height,
        });
    }

    /// The panes of frosted glass.
    fn panes(_: *View, brush: *const Brush, layout: Layout) void {
        pane(brush, layout.details, layout.scale);
        pane(brush, layout.hours, layout.scale);
        for (layout.cards) |card| pane(brush, card, layout.scale);
    }

    /// The weather's pictures - now, every third hour and each day - as
    /// their shadows on one blurred layer, or as themselves.
    fn pictures(_: *View, brush: *const Brush, layout: Layout, seen: *const Forecast, part: sky.Part) void {
        const scale = layout.scale;
        const shift_x = if (part == .shadow) 3 * scale else 0;
        const shift_y = if (part == .shadow) 6 * scale else 0;
        if (part == .shadow and !brush.layer(0.32)) return;
        const hero = layout.hero_picture;
        sky.picture(brush, forecast.skyOf(seen.now.code), seen.now.day, .{ .x = hero.x + shift_x, .y = hero.y + shift_y, .size = hero.size }, part);
        // The hours' every third: small, their shadows barely there.
        if (part == .picture) {
            var at: u32 = 0;
            while (at < seen.hour_count) : (at += 3) {
                const hour = &seen.hours[at];
                const size = 26 * scale;
                const x = layout.hourX(at, seen.hour_count) - size / 2;
                sky.picture(brush, forecast.skyOf(hour.code), hour.day, .{ .x = x, .y = layout.hours.y + 96 * scale, .size = size }, part);
            }
        }
        for (layout.cards, 0..) |card, at| {
            if (at + 1 >= seen.day_count) break;
            const day = &seen.days[at + 1];
            const size = 64 * scale;
            sky.picture(brush, forecast.skyOf(day.code), true, .{ .x = card.x + 8 * scale + shift_x / 2, .y = card.y + 30 * scale + shift_y / 2, .size = size }, part);
        }
        if (part == .shadow) {
            brush.blur(4 * scale);
            brush.drop();
        }
    }

    /// The hours' temperatures as a curve over a glow, their chance of
    /// rain as bars, and a mark every third hour.
    fn hourCurve(_: *View, brush: *const Brush, layout: Layout, seen: *const Forecast) void {
        const count = seen.hour_count;
        if (count < 2) return;
        const scale = layout.scale;
        const vb = brush.vb;
        const top = layout.hours.y + 48 * scale;
        const bottom = layout.hours.y + 90 * scale;
        const floor = bottom + 4 * scale;
        // The chance of rain, under everything.
        const step = (layout.hourX(1, count) - layout.hourX(0, count));
        const rain = draw.solid(rgb(0x4FC3F7, 0.55));
        for (seen.hours[0..count], 0..) |*hour, at| {
            if (hour.rain_chance == 0) continue;
            const tall = @as(f32, @floatFromInt(hour.rain_chance)) / 100 * 26 * scale;
            const x = layout.hourX(@intCast(at), count);
            brush.roundRect(x - step * 0.28, floor - tall, step * 0.56, tall, @min(step * 0.2, 2 * scale));
            brush.fill(&rain);
        }
        var lowest: f32 = seen.hours[0].temperature;
        var highest: f32 = lowest;
        for (seen.hours[0..count]) |*hour| {
            lowest = @min(lowest, hour.temperature);
            highest = @max(highest, hour.temperature);
        }
        if (highest - lowest < 4) {
            const middle = (highest + lowest) / 2;
            lowest = middle - 2;
            highest = middle + 2;
        }
        var points: [forecast.max_hours][2]f32 = undefined;
        for (seen.hours[0..count], 0..) |*hour, at| {
            points[at] = .{ layout.hourX(@intCast(at), count), bottom - (hour.temperature - lowest) / (highest - lowest) * (bottom - top) };
        }
        // The glow under the curve, down to the pane's floor.
        smooth(vb, brush.begin(), points[0..count]);
        vb.LineTo(brush.path, points[count - 1][0], floor);
        vb.LineTo(brush.path, points[0][0], floor);
        vb.ClosePath(brush.path);
        const glow = draw.two(rgb(0xFFD166, 0.62), rgb(0xFFD166, 0.04));
        brush.fill(&draw.linear(&glow, 0, top, 0, floor));
        // The curve.
        smooth(vb, brush.begin(), points[0..count]);
        brush.stroke(&draw.solid(rgb(0xFFF3D6, 1)), 2.4 * scale);
        // The marks.
        var at: u32 = 0;
        while (at < count) : (at += 3) {
            brush.circle(points[at][0], points[at][1], 4.2 * scale);
            brush.fill(&draw.solid(rgb(0xFFD166, 1)));
            brush.circle(points[at][0], points[at][1], 2.2 * scale);
            brush.fill(&draw.solid(rgb(white, 1)));
        }
    }

    /// The small pictures beside the details: a drop for humidity and
    /// precipitation, an arrow the way the wind blows, the sun on the
    /// horizon for sunrise and sunset.
    fn glyphs(_: *View, brush: *const Brush, layout: Layout, seen: *const Forecast) void {
        const scale = layout.scale;
        const vb = brush.vb;
        const size = 7 * scale;
        const paint = draw.solid(rgb(white, 0.9));
        const x = layout.details.x + 20 * scale;
        for (0..5) |row| {
            const y = layout.detailRow(@intCast(row)) + layout.detailHeight() / 2;
            switch (row) {
                0, 2 => {
                    // A drop: a point above, round below.
                    const path = brush.begin();
                    vb.MoveTo(path, x, y - size);
                    vb.CubicTo(path, x + size * 0.2, y - size * 0.4, x + size * 0.75, y - size * 0.05, x + size * 0.75, y + size * 0.3);
                    vb.ArcTo(path, size * 0.75, size * 0.75, 0, vector.ARC_SWEEP, x - size * 0.75, y + size * 0.3);
                    vb.CubicTo(path, x - size * 0.75, y - size * 0.05, x - size * 0.2, y - size * 0.4, x, y - size);
                    vb.ClosePath(path);
                    brush.fill(&draw.solid(rgb(0x8FD8FF, 1)));
                },
                1 => {
                    // Where the wind blows to: from where it comes, turned
                    // round.
                    const radians = (seen.now.wind_from + 180) * (3.14159265 / 180.0);
                    const dx = @sin(radians);
                    const dy = -@cos(radians);
                    const tip = [2]f32{ x + dx * size, y + dy * size };
                    const tail = [2]f32{ x - dx * size, y - dy * size };
                    brush.line(tail[0], tail[1], tip[0], tip[1]);
                    brush.stroke(&paint, 1.8 * scale);
                    const path = brush.begin();
                    vb.MoveTo(path, tip[0], tip[1]);
                    vb.LineTo(path, tip[0] - dx * size * 0.7 - dy * size * 0.5, tip[1] - dy * size * 0.7 + dx * size * 0.5);
                    vb.LineTo(path, tip[0] - dx * size * 0.7 + dy * size * 0.5, tip[1] - dy * size * 0.7 - dx * size * 0.5);
                    vb.ClosePath(path);
                    brush.fill(&paint);
                },
                else => {
                    // Half a sun over the horizon, and which way it goes.
                    const path = brush.begin();
                    vb.MoveTo(path, x - size * 0.8, y + size * 0.35);
                    vb.ArcTo(path, size * 0.8, size * 0.8, 0, vector.ARC_SWEEP, x + size * 0.8, y + size * 0.35);
                    vb.ClosePath(path);
                    brush.fill(&draw.solid(rgb(0xFFD166, 1)));
                    brush.line(x - size * 1.1, y + size * 0.35, x + size * 1.1, y + size * 0.35);
                    brush.stroke(&paint, 1.4 * scale);
                    const up = row == 3;
                    const arrow = brush.begin();
                    const point_y = if (up) y - size * 1.45 else y - size * 0.7;
                    const back_y = if (up) y - size * 0.95 else y - size * 1.2;
                    vb.MoveTo(arrow, x, point_y);
                    vb.LineTo(arrow, x - size * 0.45, back_y);
                    vb.LineTo(arrow, x + size * 0.45, back_y);
                    vb.ClosePath(arrow);
                    brush.fill(&paint);
                },
            }
        }
    }

    /// Each day's range, on the scale of the three days': low to high in
    /// the colours of the temperatures.
    fn ranges(_: *View, brush: *const Brush, layout: Layout, seen: *const Forecast) void {
        const scale = layout.scale;
        const first: u32 = 1;
        const last: u32 = @min(seen.day_count, 4);
        if (last <= first) return;
        var lowest = seen.days[first].low;
        var highest = seen.days[first].high;
        for (seen.days[first..last]) |*day| {
            lowest = @min(lowest, day.low);
            highest = @max(highest, day.high);
        }
        const span = @max(highest - lowest, 1);
        for (layout.cards, 0..) |card, at| {
            if (at + 1 >= last) break;
            const day = &seen.days[at + 1];
            const left = card.x + 84 * scale;
            const across = card.width - 84 * scale - 14 * scale;
            const y = card.y + 92 * scale;
            const thick = 6 * scale;
            brush.roundRect(left, y, across, thick, thick / 2);
            brush.fill(&draw.solid(rgb(white, 0.18)));
            const from = left + (day.low - lowest) / span * across;
            const to = left + (day.high - lowest) / span * across;
            const stops = draw.two(colourOf(celsius(day.low, seen.fahrenheit)), colourOf(celsius(day.high, seen.fahrenheit)));
            brush.roundRect(from, y, @max(to - from, thick), thick, thick / 2);
            brush.fill(&draw.linear(&stops, from, 0, @max(to, from + thick), 0));
        }
    }
};

/// A pane of frosted glass: lighter at its top, with a fine edge.
fn pane(brush: *const Brush, area: Area, scale: f32) void {
    const radius = 14 * scale;
    brush.roundRect(area.x, area.y, area.width, area.height, radius);
    const frost = draw.two(rgb(white, 0.22), rgb(white, 0.10));
    brush.fill(&draw.linear(&frost, 0, area.y, 0, area.y + area.height));
    brush.roundRect(area.x + 0.5, area.y + 0.5, area.width - 1, area.height - 1, radius);
    brush.stroke(&draw.solid(rgb(white, 0.28)), 1);
}

/// A smooth curve through the points: a Catmull-Rom spline, as cubic
/// curves, from the first point to the last.
fn smooth(vb: *VectorBase, path: *vector.Path, points: []const [2]f32) void {
    vb.MoveTo(path, points[0][0], points[0][1]);
    for (0..points.len - 1) |at| {
        const before = points[if (at == 0) 0 else at - 1];
        const from = points[at];
        const to = points[at + 1];
        const after = points[@min(at + 2, points.len - 1)];
        vb.CubicTo(
            path,
            from[0] + (to[0] - before[0]) / 6,
            from[1] + (to[1] - before[1]) / 6,
            to[0] - (after[0] - from[0]) / 6,
            to[1] - (after[1] - from[1]) / 6,
            to[0],
            to[1],
        );
    }
}

fn celsius(temperature: f32, fahrenheit: bool) f32 {
    return if (fahrenheit) (temperature - 32) * 5 / 9 else temperature;
}

/// The colour of a temperature in Celsius: blue in the cold, green when
/// mild, through yellow to red in the heat.
fn colourOf(degrees: f32) draw.Colour {
    const scale = [_]struct { at: f32, colour: u32 }{
        .{ .at = -15, .colour = 0x8AB4FF },
        .{ .at = 0, .colour = 0x7FD3FF },
        .{ .at = 10, .colour = 0x8CE0A8 },
        .{ .at = 20, .colour = 0xFFD166 },
        .{ .at = 30, .colour = 0xFF8A50 },
        .{ .at = 40, .colour = 0xFF4D5E },
    };
    if (degrees <= scale[0].at) return rgb(scale[0].colour, 1);
    for (scale[0 .. scale.len - 1], scale[1..]) |low, high| {
        if (degrees <= high.at) return draw.mix(rgb(low.colour, 1), rgb(high.colour, 1), (degrees - low.at) / (high.at - low.at));
    }
    return rgb(scale[scale.len - 1].colour, 1);
}

// --- where everything goes ---------------------------------------------------------------

const Area = struct { x: f32, y: f32, width: f32, height: f32 };

const Layout = struct {
    scale: f32,
    margin: f32,
    width: f32,
    hero_picture: sky.Box,
    /// The temperature's left edge and the hero's top.
    hero_x: f32,
    hero_y: f32,
    details: Area,
    hours: Area,
    cards: [3]Area,

    fn of(width: f32, height: f32, scale: f32) Layout {
        const margin = 16 * scale;
        const hero_y = margin + 58 * scale;
        const hero_height = 140 * scale;
        const details_width = 270 * scale;
        const hours_y = hero_y + hero_height + 12 * scale;
        const hours_height = 150 * scale;
        const cards_y = hours_y + hours_height + 12 * scale;
        const gap = 12 * scale;
        const card_width = (width - 2 * margin - 2 * gap) / 3;
        const card_height = @max(height - margin - cards_y, 110 * scale);
        var cards: [3]Area = undefined;
        for (&cards, 0..) |*card, at| {
            card.* = .{ .x = margin + @as(f32, @floatFromInt(at)) * (card_width + gap), .y = cards_y, .width = card_width, .height = card_height };
        }
        return .{
            .scale = scale,
            .margin = margin,
            .width = width,
            .hero_picture = .{ .x = margin - 6 * scale, .y = hero_y - 6 * scale, .size = 146 * scale },
            .hero_x = margin + 148 * scale,
            .hero_y = hero_y,
            .details = .{ .x = width - margin - details_width, .y = hero_y, .width = details_width, .height = hero_height },
            .hours = .{ .x = margin, .y = hours_y, .width = width - 2 * margin, .height = hours_height },
            .cards = cards,
        };
    }

    /// Where hour `at` of `count` is across the hours' pane.
    fn hourX(layout: Layout, at: u32, count: u32) f32 {
        const left = layout.hours.x + 30 * layout.scale;
        const right = layout.hours.x + layout.hours.width - 30 * layout.scale;
        if (count < 2) return left;
        return left + @as(f32, @floatFromInt(at)) * (right - left) / @as(f32, @floatFromInt(count - 1));
    }

    fn detailHeight(layout: Layout) f32 {
        return (layout.details.height - 10 * layout.scale) / 5;
    }

    fn detailRow(layout: Layout, row: u32) f32 {
        return layout.details.y + 5 * layout.scale + @as(f32, @floatFromInt(row)) * layout.detailHeight();
    }
};

// --- the words -----------------------------------------------------------------------------

/// Words written over the picture, each over its shadow.
const Writer = struct {
    view: *View,
    scale: f32,

    const Align = enum { left, right, centre };

    fn wear(writer: *Writer, font: ?*graphics.TextFont) void {
        const chosen = font orelse writer.view.screen_font orelse return;
        writer.view.gb.SetRPAttrs(writer.view.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(chosen) }, .{} });
    }

    fn attr(writer: *Writer, tag: utility.Tag) i32 {
        var value: usize = 0;
        writer.view.gb.GetRPAttrs(writer.view.rp, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} });
        return @intCast(value);
    }

    /// How tall a line of `font` is.
    fn heightOf(writer: *Writer, font: ?*graphics.TextFont) f32 {
        writer.wear(font);
        return @floatFromInt(writer.attr(graphics.RPTAG_FontHeight));
    }

    fn widthOf(writer: *Writer, font: ?*graphics.TextFont, words: [*:0]const u8) f32 {
        writer.wear(font);
        return @floatFromInt(writer.view.gb.TextLength(writer.view.rp, words, lengthOf(words)));
    }

    /// `words` in `font` with their top at `y`, from `x` as `alignment`
    /// says, at most `room` wide (0: any); how wide they came out.
    fn say(writer: *Writer, font: ?*graphics.TextFont, words: [*:0]const u8, x: f32, y: f32, alignment: Align, alpha: f32, room: f32) f32 {
        const view = writer.view;
        const gb = view.gb;
        const rp = view.rp;
        const count = lengthOf(words);
        if (count == 0) return 0;
        writer.wear(font);
        var width: f32 = @floatFromInt(gb.TextLength(rp, words, count));
        if (room > 0) width = @min(width, room);
        const left: f32 = switch (alignment) {
            .left => x,
            .right => x - width,
            .centre => x - width / 2,
        };
        const baseline = y + @as(f32, @floatFromInt(writer.attr(graphics.RPTAG_FontBaseline)));
        const shadow: i32 = @intFromFloat(@max(@round(writer.scale * 1.2), 1));
        const opacity: u8 = @intFromFloat(@min(@max(alpha, 0), 1) * 255);
        const pens = [2]Pen{ graphics.penARGB(opacity / 3, 0, 0, 0), graphics.penARGB(opacity, 255, 255, 255) };
        for (pens, [2]i32{ shadow, 0 }) |pen, offset| {
            gb.SetRPAttrs(rp, &[_]TagItem{
                .{ .tag = graphics.RPTAG_APen, .data = pen },
                .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 | graphics.DRMD_BLEND },
                .{},
            });
            gb.Move(rp, @as(i32, @intFromFloat(left)) + offset, @as(i32, @intFromFloat(baseline)) + offset);
            if (room > 0) {
                _ = gb.TextFitted(rp, words, count, @intFromFloat(room));
            } else {
                gb.Text(rp, words, count);
            }
        }
        return width;
    }

    fn centred(writer: *Writer, font: ?*graphics.TextFont, words: [*:0]const u8, x: f32, y: f32, alpha: f32) void {
        const room = @as(f32, @floatFromInt(writer.view.width)) - 32 * writer.scale;
        _ = writer.say(font, words, x, y, .centre, alpha, @max(room, 1));
    }

    // --- the parts ---------------------------------------------------------------

    fn header(writer: *Writer, layout: Layout, shown: Shown) void {
        const view = writer.view;
        const fonts = &view.fonts;
        const scale = layout.scale;
        const right = layout.width - layout.margin;
        // On the right: how it went, and whose the data are.
        const status_width = writer.say(fonts.small, shown.status, right, layout.margin + 4 * scale, .right, 0.9, layout.width * 0.4);
        const source_width = writer.say(fonts.small, view.text.get(.MSG_SOURCE), right, layout.margin + 4 * scale + writer.heightOf(fonts.small) + 2 * scale, .right, 0.6, layout.width * 0.4);
        const room = layout.width - 2 * layout.margin - @max(status_width, source_width) - 16 * scale;
        _ = writer.say(fonts.title, &shown.place.name, layout.margin, layout.margin, .left, 1, room);
        // The place's date and its time.
        var line = Line{};
        if (shown.forecast) |seen| {
            if (seen.day_count > 0) writer.dateInto(&line, &seen.days[0]);
            line.add("  ·  ");
            line.clock(seen.now.at);
        }
        _ = writer.say(fonts.small, line.text(), layout.margin, layout.margin + writer.heightOf(fonts.title) + 2 * scale, .left, 0.85, room);
    }

    fn dateInto(writer: *Writer, line: *Line, day: *const forecast.Day) void {
        const strings_of = writer.view.text;
        const lb = strings_of.library orelse return;
        const loc = strings_of.locale orelse return;
        var into: [64]u8 = @splat(0);
        var hook = locale.BufferHook.init(into[0 .. into.len - 1]);
        const stamp = dos.DateStamp{ .days = daysSince1978(day.year, day.month, day.day) };
        lb.FormatDate(loc, loc.date_format, &stamp, &hook.hook);
        line.add(into[0..hook.length]);
    }

    fn now(writer: *Writer, layout: Layout, seen: *const Forecast) void {
        const view = writer.view;
        const fonts = &view.fonts;
        const scale = layout.scale;
        const room = layout.details.x - layout.hero_x - 12 * scale;
        var line = Line{};
        line.degrees(seen.now.temperature);
        _ = writer.say(fonts.big, line.text(), layout.hero_x, layout.hero_y - 4 * scale, .left, 1, room);
        const below = layout.hero_y + writer.heightOf(fonts.big) - 4 * scale;
        _ = writer.say(fonts.medium, view.text.get(wordsOf(seen.now.code)), layout.hero_x, below, .left, 1, room);
        // How warm it feels, and today's high and low.
        var feels = Line{};
        feels.degrees(seen.now.feels_like);
        var said: [96:0]u8 = @splat(0);
        var line_two = Line{};
        line_two.add(view.text.format(&said, .MSG_FEELS_LIKE, .{@as([*:0]const u8, feels.text())}));
        if (seen.day_count > 0) {
            var high = Line{};
            var low = Line{};
            high.degrees(seen.days[0].high);
            low.degrees(seen.days[0].low);
            line_two.add("  ·  ");
            line_two.add(view.text.format(&said, .MSG_HIGH_LOW, .{ @as([*:0]const u8, high.text()), @as([*:0]const u8, low.text()) }));
        }
        _ = writer.say(fonts.small, line_two.text(), layout.hero_x, below + writer.heightOf(fonts.medium) + 4 * scale, .left, 0.85, room);
    }

    fn details(writer: *Writer, layout: Layout, seen: *const Forecast) void {
        const view = writer.view;
        const fonts = &view.fonts;
        const scale = layout.scale;
        const labels = [5]Id{ .MSG_HUMIDITY, .MSG_WIND, .MSG_PRECIPITATION, .MSG_SUNRISE, .MSG_SUNSET };
        const small_height = writer.heightOf(fonts.small);
        for (labels, 0..) |label, row| {
            const y = layout.detailRow(@intCast(row)) + (layout.detailHeight() - small_height) / 2;
            var value = Line{};
            switch (row) {
                0 => {
                    value.number(seen.now.humidity);
                    value.add(" %");
                },
                1 => {
                    value.number(@intFromFloat(@max(@round(seen.now.wind_speed), 0)));
                    value.add(if (seen.fahrenheit) " mph " else " km/h ");
                    value.addZ(view.text.get(compassOf(seen.now.wind_from)));
                },
                2 => {
                    value.tenths(seen.now.precipitation, writer.decimalPoint());
                    value.add(" mm");
                },
                3 => if (seen.day_count > 0) value.clock(seen.days[0].sunrise),
                else => if (seen.day_count > 0) value.clock(seen.days[0].sunset),
            }
            const right = layout.details.x + layout.details.width - 14 * scale;
            const value_width = writer.say(fonts.small, value.text(), right, y, .right, 1, 0);
            const left = layout.details.x + 36 * scale;
            _ = writer.say(fonts.small, view.text.get(label), left, y, .left, 0.75, @max(right - value_width - 8 * scale - left, 1));
        }
    }

    fn hours(writer: *Writer, layout: Layout, seen: *const Forecast) void {
        const view = writer.view;
        const fonts = &view.fonts;
        const scale = layout.scale;
        _ = writer.say(fonts.small, view.text.get(.MSG_NEXT_HOURS), layout.hours.x + 14 * scale, layout.hours.y + 8 * scale, .left, 0.75, layout.hours.width / 2);
        const count = seen.hour_count;
        if (count < 2) return;
        var lowest: f32 = seen.hours[0].temperature;
        var highest: f32 = lowest;
        for (seen.hours[0..count]) |*hour| {
            lowest = @min(lowest, hour.temperature);
            highest = @max(highest, hour.temperature);
        }
        if (highest - lowest < 4) {
            const middle = (highest + lowest) / 2;
            lowest = middle - 2;
            highest = middle + 2;
        }
        const top = layout.hours.y + 48 * scale;
        const bottom = layout.hours.y + 90 * scale;
        const small_height = writer.heightOf(fonts.small);
        var at: u32 = 0;
        while (at < count) : (at += 3) {
            const hour = &seen.hours[at];
            const x = layout.hourX(at, count);
            const y = bottom - (hour.temperature - lowest) / (highest - lowest) * (bottom - top);
            var degrees = Line{};
            degrees.degrees(hour.temperature);
            _ = writer.say(fonts.small, degrees.text(), x, y - small_height - 5 * scale, .centre, 1, 0);
            var time = Line{};
            time.clock(.{ .hour = hour.hour });
            _ = writer.say(fonts.small, time.text(), x, layout.hours.y + layout.hours.height - small_height - 6 * scale, .centre, 0.8, 0);
        }
    }

    fn days(writer: *Writer, layout: Layout, seen: *const Forecast) void {
        const view = writer.view;
        const fonts = &view.fonts;
        const scale = layout.scale;
        for (layout.cards, 0..) |card, at| {
            if (at + 1 >= seen.day_count) break;
            const day = &seen.days[at + 1];
            const name = if (at == 0) view.text.get(.MSG_TOMORROW) else writer.dayName(day.weekday);
            // The chance of rain on the right of its name, then the name.
            var chance = Line{};
            chance.number(day.rain_chance);
            chance.add(" %");
            const right = card.x + card.width - 14 * scale;
            const chance_width = writer.say(fonts.small, chance.text(), right, card.y + 12 * scale, .right, 0.9, 0);
            _ = writer.say(fonts.medium, name, card.x + 14 * scale, card.y + 10 * scale, .left, 1, @max(card.width - 42 * scale - chance_width, 1));
            const left = card.x + 84 * scale;
            var high = Line{};
            high.degrees(day.high);
            const high_width = writer.say(fonts.title, high.text(), left, card.y + 34 * scale, .left, 1, 0);
            var low = Line{};
            low.degrees(day.low);
            const title_height = writer.heightOf(fonts.title);
            const medium_height = writer.heightOf(fonts.medium);
            _ = writer.say(fonts.medium, low.text(), left + high_width + 8 * scale, card.y + 34 * scale + title_height - medium_height - 1 * scale, .left, 0.7, 0);
            _ = writer.say(fonts.small, view.text.get(wordsOf(day.code)), left, card.y + 36 * scale + title_height, .left, 0.85, right - left);
        }
    }

    fn dayName(writer: *Writer, weekday: u8) [*:0]const u8 {
        const strings_of = writer.view.text;
        const lb = strings_of.library orelse return "";
        const loc = strings_of.locale orelse return "";
        return lb.GetLocaleStr(loc, locale.DAY_1 + weekday) orelse "";
    }

    fn decimalPoint(writer: *Writer) [*:0]const u8 {
        const loc = writer.view.text.locale orelse return ".";
        return loc.decimal_point;
    }
};

/// The words of a WMO code.
fn wordsOf(code: u8) Id {
    return switch (code) {
        0 => .MSG_SKY_CLEAR,
        1 => .MSG_SKY_MAINLY_CLEAR,
        2 => .MSG_SKY_PARTLY_CLOUDY,
        3 => .MSG_SKY_OVERCAST,
        45 => .MSG_SKY_FOG,
        48 => .MSG_SKY_RIME_FOG,
        51 => .MSG_SKY_DRIZZLE_LIGHT,
        53 => .MSG_SKY_DRIZZLE,
        55 => .MSG_SKY_DRIZZLE_DENSE,
        56, 57 => .MSG_SKY_FREEZING_DRIZZLE,
        61 => .MSG_SKY_RAIN_LIGHT,
        63 => .MSG_SKY_RAIN,
        65 => .MSG_SKY_RAIN_HEAVY,
        66, 67 => .MSG_SKY_FREEZING_RAIN,
        71 => .MSG_SKY_SNOW_LIGHT,
        73 => .MSG_SKY_SNOW,
        75 => .MSG_SKY_SNOW_HEAVY,
        77 => .MSG_SKY_SNOW_GRAINS,
        80 => .MSG_SKY_SHOWERS_LIGHT,
        81 => .MSG_SKY_SHOWERS,
        82 => .MSG_SKY_SHOWERS_VIOLENT,
        85, 86 => .MSG_SKY_SNOW_SHOWERS,
        95 => .MSG_SKY_THUNDER,
        96, 99 => .MSG_SKY_THUNDER_HAIL,
        else => .MSG_SKY_UNKNOWN,
    };
}

/// The words for where the wind comes from, `degrees` from north.
fn compassOf(degrees: f32) Id {
    const points = [8]Id{ .MSG_WIND_N, .MSG_WIND_NE, .MSG_WIND_E, .MSG_WIND_SE, .MSG_WIND_S, .MSG_WIND_SW, .MSG_WIND_W, .MSG_WIND_NW };
    const turned = @mod(degrees + 22.5, 360);
    return points[@min(@as(usize, @intFromFloat(turned / 45)), 7)];
}

/// Days since 1 January 1978, dos's first day.
fn daysSince1978(year: u16, month: u8, day: u8) i32 {
    return civil(year, month, day) - civil(1978, 1, 1);
}

/// Days since 1 March of year 0 in the Gregorian calendar.
fn civil(year: u16, month: u8, day: u8) i32 {
    const shifted_year: i32 = @as(i32, year) - @as(i32, if (month <= 2) 1 else 0);
    const shifted_month: i32 = if (month <= 2) @as(i32, month) + 9 else @as(i32, month) - 3;
    return 365 * shifted_year + @divFloor(shifted_year, 4) - @divFloor(shifted_year, 100) + @divFloor(shifted_year, 400) + @divFloor(153 * shifted_month + 2, 5) + @as(i32, day) - 1;
}

/// A line of words put together in pieces, cut where it is full.
const Line = struct {
    bytes: [128:0]u8 = @splat(0),
    length: usize = 0,

    fn text(line: *const Line) [*:0]const u8 {
        return &line.bytes;
    }

    fn add(line: *Line, piece: []const u8) void {
        for (piece) |char| {
            if (line.length == line.bytes.len) break;
            line.bytes[line.length] = char;
            line.length += 1;
        }
        line.bytes[line.length] = 0;
    }

    fn addZ(line: *Line, piece: [*:0]const u8) void {
        line.add(piece[0..lengthOf(piece)]);
    }

    fn number(line: *Line, value: i64) void {
        var digits: [24]u8 = undefined;
        var count: usize = 0;
        var left: u64 = @abs(value);
        if (value < 0) line.add("-");
        while (true) {
            digits[count] = @intCast('0' + left % 10);
            count += 1;
            left /= 10;
            if (left == 0) break;
        }
        while (count > 0) {
            count -= 1;
            line.add(digits[count .. count + 1]);
        }
    }

    /// A temperature, whole, and the degree sign.
    fn degrees(line: *Line, value: f32) void {
        const whole: i64 = @intFromFloat(@round(value));
        line.number(whole);
        line.add("\u{B0}");
    }

    /// A number with one decimal, after `point`.
    fn tenths(line: *Line, value: f32, point: [*:0]const u8) void {
        const scaled: i64 = @intFromFloat(@round(@max(value, 0) * 10));
        line.number(@divTrunc(scaled, 10));
        line.addZ(point);
        line.number(@mod(scaled, 10));
    }

    /// `09:30`.
    fn clock(line: *Line, at: forecast.Clock) void {
        const digits = "0123456789";
        line.add(&.{ digits[at.hour / 10 % 10], digits[at.hour % 10], ':', digits[at.minute / 10 % 10], digits[at.minute % 10] });
    }
};

fn lengthOf(text: [*:0]const u8) u32 {
    var count: u32 = 0;
    while (text[count] != 0) count += 1;
    return count;
}
