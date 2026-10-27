// SPDX-License-Identifier: MIT
//! network.docklet: the network (bsdsocket.library), as an arrow down for
//! what comes in and one up for what goes out.
//!
//! The interface it follows is the first that is up and has an address,
//! else the first that is not the loopback - as NetLoad picks one. While
//! it is up the arrows are in the text pen, and one that carried
//! something since the last look in the fill pen; while it is down they
//! are in the track's, and with no network at all they are struck
//! through. It looks every second. What it says: "Network 192.168.1.20:
//! 1.2 kB/s in, 310 B/s out", "Network: wlan0 down", "No network". A
//! click on it runs SYS:System/NetLoad.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const docklets = sdk.docklets;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TagItem = utility.TagItem;

const received = 0;
const sent = 1;

pub const Data = struct {
    /// The library, opened for this object's task; null without it.
    sb: ?*SocketBase = null,
    /// The interface followed; empty for none.
    name: [bsd.IFNAMSIZ:0]u8 = @splat(0),
    up: bool = false,
    address: u32 = 0,
    /// Its counts at the last look, the dos ticks then, and the bytes a
    /// second in and out since the one before.
    bytes: [2]u64 = .{ 0, 0 },
    ticks: i64 = 0,
    counted: bool = false,
    rates: [2]u64 = .{ 0, 0 },
    read: bool = false,
    text: [80]u8 = @splat(0),
};

