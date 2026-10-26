// SPDX-License-Identifier: MIT
//! NetLoad: what goes through each network interface, now and over the
//! last minutes, in a window. Built against the SDK only.
//!
//!   NetLoad INTERFACE/K,INTERVAL/K/N,HISTORY/K/N
//!
//! INTERFACE is the one shown first - the first besides lo0 unless given,
//! and one not there yet is shown once it comes; INTERVAL how often it
//! looks, in seconds (1); HISTORY how many looks the chart keeps (120, two
//! minutes at a second).
//!
//! A chooser at the top lists the interfaces as the stack has them, and
//! follows them while it runs: one brought up - an adapter plugged in,
//! AddNetInterface - joins the list, one removed leaves it. A line under
//! it says what the one shown is: its address, its link's speed, its
//! device. Two bars show what it received and what it sent over the last
//! interval, the rate written over each, filled to the link's speed or to
//! the most the chart holds, whichever is more - a device may say no
//! speed (lo0, a line), or less than it carries - with the packets a
//! second and the total under each. The chart
//! has both rates over the last minutes, in the unit the most of them
//! needs (B/s, kB/s, MB/s), and is drawn again in another when that
//! changes.
//!
//! The figures are the stack's own counts (QueryInterfaceTagList's
//! IFQ_BytesReceived, IFQ_BytesSent and the packet counts), kept alike for
//! every kind of device and read at every interval; what changed in
//! between, over the time timer.device's E-clock says went by, is the
//! rate. Every interface is followed, not only the one shown, so the one
//! picked has its past on the chart at once.
//!
//! The close gadget or Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const motion = sdk.motion;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const MotionBase = sdk.interface.motion.MotionBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TimerBase = timer.TimerBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const fg = sdk.gadgets.fuelgauge;
const tx = sdk.gadgets.text;
const cr = sdk.gadgets.chart;
const ch = sdk.gadgets.chooser;

