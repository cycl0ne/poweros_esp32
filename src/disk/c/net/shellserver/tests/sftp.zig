// SPDX-License-Identifier: MIT
//! Host tests of ShellServer's SFTP server: requests answered on the
//! ROM's exec, utility and dos, with a RAM disk mounted as WORK: for the
//! files.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const sftp = sdk.devices.ssh.sftp;
const host = @import("host_rom");
const kexec = host.exec;
const Server = @import("../sftp.zig").Server;

const testing = std.testing;
const DosBase = sdk.interface.dos.DosBase;

/// The RAM disk behind WORK:, answering the test process's packets.
const Disk = struct {
    var port: exec.MsgPort = undefined;
    var disk: host.ram.RamDisk = undefined;
    var dl: *DosBase = undefined;

    fn wait(proc: *dos.Process, sys: *sdk.interface.exec.ExecBase) callconv(.c) *exec.Message {
        const pkt = dos.DosPacket.fromMessage(sys.GetMsg(&port).?);
        const reply = disk.answer(pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
        return sys.GetMsg(&proc.msg_port).?;
    }
};

/// exec, utility and dos; a process with WORK: behind it; a server whose
/// sessions start in /WORK.
const Rig = struct {
    db: *host.dos.DosBase,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,
    server: *Server = undefined,
    client: Client = undefined,

    fn init(rig: *Rig) !void {
        rig.* = .{ .db = try host.dos.testSetUp() };
        rig.proc.task.node.name = "test process";
        host.dos_process.initMsgPort(&rig.proc);
        rig.saved = kexec.SysBase.cpu().this_task;
        kexec.SysBase.cpu().this_task = &rig.proc.task;

        const dl = rig.dosLib();
        Disk.dl = dl;
        Disk.port = .{ .flags = exec.PA_IGNORE };
        Disk.port.msg_list.init(.message);
        Disk.disk = try host.ram.RamDisk.init(rig.db.sys_base, dl, rig.db.utility_base, &Disk.port);
        const node = dl.MakeDosEntry("WORK", dos.DLT_DEVICE).?;
        node.task = &Disk.port;
        try testing.expect(dl.AddDosEntry(node));
        rig.proc.pkt_wait = &Disk.wait;

        rig.server = try testing.allocator.create(Server);
        rig.server.init(kexec.SysBase.iface(), dl, "admin", "/WORK");
        rig.client = .{ .server = rig.server };
    }

    fn dosLib(rig: *Rig) *DosBase {
        return host.dos.testBase(rig.db);
    }

    /// The server's handles closed, the disk and every library taken
    /// down, and nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.server.deinit();
        testing.allocator.destroy(rig.server);
        Disk.disk.deinit();
        kexec.SysBase.cpu().this_task = rig.saved.?;
        try host.dos.testTearDown(rig.db);
        kexec.deinit();
    }
};

/// Requests built and answered, the way a client sends them.
const Client = struct {
    server: *Server,
    buffer: [sftp.packet_max]u8 = undefined,
    writer: sftp.Writer = undefined,
    next_id: u32 = 1,

    fn begin(client: *Client, kind: u8) *sftp.Writer {
        client.writer = .{ .bytes = &client.buffer };
        client.writer.begin(kind, client.next_id);
        return &client.writer;
    }

    /// The request sent; its answer, checked to be one whole packet with
    /// the request's id.
    fn send(client: *Client) !Reply {
        const id = client.next_id;
        client.next_id += 1;
        const bytes = client.server.answer(client.writer.end());
        try testing.expect(bytes.len >= 9);
        try testing.expectEqual(bytes.len, sftp.packetLength(bytes).?);
        var reader: sftp.Reader = .{ .bytes = bytes[4..] };
        const kind = reader.byte();
        try testing.expectEqual(id, reader.uint32());
        return .{ .kind = kind, .reader = reader };
    }

    /// A request with one name in it.
    fn named(client: *Client, kind: u8, name: []const u8) !Reply {
        client.begin(kind).string(name);
        return client.send();
    }

    fn expectStatus(client: *Client, code: u32) !void {
        var reply = try client.send();
        try reply.expectStatus(code);
    }

    fn open(client: *Client, name: []const u8, flags: u32) ![8]u8 {
        const writer = client.begin(sftp.FXP_OPEN);
        writer.string(name);
        writer.uint32(flags);
        (sftp.Attrs{ .flags = sftp.ATTR_PERMISSIONS, .permissions = 0o644 }).write(writer);
        var reply = try client.send();
        return reply.handle();
    }

    fn close(client: *Client, handle: [8]u8) !void {
        client.begin(sftp.FXP_CLOSE).string(&handle);
        try client.expectStatus(sftp.FX_OK);
    }

    fn write(client: *Client, handle: [8]u8, offset: u64, data: []const u8) !void {
        const writer = client.begin(sftp.FXP_WRITE);
        writer.string(&handle);
        writer.uint64(offset);
        writer.string(data);
        try client.expectStatus(sftp.FX_OK);
    }

    fn read(client: *Client, handle: [8]u8, offset: u64, length: u32) !Reply {
        const writer = client.begin(sftp.FXP_READ);
        writer.string(&handle);
        writer.uint64(offset);
        writer.uint32(length);
        return client.send();
    }

    fn stat(client: *Client, name: []const u8) !sftp.Attrs {
        var reply = try client.named(sftp.FXP_STAT, name);
        try testing.expectEqual(sftp.FXP_ATTRS, reply.kind);
        return sftp.Attrs.read(&reply.reader);
    }

    fn setstat(client: *Client, name: []const u8, attrs: sftp.Attrs) !Reply {
        const writer = client.begin(sftp.FXP_SETSTAT);
        writer.string(name);
        attrs.write(writer);
        return client.send();
    }
};

