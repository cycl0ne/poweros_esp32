// SPDX-License-Identifier: MIT
//! cpu.docklet: how busy the machine's cores are.
//!
//! One bar per core, side by side, each its track's height in the track
//! pen and filled from the bottom in the fill pen as far as the core was
//! busy since the last look - in tasks and in interrupts together, from
//! exec's own counts (`ReadCoreTimes`), so they are exact rather than
//! sampled. It looks every second.
//!
//! How many cores the machine runs it asks the machine (`CoreCount`) and
//! keeps room for that many. A dock too narrow for a bar a core - a bar
//! thinner than three pixels is a line, not a reading - shows one bar for
//! the machine instead, filled to the average of its cores, which is the
//! figure the words lead with anyway.
//!
//! What it says: "CPU 23%", and each core's after it for as many as the
//! words hold: "CPU 23%: 12% 34%". A click on it runs
//! SYS:System/CPULoad.

const sdk = @import("sdk");
const exec = sdk.exec;
const docklets = sdk.docklets;

/// How wide a bar is at the narrowest, in pixels: under this they are
/// lines beside one another rather than something to read, and the
/// machine's average takes their place.
const narrowest_bar = 3;

/// What is kept for one core: its counts at the last look, and how busy
/// it was since the one before, in percent.
const Core = struct {
    times: exec.CoreTimes = .{},
    busy: u32 = 0,
};

pub const Data = struct {
    /// Room for a core each, allocated when the docklet is made, and the
    /// block it is in.
    cores: []Core = &.{},
    room: ?*anyopaque = null,
    /// How many of them answered at the last look.
    read_cores: u32 = 0,
    /// The cores' average, which is what one bar shows and what the
    /// words lead with.
    average: u32 = 0,
    read: bool = false,
    text: [64]u8 = @splat(0),
};

const Class = docklets.DockletClass(Data, .{
    .name = docklets.CPU_CLASS,
    .version = 1,
    .revision = 1,
    .date = "06.11.2026",
    .title = "CPU",
    .command = "SYS:System/CPULoad",
    .begin = begin,
    .end = end,
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

/// Room for a core each: how many the machine runs is the machine's to
/// say, so nothing here holds a number for it.
fn begin(base: *sdk.gadgets.Base, own: *Data) bool {
    const sys = base.sys_base;
    const count: usize = sys.CoreCount();
    const room = sys.AllocVec(count * @sizeOf(Core), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    const held: [*]Core = @ptrCast(@alignCast(room));
    own.room = room;
    own.cores = held[0..count];
    for (own.cores) |*core| core.* = .{};
    return true;
}

fn end(base: *sdk.gadgets.Base, own: *Data) void {
    if (own.room) |room| base.sys_base.FreeVec(room);
    own.room = null;
    own.cores = &.{};
}

fn look(base: *sdk.gadgets.Base, own: *Data) bool {
    const sys = base.sys_base;
    var read: u32 = 0;
    var changed = !own.read;
    while (read < own.cores.len) : (read += 1) {
        const core = &own.cores[read];
        var now: exec.CoreTimes = .{};
        if (!sys.ReadCoreTimes(read, &now)) break;
        const busy = if (own.read) busyBetween(core.times, now) else 0;
        if (busy != core.busy) changed = true;
        core.busy = busy;
        core.times = now;
    }
    own.read = true;
    if (read != own.read_cores) changed = true;
    own.read_cores = read;
    if (!changed) return false;

    var total: u32 = 0;
    for (own.cores[0..read]) |core| total += core.busy;
    own.average = if (read > 0) (total + read / 2) / read else 0;
    var n = sliceLen(docklets.format(sys, &own.text, "CPU %u%%", .{own.average}));
    if (read > 1) {
        docklets.say(own.text[n..], ":");
        n += 1;
        for (own.cores[0..read]) |core| {
            if (n + 6 >= own.text.len) break;
            n += sliceLen(docklets.format(sys, own.text[n..], " %u%%", .{core.busy}));
        }
    }
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
    const left = f.part(12, 100);
    const right = f.part(88, 100);
    const top = f.part(14, 100);
    const bottom = f.part(86, 100);
    const gap = @max(1, f.part(4, 100));
    // A bar each while each of them is wide enough to read; otherwise
    // one bar for the machine.
    const have: i32 = @intCast(@max(own.read_cores, 1));
    const narrow = @divTrunc(right - left - gap * (have - 1), have) < narrowest_bar;
    const bars: i32 = if (narrow) 1 else have;
    const each = @divTrunc(right - left - gap * (bars - 1), bars);
    const round = @min(@divTrunc(each, 3), f.part(1, 16));
    for (0..@intCast(bars)) |k| {
        const x0 = left + @as(i32, @intCast(k)) * (each + gap);
        f.roundBox(x0, top, x0 + each, bottom, round, p.track);
        const busy: i32 = @intCast(if (narrow) own.average else if (k < own.read_cores) own.cores[k].busy else 0);
        const height = @divTrunc((bottom - top) * busy + 50, 100);
        if (height > 0) f.roundBox(x0, bottom - height, x0 + each, bottom, @min(round, @divTrunc(height, 2)), p.fill);
    }
}
