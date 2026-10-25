// SPDX-License-Identifier: MIT
//! The commands on files ([MS-SMB2] 2.2.13 to 2.2.38, [MS-FSCC]): each
//! request written into a `Request` after its header's room, each answer
//! read from its reply - CREATE, CLOSE, READ, WRITE, FLUSH,
//! QUERY_DIRECTORY, QUERY_INFO, SET_INFO, ECHO - and the information
//! classes the handler asks for and sets.
//!
//! A path is the share's own: UTF-16LE, `\` between its names, no `\` in
//! front; the share's root is the empty path. A time is a FILETIME, 100 ns
//! since 1601 in UTC.

const wire = @import("wire.zig");
const session_area = @import("session.zig");
const Request = session_area.Request;
const Reply = session_area.Reply;

// --- what a CREATE asks for ([MS-SMB2] 2.2.13) -----------------------------------

pub const FILE_READ_DATA: u32 = 0x0000_0001;
pub const FILE_LIST_DIRECTORY: u32 = 0x0000_0001;
pub const FILE_WRITE_DATA: u32 = 0x0000_0002;
pub const FILE_APPEND_DATA: u32 = 0x0000_0004;
pub const FILE_READ_EA: u32 = 0x0000_0008;
pub const FILE_WRITE_EA: u32 = 0x0000_0010;
pub const FILE_READ_ATTRIBUTES: u32 = 0x0000_0080;
pub const FILE_WRITE_ATTRIBUTES: u32 = 0x0000_0100;
pub const DELETE: u32 = 0x0001_0000;
pub const READ_CONTROL: u32 = 0x0002_0000;
pub const SYNCHRONIZE: u32 = 0x0010_0000;

pub const FILE_SHARE_READ: u32 = 0x1;
pub const FILE_SHARE_WRITE: u32 = 0x2;
pub const FILE_SHARE_DELETE: u32 = 0x4;
pub const share_all: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;

pub const FILE_OPEN: u32 = 1;
pub const FILE_CREATE: u32 = 2;
pub const FILE_OPEN_IF: u32 = 3;
pub const FILE_OVERWRITE_IF: u32 = 5;

pub const FILE_DIRECTORY_FILE: u32 = 0x0000_0001;
pub const FILE_NON_DIRECTORY_FILE: u32 = 0x0000_0040;

/// What a CREATE did: CreateAction.
pub const FILE_SUPERSEDED: u32 = 0;
pub const FILE_OPENED: u32 = 1;
pub const FILE_CREATED: u32 = 2;
pub const FILE_OVERWRITTEN: u32 = 3;

/// A file's attributes ([MS-FSCC] 2.6).
pub const ATTR_READONLY: u32 = 0x0001;
pub const ATTR_HIDDEN: u32 = 0x0002;
pub const ATTR_SYSTEM: u32 = 0x0004;
pub const ATTR_DIRECTORY: u32 = 0x0010;
pub const ATTR_ARCHIVE: u32 = 0x0020;
pub const ATTR_NORMAL: u32 = 0x0080;

/// What a CREATE answers with: the handle, and the object as it is.
pub const Object = struct {
    file_id: [16]u8 = @splat(0),
    attributes: u32 = 0,
    created: u64 = 0,
    written: u64 = 0,
    size: u64 = 0,
    allocation: u64 = 0,
    /// FILE_OPENED, FILE_CREATED, FILE_OVERWRITTEN.
    action: u32 = FILE_OPENED,

    pub fn isDir(object: *const Object) bool {
        return object.attributes & ATTR_DIRECTORY != 0;
    }
};

