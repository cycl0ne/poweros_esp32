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
/// to go, and until it is gone.
const fade_in = 12;
const fade_from = 87;
const gone = 112;

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
    age: u32 = gone,

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
        return whole.age < gone;
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
    }

    /// The title and the artist over the picture just written, as bright
    /// as this look of their fading has them.
    pub fn overlay(whole: *Whole, gb: *GraphicsBase) void {
        if (whole.age >= gone) return;
        defer whole.age += 1;
        const alpha: u32 = if (whole.age < fade_in)
            whole.age * 255 / fade_in
        else if (whole.age < fade_from) 255 else (gone - whole.age) * 255 / (gone - fade_from);
        const margin: i32 = @intCast(whole.height / 20);
        const gap: i32 = @intCast(whole.height / 80);
        const rp = whole.rast_port;
        var bottom: i32 = @as(i32, @intCast(whole.height)) - margin;
        if (whole.artist[0] != 0) bottom = whole.line(gb, whole.small, &whole.artist, margin, bottom, alpha) - gap;
        if (whole.title[0] != 0) _ = whole.line(gb, whole.big, &whole.title, margin, bottom, alpha);
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
    }

    /// `text` in `face` with its foot at `bottom`, from `left`, over its
    /// shadow: where its top is.
    fn line(whole: *Whole, gb: *GraphicsBase, face: ?*graphics.TextFont, text: [*:0]const u8, left: i32, bottom: i32, alpha: u32) i32 {
        const rp = whole.rast_port;
        if (face) |made| gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(made) }, .{} });
        var height: usize = 0;
        var baseline: usize = 0;
        gb.GetRPAttrs(rp, &[_]TagItem{
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        });
        const top = bottom - @as(i32, @intCast(height));
        const at_y = top + @as(i32, @intCast(baseline));
        // As much of it as the screen is wide.
        const room = @as(i32, @intCast(whole.width)) - 2 * left;
        var count: u32 = 0;
        while (text[count] != 0) count += 1;
        while (count > 0 and gb.TextLength(rp, text, count) > room) count -= 1;
        const shadow: i32 = @max(@as(i32, @intCast(height / 16)), 1);
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
            gb.Move(rp, left + off, at_y + off);
            gb.Text(rp, text, count);
        }
        return top;
    }
};

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
