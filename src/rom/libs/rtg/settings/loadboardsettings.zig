// SPDX-License-Identifier: MPL-2.0
//! LoadBoardSettings: The settings file read in place of what the library
//! holds, and applied to the boards there are.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const dos = sdk.dos;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const settings = @import("_settings.zig");

/// Reads the settings file and applies it.
///
/// SYNOPSIS:
/// ```zig
/// fn LoadBoardSettings(rb: *RtgBase, path: ?[*:0]const u8) i32
/// ```
///
/// SINCE: 1.34. LVO -104.
///
/// INPUTS:
/// - `path` - the file; null for `ENV:Sys/display.prefs`.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_BAD_ARG` where a line could not be read - the
/// others are in force; `RTGERR_NO_FILE` where the file is not there or
/// dos.library cannot be opened, `RTGERR_IO` where it cannot be read to
/// its end, `RTGERR_NO_MEMORY` without room for its text: these three
/// change nothing.
///
/// BEHAVIOR:
/// The file's lines take the place of every line the library held: a
/// device or an output the file does not name has none afterwards. A
/// line that cannot be read - one that names neither a device nor an
/// output, a key its kind has not got, a value out of its range - is
/// passed over, and said on the system's log with its number. No more
/// than 64 KiB of a file are read.
///
/// Then every board is given its line, as `SetBoardSettings` applies
/// one: its modes are made again with the default the line names and
/// the timings it gives by hand, the colour range is the line's, the
/// mirror and the brightness are set where the line says them, and the
/// board the file makes the first is the first. A board the file does
/// not name gets back the default mode and the place on the list it has
/// by itself, and the range its monitor asks for. The mode a board is in
/// stays: the default is what `BestBoardMode` answers a caller that
/// leaves everything open, and intuition.library puts a display in the
/// mode its line names when the display's first screen opens.
///
/// A device no driver has yet takes its line with it to the driver it
/// is offered next: `BUFFERS` as `RTGA_Buffers` and `COMPOSE` as
/// `RTGA_Compose` in front of its own tags. A device a driver has
/// already keeps what it was offered with.
///
/// CONTEXT:
/// - Waits: yes, for the file system, and where a driver waits for its
///   display.
/// - Interrupts: no.
/// - Locks: takes the settings' lock while it reads, then each board's
///   in turn. No spinlock may be held.
/// - Process: a Process, for the file.
///
/// OWNERSHIP:
/// The lines are the library's. The file is closed again, and `path` is
/// not kept.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SaveBoardSettings`, `GetBoardSettings`, `SetBoardSettings`,
/// `SetRtgDeviceDriver`
///
/// EXAMPLES:
/// ```zig
/// // The settings kept over a restart, in force now.
/// if (rb.LoadBoardSettings(rtg.RTG_SETTINGS_ENVARC) == rtg.errors.RTGERR_NO_FILE) {
///     // No file: every board as its driver and its monitor have it.
/// }
/// ```
pub fn LoadBoardSettings(rb: *RtgBase, path: ?[*:0]const u8) i32 {
    const sys = rb.sys_base;
    const dl = settings.dosBase(rb) orelse return err.RTGERR_NO_FILE;
    const file = dl.Open(settings.pathOf(path), dos.MODE_OLDFILE) orelse return err.RTGERR_NO_FILE;
    defer _ = dl.Close(file);
    const memory = sys.AllocVec(settings.file_most, exec.MEMF_ANY) orelse return err.RTGERR_NO_MEMORY;
    defer sys.FreeVec(memory);
    const text: [*]u8 = @ptrCast(memory);
    var length: usize = 0;
    while (length < settings.file_most) {
        const got = dl.Read(file, text + length, @intCast(settings.file_most - length));
        if (got < 0) return err.RTGERR_IO;
        if (got == 0) break;
        length += @intCast(got);
    }

    settings.obtain(rb);
    const unread = settings.read(rb, text[0..length]);
    settings.release(rb);

    settings.dressAll(rb);
    settings.applyAll(rb);
    return if (unread != 0) err.RTGERR_BAD_ARG else err.RTGERR_OK;
}
