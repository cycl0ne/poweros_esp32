// SPDX-License-Identifier: MPL-2.0
//! devs: exec's device list.
//!
//! The rows and their lines are the ROM debugger's too (`debug/_lists.zig`);
//! here they are copied out under the list's lock and printed after.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const _lists = @import("../../debug/_lists.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "devs";
pub const usage = "devs";
pub const help =
    \\  devs                 the device list
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: _lists.Copied(_lists.devices, _shell.max_rows) = .{};
    _ = sys.LockExecList(sdk.exec.EXECLIST_DEVICES).?;
    _lists.devices.each(.trusted, shell.base, &rows);
    sys.UnlockExecList(sdk.exec.EXECLIST_DEVICES);
    rows.print(shell);
}
