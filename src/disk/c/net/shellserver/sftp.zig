// SPDX-License-Identifier: MIT
//! ShellServer's SFTP server: what an SSH session's `sftp` subsystem
//! runs - `sftp` and `scp` on the client's side - on the files of every
//! mounted volume.
//!
//! **Names.** The client sees one tree: `/` holds the mounted file
//! systems' devices and the assigns, each a directory, and `/SYS/C/List`
//! is `SYS:C/List`. A session starts in `/SYS`, where a name without a
//! leading `/` is taken from; `.` and `..` are followed before dos sees
//! the name, so `..` never leaves `/`.
//!
//! **Requests** are answered in the order they came, each from the
//! packet alone: `answer` takes one and gives back the reply, and `serve`
//! runs it on the session's unit of ssh.device until the client ends.
//! Open files and directories are handles - up to `handles_max` - their
//! slot and a count of uses, so a stale one is told apart. A file is read
//! and written where the request says; writing past its end grows it.
//!
//! **Attributes.** A file's size, its time - the system clock's local
//! time turned into UTC by the zone in `ENVARC:Sys/timezone` - and its
//! permissions: read, write and execute for the owner from the
//! protection bits (a set bit forbids), the same without write for the
//! rest. SETSTAT sets them back - write sets delete with it - and the
//! time; a size cuts or grows the file. A new file gets the protection
//! any new file gets: the permissions OPEN carries are not used, so a
//! file brought from elsewhere stays executable.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const sftp = sdk.devices.ssh.sftp;
const timezone = dos.timezone;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;

/// The most files and directories open at once.
pub const handles_max = 16;
/// The longest name dos is given.
const path_max = 256;
/// A directory's entries go back in replies of about this much.
const listing_max = 16 * 1024;
/// The longest line `ls -l` shows for an entry, and the room one entry
/// of a listing takes at the most.
const line_max = 64 + dos.name_max;
const entry_max = 4 + dos.name_max + 4 + line_max + 32;

const Handle = struct {
    kind: enum { free, file, directory, root } = .free,
    /// Counted up each time the slot is taken: a handle's second half.
    uses: u32 = 0,
    file: ?*dos.FileHandle = null,
    lock: ?*dos.FileLock = null,
    /// Where the file is (saves a Seek per request), and whether every
    /// write goes at its end.
    position: u64 = 0,
    append: bool = false,
    /// A directory read to its end.
    done: bool = false,
    /// A time FSETSTAT gave an open file: set once it is closed, which
    /// would set its own.
    date: ?dos.DateStamp = null,
    /// The file's name, for that.
    name: [path_max:0]u8 = @splat(0),
    fib: dos.FileInfoBlock = .{},
};