/// CREATE: `path` opened as `disposition` says, with `access`, sharing
/// everything, and no oplock - nothing here keeps a file another client
/// might want.
pub fn create(request: *Request, path: []const u8, access: u32, attributes: u32, disposition: u32, options: u32) void {
    const writer = &request.writer;
    const start = request.starts[request.count - 1];
    writer.uint16(57);
    writer.byte(0); // SecurityFlags
    writer.byte(0); // RequestedOplockLevel: none
    writer.uint32(2); // ImpersonationLevel: impersonation
    writer.zeros(16); // SmbCreateFlags, Reserved
    writer.uint32(access);
    writer.uint32(attributes);
    writer.uint32(share_all);
    writer.uint32(disposition);
    writer.uint32(options);
    writer.uint16(@intCast(writer.at + 12 - start)); // NameOffset
    writer.uint16(@intCast(path.len));
    writer.zeros(8); // no create contexts
    if (path.len == 0) writer.byte(0) else writer.raw(path);
}

/// The object a CREATE's answer describes, or null when it failed or is
/// short.
pub fn created(reply: *const Reply) ?Object {
    if (reply.failed()) return null;
    var reader = reply.body();
    const fields = reader.take(88) orelse return null;
    if (wire.u16At(fields, 0) != 89) return null;
    var object: Object = .{
        .action = wire.u32At(fields, 4),
        .created = wire.u64At(fields, 8),
        .written = wire.u64At(fields, 24),
        .allocation = wire.u64At(fields, 40),
        .size = wire.u64At(fields, 48),
        .attributes = wire.u32At(fields, 56),
    };
    @memcpy(&object.file_id, fields[64..80]);
    return object;
}

/// CLOSE.
pub fn close(request: *Request, file_id: *const [16]u8) void {
    const writer = &request.writer;
    writer.uint16(24);
    writer.uint16(0); // Flags: no attributes after
    writer.uint32(0);
    writer.raw(file_id);
}

/// READ: `length` bytes from `offset`, asked to come right after the
/// answer's own fields.
pub fn read(request: *Request, file_id: *const [16]u8, offset: u64, length: u32) void {
    const writer = &request.writer;
    writer.uint16(49);
    writer.byte(wire.header_size + 16); // Padding: where the data is to be
    writer.byte(0);
    writer.uint32(length);
    writer.uint64(offset);
    writer.raw(file_id);
    writer.uint32(0); // MinimumCount
    writer.uint32(0); // Channel
    writer.uint32(0); // RemainingBytes
    writer.uint16(0); // ReadChannelInfoOffset
    writer.uint16(0); // ReadChannelInfoLength
    writer.byte(0);
}

/// The bytes a READ's answer carries: empty at the end of the file, null
/// when it failed otherwise or is short.
pub fn readData(reply: *const Reply) ?[]const u8 {
    if (reply.status() == @import("sdk").dos.smb.STATUS_END_OF_FILE) return &.{};
    if (reply.failed()) return null;
    var reader = reply.body();
    const fields = reader.take(16) orelse return null;
    if (wire.u16At(fields, 0) != 17) return null;
    return reader.bufferAt(fields[2], wire.u32At(fields, 4));
}

/// WRITE: `data` at `offset`, carried right after the request's own
/// fields; never empty.
pub fn write(request: *Request, file_id: *const [16]u8, offset: u64, data: []const u8) void {
    const writer = &request.writer;
    writer.uint16(49);
    writer.uint16(wire.header_size + 48); // DataOffset
    writer.uint32(@intCast(data.len));
    writer.uint64(offset);
    writer.raw(file_id);
    writer.uint32(0); // Channel
    writer.uint32(0); // RemainingBytes
    writer.uint16(0); // WriteChannelInfoOffset
    writer.uint16(0); // WriteChannelInfoLength
    writer.uint32(0); // Flags
    writer.raw(data);
}

/// The bytes a WRITE's answer says were written, or null when it failed
/// or is short.
pub fn written(reply: *const Reply) ?u32 {
    if (reply.failed()) return null;
    var reader = reply.body();
    const fields = reader.take(16) orelse return null;
    if (wire.u16At(fields, 0) != 17) return null;
    return wire.u32At(fields, 4);
}

/// FLUSH: what the server holds of the file written to its disk.
pub fn flush(request: *Request, file_id: *const [16]u8) void {
    const writer = &request.writer;
    writer.uint16(24);
    writer.uint16(0);
    writer.uint32(0);
    writer.raw(file_id);
}

