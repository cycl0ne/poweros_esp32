// SPDX-License-Identifier: MIT
//! The unpacking engine: a DEFLATE stream (RFC 1951) in its wrapping read
//! out of whatever input a call is given and decoded straight into the
//! caller's output, stopping wherever either runs out and going on from
//! there at the next call.
//!
//! **Stopping anywhere** is what the state's `mode` is for: each step of
//! the format - a header, a block's first bits, a table's lengths, a
//! symbol, a length's extra bits, a distance, the copy of a repeat, the
//! trailer - is a mode, and a mode takes the bits it needs or none at
//! all. The bits not yet used wait in `hold` from one call to the next.
//! Input is taken a byte at a time, and only when a step needs it, so
//! when the stream ends nothing past it has been taken: `total_in` is the
//! stream's own length, which is how a reader of a git pack or a zip file
//! finds the next thing behind it.
//!
//! **The output is the caller's buffer.** A repeat copies from what was
//! written before it; when that lies in an earlier call's output, it is
//! in the window - the last 32 KiB written, kept in the state when a call
//! returns before the stream's end. A stream unpacked in one call
//! (Uncompress) never needs the window, and never gets one.
//!
//! The checksum of the wrapping runs over the output when a call returns
//! and when the trailer is reached; the trailer is compared, and a
//! mismatch is corrupt data like any other.

const sdk = @import("sdk");
const exec = sdk.exec;
const compression = sdk.compression;
const ExecBase = sdk.interface.exec.ExecBase;
const _table = @import("_table.zig");
const _checksum = @import("../checksum/_checksum.zig");

/// What `state` points at in a Stream that InitInflate set up, first.
pub const magic: u32 = 0x494E_464C; // "INFL"

/// How far back a repeat may reach.
pub const window_size = 32 * 1024;

pub const Mode = enum(u8) {
    /// zlib or gzip: the first two bytes.
    header,
    /// gzip: CM and FLG.
    gzip_method,
    /// gzip: bytes skipped - MTIME, XFL and OS, then FEXTRA's data.
    gzip_skip,
    gzip_extra_length,
    gzip_name,
    gzip_comment,
    gzip_header_crc,
    /// A block's first three bits.
    block,
    stored_length,
    stored_copy,
    /// A dynamic block: HLIT, HDIST and HCLEN.
    table_counts,
    /// The lengths of the code-length code.
    code_lengths,
    /// The literal/length and distance codes' lengths.
    lengths,
    /// The extra bits of a repeated length.
    lengths_repeat,
    /// A literal/length symbol.
    codes,
    /// A literal read with no room for it: the byte in `length`.
    literal,
    length_extra,
    distance,
    distance_extra,
    /// A repeat being copied.
    match,
    /// zlib's Adler-32, or gzip's CRC-32.
    check,
    /// gzip's length.
    size,
    done,
    bad,
};

pub const State = struct {
    magic: u32 = magic,
    /// FORMAT_RAW, FORMAT_ZLIB or FORMAT_GZIP; FORMAT_AUTO until the
    /// header says which.
    format: u32,
    mode: Mode,
    /// The bits taken from the input and not yet used, the first the
    /// lowest.
    hold: u64 = 0,
    bits: u32 = 0,
    /// The block being read is the stream's last.
    last: bool = false,
    /// gzip: the header's flags, those still to be gone through.
    gzip_flags: u8 = 0,
    /// A stored block's bytes left, a gzip field's bytes left, or a
    /// repeat's length.
    length: u32 = 0,
    distance: u32 = 0,
    extra: u32 = 0,
    /// A dynamic block's counts, and the lengths read so far.
    literal_count: u32 = 0,
    distance_count: u32 = 0,
    code_count: u32 = 0,
    have: u32 = 0,
    repeat: u16 = 0,
    lengths: [320]u8 = undefined,
    /// The block's codes: the fixed ones, or these made from its table.
    literal_code: *const _table.Code = &_table.fixed_literal,
    distance_code: *const _table.Code = &_table.fixed_distance,
    own_literal: _table.Code = undefined,
    own_distance: _table.Code = undefined,
    length_code: _table.Code = undefined,
    /// The wrapping's checksum of the output so far.
    check: u32 = 0,
    /// The output before this call: the last 32 KiB of it, from the
    /// first call that returned before the end.
    window: ?[*]u8 = null,
    window_have: u32 = 0,
    window_next: u32 = 0,
    /// Everything written, for gzip's length.
    written: u64 = 0,
};

