// SPDX-License-Identifier: MIT
//! compression.library's stream and constants: what a program hands the
//! library to have bytes packed with DEFLATE (RFC 1951) or unpacked, bare
//! or in a zlib (RFC 1950) or gzip (RFC 1952) wrapping. The calls are in
//! `sdk.interface.compression`.
//!
//! **A stream is the caller's.** It says where the next input is and how
//! much of it there is, where the output goes and how much room there is,
//! and the library moves both on as it works - so a program feeds a file
//! through a buffer at a time, or hands the whole of it over in one go.
//! What the library needs between calls (the window of what came last,
//! the codes of the block it is in) is allocated by the Init call, hangs
//! off `state`, and goes at the End call. Any number of streams may be
//! under way at once, by any number of tasks, each in its own Stream.
//!
//! A Stream starts with its size, which `.{}` fills in, as crypto.library's
//! contexts do: an Init call refuses one smaller than its own idea of it.
//! Its fields other than the four a caller sets are the library's.

/// The library's name, for OpenLibrary.
pub const COMPRESSIONNAME = "compression.library";

// --- formats ---------------------------------------------------------------------

/// What wraps the DEFLATE data: nothing, zlib's two bytes in front and
/// Adler-32 behind, or gzip's header and its CRC-32 and length behind.
pub const FORMAT_RAW: u32 = 0;
pub const FORMAT_ZLIB: u32 = 1;
pub const FORMAT_GZIP: u32 = 2;
/// Unpacking only: zlib or gzip, told apart by the first two bytes.
pub const FORMAT_AUTO: u32 = 3;

// --- levels -----------------------------------------------------------------------

/// How hard Deflate looks for repeats: 0 stores the bytes as they are,
/// 1 is the quickest, 9 the smallest output.
pub const LEVEL_STORE: u32 = 0;
pub const LEVEL_FAST: u32 = 1;
pub const LEVEL_DEFAULT: u32 = 6;
pub const LEVEL_BEST: u32 = 9;

// --- flushing ---------------------------------------------------------------------

/// What Inflate and Deflate are to do with the input they have.
/// FLUSH_NONE: as much as suits them; Deflate may hold input back for a
/// better block.
pub const FLUSH_NONE: u32 = 0;
/// Deflate: everything given so far out, ending on a byte, so the other
/// end can unpack it all now (an empty stored block, as zlib's
/// Z_SYNC_FLUSH writes it). The stream goes on.
pub const FLUSH_SYNC: u32 = 1;
/// No more input comes: Deflate ends the stream, and Inflate counts a
/// stream that has not ended once its input is used up as cut short.
pub const FLUSH_FINISH: u32 = 2;

// --- results ----------------------------------------------------------------------

/// Work done, or nothing to do until there is more input or more room.
pub const COMPRESS_OK: i32 = 0;
/// The stream's end: Inflate has read it, Deflate has written all of it.
pub const COMPRESS_END: i32 = 1;
/// The input is no stream of the format: a bad header, a code the
/// block's codes do not have, a repeat from before the start, a
/// checksum that does not match.
pub const COMPRESSERR_DATA: i32 = -1;
/// The memory for the stream's state could not be had.
pub const COMPRESSERR_MEMORY: i32 = -2;
/// Uncompress and Compress: the output did not hold it all.
pub const COMPRESSERR_BUFFER: i32 = -3;
/// A stream that was not set up for the call, a Stream too small, or an
/// argument out of range (a format or level there is not).
pub const COMPRESSERR_STREAM: i32 = -4;
/// The input ended before the stream did, with FLUSH_FINISH or in
/// Uncompress.
pub const COMPRESSERR_TRUNCATED: i32 = -5;

// --- the stream ---------------------------------------------------------------------

/// One stream being packed or unpacked. The caller sets `next_in`,
/// `avail_in`, `next_out` and `avail_out` before each call; the library
/// moves them on by what it took and wrote.
pub const Stream = extern struct {
    /// The Stream's size in bytes, as the program was built with it.
    size: u32 = @sizeOf(Stream),
    /// The bytes at `next_in` still to be read.
    avail_in: u32 = 0,
    /// The room at `next_out` still to be written.
    avail_out: u32 = 0,
    /// FORMAT_* the stream turned out to be, once Inflate has read its
    /// header: FORMAT_AUTO becomes FORMAT_ZLIB or FORMAT_GZIP here.
    format: u32 = 0,
    next_in: ?[*]const u8 = null,
    next_out: ?[*]u8 = null,
    /// Every byte read and written since the Init call: what a reader of
    /// a packed stream inside something larger (a git pack, a zip file)
    /// learns its length from.
    total_in: u64 align(4) = 0,
    total_out: u64 align(4) = 0,
    /// The library's, from the Init call to the End call.
    state: ?*anyopaque = null,
    reserved: [4]usize = @splat(0),
};