/// QUERY_DIRECTORY's flags.
pub const RESTART_SCANS: u8 = 0x01;
pub const RETURN_SINGLE_ENTRY: u8 = 0x02;

/// FileDirectoryInformation ([MS-FSCC] 2.4.10): what a directory's
/// entries are listed with.
pub const FILE_DIRECTORY_INFORMATION: u8 = 0x01;

/// QUERY_DIRECTORY: the next entries matching `pattern` (UTF-16LE), as
/// many as `length` bytes hold.
pub fn queryDirectory(request: *Request, file_id: *const [16]u8, class: u8, flags: u8, pattern: []const u8, length: u32) void {
    const writer = &request.writer;
    const start = request.starts[request.count - 1];
    writer.uint16(33);
    writer.byte(class);
    writer.byte(flags);
    writer.uint32(0); // FileIndex
    writer.raw(file_id);
    writer.uint16(@intCast(writer.at + 8 - start)); // FileNameOffset
    writer.uint16(@intCast(pattern.len));
    writer.uint32(length);
    writer.raw(pattern);
}

/// QUERY_INFO's kinds of information, and the classes asked for.
pub const INFO_FILE: u8 = 1;
pub const INFO_FILESYSTEM: u8 = 2;
pub const FILE_STANDARD_INFORMATION: u8 = 5;
pub const FILE_FS_FULL_SIZE_INFORMATION: u8 = 7;

/// QUERY_INFO: `class` of `kind` about the open object, as many as
/// `length` bytes hold.
pub fn queryInfo(request: *Request, file_id: *const [16]u8, kind: u8, class: u8, length: u32) void {
    const writer = &request.writer;
    writer.uint16(41);
    writer.byte(kind);
    writer.byte(class);
    writer.uint32(length);
    writer.uint16(0); // InputBufferOffset
    writer.uint16(0);
    writer.uint32(0); // InputBufferLength
    writer.uint32(0); // AdditionalInformation
    writer.uint32(0); // Flags
    writer.raw(file_id);
    writer.byte(0);
}

/// The classes SET_INFO sets ([MS-FSCC] 2.4).
pub const FILE_BASIC_INFORMATION: u8 = 4;
pub const FILE_RENAME_INFORMATION: u8 = 10;
pub const FILE_DISPOSITION_INFORMATION: u8 = 13;
pub const FILE_END_OF_FILE_INFORMATION: u8 = 20;

/// SET_INFO's fields, for `length` bytes of `class` that follow them.
fn setInfo(request: *Request, file_id: *const [16]u8, class: u8, length: u32) void {
    const writer = &request.writer;
    const start = request.starts[request.count - 1];
    writer.uint16(33);
    writer.byte(INFO_FILE);
    writer.byte(class);
    writer.uint32(length);
    writer.uint16(@intCast(writer.at + 24 - start)); // BufferOffset
    writer.uint16(0);
    writer.uint32(0); // AdditionalInformation
    writer.raw(file_id);
}

/// SET_INFO of FileBasicInformation: the time last written and the
/// attributes, each left as it is when 0.
pub fn setBasic(request: *Request, file_id: *const [16]u8, last_written: u64, attributes: u32) void {
    setInfo(request, file_id, FILE_BASIC_INFORMATION, 40);
    const writer = &request.writer;
    writer.uint64(0); // CreationTime
    writer.uint64(0); // LastAccessTime
    writer.uint64(last_written);
    writer.uint64(0); // ChangeTime
    writer.uint32(attributes);
    writer.uint32(0);
}

/// SET_INFO of FileEndOfFileInformation: the file cut or grown to `size`.
pub fn setEndOfFile(request: *Request, file_id: *const [16]u8, size: u64) void {
    setInfo(request, file_id, FILE_END_OF_FILE_INFORMATION, 8);
    request.writer.uint64(size);
}

/// SET_INFO of FileDispositionInformation: the object deleted when its
/// last handle closes.
pub fn setDisposition(request: *Request, file_id: *const [16]u8) void {
    setInfo(request, file_id, FILE_DISPOSITION_INFORMATION, 1);
    request.writer.byte(1);
}