pub const Server = struct {
    sys: *ExecBase,
    dl: *DosBase,
    zone: timezone.Zone = .{},
    /// The owner named in a listing, and where a session starts.
    user: [32:0]u8 = @splat(0),
    home: [64:0]u8 = @splat(0),
    handles: [handles_max]Handle = @splat(.{}),
    /// A request's names: as the client sees them, made whole, and as dos
    /// is given them.
    whole: [path_max:0]u8 = @splat(0),
    whole_length: usize = 0,
    path: [path_max:0]u8 = @splat(0),
    /// The second name of a RENAME.
    target: [path_max:0]u8 = @splat(0),
    scratch: dos.FileInfoBlock = .{},
    /// What came from the client and is not answered yet, and the reply.
    input: [sftp.packet_max]u8 = undefined,
    input_length: usize = 0,
    reply: [sftp.packet_max]u8 = undefined,

    /// A server with no handles open: `user` names the owner in a
    /// listing, and `home` (`/SYS`) is where names are taken from.
    pub fn init(server: *Server, sys: *ExecBase, dl: *DosBase, user: []const u8, home: []const u8) void {
        server.* = .{ .sys = sys, .dl = dl };
        copyName(&server.user, user);
        copyName(&server.home, home);
        server.zone = readZone(dl);
    }

    /// Every handle the client left open, closed.
    pub fn deinit(server: *Server) void {
        for (&server.handles) |*handle| server.release(handle);
    }

    /// The client's requests read from the unit `io` is open on and
    /// answered, until the client ends or sends what is not SFTP.
    pub fn serve(server: *Server, io: *exec.IOStdReq) void {
        while (true) {
            while (sftp.packetLength(server.input[0..server.input_length])) |length| {
                if (length > server.input.len) return;
                if (length > server.input_length) break;
                const reply = server.answer(server.input[0..length]);
                if (reply.len > 0 and !send(server.sys, io, reply)) return;
                const rest = server.input_length - length;
                if (rest > 0) @memmove(server.input[0..rest], server.input[length..server.input_length]);
                server.input_length = rest;
            }
            io.req.command = exec.CMD_READ;
            io.data = &server.input[server.input_length];
            io.length = server.input.len - server.input_length;
            if (server.sys.DoIO(&io.req) != 0) return;
            server.input_length += @intCast(io.actual);
        }
    }

    /// One request, its length field and all, answered: the reply's
    /// bytes, in `reply`.
    pub fn answer(server: *Server, packet: []const u8) []const u8 {
        var reader: sftp.Reader = .{ .bytes = packet[4..] };
        const kind = reader.byte();
        if (kind == sftp.FXP_INIT) {
            var writer: sftp.Writer = .{ .bytes = &server.reply };
            writer.begin(sftp.FXP_VERSION, null);
            writer.uint32(sftp.version);
            return writer.end();
        }
        const id = reader.uint32();
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        return switch (kind) {
            sftp.FXP_OPEN => server.open(id, &reader),
            sftp.FXP_CLOSE => server.close(id, &reader),
            sftp.FXP_READ => server.read(id, &reader),
            sftp.FXP_WRITE => server.write(id, &reader),
            sftp.FXP_STAT, sftp.FXP_LSTAT => server.stat(id, &reader),
            sftp.FXP_FSTAT => server.fstat(id, &reader),
            sftp.FXP_SETSTAT => server.setstat(id, &reader),
            sftp.FXP_FSETSTAT => server.fsetstat(id, &reader),
            sftp.FXP_OPENDIR => server.opendir(id, &reader),
            sftp.FXP_READDIR => server.readdir(id, &reader),
            sftp.FXP_REMOVE => server.remove(id, &reader, false),
            sftp.FXP_RMDIR => server.remove(id, &reader, true),
            sftp.FXP_MKDIR => server.mkdir(id, &reader),
            sftp.FXP_REALPATH => server.realpath(id, &reader),
            sftp.FXP_RENAME => server.rename(id, &reader),
            else => server.status(id, sftp.FX_OP_UNSUPPORTED, "not supported"),
        };
    }

    // --- Requests --------------------------------------------------------

    fn open(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const name = reader.string();
        const flags = reader.uint32();
        _ = sftp.Attrs.read(reader);
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (!server.resolve(name, &server.path)) return server.failed(id);
        if (server.whole_length == 1 or volumeOnly(&server.whole)) return server.status(id, sftp.FX_FAILURE, "is a directory");
        const handle = server.take() orelse return server.status(id, sftp.FX_FAILURE, "too many open files");
        const dl = server.dl;
        const writing = flags & (sftp.FXF_WRITE | sftp.FXF_APPEND) != 0;
        if (flags & sftp.FXF_CREAT != 0 and flags & sftp.FXF_EXCL != 0) {
            if (dl.Lock(&server.path, dos.SHARED_LOCK)) |there| {
                dl.UnLock(there);
                handle.kind = .free;
                return server.status(id, sftp.FX_FAILURE, "file exists");
            }
        }
        const mode = if (!writing)
            dos.MODE_OLDFILE
        else if (flags & sftp.FXF_CREAT != 0)
            (if (flags & sftp.FXF_TRUNC != 0) dos.MODE_NEWFILE else dos.MODE_READWRITE)
        else
            dos.MODE_OLDFILE;
        handle.file = dl.Open(&server.path, mode) orelse {
            handle.kind = .free;
            return server.failed(id);
        };
        // A file that is there and not made new is emptied when asked.
        if (writing and flags & sftp.FXF_TRUNC != 0 and mode != dos.MODE_NEWFILE)
            _ = dl.SetFileSize(handle.file, 0, dos.OFFSET_BEGINNING);
        handle.kind = .file;
        handle.append = flags & sftp.FXF_APPEND != 0;
        copyName(&handle.name, sliceOf(&server.path));
        return server.handleReply(id, handle);
    }

    fn close(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const handle = server.handleOf(reader) orelse return server.badHandle(id);
        const closed = handle.kind != .file or server.dl.Close(handle.file);
        handle.file = null;
        if (handle.date) |date| _ = server.dl.SetFileDate(&handle.name, &date);
        server.release(handle);
        return if (closed) server.status(id, sftp.FX_OK, "") else server.failed(id);
    }

    fn read(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const handle = server.handleOf(reader) orelse return server.badHandle(id);
        const offset = reader.uint64();
        const wanted: u32 = @min(reader.uint32(), sftp.read_max);
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (handle.kind != .file) return server.status(id, sftp.FX_FAILURE, "not a file");
        if (!server.moveTo(handle, offset)) return server.status(id, sftp.FX_EOF, "");
        var writer: sftp.Writer = .{ .bytes = &server.reply };
        writer.begin(sftp.FXP_DATA, id);
        // The data's length goes in front of it, once it is known.
        const length_at = writer.at;
        writer.uint32(0);
        const room = server.reply[writer.at..][0..wanted];
        const got = server.dl.Read(handle.file, room.ptr, @intCast(wanted));
        if (got < 0) return server.failed(id);
        if (got == 0) return server.status(id, sftp.FX_EOF, "");
        handle.position += @intCast(got);
        sftp.put32(server.reply[length_at..][0..4], @intCast(got));
        writer.at += @intCast(got);
        return writer.end();
    }

    fn write(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const handle = server.handleOf(reader) orelse return server.badHandle(id);
        const offset = reader.uint64();
        const data = reader.string();
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (handle.kind != .file) return server.status(id, sftp.FX_FAILURE, "not a file");
        const dl = server.dl;
        if (handle.append) {
            if (dl.Seek(handle.file, 0, dos.OFFSET_END) < 0) return server.failed(id);
            const end = dl.Seek(handle.file, 0, dos.OFFSET_CURRENT);
            if (end < 0) return server.failed(id);
            handle.position = @intCast(end);
        } else if (!server.moveTo(handle, offset)) {
            // Past the end: the file grown to there first.
            if (offset > max_offset or dl.SetFileSize(handle.file, @intCast(offset), dos.OFFSET_BEGINNING) < 0 or
                !server.moveTo(handle, offset)) return server.failed(id);
        }
        if (data.len > 0) {
            const put = dl.Write(handle.file, data.ptr, @intCast(data.len));
            if (put != data.len) {
                handle.position = unknown_position;
                return server.failed(id);
            }
            handle.position += data.len;
        }
        return server.status(id, sftp.FX_OK, "");
    }

    fn stat(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const name = reader.string();
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (!server.resolve(name, &server.path)) return server.failed(id);
        const attrs = if (server.whole_length == 1) rootAttrs() else server.attrsOf(&server.path) orelse return server.failed(id);
        return server.attrsReply(id, attrs);
    }

    fn fstat(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const handle = server.handleOf(reader) orelse return server.badHandle(id);
        const attrs = switch (handle.kind) {
            .file => if (server.dl.ExamineFH(handle.file, &server.scratch)) server.attrsFromFib(&server.scratch) else return server.failed(id),
            .directory => if (server.dl.Examine(handle.lock, &server.scratch)) server.attrsFromFib(&server.scratch) else return server.failed(id),
            else => rootAttrs(),
        };
        return server.attrsReply(id, attrs);
    }

    fn setstat(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const name = reader.string();
        const attrs = sftp.Attrs.read(reader);
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (!server.resolve(name, &server.path)) return server.failed(id);
        if (server.whole_length == 1 or volumeOnly(&server.whole)) return server.status(id, sftp.FX_PERMISSION_DENIED, "");
        const dl = server.dl;
        if (attrs.flags & sftp.ATTR_SIZE != 0) {
            const file = dl.Open(&server.path, dos.MODE_OLDFILE) orelse return server.failed(id);
            const cut = sizeFits(attrs.size) and dl.SetFileSize(file, @intCast(attrs.size), dos.OFFSET_BEGINNING) >= 0;
            _ = dl.Close(file);
            if (!cut) return server.failed(id);
        }
        if (!server.setPermissions(&server.path, attrs)) return server.failed(id);
        if (attrs.flags & sftp.ATTR_ACMODTIME != 0) {
            const date = server.dateFromUnix(attrs.mtime);
            if (!dl.SetFileDate(&server.path, &date)) return server.failed(id);
        }
        return server.status(id, sftp.FX_OK, "");
    }

    fn fsetstat(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const handle = server.handleOf(reader) orelse return server.badHandle(id);
        const attrs = sftp.Attrs.read(reader);
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (handle.kind != .file) return server.status(id, sftp.FX_PERMISSION_DENIED, "");
        if (attrs.flags & sftp.ATTR_SIZE != 0) {
            if (!sizeFits(attrs.size) or server.dl.SetFileSize(handle.file, @intCast(attrs.size), dos.OFFSET_BEGINNING) < 0) return server.failed(id);
            handle.position = unknown_position;
        }
        if (!server.setPermissions(&handle.name, attrs)) return server.failed(id);
        if (attrs.flags & sftp.ATTR_ACMODTIME != 0) handle.date = server.dateFromUnix(attrs.mtime);
        return server.status(id, sftp.FX_OK, "");
    }

    fn opendir(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const name = reader.string();
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (!server.resolve(name, &server.path)) return server.failed(id);
        const handle = server.take() orelse return server.status(id, sftp.FX_FAILURE, "too many open files");
        if (server.whole_length == 1) {
            handle.kind = .root;
            return server.handleReply(id, handle);
        }
        const dl = server.dl;
        handle.lock = dl.Lock(&server.path, dos.SHARED_LOCK);
        if (handle.lock == null or !dl.Examine(handle.lock, &handle.fib)) {
            const reply = server.failed(id);
            server.release(handle);
            return reply;
        }
        handle.kind = .directory;
        if (handle.fib.dir_entry_type <= 0) {
            server.release(handle);
            return server.status(id, sftp.FX_FAILURE, "not a directory");
        }
        return server.handleReply(id, handle);
    }

    fn readdir(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const handle = server.handleOf(reader) orelse return server.badHandle(id);
        if (handle.kind == .file) return server.status(id, sftp.FX_FAILURE, "not a directory");
        if (handle.done) return server.status(id, sftp.FX_EOF, "");
        var writer: sftp.Writer = .{ .bytes = server.reply[0..listing_max] };
        writer.begin(sftp.FXP_NAME, id);
        const count_at = writer.at;
        writer.uint32(0);
        var today: dos.DateStamp = .{};
        _ = server.dl.DateStamp(&today);
        var count: u32 = 0;
        if (handle.kind == .root) {
            count = server.listRoot(&writer);
            handle.done = true;
        } else {
            while (writer.bytes.len - writer.at >= entry_max) {
                if (!server.dl.ExNext(handle.lock, &handle.fib)) {
                    if (server.dl.IoErr() != dos.ERROR_NO_MORE_ENTRIES and count == 0) return server.failed(id);
                    handle.done = true;
                    break;
                }
                const fib = &handle.fib;
                const attrs = server.attrsFromFib(fib);
                server.listEntry(&writer, sliceOf(@ptrCast(&fib.file_name)), attrs, fib.date, today);
                count += 1;
            }
        }
        if (count == 0) return server.status(id, sftp.FX_EOF, "");
        sftp.put32(server.reply[count_at..][0..4], count);
        return writer.end();
    }

    fn remove(server: *Server, id: u32, reader: *sftp.Reader, directory: bool) []const u8 {
        const name = reader.string();
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (!server.resolve(name, &server.path)) return server.failed(id);
        if (server.whole_length == 1 or volumeOnly(&server.whole)) return server.status(id, sftp.FX_PERMISSION_DENIED, "");
        // DeleteFile takes a file and an empty directory alike: the one
        // asked for is checked first.
        const attrs = server.attrsOf(&server.path) orelse return server.failed(id);
        if (attrs.isDir() != directory) return server.status(id, sftp.FX_FAILURE, if (directory) "not a directory" else "is a directory");
        if (!server.dl.DeleteFile(&server.path)) return server.failed(id);
        return server.status(id, sftp.FX_OK, "");
    }

    fn mkdir(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const name = reader.string();
        _ = sftp.Attrs.read(reader);
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (!server.resolve(name, &server.path)) return server.failed(id);
        if (server.whole_length == 1 or volumeOnly(&server.whole)) return server.status(id, sftp.FX_PERMISSION_DENIED, "");
        const made = server.dl.CreateDir(&server.path) orelse return server.failed(id);
        server.dl.UnLock(made);
        return server.status(id, sftp.FX_OK, "");
    }

    fn realpath(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const name = reader.string();
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (!server.resolve(name, &server.path)) return server.failed(id);
        var writer: sftp.Writer = .{ .bytes = &server.reply };
        writer.begin(sftp.FXP_NAME, id);
        writer.uint32(1);
        const whole = server.whole[0..server.whole_length];
        writer.string(whole);
        writer.string(whole);
        (sftp.Attrs{}).write(&writer);
        return writer.end();
    }

    fn rename(server: *Server, id: u32, reader: *sftp.Reader) []const u8 {
        const from = reader.string();
        const to = reader.string();
        if (reader.bad) return server.status(id, sftp.FX_BAD_MESSAGE, "");
        if (!server.resolve(to, &server.target)) return server.failed(id);
        if (server.whole_length == 1 or volumeOnly(&server.whole)) return server.status(id, sftp.FX_PERMISSION_DENIED, "");
        if (!server.resolve(from, &server.path)) return server.failed(id);
        if (server.whole_length == 1 or volumeOnly(&server.whole)) return server.status(id, sftp.FX_PERMISSION_DENIED, "");
        if (!server.dl.Rename(&server.path, &server.target)) return server.failed(id);
        return server.status(id, sftp.FX_OK, "");
    }

    // --- Names -----------------------------------------------------------

    /// The client's `name` made whole in `whole` - from `home` when it
    /// does not start at `/`, `.` and `..` followed - and the name dos is
    /// given in `into`: `VOLUME:rest`. False, with IoErr set, for a name
    /// too long or with a colon in it.
    fn resolve(server: *Server, name: []const u8, into: *[path_max:0]u8) bool {
        var whole: [path_max]u8 = undefined;
        var length: usize = 0;
        const parts = [2][]const u8{ if (name.len > 0 and name[0] == '/') "" else sliceOf(&server.home), name };
        for (parts) |part| {
            var rest = part;
            while (rest.len > 0) {
                var end: usize = 0;
                while (end < rest.len and rest[end] != '/') end += 1;
                const component = rest[0..end];
                rest = if (end < rest.len) rest[end + 1 ..] else rest[rest.len..];
                if (component.len == 0 or (component.len == 1 and component[0] == '.')) continue;
                if (component.len == 2 and component[0] == '.' and component[1] == '.') {
                    while (length > 0 and whole[length - 1] != '/') length -= 1;
                    if (length > 0) length -= 1;
                    continue;
                }
                for (component) |char| {
                    if (char == ':' or char == 0) {
                        _ = server.dl.SetIoErr(dos.ERROR_INVALID_COMPONENT_NAME);
                        return false;
                    }
                }
                if (length + 1 + component.len >= path_max) {
                    _ = server.dl.SetIoErr(dos.ERROR_LINE_TOO_LONG);
                    return false;
                }
                whole[length] = '/';
                @memcpy(whole[length + 1 ..][0..component.len], component);
                length += 1 + component.len;
            }
        }
        if (length == 0) {
            whole[0] = '/';
            length = 1;
        }
        @memcpy(server.whole[0..length], whole[0..length]);
        server.whole[length] = 0;
        server.whole_length = length;

        // "/VOLUME/rest" to "VOLUME:rest"; "/" has no dos name.
        into.* = @splat(0);
        if (length == 1) return true;
        var at: usize = 0;
        var volume = true;
        for (whole[1..length]) |char| {
            into[at] = if (volume and char == '/') ':' else char;
            if (char == '/') volume = false;
            at += 1;
        }
        if (volume) into[at] = ':';
        return true;
    }

    // --- Attributes ------------------------------------------------------

    fn attrsOf(server: *Server, name: [*:0]const u8) ?sftp.Attrs {
        const dl = server.dl;
        const lock = dl.Lock(name, dos.SHARED_LOCK) orelse return null;
        defer dl.UnLock(lock);
        if (!dl.Examine(lock, &server.scratch)) return null;
        return server.attrsFromFib(&server.scratch);
    }

    fn attrsFromFib(server: *Server, fib: *const dos.FileInfoBlock) sftp.Attrs {
        const directory = fib.dir_entry_type > 0;
        return .{
            .flags = sftp.ATTR_SIZE | sftp.ATTR_PERMISSIONS | sftp.ATTR_ACMODTIME,
            .size = if (directory) 0 else fib.size,
            .permissions = (if (directory) sftp.S_IFDIR else sftp.S_IFREG) | modeOf(fib.protection, directory),
            .atime = server.unixFromDate(fib.date),
            .mtime = server.unixFromDate(fib.date),
        };
    }

    /// Read, write and execute as the protection bits allow them.
    fn setPermissions(server: *Server, name: [*:0]const u8, attrs: sftp.Attrs) bool {
        if (attrs.flags & sftp.ATTR_PERMISSIONS == 0) return true;
        const dl = server.dl;
        const lock = dl.Lock(name, dos.SHARED_LOCK) orelse return false;
        const examined = dl.Examine(lock, &server.scratch);
        dl.UnLock(lock);
        if (!examined) return false;
        var bits = server.scratch.protection & ~@as(u32, dos.FIBF_READ | dos.FIBF_WRITE | dos.FIBF_DELETE | dos.FIBF_EXECUTE);
        if (attrs.permissions & sftp.S_IRUSR == 0) bits |= dos.FIBF_READ;
        if (attrs.permissions & sftp.S_IWUSR == 0) bits |= dos.FIBF_WRITE | dos.FIBF_DELETE;
        if (attrs.permissions & sftp.S_IXUSR == 0) bits |= dos.FIBF_EXECUTE;
        return dl.SetProtection(name, bits);
    }

    /// A DateStamp, local time, as seconds since 1970 UTC.
    fn unixFromDate(server: *Server, date: dos.DateStamp) u32 {
        const local = secondsOf(date) + timezone.datestamp_epoch;
        const guess = local - server.zone.offsetAt(local);
        const utc = local - server.zone.offsetAt(guess);
        return if (utc < 0) 0 else @truncate(@as(u64, @intCast(utc)));
    }

    fn dateFromUnix(server: *Server, unix: u32) dos.DateStamp {
        const local = @as(i64, unix) + server.zone.offsetAt(unix) - timezone.datestamp_epoch;
        if (local < 0) return .{};
        return .{
            .days = @intCast(@divFloor(local, 86400)),
            .minute = @intCast(@divFloor(@mod(local, 86400), 60)),
            .tick = @intCast(@mod(local, 60) * ticks_per_second),
        };
    }

    // --- Listings --------------------------------------------------------

    /// The mounted file systems' devices and then the assigns, each a
    /// directory: what `/` holds.
    fn listRoot(server: *Server, writer: *sftp.Writer) u32 {
        const dl = server.dl;
        var today: dos.DateStamp = .{};
        _ = dl.DateStamp(&today);
        const attrs = rootAttrs();
        var count: u32 = 0;
        const kinds = [2]u32{ dos.LDF_DEVICES, dos.LDF_ASSIGNS };
        for (kinds) |kind| {
            const flags = kind | dos.LDF_READ;
            const start = dl.LockDosList(flags) orelse continue;
            defer dl.UnLockDosList(flags);
            var node: *dos.DosList = start;
            while (dl.NextDosEntry(node, flags)) |entry| {
                node = entry;
                if (writer.bytes.len - writer.at < entry_max) break;
                if (kind == dos.LDF_DEVICES and !isFileSystem(dl, entry)) continue;
                server.listEntry(writer, sliceOf(entry.name), attrs, today, today);
                count += 1;
            }
        }
        return count;
    }

    /// One entry of a listing: its name, the line `ls -l` shows for it,
    /// and its attributes.
    fn listEntry(server: *Server, writer: *sftp.Writer, name: []const u8, attrs: sftp.Attrs, date: dos.DateStamp, today: dos.DateStamp) void {
        writer.string(name);
        var line: [line_max]u8 = undefined;
        var text: Text = .{ .bytes = &line };
        const mode = attrs.permissions;
        text.char(if (attrs.isDir()) 'd' else '-');
        const letters = "rwxrwxrwx";
        for (letters, 0..) |letter, index| {
            const bit = @as(u32, 0o400) >> @intCast(index);
            text.char(if (mode & bit != 0) letter else '-');
        }
        text.put("    1 ");
        text.padded(sliceOf(&server.user), 8);
        text.char(' ');
        text.padded(sliceOf(&server.user), 8);
        text.char(' ');
        text.number(attrs.size, 8);
        text.char(' ');
        // As ls writes it: the hour for the last half year, the year
        // before that.
        const days: i64 = @as(i64, date.days) + timezone.datestamp_epoch / 86400;
        const civil = timezone.civilFromDays(days);
        text.put(month_names[civil.month - 1]);
        text.char(' ');
        text.number(civil.day, 2);
        text.char(' ');
        if (today.days - date.days < 183 and date.days <= today.days) {
            text.number2(@intCast(@divFloor(date.minute, 60)));
            text.char(':');
            text.number2(@intCast(@mod(date.minute, 60)));
        } else {
            text.char(' ');
            text.number(@intCast(civil.year), 4);
        }
        text.char(' ');
        text.put(name);
        writer.string(line[0..text.at]);
        attrs.write(writer);
    }

    // --- Handles ---------------------------------------------------------

    fn take(server: *Server) ?*Handle {
        for (&server.handles) |*handle| {
            if (handle.kind != .free) continue;
            const uses = handle.uses +% 1;
            handle.* = .{ .uses = uses, .kind = .root };
            return handle;
        }
        return null;
    }

    fn release(server: *Server, handle: *Handle) void {
        if (handle.file) |file| _ = server.dl.Close(file);
        if (handle.lock) |lock| server.dl.UnLock(lock);
        handle.* = .{ .uses = handle.uses };
    }

    /// The handle a request names: its slot, then its count of uses.
    fn handleOf(server: *Server, reader: *sftp.Reader) ?*Handle {
        const bytes = reader.string();
        if (reader.bad or bytes.len != 8) return null;
        const slot = sftp.get32(bytes[0..4]);
        if (slot >= handles_max) return null;
        const handle = &server.handles[slot];
        if (handle.kind == .free or handle.uses != sftp.get32(bytes[4..8])) return null;
        return handle;
    }

    fn handleReply(server: *Server, id: u32, handle: *Handle) []const u8 {
        var bytes: [8]u8 = undefined;
        sftp.put32(bytes[0..4], @intCast(handle - &server.handles[0]));
        sftp.put32(bytes[4..8], handle.uses);
        var writer: sftp.Writer = .{ .bytes = &server.reply };
        writer.begin(sftp.FXP_HANDLE, id);
        writer.string(&bytes);
        return writer.end();
    }

    /// The file moved to `offset`; false past its end.
    fn moveTo(server: *Server, handle: *Handle, offset: u64) bool {
        if (handle.position == offset) return true;
        if (offset > max_offset or server.dl.Seek(handle.file, @intCast(offset), dos.OFFSET_BEGINNING) < 0) return false;
        handle.position = offset;
        return true;
    }

    // --- Replies ---------------------------------------------------------

    fn attrsReply(server: *Server, id: u32, attrs: sftp.Attrs) []const u8 {
        var writer: sftp.Writer = .{ .bytes = &server.reply };
        writer.begin(sftp.FXP_ATTRS, id);
        attrs.write(&writer);
        return writer.end();
    }

    fn status(server: *Server, id: u32, code: u32, message: []const u8) []const u8 {
        var writer: sftp.Writer = .{ .bytes = &server.reply };
        writer.begin(sftp.FXP_STATUS, id);
        writer.uint32(code);
        writer.string(message);
        writer.string("");
        return writer.end();
    }

    fn badHandle(server: *Server, id: u32) []const u8 {
        return server.status(id, sftp.FX_FAILURE, "no such handle");
    }

    /// What dos's last error was, as a STATUS: its code and its text.
    fn failed(server: *Server, id: u32) []const u8 {
        const code = server.dl.IoErr();
        var text: [80]u8 = undefined;
        const length = server.dl.Fault(code, null, &text, text.len);
        const message = if (length > 0) text[0..@intCast(length)] else "failed";
        return server.status(id, statusOf(code), message);
    }
};

