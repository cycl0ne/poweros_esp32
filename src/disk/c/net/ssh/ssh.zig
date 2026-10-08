// SPDX-License-Identifier: MIT
//! SSH: a shell, or one command, on another machine, over an encrypted
//! connection - the client's end of ssh.device. Built against the SDK
//! only.
//!
//!   SSH HOST,PORT/K/N,USER/K,KEYGEN/S,COMMAND/F
//!
//! It connects to HOST - a name, an IPv4 or an IPv6 address; `user@host`
//! names the user too - on PORT (22), and logs in as USER, or as the
//! variable USER says when neither names one.
//!
//! **The host key.** `ENVARC:Sys/net/known_hosts` holds the host keys
//! seen before, a line each as OpenSSH writes them: the host's name
//! (`[name]:port` for a port other than 22), `ssh-ed25519` and the key. A
//! host not in it has its key's fingerprint shown, and is asked about:
//! `yes` connects and keeps the key. A host whose key is not the one kept
//! is refused - someone may be in between - until its line is taken out
//! of the file.
//!
//! **The login**: with the key `ENVARC:Sys/net/id_ed25519` first, when
//! there is one, and then with a password, asked for without its echo,
//! three tries - asked for only when the server takes passwords. A banner
//! the server sends is shown before the password is asked for: as
//! Latin-1, the characters the console has not as `?`, and without its
//! control characters, so it cannot work the console. `SSH KEYGEN` makes the key - an Ed25519 key, its seed and
//! public half, 64 bytes - and writes its public line beside it in
//! `id_ed25519.pub`, for the other machine's `authorized_keys`.
//!
//! **The session.** Without COMMAND, a shell: the console runs raw, as a
//! terminal of type xterm-256color whose size it tells the server - the
//! console says it when asked (`CSI 18 t`), and is asked again every two
//! seconds; 80 by 24 when it never answers. Every key goes to the shell,
//! Ctrl-C too, and Backspace as DEL, as an xterm's does; `~.` at the start
//! of a line ends the connection, `~~` there sends one `~`. With COMMAND
//! the command runs without a terminal: lines typed go to it, Ctrl-\ ends
//! its input and Ctrl-C the connection. Input that is not a console - a
//! file - goes to the shell or the command as it is, and its end is the
//! end of their input.
//!
//! The return code is the session's exit status, 20 when it gave none, or
//! when there was no session.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const ssh = sdk.devices.ssh;
const ssh_keys = sdk.devices.ssh.keys;
const timer = sdk.devices.timer;
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const DosPacket = dos.dosextens.DosPacket;
const FileHandle = dos.FileHandle;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "SSH";
const VERSION_STRING = "\x00$VER: SSH 1.0 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "HOST,PORT/K/N,USER/K,KEYGEN/S,COMMAND/F";
const arg_host = 0;
const arg_port = 1;
const arg_user = 2;
const arg_keygen = 3;
const arg_command = 4;

const KEY_FILE = "ENVARC:Sys/net/id_ed25519";
const KEY_PUB_FILE = "ENVARC:Sys/net/id_ed25519.pub";
const KNOWN_HOSTS_FILE = "ENVARC:Sys/net/known_hosts";
const TERMINAL = "xterm-256color";
const port_default: u16 = 22;
const password_tries = 3;
/// How long the console has to say its size, and how often it is asked
/// again.
const size_answer_us = 300_000;
const size_every_us = 2_000_000;
/// The size of a console that never says.
const columns_default = 80;
const rows_default = 24;
/// The question that asks a console its size.
const SIZE_QUESTION = "\x1b[18t";
const known_hosts_max = 16384;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_USAGE = "%s: HOST is needed\n";
const MSG_NOUSER = "%s: no user: give USER, user@host, or set the variable USER\n";
const MSG_NOHOST = "%s: can't find %s\n";
const MSG_FAILED = "%s: %s failed: %s (errno %d)\n";
const MSG_NODEVICE = "%s: can't open %s\n";
const MSG_GONE = "%s: %s: %s\n";
const MSG_BREAK = "%s: stopped\n";
const MSG_UNKNOWN = "The host %s is not known. The fingerprint of its key is\n  %s (ED25519)\nConnect, and keep the key in %s (yes/no)? ";
const MSG_KEPT = "%s: kept the key of %s\n";
const MSG_CHANGED = "%s: the host key of %s is not the one kept in %s!\n  Its fingerprint now: %s\n  Someone may be in between. If the host has a new key, take its line out of the file.\n";
const MSG_NOASK = "%s: the host %s is not known, and there is no console to ask\n";
const MSG_PASSWORD = "%s@%s's password: ";
const MSG_DENIED = "%s: permission denied (%s)\n";
const MSG_REFUSED = "%s: the server refused the session\n";
const MSG_CLOSED = "\nConnection to %s closed.\n";
const MSG_KEY_EXISTS = "%s: %s is there already; delete it first to make a new key\n";
const MSG_KEY_MADE = "%s: made %s; its public line, in %s too:\n%s";
const MSG_KEY_PRINT = "Its fingerprint: %s\n";
const MSG_KEY_FAILED = "%s: can't write %s\n";

