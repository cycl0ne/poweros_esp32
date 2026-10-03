// SPDX-License-Identifier: MIT
//! ShellServer: a shell for each connection to a TCP port - a console
//! that needs no cable. Built against the SDK only.
//!
//!   ShellServer PORT/K/N,QUIET/S
//!
//! It listens on PORT (23, Telnet's), over IPv6 and IPv4 alike, until
//! Ctrl-C, and then waits for the
//! shells it started to end. A Telnet client that connects gets a shell
//! with everything a console has: line editing, history, Ctrl-C as the
//! break. EndShell ends it, and so does the client hanging up.
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
//! network, not someone who reads it.

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

pub const COMMAND_NAME = "ShellServer";
const VERSION_STRING = "\x00$VER: ShellServer 1.2 (03.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "PORT/K/N,QUIET/S";
const arg_port = 0;
const arg_quiet = 1;

/// The password, its first line; no file, no password.
const PASSWORD_FILE = "ENVARC:Sys/net/shellserver";
const SHELL_STARTUP = "S:Shell-Startup";
const port_default: u16 = 23;
const tries = 3;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_FAILED = "%s: %s failed: %s (errno %d)\n";
const MSG_LISTENING = "%s: listening on port %u; Ctrl-C stops\n";
const MSG_CONNECTED = "%s: %s from %s\n";
const MSG_WAITING = "%s: waiting for %u shells to end\n";
const MSG_PROMPT = "Password: ";
const MSG_WRONG = "\r\nWrong password\r\n";

/// What the server and its sessions share. It lives on the server's
/// stack, and the server does not return while a session runs - their
/// code is its code.
const Server = struct {
    task: *exec.Task,
    done_mask: u32,
    /// Sessions running; changed under Forbid.
    sessions: u32 = 0,
    /// The next device's number.
    next: u32 = 0,
    quiet: bool,
};

/// A session's own block, freed when it ends.
const Session = struct {
    server: *Server,
    /// The device's name, and with a colon, the name opened.
    name: [16:0]u8 = @splat(0),
    path: [17:0]u8 = @splat(0),
    startup: filehandler.FileSysStartupMsg = .{},
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const port: u16 = if (dos.rdargs.number(argv[arg_port])) |value| @truncate(@as(u32, @bitCast(value))) else port_default;
    const quiet = argv[arg_quiet] != 0;

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    const done_signal = sys.AllocSignal(-1);
    if (done_signal < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(done_signal);
    var server: Server = .{
        .task = sys.FindTask(null).?,
        .done_mask = @as(u32, 1) << @intCast(done_signal),
        .quiet = quiet,
    };

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

    // The sessions run this program's code: it stays until they are done.
    while (true) {
        sys.Forbid();
        const running = server.sessions;
        sys.Permit();
        if (running == 0) break;
        if (!quiet) _ = Printf(dl, MSG_WAITING, .{ COMMAND_NAME, running });
        _ = sys.Wait(server.done_mask);
    }
    return result;
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
    session.* = .{ .server = server };
    const number = server.next;
    server.next += 1;
    writeName(&session.name, number, false);
    writeName(&session.path, number, true);
    session.startup = .{ .unit = @bitCast(id), .device = sdk.devices.telnet.TELNETNAME };
    sys.Forbid();
    server.sessions += 1;
    sys.Permit();
    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&sessionEntry) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(&session.name) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(session) },
        .{ .tag = dos.NP_StackSize, .data = 8192 },
        // The server's CLI, and with it its command path, for the shell.
        .{ .tag = dos.NP_Cli, .data = 1 },
        .{},
    };
    if (dl.CreateNewProc(&tags) == null) {
        sys.Forbid();
        server.sessions -= 1;
        sys.Permit();
        sys.FreeVec(memory);
        return false;
    }
    if (!server.quiet) _ = Printf(dl, MSG_CONNECTED, .{ COMMAND_NAME, @as([*:0]const u8, &session.path), from });
    return true;
}

/// "TELNET<n>", with a colon for the name that is opened.
fn writeName(into: []u8, number: u32, colon: bool) void {
    const prefix = "TELNET";
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

/// A session's process: the device added, the password, the shell, and
/// the device taken away again.
fn sessionEntry(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const session: *Session = @ptrCast(@alignCast(me.user_data.?));
    const server = session.server;
    defer {
        sys.FreeVec(session);
        // The server is told last, under a Forbid that lasts until this
        // process is gone: the code it runs is the server's.
        sys.Forbid();
        server.sessions -= 1;
        sys.Signal(server.task, server.done_mask);
    }
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

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
        _ = dl.RemDosEntry(node);
        dl.FreeDosEntry(node);
    }

    // The console's first handle stays open until the shell has ended:
    // when the last one closes, the console closes the device, and with
    // it the connection.
    const input = dl.Open(&session.path, dos.MODE_READWRITE) orelse return;
    defer _ = dl.Close(input);
    if (!password(dl, input)) return;
    const output = dl.Open(&session.path, dos.MODE_NEWFILE) orelse return;
    defer _ = dl.Close(output);
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
