// SPDX-License-Identifier: MPL-2.0
//! ports: the public message ports, who they signal and what is queued.
//!
//! The rows and their lines are the ROM debugger's too (`debug/_lists.zig`);
//! here they are copied out under exec's port lock, which masks this core's
//! interrupts, and printed after.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const _lists = @import("../../debug/_lists.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "ports";
pub const usage = "ports";
pub const help =
    \\  ports                public message ports
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: _lists.Copied(_lists.ports, _shell.max_rows) = .{};
    _ = sys.LockExecList(sdk.exec.EXECLIST_PORTS).?;
    _lists.ports.each(.trusted, shell.base, &rows);
    sys.UnlockExecList(sdk.exec.EXECLIST_PORTS);
    rows.print(shell);
}
