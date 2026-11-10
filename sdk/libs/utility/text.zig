// SPDX-License-Identifier: MIT
//! Text between UTF-8 and the system's Latin-1: what Utf8ToLatin1 is
//! told and keeps between the pieces of a text, and what Utf8Kind
//! answers.
//!
//! The system's names, its fonts and its console are Latin-1; what comes
//! from elsewhere - a server, a file another system wrote, a name in a
//! repository - is mostly UTF-8. Latin-1's 256 characters are Unicode's
//! first 256, so a character up to U+00FF is one byte either way round,
//! and the rest is what a conversion decides.

/// What Utf8ToLatin1 is told, and what it holds between the pieces of
/// one text. The caller sets `flags` and leaves the rest as it is; with
/// UTF8F_PIECES the same conversion goes to every call for one text, and
/// a new text takes a new one.
pub const Utf8Conversion = extern struct {
    /// UTF8F_*.
    flags: u32 = 0,
    /// The bytes of a character the last piece ended inside, held for the
    /// next.
    held: [3]u8 = .{ 0, 0, 0 },
    held_length: u8 = 0,
    /// The text has begun: a byte order mark is dropped only at its start.
    begun: bool = false,
};

/// A character Latin-1 has not, or bytes that are no UTF-8, refuse the
/// whole: Utf8ToLatin1 answers UTF8_REFUSED. For a name that must come
/// back as it went - the caller keeps the bytes as they are instead.
pub const UTF8F_REFUSE: u32 = 1 << 0;
/// Typesetting's characters made plain ones: its quotes ' and ", its
/// dashes and the minus sign -, the ellipsis ..., its spaces a space; the
/// marks of no width (U+200B to U+200F, U+FEFF) left out.
pub const UTF8F_TYPESET: u32 = 1 << 1;
/// A byte that starts no UTF-8 character, or a sequence broken off, taken
/// as the Latin-1 byte it is - for text that may be either, as an older
/// server sends it. Without it such a byte is a `?`.
pub const UTF8F_LATIN1: u32 = 1 << 2;
/// The text comes a piece at a time: a piece that ends inside a character
/// keeps its bytes in the conversion for the next, and a call with no
/// bytes ends the text. Without it each call's bytes are the whole text.
pub const UTF8F_PIECES: u32 = 1 << 3;

/// What Utf8ToLatin1 answers when UTF8F_REFUSE refused: `into` then holds
/// nothing of use.
pub const UTF8_REFUSED: usize = ~@as(usize, 0);

/// What Utf8Kind answers.
/// Bytes that are no UTF-8: a lead without its continuation, a stray
/// continuation, an overlong form, a surrogate, past U+10FFFF.
pub const UTF8KIND_NONE: u32 = 0;
/// ASCII alone, which is UTF-8 and Latin-1 alike; an empty text too.
pub const UTF8KIND_ASCII: u32 = 1;
/// UTF-8 with characters past ASCII, every one of them Latin-1's.
pub const UTF8KIND_LATIN1: u32 = 2;
/// UTF-8 with a character Latin-1 has not.
pub const UTF8KIND_WIDE: u32 = 3;
