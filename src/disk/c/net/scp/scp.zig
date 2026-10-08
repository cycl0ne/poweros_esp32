// SPDX-License-Identifier: MIT
//! SCP: copies files to and from another machine over SSH - the client's
//! end of ssh.device, speaking SFTP in the `sftp` subsystem, as `scp`
//! does. Built against the SDK only.
//!
//!   SCP FROM/A,TO/A,ALL/S,PORT/K/N,USER/K,QUIET/S
//!
//! One of FROM and TO is on the other machine: `user@host:path`, or
//! `host:path` when no device, volume or assign here is called `host`;
//! an IPv6 address goes in brackets (`[fe80::1]:path`). The path there
//! is from the home directory unless it starts at `/`; empty, it is the
//! home directory. The other name is one here (`RAM:x`, `SYS:C/List`).
//! The user is the one before the `@`, else USER, else the variable USER;
//! the connection, the host key and the login are as for C:net/SSH
//! (sdk/devices/ssh/connect.zig), on PORT (22).
//!
//! **What is copied.** A file goes to TO, or into TO under its own name
//! when TO is a directory. A directory needs ALL: it is copied with
//! everything in it, to TO - or into TO under its own name when TO is a
//! directory already. Each file copied is listed with its size unless
//! QUIET. A file there is replaced; a copy stopped part way leaves what
//! it wrote.
//!
//! **How.** Requests go out several at a time - four reads or writes of
//! 32 KiB each in flight - so the round trips overlap. Ctrl-C stops
//! between them. The return code is 0 when all was copied, 10 when
//! something could not be, 20 when there was no connection.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const crypto = sdk.crypto;
const ssh = sdk.devices.ssh;
const sftp = ssh.sftp;
const connect = ssh.connect;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "SCP";
const VERSION_STRING = "\x00$VER: SCP 1.0 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FROM/A,TO/A,ALL/S,PORT/K/N,USER/K,QUIET/S";
const arg_from = 0;
const arg_to = 1;
const arg_all = 2;
const arg_port = 3;
const arg_user = 4;
const arg_quiet = 5;

/// The data of one READ or WRITE, and how many are in flight.
const chunk: u32 = 32 * 1024;
const window = 4;
/// The longest name, here or there.
const path_max = 1024;
const handle_max = 256;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_PLACES = "%s: one of FROM and TO is on the other machine (user@host:path), the other here\n";
const MSG_REFUSED = "%s: the server has no sftp\n";
const MSG_PROTOCOL = "%s: the server's answer is not SFTP\n";
const MSG_THERE = "%s: %s: %s\n";
const MSG_HERE = "%s: %s";
const MSG_DIRECTORY = "%s: %s is a directory; ALL copies it\n";
const MSG_COPIED = "%s  %lu bytes\n";
const MSG_BREAK = "%s: stopped\n";

const Place = struct {
    remote: bool = false,
    /// `user@host` or `host`, without the brackets.
    user: []const u8 = "",
    host: []const u8 = "",
    path: []const u8 = "",
};

