// SPDX-License-Identifier: MPL-2.0
//! segments: dos.library's resident segments - the handlers' system code
//! and the commands - read between LockSegmentList and UnLockSegmentList.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "segments";
pub const usage = "segments";
pub const help =
    \\  segments             dos.library's resident segments: system code (handlers), commands
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const dl = _shell.openDos(shell) orelse return;
    defer shell.base.iface().CloseLibrary(dl.lib());
    var segment = dl.LockSegmentList(true);
    defer dl.UnLockSegmentList();
    shell.print("name                 use       entry\n", .{});
    while (segment) |s| : (segment = s.next) {
        const use: ?[*:0]const u8 = switch (s.uc) {
            sdk.dos.CMD_SYSTEM => "system",
            sdk.dos.CMD_INTERNAL => "internal",
            sdk.dos.CMD_DISABLED => "disabled",
            else => null,
        };
        if (use) |u| {
            shell.print("%-20s %-9s 0x%08x\n", .{ s.name, u, codeAddress(s) });
        } else {
            shell.print("%-20s %-9d 0x%08x\n", .{ s.name, s.uc, codeAddress(s) });
        }
    }
}

/// A segment's code: its process entry, else its command.
fn codeAddress(s: *const sdk.dos.Segment) u32 {
    if (s.code.entry) |entry| return @intFromPtr(entry);
    if (s.code.command) |command| return @intFromPtr(command);
    return 0;
}
