// SPDX-License-Identifier: MIT
//! Host tests of the docklets: each class library made from its ROM tag
//! on the ROM's intuition.library, its object asked what every docklet
//! answers, set to look, and drawn into memory. clock.docklet and
//! network.docklet open dos.library, which the host's intuition stands
//! without; they are tried on a machine.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const host_rom = @import("host_rom");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const ic = intuition.imageclass;
const docklets = sdk.docklets;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.classes.Object;
const TagItem = utility.TagItem;
const kexec = host_rom.exec;

const cpu = @import("../cpu/cpu.zig");
const battery = @import("../battery/battery.zig");
const volume = @import("../volume/volume.zig");

fn attr(ib: *IntuitionBase, o: *Object, tag: utility.Tag) usize {
    var value: usize = 0;
    _ = ib.GetAttr(tag, o, &value);
    return value;
}

fn string(value: usize) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrFromInt(value)));
}

const ground: graphics.Pen = 0xFF20_4060;

/// How many of a square of `size` pixels, filled with `ground`, a docklet
/// drew over.
fn drawnPixels(kib: *host_rom.intuition.IntuitionBase, o: *Object, comptime size: u32) !usize {
    const gb = kib.graphics_base;
    var pixels: [size * size]u32 = undefined;
    var surface = sdk.rtg.Surface{ .pixels = @ptrCast(&pixels), .width = size, .height = size, .pitch = size * 4, .size_bytes = size * size * 4, .format = .rgba32 };
    const rp = gb.CreateRastPortTagList(&[_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) }, .{} }) orelse return error.NoRastPort;
    defer gb.FreeRastPort(rp);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = ground }, .{} });
    gb.RectFill(rp, &.{ .min_x = 0, .min_y = 0, .max_x = size, .max_y = size });
    const before = pixels[0];
    var draw = ic.ImpDraw{ .method_id = ic.IM_DRAWFRAME, .rast_port = rp, .dimensions = .{ .width = size, .height = size } };
    try testing.expectEqual(@as(usize, 1), kib.iface().SendMessage(o, @ptrCast(&draw)));
    var changed: usize = 0;
    for (pixels) |pixel| changed += @intFromBool(pixel != before);
    return changed;
}

/// The ROM's intuition and a docklet's class library made from its tag;
/// one object of it asked, looked at, drawn and disposed of; the library
/// expunged.
fn tryDocklet(tag: *const exec.Resident, class: [*:0]const u8, title: []const u8, command: ?[]const u8, every: usize, says: []const u8) !void {
    const kib = try host_rom.intuition.setUp();
    const ib = kib.iface();
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, tag, null) orelse return error.NoClassLibrary));
    const o = ib.NewObjectTagList(null, class, null) orelse return error.NoObject;
    try testing.expectEqualStrings(title, string(attr(ib, o, docklets.DOCKLET_Title)));
    if (command) |runs| {
        try testing.expectEqualStrings(runs, string(attr(ib, o, docklets.DOCKLET_Command)));
    } else {
        try testing.expectEqual(@as(usize, 0), attr(ib, o, docklets.DOCKLET_Command));
    }
    try testing.expectEqual(every, attr(ib, o, docklets.DOCKLET_Every));
    // What it said at its first look, and the same again: nothing changed.
    try testing.expect(std.mem.startsWith(u8, string(attr(ib, o, docklets.DOCKLET_Text)), says));
    const look = [_]TagItem{ .{ .tag = docklets.DOCKLET_Look, .data = 1 }, .{} };
    _ = ib.SetAttrsTagList(o, &look);
    try testing.expect(std.mem.startsWith(u8, string(attr(ib, o, docklets.DOCKLET_Text)), says));
    // Drawn at two sizes, over part of the square and not all of it.
    for ([_]usize{ try drawnPixels(kib, o, 24), try drawnPixels(kib, o, 48) }, [_]usize{ 24 * 24, 48 * 48 }) |drawn, all| {
        try testing.expect(drawn > all / 20);
        try testing.expect(drawn < all);
    }
    ib.DisposeObject(o);
    _ = kexec.SysBase.iface().RemLibrary(lib);
    try testing.expect(ib.FindClass(class) == null);
    try host_rom.intuition.tearDown(kib);
}

test "cpu.docklet: a core's share busy between two counts, tasks and interrupts together" {
    const before = exec.CoreTimes{ .tasks = 1000, .idle = 3000, .interrupts = 0 };
    try testing.expectEqual(@as(u32, 67), cpu.busyBetween(before, .{ .tasks = 1100, .idle = 3100, .interrupts = 100 }));
    try testing.expectEqual(@as(u32, 0), cpu.busyBetween(before, .{ .tasks = 1000, .idle = 3500, .interrupts = 0 }));
    try testing.expectEqual(@as(u32, 100), cpu.busyBetween(before, .{ .tasks = 1400, .idle = 3000, .interrupts = 0 }));
    // No time between them is no share.
    try testing.expectEqual(@as(u32, 0), cpu.busyBetween(before, before));
}

test "cpu.docklet: made, named, looked at and drawn as a bar for each core" {
    try tryDocklet(&cpu.Library.resident_tag, docklets.CPU_CLASS, "CPU", "SYS:System/CPULoad", 1000, "CPU ");
}

test "battery.docklet: with no battery.resource, an empty battery struck through" {
    try tryDocklet(&battery.Library.resident_tag, docklets.BATTERY_CLASS, "Battery", null, 5000, "No battery measured");
}

test "volume.docklet: with no audio.device, a speaker struck through" {
    try tryDocklet(&volume.Library.resident_tag, docklets.VOLUME_CLASS, "Volume", "SYS:Programs/Volume", 1000, "No sound");
}
