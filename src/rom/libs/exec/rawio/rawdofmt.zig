// SPDX-License-Identifier: MPL-2.0
//! RawDoFmt: the system's one formatter. Everything that prints in this
//! tree is built on it, so a conversion means the same thing in a shell
//! command, a device's error and a kernel panic. The rules are in the file
//! header of _rawio.zig; the work is `_rawio.format`, which `kprintf` uses
//! too, before there is an ExecBase to pass.

const sdk = @import("sdk");
const _rawio = @import("_rawio.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const PutChProc = sdk.exec.PutChProc;

/// Formats text, handing each character to a function of the caller's.
///
/// SYNOPSIS:
/// ```zig
/// fn RawDoFmt(_: *ExecBase, format_string: [*:0]const u8,
///     data_stream: ?*const anyopaque, put_ch_proc: ?PutChProc,
///     put_ch_data: ?*anyopaque) ?*const anyopaque
/// ```
///
/// SINCE: 1.0. LVO -372.
///
/// INPUTS:
/// - `format_string` - `%[-][0][width][.limit][l]{d,D,u,U,x,X,s,c}`.
///   `%d %u %x %c` take 32 bits and `%l...` 64; `%s` takes a pointer to a
///   NUL-terminated string. An unknown conversion prints its own character,
///   so `%%` prints one per cent.
/// - `data_stream` - the values, packed and read with unaligned loads. Null
///   gives 0 and null for every value rather than faulting.
/// - `put_ch_proc` - called with each character and `put_ch_data`, and with
///   a final NUL. **Null instead stores the characters into `put_ch_data`
///   as a buffer**, which is how a string is formatted without a function.
/// - `put_ch_data` - passed to `put_ch_proc` untouched, or the buffer.
///
/// RESULT:
/// The data stream past the values that were used, so a second format can
/// carry on where the first stopped.
///
/// BEHAVIOR:
/// Hex is upper case with no leading zeros, and 0 prints as "0". With zero
/// fill the sign comes before the zeros, so `%03d` of -5 is "-05". A
/// `.limit` cuts the text, and a null `%s` prints nothing at all - not even
/// padding. A format ending in a lone `%` ends there rather than reading
/// past the NUL.
///
/// CONTEXT:
/// - Waits: no, though `put_ch_proc` may.
/// - Interrupts: safe in itself; it depends entirely on what
///   `put_ch_proc` does.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. With a null `put_ch_proc` the buffer is the
/// caller's and **nothing checks its size**.
///
/// NOTES:
/// These are not Zig's format strings. `sdk.exec.checkFormat` rejects a
/// mismatch at compile time, which is what stops `%d` being handed a
/// 64-bit value.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RawPutChar`, `RawIOInit`
///
/// EXAMPLES:
/// ```zig
/// _ = sys.RawDoFmt("%-14s %08x %ld\n", &args, &putCh, ctx);
/// ```
pub fn RawDoFmt(_: *ExecBase, format_string: [*:0]const u8, data_stream: ?*const anyopaque, put_ch_proc: ?PutChProc, put_ch_data: ?*anyopaque) ?*const anyopaque {
    return _rawio.format(format_string, data_stream, put_ch_proc, put_ch_data);
}
