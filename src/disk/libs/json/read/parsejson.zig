// SPDX-License-Identifier: MIT
//! ParseJSON: JSON text in memory read into a new document.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _read = @import("_read.zig");

/// Reads JSON text into a new document.
///
/// SYNOPSIS:
/// ```zig
/// fn ParseJSON(base: *JSONBase, text: [*]const u8, length: usize, flags: u32, report: ?*json.Error) ?*json.Document
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `text`: the text, UTF-8; it needs no NUL at its end.
/// - `length`: how many bytes of it to read.
/// - `flags`: `JSONF_COMMENTS` to read `//` and `/* */` comments as
///   blanks and a comma before a closing `]` or `}` as nothing; 0 for
///   JSON as RFC 8259 has it.
/// - `report`: filled in with why and where reading stopped, or with
///   `JSONERR_OK`; null when that is not wanted.
///
/// RESULT:
/// The document, its `root` the text's value; null when the text is not
/// JSON or there was no memory, `report` saying which (`JSONERR_*`) and
/// where: the byte, its line and its column.
///
/// BEHAVIOR:
/// The text is one value with blanks - space, tab, line feed, carriage
/// return - around it; a UTF-8 byte order mark before it is passed over.
/// Arrays and objects may nest as deep as memory lets them. Every string
/// and name has its escapes undone and is copied into the document,
/// with a NUL after it; a `\u` escape of half a surrogate pair is read as
/// U+FFFD. Bytes that are not UTF-8 in a string stop the reading. An
/// object may name a member twice: both are kept, in order, and
/// `FindJSONMember` finds the last. A number is read to the double
/// nearest its text, and one written as a whole number that fits 64 bits
/// is kept exactly too (`JSONVF_INTEGER`); one too large for a double is
/// read as infinity.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The text stays the caller's and may go once the call answers: the
/// document holds copies. The document is the caller's, given back with
/// `DisposeJSONDocument`.
///
/// NOTES:
/// A number with more digits than its double holds, or an exponent
/// beyond 22, takes the slow way: a decimal of up to 800 digits, the
/// call's own while it reads.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadJSONFile`, `DisposeJSONDocument`, `FindJSONPointer`, `FormatJSON`
///
/// EXAMPLES:
/// ```zig
/// var report = json.Error{};
/// const document = jb.ParseJSON(answer.ptr, answer.len, 0, &report) orelse {
///     // report.code, report.line, report.column say why and where
///     return;
/// };
/// defer jb.DisposeJSONDocument(document);
/// ```
pub fn ParseJSON(base: *JSONBase, text: [*]const u8, length: usize, flags: u32, report: ?*json.Error) ?*json.Document {
    return _read.read(base, text, length, flags, report);
}
