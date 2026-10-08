// SPDX-License-Identifier: MIT
//! ShellServer: a shell for each connection to a TCP port - a console
//! that needs no cable. Built against the SDK only.
//!
//!   ShellServer PORT/K/N,QUIET/S,SSH/S
//!
//! It listens on PORT (23, Telnet's; 22 with SSH), over IPv6 and IPv4
//! alike, until Ctrl-C, and then waits for the shells it started to end.
//! A client that connects gets a shell with everything a console has:
//! line editing, history, Ctrl-C as the break. EndShell ends it, and so
//! does the client hanging up.
//!
//! **With SSH** it speaks SSH (ssh.device) instead of Telnet: the
//! connection is encrypted, and the client logs in with the password of
//! `ENVARC:Sys/net/shellserver` or with a key of
//! `ENVARC:Sys/net/authorized_keys` (OpenSSH's lines; ssh-ed25519 keys),
//! both read again for each connection, so a key added or a password
//! changed counts for the next one - with neither there at the start,
//! ShellServer does not start. The host key is
//! `ENVARC:Sys/net/ssh_host_key`, made at the first start, its public
//! half beside it in `ssh_host_key.pub` and its fingerprint printed, for
//! the client's first connection to be checked against. A client may
//! also ask for one command instead of a shell (`ssh host list`): it runs,
//! and its return code is the exit status. Or it asks for the `sftp`
//! subsystem - `sftp` and `scp` do - and the session serves the files of
//! every mounted volume (sftp.zig): `/` holds the devices and the
//! assigns, `/SYS/C/List` is `SYS:C/List`, and a session starts in `/SYS`.
//!
//! **A session.** Each connection's socket is left with the stack
//! (ReleaseSocket) and a process of its own is started for it, which:
//!
//! - adds a device `TELNET<n>:` - con-handler on telnet.device, whose
//!   unit is the socket's id - as C:Mount would;
//! - asks for the password, if `ENVARC:Sys/net/shellserver` holds one,
//!   without echoing it; three wrong tries hang up;
//! - runs a shell on it, which reads S:Shell-Startup first, with this
//!   server's command path;
//! - when the shell has ended, tells the console to end (ACTION_DIE) and
//!   takes the device away again.
//!
//! Telnet is plain text: a password keeps out a passer-by on the local
//! network, not someone who reads it. Over SSH the device asks for the
//! login before the session starts, so there is no password prompt.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const filehandler = dos.filehandler;
const Printf = dos.stdio.Printf;
const ssh = sdk.devices.ssh;
const ssh_keys = sdk.devices.ssh.keys;
const crypto = sdk.crypto;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const sftp = @import("sftp.zig");

pub const COMMAND_NAME = "ShellServer";
const VERSION_STRING = "\x00$VER: ShellServer 1.5 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "PORT/K/N,QUIET/S,SSH/S";
const arg_port = 0;
const arg_quiet = 1;
const arg_ssh = 2;

/// The password, its first line; no file, no password.
const PASSWORD_FILE = "ENVARC:Sys/net/shellserver";
const SHELL_STARTUP = "S:Shell-Startup";
const port_default: u16 = 23;
const tries = 3;
/// SSH's port, and its files.
const ssh_port_default: u16 = 22;
const HOST_KEY_FILE = "ENVARC:Sys/net/ssh_host_key";
const HOST_KEY_PUB_FILE = "ENVARC:Sys/net/ssh_host_key.pub";
const AUTHORIZED_KEYS_FILE = "ENVARC:Sys/net/authorized_keys";
/// Where an SFTP session starts.
const SFTP_HOME = "/SYS";

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_FAILED = "%s: %s failed: %s (errno %d)\n";
const MSG_LISTENING = "%s: listening on port %u; Ctrl-C stops\n";
const MSG_CONNECTED = "%s: %s from %s\n";
const MSG_WAITING = "%s: waiting for %u shells to end\n";
const MSG_PROMPT = "Password: ";
const MSG_WRONG = "\r\nWrong password\r\n";
const MSG_HOSTKEY = "%s: host key %s (%s)\n";
const MSG_NEWKEY = "%s: made the host key %s\n";
const MSG_NOKEY = "%s: no host key: %s cannot be read or written\n";
const MSG_NOLOGIN = "%s: SSH needs a password in %s or keys in %s\n";
const MSG_KEYS = "%s: logins: %s%u keys\n";

