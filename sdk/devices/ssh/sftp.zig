// SPDX-License-Identifier: MIT
//! SFTP, version 3 (draft-ietf-secsh-filexfer-02, what OpenSSH speaks): the
//! file protocol that runs in an SSH session's `sftp` subsystem, and under
//! scp too since OpenSSH 9. ShellServer SSH serves it, C:net/SCP speaks it;
//! this is what both read and write.
//!
//! **A packet** is its length (a u32, not counting itself), its type, and
//! for every request a u32 id the answer carries back. Numbers go most
//! significant byte first; a string is a u32 length and its bytes. The
//! client begins with INIT and the server answers VERSION; then requests -
//! OPEN, READ, WRITE, CLOSE, STAT, OPENDIR, READDIR, REMOVE, MKDIR, RMDIR,
//! RENAME, REALPATH, SETSTAT - each answered by STATUS, HANDLE, DATA, NAME
//! or ATTRS. A client may send many requests before it reads an answer.
//!
//! **Attributes** are a u32 of flags saying which follow: the size (u64),
//! the owner (two u32), the permissions (a u32 - Unix's mode, the type in
//! its top bits), the times (two u32 seconds since 1970, access and
//! modification).

/// The version spoken.
pub const version: u32 = 3;

// Packet types.
pub const FXP_INIT: u8 = 1;
pub const FXP_VERSION: u8 = 2;
pub const FXP_OPEN: u8 = 3;
pub const FXP_CLOSE: u8 = 4;
pub const FXP_READ: u8 = 5;
pub const FXP_WRITE: u8 = 6;
pub const FXP_LSTAT: u8 = 7;
pub const FXP_FSTAT: u8 = 8;
pub const FXP_SETSTAT: u8 = 9;
pub const FXP_FSETSTAT: u8 = 10;
pub const FXP_OPENDIR: u8 = 11;
pub const FXP_READDIR: u8 = 12;
pub const FXP_REMOVE: u8 = 13;
pub const FXP_MKDIR: u8 = 14;
pub const FXP_RMDIR: u8 = 15;
pub const FXP_REALPATH: u8 = 16;
pub const FXP_STAT: u8 = 17;
pub const FXP_RENAME: u8 = 18;
pub const FXP_READLINK: u8 = 19;
pub const FXP_SYMLINK: u8 = 20;
pub const FXP_STATUS: u8 = 101;
pub const FXP_HANDLE: u8 = 102;
pub const FXP_DATA: u8 = 103;
pub const FXP_NAME: u8 = 104;
pub const FXP_ATTRS: u8 = 105;
pub const FXP_EXTENDED: u8 = 200;
pub const FXP_EXTENDED_REPLY: u8 = 201;

// STATUS codes.
pub const FX_OK: u32 = 0;
pub const FX_EOF: u32 = 1;
pub const FX_NO_SUCH_FILE: u32 = 2;
pub const FX_PERMISSION_DENIED: u32 = 3;
pub const FX_FAILURE: u32 = 4;
pub const FX_BAD_MESSAGE: u32 = 5;
pub const FX_NO_CONNECTION: u32 = 6;
pub const FX_CONNECTION_LOST: u32 = 7;
pub const FX_OP_UNSUPPORTED: u32 = 8;

// OPEN's flags.
pub const FXF_READ: u32 = 0x01;
pub const FXF_WRITE: u32 = 0x02;
pub const FXF_APPEND: u32 = 0x04;
pub const FXF_CREAT: u32 = 0x08;
pub const FXF_TRUNC: u32 = 0x10;
pub const FXF_EXCL: u32 = 0x20;

// Which attributes follow.
pub const ATTR_SIZE: u32 = 0x01;
pub const ATTR_UIDGID: u32 = 0x02;
pub const ATTR_PERMISSIONS: u32 = 0x04;
pub const ATTR_ACMODTIME: u32 = 0x08;
pub const ATTR_EXTENDED: u32 = 0x8000_0000;

// The permissions' type bits, and the owner's.
pub const S_IFMT: u32 = 0o170000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IRUSR: u32 = 0o400;
pub const S_IWUSR: u32 = 0o200;
pub const S_IXUSR: u32 = 0o100;

/// The largest packet taken: a WRITE of 32 KiB, as OpenSSH sends, and
/// its header with room to spare.
pub const packet_max: u32 = 34 * 1024;
/// The most data one READ answers.
pub const read_max: u32 = 32 * 1024;

