// SPDX-License-Identifier: MIT
//! WriteJSONFile: a value written into a file as JSON text.

const sdk = @import("sdk");
const dos = sdk.dos;
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const DosBase = sdk.interface.dos.DosBase;
const _write = @import("_write.zig");

/// The text a missing value stands for.
const null_value = json.Value{ .kind = json.JSON_NULL, .document = undefined };

/// Writes a value into a file as JSON text.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteJSONFile(base: *JSONBase, value: ?*const json.Value, name: [*:0]const u8, flags: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `value`: the value, with all it holds; null is written `null`.
/// - `name`: the file, as dos.library names one: made, or emptied when
///   it is there.
/// - `flags`: as `FormatJSON` takes them.
///
/// RESULT:
/// True; false when the file could not be made or written, `IoErr`
/// saying why, or there was no memory to write a number in
/// (`ERROR_NO_FREE_STORE`).
///
/// BEHAVIOR:
/// The text `FormatJSON` would make, and a line end after it, written
/// through a buffer of the call's own. A file that could not be written
/// whole is closed as far as it got.
///
/// CONTEXT:
/// - Waits: yes: for the file's handler.
/// - Interrupts: no.
/// - Locks: none taken; none may be held around it, since it waits.
/// - Process: a Process: dos.library's calls need one.
///
/// OWNERSHIP:
/// The file is closed before the call answers.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FormatJSON`, `ReadJSONFile`
///
/// EXAMPLES:
/// ```zig
/// if (!jb.WriteJSONFile(settings.root, "ENVARC:Weather.json", json.JSONF_PRETTY)) {
///     _ = dl.PrintFault(dl.IoErr(), "Weather");
/// }
/// ```
pub fn WriteJSONFile(base: *JSONBase, value: ?*const json.Value, name: [*:0]const u8, flags: u32) bool {
    const sys = base.sys_base;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return false;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const file = dl.Open(name, dos.MODE_NEWFILE) orelse return false;
    var sink = _write.Sink{ .dl = dl, .file = file };
    const written = _write.write(base, value orelse &null_value, flags, &sink);
    if (written) sink.byte('\n');
    sink.flush();
    // The reason kept across the close, which may set its own.
    const reason = if (!written) dos.ERROR_NO_FREE_STORE else if (sink.failed) dl.IoErr() else 0;
    const closed = dl.Close(file);
    if (reason != 0) {
        _ = dl.SetIoErr(reason);
        return false;
    }
    return closed;
}