/// What the server and its sessions share. It lives on the server's
/// stack, and the server does not return while a session runs - their
/// code is its code.
const Server = struct {
    /// Where each session's end message comes back, once the session is
    /// gone and nothing runs its code any more (NP_EndMsg).
    ended: *exec.MsgPort,
    /// Sessions not gone yet: counted by the server alone, up as one is
    /// made and down as its end message comes back.
    sessions: u32 = 0,
    /// The next device's number.
    next: u32 = 0,
    quiet: bool,
    /// SSH rather than Telnet, and what every SSH session's device is
    /// given: the host key and the logins.
    ssh: bool = false,
    credentials: ssh.SshAccept = .{},
};

/// A session's own block, freed when it ends.
const Session = struct {
    /// The device's name, and with a colon, the name opened.
    name: [16:0]u8 = @splat(0),
    path: [17:0]u8 = @splat(0),
    startup: filehandler.FileSysStartupMsg = .{},
    /// The connection's id, and over SSH what the device is given and
    /// tells back.
    id: i32 = 0,
    ssh: bool = false,
    accept: ssh.SshAccept = .{},
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const secure = argv[arg_ssh] != 0;
    const port: u16 = if (dos.rdargs.number(argv[arg_port])) |value| @truncate(@as(u32, @bitCast(value))) else if (secure) ssh_port_default else port_default;
    const quiet = argv[arg_quiet] != 0;

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    const ended = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(ended);
    var server: Server = .{
        .ended = ended,
        .quiet = quiet,
        .ssh = secure,
    };
    if (secure and !sshCredentials(sys, dl, &server)) return dos.RETURN_FAIL;

    // One AF_INET6 socket takes both families: an IPv4 client comes as
    // its mapped address.
    const listener = sb.Socket(bsd.PF_INET6, bsd.SOCK_STREAM, 0);
    if (listener < 0) return failed(dl, sb, "Socket");
    const on: i32 = 1;
    _ = sb.SetSockOpt(listener, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, &on, @sizeOf(i32));
    var here: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(port) };
    if (sb.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in6)) < 0 or sb.Listen(listener, 4) < 0) {
        const result = failed(dl, sb, "Bind");
        _ = sb.CloseSocket(listener);
        return result;
    }
    if (!quiet) _ = Printf(dl, MSG_LISTENING, .{ COMMAND_NAME, @as(u32, port) });

    var result: i32 = dos.RETURN_OK;
    while (true) {
        var peer: bsd.sockaddr_in6 = .{};
        var peer_length: u32 = @sizeOf(bsd.sockaddr_in6);
        const connection = sb.Accept(listener, peer.any(), &peer_length);
        collect(sys, &server);
        if (connection < 0) {
            if (sb.Errno() != bsd.EINTR) result = failed(dl, sb, "Accept");
            break;
        }
        const id = sb.ReleaseSocket(connection, bsd.UNIQUE_ID);
        if (id < 0) {
            _ = sb.CloseSocket(connection);
            continue;
        }
        var from: [bsd.INET6_ADDRSTRLEN]u8 = @splat(0);
        peerText(sb, &peer, &from);
        if (!start(sys, dl, sb, &server, id, @ptrCast(&from))) {
            // Taken back and closed: no session for it.
            const back = sb.ObtainSocket(id, bsd.PF_INET6, bsd.SOCK_STREAM, 0);
            if (back >= 0) _ = sb.CloseSocket(back);
        }
    }
    _ = sb.CloseSocket(listener);

    // The sessions run this program's code: it stays until they are gone.
    while (server.sessions != 0) {
        if (!quiet) _ = Printf(dl, MSG_WAITING, .{ COMMAND_NAME, server.sessions });
        _ = sys.WaitPort(ended);
        collect(sys, &server);
    }
    return result;
}

/// The end messages of the sessions gone since the last look, freed and
/// counted off.
fn collect(sys: *ExecBase, server: *Server) void {
    while (sys.GetMsg(server.ended)) |message| {
        sys.FreeVec(message);
        server.sessions -= 1;
    }
}