/// Everything the command keeps: too big for a command's stack.
const State = struct {
    sys: *ExecBase,
    dl: *DosBase,
    client: connect.Client,
    reply_port: *exec.MsgPort,
    read_io: *exec.IOStdReq,
    write_io: *exec.IOStdReq,
    all: bool,
    quiet: bool,
    /// Ctrl-C came, or the connection went: nothing more is sent.
    broken: bool = false,
    /// Something could not be copied.
    failures: u32 = 0,
    next_id: u32 = 1,

    /// The names, there and here, a part pushed as a directory is gone
    /// into and cut off as it is left.
    remote: [path_max]u8 = undefined,
    remote_length: usize = 0,
    local: [path_max:0]u8 = @splat(0),

    /// What came from the server, and the packet taken from it last.
    input: [sftp.packet_max]u8 = undefined,
    input_length: usize = 0,
    taken: usize = 0,
    /// A request, built.
    out: [sftp.packet_max]u8 = undefined,

    /// The last STATUS's text, for what is said about it.
    message: [128]u8 = undefined,
    message_length: usize = 0,
    remote_text: [path_max + 1]u8 = undefined,

    fn takeId(st: *State) u32 {
        const id = st.next_id;
        st.next_id +%= 1;
        return id;
    }

    fn send(st: *State, bytes: []const u8) bool {
        if (bytes.len == 0 or st.broken) return false;
        return st.exchange(st.write_io, exec.CMD_WRITE, @constCast(bytes.ptr), bytes.len);
    }

    /// The next packet from the server, the one before let go: its type
    /// and what follows the id. Null when the connection went, Ctrl-C
    /// came, or what came is not SFTP.
    fn receive(st: *State) ?Reply {
        if (st.broken) return null;
        if (st.taken > 0) {
            const rest = st.input_length - st.taken;
            if (rest > 0) @memmove(st.input[0..rest], st.input[st.taken..st.input_length]);
            st.input_length = rest;
            st.taken = 0;
        }
        while (true) {
            if (sftp.packetLength(st.input[0..st.input_length])) |length| {
                if (length > st.input.len or length < 5) {
                    st.protocol();
                    return null;
                }
                if (length <= st.input_length) {
                    st.taken = length;
                    var reader: sftp.Reader = .{ .bytes = st.input[4..length] };
                    const kind = reader.byte();
                    if (kind != sftp.FXP_VERSION) _ = reader.uint32();
                    return .{ .kind = kind, .reader = reader };
                }
            }
            if (!st.exchange(st.read_io, exec.CMD_READ, &st.input[st.input_length], st.input.len - st.input_length)) return null;
            st.input_length += @intCast(st.read_io.actual);
        }
    }

    /// A request to the device, waited for; Ctrl-C aborts it. False, and
    /// nothing more sent, when it failed.
    fn exchange(st: *State, io: *exec.IOStdReq, command: u16, data: ?*anyopaque, length: usize) bool {
        const sys = st.sys;
        io.req.command = command;
        io.data = data;
        io.length = length;
        sys.SendIO(&io.req);
        while (sys.CheckIO(&io.req) == null) {
            const got = sys.Wait(st.reply_port.sigMask() | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0 and sys.CheckIO(&io.req) == null) {
                _ = sys.AbortIO(&io.req);
                _ = sys.WaitIO(&io.req);
                _ = Printf(st.dl, MSG_BREAK, .{COMMAND_NAME});
                st.broken = true;
                return false;
            }
        }
        _ = sys.WaitIO(&io.req);
        if (io.req.err != 0) {
            // Why the connection went, said as a step's would be.
            st.client.io.req.err = io.req.err;
            st.client.io.actual = io.actual;
            st.client.gone();
            st.broken = true;
            return false;
        }
        return true;
    }

    /// A request naming `remote` - MKDIR with no attributes - answered
    /// by a STATUS: its code.
    fn simple(st: *State, kind: u8) u32 {
        var writer: sftp.Writer = .{ .bytes = &st.out };
        writer.begin(kind, st.takeId());
        writer.string(st.remote[0..st.remote_length]);
        if (kind == sftp.FXP_MKDIR) writer.uint32(0);
        if (!st.send(writer.end())) return sftp.FX_CONNECTION_LOST;
        const reply = st.receive() orelse return sftp.FX_CONNECTION_LOST;
        if (reply.kind != sftp.FXP_STATUS) {
            st.protocol();
            return sftp.FX_BAD_MESSAGE;
        }
        return st.keepStatus(reply);
    }

    /// `remote`'s attributes; null, the STATUS kept, when it is not
    /// there.
    fn stat(st: *State) ?sftp.Attrs {
        var writer: sftp.Writer = .{ .bytes = &st.out };
        writer.begin(sftp.FXP_STAT, st.takeId());
        writer.string(st.remote[0..st.remote_length]);
        if (!st.send(writer.end())) return null;
        var reply = st.receive() orelse return null;
        switch (reply.kind) {
            sftp.FXP_ATTRS => return sftp.Attrs.read(&reply.reader),
            sftp.FXP_STATUS => _ = st.keepStatus(reply),
            else => st.protocol(),
        }
        return null;
    }

    /// `remote` opened, a file with `flags` (OPEN) or a directory
    /// (OPENDIR): its handle. False, the STATUS kept, when not.
    fn open(st: *State, kind: u8, flags: u32, handle: *Handle) bool {
        var writer: sftp.Writer = .{ .bytes = &st.out };
        writer.begin(kind, st.takeId());
        writer.string(st.remote[0..st.remote_length]);
        if (kind == sftp.FXP_OPEN) {
            writer.uint32(flags);
            writer.uint32(0);
        }
        if (!st.send(writer.end())) return false;
        var reply = st.receive() orelse return false;
        switch (reply.kind) {
            sftp.FXP_HANDLE => {
                const bytes = reply.reader.string();
                if (reply.reader.bad or bytes.len > handle.bytes.len) {
                    st.protocol();
                    return false;
                }
                @memcpy(handle.bytes[0..bytes.len], bytes);
                handle.length = bytes.len;
                return true;
            },
            sftp.FXP_STATUS => _ = st.keepStatus(reply),
            else => st.protocol(),
        }
        return false;
    }

    fn close(st: *State, handle: *Handle) void {
        var writer: sftp.Writer = .{ .bytes = &st.out };
        writer.begin(sftp.FXP_CLOSE, st.takeId());
        writer.string(handle.bytes[0..handle.length]);
        if (st.send(writer.end())) _ = st.receive();
    }

    fn readdir(st: *State, handle: *Handle) ?Reply {
        var writer: sftp.Writer = .{ .bytes = &st.out };
        writer.begin(sftp.FXP_READDIR, st.takeId());
        writer.string(handle.bytes[0..handle.length]);
        if (!st.send(writer.end())) return null;
        return st.receive();
    }

    /// A STATUS's code, and its text kept.
    fn keepStatus(st: *State, reply: Reply) u32 {
        var reader = reply.reader;
        const code = reader.uint32();
        const text = reader.string();
        const length = @min(text.len, st.message.len);
        @memcpy(st.message[0..length], text[0..length]);
        st.message_length = length;
        if (length == 0) {
            const fallback: []const u8 = switch (code) {
                sftp.FX_NO_SUCH_FILE => "no such file",
                sftp.FX_PERMISSION_DENIED => "permission denied",
                else => "failed",
            };
            @memcpy(st.message[0..fallback.len], fallback);
            st.message_length = fallback.len;
        }
        return code;
    }

    /// What went wrong there, said with the name there.
    fn thereFailed(st: *State) void {
        st.failures += 1;
        if (st.broken) return;
        st.message[@min(st.message_length, st.message.len - 1)] = 0;
        _ = Printf(st.dl, MSG_THERE, .{ COMMAND_NAME, st.remoteName(), @as([*:0]const u8, @ptrCast(&st.message)) });
    }

    fn statusFailed(st: *State, reply: Reply) void {
        _ = st.keepStatus(reply);
        st.thereFailed();
    }

    /// What went wrong here, said with the name here.
    fn hereFailed(st: *State) void {
        st.failures += 1;
        _ = st.dl.PrintFault(st.dl.IoErr(), &st.local);
    }

    fn protocol(st: *State) void {
        if (!st.broken) _ = Printf(st.dl, MSG_PROTOCOL, .{COMMAND_NAME});
        st.broken = true;
    }

    fn copied(st: *State, name: [*:0]const u8, bytes: u64) void {
        if (!st.quiet) _ = Printf(st.dl, MSG_COPIED, .{ name, bytes });
    }

    fn remoteName(st: *State) [*:0]const u8 {
        @memcpy(st.remote_text[0..st.remote_length], st.remote[0..st.remote_length]);
        st.remote_text[st.remote_length] = 0;
        return @ptrCast(&st.remote_text);
    }

    /// `name` put after the name there, a `/` between.
    fn pushRemote(st: *State, name: []const u8) bool {
        const slash: usize = if (st.remote_length > 0 and st.remote[st.remote_length - 1] != '/') 1 else 0;
        if (st.remote_length + slash + name.len > st.remote.len) {
            st.failures += 1;
            return false;
        }
        if (slash == 1) st.remote[st.remote_length] = '/';
        @memcpy(st.remote[st.remote_length + slash ..][0..name.len], name);
        st.remote_length += slash + name.len;
        return true;
    }

    /// `name` put after the name here, as AddPart puts it.
    fn pushLocal(st: *State, name: []const u8) bool {
        var text: [dos.name_max + 1:0]u8 = @splat(0);
        if (name.len > dos.name_max) {
            st.failures += 1;
            return false;
        }
        @memcpy(text[0..name.len], name);
        if (!st.dl.AddPart(&st.local, &text, st.local.len)) {
            st.hereFailed();
            return false;
        }
        return true;
    }
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const from = place(dl, span(dos.rdargs.string(argv[arg_from]).?));
    const to = place(dl, span(dos.rdargs.string(argv[arg_to]).?));
    if (from.remote == to.remote) {
        _ = Printf(dl, MSG_PLACES, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    const there = if (from.remote) from else to;

    const crypto_lib = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, crypto.CRYPTONAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(crypto_lib);
    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);

    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_CLEAR) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(memory);
    const st: *State = @ptrCast(@alignCast(memory));
    const reply_port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(reply_port);
    var requests: [3]*exec.IOStdReq = undefined;
    var made: usize = 0;
    defer for (requests[0..made]) |io| sys.DeleteIORequest(&io.req);
    while (made < requests.len) : (made += 1) {
        const request = sys.CreateIORequest(reply_port, @sizeOf(exec.IOStdReq)) orelse return dos.RETURN_FAIL;
        requests[made] = @fieldParentPtr("req", request);
    }
    st.* = .{
        .sys = sys,
        .dl = dl,
        .client = .{
            .sys = sys,
            .dl = dl,
            .sb = @ptrCast(socket_lib),
            .cb = @ptrCast(crypto_lib),
            .program = COMMAND_NAME,
            .input = dl.Input().?,
            .output = dl.Output().?,
            .reply_port = reply_port,
            .io = requests[0],
        },
        .reply_port = reply_port,
        .read_io = requests[1],
        .write_io = requests[2],
        .all = argv[arg_all] != 0,
        .quiet = argv[arg_quiet] != 0,
    };
    const client = &st.client;
    const given_user = dos.rdargs.string(argv[arg_user]);
    const user: ?[]const u8 = if (given_user) |name| span(name) else if (there.user.len > 0) there.user else null;
    if (!client.names(there.host, user)) return dos.RETURN_FAIL;
    if (dos.rdargs.number(argv[arg_port])) |value| client.port = @truncate(@as(u32, @bitCast(value)));

    if (!client.start()) return dos.RETURN_FAIL;
    defer client.stop();
    client.share(st.read_io);
    client.share(st.write_io);
    if (!startSftp(st)) return dos.RETURN_FAIL;

    if (from.remote) {
        download(st, from.path, to.path);
    } else {
        upload(st, from.path, to.path);
    }
    _ = client.step(ssh.SSHCMD_EOF, null, 0);
    if (st.broken) return dos.RETURN_FAIL;
    return if (st.failures > 0) dos.RETURN_ERROR else dos.RETURN_OK;
}