/// A complete reply written to the client.
fn send(sys: *ExecBase, io: *exec.IOStdReq, bytes: []const u8) bool {
    io.req.command = exec.CMD_WRITE;
    io.data = @constCast(bytes.ptr);
    io.length = bytes.len;
    return sys.DoIO(&io.req) == 0;
}

/// The furthest a file is moved: Seek's offsets are 32 bits.
const max_offset: u64 = 0x7FFF_FFFF;
/// A position no offset matches: the next request seeks.
const unknown_position: u64 = ~@as(u64, 0);
const ticks_per_second = 50;
const month_names = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn sizeFits(size: u64) bool {
    return size <= max_offset;
}

fn statusOf(code: i32) u32 {
    return switch (code) {
        dos.ERROR_OBJECT_NOT_FOUND, dos.ERROR_DIR_NOT_FOUND, dos.ERROR_DEVICE_NOT_MOUNTED, dos.ERROR_NO_DISK => sftp.FX_NO_SUCH_FILE,
        dos.ERROR_READ_PROTECTED, dos.ERROR_WRITE_PROTECTED, dos.ERROR_DELETE_PROTECTED, dos.ERROR_DISK_WRITE_PROTECTED => sftp.FX_PERMISSION_DENIED,
        else => sftp.FX_FAILURE,
    };
}

