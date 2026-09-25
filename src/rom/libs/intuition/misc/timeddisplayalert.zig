// SPDX-License-Identifier: MPL-2.0
//! TimedDisplayAlert: an alert, answered with a button or left to time out.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("../screen/_screen.zig");
const _misc = @import("_misc.zig");

/// How often the box's border changes, in frames.
const flash_frames = 64;
/// The border's width across and down.
const border_x = 6;
const border_y = 3;

/// Shows an alert and waits for an answer, or for the time to run out.
///
/// SYNOPSIS:
/// ```zig
/// fn TimedDisplayAlert(ib: *IntuitionBase, alert_number: u32, text: [*:0]const u8, height: u32, frames: u32) bool
/// ```
///
/// SINCE: 0.14. LVO -420.
///
/// INPUTS:
/// - `alert_number` - what the alert is; only its type counts here:
///   `AT_DeadEnd` set for one the system does not come back from.
/// - `text` - what it says, lines parted by `'\n'`, each centred.
/// - `height` - the least height of its box, in pixels; the box grows to
///   hold the lines.
/// - `frames` - how long it waits for an answer, in frames of a 60 Hz
///   display; 0 shows nothing and answers false.
///
/// RESULT:
/// True when the left button - or a touch on the left half of the display -
/// answered it; false for the right button or the right half, when the
/// time ran out, when it could not be shown, and always for a dead-end
/// alert.
///
/// BEHAVIOR:
/// The alert is shown alone, on a black picture of the display's own: a
/// box across its top, amber - red for a dead end - with the text in it,
/// its border flashing. Everything else is kept as it is and shown again
/// when the alert comes down. While it is up, the input is its own:
/// nothing reaches a window, and presses made before it came up are not
/// taken for an answer. A dead-end alert stays up: this returns at once
/// and nothing takes it down. One alert at a time; a second waits for the
/// first.
///
/// CONTEXT:
/// - Waits: for the answer or the time, and for an alert already up.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; not intuition's input task, whose events
///   answer it.
///
/// OWNERSHIP:
/// The text is read while the alert is up and not kept.
///
/// NOTES:
/// The picture comes out of the display's memory: when that has no room
/// for another one, the alert cannot be shown.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DisplayAlert`, `EasyRequestArgs`, exec's `Alert`
///
/// EXAMPLES:
/// ```zig
/// // Six seconds to say whether to go on.
/// const go_on = ib.TimedDisplayAlert(exec.AT_Recovery, "The disk went away.\nLeft: retry   Right: cancel", 60, 360);
/// ```
pub fn TimedDisplayAlert(ib: *IntuitionBase, alert_number: u32, text: [*:0]const u8, height: u32, frames: u32) bool {
    if (frames == 0) return false;
    const sys = ib.sys_base;
    const gb = ib.graphics_base;
    const rb = ib.rtg_base orelse return false;
    sys.ObtainSemaphore(&ib.alert_lock);
    const dead_end = alert_number & exec.AT_DeadEnd != 0;
    // A dead end keeps the lock: no alert comes after it.
    defer if (!dead_end) sys.ReleaseSemaphore(&ib.alert_lock);

    const board = displayBoard(ib) orelse return false;
    const shown = board.showing orelse return false;
    const picture = rb.AllocBitMap(board, shown.width, shown.height, @intFromEnum(shown.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse return false;
    const on = [_]TagItem{ .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(picture) }, .{} };
    const rp = gb.CreateRastPortTagList(&on) orelse {
        rb.FreeBitMap(picture);
        return false;
    };
    const font = gb.OpenFont(graphics.POSPAZNAME, ib.font_height);
    if (font) |f| graphics.SetFont(gb, rp, f);

    const colour = if (dead_end) graphics.penRGB(0xFF, 0x22, 0x00) else graphics.penRGB(0xFF, 0xAA, 0x22);
    const width: i32 = @intCast(shown.width);
    const box_h = boxHeight(gb, rp, text, height);
    pen(gb, rp, graphics.penRGB(0, 0, 0));
    gb.RectFill(rp, &.{ .max_x = width, .max_y = @intCast(shown.height) });
    drawBorder(gb, rp, width, box_h, colour);
    drawText(gb, rp, text, width, colour);

    // Up: the input is the alert's from now on.
    _screen.lock(ib);
    ib.alert = .{ .active = true, .half = @divTrunc(width, 2) };
    _ = rb.ShowBitMap(board, picture, 0, 0);
    _screen.unlock(ib);
    if (dead_end) return false;

    var left = frames;
    var lit = true;
    while (left > 0 and ib.alert.answer == .none) : (left -= 1) {
        _misc.wait(ib, _misc.frame_us);
        if (left % flash_frames == 0) {
            lit = !lit;
            drawBorder(gb, rp, width, box_h, if (lit) colour else graphics.penRGB(0, 0, 0));
        }
    }
    const answer = ib.alert.answer;

    // Down: the display shows what it would have, and the input goes back.
    _screen.lock(ib);
    ib.alert = .{};
    _screen.showFront(ib, board, homeOf(ib, board, shown));
    if (board.showing == picture) _ = rb.ShowBitMap(board, shown, 0, 0);
    _screen.unlock(ib);
    gb.FreeRastPort(rp);
    if (font) |f| gb.CloseFont(f);
    rb.FreeBitMap(picture);
    return answer == .yes;
}

fn pen(gb: anytype, rp: *graphics.RastPort, value: graphics.Pen) void {
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = value },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
}