/// Where a name is: on the other machine or here.
fn place(dl: *DosBase, text: []const u8) Place {
    var result: Place = .{ .path = text };
    var rest = text;
    var user: []const u8 = "";
    const colon = indexOf(text, ':') orelse return result;
    if (indexOf(text[0..colon], '@')) |at| {
        if (indexOf(text[0..at], '/') == null) {
            user = text[0..at];
            rest = text[at + 1 ..];
        }
    }
    if (rest.len > 0 and rest[0] == '[') {
        const end = indexOf(rest, ']') orelse return result;
        if (end + 1 >= rest.len or rest[end + 1] != ':') return result;
        return .{ .remote = true, .user = user, .host = rest[1..end], .path = rest[end + 2 ..] };
    }
    const host_end = indexOf(rest, ':') orelse return result;
    if (indexOf(rest[0..host_end], '/') != null or host_end == 0) return result;
    const host = rest[0..host_end];
    // `name:path` is a name here when dos knows the name.
    if (user.len == 0 and knownHere(dl, host)) return result;
    result = .{ .remote = true, .user = user, .host = host, .path = rest[host_end + 1 ..] };
    return result;
}

fn knownHere(dl: *DosBase, name: []const u8) bool {
    var text: [32:0]u8 = @splat(0);
    if (name.len >= text.len) return false;
    @memcpy(text[0..name.len], name);
    const flags = dos.LDF_ALL | dos.LDF_READ;
    const start = dl.LockDosList(flags) orelse return false;
    defer dl.UnLockDosList(flags);
    return dl.FindDosEntry(start, &text, dos.LDF_ALL) != null;
}

