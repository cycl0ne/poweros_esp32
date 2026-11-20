// SPDX-License-Identifier: MIT
//! FormatJSON: a value as JSON text in memory.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _write = @import("_write.zig");

/// The text a missing value stands for.
const null_value = json.Value{ .kind = json.JSON_NULL, .document = undefined };

/// Writes a value as JSON text into memory.
///
/// SYNOPSIS:
/// ```zig
/// fn FormatJSON(base: *JSONBase, value: ?*const json.Value, buffer: ?[*]u8, size: usize, flags: u32) usize
/// ```
///
/// SINCE: 1.0. LVO -108.
///
/// INPUTS:
/// - `value`: the value, with all it holds; null is written `null`.
/// - `buffer`: where the text goes; null to only measure it.
/// - `size`: the buffer's size in bytes, its NUL included.
/// - `flags`: `JSONF_PRETTY` for a value or member a line, indented;
///   `JSONF_ASCII` for every character past ASCII as a `\u` escape; 0 for
///   compact UTF-8.
///
/// RESULT:
/// How long the whole text is in bytes, its NUL aside - more than fits
/// when the buffer was too small. 0, and an empty buffer, when there was
/// no memory to write a number in.
///
/// BEHAVIOR:
/// What fits of the text is written, and a NUL after it whenever `size`
/// is not 0, so a buffer too small holds the text's start; a second call
/// with a buffer of the answer plus one holds all of it. A value's own
/// name is not written: the text is the value. Strings are escaped as
/// JSON wants, and bytes that are not UTF-8 written as U+FFFD. A number
/// takes the fewest digits that read back as the same double, a whole
/// number kept exactly its own digits; infinity and NaN are `null`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the caller's. The room a number is worked out in is
/// the call's own and freed before it answers.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WriteJSONFile`, `ParseJSON`
///
/// EXAMPLES:
/// ```zig
/// const length = jb.FormatJSON(document.root, null, 0, json.JSONF_PRETTY);
/// const text: [*]u8 = @ptrCast(sys.AllocVec(length + 1, exec.MEMF_ANY) orelse return);
/// _ = jb.FormatJSON(document.root, text, length + 1, json.JSONF_PRETTY);
/// ```
pub fn FormatJSON(base: *JSONBase, value: ?*const json.Value, buffer: ?[*]u8, size: usize, flags: u32) usize {
    var sink = _write.Sink{ .buffer = buffer, .size = if (buffer == null) 0 else size };
    if (!_write.write(base, value orelse &null_value, flags, &sink)) {
        if (buffer) |into| {
            if (size > 0) into[0] = 0;
        }
        return 0;
    }
    if (buffer) |into| {
        if (size > 0) into[@min(sink.total, size - 1)] = 0;
    }
    return sink.total;
}