/// The display intuition shows its screens on: the front screen's, or the
/// one graphics.library draws on by default.
fn displayBoard(ib: *IntuitionBase) ?*rtg.RtgBoard {
    if (ib.screen_list.head) |n| {
        if (n.succ != null) return @as(*_screen.Screen, @ptrCast(@alignCast(n))).board;
    }
    const gb = ib.graphics_base;
    const probe = gb.CreateRastPortTagList(null) orelse return null;
    defer gb.FreeRastPort(probe);
    var at: usize = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(&at) }, .{} };
    gb.GetRPAttrs(probe, &ask);
    if (at == 0) return null;
    const bitmap: *rtg.RtgBitMap = @ptrFromInt(at);
    return @ptrCast(@alignCast(bitmap.board orelse return null));
}

/// What the display shows when no screen is up: its screens' home, or the
/// buffer it showed before the alert.
fn homeOf(ib: *IntuitionBase, board: *rtg.RtgBoard, before: *rtg.RtgBitMap) *rtg.RtgBitMap {
    return _screen.homeOf(ib, board, before);
}

fn fontHeight(gb: anytype, rp: *graphics.RastPort) i32 {
    var height: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    return @intCast(height);
}

fn lineCount(text: [*:0]const u8) i32 {
    var lines: i32 = 1;
    var i: usize = 0;
    while (text[i] != 0) : (i += 1) {
        if (text[i] == '\n') lines += 1;
    }
    return lines;
}

/// The box: as tall as asked, or as the lines and the border need.
fn boxHeight(gb: anytype, rp: *graphics.RastPort, text: [*:0]const u8, height: u32) i32 {
    // The lines, half a line's room above and below them, and the border.
    const needed = (lineCount(text) + 1) * fontHeight(gb, rp) + 4 * border_y;
    return @max(@as(i32, @intCast(height)), needed);
}

/// The box's border, in `colour`.
fn drawBorder(gb: anytype, rp: *graphics.RastPort, width: i32, height: i32, colour: graphics.Pen) void {
    pen(gb, rp, colour);
    gb.RectFill(rp, &.{ .max_x = width, .max_y = border_y });
    gb.RectFill(rp, &.{ .min_y = height - border_y, .max_x = width, .max_y = height });
    gb.RectFill(rp, &.{ .min_y = 0, .max_x = border_x, .max_y = height });
    gb.RectFill(rp, &.{ .min_x = width - border_x, .max_x = width, .max_y = height });
}

/// Each line centred, one under the other from the top of the box.
fn drawText(gb: anytype, rp: *graphics.RastPort, text: [*:0]const u8, width: i32, colour: graphics.Pen) void {
    pen(gb, rp, colour);
    var baseline: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    const line_h = fontHeight(gb, rp);
    var y: i32 = 2 * border_y + @divTrunc(line_h, 2) + @as(i32, @intCast(baseline));
    var start: usize = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        const c = text[i];
        if (c != '\n' and c != 0) continue;
        const len: u32 = @intCast(i - start);
        const line = text + start;
        const w = gb.TextLength(rp, line, len);
        gb.Move(rp, @divTrunc(width - w, 2), y);
        gb.Text(rp, line, len);
        y += line_h;
        if (c == 0) break;
        start = i + 1;
    }
}
