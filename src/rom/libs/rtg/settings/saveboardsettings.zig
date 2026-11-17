// SPDX-License-Identifier: MPL-2.0
//! SaveBoardSettings: The settings the library holds, written as a file.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const dos = sdk.dos;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const settings = @import("_settings.zig");

/// Writes the settings file.
///
/// SYNOPSIS:
/// ```zig
/// fn SaveBoardSettings(rb: *RtgBase, path: ?[*:0]const u8) i32
/// ```
///
/// SINCE: 1.34. LVO -108.
///
/// INPUTS:
/// - `path` - the file; null for `ENV:Sys/display.prefs`.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_NO_FILE` where the file cannot be made or
/// dos.library cannot be opened; `RTGERR_IO` where it could not be
/// written whole; `RTGERR_NO_MEMORY` without room for its text.
///
/// BEHAVIOR:
/// The file is made anew: an explanation of its keys in comment lines,
/// then a line for every device the settings say something of, then
/// one for every output and monitor - those of boards and monitors that
/// are not there now too, so a monitor that comes back finds its line.
/// What the library holds is what `LoadBoardSettings` read and what
/// `SetBoardSettings` and `SetRtgDeviceDriver` changed since; a board
/// nothing was said of has no line.
///
/// The settings in force are not changed. To keep them over a restart
/// write `ENVARC:Sys/display.prefs` (`RTG_SETTINGS_ENVARC`).
///
/// CONTEXT:
/// - Waits: yes, for the file system.
/// - Interrupts: no.
/// - Locks: takes the settings' lock while the text is made, and gives
///   it back before the file is written. No spinlock may be held.
/// - Process: a Process, for the file.
///
/// OWNERSHIP:
/// The file is closed again, and `path` is not kept.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LoadBoardSettings`, `SetBoardSettings`, `SetRtgDeviceDriver`
///
/// EXAMPLES:
/// ```zig
/// // For the running system, and for the next start.
/// _ = rb.SaveBoardSettings(null);
/// _ = rb.SaveBoardSettings(rtg.RTG_SETTINGS_ENVARC);
/// ```
pub fn SaveBoardSettings(rb: *RtgBase, path: ?[*:0]const u8) i32 {
    const sys = rb.sys_base;
    const dl = settings.dosBase(rb) orelse return err.RTGERR_NO_FILE;

    settings.obtain(rb);
    const room = settings.bytes(rb);
    const memory = sys.AllocVec(room, exec.MEMF_ANY) orelse {
        settings.release(rb);
        return err.RTGERR_NO_MEMORY;
    };
    const text: [*]u8 = @ptrCast(memory);
    const length = settings.write(rb, text[0..room]);
    settings.release(rb);
    defer sys.FreeVec(memory);

    const file = dl.Open(settings.pathOf(path), dos.MODE_NEWFILE) orelse return err.RTGERR_NO_FILE;
    const written = dl.Write(file, text, @intCast(length));
    const closed = dl.Close(file);
    if (written != @as(isize, @intCast(length)) or !closed) return err.RTGERR_IO;
    return err.RTGERR_OK;
}