/// The inflate state of `stream`, or null when the Stream is too small
/// or was not set up by InitInflate (or has been ended).
pub fn of(stream: *compression.Stream) ?*State {
    if (stream.size < @sizeOf(compression.Stream)) return null;
    const raw = stream.state orelse return null;
    const state: *State = @ptrCast(@alignCast(raw));
    return if (state.magic == magic) state else null;
}

/// A state set up for `format`, which the caller has checked.
pub fn begin(state: *State, format: u32) void {
    state.* = .{
        .format = format,
        .mode = if (format == compression.FORMAT_RAW) .block else .header,
    };
}

const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const distance_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const distance_extra = [30]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
/// The order the code-length code's lengths come in.
const length_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

const gzip_text: u8 = 1 << 0;
const gzip_header_crc: u8 = 1 << 1;
const gzip_extra: u8 = 1 << 2;
const gzip_name: u8 = 1 << 3;
const gzip_comment: u8 = 1 << 4;

/// One call's input and output, as the steps take and write them.
const Call = struct {
    state: *State,
    input: []const u8,
    output: []u8,
    written: usize = 0,
    /// Where the checksum has run to in `output`.
    checked: usize = 0,
    finish: bool,

    /// At least `count` bits in `hold`, a byte at a time; false when the
    /// input runs out first.
    fn need(call: *Call, count: u32) bool {
        while (call.state.bits < count) {
            if (!call.pull()) return false;
        }
        return true;
    }

    fn pull(call: *Call) bool {
        if (call.input.len == 0) return false;
        call.state.hold |= @as(u64, call.input[0]) << @intCast(call.state.bits);
        call.state.bits += 8;
        call.input = call.input[1..];
        return true;
    }

    fn take(call: *Call, count: u32) u32 {
        const value: u32 = @intCast(call.state.hold & ((@as(u64, 1) << @intCast(count)) - 1));
        call.state.hold >>= @intCast(count);
        call.state.bits -= count;
        return value;
    }

    /// The bits to the next byte's start dropped.
    fn toByte(call: *Call) void {
        _ = call.take(call.state.bits & 7);
    }

    fn room(call: *Call) usize {
        return call.output.len - call.written;
    }

    fn put(call: *Call, byte: u8) void {
        call.output[call.written] = byte;
        call.written += 1;
    }

    /// What a step that has run out of input answers.
    fn starved(call: *Call) i32 {
        return if (call.finish) compression.COMPRESSERR_TRUNCATED else compression.COMPRESS_OK;
    }

    fn bad(call: *Call) i32 {
        call.state.mode = .bad;
        return compression.COMPRESSERR_DATA;
    }

    /// The next symbol of `code`, taking more input while the bits at
    /// hand do not finish it; null when the input runs out first, and
    /// `corrupt` set when the bits are no code.
    fn symbol(call: *Call, code: *const _table.Code, corrupt: *bool) ?u16 {
        while (true) {
            const found = _table.find(code, call.state.hold, call.state.bits);
            if (found.corrupt) {
                corrupt.* = true;
                return null;
            }
            if (found.length != 0) {
                _ = call.take(found.length);
                return found.symbol;
            }
            if (!call.pull()) return null;
        }
    }

    /// The checksum carried over what has been written since it last ran.
    fn sum(call: *Call) void {
        const fresh = call.output[call.checked..call.written];
        call.checked = call.written;
        switch (call.state.format) {
            compression.FORMAT_ZLIB => call.state.check = _checksum.adler32(call.state.check, fresh),
            compression.FORMAT_GZIP => call.state.check = _checksum.crc32(call.state.check, fresh),
            else => {},
        }
    }

    /// The mode after a block's end.
    fn blockEnd(call: *Call) Mode {
        if (!call.state.last) return .block;
        call.toByte();
        call.sum();
        return if (call.state.format == compression.FORMAT_RAW) .done else .check;
    }

    /// The byte `distance` back from the next one written, from this
    /// call's output or from the window.
    fn behind(call: *Call, distance: u32) u8 {
        if (distance <= call.written) return call.output[call.written - distance];
        const back = distance - @as(u32, @intCast(call.written));
        const window = call.state.window.?;
        return window[(call.state.window_next -% back) & (window_size - 1)];
    }

    /// The stream run on until it ends, the input runs out, the output is
    /// full, or the data turns out corrupt.
    fn go(call: *Call) i32 {
        const state = call.state;
        while (true) switch (state.mode) {
            .header => {
                if (!call.need(16)) return call.starved();
                const first: u8 = @truncate(state.hold);
                const second: u8 = @truncate(state.hold >> 8);
                if (state.format == compression.FORMAT_AUTO) {
                    state.format = if (first == 0x1F and second == 0x8B) compression.FORMAT_GZIP else compression.FORMAT_ZLIB;
                }
                if (state.format == compression.FORMAT_GZIP) {
                    if (first != 0x1F or second != 0x8B) return call.bad();
                    _ = call.take(16);
                    state.check = 0;
                    state.mode = .gzip_method;
                } else {
                    // Deflate, a window of 32 KiB at most, the header's own
                    // check, and no preset dictionary.
                    const header = @as(u16, first) << 8 | second;
                    if (first & 0x0F != 8 or first >> 4 > 7 or header % 31 != 0 or second & 0x20 != 0) return call.bad();
                    _ = call.take(16);
                    state.check = 1;
                    state.mode = .block;
                }
            },
            .gzip_method => {
                if (!call.need(16)) return call.starved();
                const method = call.take(8);
                const flags: u8 = @intCast(call.take(8));
                if (method != 8 or flags & 0xE0 != 0) return call.bad();
                state.gzip_flags = flags & ~gzip_text;
                // MTIME, XFL and OS.
                state.length = 6;
                state.mode = .gzip_skip;
            },
            .gzip_skip => {
                while (state.length > 0) : (state.length -= 1) {
                    if (!call.need(8)) return call.starved();
                    _ = call.take(8);
                }
                state.mode = call.gzipNext();
            },
            .gzip_extra_length => {
                if (!call.need(16)) return call.starved();
                state.length = call.take(16);
                state.mode = .gzip_skip;
            },
            .gzip_name, .gzip_comment => {
                while (true) {
                    if (!call.need(8)) return call.starved();
                    if (call.take(8) == 0) break;
                }
                state.mode = call.gzipNext();
            },
            .gzip_header_crc => {
                if (!call.need(16)) return call.starved();
                _ = call.take(16);
                state.mode = .block;
            },
            .block => {
                if (!call.need(3)) return call.starved();
                state.last = call.take(1) == 1;
                switch (call.take(2)) {
                    0 => {
                        call.toByte();
                        state.mode = .stored_length;
                    },
                    1 => {
                        state.literal_code = &_table.fixed_literal;
                        state.distance_code = &_table.fixed_distance;
                        state.mode = .codes;
                    },
                    2 => state.mode = .table_counts,
                    else => return call.bad(),
                }
            },
            .stored_length => {
                if (!call.need(32)) return call.starved();
                const length = call.take(16);
                const complement = call.take(16);
                if (length != ~complement & 0xFFFF) return call.bad();
                state.length = length;
                state.mode = .stored_copy;
            },
            .stored_copy => {
                while (state.length > 0) {
                    if (call.room() == 0) return compression.COMPRESS_OK;
                    if (call.input.len == 0) return call.starved();
                    const count = @min(state.length, call.input.len, call.room());
                    @memcpy(call.output[call.written..][0..count], call.input[0..count]);
                    call.written += count;
                    call.input = call.input[count..];
                    state.length -= @intCast(count);
                }
                state.mode = call.blockEnd();
            },
            .table_counts => {
                if (!call.need(14)) return call.starved();
                state.literal_count = call.take(5) + 257;
                state.distance_count = call.take(5) + 1;
                state.code_count = call.take(4) + 4;
                if (state.literal_count > 286 or state.distance_count > 30) return call.bad();
                state.have = 0;
                state.mode = .code_lengths;
            },
            .code_lengths => {
                while (state.have < state.code_count) : (state.have += 1) {
                    if (!call.need(3)) return call.starved();
                    state.lengths[length_order[state.have]] = @intCast(call.take(3));
                }
                for (length_order[state.code_count..]) |index| state.lengths[index] = 0;
                if (!_table.build(&state.length_code, state.lengths[0..19])) return call.bad();
                state.have = 0;
                state.mode = .lengths;
            },
            .lengths => {
                const total = state.literal_count + state.distance_count;
                while (state.have < total) {
                    var corrupt = false;
                    const got = call.symbol(&state.length_code, &corrupt) orelse {
                        return if (corrupt) call.bad() else call.starved();
                    };
                    if (got < 16) {
                        state.lengths[state.have] = @intCast(got);
                        state.have += 1;
                    } else {
                        state.repeat = got;
                        state.mode = .lengths_repeat;
                        break;
                    }
                } else {
                    // A block that cannot end is no block.
                    if (state.lengths[256] == 0) return call.bad();
                    if (!_table.build(&state.own_literal, state.lengths[0..state.literal_count])) return call.bad();
                    if (!_table.build(&state.own_distance, state.lengths[state.literal_count..total])) return call.bad();
                    state.literal_code = &state.own_literal;
                    state.distance_code = &state.own_distance;
                    state.mode = .codes;
                }
            },
            .lengths_repeat => {
                const extra: u32 = switch (state.repeat) {
                    16 => 2,
                    17 => 3,
                    else => 7,
                };
                if (!call.need(extra)) return call.starved();
                const count = call.take(extra) + @as(u32, if (state.repeat == 18) 11 else 3);
                var value: u8 = 0;
                if (state.repeat == 16) {
                    if (state.have == 0) return call.bad();
                    value = state.lengths[state.have - 1];
                }
                if (state.have + count > state.literal_count + state.distance_count) return call.bad();
                @memset(state.lengths[state.have..][0..count], value);
                state.have += count;
                state.mode = .lengths;
            },
            .codes => {
                // The symbol is read even with no room: a block's end
                // needs none, and the stream's end comes behind it.
                var corrupt = false;
                const got = call.symbol(state.literal_code, &corrupt) orelse {
                    return if (corrupt) call.bad() else call.starved();
                };
                if (got < 256) {
                    if (call.room() != 0) {
                        call.put(@intCast(got));
                    } else {
                        state.length = got;
                        state.mode = .literal;
                    }
                } else if (got == 256) {
                    state.mode = call.blockEnd();
                } else {
                    const index = got - 257;
                    if (index >= length_base.len) return call.bad();
                    state.length = length_base[index];
                    state.extra = length_extra[index];
                    state.mode = .length_extra;
                }
            },
            .literal => {
                if (call.room() == 0) return compression.COMPRESS_OK;
                call.put(@intCast(state.length));
                state.mode = .codes;
            },
            .length_extra => {
                if (!call.need(state.extra)) return call.starved();
                state.length += call.take(state.extra);
                state.mode = .distance;
            },
            .distance => {
                var corrupt = false;
                const got = call.symbol(state.distance_code, &corrupt) orelse {
                    return if (corrupt) call.bad() else call.starved();
                };
                if (got >= distance_base.len) return call.bad();
                state.distance = distance_base[got];
                state.extra = distance_extra[got];
                state.mode = .distance_extra;
            },
            .distance_extra => {
                if (!call.need(state.extra)) return call.starved();
                state.distance += call.take(state.extra);
                // Back no further than the stream has come.
                if (state.distance > state.window_have + call.written) return call.bad();
                state.mode = .match;
            },
            .match => {
                while (state.length > 0) : (state.length -= 1) {
                    if (call.room() == 0) return compression.COMPRESS_OK;
                    call.put(call.behind(state.distance));
                }
                state.mode = .codes;
            },
            .check => {
                if (!call.need(32)) return call.starved();
                const said = if (state.format == compression.FORMAT_ZLIB)
                    @byteSwap(call.take(32))
                else
                    call.take(32);
                if (said != state.check) return call.bad();
                state.mode = if (state.format == compression.FORMAT_GZIP) .size else .done;
            },
            .size => {
                if (!call.need(32)) return call.starved();
                const said = call.take(32);
                if (said != @as(u32, @truncate(state.written + call.written))) return call.bad();
                state.mode = .done;
            },
            .done => return compression.COMPRESS_END,
            .bad => return compression.COMPRESSERR_DATA,
        };
    }

    /// The gzip header's next field, by the flags not yet gone through.
    fn gzipNext(call: *Call) Mode {
        const state = call.state;
        if (state.gzip_flags & gzip_extra != 0) {
            state.gzip_flags &= ~gzip_extra;
            return .gzip_extra_length;
        }
        if (state.gzip_flags & gzip_name != 0) {
            state.gzip_flags &= ~gzip_name;
            return .gzip_name;
        }
        if (state.gzip_flags & gzip_comment != 0) {
            state.gzip_flags &= ~gzip_comment;
            return .gzip_comment;
        }
        if (state.gzip_flags & gzip_header_crc != 0) {
            state.gzip_flags &= ~gzip_header_crc;
            return .gzip_header_crc;
        }
        return .block;
    }
};

