// SPDX-License-Identifier: MIT
//! cpu.docklet: how busy each core is, as a bar for each.
//!
//! The bars stand side by side, at most eight, each its track's height in
//! the track pen and filled from the bottom in the fill pen as far as the
//! core was busy since the last look - in tasks and in interrupts
//! together, from exec's own counts (`ReadCoreTimes`), so they are exact
//! rather than sampled. It looks every second. What it says: "CPU 23%",
//! or with more cores each one's after it: "CPU 23%: 12% 34%". A click on
//! it runs SYS:System/CPULoad.

const sdk = @import("sdk");
const exec = sdk.exec;
const docklets = sdk.docklets;

/// The most cores it shows.
const cores_max = 8;

pub const Data = struct {
    cores: u32 = 0,
    /// Each core's counts at the last look, and how busy it was since the
    /// one before, in percent.
    times: [cores_max]exec.CoreTimes = @splat(.{}),
    busy: [cores_max]u32 = @splat(0),
    read: bool = false,
    text: [64]u8 = @splat(0),
};

const Class = docklets.DockletClass(Data, .{
    .name = docklets.CPU_CLASS,
    .version = 1,
    .date = "27.10.2026",
    .title = "CPU",
    .command = "SYS:System/CPULoad",
    .look = look,
    .text = text,
    .draw = draw,
});
pub const Library = Class.Library;
comptime {
    _ = Library;
}

/// How busy a core was between two of its counts, in percent.
pub fn busyBetween(before: exec.CoreTimes, now: exec.CoreTimes) u32 {
    const work = (now.tasks -% before.tasks) +% (now.interrupts -% before.interrupts);
    const all = work +% (now.idle -% before.idle);
    if (all == 0 or work > all) return 0;
    return @intCast((work * 100 + all / 2) / all);
}

fn look(base: *sdk.gadgets.Base, own: *Data) bool {
    const sys = base.sys_base;
    var busy: [cores_max]u32 = @splat(0);
    var cores: u32 = 0;
    while (cores < cores_max) : (cores += 1) {
        var now: exec.CoreTimes = .{};
        if (!sys.ReadCoreTimes(cores, &now)) break;
        if (own.read) busy[cores] = busyBetween(own.times[cores], now);
        own.times[cores] = now;
    }
    const first = !own.read;
    own.read = true;
    if (!first and cores == own.cores and sameBusy(busy[0..cores], own.busy[0..cores])) return false;
    own.cores = cores;
    own.busy = busy;
    var total: u32 = 0;
    for (busy[0..cores]) |b| total += b;
    const average = if (cores > 0) (total + cores / 2) / cores else 0;
    var n = sliceLen(docklets.format(sys, &own.text, "CPU %u%%", .{average}));
    if (cores > 1) {
        docklets.say(own.text[n..], ":");
        n += 1;
        for (busy[0..cores]) |b| {
            if (n + 6 >= own.text.len) break;
            n += sliceLen(docklets.format(sys, own.text[n..], " %u%%", .{b}));
        }
    }
    return true;
}

fn sameBusy(a: []const u32, b: []const u32) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn sliceLen(written: [*:0]const u8) usize {
    var n: usize = 0;
    while (written[n] != 0) n += 1;
    return n;
}

fn text(own: *Data) [*:0]const u8 {
    return @ptrCast(&own.text);
}

fn draw(own: *Data, f: *const docklets.Frame) void {
    const p = f.pens;
    const cores: i32 = @intCast(@max(own.cores, 1));
    const left = f.part(12, 100);
    const right = f.part(88, 100);
    const top = f.part(14, 100);
    const bottom = f.part(86, 100);
    const gap = @max(1, f.part(4, 100));
    const each = @divTrunc(right - left - gap * (cores - 1), cores);
    const round = @min(@divTrunc(each, 3), f.part(1, 16));
    for (0..@intCast(cores)) |k| {
        const x0 = left + @as(i32, @intCast(k)) * (each + gap);
        f.roundBox(x0, top, x0 + each, bottom, round, p.track);
        const busy: i32 = @intCast(if (k < own.cores) own.busy[k] else 0);
        const height = @divTrunc((bottom - top) * busy + 50, 100);
        if (height > 0) f.roundBox(x0, bottom - height, x0 + each, bottom, @min(round, @divTrunc(height, 2)), p.fill);
    }
}
