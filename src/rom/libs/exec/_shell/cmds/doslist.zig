// SPDX-License-Identifier: MPL-2.0
//! doslist: dos.library's device list - devices, volumes, assigns - read
//! between LockDosList and UnLockDosList, with where each assign goes.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const DosBase = sdk.interface.dos.DosBase;

pub const name = "doslist";
pub const usage = "doslist";
pub const help =
    \\  doslist              dos.library's device list: devices, volumes, assigns
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const dl = _shell.openDos(shell) orelse return;
    defer shell.base.iface().CloseLibrary(dl.lib());
    const flags = sdk.dos.LDF_ALL | sdk.dos.LDF_READ;
    var node = dl.LockDosList(flags) orelse return;
    defer dl.UnLockDosList(flags);
    shell.print("name            type        port\n", .{});
    while (dl.NextDosEntry(node, flags)) |entry| : (node = entry) {
        shell.print("%-15s %-10s  0x%08x\n", .{ entry.name, _shell.enumName(sdk.dos.DosListType, entry.type), @intFromPtr(entry.task) });
        showAssign(shell, dl, entry);
    }
}

/// Where an assign goes: its directories by NameFromLock, or a late or
/// non-binding assign's path.
fn showAssign(shell: *Shell, dl: *DosBase, entry: *sdk.dos.DosList) void {
    switch (entry.type) {
        .directory => {
            showLock(shell, dl, "->", entry.lock);
            var more = entry.misc.assign.list;
            while (more) |next| : (more = next.next) showLock(shell, dl, "+ ", next.lock);
        },
        .late, .nonbinding => {
            const path: [*:0]const u8 = entry.misc.assign.assign_name orelse "";
            const how: [*:0]const u8 = if (entry.type == .late) "late" else "path";
            shell.print("                -> %s (%s)\n", .{ path, how });
        },
        else => {},
    }
}

fn showLock(shell: *Shell, dl: *DosBase, mark: [*:0]const u8, lock: ?*sdk.dos.FileLock) void {
    var buf: [128]u8 = undefined;
    const path: [*:0]const u8 = if (dl.NameFromLock(lock, &buf, buf.len)) @ptrCast(&buf) else "?";
    shell.print("                %s %s\n", .{ mark, path });
}