// --- Copying ----------------------------------------------------------------

/// FROM here to TO there.
fn upload(st: *State, from: []const u8, to: []const u8) void {
    const dl = st.dl;
    if (!setLocal(st, from)) return;
    const lock = dl.Lock(&st.local, dos.SHARED_LOCK) orelse return st.hereFailed();
    const fib = st.sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_CLEAR) orelse {
        dl.UnLock(lock);
        return;
    };
    defer st.sys.FreeVec(fib);
    const info: *dos.FileInfoBlock = @ptrCast(@alignCast(fib));
    const examined = dl.Examine(lock, info);
    dl.UnLock(lock);
    if (!examined) return st.hereFailed();
    const directory = info.dir_entry_type > 0;
    if (directory and !st.all) {
        _ = Printf(dl, MSG_DIRECTORY, .{ COMMAND_NAME, @as([*:0]const u8, &st.local) });
        st.failures += 1;
        return;
    }
    setRemote(st, if (to.len == 0) "." else to);
    // Into TO when it is a directory there.
    if (st.stat()) |attrs| {
        if (attrs.isDir()) {
            const name = span(dl.FilePart(&st.local));
            if (name.len > 0) _ = st.pushRemote(name);
        }
    }
    if (directory) putDirectory(st) else putFile(st);
}