/// SET_INFO of FileRenameInformation: the object moved to `path`, from
/// the share's root, never over another. The buffer is never shorter
/// than the structure with room for two characters, which some servers
/// insist on.
pub fn setRename(request: *Request, file_id: *const [16]u8, path: []const u8) void {
    const length: u32 = @intCast(@max(20 + path.len, 24));
    setInfo(request, file_id, FILE_RENAME_INFORMATION, length);
    const writer = &request.writer;
    writer.byte(0); // ReplaceIfExists
    writer.zeros(7);
    writer.uint64(0); // RootDirectory
    writer.uint32(@intCast(path.len));
    writer.raw(path);
    if (path.len < 4) writer.zeros(4 - path.len);
}

/// The output a QUERY_DIRECTORY's or a QUERY_INFO's answer carries (both
/// lay it out alike); null when it failed or is short.
/// STATUS_BUFFER_OVERFLOW is a warning: what came is all that fitted.
pub fn output(reply: *const Reply) ?[]const u8 {
    if (reply.failed()) return null;
    var reader = reply.body();
    const fields = reader.take(8) orelse return null;
    if (wire.u16At(fields, 0) != 9) return null;
    return reader.bufferAt(wire.u16At(fields, 2), wire.u32At(fields, 4));
}

/// ECHO: is the server there.
pub fn echo(request: *Request) void {
    request.writer.uint16(4);
    request.writer.uint16(0);
}

// --- what comes back ---------------------------------------------------------------

/// One entry of a FileDirectoryInformation listing.
pub const Entry = struct {
    attributes: u32,
    created: u64,
    written: u64,
    size: u64,
    allocation: u64,
    /// UTF-16LE.
    name: []const u8,

    pub fn isDir(entry: *const Entry) bool {
        return entry.attributes & ATTR_DIRECTORY != 0;
    }

    /// Whether it is `.` or `..`, which every directory but the root
    /// lists and nothing here shows.
    pub fn isDots(entry: *const Entry) bool {
        const name = entry.name;
        if (name.len == 2) return name[0] == '.' and name[1] == 0;
        if (name.len == 4) return name[0] == '.' and name[1] == 0 and name[2] == '.' and name[3] == 0;
        return false;
    }
};

/// The entries of one QUERY_DIRECTORY's output, one after another.
pub const Entries = struct {
    bytes: []const u8,
    at: usize = 0,
    done: bool = false,

    pub fn next(entries: *Entries) ?Entry {
        if (entries.done) return null;
        const rest = entries.bytes[@min(entries.at, entries.bytes.len)..];
        if (rest.len < 64) {
            entries.done = true;
            return null;
        }
        const name_length = wire.u32At(rest, 60);
        if (name_length > rest.len - 64) {
            entries.done = true;
            return null;
        }
        const following = wire.u32At(rest, 0);
        if (following == 0 or following > rest.len) entries.done = true else entries.at += following;
        return .{
            .created = wire.u64At(rest, 8),
            .written = wire.u64At(rest, 24),
            .size = wire.u64At(rest, 40),
            .allocation = wire.u64At(rest, 48),
            .attributes = wire.u32At(rest, 56),
            .name = rest[64..][0..name_length],
        };
    }
};

/// FileFsFullSizeInformation: the share's size and what is free of it,
/// for the one asking.
pub const Space = struct {
    total_units: u64 = 0,
    free_units: u64 = 0,
    unit_bytes: u32 = 0,

    pub fn of(bytes: []const u8) ?Space {
        if (bytes.len < 32) return null;
        return .{
            .total_units = wire.u64At(bytes, 0),
            .free_units = wire.u64At(bytes, 8),
            .unit_bytes = wire.u32At(bytes, 24) *% wire.u32At(bytes, 28),
        };
    }
};