pub const COMMAND_NAME = "NetLoad";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (26.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while one of its windows is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "INTERFACE/K,INTERVAL/K/N,HISTORY/K/N";
const arg_interface = 0;
const arg_interval = 1;
const arg_history = 2;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_OLDSOCKET = "%s: needs bsdsocket.library 1.14, which counts bytes\n";
const MSG_NOMEMORY = "%s: no memory\n";
const MSG_NOWINDOW = "%s: no window\n";

/// The bsdsocket.library revision that counts each interface's bytes.
const socket_revision = 14;

/// The most interfaces followed at once.
const links_max = 8;

/// The two ways, as the rates and the chart's series hold them.
const received = 0;
const sent = 1;
/// The chart's lines: received blue, sent orange.
const colours = [2]u32{ 0xFF3070C0, 0xFFD07A1E };
const titles = [2][*:0]const u8{ "Received", "Sent" };

/// The bars run from 0 to this, a thousandth of the scale a step.
const gauge_steps = 1000;
/// How many lines go across the chart.
const chart_lines = 4;

const ID_INTERFACE = 1;

fn pair(t: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

/// A line of text put together piece by piece, cut short rather than
/// overrun: what a gadget shows, which keeps pointing at it.
const Line = struct {
    text: [96:0]u8 = @splat(0),
    length: usize = 0,

    fn clear(line: *Line) void {
        @memset(&line.text, 0);
        line.length = 0;
    }

    /// `text` as it is, at the end.
    fn put(line: *Line, text: []const u8) void {
        for (text) |char| putChar(char, line);
    }

    /// `format` with `args`, at the end.
    fn add(line: *Line, sys: *ExecBase, comptime format: [:0]const u8, args: anytype) void {
        comptime exec.checkFormat(format, @TypeOf(args));
        const stream = exec.fmtStream(args);
        _ = sys.RawDoFmt(format, &stream, &putChar, line);
    }

    fn putChar(char: u8, data: ?*anyopaque) callconv(.c) void {
        const line: *Line = @ptrCast(@alignCast(data.?));
        if (char == 0 or line.length >= line.text.len) return;
        line.text[line.length] = char;
        line.length += 1;
    }

    /// `value` - bytes, or with `per` "/s" bytes a second - in the
    /// largest unit it makes one of, with a tenth below a hundred.
    fn addAmount(line: *Line, sys: *ExecBase, value: u64, per: [*:0]const u8) void {
        var unit = amount_units[0];
        for (amount_units) |candidate| {
            if (value >= candidate.size) unit = candidate;
        }
        const whole = value / unit.size;
        if (unit.size == 1 or whole >= 100) {
            line.add(sys, "%ld %s%s", .{ whole, unit.name, per });
        } else {
            line.add(sys, "%ld.%ld %s%s", .{ whole, value % unit.size * 10 / unit.size, unit.name, per });
        }
    }
};

const Unit = struct { size: u64, name: [*:0]const u8 };
const amount_units = [_]Unit{
    .{ .size = 1, .name = "B" },
    .{ .size = 1000, .name = "kB" },
    .{ .size = 1_000_000, .name = "MB" },
    .{ .size = 1_000_000_000, .name = "GB" },
    .{ .size = 1_000_000_000_000, .name = "TB" },
};

/// The chart's units, a second, and below how many bytes a second each
/// is the one used: its numbers stay within four digits.
const chart_units = [_]struct { size: u64, below: u64, name: [*:0]const u8 }{
    .{ .size = 1, .below = 10_000, .name = "B/s" },
    .{ .size = 1000, .below = 10_000_000, .name = "kB/s" },
    .{ .size = 1_000_000, .below = ~@as(u64, 0), .name = "MB/s" },
};

/// One interface followed: its name, its last reading, and the rates of
/// the looks before.
const Link = struct {
    used: bool = false,
    /// In the stack's list at the last look.
    listed: bool = false,
    /// Whether `bytes` and `packets` hold a reading yet.
    read: bool = false,
    /// A rate was added at the last look.
    added: bool = false,
    name: [bsd.IFNAMSIZ:0]u8 = @splat(0),
    /// The counts at the last look, received and sent.
    bytes: [2]u64 = @splat(0),
    packets: [2]u64 = @splat(0),
    /// Over the last interval, a second.
    rate: [2]u64 = @splat(0),
    packet_rate: [2]u64 = @splat(0),
    /// The link's speed in bits a second, 0 when the device does not say.
    speed: u64 = 0,
    /// The rates of the looks before, in bytes a second, received and
    /// sent: `count` of them from `start`, oldest first.
    rings: [2][]u32 = .{ &.{}, &.{} },
    start: usize = 0,
    count: usize = 0,

    fn named(link: *const Link, name: [*:0]const u8) bool {
        var index: usize = 0;
        while (index < link.name.len and link.name[index] == name[index] and name[index] != 0) index += 1;
        return index < link.name.len and link.name[index] == name[index];
    }

    /// The link made the one called `name`, from nothing.
    fn begin(link: *Link, name: [*:0]const u8) void {
        const rings = link.rings;
        link.* = .{ .used = true, .rings = rings };
        var index: usize = 0;
        while (index < link.name.len and name[index] != 0) : (index += 1) link.name[index] = name[index];
    }

    /// The `index`th rate held, counted from the oldest.
    fn held(link: *const Link, direction: usize, index: usize) u32 {
        const ring = link.rings[direction];
        return ring[(link.start + index) % ring.len];
    }

    fn push(link: *Link, rates: [2]u64) void {
        const capacity = link.rings[received].len;
        var slot: usize = undefined;
        if (link.count < capacity) {
            slot = (link.start + link.count) % capacity;
            link.count += 1;
        } else {
            slot = link.start;
            link.start = (link.start + 1) % capacity;
        }
        for (link.rings, rates) |ring, rate| ring[slot] = @intCast(@min(rate, 0xFFFF_FFFF));
    }

    /// The most either way reached in what is held.
    fn peak(link: *const Link) u64 {
        var most: u64 = 0;
        for (0..link.count) |index| {
            most = @max(most, link.held(received, index), link.held(sent, index));
        }
        return most;
    }
};

/// Everything the window shows, and what it is worked out from.
const App = struct {
    sys: *ExecBase,
    ib: *IntuitionBase,
    sb: *SocketBase,
    clock: ?*TimerBase,
    interval: u32,
    window: ?*intuition.Window = null,
    chooser: ?*Object = null,
    info: ?*Object = null,
    gauges: [2]?*Object = .{ null, null },
    figures: [2]?*Object = .{ null, null },
    plot: ?*Object = null,
    legend: ?*Object = null,
    links: [links_max]Link = @splat(.{}),
    /// The chooser's labels, the links' names in the stack's order, and
    /// the link each is.
    labels: [links_max:null]?[*:0]const u8 = @splat(null),
    order: [links_max]usize = @splat(0),
    listed: usize = 0,
    /// The link shown.
    shown: usize = 0,
    /// The interface asked for, until it has been shown.
    wanted: [bsd.IFNAMSIZ:0]u8 = @splat(0),
    /// The chart's unit, from `chart_units`, and its top.
    unit: usize = 0,
    top: u32 = chart_lines,
    /// The E-clock at the last look.
    ticks: u64 = 0,
    info_text: Line = .{},
    gauge_text: [2]Line = .{ .{}, .{} },
    figure_text: [2]Line = .{ .{}, .{} },
    legend_text: Line = .{},
    chart_title: Line = .{},

    /// The interfaces read again: true when the list changed.
    fn readList(app: *App) bool {
        const list = app.sb.ObtainInterfaceList() orelse return false;
        defer app.sb.ReleaseInterfaceList(list);
        for (&app.links) |*link| link.listed = false;
        var order: [links_max]usize = undefined;
        var count: usize = 0;
        var it = list.iterator();
        while (it.next()) |node| {
            const name = node.name orelse continue;
            const index = app.find(name) orelse app.free() orelse continue;
            const link = &app.links[index];
            if (!link.used) link.begin(name);
            link.listed = true;
            order[count] = index;
            count += 1;
        }
        for (&app.links) |*link| {
            if (!link.used or link.listed) continue;
            const rings = link.rings;
            link.* = .{ .rings = rings };
        }
        var changed = count != app.listed;
        for (order[0..count], app.order[0..count]) |now, before| {
            if (now != before) changed = true;
        }
        if (!changed) return false;
        app.listed = count;
        for (order[0..count], app.order[0..count], app.labels[0..count]) |index, *kept, *label| {
            kept.* = index;
            label.* = &app.links[index].name;
        }
        for (app.labels[count..]) |*label| label.* = null;
        return true;
    }

    fn find(app: *App, name: [*:0]const u8) ?usize {
        for (&app.links, 0..) |*link, index| {
            if (link.used and link.named(name)) return index;
        }
        return null;
    }

    fn free(app: *App) ?usize {
        for (&app.links, 0..) |*link, index| {
            if (!link.used) return index;
        }
        return null;
    }

    /// The link to show: the one asked for once it is there; else, at the
    /// start or when the one shown has gone (`keep` false, or nothing to
    /// keep), the first that is not a loopback, or the first.
    fn pickShown(app: *App, keep: bool) void {
        if (app.wanted[0] != 0) {
            if (app.find(&app.wanted)) |index| {
                app.shown = index;
                app.wanted[0] = 0;
                return;
            }
        }
        if (keep and app.links[app.shown].used) return;
        for (app.order[0..app.listed]) |index| {
            var state: u32 = 0;
            const tags = [_]TagItem{ pair(bsd.IFQ_State, @intFromPtr(&state)), .{} };
            if (app.sb.QueryInterfaceTagList(&app.links[index].name, &tags) == 0 and state & bsd.IFSTATE_LOOPBACK == 0) {
                app.shown = index;
                return;
            }
        }
        app.shown = if (app.listed > 0) app.order[0] else 0;
    }

    /// Microseconds since the last look, by the E-clock; the interval
    /// when there is no clock.
    fn elapsed(app: *App) u64 {
        const nominal = @as(u64, app.interval) * 1_000_000;
        const clock = app.clock orelse return nominal;
        var value: timer.EClockVal = .{};
        const hertz = clock.ReadEClock(&value);
        const now = value.toTicks();
        defer app.ticks = now;
        if (app.ticks == 0 or hertz == 0 or now <= app.ticks) return nominal;
        return @max((now - app.ticks) * 1_000_000 / hertz, 1);
    }

    /// Every link's counts read, and the rates since the last look added
    /// to its ring.
    fn sample(app: *App, micros: u64) void {
        for (&app.links) |*link| {
            link.added = false;
            if (!link.used) continue;
            var bytes: [2]u64 = @splat(0);
            var packets: [2]u64 = @splat(0);
            var speed: u64 = 0;
            const tags = [_]TagItem{
                pair(bsd.IFQ_BytesReceived, @intFromPtr(&bytes[received])),
                pair(bsd.IFQ_BytesSent, @intFromPtr(&bytes[sent])),
                pair(bsd.IFQ_PacketsReceived, @intFromPtr(&packets[received])),
                pair(bsd.IFQ_PacketsSent, @intFromPtr(&packets[sent])),
                pair(bsd.IFQ_Speed, @intFromPtr(&speed)),
                .{},
            };
            // Gone since the list was read: the next look drops it.
            if (app.sb.QueryInterfaceTagList(&link.name, &tags) != 0) continue;
            link.speed = speed;
            if (link.read) {
                for (0..2) |direction| {
                    // Counts that went back belong to an interface made
                    // again under the same name: nothing went between.
                    const moved = if (bytes[direction] >= link.bytes[direction]) bytes[direction] - link.bytes[direction] else 0;
                    const counted = if (packets[direction] >= link.packets[direction]) packets[direction] - link.packets[direction] else 0;
                    link.rate[direction] = moved * 1_000_000 / micros;
                    link.packet_rate[direction] = (counted * 1_000_000 + micros / 2) / micros;
                }
                link.push(link.rate);
                link.added = true;
            }
            link.bytes = bytes;
            link.packets = packets;
            link.read = true;
        }
    }

    /// One look: the list, the counts, and the window brought up to
    /// them.
    fn look(app: *App) void {
        const changed = app.readList();
        app.sample(app.elapsed());
        if (!changed) return app.show(false);
        const before = app.shown;
        app.pickShown(true);
        _ = app.ib.SetGadgetAttrsTagList(app.chooser.?, app.window, &[_]TagItem{
            pair(ch.CHOOSER_Labels, @intFromPtr(&app.labels)),
            pair(ch.CHOOSER_Active, app.position()),
            .{},
        });
        app.show(app.shown != before);
    }

    /// Where the link shown is in the chooser.
    fn position(app: *const App) usize {
        for (app.order[0..app.listed], 0..) |index, place| {
            if (index == app.shown) return place;
        }
        return 0;
    }

    /// The `place`th interface in the chooser picked.
    fn pick(app: *App, place: usize) void {
        if (place >= app.listed or app.order[place] == app.shown) return;
        app.shown = app.order[place];
        app.wanted[0] = 0;
        app.show(true);
    }

    /// The link shown, in every gadget; `again` draws its chart anew.
    fn show(app: *App, again: bool) void {
        const sys = app.sys;
        const ib = app.ib;
        const window = app.window;
        const link = &app.links[app.shown];
        app.describe(link);
        _ = ib.SetGadgetAttrsTagList(app.info.?, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&app.info_text.text)), .{} });

        // The bars: the link's speed, in bytes, or the most held if that
        // is more.
        const scale = @max(link.speed / 8, link.peak(), 1);
        for (0..2) |direction| {
            const rate = if (link.read) link.rate[direction] else 0;
            const gauge = &app.gauge_text[direction];
            gauge.clear();
            gauge.addAmount(sys, rate, "/s");
            const figures = &app.figure_text[direction];
            figures.clear();
            figures.add(sys, "%ld packets/s, ", .{link.packet_rate[direction]});
            figures.addAmount(sys, link.bytes[direction], "");
            figures.put(" in all");
            _ = ib.SetGadgetAttrsTagList(app.gauges[direction].?, window, &[_]TagItem{
                pair(fg.GAUGE_Format, @intFromPtr(&gauge.text)),
                pair(fg.GAUGE_Level, @intCast(@min(rate * gauge_steps / scale, gauge_steps))),
                .{},
            });
            _ = ib.SetGadgetAttrsTagList(app.figures[direction].?, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&figures.text)), .{} });
        }

        // The chart: in the unit the most held needs, up to a round top.
        const peak = link.peak();
        var unit: usize = 0;
        while (peak >= chart_units[unit].below) unit += 1;
        const size = chart_units[unit].size;
        const top = roundTop((peak + size - 1) / size);
        if (again or unit != app.unit) {
            app.unit = unit;
            app.top = top;
            app.fill(link);
            app.legend_text.clear();
            app.legend_text.add(sys, "In %s: received blue, sent orange", .{chart_units[unit].name});
            _ = ib.SetGadgetAttrsTagList(app.legend.?, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&app.legend_text.text)), .{} });
            return;
        }
        app.top = top;
        if (!link.added) return;
        const last = link.count - 1;
        _ = ib.SetGadgetAttrsTagList(app.plot.?, window, &[_]TagItem{
            pair(cr.CHART_Current, received),
            pair(cr.CHART_Add, @intCast(link.held(received, last) / size)),
            pair(cr.CHART_Current, sent),
            pair(cr.CHART_Add, @intCast(link.held(sent, last) / size)),
            pair(cr.CHART_Max, top),
            .{},
        });
    }

    /// The chart emptied and given the link's rates held, a handful at a
    /// time without drawing, then drawn once.
    fn fill(app: *App, link: *const Link) void {
        const ib = app.ib;
        const plot = app.plot.?;
        const size = chart_units[app.unit].size;
        _ = ib.SetAttrsTagList(plot, &[_]TagItem{
            pair(cr.CHART_Current, received),
            pair(cr.CHART_Clear, 1),
            pair(cr.CHART_Current, sent),
            pair(cr.CHART_Clear, 1),
            .{},
        });
        const per_list = 16;
        var tags: [4 * per_list + 1]TagItem = undefined;
        var index: usize = 0;
        while (index < link.count) {
            var used: usize = 0;
            while (index < link.count and used < tags.len - 1) : (index += 1) {
                tags[used] = pair(cr.CHART_Current, received);
                tags[used + 1] = pair(cr.CHART_Add, @intCast(link.held(received, index) / size));
                tags[used + 2] = pair(cr.CHART_Current, sent);
                tags[used + 3] = pair(cr.CHART_Add, @intCast(link.held(sent, index) / size));
                used += 4;
            }
            tags[used] = .{};
            _ = ib.SetAttrsTagList(plot, &tags);
        }
        _ = ib.SetGadgetAttrsTagList(plot, app.window, &[_]TagItem{ pair(cr.CHART_Min, 0), pair(cr.CHART_Max, app.top), .{} });
    }

    /// The line under the chooser: the link's address, speed and device.
    fn describe(app: *App, link: *const Link) void {
        const sys = app.sys;
        const line = &app.info_text;
        line.clear();
        var address: u32 = 0;
        var state: u32 = 0;
        var unit: u32 = 0;
        var device: ?[*:0]const u8 = null;
        const tags = [_]TagItem{
            pair(bsd.IFQ_Address, @intFromPtr(&address)),
            pair(bsd.IFQ_State, @intFromPtr(&state)),
            pair(bsd.IFQ_DeviceUnit, @intFromPtr(&unit)),
            pair(bsd.IFQ_DeviceName, @intFromPtr(&device)),
            .{},
        };
        if (!link.used or app.sb.QueryInterfaceTagList(&link.name, &tags) != 0) {
            line.put("gone");
            return;
        }
        if (state & bsd.IFSTATE_UP == 0) {
            line.put("down");
        } else if (address == 0) {
            line.put("no address yet");
        } else {
            line.add(sys, "%s", .{app.sb.Inet_NtoA(address)});
        }
        if (link.speed >= 1_000_000) {
            line.add(sys, ", %ld Mbit/s", .{link.speed / 1_000_000});
        } else if (link.speed > 0) {
            line.add(sys, ", %ld bit/s", .{link.speed});
        }
        if (state & bsd.IFSTATE_LOOPBACK != 0) {
            line.put(", loopback");
        } else if (device) |name| {
            line.add(sys, ", %s unit %u", .{ name, unit });
        }
    }
};

