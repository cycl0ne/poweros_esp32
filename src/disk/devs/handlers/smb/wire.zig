// SPDX-License-Identifier: MIT
//! SMB2's messages on the wire ([MS-SMB2] 2.2): the 64-byte header every
//! message begins with, the commands, and a message's fields read and
//! written one at a time - every number least significant byte first.
//!
//! **Offsets count from the header.** A field that says where a buffer
//! is (a path, a security blob, a negotiate context) counts from the
//! first byte of the message's header, so a message is written into a
//! buffer that begins with its header, and the writer's position is the
//! offset to put in such a field.
//!
//! **A reader or a writer that runs off its bytes** reads zeros or writes
//! nothing from then on and remembers it, so a message is checked once,
//! at its end, instead of field by field.

/// The header's size, which is where every command's own fields begin.
pub const header_size: usize = 64;

/// The first four bytes of a message, and of an encrypted one.
pub const protocol_id = [4]u8{ 0xFE, 'S', 'M', 'B' };
pub const transform_id = [4]u8{ 0xFD, 'S', 'M', 'B' };

pub const Command = enum(u16) {
    negotiate = 0,
    session_setup = 1,
    logoff = 2,
    tree_connect = 3,
    tree_disconnect = 4,
    create = 5,
    close = 6,
    flush = 7,
    read = 8,
    write = 9,
    lock = 10,
    ioctl = 11,
    cancel = 12,
    echo = 13,
    query_directory = 14,
    change_notify = 15,
    query_info = 16,
    set_info = 17,
    oplock_break = 18,
    _,
};

/// The header's flags: an answer, an answer that comes later than its
/// interim one (async), a request that goes on from the one before it in
/// a compound, a signed message.
pub const FLAGS_SERVER_TO_REDIR: u32 = 0x0000_0001;
pub const FLAGS_ASYNC_COMMAND: u32 = 0x0000_0002;
pub const FLAGS_RELATED_OPERATIONS: u32 = 0x0000_0004;
pub const FLAGS_SIGNED: u32 = 0x0000_0008;

/// Where the signature is in the header.
pub const signature_at: usize = 48;

/// The header of a message, as read off the wire or about to be written.
pub const Header = struct {
    credit_charge: u16 = 0,
    /// The NTSTATUS of an answer; 0 in a request.
    status: u32 = 0,
    command: Command = .negotiate,
    /// CreditRequest in a request, CreditResponse in an answer.
    credits: u16 = 0,
    flags: u32 = 0,
    next_command: u32 = 0,
    message_id: u64 = 0,
    /// An async answer's id, which stands where a sync one has the tree's.
    async_id: u64 = 0,
    tree_id: u32 = 0,
    session_id: u64 = 0,
    signature: [16]u8 = @splat(0),

    /// The header at the start of `bytes`, or null when it is no SMB2
    /// header.
    pub fn read(bytes: []const u8) ?Header {
        if (bytes.len < header_size) return null;
        if (!same(bytes[0..4], &protocol_id) or u16At(bytes, 4) != header_size) return null;
        var header: Header = .{
            .credit_charge = u16At(bytes, 6),
            .status = u32At(bytes, 8),
            .command = @enumFromInt(u16At(bytes, 12)),
            .credits = u16At(bytes, 14),
            .flags = u32At(bytes, 16),
            .next_command = u32At(bytes, 20),
            .message_id = u64At(bytes, 24),
            .session_id = u64At(bytes, 40),
        };
        if (header.flags & FLAGS_ASYNC_COMMAND != 0) {
            header.async_id = u64At(bytes, 32);
        } else {
            header.tree_id = u32At(bytes, 36);
        }
        @memcpy(&header.signature, bytes[signature_at..][0..16]);
        return header;
    }

    /// The header written over the first `header_size` bytes of `bytes`,
    /// its signature as it stands.
    pub fn write(header: *const Header, bytes: []u8) void {
        @memcpy(bytes[0..4], &protocol_id);
        put16(bytes, 4, header_size);
        put16(bytes, 6, header.credit_charge);
        put32(bytes, 8, header.status);
        put16(bytes, 12, @intFromEnum(header.command));
        put16(bytes, 14, header.credits);
        put32(bytes, 16, header.flags);
        put32(bytes, 20, header.next_command);
        put64(bytes, 24, header.message_id);
        if (header.flags & FLAGS_ASYNC_COMMAND != 0) {
            put64(bytes, 32, header.async_id);
        } else {
            put32(bytes, 32, 0);
            put32(bytes, 36, header.tree_id);
        }
        put64(bytes, 40, header.session_id);
        @memcpy(bytes[signature_at..][0..16], &header.signature);
    }
};

