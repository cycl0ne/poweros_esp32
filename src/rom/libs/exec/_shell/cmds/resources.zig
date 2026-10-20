// SPDX-License-Identifier: MPL-2.0
//! resources: exec's resource list, what OpenResource finds.
//!
//! The rows and their lines are the ROM debugger's too (`debug/_lists.zig`);
//! here they are copied out under the list's lock and printed after.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const _lists = @import("../../debug/_lists.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "resources";
pub const usage = "resources";
pub const help =
    \\  resources            exec's resources (OpenResource)
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: _lists.Copied(_lists.resources, _shell.max_rows) = .{};
    _ = sys.LockExecList(sdk.exec.EXECLIST_RESOURCES).?;
    _lists.resources.each(.trusted, shell.base, &rows);
    sys.UnlockExecList(sdk.exec.EXECLIST_RESOURCES);
    rows.print(shell);
}