const Reply = struct {
    kind: u8,
    reader: sftp.Reader,

    fn expectStatus(reply: *Reply, code: u32) !void {
        try testing.expectEqual(sftp.FXP_STATUS, reply.kind);
        try testing.expectEqual(code, reply.reader.uint32());
    }

    fn handle(reply: *Reply) ![8]u8 {
        try testing.expectEqual(sftp.FXP_HANDLE, reply.kind);
        const bytes = reply.reader.string();
        try testing.expectEqual(@as(usize, 8), bytes.len);
        return bytes[0..8].*;
    }

    fn data(reply: *Reply) ![]const u8 {
        try testing.expectEqual(sftp.FXP_DATA, reply.kind);
        return reply.reader.string();
    }

    /// A NAME's names, joined by spaces, and the first entry's long name.
    fn names(reply: *Reply, into: []u8, long: *[]const u8) ![]const u8 {
        try testing.expectEqual(sftp.FXP_NAME, reply.kind);
        const count = reply.reader.uint32();
        var at: usize = 0;
        for (0..count) |index| {
            const name = reply.reader.string();
            const long_name = reply.reader.string();
            if (index == 0) long.* = long_name;
            _ = sftp.Attrs.read(&reply.reader);
            if (index > 0) {
                into[at] = ' ';
                at += 1;
            }
            @memcpy(into[at..][0..name.len], name);
            at += name.len;
        }
        try testing.expect(!reply.reader.bad);
        return into[0..at];
    }
};

test "the version, and names: home, dots, the root" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const client = &rig.client;

    var init_packet: [9]u8 = undefined;
    var writer: sftp.Writer = .{ .bytes = &init_packet };
    writer.begin(sftp.FXP_INIT, null);
    writer.uint32(3);
    const version = rig.server.answer(writer.end());
    var reader: sftp.Reader = .{ .bytes = version[4..] };
    try testing.expectEqual(sftp.FXP_VERSION, reader.byte());
    try testing.expectEqual(@as(u32, 3), reader.uint32());

    var text: [64]u8 = undefined;
    var long: []const u8 = "";
    var reply = try client.named(sftp.FXP_REALPATH, ".");
    try testing.expectEqualStrings("/WORK", try reply.names(&text, &long));
    reply = try client.named(sftp.FXP_REALPATH, "a/./b/../../c//d");
    try testing.expectEqualStrings("/WORK/c/d", try reply.names(&text, &long));
    reply = try client.named(sftp.FXP_REALPATH, "/../../..");
    try testing.expectEqualStrings("/", try reply.names(&text, &long));
    // A colon is no part of a name.
    reply = try client.named(sftp.FXP_REALPATH, "/WORK:x");
    try reply.expectStatus(sftp.FX_FAILURE);

    // The root and a volume are directories.
    try testing.expect((try client.stat("/")).isDir());
    try testing.expect((try client.stat("/WORK")).isDir());
    try testing.expect((try client.stat("..")).isDir());
    reply = try client.named(sftp.FXP_STAT, "/NONE/x");
    try reply.expectStatus(sftp.FX_NO_SUCH_FILE);

    // `/` lists the mounted file system.
    reply = try client.named(sftp.FXP_OPENDIR, "/");
    const root = try reply.handle();
    client.begin(sftp.FXP_READDIR).string(&root);
    reply = try client.send();
    try testing.expectEqualStrings("WORK", try reply.names(&text, &long));
    try testing.expect(std.mem.startsWith(u8, long, "drwxr-xr-x    1 admin    admin           0 "));
    try testing.expect(std.mem.endsWith(u8, long, " WORK"));
    client.begin(sftp.FXP_READDIR).string(&root);
    try client.expectStatus(sftp.FX_EOF);
    try client.close(root);
    // Gone: the handle is no more.
    client.begin(sftp.FXP_READDIR).string(&root);
    try client.expectStatus(sftp.FX_FAILURE);
    // Neither the root nor a volume opens as a file.
    for ([_][]const u8{ "/", "/WORK" }) |name| {
        const open = client.begin(sftp.FXP_OPEN);
        open.string(name);
        open.uint32(sftp.FXF_READ);
        open.uint32(0);
        try client.expectStatus(sftp.FX_FAILURE);
    }
    // A request cut short.
    reply = try client.named(sftp.FXP_OPEN, "x");
    try reply.expectStatus(sftp.FX_BAD_MESSAGE);
}