fn failed(dl: *DosBase, sb: *SocketBase, what: [*:0]const u8) i32 {
    _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, what, bsd.errnoText(sb, sb.Errno()), sb.Errno() });
    return dos.RETURN_ERROR;
}

/// A session process for the connection left under `id`.
/// Who connected, as text: an IPv4 client dotted, an IPv6 one as IPv6
/// writes it.
fn peerText(sb: *SocketBase, peer: *const bsd.sockaddr_in6, into: *[bsd.INET6_ADDRSTRLEN]u8) void {
    const bytes = peer.sin6_addr.s6_addr;
    const mapped = for (bytes[0..10]) |byte| {
        if (byte != 0) break false;
    } else bytes[10] == 0xff and bytes[11] == 0xff;
    if (mapped) {
        _ = sb.Inet_NtoP(bsd.AF_INET, bytes[12..16], into, into.len);
    } else {
        _ = sb.Inet_NtoP(bsd.AF_INET6, &peer.sin6_addr, into, into.len);
    }
}

fn start(sys: *ExecBase, dl: *DosBase, sb: *SocketBase, server: *Server, id: i32, from: [*:0]const u8) bool {
    _ = sb;
    const memory = sys.AllocVec(@sizeOf(Session), exec.MEMF_CLEAR) orelse return false;
    const session: *Session = @ptrCast(@alignCast(memory));
    session.* = .{};
    const number = server.next;
    server.next += 1;
    writeName(&session.name, number, false, server.ssh);
    writeName(&session.path, number, true, server.ssh);
    const device_name = if (server.ssh) ssh.SSHNAME else sdk.devices.telnet.TELNETNAME;
    session.startup = .{ .unit = @bitCast(id), .device = device_name };
    session.id = id;
    session.ssh = server.ssh;
    session.accept = server.credentials;
    // The logins as the files are now: a key or a password changed counts
    // for the next connection, with no restart.
    if (server.ssh) readLogins(dl, &session.accept);
    // Comes back once the session is gone: the server's to free.
    const ended: *exec.Message = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(exec.Message), exec.MEMF_CLEAR) orelse {
        sys.FreeVec(memory);
        return false;
    }));
    ended.* = .{ .reply_port = server.ended };
    server.sessions += 1;
    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&sessionEntry) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(&session.name) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(session) },
        .{ .tag = dos.NP_StackSize, .data = 8192 },
        // The server's CLI, and with it its command path, for the shell.
        .{ .tag = dos.NP_Cli, .data = 1 },
        .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(ended) },
        .{},
    };
    if (dl.CreateNewProc(&tags) == null) {
        server.sessions -= 1;
        sys.FreeVec(ended);
        sys.FreeVec(memory);
        return false;
    }
    if (!server.quiet) _ = Printf(dl, MSG_CONNECTED, .{ COMMAND_NAME, @as([*:0]const u8, &session.path), from });
    return true;
}

/// "TELNET<n>" or "SSH<n>", with a colon for the name that is opened.
fn writeName(into: []u8, number: u32, colon: bool, secure: bool) void {
    const prefix = if (secure) "SSH" else "TELNET";
    @memcpy(into[0..prefix.len], prefix);
    var at: usize = prefix.len;
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var rest = number;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    while (count > 0) {
        count -= 1;
        into[at] = digits[count];
        at += 1;
    }
    if (colon) {
        into[at] = ':';
        at += 1;
    }
    into[at] = 0;
}