// --- fields at fixed places ---------------------------------------------------

pub fn u16At(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | @as(u16, bytes[at + 1]) << 8;
}

pub fn u32At(bytes: []const u8, at: usize) u32 {
    return @as(u32, u16At(bytes, at)) | @as(u32, u16At(bytes, at + 2)) << 16;
}

pub fn u64At(bytes: []const u8, at: usize) u64 {
    return @as(u64, u32At(bytes, at)) | @as(u64, u32At(bytes, at + 4)) << 32;
}

pub fn put16(bytes: []u8, at: usize, value: u16) void {
    bytes[at] = @truncate(value);
    bytes[at + 1] = @truncate(value >> 8);
}

pub fn put32(bytes: []u8, at: usize, value: u32) void {
    put16(bytes, at, @truncate(value));
    put16(bytes, at + 2, @truncate(value >> 16));
}

pub fn put64(bytes: []u8, at: usize, value: u64) void {
    put32(bytes, at, @truncate(value));
    put32(bytes, at + 4, @truncate(value >> 32));
}

pub fn same(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| if (a != b) return false;
    return true;
}

// --- a message field by field -------------------------------------------------

/// A message read field by field, from `at`.
pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    bad: bool = false,

    /// `count` bytes from where the reader is, or null (and the reader
    /// bad) when there are not that many.
    pub fn take(reader: *Reader, count: usize) ?[]const u8 {
        if (reader.bad or reader.at > reader.bytes.len or reader.bytes.len - reader.at < count) {
            reader.bad = true;
            return null;
        }
        const part = reader.bytes[reader.at..][0..count];
        reader.at += count;
        return part;
    }

    pub fn byte(reader: *Reader) u8 {
        const part = reader.take(1) orelse return 0;
        return part[0];
    }

    pub fn uint16(reader: *Reader) u16 {
        const part = reader.take(2) orelse return 0;
        return u16At(part, 0);
    }

    pub fn uint32(reader: *Reader) u32 {
        const part = reader.take(4) orelse return 0;
        return u32At(part, 0);
    }

    pub fn uint64(reader: *Reader) u64 {
        const part = reader.take(8) orelse return 0;
        return u64At(part, 0);
    }

    pub fn skip(reader: *Reader, count: usize) void {
        _ = reader.take(count);
    }

    /// `length` bytes at `offset` from the start of the message, where an
    /// offset field says a buffer is; empty for a length of 0, null when
    /// the buffer is not all in the message.
    pub fn bufferAt(reader: *const Reader, offset: usize, length: usize) ?[]const u8 {
        if (length == 0) return &.{};
        if (offset > reader.bytes.len or reader.bytes.len - offset < length) return null;
        return reader.bytes[offset..][0..length];
    }
};