/// FileStandardInformation's end of file: an open file's size.
pub fn standardSize(bytes: []const u8) ?u64 {
    if (bytes.len < 24) return null;
    return wire.u64At(bytes, 8);
}

// --- tests (host) ------------------------------------------------------------------

const testing = @import("std").testing;

/// A request of one command, written by `fill` into `buffer`: its
/// fields, after the header's room.
fn writtenBy(buffer: []u8, command: wire.Command, fill: anytype, args: anytype) []const u8 {
    var request: Request = .{ .writer = .{ .bytes = buffer } };
    request.add(command);
    @call(.auto, fill, .{&request} ++ args);
    return buffer[wire.header_size..request.writer.at];
}

test "WRITE carries its data right after its fields" {
    var buffer: [256]u8 = undefined;
    const id: [16]u8 = @splat(0xAB);
    const fields = writtenBy(&buffer, .write, write, .{ &id, 0x1_0000_0002, "hello" });
    try testing.expectEqual(@as(usize, 48 + 5), fields.len);
    try testing.expectEqual(@as(u16, 49), wire.u16At(fields, 0));
    try testing.expectEqual(@as(u16, 64 + 48), wire.u16At(fields, 2));
    try testing.expectEqual(@as(u32, 5), wire.u32At(fields, 4));
    try testing.expectEqual(@as(u64, 0x1_0000_0002), wire.u64At(fields, 8));
    try testing.expectEqualSlices(u8, &id, fields[16..32]);
    try testing.expectEqualStrings("hello", fields[48..]);
}

test "SET_INFO: its buffer where its offset says, for each class" {
    var buffer: [256]u8 = undefined;
    const id: [16]u8 = @splat(0x11);
    const basic = writtenBy(&buffer, .set_info, setBasic, .{ &id, 0x0102_0304_0506_0708, ATTR_READONLY });
    try testing.expectEqual(@as(u16, 33), wire.u16At(basic, 0));
    try testing.expectEqual(INFO_FILE, basic[2]);
    try testing.expectEqual(FILE_BASIC_INFORMATION, basic[3]);
    try testing.expectEqual(@as(u32, 40), wire.u32At(basic, 4));
    try testing.expectEqual(@as(u16, 64 + 32), wire.u16At(basic, 8));
    try testing.expectEqualSlices(u8, &id, basic[16..32]);
    try testing.expectEqual(@as(usize, 32 + 40), basic.len);
    try testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), wire.u64At(basic, 32 + 16));
    try testing.expectEqual(ATTR_READONLY, wire.u32At(basic, 32 + 32));

    const end = writtenBy(&buffer, .set_info, setEndOfFile, .{ &id, 12345 });
    try testing.expectEqual(FILE_END_OF_FILE_INFORMATION, end[3]);
    try testing.expectEqual(@as(u64, 12345), wire.u64At(end, 32));

    const gone = writtenBy(&buffer, .set_info, setDisposition, .{&id});
    try testing.expectEqual(FILE_DISPOSITION_INFORMATION, gone[3]);
    try testing.expectEqual(@as(u32, 1), wire.u32At(gone, 4));
    try testing.expectEqual(@as(u8, 1), gone[32]);

    // A rename's name from the share's root, never replacing; a short
    // one padded to the structure's least.
    const name = [_]u8{ 'a', 0, '\\', 0, 'b', 0 };
    const moved = writtenBy(&buffer, .set_info, setRename, .{ &id, &name });
    try testing.expectEqual(FILE_RENAME_INFORMATION, moved[3]);
    try testing.expectEqual(@as(u32, 26), wire.u32At(moved, 4));
    try testing.expectEqual(@as(u8, 0), moved[32]);
    try testing.expectEqual(@as(u32, name.len), wire.u32At(moved, 32 + 16));
    try testing.expectEqualSlices(u8, &name, moved[32 + 20 ..]);
    const short = writtenBy(&buffer, .set_info, setRename, .{ &id, name[0..2] });
    try testing.expectEqual(@as(u32, 24), wire.u32At(short, 4));
    try testing.expectEqual(@as(usize, 32 + 24), short.len);
}