/// A session's process: the device added, the password or SSH's login,
/// the shell or the command, and the device taken away again.
fn sessionEntry(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const session: *Session = @ptrCast(@alignCast(me.user_data.?));
    // The server hears of the end from exec, once this process is gone
    // (NP_EndMsg): the code it runs is the server's.
    defer sys.FreeVec(session);
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    // Over SSH the session's own opening of the device comes first: the
    // client logs in, and says what it wants, before there is a console.
    // Closed last, after the console's: the connection goes with it.
    var login: ?Login = null;
    if (session.ssh) login = Login.open(sys, session) orelse return;
    defer if (login) |*held| held.close(sys);
    if (session.ssh and session.accept.kind == ssh.SSHSESSION_SUBSYSTEM) {
        // No console: the subsystem speaks on the session's own unit.
        const held = &login.?;
        return held.exit(sys, subsystem(sys, dl, session, held));
    }

    const node = dl.MakeDosEntry(&session.name, dos.DLT_DEVICE) orelse return;
    node.misc.handler.handler = "con-handler";
    node.misc.handler.stack_size = 16384;
    node.misc.handler.priority = 5;
    node.misc.handler.startup = @intFromPtr(&session.startup);
    if (!dl.AddDosEntry(node)) return dl.FreeDosEntry(node);
    defer {
        // The console told to end once its last handle is closed, then its
        // node taken off the list.
        if (node.task) |console| _ = dl.DoPkt(console, @intFromEnum(dos.ActionCode.die), 0, 0, 0, 0, 0);
        const flags = dos.LDF_DEVICES | dos.LDF_WRITE;
        _ = dl.LockDosList(flags);
        _ = dl.RemDosEntry(node);
        dl.UnLockDosList(flags);
        dl.FreeDosEntry(node);
    }

    // The console's first handle stays open until the shell has ended:
    // when the last one closes, the console closes the device - and,
    // over Telnet, the connection.
    const input = dl.Open(&session.path, dos.MODE_READWRITE) orelse return;
    if (!session.ssh and !password(dl, input)) {
        _ = dl.Close(input);
        return;
    }
    const output = dl.Open(&session.path, dos.MODE_NEWFILE) orelse {
        _ = dl.Close(input);
        return;
    };
    var status: i32 = 0;
    if (session.ssh and session.accept.kind == ssh.SSHSESSION_EXEC) {
        // Raw: the command's input and output go as they are - no echo, no
        // line editing, no banner.
        _ = dl.SetMode(input, 1);
        const tags = [_]TagItem{
            .{ .tag = dos.SYS_Input, .data = @intFromPtr(input) },
            .{ .tag = dos.SYS_Output, .data = @intFromPtr(output) },
            .{},
        };
        status = dl.SystemTagList(@ptrCast(&session.accept.command), &tags);
    } else {
        const script = dl.Open(SHELL_STARTUP, dos.MODE_OLDFILE);
        const tags = [_]TagItem{
            .{ .tag = dos.SYS_Input, .data = @intFromPtr(input) },
            .{ .tag = dos.SYS_Output, .data = @intFromPtr(output) },
            .{ .tag = dos.SYS_UserShell, .data = 1 },
            .{ .tag = dos.SYS_ScriptFile, .data = @intFromPtr(script) },
            .{},
        };
        _ = dl.SystemTagList(null, &tags);
    }
    // What the console still holds goes out before the channel closes.
    _ = dl.Close(output);
    _ = dl.Close(input);
    if (login) |*held| held.exit(sys, if (status < 0) 127 else @intCast(status));
}

/// A subsystem the client asked for: `sftp` served until the client
/// ends, any other refused. The exit status.
fn subsystem(sys: *ExecBase, dl: *DosBase, session: *Session, login: *Login) u32 {
    const name: [*:0]const u8 = @ptrCast(&session.accept.command);
    if (!sameName(name, "sftp")) return 1;
    const memory = sys.AllocVec(@sizeOf(sftp.Server), exec.MEMF_ANY) orelse return 1;
    defer sys.FreeVec(memory);
    const server: *sftp.Server = @ptrCast(@alignCast(memory));
    const user: [*:0]const u8 = @ptrCast(&session.accept.user);
    server.init(sys, dl, user[0..lengthOf(user)], SFTP_HOME);
    defer server.deinit();
    server.serve(login.io);
    return 0;
}

fn sameName(name: [*:0]const u8, wanted: []const u8) bool {
    for (wanted, 0..) |char, index| {
        if (name[index] != char) return false;
    }
    return name[wanted.len] == 0;
}

fn lengthOf(name: [*:0]const u8) usize {
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    return length;
}