/// Everything the command keeps: too big for a command's stack.
const State = struct {
    sys: *ExecBase,
    dl: *DosBase,
    sb: *SocketBase,
    cb: *CryptoBase,
    host: [*:0]const u8,
    /// The name known_hosts knows the host by.
    host_name: [264]u8 = @splat(0),
    host_name_length: usize = 0,
    user: [64]u8 = @splat(0),
    port: u16 = port_default,

    // --- the device --------------------------------------------------------

    reply_port: *exec.MsgPort,
    /// The steps', the reads', the writes' and the status' requests.
    io: *exec.IOStdReq,
    read_io: *exec.IOStdReq,
    write_io: *exec.IOStdReq,
    status_io: *exec.IOStdReq,
    connect: ssh.SshConnect = .{},
    login: ssh.SshLogin = .{},
    session: ssh.SshSession = .{},

    // --- the console -------------------------------------------------------

    /// Our own handle on the console, when the input is one: closing it
    /// ends a READ still waiting.
    console: ?*FileHandle = null,
    /// Where the input is read from: the console, or the input as it is.
    input: *FileHandle,
    output: *FileHandle,
    /// The console is raw: a terminal session.
    raw: bool = false,
    packet: DosPacket = DosPacket.init(.read, .{ .raw = @splat(0) }),
    columns: u32 = columns_default,
    rows: u32 = rows_default,
    /// The console has said its size, so it is asked again.
    answers: bool = false,
    /// The input is read: not when it is a console this command cannot
    /// have a handle of its own on.
    reading: bool = true,
    /// At the start of a line, a `~` there held back, and `~.` typed.
    line_start: bool = true,
    tilde: bool = false,
    quit_typed: bool = false,
    clock: timer.TimeRequest = .{},
    clock_open: bool = false,

    in_bytes: [1024]u8 = undefined,
    /// What goes to the session, after the escapes: at most two bytes for
    /// each one typed.
    send_bytes: [2048]u8 = undefined,
    send_length: usize = 0,
    out_bytes: [4096]u8 = undefined,
    known: [known_hosts_max]u8 = undefined,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const crypto_lib = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, crypto.CRYPTONAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(crypto_lib);
    const cb: *CryptoBase = @ptrCast(crypto_lib);
    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    if (argv[arg_keygen] != 0) return keygen(dl, sb, cb);
    const given_host = dos.rdargs.string(argv[arg_host]) orelse {
        _ = Printf(dl, MSG_USAGE, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };

    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_CLEAR) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(memory);
    const st: *State = @ptrCast(@alignCast(memory));
    const reply_port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(reply_port);
    var requests: [4]*exec.IOStdReq = undefined;
    var made: usize = 0;
    defer for (requests[0..made]) |io| sys.DeleteIORequest(&io.req);
    while (made < requests.len) : (made += 1) {
        const request = sys.CreateIORequest(reply_port, @sizeOf(exec.IOStdReq)) orelse return dos.RETURN_FAIL;
        requests[made] = @fieldParentPtr("req", request);
    }
    st.* = .{
        .sys = sys,
        .dl = dl,
        .sb = sb,
        .cb = cb,
        .host = given_host,
        .reply_port = reply_port,
        .io = requests[0],
        .read_io = requests[1],
        .write_io = requests[2],
        .status_io = requests[3],
        .input = dl.Input().?,
        .output = dl.Output().?,
    };
    if (!names(st, given_host, dos.rdargs.string(argv[arg_user]))) return dos.RETURN_FAIL;
    if (dos.rdargs.number(argv[arg_port])) |value| st.port = @truncate(@as(u32, @bitCast(value)));
    const command = dos.rdargs.string(argv[arg_command]);
    const result = run(st, command);
    _ = dl.Flush(st.output);
    wipe(@as([*]u8, @ptrCast(&st.login))[0..@sizeOf(ssh.SshLogin)]);
    // A Ctrl-C typed into the raw console is the session's, not the
    // shell's.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    return result;
}

/// The host, the user and the name the host's key is kept under, from
/// `user@host` and USER.
fn names(st: *State, given_host: [*:0]const u8, given_user: ?[*:0]const u8) bool {
    const dl = st.dl;
    var host = given_host;
    var length: usize = 0;
    while (given_host[length] != 0) length += 1;
    var user_length: usize = 0;
    if (indexOf(given_host[0..length], '@')) |at| {
        user_length = @min(at, st.user.len - 1);
        @memcpy(st.user[0..user_length], given_host[0..user_length]);
        host = given_host + at + 1;
        length -= at + 1;
    }
    if (given_user) |user| {
        user_length = 0;
        while (user[user_length] != 0 and user_length < st.user.len - 1) : (user_length += 1) st.user[user_length] = user[user_length];
    }
    if (user_length == 0) {
        const got = dl.GetVar("USER", &st.user, st.user.len, 0);
        if (got > 0) user_length = @intCast(got);
    }
    if (user_length == 0) {
        _ = Printf(dl, MSG_NOUSER, .{COMMAND_NAME});
        return false;
    }
    st.user[user_length] = 0;
    st.host = host;
    if (length == 0) {
        _ = Printf(dl, MSG_USAGE, .{COMMAND_NAME});
        return false;
    }
    return true;
}

