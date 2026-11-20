// SPDX-License-Identifier: MIT
//! ReadJSONFile: a file of JSON text read into a new document.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const DosBase = sdk.interface.dos.DosBase;
const _read = @import("_read.zig");

/// How much is read at a time; the room grows by doubling.
const first_room: usize = 8 * 1024;

/// Reads a file of JSON text into a new document.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadJSONFile(base: *JSONBase, name: [*:0]const u8, flags: u32, report: ?*json.Error) ?*json.Document
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `name`: the file, as dos.library names one.
/// - `flags`: as `ParseJSON` takes them.
/// - `report`: filled in with why and where reading stopped, or with
///   `JSONERR_OK`; null when that is not wanted.
///
/// RESULT:
/// The document; null when the file could not be read - `report` then
/// says `JSONERR_FILE` and its `dos_error` what dos.library said - when
/// its text is not JSON, or when there was no memory.
///
/// BEHAVIOR:
/// The file is read to its end into memory that grows as it fills, so a
/// stream with no size - a pipe, a console - is read as a file is, then
/// read as `ParseJSON` reads text.
///
/// CONTEXT:
/// - Waits: yes: for the file's handler.
/// - Interrupts: no.
/// - Locks: none taken; none may be held around it, since it waits.
/// - Process: a Process: dos.library's calls need one.
///
/// OWNERSHIP:
/// The document is the caller's, given back with `DisposeJSONDocument`.
/// The file is closed and its text given back before the call answers.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParseJSON`, `WriteJSONFile`, `DisposeJSONDocument`
///
/// EXAMPLES:
/// ```zig
/// const kept = jb.ReadJSONFile("ENV:Weather.json", json.JSONF_COMMENTS, null);
/// defer jb.DisposeJSONDocument(kept);
/// ```
pub fn ReadJSONFile(base: *JSONBase, name: [*:0]const u8, flags: u32, report: ?*json.Error) ?*json.Document {
    const sys = base.sys_base;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse {
        failed(report, dos.ERROR_INVALID_RESIDENT_LIBRARY);
        return null;
    };
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse {
        failed(report, dl.IoErr());
        return null;
    };
    defer _ = dl.Close(file);

    var room = first_room;
    var text: [*]u8 = @ptrCast(sys.AllocVec(room, exec.MEMF_ANY) orelse {
        _read.tell(report, json.JSONERR_NOMEM, "", 0);
        return null;
    });
    defer sys.FreeVec(text);
    var length: usize = 0;
    while (true) {
        if (length == room) {
            const larger: [*]u8 = @ptrCast(sys.AllocVec(room * 2, exec.MEMF_ANY) orelse {
                _read.tell(report, json.JSONERR_NOMEM, "", 0);
                return null;
            });
            @memcpy(larger[0..length], text[0..length]);
            sys.FreeVec(text);
            text = larger;
            room *= 2;
        }
        const got = dl.Read(file, text + length, @intCast(room - length));
        if (got < 0) {
            failed(report, dl.IoErr());
            return null;
        }
        if (got == 0) break;
        length += @intCast(got);
    }
    return _read.read(base, text, length, flags, report);
}

fn failed(report: ?*json.Error, dos_error: i32) void {
    const into = report orelse return;
    into.* = .{ .code = json.JSONERR_FILE, .dos_error = dos_error };
}