/// The session's own opening of ssh.device: the login waited for, and at
/// the end the exit status told.
const Login = struct {
    port: *exec.MsgPort,
    io: *exec.IOStdReq,

    /// The unit opened and SSHCMD_ACCEPT answered: the client has logged
    /// in and asked for its session. Null when it went first.
    fn open(sys: *ExecBase, session: *Session) ?Login {
        const port = sys.CreateMsgPort() orelse return null;
        const request = sys.CreateIORequest(port, @sizeOf(exec.IOStdReq)) orelse {
            sys.DeleteMsgPort(port);
            return null;
        };
        const io: *exec.IOStdReq = @fieldParentPtr("req", request);
        var login: Login = .{ .port = port, .io = io };
        if (sys.OpenDevice(ssh.SSHNAME, @bitCast(session.id), request, 0) != 0) {
            sys.DeleteIORequest(request);
            sys.DeleteMsgPort(port);
            return null;
        }
        io.req.command = ssh.SSHCMD_ACCEPT;
        io.data = &session.accept;
        io.length = @sizeOf(ssh.SshAccept);
        if (sys.DoIO(request) != 0) {
            login.close(sys);
            return null;
        }
        return login;
    }

    fn exit(login: *Login, sys: *ExecBase, status: u32) void {
        login.io.req.command = ssh.SSHCMD_EXIT;
        login.io.length = status;
        _ = sys.DoIO(&login.io.req);
    }

    fn close(login: *Login, sys: *ExecBase) void {
        sys.CloseDevice(&login.io.req);
        sys.DeleteIORequest(&login.io.req);
        sys.DeleteMsgPort(login.port);
    }
};

// --- SSH's keys -----------------------------------------------------------------

/// The host key and the logins, read - the host key made the first time -
/// into what every session's device is given. False, said why, when SSH
/// cannot run.
fn sshCredentials(sys: *ExecBase, dl: *DosBase, server: *Server) bool {
    const lib = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, crypto.CRYPTONAME });
        return false;
    };
    defer sys.CloseLibrary(lib);
    const cb: *CryptoBase = @ptrCast(lib);
    const credentials = &server.credentials;
    if (!hostKey(dl, cb, credentials)) return false;
    readLogins(dl, credentials);
    if (credentials.password_length == 0 and credentials.key_count == 0) {
        _ = Printf(dl, MSG_NOLOGIN, .{ COMMAND_NAME, PASSWORD_FILE, AUTHORIZED_KEYS_FILE });
        return false;
    }
    if (!server.quiet) {
        const with_password: [*:0]const u8 = if (credentials.password_length > 0) "a password, " else "";
        _ = Printf(dl, MSG_KEYS, .{ COMMAND_NAME, with_password, credentials.key_count });
    }
    return true;
}

/// The host key from its file, or made and written there with its public
/// half beside it; its fingerprint said.
fn hostKey(dl: *DosBase, cb: *CryptoBase, credentials: *ssh.SshAccept) bool {
    var bytes: [ssh_keys.host_file_bytes]u8 = undefined;
    var have = false;
    if (dl.Open(HOST_KEY_FILE, dos.MODE_OLDFILE)) |file| {
        have = dl.Read(file, &bytes, bytes.len) == bytes.len;
        _ = dl.Close(file);
    }
    if (have) {
        credentials.host_seed = bytes[0..32].*;
        credentials.host_public = bytes[32..64].*;
    } else {
        var length: u32 = 32;
        if (cb.MakeKeyPair(crypto.CURVE_ED25519, &credentials.host_seed, &credentials.host_public, &length) != crypto.CRYPTOERR_OK) return false;
        bytes[0..32].* = credentials.host_seed;
        bytes[32..64].* = credentials.host_public;
        const file = dl.Open(HOST_KEY_FILE, dos.MODE_NEWFILE) orelse {
            _ = Printf(dl, MSG_NOKEY, .{ COMMAND_NAME, HOST_KEY_FILE });
            return false;
        };
        const written = dl.Write(file, &bytes, bytes.len);
        _ = dl.Close(file);
        if (written != bytes.len) {
            _ = Printf(dl, MSG_NOKEY, .{ COMMAND_NAME, HOST_KEY_FILE });
            return false;
        }
        var line: [128]u8 = undefined;
        const line_length = ssh_keys.publicLine(&credentials.host_public, "poweros", &line);
        if (dl.Open(HOST_KEY_PUB_FILE, dos.MODE_NEWFILE)) |pub_file| {
            _ = dl.Write(pub_file, &line, @intCast(line_length));
            _ = dl.Close(pub_file);
        }
        _ = Printf(dl, MSG_NEWKEY, .{ COMMAND_NAME, HOST_KEY_FILE });
    }
    @memset(&bytes, 0);
    var print: [ssh_keys.fingerprint_bytes + 1]u8 = @splat(0);
    if (ssh_keys.fingerprint(cb, &credentials.host_public, print[0..ssh_keys.fingerprint_bytes])) {
        _ = Printf(dl, MSG_HOSTKEY, .{ COMMAND_NAME, @as([*:0]const u8, @ptrCast(&print)), HOST_KEY_PUB_FILE });
    }
    return true;
}