/// The permissions' nine bits: the owner's from the protection, the rest
/// the same without write. A directory can always be gone into.
fn modeOf(protection: u32, directory: bool) u32 {
    var owner: u32 = 0;
    if (protection & dos.FIBF_READ == 0) owner |= 4;
    if (protection & dos.FIBF_WRITE == 0) owner |= 2;
    if (directory or protection & dos.FIBF_EXECUTE == 0) owner |= 1;
    const others = owner & 5;
    return owner << 6 | others << 3 | others;
}

fn rootAttrs() sftp.Attrs {
    return .{ .flags = sftp.ATTR_PERMISSIONS, .permissions = sftp.S_IFDIR | 0o755 };
}

fn secondsOf(date: dos.DateStamp) i64 {
    return @as(i64, date.days) * 86400 + @as(i64, date.minute) * 60 + @divFloor(date.tick, ticks_per_second);
}

/// Whether a whole name is `/VOLUME` alone.
fn volumeOnly(whole: [*:0]const u8) bool {
    if (whole[0] != '/' or whole[1] == 0) return false;
    var at: usize = 1;
    while (whole[at] != 0) : (at += 1) {
        if (whole[at] == '/') return false;
    }
    return true;
}

/// A device that is a file system with something mounted: its handler
/// runs and answers DISK_INFO, and is not a console.
fn isFileSystem(dl: *DosBase, entry: *dos.DosList) bool {
    const port = entry.task orelse return false;
    var info: dos.InfoData = .{};
    const action = @intFromEnum(dos.ActionCode.disk_info);
    if (dl.DoPkt(port, action, @bitCast(@intFromPtr(&info)), 0, 0, 0, 0) == dos.DOSFALSE) return false;
    return info.disk_type != dos.ID_CON and info.disk_type != dos.ID_RAWCON;
}