/// FROM there to TO here.
fn download(st: *State, from: []const u8, to: []const u8) void {
    const dl = st.dl;
    setRemote(st, if (from.len == 0) "." else from);
    const attrs = st.stat() orelse return st.thereFailed();
    const directory = attrs.isDir();
    if (directory and !st.all) {
        _ = Printf(dl, MSG_DIRECTORY, .{ COMMAND_NAME, st.remoteName() });
        st.failures += 1;
        return;
    }
    if (!setLocal(st, to)) return;
    // Into TO when it is a directory here.
    if (dl.Lock(&st.local, dos.SHARED_LOCK)) |lock| {
        var info: dos.FileInfoBlock = .{};
        const is_directory = dl.Examine(lock, &info) and info.dir_entry_type > 0;
        dl.UnLock(lock);
        const name = lastPart(st.remote[0..st.remote_length]);
        if (is_directory and name.len > 0 and !same(name, ".") and !same(name, "..")) {
            if (!st.pushLocal(name)) return;
        }
    }
    if (directory) getDirectory(st) else getFile(st);
}

/// The directory here at `local`, everything in it, to `remote` there.
fn putDirectory(st: *State) void {
    const dl = st.dl;
    const sys = st.sys;
    var status = st.simple(sftp.FXP_MKDIR);
    // There already, as a directory, is as good.
    if (status != sftp.FX_OK) {
        if (st.stat()) |attrs| {
            if (attrs.isDir()) status = sftp.FX_OK;
        }
    }
    if (status != sftp.FX_OK) return st.thereFailed();
    const lock = dl.Lock(&st.local, dos.SHARED_LOCK) orelse return st.hereFailed();
    defer dl.UnLock(lock);
    const fib = sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_CLEAR) orelse return;
    defer sys.FreeVec(fib);
    const info: *dos.FileInfoBlock = @ptrCast(@alignCast(fib));
    if (!dl.Examine(lock, info)) return st.hereFailed();
    while (!st.broken and dl.ExNext(lock, info)) {
        const name: [*:0]const u8 = @ptrCast(&info.file_name);
        const local_length = span(&st.local).len;
        const remote_length = st.remote_length;
        if (dl.AddPart(&st.local, name, st.local.len) and st.pushRemote(span(name))) {
            if (info.dir_entry_type > 0) putDirectory(st) else putFile(st);
        }
        st.local[local_length] = 0;
        st.remote_length = remote_length;
    }
}

