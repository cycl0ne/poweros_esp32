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
//! **The host key and the login** are sdk/devices/ssh/connect.zig's: a
//! host not in `ENVARC:Sys/net/known_hosts` is asked about, one whose key
//! changed is refused; the login is with the key
//! `ENVARC:Sys/net/id_ed25519`, then with a password asked for. `SSH
//! KEYGEN` makes the key - an Ed25519 key, its seed and public half, 64
//! bytes - and writes its public line beside it in `id_ed25519.pub`, for
//! the other machine's `authorized_keys`.
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
const connect = sdk.devices.ssh.connect;
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

const KEY_FILE = connect.KEY_FILE;
const KEY_PUB_FILE = connect.KEY_PUB_FILE;
const TERMINAL = "xterm-256color";
/// How long the console has to say its size, and how often it is asked
/// again.
const size_answer_us = 300_000;
const size_every_us = 2_000_000;
/// The size of a console that never says.
const columns_default = 80;
const rows_default = 24;
/// The question that asks a console its size.
const SIZE_QUESTION = "\x1b[18t";

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_USAGE = "%s: HOST is needed\n";
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
    /// The connection and the login, and the steps' request.
    client: connect.Client,

    // --- the device --------------------------------------------------------

    reply_port: *exec.MsgPort,
    /// The reads', the writes' and the status' requests.
    read_io: *exec.IOStdReq,
    write_io: *exec.IOStdReq,
    status_io: *exec.IOStdReq,
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
        .client = .{
            .sys = sys,
            .dl = dl,
            .sb = sb,
            .cb = cb,
            .program = COMMAND_NAME,
            .input = dl.Input().?,
            .output = dl.Output().?,
            .reply_port = reply_port,
            .io = requests[0],
        },
        .reply_port = reply_port,
        .read_io = requests[1],
        .write_io = requests[2],
        .status_io = requests[3],
        .input = dl.Input().?,
        .output = dl.Output().?,
    };
    const client = &st.client;
    const given_user = dos.rdargs.string(argv[arg_user]);
    if (!client.names(span(given_host), if (given_user) |user| span(user) else null)) return dos.RETURN_FAIL;
    if (dos.rdargs.number(argv[arg_port])) |value| client.port = @truncate(@as(u32, @bitCast(value)));
    const command = dos.rdargs.string(argv[arg_command]);
    const result = run(st, command);
    _ = dl.Flush(st.output);
    client.stop();
    // A Ctrl-C typed into the raw console is the session's, not the
    // shell's.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    return result;
}

fn run(st: *State, command: ?[*:0]const u8) i32 {
    const dl = st.dl;
    const client = &st.client;
    // Stopping the client closes the connection.
    if (!client.start()) return dos.RETURN_FAIL;
    for ([_]*exec.IOStdReq{ st.read_io, st.write_io, st.status_io }) |io| client.share(io);

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
    switch (client.step(ssh.SSHCMD_SESSION, &st.session, @sizeOf(ssh.SshSession))) {
        0 => {},
        ssh.SSHERR_SESSION => {
            _ = Printf(dl, MSG_REFUSED, .{COMMAND_NAME});
            return dos.RETURN_FAIL;
        },
        else => {
            client.gone();
            return dos.RETURN_FAIL;
        },
    }
    const terminal = st.raw;
    _ = dl.Flush(st.output);
    const status = pump(st);
    if (terminal) _ = Printf(dl, MSG_CLOSED, .{@as([*:0]const u8, &client.host)});
    return status;
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
    const io = st.client.io;
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

const sliceTo = connect.sliceTo;
const wipe = connect.wipe;

fn span(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}