/// The name known_hosts keeps the key under: the host, lower case, and
/// in brackets with the port when it is not 22.
fn hostName(st: *State) void {
    var at: usize = 0;
    const bracket = st.port != port_default;
    if (bracket) {
        st.host_name[0] = '[';
        at = 1;
    }
    var index: usize = 0;
    while (st.host[index] != 0 and at < st.host_name.len - 10) : (index += 1) {
        const char = st.host[index];
        st.host_name[at] = if (char >= 'A' and char <= 'Z') char + 32 else char;
        at += 1;
    }
    if (bracket) {
        st.host_name[at] = ']';
        st.host_name[at + 1] = ':';
        at += 2;
        at += decimal(st.port, st.host_name[at..]);
    }
    st.host_name[at] = 0;
    st.host_name_length = at;
}

fn run(st: *State, command: ?[*:0]const u8) i32 {
    const sys = st.sys;
    const dl = st.dl;
    hostName(st);
    const id = connectSocket(st) orelse return dos.RETURN_FAIL;
    if (sys.OpenDevice(ssh.SSHNAME, @bitCast(id), &st.io.req, 0) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{ COMMAND_NAME, ssh.SSHNAME });
        const back = st.sb.ObtainSocket(id, bsd.PF_UNSPEC, bsd.SOCK_STREAM, 0);
        if (back >= 0) _ = st.sb.CloseSocket(back);
        return dos.RETURN_FAIL;
    }
    // Closing the device closes the connection.
    defer sys.CloseDevice(&st.io.req);
    for ([_]*exec.IOStdReq{ st.read_io, st.write_io, st.status_io }) |io| {
        io.req.device = st.io.req.device;
        io.req.unit = st.io.req.unit;
    }

    if (step(st, ssh.SSHCMD_CONNECT, &st.connect, @sizeOf(ssh.SshConnect)) != 0) return gone(st);
    if (!hostKnown(st)) return dos.RETURN_FAIL;
    if (!logIn(st)) return dos.RETURN_FAIL;

    // The session: a terminal for a shell on a console.
    const interactive = dl.IsInteractive(st.input);
    if (interactive) {
        st.console = dl.Open("*", dos.MODE_OLDFILE);
        if (st.console) |console| st.input = console else st.reading = false;
    }
    defer if (st.console) |console| {
        if (st.raw) _ = dl.SetMode(console, 0);
        _ = dl.Close(console);
    };
    if (command) |text| {
        var length: usize = 0;
        while (text[length] != 0 and length < st.session.command.len - 1) : (length += 1) st.session.command[length] = text[length];
    } else if (interactive and st.console != null) {
        st.raw = true;
        _ = dl.SetMode(st.input, 1);
        askSize(st);
        @memcpy(st.session.terminal[0..TERMINAL.len], TERMINAL);
        st.session.columns = st.columns;
        st.session.rows = st.rows;
    }
    switch (step(st, ssh.SSHCMD_SESSION, &st.session, @sizeOf(ssh.SshSession))) {
        0 => {},
        ssh.SSHERR_SESSION => {
            _ = Printf(dl, MSG_REFUSED, .{COMMAND_NAME});
            return dos.RETURN_FAIL;
        },
        else => return gone(st),
    }
    const terminal = st.raw;
    _ = dl.Flush(st.output);
    const status = pump(st);
    if (terminal) _ = Printf(dl, MSG_CLOSED, .{st.host});
    return status;
}

/// A TCP connection to the host, left with the stack for ssh.device: its
/// id, or null, said why.
fn connectSocket(st: *State) ?i32 {
    const sb = st.sb;
    const hints: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM };
    var list: ?*bsd.addrinfo = null;
    if (sb.GetAddrInfo(st.host, null, &hints, &list) != 0 or list == null) {
        _ = Printf(st.dl, MSG_NOHOST, .{ COMMAND_NAME, st.host });
        return null;
    }
    defer sb.FreeAddrInfo(list.?);
    const target = list.?;
    // The port into whichever sockaddr it is: both have it at offset 2.
    @as(*align(1) u16, @ptrCast(@as([*]u8, @ptrCast(target.ai_addr.?)) + 2)).* = bsd.htons(st.port);
    const socket = sb.Socket(target.ai_family, bsd.SOCK_STREAM, 0);
    if (socket < 0) return socketFailed(st, "Socket");
    if (sb.Connect(socket, target.ai_addr.?, target.ai_addrlen) < 0) {
        _ = socketFailed(st, "Connect");
        _ = sb.CloseSocket(socket);
        return null;
    }
    const id = sb.ReleaseSocket(socket, bsd.UNIQUE_ID);
    if (id < 0) {
        _ = socketFailed(st, "ReleaseSocket");
        _ = sb.CloseSocket(socket);
        return null;
    }
    return id;
}