/// The directory there at `remote`, everything in it, to `local` here.
fn getDirectory(st: *State) void {
    const dl = st.dl;
    const sys = st.sys;
    if (dl.CreateDir(&st.local)) |made| {
        dl.UnLock(made);
    } else if (dl.IoErr() != dos.ERROR_OBJECT_EXISTS) {
        return st.hereFailed();
    }
    var handle: Handle = .{};
    if (!st.open(sftp.FXP_OPENDIR, 0, &handle)) return st.thereFailed();
    defer st.close(&handle);
    while (!st.broken) {
        const reply = st.readdir(&handle) orelse return;
        if (reply.kind == sftp.FXP_STATUS) {
            var reader = reply.reader;
            if (reader.uint32() != sftp.FX_EOF) st.statusFailed(reply);
            return;
        }
        if (reply.kind != sftp.FXP_NAME) return st.protocol();
        // The names kept apart from the input, which going into each one
        // takes over.
        const bytes = reply.reader.bytes[reply.reader.at..];
        const kept = sys.AllocVec(bytes.len, exec.MEMF_ANY) orelse return;
        defer sys.FreeVec(kept);
        const names: [*]u8 = @ptrCast(kept);
        @memcpy(names[0..bytes.len], bytes);
        var reader: sftp.Reader = .{ .bytes = names[0..bytes.len] };
        const count = reader.uint32();
        for (0..count) |_| {
            const name = reader.string();
            _ = reader.string();
            const attrs = sftp.Attrs.read(&reader);
            if (reader.bad or st.broken) break;
            if (same(name, ".") or same(name, "..") or name.len == 0) continue;
            const local_length = span(&st.local).len;
            const remote_length = st.remote_length;
            if (st.pushLocal(name) and st.pushRemote(name)) {
                if (attrs.isDir()) getDirectory(st) else getFile(st);
            }
            st.local[local_length] = 0;
            st.remote_length = remote_length;
        }
    }
}

/// The file here at `local` to `remote` there, its writes in flight
/// `window` at a time.
fn putFile(st: *State) void {
    const dl = st.dl;
    const file = dl.Open(&st.local, dos.MODE_OLDFILE) orelse return st.hereFailed();
    defer _ = dl.Close(file);
    var handle: Handle = .{};
    if (!st.open(sftp.FXP_OPEN, sftp.FXF_WRITE | sftp.FXF_CREAT | sftp.FXF_TRUNC, &handle)) return st.thereFailed();
    var offset: u64 = 0;
    var in_flight: u32 = 0;
    var ended = false;
    var good = true;
    while (good and !st.broken and (!ended or in_flight > 0)) {
        while (!ended and in_flight < window) {
            var writer: sftp.Writer = .{ .bytes = &st.out };
            writer.begin(sftp.FXP_WRITE, st.takeId());
            writer.string(handle.bytes[0..handle.length]);
            writer.uint64(offset);
            const length_at = writer.at;
            writer.uint32(0);
            const got = dl.Read(file, st.out[writer.at..].ptr, chunk);
            if (got < 0) {
                st.hereFailed();
                good = false;
                break;
            }
            if (got == 0) {
                ended = true;
                break;
            }
            sftp.put32(st.out[length_at..][0..4], @intCast(got));
            writer.at += @intCast(got);
            if (!st.send(writer.end())) {
                good = false;
                break;
            }
            offset += @intCast(got);
            in_flight += 1;
        }
        if (in_flight == 0) break;
        const reply = st.receive() orelse {
            good = false;
            break;
        };
        in_flight -= 1;
        if (reply.kind != sftp.FXP_STATUS) {
            st.protocol();
            good = false;
        } else {
            var reader = reply.reader;
            if (reader.uint32() != sftp.FX_OK) {
                st.statusFailed(reply);
                good = false;
            }
        }
    }
    // The answers still on their way, taken.
    while (in_flight > 0 and !st.broken) : (in_flight -= 1) _ = st.receive() orelse break;
    st.close(&handle);
    if (good and !st.broken) st.copied(&st.local, offset);
}