/// The zone the system clock keeps; UTC without one.
fn readZone(dl: *DosBase) timezone.Zone {
    const file = dl.Open(timezone.zone_file, dos.MODE_OLDFILE) orelse return .{};
    defer _ = dl.Close(file);
    var text: [256]u8 = undefined;
    const got = dl.Read(file, &text, text.len);
    if (got <= 0) return .{};
    var rest: []const u8 = text[0..@intCast(got)];
    while (rest.len > 0) {
        var end: usize = 0;
        while (end < rest.len and rest[end] != '\n') end += 1;
        var line = rest[0..end];
        rest = if (end < rest.len) rest[end + 1 ..] else rest[rest.len..];
        while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) line = line[0 .. line.len - 1];
        while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
        if (line.len == 0 or line[0] == '#') continue;
        return timezone.parse(line) orelse .{};
    }
    return .{};
}

fn copyName(into: anytype, from: []const u8) void {
    const length: usize = @min(from.len, into.len);
    @memcpy(into[0..length], from[0..length]);
    if (length < into.len) into[length] = 0;
}

fn sliceOf(name: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    return name[0..length];
}

/// A line of a listing, put together.
const Text = struct {
    bytes: []u8,
    at: usize = 0,

    fn char(text: *Text, value: u8) void {
        if (text.at < text.bytes.len) {
            text.bytes[text.at] = value;
            text.at += 1;
        }
    }

    fn put(text: *Text, value: []const u8) void {
        for (value) |char_value| text.char(char_value);
    }

    fn padded(text: *Text, value: []const u8, width: usize) void {
        text.put(value);
        var count = value.len;
        while (count < width) : (count += 1) text.char(' ');
    }

    /// Right-aligned in `width`.
    fn number(text: *Text, value: u64, width: usize) void {
        var digits: [20]u8 = undefined;
        var count: usize = 0;
        var rest = value;
        while (true) {
            digits[count] = '0' + @as(u8, @intCast(rest % 10));
            count += 1;
            rest /= 10;
            if (rest == 0) break;
        }
        var pad = count;
        while (pad < width) : (pad += 1) text.char(' ');
        while (count > 0) {
            count -= 1;
            text.char(digits[count]);
        }
    }

    /// Two digits, a leading 0.
    fn number2(text: *Text, value: u32) void {
        text.char('0' + @as(u8, @intCast(value / 10 % 10)));
        text.char('0' + @as(u8, @intCast(value % 10)));
    }
};