fn socketFailed(st: *State, what: [*:0]const u8) ?i32 {
    _ = Printf(st.dl, MSG_FAILED, .{ COMMAND_NAME, what, bsd.errnoText(st.sb, st.sb.Errno()), st.sb.Errno() });
    return null;
}

/// One of the client's steps: sent, and waited for - or stopped with
/// Ctrl-C. Its io_Error.
fn step(st: *State, command: u16, data: *anyopaque, length: usize) i8 {
    const sys = st.sys;
    const io = st.io;
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
            io.req.err = exec.IOERR_ABORTED;
            return io.req.err;
        }
    }
    _ = sys.WaitIO(&io.req);
    return io.req.err;
}

/// The connection gone during a step: why, said.
fn gone(st: *State) i32 {
    if (st.io.req.err == exec.IOERR_ENDOFSTREAM) {
        _ = Printf(st.dl, MSG_GONE, .{ COMMAND_NAME, st.host, reasonText(st.io.actual) });
    }
    return dos.RETURN_FAIL;
}

fn reasonText(reason: u64) [*:0]const u8 {
    return switch (reason) {
        ssh.SSH_DISCONNECT_KEY_EXCHANGE_FAILED => "the key exchange failed",
        ssh.SSH_DISCONNECT_PROTOCOL_VERSION_NOT_SUPPORTED => "not an SSH server",
        ssh.SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE => "the host key changed",
        ssh.SSH_DISCONNECT_CONNECTION_LOST => "connection lost",
        ssh.SSH_DISCONNECT_NO_MORE_AUTH_METHODS_AVAILABLE => "too many login tries",
        ssh.SSH_DISCONNECT_MAC_ERROR => "a packet came altered",
        ssh.SSH_DISCONNECT_SERVICE_NOT_AVAILABLE => "the server has no login",
        ssh.SSH_DISCONNECT_BY_APPLICATION => "closed by the server",
        else => "protocol error",
    };
}

// --- the host key ---------------------------------------------------------------

const Known = enum { known, unknown, changed };

/// Whether the host's key may be trusted: kept before, or kept now that
/// the console said yes.
fn hostKnown(st: *State) bool {
    const dl = st.dl;
    const key = &st.connect.host_public;
    var print: [ssh_keys.fingerprint_bytes + 1]u8 = @splat(0);
    _ = ssh_keys.fingerprint(st.cb, key, print[0..ssh_keys.fingerprint_bytes]);
    const name: [*:0]const u8 = @ptrCast(&st.host_name);
    switch (lookUp(st, key)) {
        .known => return true,
        .changed => {
            _ = Printf(dl, MSG_CHANGED, .{ COMMAND_NAME, name, KNOWN_HOSTS_FILE, @as([*:0]const u8, @ptrCast(&print)) });
            return false;
        },
        .unknown => {},
    }
    if (!dl.IsInteractive(st.input)) {
        _ = Printf(dl, MSG_NOASK, .{ COMMAND_NAME, name });
        return false;
    }
    _ = Printf(dl, MSG_UNKNOWN, .{ name, @as([*:0]const u8, @ptrCast(&print)), KNOWN_HOSTS_FILE });
    _ = dl.Flush(st.output);
    var answer: [16]u8 = undefined;
    const got = dl.Read(st.input, &answer, answer.len);
    if (got < 3 or !same(answer[0..3], "yes")) return false;
    keep(st, key);
    return true;
}

/// The host's line in known_hosts: the same key, another key, or none.
fn lookUp(st: *State, key: *const [32]u8) Known {
    const dl = st.dl;
    const file = dl.Open(KNOWN_HOSTS_FILE, dos.MODE_OLDFILE) orelse return .unknown;
    defer _ = dl.Close(file);
    const got = dl.Read(file, &st.known, st.known.len);
    if (got <= 0) return .unknown;
    const name = st.host_name[0..st.host_name_length];
    var found: Known = .unknown;
    var lines = Lines{ .text = st.known[0..@intCast(got)] };
    while (lines.next()) |line| {
        var at: usize = 0;
        while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
        const names_start = at;
        while (at < line.len and line[at] != ' ' and line[at] != '\t') at += 1;
        if (!listHas(line[names_start..at], name)) continue;
        const kept = ssh_keys.authorizedKey(line[at..]) orelse continue;
        if (same(&kept, key)) return .known;
        found = .changed;
    }
    return found;
}