/// The password and the keys, read afresh into `credentials`.
fn readLogins(dl: *DosBase, credentials: *ssh.SshAccept) void {
    @memset(&credentials.password, 0);
    credentials.password_length = 0;
    credentials.key_count = 0;
    if (firstLine(dl, &credentials.password)) |length| credentials.password_length = @intCast(length);
    readAuthorizedKeys(dl, credentials);
}

/// The ssh-ed25519 keys of the authorized keys file, as many as are
/// taken.
fn readAuthorizedKeys(dl: *DosBase, credentials: *ssh.SshAccept) void {
    const file = dl.Open(AUTHORIZED_KEYS_FILE, dos.MODE_OLDFILE) orelse return;
    defer _ = dl.Close(file);
    var text: [8192]u8 = undefined;
    const got = dl.Read(file, &text, text.len);
    if (got <= 0) return;
    var lines = linesOf(text[0..@intCast(got)]);
    while (lines.next()) |line| {
        if (credentials.key_count == ssh.SSH_KEYS_MAX) return;
        const key = ssh_keys.authorizedKey(line) orelse continue;
        credentials.keys[credentials.key_count] = key;
        credentials.key_count += 1;
    }
}

/// The lines of `text`, without their line ends.
fn linesOf(text: []const u8) Lines {
    return .{ .text = text };
}

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

/// The password asked for, if there is one, without its echo: whether
/// the session may go on.
fn password(dl: *DosBase, console: *dos.FileHandle) bool {
    var wanted: [64]u8 = undefined;
    const wanted_length = firstLine(dl, &wanted) orelse return true;
    var tried: u32 = 0;
    while (tried < tries) : (tried += 1) {
        _ = dl.Write(console, MSG_PROMPT, MSG_PROMPT.len);
        _ = dl.SetMode(console, 1);
        var typed: [64]u8 = undefined;
        var length: usize = 0;
        var ended = false;
        while (true) {
            var char: [1]u8 = undefined;
            if (dl.Read(console, &char, 1) != 1) {
                ended = true;
                break;
            }
            if (char[0] == '\r' or char[0] == '\n') break;
            if ((char[0] == 8 or char[0] == 127) and length > 0) {
                length -= 1;
            } else if (length < typed.len and char[0] >= ' ') {
                typed[length] = char[0];
                length += 1;
            }
        }
        _ = dl.SetMode(console, 0);
        if (ended) return false;
        const right = length == wanted_length and for (typed[0..length], wanted[0..length]) |got, want| {
            if (got != want) break false;
        } else true;
        if (right) {
            _ = dl.Write(console, "\r\n", 2);
            return true;
        }
        _ = dl.Write(console, MSG_WRONG, MSG_WRONG.len);
    }
    return false;
}

/// The password file's first line, trimmed: its length, or null when
/// there is none.
fn firstLine(dl: *DosBase, into: []u8) ?usize {
    const file = dl.Open(PASSWORD_FILE, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(file);
    const got = dl.Read(file, into.ptr, @intCast(into.len));
    if (got <= 0) return null;
    var end: usize = 0;
    while (end < @as(usize, @intCast(got)) and into[end] != '\n' and into[end] != '\r') end += 1;
    while (end > 0 and (into[end - 1] == ' ' or into[end - 1] == '\t')) end -= 1;
    if (end == 0) return null;
    return end;
}