test "a file written, read back, grown past its end, appended to" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const client = &rig.client;

    var file = try client.open("file", sftp.FXF_WRITE | sftp.FXF_CREAT | sftp.FXF_TRUNC);
    try client.write(file, 0, "hello ");
    try client.write(file, 6, "world");
    try client.close(file);
    const attrs = try client.stat("/WORK/file");
    try testing.expectEqual(@as(u64, 11), attrs.size);
    try testing.expectEqual(sftp.S_IFREG, attrs.permissions & sftp.S_IFMT);
    try testing.expectEqual(@as(u32, 0o755), attrs.permissions & 0o777);

    file = try client.open("/WORK/file", sftp.FXF_READ);
    var reply = try client.read(file, 6, 100);
    try testing.expectEqualStrings("world", try reply.data());
    reply = try client.read(file, 0, 5);
    try testing.expectEqualStrings("hello", try reply.data());
    reply = try client.read(file, 11, 100);
    try reply.expectStatus(sftp.FX_EOF);
    reply = try client.read(file, 50, 100);
    try reply.expectStatus(sftp.FX_EOF);
    try client.close(file);

    // Written past the end: the gap is zeroes.
    file = try client.open("file", sftp.FXF_WRITE);
    try client.write(file, 13, "!");
    try client.close(file);
    file = try client.open("file", sftp.FXF_READ);
    reply = try client.read(file, 0, 100);
    try testing.expectEqualStrings("hello world\x00\x00!", try reply.data());
    try client.close(file);

    // Appended: every write at the end, whatever its offset.
    file = try client.open("file", sftp.FXF_WRITE | sftp.FXF_APPEND);
    try client.write(file, 0, "?");
    try client.close(file);
    try testing.expectEqual(@as(u64, 15), (try client.stat("file")).size);

    // Made only when not there.
    const writer = client.begin(sftp.FXP_OPEN);
    writer.string("file");
    writer.uint32(sftp.FXF_WRITE | sftp.FXF_CREAT | sftp.FXF_EXCL);
    writer.uint32(0);
    try client.expectStatus(sftp.FX_FAILURE);
    // A file that is not there, read.
    const missing = client.begin(sftp.FXP_OPEN);
    missing.string("none");
    missing.uint32(sftp.FXF_READ);
    missing.uint32(0);
    try client.expectStatus(sftp.FX_NO_SUCH_FILE);

    // Emptied on opening.
    file = try client.open("file", sftp.FXF_WRITE | sftp.FXF_TRUNC);
    try client.close(file);
    try testing.expectEqual(@as(u64, 0), (try client.stat("file")).size);
}

