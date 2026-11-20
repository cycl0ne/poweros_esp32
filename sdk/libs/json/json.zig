// SPDX-License-Identifier: MIT
//! json.library's types: JSON text (RFC 8259) read into a tree of values,
//! looked through, built and changed, and written out again.
//!
//! **A document** holds one tree: its outermost value, `root`, and every
//! value made for it, all taken from one memory pool and given back
//! together by `DisposeJSONDocument`. `ParseJSON` and `ReadJSONFile` make
//! one from text; `CreateJSONDocument` makes an empty one to build in.
//!
//! **A value** is one of the six kinds (`JSON_*`). An array or an object
//! holds its values as a list - `first` to `last`, each with `next` and
//! `prev`, in the order of the text - and each knows its `parent`; a value
//! in an object carries its `name`. A program reads the fields as it
//! likes, or goes through the calls, every one of which takes null for a
//! value and answers null or false for it, so that one lookup can be
//! handed straight to the next:
//!
//!   var celsius: f64 = 0;
//!   if (jb.GetJSONNumber(jb.FindJSONPointer(doc.root, "/current/temperature_2m"), &celsius)) ...
//!
//! The fields are changed only by the calls: a value is placed into an
//! array or object, moved, or taken out with them, which keep the lists,
//! the counts and the parents true.
//!
//! **Text** is UTF-8 throughout. A string's escapes are undone as it is
//! read - `\u` escapes, surrogate pairs among them, become UTF-8 - and
//! every string and name ends in a NUL besides its length, which is what
//! to go by when the text may hold a `\u0000`.
//!
//! **Numbers** are read to the double nearest the text, correctly rounded
//! whatever its digits, and one written as a whole number that fits 64
//! bits is kept exactly as well (`JSONVF_INTEGER`). Written out, a number
//! takes the fewest digits that read back as the same double.

pub const JSONNAME = "json.library";

// --- what a value is ---------------------------------------------------------

/// `null`.
pub const JSON_NULL: u32 = 0;
/// `true` or `false`, in `truth`.
pub const JSON_BOOLEAN: u32 = 1;
/// A number, in `number` (and in `integer` with `JSONVF_INTEGER`).
pub const JSON_NUMBER: u32 = 2;
/// A string, in `string` and `length`.
pub const JSON_STRING: u32 = 3;
/// An array: `count` values from `first` to `last`.
pub const JSON_ARRAY: u32 = 4;
/// An object: `count` values from `first` to `last`, each with its `name`.
pub const JSON_OBJECT: u32 = 5;

/// `Value.flags`: the number was written, or made, as a whole number that
/// fits 64 bits, and `integer` holds it exactly.
pub const JSONVF_INTEGER: u32 = 1 << 0;

/// `InsertJSONItem`'s index for after the last item.
pub const JSON_END: u32 = 0xFFFF_FFFF;
/// `CreateJSONString`'s length for text that ends at its NUL.
pub const JSON_TERMINATED: u32 = 0xFFFF_FFFF;

// --- how text is read and written --------------------------------------------

/// Reading: `//` and `/* */` comments are read as blanks, and a comma
/// before a closing `]` or `}` as nothing - what a settings file written
/// by hand is allowed.
pub const JSONF_COMMENTS: u32 = 1 << 0;
/// Writing: one value or member a line, indented two spaces a level, a
/// space after each name's colon.
pub const JSONF_PRETTY: u32 = 1 << 8;
/// Writing: every character past ASCII as a `\u` escape, a surrogate pair
/// past U+FFFF, so that the text is 7-bit.
pub const JSONF_ASCII: u32 = 1 << 9;

// --- why text could not be read ----------------------------------------------

/// Read.
pub const JSONERR_OK: i32 = 0;
/// No memory for the values.
pub const JSONERR_NOMEM: i32 = 1;
/// The text holds no value, only blanks.
pub const JSONERR_EMPTY: i32 = 2;
/// A character where nothing of its kind can stand.
pub const JSONERR_UNEXPECTED: i32 = 3;
/// The text ends inside a value.
pub const JSONERR_END: i32 = 4;
/// A number not written as JSON writes one: a leading zero, a point or
/// an `e` without digits after it.
pub const JSONERR_NUMBER: i32 = 5;
/// A backslash in a string that starts no escape, or a `\u` without four
/// hexadecimal digits.
pub const JSONERR_ESCAPE: i32 = 6;
/// A control character, U+0000 to U+001F, written into a string as it is.
pub const JSONERR_CONTROL: i32 = 7;
/// Bytes that are not UTF-8.
pub const JSONERR_UTF8: i32 = 8;
/// More after the value than blanks.
pub const JSONERR_TRAILING: i32 = 9;
/// The file could not be read: `Error.dos_error` says why.
pub const JSONERR_FILE: i32 = 10;

/// Where and why reading stopped, filled in by `ParseJSON` and
/// `ReadJSONFile`.
pub const Error = extern struct {
    /// `JSONERR_*`; `JSONERR_OK` when the text was read.
    code: i32 = JSONERR_OK,
    /// The byte the reading stopped at, from 0.
    offset: u32 = 0,
    /// Its line and its column, both from 1; a column counts characters,
    /// not bytes.
    line: u32 = 0,
    column: u32 = 0,
    /// dos.library's error for `JSONERR_FILE`, as `IoErr` had it.
    dos_error: i32 = 0,
};

/// One value of a document. Read its fields; change them only through the
/// calls.
pub const Value = extern struct {
    /// `JSON_*`.
    kind: u32,
    /// `JSONVF_*`.
    flags: u32 = 0,
    /// The array or object it is in; null for the root and for a value
    /// not placed anywhere yet.
    parent: ?*Value = null,
    /// The values beside it in that array or object, in order.
    next: ?*Value = null,
    prev: ?*Value = null,
    /// Its name in its object: UTF-8, `name_length` bytes and a NUL. Null
    /// anywhere else.
    name: ?[*:0]const u8 = null,
    name_length: u32 = 0,
    /// A string's text: UTF-8, `length` bytes and a NUL.
    string: ?[*:0]const u8 = null,
    length: u32 = 0,
    /// An array's or object's values, and how many there are.
    first: ?*Value = null,
    last: ?*Value = null,
    count: u32 = 0,
    /// A boolean's value.
    truth: bool = false,
    pad: [3]u8 = @splat(0),
    /// A number's value; `integer` holds it exactly under `JSONVF_INTEGER`.
    number: f64 align(4) = 0,
    integer: i64 align(4) = 0,
    /// The document it belongs to.
    document: *Document,
};

/// One tree of values and the memory they are in.
pub const Document = extern struct {
    /// The outermost value; null for a document with none yet.
    root: ?*Value = null,
    /// The library's own: the pool every value and text is taken from.
    pool: ?*anyopaque = null,
};