/// The file there at `remote` to `local` here, its reads in flight
/// `window` at a time. A short answer has the rest asked for again; an
/// answer for a place already passed is let go.
fn getFile(st: *State) void {
    const dl = st.dl;
    var handle: Handle = .{};
    if (!st.open(sftp.FXP_OPEN, sftp.FXF_READ, &handle)) return st.thereFailed();
    defer st.close(&handle);
    const file = dl.Open(&st.local, dos.MODE_NEWFILE) orelse return st.hereFailed();
    defer _ = dl.Close(file);
    var asked: [window]u64 = undefined;
    var first: usize = 0;
    var in_flight: usize = 0;
    var next: u64 = 0;
    var written: u64 = 0;
    var ended = false;
    var good = true;
    while (good and !st.broken and (!ended or in_flight > 0)) {
        while (!ended and in_flight < window) {
            var writer: sftp.Writer = .{ .bytes = &st.out };
            writer.begin(sftp.FXP_READ, st.takeId());
            writer.string(handle.bytes[0..handle.length]);
            writer.uint64(next);
            writer.uint32(chunk);
            if (!st.send(writer.end())) {
                good = false;
                break;
            }
            asked[(first + in_flight) % window] = next;
            in_flight += 1;
            next += chunk;
        }
        if (in_flight == 0) break;
        const reply = st.receive() orelse {
            good = false;
            break;
        };
        const offset = asked[first];
        first = (first + 1) % window;
        in_flight -= 1;
        var reader = reply.reader;
        switch (reply.kind) {
            sftp.FXP_DATA => {
                const data = reader.string();
                if (reader.bad) {
                    st.protocol();
                    good = false;
                } else if (offset == written and data.len > 0) {
                    if (dl.Write(file, data.ptr, @intCast(data.len)) != data.len) {
                        st.hereFailed();
                        good = false;
                    }
                    written += data.len;
                    // Short: what follows is asked for from here.
                    if (data.len < chunk) next = written;
                }
            },
            sftp.FXP_STATUS => {
                const code = reader.uint32();
                if (code == sftp.FX_EOF) {
                    if (offset <= written) ended = true;
                } else {
                    st.statusFailed(reply);
                    good = false;
                }
            },
            else => {
                st.protocol();
                good = false;
            },
        }
    }
    while (in_flight > 0 and !st.broken) : (in_flight -= 1) _ = st.receive() orelse break;
    if (good and !st.broken) st.copied(st.remoteName(), written);
}

// --- SFTP -----------------------------------------------------------------

const Handle = struct {
    bytes: [handle_max]u8 = undefined,
    length: usize = 0,
};

const Reply = struct {
    kind: u8,
    reader: sftp.Reader,
};

/// The session: the `sftp` subsystem, and its INIT answered.
fn startSftp(st: *State) bool {
    var session: ssh.SshSession = .{ .subsystem = 1 };
    @memcpy(session.command[0..4], "sftp");
    switch (st.client.step(ssh.SSHCMD_SESSION, &session, @sizeOf(ssh.SshSession))) {
        0 => {},
        ssh.SSHERR_SESSION => {
            _ = Printf(st.dl, MSG_REFUSED, .{COMMAND_NAME});
            return false;
        },
        else => {
            st.client.gone();
            return false;
        },
    }
    var writer: sftp.Writer = .{ .bytes = &st.out };
    writer.begin(sftp.FXP_INIT, null);
    writer.uint32(sftp.version);
    if (!st.send(writer.end())) return false;
    const reply = st.receive() orelse return false;
    if (reply.kind != sftp.FXP_VERSION) {
        st.protocol();
        return false;
    }
    return true;
}

fn setRemote(st: *State, path: []const u8) void {
    const length = @min(path.len, st.remote.len);
    @memcpy(st.remote[0..length], path[0..length]);
    st.remote_length = length;
}

fn setLocal(st: *State, path: []const u8) bool {
    if (path.len >= st.local.len) {
        _ = st.dl.SetIoErr(dos.ERROR_LINE_TOO_LONG);
        st.hereFailed();
        return false;
    }
    @memcpy(st.local[0..path.len], path);
    st.local[path.len] = 0;
    return true;
}

fn lastPart(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/') start -= 1;
    return path[start..end];
}

fn span(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

fn indexOf(text: []const u8, char: u8) ?usize {
    for (text, 0..) |each, index| if (each == char) return index;
    return null;
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
