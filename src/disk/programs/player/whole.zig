// SPDX-License-Identifier: MIT
//! The picture over the whole screen: a borderless window as large as the
//! screen, in front of every window - those that stay in front, a dock,
//! too, as the newest of them (`WA_StayInFront`) - which the window's
//! looks draw into in place of the canvas while it is open, with no
//! pointer over it. A key, or a press of any button, closes it; so does
//! another window made active over it.
//!
//! **The title** of the song - and its artist under it - is laid over the
//! picture at each new song, in the lower left: faded in for half a
//! second, held three, faded out in one (`overlay`, after each look). It
//! is drawn with the pen's alpha (`DRMD_BLEND`) over a shadow, in fonts
//! of its own made from the screen's - the title a fourteenth of the
//! screen high and bold, the artist half that - so it reads over any
//! picture, the whole screen's size whatever it is.
//!
//! **A line too wide** for the screen between its margins goes along: a
//! second after it has come in it moves left, three of its own heights a
//! second, until its end is at the right margin, and the title is held
//! there a second and a half before it fades - so a long title is held
//! longer. It is drawn whole, with the RastPort's clip narrowed to the
//! margins while it is, and the clip put back after. How wide each line
//! is is measured at the first look after the song is named, when the
//! fonts are on the RastPort to measure with (`measure`).

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const wn = intuition.windows;
const sc = intuition.screens;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const TagItem = utility.TagItem;

/// The looks - 25 a second - the title takes to come in, until it starts
/// to go, and until it is gone, when nothing of it is too wide.
const looks_a_second = 25;
const fade_in = 12;
const fade_from = 87;
const fade_out = 25;
/// A line too wide: the looks after it has come in before it moves, and
/// at its end before the title fades; how many of its heights it moves a
/// second.
const wait_before = 25;
const wait_after = 37;
const heights_a_second = 3;

