// SPDX-License-Identifier: MIT
//! What every part of Git uses: an object's id and its hex, SHA-1 through
//! crypto.library, big-endian numbers in git's files, and text put into
//! a buffer.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CryptoBase = sdk.interface.crypto.CryptoBase;

/// An object's id: the SHA-1 of its header and body.
pub const Id = [20]u8;

pub const zero_id: Id = @splat(0);

/// `id` in lower-case hex, 40 characters.
pub fn hexOf(id: *const Id, into: *[40]u8) void {
    const digits = "0123456789abcdef";
    for (id, 0..) |byte, index| {
        into[index * 2] = digits[byte >> 4];
        into[index * 2 + 1] = digits[byte & 15];
    }
}

fn digit(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// The id 40 hex digits at the start of `text` write; null when they are
/// not.
pub fn idOf(text: []const u8) ?Id {
    if (text.len < 40) return null;
    var id: Id = undefined;
    for (&id, 0..) |*byte, index| {
        const high = digit(text[index * 2]) orelse return null;
        const low = digit(text[index * 2 + 1]) orelse return null;
        byte.* = high << 4 | low;
    }
    return id;
}

/// SHA-1, a piece at a time, on crypto.library.
pub const Sha1 = struct {
    cb: *CryptoBase,
    context: crypto.HashContext = .{},

    pub fn start(cb: *CryptoBase) Sha1 {
        var sha: Sha1 = .{ .cb = cb };
        _ = cb.InitHash(&sha.context, crypto.HASH_SHA1);
        return sha;
    }

    pub fn update(sha: *Sha1, data: []const u8) void {
        if (data.len != 0) sha.cb.UpdateHash(&sha.context, data.ptr, @intCast(data.len));
    }

    pub fn finish(sha: *Sha1) Id {
        var id: Id = undefined;
        _ = sha.cb.FinishHash(&sha.context, &id);
        return id;
    }
};

/// The SHA-1 of `data`.
pub fn sha1Of(cb: *CryptoBase, data: []const u8) Id {
    var sha = Sha1.start(cb);
    sha.update(data);
    return sha.finish();
}

pub fn get16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

pub fn get32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

pub fn put16(into: []u8, value: u16) void {
    into[0] = @intCast(value >> 8);
    into[1] = @truncate(value);
}

pub fn put32(into: []u8, value: u32) void {
    into[0] = @intCast(value >> 24);
    into[1] = @truncate(value >> 16);
    into[2] = @truncate(value >> 8);
    into[3] = @truncate(value);
}

/// Bytes put one piece after another into a buffer, remembering whether
/// any did not fit.
pub const Out = struct {
    into: []u8,
    at: usize = 0,
    overflow: bool = false,

    pub fn put(out: *Out, bytes: []const u8) void {
        if (out.at + bytes.len > out.into.len) {
            out.overflow = true;
            return;
        }
        @memcpy(out.into[out.at..][0..bytes.len], bytes);
        out.at += bytes.len;
    }

    pub fn byte(out: *Out, value: u8) void {
        out.put(&.{value});
    }

    /// A number in decimal.
    pub fn decimal(out: *Out, value: u64) void {
        var digits: [20]u8 = undefined;
        var count: usize = 0;
        var rest = value;
        while (true) {
            digits[digits.len - 1 - count] = '0' + @as(u8, @intCast(rest % 10));
            count += 1;
            rest /= 10;
            if (rest == 0) break;
        }
        out.put(digits[digits.len - count ..]);
    }

    /// An id in hex.
    pub fn hex(out: *Out, id: *const Id) void {
        var text: [40]u8 = undefined;
        hexOf(id, &text);
        out.put(&text);
    }

    pub fn written(out: *const Out) []u8 {
        return out.into[0..out.at];
    }
};

/// Where bytes go a piece at a time - a file, a buffer, a connection:
/// false when they could not.
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, data: []const u8) bool,

    pub fn put(sink: Sink, data: []const u8) bool {
        return sink.write(sink.context, data);
    }
};

/// Bytes written to a sink a buffer at a time, the SHA-1 running over
/// them, for the files git ends with their own SHA-1.
pub const Emit = struct {
    sink: Sink,
    sha: Sha1,
    buffer: [1024]u8 = undefined,
    at: usize = 0,
    failed: bool = false,

    pub fn put(emit: *Emit, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            if (emit.at == emit.buffer.len) emit.flush();
            const count = @min(rest.len, emit.buffer.len - emit.at);
            @memcpy(emit.buffer[emit.at..][0..count], rest[0..count]);
            emit.at += count;
            rest = rest[count..];
        }
    }

    pub fn be32(emit: *Emit, value: u32) void {
        var bytes: [4]u8 = undefined;
        put32(&bytes, value);
        emit.put(&bytes);
    }

    pub fn be16(emit: *Emit, value: u16) void {
        var bytes: [2]u8 = undefined;
        put16(&bytes, value);
        emit.put(&bytes);
    }

    fn flush(emit: *Emit) void {
        emit.sha.update(emit.buffer[0..emit.at]);
        if (!emit.failed and !emit.sink.put(emit.buffer[0..emit.at])) emit.failed = true;
        emit.at = 0;
    }

    /// What is left written, and the SHA-1 of everything before it, as
    /// git's files end: false when the sink failed anywhere.
    pub fn finish(emit: *Emit) bool {
        emit.flush();
        const sum = emit.sha.finish();
        if (!emit.failed and !emit.sink.put(&sum)) emit.failed = true;
        return !emit.failed;
    }
};

/// Whether `text` starts with `prefix`.
pub fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and same(text[0..prefix.len], prefix);
}

/// Whether `text` ends with `suffix`.
pub fn endsWith(text: []const u8, suffix: []const u8) bool {
    return text.len >= suffix.len and same(text[text.len - suffix.len ..], suffix);
}

/// Whether two byte strings are equal.
pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// `items` sorted in place by `before` (a heap sort: no memory, and no
/// worst case to fear).
pub fn heapSort(comptime T: type, items: []T, context: anytype, comptime before: fn (@TypeOf(context), *const T, *const T) bool) void {
    if (items.len < 2) return;
    var start = items.len / 2;
    while (start > 0) {
        start -= 1;
        siftDown(T, items, start, items.len, context, before);
    }
    var end = items.len;
    while (end > 1) {
        end -= 1;
        const top = items[0];
        items[0] = items[end];
        items[end] = top;
        siftDown(T, items, 0, end, context, before);
    }
}

fn siftDown(comptime T: type, items: []T, first: usize, end: usize, context: anytype, comptime before: fn (@TypeOf(context), *const T, *const T) bool) void {
    var root = first;
    while (true) {
        var child = root * 2 + 1;
        if (child >= end) return;
        if (child + 1 < end and before(context, &items[child], &items[child + 1])) child += 1;
        if (!before(context, &items[root], &items[child])) return;
        const held = items[root];
        items[root] = items[child];
        items[child] = held;
        root = child;
    }
}

/// How `a` sorts against `b`, byte by byte, the shorter first when one
/// starts the other.
pub fn order(a: []const u8, b: []const u8) enum { less, equal, greater } {
    const shorter = @min(a.len, b.len);
    for (a[0..shorter], b[0..shorter]) |x, y| {
        if (x < y) return .less;
        if (x > y) return .greater;
    }
    if (a.len < b.len) return .less;
    if (a.len > b.len) return .greater;
    return .equal;
}
