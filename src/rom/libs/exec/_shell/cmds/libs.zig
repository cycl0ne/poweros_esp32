// SPDX-License-Identifier: MPL-2.0
//! libs: exec's library list.
//!
//! The rows and their lines are the ROM debugger's too (`debug/_lists.zig`);
//! here they are copied out under the list's lock and printed after.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const _lists = @import("../../debug/_lists.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "libs";
pub const usage = "libs";
pub const help =
    \\  libs                 list exec's libraries
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: _lists.Copied(_lists.libraries, _shell.max_rows) = .{};
    _ = sys.LockExecList(sdk.exec.EXECLIST_LIBRARIES).?;
    _lists.libraries.each(.trusted, shell.base, &rows);
    sys.UnlockExecList(sdk.exec.EXECLIST_LIBRARIES);
    rows.print(shell);
}
