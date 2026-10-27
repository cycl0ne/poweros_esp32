// SPDX-License-Identifier: MIT
//! clock.docklet: the time, as a clock face with two hands.
//!
//! The face is the screen's shine pen in a ring of its text pen, with a
//! mark at each hour - the four quarters larger - and the hour and minute
//! hands, each tapering from the middle to a point. It looks every second
//! and changes when the minute does. What it says is the time and the
//! date as `Date` prints them: "14:05, Tuesday 27-Oct-2026". A click on
//! it runs nothing.

const sdk = @import("sdk");
const dos = sdk.dos;
const docklets = sdk.docklets;
const angles = sdk.gadgets.angles;
const DosBase = sdk.interface.dos.DosBase;

pub const Data = extern struct {
    /// The day and the minute shown; -1 before the first look.
    days: i32 = -1,
    minute: i32 = -1,
    text: [48]u8 = @splat(0),
};

const Class = docklets.DockletClass(Data, .{
    .name = docklets.CLOCK_CLASS,
    .version = 1,
    .date = "27.10.2026",
    .title = "Clock",
    .opens = &.{"dos.library"},
    .look = look,
    .text = text,
    .draw = draw,
});
pub const Library = Class.Library;
comptime {
    _ = Library;
}

fn look(base: *sdk.gadgets.Base, own: *Data) bool {
    const dl: *DosBase = @ptrCast(base.opened[0].?);
    var now: dos.DateTime = .{};
    _ = dl.DateStamp(&now.stamp);
    if (now.stamp.days == own.days and now.stamp.minute == own.minute) return false;
    own.days = now.stamp.days;
    own.minute = now.stamp.minute;
    var day: [16:0]u8 = @splat(0);
    var date: [16:0]u8 = @splat(0);
    var time: [16:0]u8 = @splat(0);
    now.str_day = &day;
    now.str_date = &date;
    now.str_time = &time;
    if (!dl.DateToStr(&now)) {
        own.text[0] = 0;
        return true;
    }
    // hh:mm, without the seconds.
    time[5] = 0;
    _ = docklets.format(base.sys_base, &own.text, "%s, %s %s", .{ @as([*:0]const u8, &time), @as([*:0]const u8, &day), @as([*:0]const u8, &date) });
    return true;
}

fn text(own: *Data) [*:0]const u8 {
    return @ptrCast(&own.text);
}

/// A hand at `degrees`, `length` from the middle: a narrow wedge whose
/// point is the hand's tip and whose wide end, `sweep` degrees across,
/// is at the middle.
fn hand(f: *const docklets.Frame, cx: i32, cy: i32, length: i32, degrees: i32, sweep: i32, colour: sdk.graphics.Pen) void {
    const tip = angles.pointAt(cx, cy, length, degrees);
    const back = @mod(degrees + 180 - @divTrunc(sweep, 2), 360);
    f.arc(tip[0], tip[1], length + 1, 0, back, back + sweep, colour);
}

fn draw(own: *Data, f: *const docklets.Frame) void {
    const p = f.pens;
    const middle = @divTrunc(f.size, 2);
    const radius = middle - 1;
    const rim = @max(1, @divTrunc(f.size, 16));
    f.disc(middle, middle, radius, p.shine);
    f.arc(middle, middle, radius, radius - rim, 0, 360, p.text);
    // A mark at each hour, the quarters larger.
    const marks_at = radius - rim - @max(1, @divTrunc(f.size, 12));
    for (0..12) |hour| {
        const at = angles.pointAt(middle, middle, marks_at, @as(i32, @intCast(hour)) * 30);
        const big = hour % 3 == 0;
        f.disc(at[0], at[1], if (big) @max(1, @divTrunc(f.size, 24)) else @max(1, @divTrunc(f.size, 48)), p.text);
    }
    if (own.minute < 0) return;
    const hours = @mod(own.minute, 12 * 60);
    const minutes = @mod(own.minute, 60);
    // Clockwise from twelve; graphics' degrees go the other way from
    // three.
    hand(f, middle, middle, @divTrunc(radius * 5, 10), 90 - @divTrunc(hours, 2), 20, p.text);
    hand(f, middle, middle, @divTrunc(radius * 8, 10), 90 - minutes * 6, 12, p.text);
    f.disc(middle, middle, @max(1, @divTrunc(f.size, 20)), p.fill);
}