/// A file's attributes, those `flags` says are there.
pub const Attrs = struct {
    flags: u32 = 0,
    size: u64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    permissions: u32 = 0,
    atime: u32 = 0,
    mtime: u32 = 0,

    pub fn isDir(attrs: Attrs) bool {
        return attrs.flags & ATTR_PERMISSIONS != 0 and attrs.permissions & S_IFMT == S_IFDIR;
    }

    pub fn write(attrs: Attrs, writer: *Writer) void {
        writer.uint32(attrs.flags & ~ATTR_EXTENDED);
        if (attrs.flags & ATTR_SIZE != 0) writer.uint64(attrs.size);
        if (attrs.flags & ATTR_UIDGID != 0) {
            writer.uint32(attrs.uid);
            writer.uint32(attrs.gid);
        }
        if (attrs.flags & ATTR_PERMISSIONS != 0) writer.uint32(attrs.permissions);
        if (attrs.flags & ATTR_ACMODTIME != 0) {
            writer.uint32(attrs.atime);
            writer.uint32(attrs.mtime);
        }
    }

    /// Attributes read, extended ones passed over.
    pub fn read(reader: *Reader) Attrs {
        var attrs: Attrs = .{ .flags = reader.uint32() };
        if (attrs.flags & ATTR_SIZE != 0) attrs.size = reader.uint64();
        if (attrs.flags & ATTR_UIDGID != 0) {
            attrs.uid = reader.uint32();
            attrs.gid = reader.uint32();
        }
        if (attrs.flags & ATTR_PERMISSIONS != 0) attrs.permissions = reader.uint32();
        if (attrs.flags & ATTR_ACMODTIME != 0) {
            attrs.atime = reader.uint32();
            attrs.mtime = reader.uint32();
        }
        if (attrs.flags & ATTR_EXTENDED != 0) {
            const count = reader.uint32();
            var index: u32 = 0;
            while (index < count and !reader.bad) : (index += 1) {
                _ = reader.string();
                _ = reader.string();
            }
        }
        return attrs;
    }
};

/// A packet read field by field; a field past its end reads as nothing
/// and marks it bad, so a packet is checked once, at the end.
pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    bad: bool = false,

    fn take(reader: *Reader, count: usize) ?[]const u8 {
        if (reader.bad or reader.bytes.len - reader.at < count) {
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

    pub fn uint32(reader: *Reader) u32 {
        const part = reader.take(4) orelse return 0;
        return get32(part);
    }

    pub fn uint64(reader: *Reader) u64 {
        const high: u64 = reader.uint32();
        return high << 32 | reader.uint32();
    }

    pub fn string(reader: *Reader) []const u8 {
        const length = reader.uint32();
        return reader.take(length) orelse &.{};
    }
};

/// A packet written field by field into `bytes`; a field that does not
/// fit marks it full and is not written.
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

    pub fn byte(writer: *Writer, value: u8) void {
        writer.raw(&.{value});
    }

    pub fn uint32(writer: *Writer, value: u32) void {
        var four: [4]u8 = undefined;
        put32(&four, value);
        writer.raw(&four);
    }

    pub fn uint64(writer: *Writer, value: u64) void {
        writer.uint32(@truncate(value >> 32));
        writer.uint32(@truncate(value));
    }

    pub fn string(writer: *Writer, data: []const u8) void {
        writer.uint32(@intCast(data.len));
        writer.raw(data);
    }

    /// A packet begun: room for its length, then its type and, for all but
    /// INIT and VERSION, the id.
    pub fn begin(writer: *Writer, kind: u8, id: ?u32) void {
        writer.at = 0;
        writer.full = false;
        writer.uint32(0);
        writer.byte(kind);
        if (id) |value| writer.uint32(value);
    }

    /// The packet ended: its length written in front. Its bytes.
    pub fn end(writer: *Writer) []const u8 {
        if (writer.full) return &.{};
        put32(writer.bytes[0..4], @intCast(writer.at - 4));
        return writer.bytes[0..writer.at];
    }
};

pub fn get32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

pub fn put32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

/// How long the whole packet at the start of `bytes` is, its length field
/// with it; null until four bytes are there.
pub fn packetLength(bytes: []const u8) ?usize {
    if (bytes.len < 4) return null;
    return @as(usize, get32(bytes[0..4])) + 4;
}