pub const Whole = struct {
    window: *intuition.Window,
    rast_port: *graphics.RastPort,
    port: *sdk.exec.MsgPort,
    width: u32,
    height: u32,
    /// The title's font and the artist's; null without diskfont.library,
    /// and then the screen's own.
    big: ?*graphics.TextFont,
    small: ?*graphics.TextFont,
    /// What is shown, and the looks since it was named.
    title: [160:0]u8 = @splat(0),
    artist: [160:0]u8 = @splat(0),
    age: u32 = 0,
    /// The look the title starts to fade at, and the one it is gone at:
    /// later than `fade_from` when a line has to go along first. Gone
    /// before anything is named.
    fades: u32 = 0,
    ends: u32 = 0,
    /// Whether the lines have been measured since the song was named, and
    /// how far each runs past the margins.
    measured: bool = false,
    title_over: i32 = 0,
    artist_over: i32 = 0,

    /// The window opened over the whole of `screen`, made active: null
    /// when it would not open.
    pub fn open(ib: *IntuitionBase, gb: *GraphicsBase, dfb: ?*DiskfontBase, screen: *intuition.Screen) ?Whole {
        var width: usize = 0;
        var height: usize = 0;
        ib.GetScreenAttrs(screen, &[_]TagItem{
            .{ .tag = sc.SA_Width, .data = @intFromPtr(&width) },
            .{ .tag = sc.SA_Height, .data = @intFromPtr(&height) },
            .{},
        });
        if (width < 16 or height < 16) return null;
        const window = ib.OpenWindowTagList(&[_]TagItem{
            .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
            .{ .tag = wn.WA_Left, .data = 0 },
            .{ .tag = wn.WA_Top, .data = 0 },
            .{ .tag = wn.WA_Width, .data = width },
            .{ .tag = wn.WA_Height, .data = height },
            .{ .tag = wn.WA_Borderless, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wn.WA_StayInFront, .data = 1 },
            .{ .tag = wn.WA_HidePointer, .data = 1 },
            .{ .tag = wn.WA_RMBTrap, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_VANILLAKEY | wn.IDCMP_RAWKEY | wn.IDCMP_MOUSEBUTTONS | wn.IDCMP_INACTIVEWINDOW },
            .{},
        }) orelse return null;
        var rast_port: usize = 0;
        var port: usize = 0;
        ib.GetWindowAttrs(window, &[_]TagItem{
            .{ .tag = wn.WA_RastPort, .data = @intFromPtr(&rast_port) },
            .{ .tag = wn.WA_UserPort, .data = @intFromPtr(&port) },
            .{},
        });
        if (rast_port == 0 or port == 0) {
            ib.CloseWindow(window);
            return null;
        }
        const rows: u32 = @intCast(height);
        return .{
            .window = window,
            .rast_port = @ptrFromInt(rast_port),
            .port = @ptrFromInt(port),
            .width = @intCast(width),
            .height = rows,
            .big = font(ib, gb, dfb, rows / 14, graphics.FSF_BOLD),
            .small = font(ib, gb, dfb, rows / 28, 0),
        };
    }

    pub fn close(whole: *Whole, ib: *IntuitionBase, gb: *GraphicsBase) void {
        ib.CloseWindow(whole.window);
        if (whole.big) |made| gb.CloseFont(made);
        if (whole.small) |made| gb.CloseFont(made);
    }

    /// Whether the title is still being laid over the picture.
    pub fn fading(whole: *const Whole) bool {
        return whole.age < whole.ends;
    }

    pub fn signal(whole: *const Whole) u32 {
        return whole.port.sigMask();
    }

    /// Its messages answered: false once it is to close - a key went down,
    /// a button was pressed, or it is no longer the active window.
    pub fn messages(whole: *Whole, ib: *IntuitionBase) bool {
        var stays = true;
        while (ib.GetIMsg(whole.window)) |message| {
            switch (message.class) {
                wn.IDCMP_VANILLAKEY, wn.IDCMP_INACTIVEWINDOW => stays = false,
                // A key going down; its going up comes after the window
                // that took it closed it.
                wn.IDCMP_RAWKEY => if (message.code & sdk.devices.inputevent.IECODE_UP_PREFIX == 0) {
                    stays = false;
                },
                wn.IDCMP_MOUSEBUTTONS => if (message.code == wn.SELECTDOWN or message.code == wn.MENUDOWN or message.code == wn.MIDDLEDOWN) {
                    stays = false;
                },
                else => {},
            }
            ib.ReplyIMsg(message);
        }
        return stays;
    }

    /// The song named `title` by `artist` (either empty), laid over the
    /// picture from the next look - unless it is the one shown.
    pub fn named(whole: *Whole, title: [*:0]const u8, artist: [*:0]const u8) void {
        if (same(title, &whole.title) and same(artist, &whole.artist)) return;
        copy(&whole.title, title);
        copy(&whole.artist, artist);
        whole.age = 0;
        whole.measured = false;
        whole.fades = fade_from;
        whole.ends = fade_from + fade_out;
    }

    /// The title and the artist over the picture just written, as bright
    /// as this look of their fading has them.
    ///
    /// It draws four times - a shadow and the text itself, for each of
    /// the two lines - so the caller holds it and the picture under it in
    /// one batch (graphics' `BeginDraw`/`EndDraw`), or the display is
    /// given the picture without the title and then the title, and the
    /// title flickers at the look rate.
    pub fn overlay(whole: *Whole, gb: *GraphicsBase) void {
        if (whole.age >= whole.ends) return;
        defer whole.age += 1;
        const margin: i32 = @intCast(whole.height / 20);
        if (!whole.measured) whole.measure(gb, margin);
        const alpha: u32 = if (whole.age < fade_in)
            whole.age * 255 / fade_in
        else if (whole.age < whole.fades) 255 else (whole.ends - whole.age) * 255 / (whole.ends - whole.fades);
        const gap: i32 = @intCast(whole.height / 80);
        const rp = whole.rast_port;
        var bottom: i32 = @as(i32, @intCast(whole.height)) - margin;
        if (whole.artist[0] != 0) bottom = whole.line(gb, whole.small, &whole.artist, whole.artist_over, margin, bottom, alpha) - gap;
        if (whole.title[0] != 0) _ = whole.line(gb, whole.big, &whole.title, whole.title_over, margin, bottom, alpha);
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
    }

    /// How far each line runs past the margins, and when the title fades
    /// with the longest of them gone along first.
    fn measure(whole: *Whole, gb: *GraphicsBase, margin: i32) void {
        whole.measured = true;
        const room = @as(i32, @intCast(whole.width)) - 2 * margin;
        whole.title_over = whole.overOf(gb, whole.big, &whole.title, room);
        whole.artist_over = whole.overOf(gb, whole.small, &whole.artist, room);
        const going = @max(whole.looksFor(gb, whole.big, whole.title_over), whole.looksFor(gb, whole.small, whole.artist_over));
        if (going == 0) return;
        whole.fades = @max(fade_from, fade_in + wait_before + going + wait_after);
        whole.ends = whole.fades + fade_out;
    }

    /// How far `text` in `face` runs past `room`; 0 when it fits.
    fn overOf(whole: *Whole, gb: *GraphicsBase, face: ?*graphics.TextFont, text: [*:0]const u8, room: i32) i32 {
        if (text[0] == 0) return 0;
        const rp = whole.rast_port;
        wear(gb, rp, face);
        return @max(gb.TextLength(rp, text, textLength(text)) - room, 0);
    }

    /// The looks a line `over` past the margins in `face` takes to go
    /// along to its end.
    fn looksFor(whole: *Whole, gb: *GraphicsBase, face: ?*graphics.TextFont, over: i32) u32 {
        if (over <= 0) return 0;
        const speed = whole.speedOf(gb, face);
        return (@as(u32, @intCast(over)) * looks_a_second + speed - 1) / speed;
    }

    /// How many pixels a second a line in `face` goes along: three of its
    /// heights.
    fn speedOf(whole: *Whole, gb: *GraphicsBase, face: ?*graphics.TextFont) u32 {
        wear(gb, whole.rast_port, face);
        return @max(heightOf(gb, whole.rast_port) * heights_a_second, 1);
    }

    /// How far along a line `over` past the margins in `face` is at this
    /// look.
    fn along(whole: *Whole, gb: *GraphicsBase, face: ?*graphics.TextFont, over: i32) i32 {
        if (over <= 0 or whole.age <= fade_in + wait_before) return 0;
        const moved = @as(u64, whole.age - fade_in - wait_before) * whole.speedOf(gb, face) / looks_a_second;
        return @intCast(@min(moved, @as(u64, @intCast(over))));
    }

    /// `text` in `face` with its foot at `bottom`, from `left`, over its
    /// shadow - gone along by as much as it has when it is `over` the
    /// margins: where its top is.
    fn line(whole: *Whole, gb: *GraphicsBase, face: ?*graphics.TextFont, text: [*:0]const u8, over: i32, left: i32, bottom: i32, alpha: u32) i32 {
        const rp = whole.rast_port;
        const shift = whole.along(gb, face, over);
        wear(gb, rp, face);
        const height = heightOf(gb, rp);
        var baseline: usize = 0;
        gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) }, .{} });
        const top = bottom - @as(i32, @intCast(height));
        const at_y = top + @as(i32, @intCast(baseline));
        const shadow: i32 = @max(@as(i32, @intCast(height / 16)), 1);
        const count = textLength(text);
        // Held between the margins while it goes along.
        var was: graphics.Rect = .{};
        if (over > 0) {
            gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&was) }, .{} });
            var held = was;
            held.min_x = @max(was.min_x, left);
            held.max_x = @min(was.max_x, @as(i32, @intCast(whole.width)) - left + shadow);
            gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&held) }, .{} });
        }
        defer if (over > 0) gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&was) }, .{} });
        const pen = [2]graphics.Pen{
            graphics.penARGB(@intCast(alpha * 3 / 4), 0, 0, 0),
            graphics.penARGB(@intCast(alpha), 255, 255, 255),
        };
        for (pen, [2]i32{ shadow, 0 }) |colour, off| {
            gb.SetRPAttrs(rp, &[_]TagItem{
                .{ .tag = graphics.RPTAG_APen, .data = colour },
                .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 | graphics.DRMD_BLEND },
                .{},
            });
            gb.Move(rp, left - shift + off, at_y + off);
            gb.Text(rp, text, count);
        }
        return top;
    }
};

