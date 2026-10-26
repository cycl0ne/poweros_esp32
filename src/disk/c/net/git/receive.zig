// SPDX-License-Identifier: MIT
//! A pack as it arrives: each piece written to a sink at once, its head
//! checked, the SHA-1 running over everything but the last 20 bytes seen
//! so far - which, when the stream ends, are the trailer it must match.

const _git = @import("_git.zig");
const pack = @import("pack.zig");
const Id = _git.Id;
const CryptoBase = @import("sdk").interface.crypto.CryptoBase;

/// A pack received whole.
pub const Received = struct {
    /// Its entries, as its head says.
    count: u32,
    /// Its SHA-1, as its trailer holds it: the name git gives the pack.
    checksum: Id,
    bytes: u64,
};

pub const Receiver = struct {
    sink: _git.Sink,
    sha: _git.Sha1,
    head: [pack.header_bytes]u8 = undefined,
    head_length: usize = 0,
    /// The last bytes seen, held back from the SHA-1 until more come.
    held: [pack.trailer_bytes]u8 = undefined,
    held_length: usize = 0,
    total: u64 = 0,
    sink_failed: bool = false,

    pub fn start(cb: *CryptoBase, sink: _git.Sink) Receiver {
        return .{ .sink = sink, .sha = _git.Sha1.start(cb) };
    }

    /// The next piece: false when the sink failed or the head is no
    /// pack's.
    pub fn take(receiver: *Receiver, bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        if (!receiver.sink.put(bytes)) {
            receiver.sink_failed = true;
            return false;
        }
        receiver.total += bytes.len;
        if (receiver.head_length < receiver.head.len) {
            const count = @min(bytes.len, receiver.head.len - receiver.head_length);
            @memcpy(receiver.head[receiver.head_length..][0..count], bytes[0..count]);
            receiver.head_length += count;
            if (receiver.head_length == receiver.head.len and pack.parseHeader(&receiver.head) == null) return false;
        }
        // What is no longer among the last 20 bytes goes into the SHA-1.
        const keep = receiver.held.len;
        if (bytes.len >= keep) {
            receiver.sha.update(receiver.held[0..receiver.held_length]);
            receiver.sha.update(bytes[0 .. bytes.len - keep]);
            @memcpy(&receiver.held, bytes[bytes.len - keep ..]);
            receiver.held_length = keep;
        } else {
            const total = receiver.held_length + bytes.len;
            const out = if (total > keep) total - keep else 0;
            receiver.sha.update(receiver.held[0..out]);
            const left = receiver.held_length - out;
            var moved: [pack.trailer_bytes]u8 = undefined;
            @memcpy(moved[0..left], receiver.held[out..receiver.held_length]);
            @memcpy(moved[left..][0..bytes.len], bytes);
            receiver.held_length = left + bytes.len;
            @memcpy(receiver.held[0..receiver.held_length], moved[0..receiver.held_length]);
        }
        return true;
    }

    /// The pack's end: what it was, or null when it is cut short or its
    /// trailer is not its SHA-1.
    pub fn finish(receiver: *Receiver) ?Received {
        if (receiver.head_length < receiver.head.len or receiver.held_length < receiver.held.len) return null;
        const count = pack.parseHeader(&receiver.head) orelse return null;
        const sum = receiver.sha.finish();
        if (!_git.same(&sum, &receiver.held)) return null;
        return .{ .count = count, .checksum = sum, .bytes = receiver.total };
    }
};
