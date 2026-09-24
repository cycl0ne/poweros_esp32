// SPDX-License-Identifier: MPL-2.0
//! format <device> <name>: ACTION_FORMAT to a device's file system -
//! everything on it goes, and the volume takes the name given. C:Format
//! does this properly, with a confirmation and the node's own DosType;
//! this one is here because a board whose disk has only just had a
//! RigidDiskBlock written to it has no C: to load C:Format from.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "format";
pub const usage = "format <device> <name>";
pub const help =
    \\  format <device> <name>  ACTION_FORMAT, e.g. format DH0: System
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const device = args.next() orelse return error.Usage;
    const volume = args.next() orelse return error.Usage;
    const dl = _shell.openDos(shell) orelse return;
    defer shell.base.iface().CloseLibrary(dl.lib());
    const dp = dl.GetDeviceProc(device.ptr, null) orelse {
        shell.print("%s: no handler (%d)\n", .{ device, dl.IoErr() });
        return;
    };
    defer dl.FreeDeviceProc(dp);
    const port = dp.port orelse {
        shell.print("%s: its handler has no port\n", .{device});
        return;
    };
    const done = dl.DoPkt(
        port,
        @intFromEnum(sdk.dos.ActionCode.format),
        @bitCast(@intFromPtr(volume.ptr)),
        @bitCast(@as(usize, sdk.dos.flashfs.ID_FLASHFS_DISK)),
        0,
        0,
        0,
    );
    if (done == sdk.dos.DOSFALSE) {
        shell.print("format %s failed (%d)\n", .{ device, dl.IoErr() });
        return;
    }
    shell.print("%s formatted as \"%s\"\n", .{ device, volume });
}