const Class = docklets.DockletClass(Data, .{
    .name = docklets.NETWORK_CLASS,
    .version = 1,
    .date = "27.10.2026",
    .title = "Network",
    .command = "SYS:System/NetLoad",
    .opens = &.{"dos.library"},
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

fn pair(t: utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

fn begin(base: *sdk.gadgets.Base, own: *Data) bool {
    own.sb = @ptrCast(base.sys_base.OpenLibrary(bsd.SOCKETNAME, 0));
    return true;
}

fn end(base: *sdk.gadgets.Base, own: *Data) void {
    if (own.sb) |sb| base.sys_base.CloseLibrary(sb.lib());
    own.sb = null;
}

/// The interface to follow, into `into`: the first that is up with an
/// address, else the first that is not the loopback. False for none.
fn pick(sb: *SocketBase, into: *[bsd.IFNAMSIZ:0]u8) bool {
    const list = sb.ObtainInterfaceList() orelse return false;
    defer sb.ReleaseInterfaceList(list);
    var found = false;
    var it = list.iterator();
    while (it.next()) |node| {
        const name = node.name orelse continue;
        var state: u32 = 0;
        var address: u32 = 0;
        const tags = [_]TagItem{ pair(bsd.IFQ_State, @intFromPtr(&state)), pair(bsd.IFQ_Address, @intFromPtr(&address)), .{} };
        if (sb.QueryInterfaceTagList(name, &tags) != 0 or state & bsd.IFSTATE_LOOPBACK != 0) continue;
        const best = state & bsd.IFSTATE_UP != 0 and address != 0;
        if (found and !best) continue;
        var n: usize = 0;
        while (n < into.len and name[n] != 0) : (n += 1) into[n] = name[n];
        into[n] = 0;
        found = true;
        if (best) break;
    }
    return found;
}

/// Bytes a second, in the largest unit that makes one of it, with a tenth
/// below ten.
fn amount(sys: *sdk.interface.exec.ExecBase, into: []u8, rate: u64) [*:0]const u8 {
    if (rate < 1000) return docklets.format(sys, into, "%lu B/s", .{rate});
    const unit: u64 = if (rate < 1_000_000) 1000 else 1_000_000;
    const name: [*:0]const u8 = if (unit == 1000) "kB/s" else "MB/s";
    const tenths = rate * 10 / unit;
    if (tenths < 100) return docklets.format(sys, into, "%lu.%lu %s", .{ tenths / 10, tenths % 10, name });
    return docklets.format(sys, into, "%lu %s", .{ tenths / 10, name });
}

fn look(base: *sdk.gadgets.Base, own: *Data) bool {
    const sys = base.sys_base;
    const before = own.*;
    own.read = true;
    const sb = own.sb orelse {
        own.name[0] = 0;
        docklets.say(&own.text, "No network");
        return !before.read;
    };
    var name: [bsd.IFNAMSIZ:0]u8 = @splat(0);
    if (!pick(sb, &name)) {
        own.name[0] = 0;
        own.counted = false;
        docklets.say(&own.text, "No network");
        return !before.read or before.name[0] != 0;
    }
    var state: u32 = 0;
    var bytes: [2]u64 = .{ 0, 0 };
    const tags = [_]TagItem{
        pair(bsd.IFQ_State, @intFromPtr(&state)),
        pair(bsd.IFQ_Address, @intFromPtr(&own.address)),
        pair(bsd.IFQ_BytesReceived, @intFromPtr(&bytes[received])),
        pair(bsd.IFQ_BytesSent, @intFromPtr(&bytes[sent])),
        .{},
    };
    if (sb.QueryInterfaceTagList(&name, &tags) != 0) state = 0;
    own.up = state & bsd.IFSTATE_UP != 0;
    // The time since the last look, by dos's fiftieths of a second.
    const dl: *DosBase = @ptrCast(base.opened[0].?);
    var stamp: dos.DateStamp = .{};
    _ = dl.DateStamp(&stamp);
    const ticks = (@as(i64, stamp.days) * 24 * 60 + stamp.minute) * 60 * 50 + stamp.tick;
    const same = own.counted and sameName(&name, &own.name);
    own.rates = .{ 0, 0 };
    if (same and ticks > own.ticks) {
        for (0..2) |d| {
            // Counts that went back belong to an interface made again.
            const moved = if (bytes[d] >= own.bytes[d]) bytes[d] - own.bytes[d] else 0;
            own.rates[d] = moved * 50 / @as(u64, @intCast(ticks - own.ticks));
        }
    }
    own.name = name;
    own.bytes = bytes;
    own.ticks = ticks;
    own.counted = true;
    if (!own.up) {
        _ = docklets.format(sys, &own.text, "Network: %s down", .{@as([*:0]const u8, &own.name)});
    } else if (own.address == 0) {
        _ = docklets.format(sys, &own.text, "Network: %s, no address yet", .{@as([*:0]const u8, &own.name)});
    } else {
        var in: [16]u8 = undefined;
        var out: [16]u8 = undefined;
        _ = docklets.format(sys, &own.text, "Network %s: %s in, %s out", .{
            sb.Inet_NtoA(own.address),
            amount(sys, &in, own.rates[received]),
            amount(sys, &out, own.rates[sent]),
        });
    }
    if (!before.read or before.up != own.up or before.address != own.address or !sameName(&before.name, &own.name)) return true;
    for (0..2) |d| if ((before.rates[d] != 0) != (own.rates[d] != 0)) return true;
    return !sameText(&before.text, &own.text);
}

fn sameName(a: *const [bsd.IFNAMSIZ:0]u8, b: *const [bsd.IFNAMSIZ:0]u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
        if (x == 0) return true;
    }
    return true;
}

fn sameText(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
        if (x == 0) return true;
    }
    return true;
}

fn text(own: *Data) [*:0]const u8 {
    return @ptrCast(&own.text);
}

/// An arrow in a column from `left` to `right`, its head at the top or
/// the bottom.
fn arrow(f: *const docklets.Frame, left: i32, right: i32, down: bool, colour: sdk.graphics.Pen) void {
    const width = right - left;
    const middle = left + @divTrunc(width, 2);
    const shaft = @max(1, @divTrunc(width * 36, 100));
    const top = f.part(18, 100);
    const bottom = f.part(82, 100);
    const head = @divTrunc(width * 7, 10);
    const sx0 = middle - @divTrunc(shaft, 2);
    const sx1 = sx0 + shaft;
    if (down) {
        f.box(sx0, top, sx1, bottom - head + 1, colour);
        f.polygon(&.{ .{ left, bottom - head }, .{ right, bottom - head }, .{ middle, bottom } }, colour);
    } else {
        f.box(sx0, top + head - 1, sx1, bottom, colour);
        f.polygon(&.{ .{ left, top + head }, .{ middle, top }, .{ right, top + head } }, colour);
    }
}

fn draw(own: *Data, f: *const docklets.Frame) void {
    const p = f.pens;
    const none = own.name[0] == 0;
    const lit = [2]bool{ own.rates[received] != 0, own.rates[sent] != 0 };
    for (0..2) |d| {
        const colour = if (none or !own.up) p.track else if (lit[d]) p.fill else p.text;
        const left = if (d == received) f.part(14, 100) else f.part(54, 100);
        arrow(f, left, left + f.part(32, 100), d == received, colour);
    }
    if (none) f.line(f.part(10, 100), f.part(86, 100), f.part(90, 100), f.part(14, 100), p.text);
}
