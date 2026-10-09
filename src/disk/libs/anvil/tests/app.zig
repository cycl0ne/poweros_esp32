// SPDX-License-Identifier: MIT
//! Host tests of anvil.library's calls for programs, on exec, utility and
//! dos.library brought up as the ROM's tests bring them up: nothing added
//! without a desktop; with one - this task standing in, told by a signal
//! - each kind added and told, its text cut, an icon's picture copied,
//! and each removed once.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const intuition = sdk.intuition;
const AnvilBase = sdk.interface.anvil.AnvilBase;
const anvil_init = @import("../anvil_init.zig");
const _base = @import("../anvil_base.zig");
const _app = @import("../app/_app.zig");
const host = @import("host_rom");
const kexec = host.exec;

const testing = std.testing;

test "App calls: none without a desktop; added, told, cut, copied and removed once with one" {
    const db = try host.dos.testSetUp();
    const sys = kexec.SysBase.iface();
    // A process runs the test, as a program would: IoErr is a process's.
    var proc: dos.Process = .{};
    proc.task.node.name = "test process";
    host.dos_process.initMsgPort(&proc);
    const saved = kexec.SysBase.cpu().this_task;
    kexec.SysBase.cpu().this_task = &proc.task;
    const made = kexec.InitResident(kexec.SysBase, &anvil_init.anvil_library_tag, null) orelse return error.NoAnvil;
    const lib: *exec.Library = @ptrCast(@alignCast(made));
    const base = _base.anvilBase(lib);
    const ab: *AnvilBase = @ptrCast(sys.OpenLibrary(sdk.anvil.ANVILNAME, 1) orelse return error.NoAnvil);
    const dl = host.dos.testBase(db);
    const port = sys.CreateMsgPort() orelse return error.NoPort;

    // Nothing is added while no desktop runs.
    var stand_in: u64 = 0;
    const window: *intuition.Window = @ptrCast(&stand_in);
    try testing.expect(ab.AddAppWindow(1, 2, window, port, null) == null);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(ab.AddAppMenuItem(3, 4, "Item", port, null) == null);

    // This task stands in for the desktop: each addition signals it.
    const signal = sys.AllocSignal(-1);
    try testing.expect(signal >= 0);
    const mask = @as(u32, 1) << @intCast(signal);
    base.app_task = sys.FindTask(null);
    base.app_signals = mask;
    _ = sys.SetSignal(0, mask);

    const app_window = ab.AddAppWindow(1, 2, window, port, null) orelse return error.NotAdded;
    try testing.expect(sys.SetSignal(0, mask) & mask != 0);
    const long = "An item whose words run on well past the sixty-three bytes kept of them";
    const app_item = ab.AddAppMenuItem(3, 4, long, port, null) orelse return error.NotAdded;
    const item_record: *_app.App = @ptrCast(@alignCast(app_item));
    try testing.expectEqualStrings(long[0.._app.text_max], std.mem.span(@as([*:0]const u8, &item_record.text)));
    try testing.expectEqual(@as(u32, 3), item_record.id);
    try testing.expectEqual(@as(usize, 4), item_record.user_data);

    // An icon's picture is copied, and the object made the desktop's.
    var pixels: [16]u8 = undefined;
    for (&pixels, 0..) |*byte, i| byte.* = @intCast(i);
    const image = icon.IconImage{ .width = 2, .height = 2, .pixels = &pixels };
    var object = icon.DiskObject{ .kind = icon.WBTOOL, .current_x = 30, .current_y = 40, .image = &image };
    const app_icon = ab.AddAppIcon(5, 6, "Clock", port, &object, null) orelse return error.NotAdded;
    const icon_record: *_app.App = @ptrCast(@alignCast(app_icon));
    pixels[0] = 99;
    try testing.expectEqual(@as(u8, 0), icon_record.image.pixels[0]);
    try testing.expectEqual(@as(u8, 15), icon_record.image.pixels[15]);
    try testing.expectEqual(icon.WBAPPICON, icon_record.object.kind);
    try testing.expectEqual(@as(i32, 30), icon_record.object.current_x);
    try testing.expect(icon_record.object.image == &icon_record.image);
    try testing.expectEqualStrings("Clock", std.mem.span(@as([*:0]const u8, &icon_record.text)));
    object.image = null;
    try testing.expect(ab.AddAppIcon(5, 6, "None", port, &object, null) == null);
    try testing.expectEqual(dos.ERROR_REQUIRED_ARG_MISSING, dl.IoErr());

    // Removed once each: the port taken off at once, the record left for
    // the desktop to free; a handle of another kind, or one removed, is
    // not taken.
    _ = sys.SetSignal(0, mask);
    try testing.expect(!ab.RemoveAppIcon(@ptrCast(app_window)));
    try testing.expect(ab.RemoveAppWindow(app_window));
    try testing.expect(sys.SetSignal(0, mask) & mask != 0);
    try testing.expect(!ab.RemoveAppWindow(app_window));
    try testing.expect(ab.RemoveAppMenuItem(app_item));
    try testing.expect(ab.RemoveAppIcon(app_icon));
    try testing.expect(item_record.port == null and item_record.gone);
    try testing.expect(!ab.RemoveAppWindow(null));

    // The desktop's part: every record freed as it ends.
    base.app_task = null;
    while (base.apps.first()) |node| {
        sys.Remove(node);
        _app.free(sys, @fieldParentPtr("node", node));
    }
    sys.FreeSignal(signal);
    sys.DeleteMsgPort(port);
    sys.CloseLibrary(ab.lib());
    _ = sys.RemLibrary(lib);
    kexec.SysBase.cpu().this_task = saved;
    try host.dos.testTearDown(db);
    kexec.deinit();
}