/// The chart's top for a most of `most`: `chart_lines` steps of 1, 2 or
/// 5 times a power of ten, so each line across has a round number.
fn roundTop(most: u64) u32 {
    const raw = @max((most + chart_lines - 1) / chart_lines, 1);
    var power: u64 = 1;
    while (power * 10 <= raw) power *= 10;
    var step = power * 10;
    for ([_]u64{ 1, 2, 5 }) |times| {
        if (power * times >= raw) {
            step = power * times;
            break;
        }
    }
    return @intCast(@min(step * chart_lines, 0x7FFF_FFFF));
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const interval: u32 = @intCast(@max(rdargs.number(argv[arg_interval]) orelse 1, 1));
    const history: u32 = @intCast(@min(@max(rdargs.number(argv[arg_history]) orelse 120, 2), 1024));

    var libraries: [7]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{ intuition.INTUITIONNAME, motion.MOTIONNAME, fg.GAUGE_LIBRARY, tx.TEXT_LIBRARY, cr.CHART_LIBRARY, ch.CHOOSER_LIBRARY, bsd.SOCKETNAME };
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const motion_base: *MotionBase = @ptrCast(libraries[1].?);
    const socket_lib = libraries[6].?;
    if (socket_lib.version == 1 and socket_lib.revision < socket_revision) {
        _ = Printf(dl, MSG_OLDSOCKET, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }

    // The E-clock, for the time between looks: never sent, only read.
    var timer_req: timer.TimeRequest = .{};
    const timer_open = sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) == 0;
    defer if (timer_open) sys.CloseDevice(&timer_req.node);

    // The app, and after it every link's two rings.
    const ring_bytes = links_max * 2 * @as(usize, history) * @sizeOf(u32);
    const memory = sys.AllocVec(@sizeOf(App) + ring_bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const app: *App = @ptrCast(@alignCast(memory));
    app.* = .{
        .sys = sys,
        .ib = ib,
        .sb = @ptrCast(socket_lib),
        .clock = if (timer_open) @ptrCast(timer_req.node.device.?) else null,
        .interval = interval,
    };
    const rings: [*]u32 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(memory)) + @sizeOf(App)));
    for (&app.links, 0..) |*link, index| {
        for (&link.rings, 0..) |*ring, direction| ring.* = rings[(2 * index + direction) * history ..][0..history];
    }
    if (rdargs.string(argv[arg_interface])) |name| {
        var index: usize = 0;
        while (index < app.wanted.len and name[index] != 0) : (index += 1) app.wanted[index] = name[index];
    }
    _ = app.readList();
    app.sample(app.elapsed());
    app.pickShown(false);

    // The gadgets: the chooser and the line under it, a bar and its
    // figures each way, the chart and its legend. The chooser is as wide
    // as its labels at the start, at the least room for a name the stack
    // gives one later.
    app.chooser = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_INTERFACE),
        pair(gc.GA_Width, 120),
        pair(ch.CHOOSER_Labels, @intFromPtr(&app.labels)),
        pair(ch.CHOOSER_Active, app.position()),
        .{},
    });
    app.info = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&app.info_text.text)), pair(gc.GA_Width, 460), .{} });
    var made_all = app.chooser != null and app.info != null;
    for (0..2) |direction| {
        app.gauges[direction] = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
            pair(fg.GAUGE_Max, gauge_steps),
            pair(fg.GAUGE_Format, @intFromPtr(&app.gauge_text[direction].text)),
            pair(gc.GA_Width, 220),
            .{},
        });
        app.figures[direction] = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            pair(tx.TEXT_Text, @intFromPtr(&app.figure_text[direction].text)),
            pair(gc.GA_Width, 220),
            .{},
        });
        if (app.gauges[direction] == null or app.figures[direction] == null) made_all = false;
    }
    app.plot = ib.NewObjectTagList(null, cr.CHART_CLASS, &[_]TagItem{
        pair(cr.CHART_Series, 2),
        pair(cr.CHART_Capacity, history),
        pair(cr.CHART_Min, 0),
        pair(cr.CHART_Max, chart_lines),
        pair(cr.CHART_Lines, chart_lines),
        pair(cr.CHART_Current, received),
        pair(cr.CHART_ColourRGB, colours[received]),
        pair(cr.CHART_Current, sent),
        pair(cr.CHART_ColourRGB, colours[sent]),
        pair(gc.GA_Width, 460),
        pair(gc.GA_Height, 140),
        .{},
    });
    app.legend = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&app.legend_text.text)), pair(gc.GA_Width, 460), .{} });
    if (app.plot == null or app.legend == null) made_all = false;
    if (!made_all) {
        for ([_]?*Object{ app.chooser, app.info, app.gauges[0], app.gauges[1], app.figures[0], app.figures[1], app.plot, app.legend }) |object| ib.DisposeObject(object);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }

    var groups: [2]?*Object = .{ null, null };
    for (&groups, 0..) |*group, direction| {
        group.* = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_FrameTitle, @intFromPtr(titles[direction])),
            pair(lg.LAYOUTA_Margin, 6),
            pair(lg.LAYOUTA_Spacing, 4),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.gauges[direction])),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.figures[direction])),
            pair(lg.CHILDA_WeightHeight, 0),
            .{},
        });
    }
    app.chart_title.add(sys, "Received and sent, last %u s", .{history * interval});
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.chooser)),
        pair(lg.CHILDA_Label, @intFromPtr("_Interface")),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.info)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
            pair(lg.LAYOUTA_Spacing, 6),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(groups[received])),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(groups[sent])),
            .{},
        }))),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
            pair(lg.LAYOUTA_FrameTitle, @intFromPtr(&app.chart_title.text)),
            pair(lg.LAYOUTA_Margin, 6),
            pair(lg.LAYOUTA_Spacing, 4),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.plot)),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.legend)),
            pair(lg.CHILDA_WeightHeight, 0),
            .{},
        }))),
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr("Network")),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    var window_pointer: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_pointer);
    const window: *intuition.Window = @ptrFromInt(window_pointer);
    app.window = window;
    app.show(true);

    // The clock: a look every interval.
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const tick = motion_base.CreateTimerTagList(&[_]TagItem{
        pair(motion.TIMER_Period, interval * 1000),
        pair(motion.TIMER_Repeat, motion.TIMER_FOREVER),
        pair(motion.TIMER_Signal, @intCast(bit)),
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer motion_base.DeleteTimer(tick);
    motion_base.StartTimer(tick);
    const tick_mask = @as(u32, 1) << @intCast(bit);

    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        const got = ib.WaitIMsg(window, tick_mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & tick_mask != 0) app.look();
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => if (word & wc.WMHI_GADGETMASK == ID_INTERFACE) app.pick(code_word),
                else => {},
            }
        }
    }
}
