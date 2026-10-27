// SPDX-License-Identifier: MIT
//! OpenObject: a file, a drawer or a disk opened by the desktop, as a
//! double click on its icon opens it.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const anvil = sdk.anvil;
const utility = sdk.utility;
const AnvilBase = @import("../anvil_base.zig").AnvilBase;
const _open = @import("_open.zig");

/// Opens a file, a drawer or a disk as a double click on its icon does.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenObject(base: *AnvilBase, name: [*:0]const u8, tags: ?[*]const utility.TagItem) bool
/// ```
///
/// SINCE: 1.16. LVO -52.
///
/// INPUTS:
/// - `name` - the file, drawer or disk, as the caller's current directory
///   has it: `Work:Notes`, `Pictures`, `SYS:`.
/// - `tags`:
///   - ANVO_File ([*:0]const u8, as often as wanted): a file handed on
///     with it, as an icon picked with it is; up to `OPEN_FILES_MAX`, the
///     rest left out.
///   - ANVO_EndMsg (*exec.Message): replied to its `reply_port` once what
///     was opened has ended, as `NP_EndMsg` is; at once for a drawer or a
///     disk.
///
/// RESULT:
/// True once it is opened: the drawer's window open, the program started.
/// False with IoErr: ERROR_OBJECT_NOT_FOUND (a name is not there, or the
/// desktop does not run), ERROR_OBJECT_WRONG_TYPE (nothing opens the
/// file), ERROR_LINE_TOO_LONG (the names make too long a command line),
/// ERROR_OBJECT_IN_USE (the caller is the desktop itself),
/// ERROR_NO_FREE_STORE, or what stopped the program from starting.
///
/// BEHAVIOR:
/// The names are made full on the caller's task, then the desktop opens
/// them on its own and answers. A disk or a drawer, the trash among them,
/// opens in a window of its own, or comes to the front when it is open;
/// the files are not read. Anything else is run as a double click with
/// the files picked runs it: a tool among them with the others; else the
/// first project's default tool; else the file's type's tool
/// (datatypes.library's BROWSE); else a script through `C:IconX` - in a
/// shell of its own, its files on its command line and as lock-and-name
/// pairs, with the stack and the `TOOLPRI` of its icon. A file that has
/// no icon is opened as if it had the default one of its kind.
///
/// A program started without `ANVO_EndMsg` is the desktop's to wait for,
/// as one started from an icon is. With it, the desktop leaves it to the
/// caller.
///
/// CONTEXT:
/// - Waits: yes, for the desktop, which answers between its other work.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process; IoErr is set on failure.
///
/// OWNERSHIP:
/// The names are copied: they may go once the call returns. The end
/// message stays the caller's and must stay until it is replied - on a
/// false answer it is not replied.
///
/// NOTES:
/// What is opened is not the caller's: it runs on when the caller ends,
/// and its end comes back only by `ANVO_EndMsg`. The desktop's title says
/// why a file could not be opened, as it does for a double click.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartAnvil`, `SystemTagList`
///
/// EXAMPLES:
/// ```zig
/// const files = [_]utility.TagItem{
///     .{ .tag = anvil.ANVO_File, .data = @intFromPtr("Work:Notes") },
///     .{},
/// };
/// if (!ab.OpenObject("SYS:Programs/Notepad", &files)) _ = dl.PrintFault(dl.IoErr(), "Open");
/// _ = ab.OpenObject("Work:", null); // the disk's window
/// ```
pub fn OpenObject(base: *AnvilBase, name: [*:0]const u8, tags: ?[*]const utility.TagItem) bool {
    const sys = base.sys_base;
    const dl = base.dos_base;
    if (_open.isDesktop(base)) return failed(dl, dos.ERROR_OBJECT_IN_USE);
    const reply = sys.CreateMsgPort() orelse return failed(dl, dos.ERROR_NO_FREE_STORE);
    defer sys.DeleteMsgPort(reply);
    const request = _open.make(base, name, tags, reply) orelse return false;
    defer sys.FreeVec(request);
    if (!_open.send(base, request)) return failed(dl, dos.ERROR_OBJECT_NOT_FOUND);
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
    if (request.failure != 0) return failed(dl, request.failure);
    return true;
}

fn failed(dl: *sdk.interface.dos.DosBase, code: i32) bool {
    _ = dl.SetIoErr(code);
    return false;
}
