// SPDX-License-Identifier: MIT
//! Movie's frame rate: how many pictures were shown in the last second of
//! playing and how many were given back unshown, drawn over the top left
//! of the picture while the menu's Frame rate is ticked.
//!
//! **The count** goes by what the pictures' turn does: each picture shown
//! and each given back too late is counted, and once a second of playing
//! has passed the program makes the text from it (`due`, `take`). A start
//! or a move counts from there (`restart`), so a pause is no slow second.
//!
//! **The text** is drawn in the screen's font, white on a black box, a
//! little in from the picture's corner. Without the video layer the
//! picture is put down anew each frame, over it, and the text is drawn
//! again on it each time. Over the layer nothing paints over it, so it is
//! drawn when it changes, and the key colour put back where it was before
//! - as when the frame rate is no longer shown (`hide`).

const sdk = @import("sdk");
const graphics = sdk.graphics;
const sc = sdk.intuition.screens;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const TagItem = sdk.utility.TagItem;
const Rect = graphics.Rect;

/// How long a count runs before it is turned into a rate, in microseconds.
const period: u64 = 1_000_000;
/// How far the box is in from the picture's corner, and the text in from
/// the box's edge, in pixels.
const margin = 8;
const pad = 4;

pub const FrameRate = struct {
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    /// Shown over the picture.
    on: bool = false,
    /// The count since `since` (an uptime in microseconds): pictures shown,
    /// and given back unshown.
    since: u64 = 0,
    shown: u32 = 0,
    dropped: u32 = 0,
    /// The text, as the program last made it; empty before the first
    /// second has passed. `changed` until it is drawn.
    text: [128:0]u8 = @splat(0),
    changed: bool = false,
    /// The screen's font, opened when the text is first drawn.
    font: ?*graphics.TextFont = null,
    /// Where the box was drawn last, and into which RastPort: the key
    /// colour goes back there.
    drawn: bool = false,
    rast_port: ?*graphics.RastPort = null,
    area: Rect = .{},

    /// The font given back.
    pub fn close(rate: *FrameRate) void {
        if (rate.font) |font| rate.gb.CloseFont(font);
        rate.font = null;
    }

    /// Counting begins again at `now`: the film started, moved or went on.
    pub fn restart(rate: *FrameRate, now: u64) void {
        rate.since = now;
        rate.shown = 0;
        rate.dropped = 0;
    }

    /// A picture shown, or given back unshown.
    pub fn count(rate: *FrameRate, shown: bool) void {
        if (shown) rate.shown += 1 else rate.dropped += 1;
    }

    /// Whether a second's count is in at `now`: the program then makes the
    /// text with `take`.
    pub fn due(rate: *const FrameRate, now: u64) bool {
        return now -% rate.since >= period;
    }

    /// The count turned into a rate, in tenths of a picture a second, and
    /// the pictures given back unshown; counting begins again at `now`.
    pub fn take(rate: *FrameRate, now: u64) struct { tenths: u32, dropped: u32 } {
        const elapsed = @max(now -% rate.since, 1);
        const tenths: u32 = @intCast(@min(@as(u64, rate.shown) * 10_000_000 / elapsed, 0xFFFF_FFFF));
        const dropped = rate.dropped;
        rate.restart(now);
        return .{ .tenths = tenths, .dropped = dropped };
    }

    /// A new text for the box.
    pub fn set(rate: *FrameRate, made: []const u8) void {
        const length = @min(made.len, rate.text.len);
        @memcpy(rate.text[0..length], made[0..length]);
        rate.text[length] = 0;
        rate.changed = true;
    }

    /// Forgets what was drawn: the picture's place has been filled anew.
    pub fn forget(rate: *FrameRate) void {
        rate.drawn = false;
        rate.area = .{};
    }

    /// The text drawn over the picture just put in `box` of `rp`: always
    /// when the picture was put down over it (`repainted`), else when it
    /// changed. `key` is the layer's colour where the film is on one.
    /// Whether anything was drawn.
    pub fn show(rate: *FrameRate, rp: *graphics.RastPort, box: Rect, key: ?u32, repainted: bool) bool {
        if (!rate.on or rate.text[0] == 0) return false;
        if (!repainted and !rate.changed and rp == rate.rast_port and rate.drawn) return false;
        const gb = rate.gb;
        // The box before taken away where the picture was not put again.
        if (rate.drawn and !repainted and rp == rate.rast_port) rate.fill(rp, rate.area, key);
        if (rate.font == null) rate.font = rate.ib.OpenSystemFont(sc.SYSFONT_DEFAULT);
        if (rate.font) |font| gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) }, .{} });
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
        var font_height: usize = 0;
        var baseline: usize = 0;
        gb.GetRPAttrs(rp, &[_]TagItem{
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) },
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        });
        var length: u32 = 0;
        while (rate.text[length] != 0) length += 1;
        const wide = gb.TextLength(rp, &rate.text, length);
        const left = box.min_x + margin;
        const top = box.min_y + margin;
        const area = clip(.{
            .min_x = left,
            .min_y = top,
            .max_x = left + wide + 2 * pad,
            .max_y = top + @as(i32, @intCast(font_height)) + 2 * pad,
        }, box);
        rate.rast_port = rp;
        rate.changed = false;
        if (area.width() <= 0 or area.height() <= 0) {
            rate.forget();
            return false;
        }
        gb.SetRPAttrs(rp, &[_]TagItem{ pen(graphics.penRGB(0, 0, 0)), .{} });
        gb.RectFill(rp, &area);
        gb.SetRPAttrs(rp, &[_]TagItem{ pen(graphics.penRGB(255, 255, 255)), .{} });
        gb.Move(rp, left + pad, top + pad + @as(i32, @intCast(baseline)));
        gb.Text(rp, &rate.text, length);
        rate.drawn = true;
        rate.area = area;
        return true;
    }

    /// The box taken away: the key colour put back where it was over the
    /// layer. Without the layer the program puts the picture down again.
    /// Whether anything was drawn.
    pub fn hide(rate: *FrameRate, key: ?u32) bool {
        defer rate.forget();
        const rp = rate.rast_port orelse return false;
        if (!rate.drawn or key == null) return false;
        rate.fill(rp, rate.area, key);
        return true;
    }

    /// `area` filled with the layer's key colour, where there is a layer.
    fn fill(rate: *FrameRate, rp: *graphics.RastPort, area: Rect, key: ?u32) void {
        const colour = key orelse return;
        if (area.width() <= 0 or area.height() <= 0) return;
        rate.gb.SetRPAttrs(rp, &[_]TagItem{ pen(graphics.penRGB(@truncate(colour >> 16), @truncate(colour >> 8), @truncate(colour))), .{} });
        rate.gb.RectFill(rp, &area);
    }
};

fn pen(colour: graphics.Pen) TagItem {
    return .{ .tag = graphics.RPTAG_APen, .data = colour };
}

fn clip(area: Rect, box: Rect) Rect {
    const clipped = Rect{
        .min_x = @max(area.min_x, box.min_x),
        .min_y = @max(area.min_y, box.min_y),
        .max_x = @min(area.max_x, box.max_x),
        .max_y = @min(area.max_y, box.max_y),
    };
    if (clipped.max_x <= clipped.min_x or clipped.max_y <= clipped.min_y) return .{};
    return clipped;
}