/// Whether the comma-separated `list` holds `name`, case aside.
fn listHas(list: []const u8, name: []const u8) bool {
    var start: usize = 0;
    while (start <= list.len) {
        var end = start;
        while (end < list.len and list[end] != ',') end += 1;
        const each = list[start..end];
        if (each.len == name.len) {
            const equal = for (each, name) |a, b| {
                const lower = if (a >= 'A' and a <= 'Z') a + 32 else a;
                if (lower != b) break false;
            } else true;
            if (equal) return true;
        }
        start = end + 1;
    }
    return false;
}

/// The host's key added to known_hosts.
fn keep(st: *State, key: *const [32]u8) void {
    const dl = st.dl;
    var line: [ssh_keys.fingerprint_bytes + 400]u8 = undefined;
    const name_length = st.host_name_length;
    @memcpy(line[0..name_length], st.host_name[0..name_length]);
    line[name_length] = ' ';
    const length = name_length + 1 + ssh_keys.publicLine(key, "", line[name_length + 1 ..]);
    const file = dl.Open(KNOWN_HOSTS_FILE, dos.MODE_READWRITE) orelse dl.Open(KNOWN_HOSTS_FILE, dos.MODE_NEWFILE) orelse return;
    defer _ = dl.Close(file);
    _ = dl.Seek(file, 0, dos.OFFSET_END);
    if (dl.Write(file, &line, @intCast(length)) == length) {
        _ = Printf(dl, MSG_KEPT, .{ COMMAND_NAME, @as([*:0]const u8, @ptrCast(&st.host_name)) });
    }
}

// --- the login --------------------------------------------------------------------

/// Logged in: with the key, if there is one - or with nothing, to hear
/// what the server takes - then with passwords asked for. False, said
/// why, when not.
fn logIn(st: *State) bool {
    const dl = st.dl;
    const login = &st.login;
    login.user = st.user;
    if (dl.Open(KEY_FILE, dos.MODE_OLDFILE)) |file| {
        var bytes: [ssh_keys.host_file_bytes]u8 = undefined;
        if (dl.Read(file, &bytes, bytes.len) == bytes.len) {
            login.key_seed = bytes[0..32].*;
            login.key_public = bytes[32..64].*;
            login.key_given = 1;
        }
        wipe(&bytes);
        _ = dl.Close(file);
    }
    var tries: u32 = 0;
    while (true) {
        const result = step(st, ssh.SSHCMD_LOGIN, login, @sizeOf(ssh.SshLogin));
        showBanner(st);
        switch (result) {
            0 => return true,
            ssh.SSHERR_LOGIN => {},
            exec.IOERR_ABORTED => return false,
            else => {
                _ = gone(st);
                return false;
            },
        }
        wipe(&login.password);
        login.password_length = 0;
        login.key_given = 0;
        const methods = sliceTo(&login.methods);
        if (!hasMethod(methods, "password") or tries == password_tries or !dl.IsInteractive(st.input)) {
            _ = Printf(dl, MSG_DENIED, .{ COMMAND_NAME, @as([*:0]const u8, @ptrCast(&login.methods)) });
            return false;
        }
        tries += 1;
        if (!askPassword(st)) return false;
    }
}

/// The banner the last SSHCMD_LOGIN brought, if any, shown as the
/// console can show it: UTF-8 taken to Latin-1, a character Latin-1 has
/// not as `?`, the control characters left out but for tabs and line
/// ends.
fn showBanner(st: *State) void {
    const dl = st.dl;
    const text = sliceTo(&st.login.banner);
    if (text.len == 0) return;
    _ = dl.Flush(st.output);
    var shown: [256]u8 = undefined;
    var length: usize = 0;
    var last: u8 = '\n';
    var at: usize = 0;
    while (at < text.len) {
        const decoded = decodeUtf8(text[at..]);
        at += decoded.length;
        const char = decoded.char;
        if (char != '\t' and char != '\n' and (char < 0x20 or (char >= 0x7F and char < 0xA0))) continue;
        last = if (char <= 0xFF) @intCast(char) else '?';
        shown[length] = last;
        length += 1;
        if (length == shown.len) {
            _ = dl.Write(st.output, &shown, @intCast(length));
            length = 0;
        }
    }
    if (last != '\n') {
        shown[length] = '\n';
        length += 1;
    }
    _ = dl.Write(st.output, &shown, @intCast(length));
    st.login.banner[0] = 0;
}

const Decoded = struct { char: u32, length: usize };

/// The character UTF-8 starts `bytes` with, and how many bytes it takes;
/// `?` for a byte that starts none.
fn decodeUtf8(bytes: []const u8) Decoded {
    const lead = bytes[0];
    const extra: usize = switch (lead) {
        0x00...0x7F => return .{ .char = lead, .length = 1 },
        0xC2...0xDF => 1,
        0xE0...0xEF => 2,
        0xF0...0xF4 => 3,
        else => return .{ .char = '?', .length = 1 },
    };
    if (bytes.len <= extra) return .{ .char = '?', .length = 1 };
    var char: u32 = lead & (@as(u8, 0x3F) >> @intCast(extra));
    for (bytes[1 .. 1 + extra]) |byte| {
        if (byte & 0xC0 != 0x80) return .{ .char = '?', .length = 1 };
        char = char << 6 | (byte & 0x3F);
    }
    return .{ .char = char, .length = 1 + extra };
}