/// The stream in `stream` run on as far as its input and output let it.
/// The stream's pointers, counts and totals are moved on by what was
/// taken and written; the last 32 KiB written go into the window when
/// the stream has not ended, allocated through `sys` the first time.
pub fn run(state: *State, stream: *compression.Stream, finish: bool, sys: *ExecBase) i32 {
    const input: []const u8 = if (stream.next_in) |next| next[0..stream.avail_in] else &.{};
    const output: []u8 = if (stream.next_out) |next| next[0..stream.avail_out] else &.{};
    var call: Call = .{ .state = state, .input = input, .output = output, .finish = finish };
    var result = call.go();
    if (state.mode != .done and state.mode != .bad) call.sum();

    const taken = input.len - call.input.len;
    if (taken != 0) stream.next_in = input.ptr + taken;
    stream.avail_in -= @intCast(taken);
    stream.total_in += taken;
    if (call.written != 0) stream.next_out = output.ptr + call.written;
    stream.avail_out -= @intCast(call.written);
    stream.total_out += call.written;
    state.written += call.written;
    if (state.format != compression.FORMAT_AUTO) stream.format = state.format;

    if (state.mode != .done and state.mode != .bad and call.written != 0) {
        if (!keep(state, output[0..call.written], sys)) result = compression.COMPRESSERR_MEMORY;
    }
    return result;
}

/// The last 32 KiB of `written` into the window, which comes into being
/// here the first time; false when it cannot be had.
fn keep(state: *State, written: []const u8, sys: *ExecBase) bool {
    const window = state.window orelse made: {
        const memory = sys.AllocVec(window_size, exec.MEMF_ANY) orelse return false;
        const made: [*]u8 = @ptrCast(memory);
        state.window = made;
        break :made made;
    };
    if (written.len >= window_size) {
        @memcpy(window[0..window_size], written[written.len - window_size ..]);
        state.window_next = 0;
        state.window_have = window_size;
        return true;
    }
    var rest = written;
    while (rest.len > 0) {
        const count = @min(rest.len, window_size - state.window_next);
        @memcpy(window[state.window_next..][0..count], rest[0..count]);
        state.window_next = (state.window_next + @as(u32, @intCast(count))) & (window_size - 1);
        rest = rest[count..];
    }
    state.window_have = @min(window_size, state.window_have + @as(u32, @intCast(written.len)));
    return true;
}

/// The window freed, if there is one.
pub fn end(state: *State, sys: *ExecBase) void {
    if (state.window) |window| sys.FreeVec(window);
    state.window = null;
}