/// A message written field by field into `bytes`, from `at`.
pub const Writer = struct {
    bytes: []u8,
    at: usize = 0,
    full: bool = false,

    pub fn raw(writer: *Writer, data: []const u8) void {
        if (writer.full or writer.bytes.len - writer.at < data.len) {
            writer.full = true;
            return;
        }
        @memcpy(writer.bytes[writer.at..][0..data.len], data);
        writer.at += data.len;
    }

    pub fn zeros(writer: *Writer, count: usize) void {
        if (writer.full or writer.bytes.len - writer.at < count) {
            writer.full = true;
            return;
        }
        @memset(writer.bytes[writer.at..][0..count], 0);
        writer.at += count;
    }

    pub fn byte(writer: *Writer, value: u8) void {
        writer.raw(&.{value});
    }

    pub fn uint16(writer: *Writer, value: u16) void {
        var two: [2]u8 = undefined;
        put16(&two, 0, value);
        writer.raw(&two);
    }

    pub fn uint32(writer: *Writer, value: u32) void {
        var four: [4]u8 = undefined;
        put32(&four, 0, value);
        writer.raw(&four);
    }

    pub fn uint64(writer: *Writer, value: u64) void {
        var eight: [8]u8 = undefined;
        put64(&eight, 0, value);
        writer.raw(&eight);
    }

    /// Zeros up to the next multiple of `boundary` from the start.
    pub fn alignTo(writer: *Writer, boundary: usize) void {
        const over = writer.at % boundary;
        if (over != 0) writer.zeros(boundary - over);
    }

    /// A 16-bit field written over at `at`, which the writer has passed:
    /// a length or an offset known only once what it names is written.
    pub fn patch16(writer: *Writer, at: usize, value: u16) void {
        if (writer.full or at + 2 > writer.at) return;
        put16(writer.bytes, at, value);
    }

    pub fn patch32(writer: *Writer, at: usize, value: u32) void {
        if (writer.full or at + 4 > writer.at) return;
        put32(writer.bytes, at, value);
    }

    pub fn written(writer: *const Writer) []u8 {
        return writer.bytes[0..writer.at];
    }
};

// --- names ---------------------------------------------------------------------

/// `text` (Latin-1) as UTF-16 - which for Latin-1 is each byte widened -
/// written little-endian.
pub fn latin1(writer: *Writer, text: []const u8) void {
    for (text) |char| writer.uint16(char);
}

const testing = @import("std").testing;

test "a header written and read back is the same, sync and async" {
    var bytes: [header_size]u8 = undefined;
    const sync: Header = .{ .credit_charge = 1, .status = 0xC000_0016, .command = .session_setup, .credits = 64, .flags = FLAGS_SIGNED, .message_id = 0x1122_3344_5566_7788, .tree_id = 7, .session_id = 0xAABB_CCDD_0011_2233, .signature = @splat(0x5A) };
    sync.write(&bytes);
    try testing.expectEqualSlices(u8, &protocol_id, bytes[0..4]);
    try testing.expectEqual(@as(u16, 64), u16At(&bytes, 4));
    const back = Header.read(&bytes).?;
    try testing.expectEqual(sync.status, back.status);
    try testing.expectEqual(sync.command, back.command);
    try testing.expectEqual(sync.message_id, back.message_id);
    try testing.expectEqual(sync.tree_id, back.tree_id);
    try testing.expectEqual(sync.session_id, back.session_id);
    try testing.expectEqualSlices(u8, &sync.signature, &back.signature);

    const later: Header = .{ .status = 0x103, .command = .read, .flags = FLAGS_SERVER_TO_REDIR | FLAGS_ASYNC_COMMAND, .async_id = 99 };
    later.write(&bytes);
    const read_back = Header.read(&bytes).?;
    try testing.expectEqual(@as(u64, 99), read_back.async_id);
    try testing.expectEqual(@as(u32, 0), read_back.tree_id);
    bytes[0] = 0xFD;
    try testing.expect(Header.read(&bytes) == null);
}

test "a reader past its end reads zeros and says so; a writer that is full writes nothing" {
    var reader: Reader = .{ .bytes = &.{ 1, 2, 3 } };
    try testing.expectEqual(@as(u16, 0x0201), reader.uint16());
    try testing.expect(!reader.bad);
    try testing.expectEqual(@as(u32, 0), reader.uint32());
    try testing.expect(reader.bad);
    try testing.expect(reader.bufferAt(1, 2) != null);
    try testing.expect(reader.bufferAt(2, 2) == null);

    var room: [6]u8 = @splat(0xEE);
    var writer: Writer = .{ .bytes = &room };
    writer.uint16(0xBEEF);
    writer.byte(1);
    writer.alignTo(4);
    try testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 1, 0 }, writer.written());
    writer.patch16(0, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), u16At(&room, 0));
    writer.uint32(5);
    try testing.expect(writer.full);
    try testing.expectEqual(@as(usize, 4), writer.at);
}