fn hasMethod(methods: []const u8, method: []const u8) bool {
    var start: usize = 0;
    while (start < methods.len) {
        var end = start;
        while (end < methods.len and methods[end] != ',') end += 1;
        if (same(methods[start..end], method)) return true;
        start = end + 1;
    }
    return false;
}

/// The password, typed without its echo into the login: false when the
/// input ended or Ctrl-C came.
fn askPassword(st: *State) bool {
    const dl = st.dl;
    const input = st.input;
    if (!dl.IsInteractive(input)) return false;
    _ = Printf(dl, MSG_PASSWORD, .{ @as([*:0]const u8, @ptrCast(&st.user)), st.host });
    _ = dl.Flush(st.output);
    _ = dl.SetMode(input, 1);
    defer _ = dl.SetMode(input, 0);
    const login = &st.login;
    var length: usize = 0;
    while (true) {
        var char: [1]u8 = undefined;
        if (dl.Read(input, &char, 1) != 1 or char[0] == 3 or char[0] == 0x1C) {
            wipe(&login.password);
            _ = dl.Write(st.output, "\n", 1);
            return false;
        }
        if (char[0] == '\r' or char[0] == '\n') break;
        if (char[0] == 8 or char[0] == 127) {
            if (length > 0) length -= 1;
        } else if (length < login.password.len and char[0] >= ' ') {
            login.password[length] = char[0];
            length += 1;
        }
    }
    _ = dl.Write(st.output, "\n", 1);
    login.password_length = @intCast(length);
    return true;
}

// --- the session ------------------------------------------------------------------

/// The console asked its size, and given a moment to say it.
fn askSize(st: *State) void {
    const dl = st.dl;
    _ = dl.Write(st.input, SIZE_QUESTION, SIZE_QUESTION.len);
    while (dl.WaitForChar(st.input, size_answer_us)) {
        const got = dl.Read(st.input, &st.in_bytes, st.in_bytes.len);
        if (got <= 0) return;
        // What was typed meanwhile goes to the session first.
        filterInput(st, st.in_bytes[0..@intCast(got)]);
        if (st.answers) return;
    }
}

/// The session served until it is over: what it prints to the output,
/// what is typed to it, the console's size as it changes. Its exit
/// status.
fn pump(st: *State) i32 {
    const sys = st.sys;
    const dl = st.dl;
    const port = st.reply_port;
    // The status comes once the session is over.
    st.status_io.req.command = ssh.SSHCMD_STATUS;
    sys.SendIO(&st.status_io.req);
    var status_out = true;
    sendRead(st);
    var read_out = true;
    var output_ended = false;
    var packet_out = false;
    var input_ended = !st.reading;
    var write_out = false;
    if (st.send_length > 0) {
        sendWrite(st, false);
        write_out = true;
    } else if (st.reading) {
        sendPacket(st);
        packet_out = true;
    }
    if (st.raw and st.answers) {
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &st.clock.node, 0) == 0) {
            st.clock_open = true;
            st.clock.node.message.reply_port = port;
            startClock(st);
        }
    }
    var clock_out = st.clock_open;
    var quit = false;
    const breaks: u32 = if (st.raw) 0 else exec.SIGBREAKF_CTRL_C;

    while (!quit and (status_out or !output_ended)) {
        while (sys.GetMsg(port)) |message| {
            if (message == &st.read_io.req.message) {
                read_out = false;
                if (st.read_io.req.err != 0) {
                    output_ended = true;
                    continue;
                }
                _ = dl.Write(st.output, &st.out_bytes, @intCast(st.read_io.actual));
                sendRead(st);
                read_out = true;
            } else if (message == &st.status_io.req.message) {
                status_out = false;
            } else if (message == &st.write_io.req.message) {
                write_out = false;
                if (st.write_io.req.err != 0) input_ended = true;
                if (!input_ended) {
                    sendPacket(st);
                    packet_out = true;
                }
            } else if (message == &st.packet.msg) {
                packet_out = false;
                const got = st.packet.res1;
                if (got <= 0) {
                    // The input's end: the session's too.
                    input_ended = true;
                    sendWrite(st, true);
                    write_out = true;
                    continue;
                }
                filterInput(st, st.in_bytes[0..@intCast(got)]);
                if (st.quit_typed) {
                    quit = true;
                    break;
                }
                if (st.send_length > 0) {
                    sendWrite(st, false);
                    write_out = true;
                } else {
                    sendPacket(st);
                    packet_out = true;
                }
            } else if (message == &st.clock.node.message) {
                clock_out = false;
                _ = dl.Write(st.input, SIZE_QUESTION, SIZE_QUESTION.len);
                if (!output_ended) {
                    startClock(st);
                    clock_out = true;
                }
            }
        }
        if (quit or !(status_out or !output_ended)) break;
        const got = sys.Wait(port.sigMask() | breaks);
        if (got & breaks != 0) quit = true;
    }

    // Whatever is still out, back: the console's READ ended by closing
    // our handle, the rest aborted.
    if (clock_out) {
        _ = sys.AbortIO(&st.clock.node);
        _ = sys.WaitIO(&st.clock.node);
    }
    if (st.clock_open) sys.CloseDevice(&st.clock.node);
    for ([_]struct { *exec.IOStdReq, bool }{ .{ st.read_io, read_out }, .{ st.write_io, write_out }, .{ st.status_io, status_out } }) |pair| {
        if (!pair[1]) continue;
        _ = sys.AbortIO(&pair[0].req);
        _ = sys.WaitIO(&pair[0].req);
    }
    if (packet_out) {
        if (st.console) |console| {
            if (st.raw) _ = dl.SetMode(console, 0);
            _ = dl.Close(console);
            st.console = null;
            st.raw = false;
        }
        waitPacket(st);
    }
    if (quit or st.status_io.req.err != 0) return dos.RETURN_FAIL;
    return @intCast(@min(st.status_io.actual, 255));
}

