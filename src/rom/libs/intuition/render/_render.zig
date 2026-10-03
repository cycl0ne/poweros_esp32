// SPDX-License-Identifier: MPL-2.0
//! What the drawing calls share: a chain of IntuiText runs read and put
//! down.
//!
//! An IntuiText is a tag list of `IT_` tags. `runOf` reads one run's tags
//! in a single pass; whatever a run does not name comes back null and is
//! the RastPort's own. `PrintIText` draws each run in what it names; an
//! itexticlass image draws its runs in the one pen the image has, so a
//! label takes its colour from where it is shown. Both are `printRuns`,
//! told which.
//!
//! The runs intuition makes for itself - a menu item's words, a
//! requester's lines - are `RunTags`: every tag in a fixed place, so a
//! layout can write the place, the pen and the font it works out into
//! them afterwards with `setTag`.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const TagItem = utility.TagItem;
const UtilityBase = sdk.interface.utility.UtilityBase;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const d = @import("../classes/draw.zig");

/// One run, read out of its tags: what it names, and null for what it
/// leaves to the RastPort.
pub const Run = struct {
    text: ?[*:0]const u8 = null,
    front_pen: ?graphics.Pen = null,
    back_pen: ?graphics.Pen = null,
    draw_mode: ?u32 = null,
    left: i32 = 0,
    top: i32 = 0,
    font: ?*graphics.TextFont = null,
    style: ?graphics.FontStyle = null,
    next: ?[*]const TagItem = null,
};

/// A run's tags read in one pass.
pub fn runOf(ub: *UtilityBase, tags: [*]const TagItem) Run {
    var run = Run{};
    var state: ?[*]const TagItem = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            intuition.IT_Text => run.text = @ptrFromInt(item.data),
            intuition.IT_FrontPen => run.front_pen = @truncate(item.data),
            intuition.IT_BackPen => run.back_pen = @truncate(item.data),
            intuition.IT_DrawMode => run.draw_mode = @truncate(item.data),
            intuition.IT_Left => run.left = @truncate(@as(isize, @bitCast(item.data))),
            intuition.IT_Top => run.top = @truncate(@as(isize, @bitCast(item.data))),
            intuition.IT_Font => run.font = @ptrFromInt(item.data),
            intuition.IT_Style => run.style = @truncate(item.data),
            intuition.IT_Next => run.next = @ptrFromInt(item.data),
            else => {},
        }
    }
    return run;
}

/// A run's tag set to `value` where the run has it: how a layout puts
/// what it worked out into runs that were made writable for it. False,
/// and nothing written, when the run has no such tag.
pub fn setTag(ub: *UtilityBase, tags: [*]const TagItem, tag: utility.Tag, value: usize) bool {
    const item = ub.FindTagItem(tag, tags) orelse return false;
    // The runs a layout writes are made writable for it (`RunTags`).
    @constCast(item).data = value;
    return true;
}

/// The tags of a run intuition makes: the words, the pen and mode, the
/// place, the font and the next run, each in its own place, and the end.
pub const RunTags = [8]TagItem;

/// A run in `RunTags`, JAM1, in `font` (null: the RastPort's).
pub fn makeRun(words: ?[*:0]const u8, front_pen: graphics.Pen, left: i32, top: i32, font: ?*graphics.TextFont, next: ?[*]const TagItem) RunTags {
    return .{
        .{ .tag = intuition.IT_Text, .data = @intFromPtr(words) },
        .{ .tag = intuition.IT_FrontPen, .data = front_pen },
        .{ .tag = intuition.IT_DrawMode, .data = graphics.DRMD_JAM1 },
        .{ .tag = intuition.IT_Left, .data = @bitCast(@as(isize, left)) },
        .{ .tag = intuition.IT_Top, .data = @bitCast(@as(isize, top)) },
        // There even without a font, so that a layout can name one.
        .{ .tag = intuition.IT_Font, .data = @intFromPtr(font) },
        .{ .tag = intuition.IT_Next, .data = @intFromPtr(next) },
        .{},
    };
}

/// Each run of the chain at (left, top) plus its own place. `ink` null
/// draws each in what it names and the RastPort's own for the rest; a pen
/// draws every run in that pen, in JAM1. Each run starts from the
/// RastPort as it was given, which gets its pens, mode, font and style
/// back at the end; its current point is left where the last run ended.
pub fn printRuns(ib: *IntuitionBase, rp: *graphics.RastPort, itext: ?[*]const TagItem, left: i32, top: i32, ink: ?graphics.Pen) void {
    const gb = ib.graphics_base;
    const ub = ib.utility_base;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);

    var at = itext;
    while (at) |tags| {
        const run = runOf(ub, tags);
        at = run.next;
        const words = run.text orelse continue;
        const count: u32 = @intCast(ub.Strlen(words));
        if (count == 0) continue;
        const looks = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = ink orelse run.front_pen orelse saved.apen },
            .{ .tag = graphics.RPTAG_BPen, .data = run.back_pen orelse saved.bpen },
            .{ .tag = graphics.RPTAG_DrMd, .data = if (ink != null) graphics.DRMD_JAM1 else run.draw_mode orelse saved.mode },
            .{ .tag = graphics.RPTAG_Font, .data = if (run.font) |font| @intFromPtr(font) else saved.font },
            .{ .tag = graphics.RPTAG_TextStyle, .data = run.style orelse saved.style },
            .{},
        };
        gb.SetRPAttrs(rp, &looks);
        // The font is known only now, so its baseline is asked for here.
        var baseline: u32 = 0;
        const metric = [_]TagItem{
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        };
        gb.GetRPAttrs(rp, &metric);
        gb.Move(rp, left + run.left, top + run.top + @as(i32, @intCast(baseline)));
        gb.Text(rp, words, count);
    }
}
