// SPDX-License-Identifier: MIT
//! battery.docklet: the board's battery (battery.resource), as a battery
//! filled to its charge.
//!
//! The battery lies on its side, its outline in the text pen, filled from
//! the left as far as it is charged - in the fill pen, or the alarm's red
//! once it is low - with a bolt on it while it charges. A board that
//! measures no cell shows the outline empty and struck through. It looks
//! every five seconds, as often as the resource measures. What it says:
//! "Battery 80%, charging", "On external power, no battery", "No battery
//! measured". A click on it runs nothing.

const sdk = @import("sdk");
const battery = sdk.resources.battery;
const docklets = sdk.docklets;
const BatteryBase = battery.BatteryBase;

pub const Data = extern struct {
    /// The resource; null on a board without one.
    bb: ?*BatteryBase = null,
    state: battery.BatteryState = .{},
    measured: bool = false,
    /// Read once: what it shows is then something.
    read: bool = false,
    text: [48]u8 = @splat(0),
};

const Class = docklets.DockletClass(Data, .{
    .name = docklets.BATTERY_CLASS,
    .version = 1,
    .date = "27.10.2026",
    .title = "Battery",
    .every = 5000,
    .begin = begin,
    .look = look,
    .text = text,
    .draw = draw,
});
pub const Library = Class.Library;
comptime {
    _ = Library;
}

fn begin(base: *sdk.gadgets.Base, own: *Data) bool {
    // A resource is never closed: OpenResource only finds it.
    own.bb = @ptrCast(@alignCast(base.sys_base.OpenResource(battery.BATTERYNAME)));
    return true;
}

fn look(base: *sdk.gadgets.Base, own: *Data) bool {
    var state: battery.BatteryState = .{};
    const measured = if (own.bb) |bb| bb.ReadBattery(&state) else false;
    if (own.read and measured == own.measured and state.flags == own.state.flags and state.percent == own.state.percent) return false;
    own.read = true;
    own.measured = measured;
    own.state = state;
    const sys = base.sys_base;
    const charging = state.flags & battery.BATTF_CHARGING != 0;
    const external = state.flags & battery.BATTF_EXTERNAL != 0;
    if (measured and state.flags & battery.BATTF_PRESENT != 0) {
        const how: [*:0]const u8 = if (charging) ", charging" else if (external) ", on external power" else "";
        _ = docklets.format(sys, &own.text, "Battery %u%%%s", .{ state.percent, how });
    } else if (external) {
        docklets.say(&own.text, "On external power, no battery");
    } else {
        docklets.say(&own.text, "No battery measured");
    }
    return true;
}

fn text(own: *Data) [*:0]const u8 {
    return @ptrCast(&own.text);
}

fn draw(own: *Data, f: *const docklets.Frame) void {
    const p = f.pens;
    const line = @max(1, f.part(1, 24));
    const left = f.part(10, 100);
    const right = f.part(84, 100);
    const top = f.part(30, 100);
    const bottom = f.part(70, 100);
    const round = f.part(1, 12);
    // The knob at its plus end.
    f.roundBox(right, f.part(41, 100), right + f.part(7, 100), f.part(59, 100), @max(1, f.part(1, 48)), p.text);
    f.roundOutline(left, top, right, bottom, round, line, p.text);
    const present = own.measured and own.state.flags & battery.BATTF_PRESENT != 0;
    const in = line + @max(1, f.part(1, 32));
    if (!present) {
        f.line(left + in, bottom - in - 1, right - in - 1, top + in, p.text);
        return;
    }
    const room = right - left - 2 * in;
    const filled = @divTrunc(room * @as(i32, @intCast(@min(own.state.percent, 100))) + 50, 100);
    const low = own.state.flags & battery.BATTF_LOW != 0;
    f.roundBox(left + in, top + in, left + in + @max(filled, 1), bottom - in, @max(0, round - in), if (low) p.alarm else p.fill);
    if (own.state.flags & battery.BATTF_CHARGING == 0) return;
    // A bolt across the middle, in a grid of 12 by 20.
    const height = bottom - top - 2 * line;
    const bx = @divTrunc(left + right, 2) - @divTrunc(height * 6, 20);
    const by = top + line;
    const grid = [_][2]i32{ .{ 8, 0 }, .{ 0, 11 }, .{ 5, 11 }, .{ 3, 20 }, .{ 12, 8 }, .{ 7, 8 }, .{ 10, 0 } };
    var points: [grid.len][2]i32 = undefined;
    for (grid, &points) |g, *pt| pt.* = .{ bx + @divTrunc(g[0] * height, 20), by + @divTrunc(g[1] * height, 20) };
    f.polygon(&points, p.text);
}