fn sendRead(st: *State) void {
    const io = st.read_io;
    io.req.command = exec.CMD_READ;
    io.data = &st.out_bytes;
    io.length = st.out_bytes.len;
    st.sys.SendIO(&io.req);
}

/// What was typed, to the session; or with `end`, the end of its input.
fn sendWrite(st: *State, end: bool) void {
    const io = st.write_io;
    io.req.command = if (end) ssh.SSHCMD_EOF else exec.CMD_WRITE;
    io.data = &st.send_bytes;
    io.length = if (end) 0 else st.send_length;
    st.send_length = 0;
    st.sys.SendIO(&io.req);
}

/// A READ of the input sent to its handler, to come back on our port.
fn sendPacket(st: *State) void {
    st.packet = DosPacket.init(.read, .{ .io = .{ .fh = st.input, .buffer = &st.in_bytes, .length = st.in_bytes.len } });
    st.dl.SendPkt(&st.packet, st.input.task.?, st.reply_port);
}

/// The READ waited for, once it is ending.
fn waitPacket(st: *State) void {
    const sys = st.sys;
    while (true) {
        var found = false;
        while (sys.GetMsg(st.reply_port)) |message| {
            if (message == &st.packet.msg) found = true;
        }
        if (found) return;
        _ = sys.Wait(st.reply_port.sigMask());
    }
}

fn startClock(st: *State) void {
    st.clock.node.command = timer.TR_ADDREQUEST;
    st.clock.time = timer.TimeVal.fromMicros(size_every_us);
    st.sys.SendIO(&st.clock.node);
}

/// What came from the console, into what goes to the session: the
/// console's answers about its size taken out (and the size told), and
/// on a terminal Backspace as DEL and the `~` escapes.
fn filterInput(st: *State, bytes: []const u8) void {
    var at: usize = 0;
    while (at < bytes.len) {
        if (st.raw) {
            if (sizeAnswer(bytes[at..])) |answer| {
                at += answer.length;
                st.answers = true;
                if (answer.columns != st.columns or answer.rows != st.rows) {
                    st.columns = answer.columns;
                    st.rows = answer.rows;
                    tellSize(st);
                }
                continue;
            }
        }
        const byte = bytes[at];
        at += 1;
        if (!st.raw) {
            push(st, byte);
            continue;
        }
        if (st.tilde) {
            st.tilde = false;
            if (byte == '.') {
                st.quit_typed = true;
                return;
            }
            push(st, '~');
            if (byte == '~') continue;
        } else if (st.line_start and byte == '~') {
            st.tilde = true;
            continue;
        }
        push(st, if (byte == 8) 127 else byte);
        st.line_start = byte == '\r' or byte == '\n';
    }
}

fn push(st: *State, byte: u8) void {
    if (st.send_length == st.send_bytes.len) return;
    st.send_bytes[st.send_length] = byte;
    st.send_length += 1;
}

/// The terminal's new size, told the server - before the session it is
/// only kept, for SSHCMD_SESSION.
fn tellSize(st: *State) void {
    if (st.session.terminal[0] == 0 or st.session.columns == 0) return;
    const io = st.io;
    io.req.command = ssh.SSHCMD_WINDOW;
    io.length = st.columns;
    io.offset = st.rows;
    _ = st.sys.DoIO(&io.req);
}

const SizeAnswer = struct { length: usize, columns: u32, rows: u32 };