/// `face` on the RastPort, when there is one; the screen's font stays
/// otherwise.
fn wear(gb: *GraphicsBase, rp: *graphics.RastPort, face: ?*graphics.TextFont) void {
    if (face) |made| gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(made) }, .{} });
}

fn heightOf(gb: *GraphicsBase, rp: *graphics.RastPort) u32 {
    var height: usize = 0;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) }, .{} });
    return @intCast(height);
}

fn textLength(text: [*:0]const u8) u32 {
    var count: u32 = 0;
    while (text[count] != 0) count += 1;
    return count;
}

/// The screen's font `rows` high in `style`, from diskfont.library; null
/// without it.
fn font(ib: *IntuitionBase, gb: *GraphicsBase, dfb: ?*DiskfontBase, rows: u32, style: u8) ?*graphics.TextFont {
    const fonts = dfb orelse return null;
    const system = ib.OpenSystemFont(sc.SYSFONT_DEFAULT) orelse return null;
    defer gb.CloseFont(system);
    const name = system.node.name orelse return null;
    return fonts.OpenDiskFont(&.{ .name = name, .y_size = @intCast(@max(rows, 8)), .style = style });
}

fn same(a: [*:0]const u8, b: [*:0]const u8) bool {
    var at: usize = 0;
    while (a[at] == b[at]) : (at += 1) {
        if (a[at] == 0) return true;
    }
    return false;
}

fn copy(into: *[160:0]u8, text: [*:0]const u8) void {
    var length: usize = 0;
    while (text[length] != 0 and length < into.len) : (length += 1) into[length] = text[length];
    into[length] = 0;
}