test "directories: made, listed, renamed into, removed; permissions and times" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const client = &rig.client;

    const writer = client.begin(sftp.FXP_MKDIR);
    writer.string("/WORK/dir");
    writer.uint32(0);
    try client.expectStatus(sftp.FX_OK);
    const file = try client.open("file", sftp.FXF_WRITE | sftp.FXF_CREAT);
    try client.write(file, 0, "data");
    try client.close(file);
    const rename = client.begin(sftp.FXP_RENAME);
    rename.string("file");
    rename.string("dir/moved");
    try client.expectStatus(sftp.FX_OK);

    var text: [256]u8 = undefined;
    var long: []const u8 = "";
    var reply = try client.named(sftp.FXP_OPENDIR, "dir");
    const listing = try reply.handle();
    client.begin(sftp.FXP_READDIR).string(&listing);
    reply = try client.send();
    try testing.expectEqualStrings("moved", try reply.names(&text, &long));
    try testing.expect(std.mem.startsWith(u8, long, "-rwxr-xr-x    1 admin    admin           4 "));
    client.begin(sftp.FXP_READDIR).string(&listing);
    try client.expectStatus(sftp.FX_EOF);
    // FSTAT of the directory, and the handle closed.
    client.begin(sftp.FXP_FSTAT).string(&listing);
    reply = try client.send();
    try testing.expectEqual(sftp.FXP_ATTRS, reply.kind);
    try testing.expect(sftp.Attrs.read(&reply.reader).isDir());
    try client.close(listing);
    // A file is no directory to list.
    reply = try client.named(sftp.FXP_OPENDIR, "dir/moved");
    try reply.expectStatus(sftp.FX_FAILURE);

    // Read only: write and delete forbidden, and execute.
    reply = try client.setstat("dir/moved", .{ .flags = sftp.ATTR_PERMISSIONS, .permissions = 0o444 });
    try reply.expectStatus(sftp.FX_OK);
    try testing.expectEqual(@as(u32, 0o444), (try client.stat("dir/moved")).permissions & 0o777);
    reply = try client.named(sftp.FXP_REMOVE, "dir/moved");
    try reply.expectStatus(sftp.FX_PERMISSION_DENIED);
    reply = try client.setstat("dir/moved", .{ .flags = sftp.ATTR_PERMISSIONS, .permissions = 0o755 });
    try reply.expectStatus(sftp.FX_OK);

    // A time, as seconds since 1970, comes back as it went.
    reply = try client.setstat("dir/moved", .{ .flags = sftp.ATTR_ACMODTIME, .atime = 1_000_000_000, .mtime = 1_000_000_000 });
    try reply.expectStatus(sftp.FX_OK);
    try testing.expectEqual(@as(u32, 1_000_000_000), (try client.stat("dir/moved")).mtime);
    // A size cuts the file.
    reply = try client.setstat("dir/moved", .{ .flags = sftp.ATTR_SIZE, .size = 2 });
    try reply.expectStatus(sftp.FX_OK);
    try testing.expectEqual(@as(u64, 2), (try client.stat("dir/moved")).size);

    // FSETSTAT's time holds past the close.
    const again = try client.open("dir/moved", sftp.FXF_WRITE);
    try client.write(again, 2, "ta");
    const fsetstat = client.begin(sftp.FXP_FSETSTAT);
    fsetstat.string(&again);
    (sftp.Attrs{ .flags = sftp.ATTR_ACMODTIME, .atime = 1_200_000_000, .mtime = 1_200_000_000 }).write(fsetstat);
    try client.expectStatus(sftp.FX_OK);
    try client.close(again);
    const attrs = try client.stat("dir/moved");
    try testing.expectEqual(@as(u32, 1_200_000_000), attrs.mtime);
    try testing.expectEqual(@as(u64, 4), attrs.size);

    // REMOVE takes files, RMDIR directories, an empty one.
    reply = try client.named(sftp.FXP_REMOVE, "dir");
    try reply.expectStatus(sftp.FX_FAILURE);
    reply = try client.named(sftp.FXP_RMDIR, "dir/moved");
    try reply.expectStatus(sftp.FX_FAILURE);
    reply = try client.named(sftp.FXP_RMDIR, "dir");
    try reply.expectStatus(sftp.FX_FAILURE);
    reply = try client.named(sftp.FXP_REMOVE, "dir/moved");
    try reply.expectStatus(sftp.FX_OK);
    reply = try client.named(sftp.FXP_RMDIR, "dir");
    try reply.expectStatus(sftp.FX_OK);
    reply = try client.named(sftp.FXP_STAT, "dir");
    try reply.expectStatus(sftp.FX_NO_SUCH_FILE);
    // The volume itself stays.
    reply = try client.named(sftp.FXP_RMDIR, "/WORK");
    try reply.expectStatus(sftp.FX_PERMISSION_DENIED);
}

test "handles: a stale one refused, the last slot, those left open closed at the end" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const client = &rig.client;

    const first = try client.open("a", sftp.FXF_WRITE | sftp.FXF_CREAT);
    try client.close(first);
    // The slot used again: the old handle names it no more.
    const second = try client.open("a", sftp.FXF_READ);
    try testing.expectEqualSlices(u8, first[0..4], second[0..4]);
    var reply = try client.read(first, 0, 10);
    try reply.expectStatus(sftp.FX_FAILURE);

    // Every slot taken: one more is refused.
    for (1..@import("../sftp.zig").handles_max) |_| _ = try client.open("a", sftp.FXF_READ);
    const writer = client.begin(sftp.FXP_OPEN);
    writer.string("a");
    writer.uint32(sftp.FXF_READ);
    writer.uint32(0);
    try client.expectStatus(sftp.FX_FAILURE);
    // An unknown request is said to be one.
    client.begin(sftp.FXP_SYMLINK).string("a");
    try client.expectStatus(sftp.FX_OP_UNSUPPORTED);
    // The rig's end closes every one left open.
}
