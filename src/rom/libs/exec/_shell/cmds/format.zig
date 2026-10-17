// SPDX-License-Identifier: MPL-2.0
//! format <device> <name>: a fresh volume over a drive's medium -
//! everything on it goes, and the volume takes the name given. The drive
//! is inhibited, formatted in its own DosType and let go, through
//! dos.library's Inhibit and Format. C:Format does the same with a
//! question first; this one is here because a board whose disk has only
//! just had a RigidDiskBlock written to it has no C: to load C:Format
//! from.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "format";
pub const usage = "format <device> <name>";
pub const help =
    \\  format <device> <name>  a fresh volume, e.g. format DH0: System
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const device = args.next() orelse return error.Usage;
    const volume = args.next() orelse return error.Usage;
    const dl = _shell.openDos(shell) orelse return;
    defer shell.base.iface().CloseLibrary(dl.lib());
    if (!dl.Inhibit(device.ptr, true)) {
        shell.print("%s: not inhibited (%d)\n", .{ device, dl.IoErr() });
        return;
    }
    const done = dl.Format(device.ptr, volume.ptr, 0);
    const code = dl.IoErr();
    _ = dl.Inhibit(device.ptr, false);
    if (!done) {
        shell.print("format %s failed (%d)\n", .{ device, code });
        return;
    }
    shell.print("%s formatted as \"%s\"\n", .{ device, volume });
}