/// The console's answer to CSI 18 t at the start of `bytes`:
/// `CSI 8 ; rows ; columns t`, CSI as ESC [ or the one byte.
fn sizeAnswer(bytes: []const u8) ?SizeAnswer {
    var at: usize = 0;
    if (bytes.len >= 2 and bytes[0] == 0x1B and bytes[1] == '[') {
        at = 2;
    } else if (bytes.len >= 1 and bytes[0] == 0x9B) {
        at = 1;
    } else return null;
    if (at + 2 > bytes.len or bytes[at] != '8' or bytes[at + 1] != ';') return null;
    at += 2;
    var numbers: [2]u32 = .{ 0, 0 };
    for (&numbers, 0..) |*number, index| {
        const start = at;
        while (at < bytes.len and bytes[at] >= '0' and bytes[at] <= '9' and at - start < 5) : (at += 1) number.* = number.* * 10 + (bytes[at] - '0');
        if (at == start or at >= bytes.len) return null;
        const want: u8 = if (index == 0) ';' else 't';
        if (bytes[at] != want) return null;
        at += 1;
    }
    if (numbers[0] == 0 or numbers[1] == 0) return null;
    return .{ .length = at, .columns = numbers[1], .rows = numbers[0] };
}

// --- KEYGEN -------------------------------------------------------------------------

/// A new key for logins: its file, its public line beside it, both said.
fn keygen(dl: *DosBase, sb: *SocketBase, cb: *CryptoBase) i32 {
    if (dl.Open(KEY_FILE, dos.MODE_OLDFILE)) |file| {
        _ = dl.Close(file);
        _ = Printf(dl, MSG_KEY_EXISTS, .{ COMMAND_NAME, KEY_FILE });
        return dos.RETURN_WARN;
    }
    var bytes: [ssh_keys.host_file_bytes]u8 = undefined;
    defer wipe(&bytes);
    var length: u32 = 32;
    if (cb.MakeKeyPair(crypto.CURVE_ED25519, bytes[0..32], bytes[32..64], &length) != crypto.CRYPTOERR_OK) return dos.RETURN_FAIL;
    const file = dl.Open(KEY_FILE, dos.MODE_NEWFILE) orelse {
        _ = Printf(dl, MSG_KEY_FAILED, .{ COMMAND_NAME, KEY_FILE });
        return dos.RETURN_FAIL;
    };
    const written = dl.Write(file, &bytes, bytes.len);
    _ = dl.Close(file);
    if (written != bytes.len) {
        _ = Printf(dl, MSG_KEY_FAILED, .{ COMMAND_NAME, KEY_FILE });
        return dos.RETURN_FAIL;
    }
    // The comment says which machine the key is from.
    var host: [64]u8 = @splat(0);
    if (sb.GetHostName(&host, host.len - 1) != 0 or host[0] == 0) @memcpy(host[0..7], "poweros");
    var line: [256:0]u8 = @splat(0);
    const public: *const [32]u8 = bytes[32..64];
    const line_length = ssh_keys.publicLine(public, sliceTo(&host), &line);
    if (dl.Open(KEY_PUB_FILE, dos.MODE_NEWFILE)) |pub_file| {
        _ = dl.Write(pub_file, &line, @intCast(line_length));
        _ = dl.Close(pub_file);
    }
    _ = Printf(dl, MSG_KEY_MADE, .{ COMMAND_NAME, KEY_FILE, KEY_PUB_FILE, @as([*:0]const u8, &line) });
    var print: [ssh_keys.fingerprint_bytes + 1]u8 = @splat(0);
    if (ssh_keys.fingerprint(cb, public, print[0..ssh_keys.fingerprint_bytes])) {
        _ = Printf(dl, MSG_KEY_PRINT, .{@as([*:0]const u8, @ptrCast(&print))});
    }
    return dos.RETURN_OK;
}

// --- small things -------------------------------------------------------------------

const Lines = struct {
    text: []const u8,
    at: usize = 0,

    fn next(lines: *Lines) ?[]const u8 {
        if (lines.at >= lines.text.len) return null;
        const line_start = lines.at;
        while (lines.at < lines.text.len and lines.text[lines.at] != '\n') lines.at += 1;
        const line = lines.text[line_start..lines.at];
        lines.at += 1;
        return line;
    }
};

fn indexOf(text: []const u8, char: u8) ?usize {
    for (text, 0..) |each, index| if (each == char) return index;
    return null;
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn sliceTo(bytes: []const u8) []const u8 {
    return bytes[0 .. indexOf(bytes, 0) orelse bytes.len];
}

/// `value` in decimal into `into`: how many digits.
fn decimal(value: u32, into: []u8) usize {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var rest = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    for (0..count) |index| into[index] = digits[count - 1 - index];
    return count;
}

/// A secret cleared where the compiler cannot skip it.
fn wipe(bytes: []u8) void {
    const volatile_bytes: []volatile u8 = bytes;
    for (volatile_bytes) |*byte| byte.* = 0;
}
