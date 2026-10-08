// SPDX-License-Identifier: MIT
//! The client's way into ssh.device, for a program that runs a session
//! on another machine - C:net/SSH, C:net/SCP: the TCP connection, the
//! device opened on it, the host key checked, the login.
//!
//! **The host key.** `ENVARC:Sys/net/known_hosts` holds the host keys
//! seen before, a line each as OpenSSH writes them: the host's name
//! (`[name]:port` for a port other than 22), `ssh-ed25519` and the key. A
//! host not in it has its key's fingerprint shown, and is asked about on
//! the console: `yes` connects and keeps the key. A host whose key is not
//! the one kept is refused - someone may be in between - until its line
//! is taken out of the file.
//!
//! **The login**: with the key `ENVARC:Sys/net/id_ed25519` first, when
//! there is one, and then with a password, asked for on the console
//! without its echo, three tries - asked for only when the server takes
//! passwords. A banner the server sends is shown before the password is
//! asked for: as Latin-1, the characters the console has not as `?`, and
//! without its control characters, so it cannot work the console.
//!
//! Everything that goes wrong is said on the output, after the program's
//! name; Ctrl-C stops a step that waits.

const exec = @import("../../libs/exec/exec.zig");
const dos = @import("../../libs/dos/dos.zig");
const bsd = @import("../../libs/bsdsocket/bsdsocket.zig");
const ssh = @import("../ssh.zig");
const ssh_keys = @import("keys.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const DosBase = @import("../../interface/dos.zig").DosBase;
const SocketBase = @import("../../interface/bsdsocket.zig").SocketBase;
const CryptoBase = @import("../../interface/crypto.zig").CryptoBase;
const FileHandle = dos.FileHandle;
const Printf = dos.stdio.Printf;

/// The login key, its public line, and the host keys seen before.
pub const KEY_FILE = "ENVARC:Sys/net/id_ed25519";
pub const KEY_PUB_FILE = "ENVARC:Sys/net/id_ed25519.pub";
pub const KNOWN_HOSTS_FILE = "ENVARC:Sys/net/known_hosts";
pub const port_default: u16 = 22;
const password_tries = 3;
const known_hosts_max = 16384;

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

/// A connection's client end, from the host's name to the login. Big -
/// it holds known_hosts while it reads it - so it goes in memory of its
/// own, not on a stack.
pub const Client = struct {
    sys: *ExecBase,
    dl: *DosBase,
    sb: *SocketBase,
    cb: *CryptoBase,
    /// The program's name, in front of every message.
    program: [*:0]const u8,
    /// Where the console's answers come from - the host key's question,
    /// the password - and where the banner goes.
    input: *FileHandle,
    output: *FileHandle,
    /// The steps' request; once `start` has opened the device, a further
    /// request is opened on its unit with `share`.
    reply_port: *exec.MsgPort,
    io: *exec.IOStdReq,
    open: bool = false,

    host: [256:0]u8 = @splat(0),
    user: [64]u8 = @splat(0),
    port: u16 = port_default,
    /// The name known_hosts knows the host by.
    host_name: [264]u8 = @splat(0),
    host_name_length: usize = 0,
    connect: ssh.SshConnect = .{},
    login: ssh.SshLogin = .{},
    known: [known_hosts_max]u8 = undefined,

    /// The host and the user: `host`, or `user@host`; `user` when it is
    /// given, else the one before the `@`, else the variable USER. False,
    /// said why, when there is no host or no user.
    pub fn names(client: *Client, given_host: []const u8, given_user: ?[]const u8) bool {
        const dl = client.dl;
        var host = given_host;
        var user_length: usize = 0;
        if (indexOf(given_host, '@')) |at| {
            user_length = @min(at, client.user.len - 1);
            @memcpy(client.user[0..user_length], given_host[0..user_length]);
            host = given_host[at + 1 ..];
        }
        if (given_user) |user| {
            user_length = @min(user.len, client.user.len - 1);
            @memcpy(client.user[0..user_length], user[0..user_length]);
        }
        if (user_length == 0) {
            const got = dl.GetVar("USER", &client.user, client.user.len, 0);
            if (got > 0) user_length = @intCast(got);
        }
        if (user_length == 0) {
            _ = Printf(dl, MSG_NOUSER, .{client.program});
            return false;
        }
        client.user[user_length] = 0;
        // An IPv6 address may come in brackets, as before a port.
        if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
        if (host.len == 0) {
            _ = Printf(dl, MSG_USAGE, .{client.program});
            return false;
        }
        const length = @min(host.len, client.host.len);
        @memcpy(client.host[0..length], host[0..length]);
        client.host[length] = 0;
        return true;
    }

    /// Connected and logged in, the device open on `io`: false, said why,
    /// when not - the connection closed again.
    pub fn start(client: *Client) bool {
        const sys = client.sys;
        client.hostName();
        const id = client.connectSocket() orelse return false;
        if (sys.OpenDevice(ssh.SSHNAME, @bitCast(id), &client.io.req, 0) != 0) {
            _ = Printf(client.dl, MSG_NODEVICE, .{ client.program, ssh.SSHNAME });
            const back = client.sb.ObtainSocket(id, bsd.PF_UNSPEC, bsd.SOCK_STREAM, 0);
            if (back >= 0) _ = client.sb.CloseSocket(back);
            return false;
        }
        client.open = true;
        if (client.step(ssh.SSHCMD_CONNECT, &client.connect, @sizeOf(ssh.SshConnect)) != 0) {
            client.gone();
            client.stop();
            return false;
        }
        if (!client.hostKnown() or !client.logIn()) {
            client.stop();
            return false;
        }
        return true;
    }

    /// The device closed, and with it the connection; the login's
    /// secrets wiped.
    pub fn stop(client: *Client) void {
        if (client.open) client.sys.CloseDevice(&client.io.req);
        client.open = false;
        wipe(@as([*]u8, @ptrCast(&client.login))[0..@sizeOf(ssh.SshLogin)]);
    }

    /// Another request on the connection's unit, for reads and writes
    /// that run beside the steps.
    pub fn share(client: *Client, io: *exec.IOStdReq) void {
        io.req.device = client.io.req.device;
        io.req.unit = client.io.req.unit;
    }

    /// One of the client's steps: sent, and waited for - or stopped with
    /// Ctrl-C, IOERR_ABORTED. Its io_Error.
    pub fn step(client: *Client, command: u16, data: ?*anyopaque, length: usize) i8 {
        const sys = client.sys;
        const io = client.io;
        io.req.command = command;
        io.data = data;
        io.length = length;
        sys.SendIO(&io.req);
        while (sys.CheckIO(&io.req) == null) {
            const got = sys.Wait(client.reply_port.sigMask() | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0 and sys.CheckIO(&io.req) == null) {
                _ = sys.AbortIO(&io.req);
                _ = sys.WaitIO(&io.req);
                _ = Printf(client.dl, MSG_BREAK, .{client.program});
                io.req.err = exec.IOERR_ABORTED;
                return io.req.err;
            }
        }
        _ = sys.WaitIO(&io.req);
        return io.req.err;
    }

    /// The connection gone during a step: why, said.
    pub fn gone(client: *Client) void {
        if (client.io.req.err == exec.IOERR_ENDOFSTREAM) {
            _ = Printf(client.dl, MSG_GONE, .{ client.program, @as([*:0]const u8, &client.host), reasonText(client.io.actual) });
        }
    }

    /// The name known_hosts keeps the key under: the host, lower case,
    /// and in brackets with the port when it is not 22.
    fn hostName(client: *Client) void {
        var at: usize = 0;
        const bracket = client.port != port_default;
        if (bracket) {
            client.host_name[0] = '[';
            at = 1;
        }
        var index: usize = 0;
        while (client.host[index] != 0 and at < client.host_name.len - 10) : (index += 1) {
            const char = client.host[index];
            client.host_name[at] = if (char >= 'A' and char <= 'Z') char + 32 else char;
            at += 1;
        }
        if (bracket) {
            client.host_name[at] = ']';
            client.host_name[at + 1] = ':';
            at += 2;
            at += decimal(client.port, client.host_name[at..]);
        }
        client.host_name[at] = 0;
        client.host_name_length = at;
    }

    /// A TCP connection to the host, left with the stack for ssh.device:
    /// its id, or null, said why.
    fn connectSocket(client: *Client) ?i32 {
        const sb = client.sb;
        const hints: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM };
        var list: ?*bsd.addrinfo = null;
        if (sb.GetAddrInfo(&client.host, null, &hints, &list) != 0 or list == null) {
            _ = Printf(client.dl, MSG_NOHOST, .{ client.program, @as([*:0]const u8, &client.host) });
            return null;
        }
        defer sb.FreeAddrInfo(list.?);
        const target = list.?;
        // The port into whichever sockaddr it is: both have it at offset 2.
        @as(*align(1) u16, @ptrCast(@as([*]u8, @ptrCast(target.ai_addr.?)) + 2)).* = bsd.htons(client.port);
        const socket = sb.Socket(target.ai_family, bsd.SOCK_STREAM, 0);
        if (socket < 0) return client.socketFailed("Socket");
        if (sb.Connect(socket, target.ai_addr.?, target.ai_addrlen) < 0) {
            _ = client.socketFailed("Connect");
            _ = sb.CloseSocket(socket);
            return null;
        }
        const id = sb.ReleaseSocket(socket, bsd.UNIQUE_ID);
        if (id < 0) {
            _ = client.socketFailed("ReleaseSocket");
            _ = sb.CloseSocket(socket);
            return null;
        }
        return id;
    }

    fn socketFailed(client: *Client, what: [*:0]const u8) ?i32 {
        const sb = client.sb;
        _ = Printf(client.dl, MSG_FAILED, .{ client.program, what, bsd.errnoText(sb, sb.Errno()), sb.Errno() });
        return null;
    }

    // --- The host key ----------------------------------------------------

    const Known = enum { known, unknown, changed };

    /// Whether the host's key may be trusted: kept before, or kept now
    /// that the console said yes.
    fn hostKnown(client: *Client) bool {
        const dl = client.dl;
        const key = &client.connect.host_public;
        var print: [ssh_keys.fingerprint_bytes + 1]u8 = @splat(0);
        _ = ssh_keys.fingerprint(client.cb, key, print[0..ssh_keys.fingerprint_bytes]);
        const name: [*:0]const u8 = @ptrCast(&client.host_name);
        switch (client.lookUp(key)) {
            .known => return true,
            .changed => {
                _ = Printf(dl, MSG_CHANGED, .{ client.program, name, KNOWN_HOSTS_FILE, @as([*:0]const u8, @ptrCast(&print)) });
                return false;
            },
            .unknown => {},
        }
        if (!dl.IsInteractive(client.input)) {
            _ = Printf(dl, MSG_NOASK, .{ client.program, name });
            return false;
        }
        _ = Printf(dl, MSG_UNKNOWN, .{ name, @as([*:0]const u8, @ptrCast(&print)), KNOWN_HOSTS_FILE });
        _ = dl.Flush(client.output);
        var answer: [16]u8 = undefined;
        const got = dl.Read(client.input, &answer, answer.len);
        if (got < 3 or !same(answer[0..3], "yes")) return false;
        client.keep(key);
        return true;
    }

    /// The host's line in known_hosts: the same key, another key, or
    /// none.
    fn lookUp(client: *Client, key: *const [32]u8) Known {
        const dl = client.dl;
        const file = dl.Open(KNOWN_HOSTS_FILE, dos.MODE_OLDFILE) orelse return .unknown;
        defer _ = dl.Close(file);
        const got = dl.Read(file, &client.known, client.known.len);
        if (got <= 0) return .unknown;
        const name = client.host_name[0..client.host_name_length];
        var found: Known = .unknown;
        var lines = Lines{ .text = client.known[0..@intCast(got)] };
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

    /// The host's key added to known_hosts.
    fn keep(client: *Client, key: *const [32]u8) void {
        const dl = client.dl;
        var line: [ssh_keys.fingerprint_bytes + 400]u8 = undefined;
        const name_length = client.host_name_length;
        @memcpy(line[0..name_length], client.host_name[0..name_length]);
        line[name_length] = ' ';
        const length = name_length + 1 + ssh_keys.publicLine(key, "", line[name_length + 1 ..]);
        const file = dl.Open(KNOWN_HOSTS_FILE, dos.MODE_READWRITE) orelse dl.Open(KNOWN_HOSTS_FILE, dos.MODE_NEWFILE) orelse return;
        defer _ = dl.Close(file);
        _ = dl.Seek(file, 0, dos.OFFSET_END);
        if (dl.Write(file, &line, @intCast(length)) == length) {
            _ = Printf(dl, MSG_KEPT, .{ client.program, @as([*:0]const u8, @ptrCast(&client.host_name)) });
        }
    }

    // --- The login -------------------------------------------------------

    /// Logged in: with the key, if there is one - or with nothing, to
    /// hear what the server takes - then with passwords asked for. False,
    /// said why, when not.
    fn logIn(client: *Client) bool {
        const dl = client.dl;
        const login = &client.login;
        login.user = client.user;
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
            const result = client.step(ssh.SSHCMD_LOGIN, login, @sizeOf(ssh.SshLogin));
            client.showBanner();
            switch (result) {
                0 => return true,
                ssh.SSHERR_LOGIN => {},
                exec.IOERR_ABORTED => return false,
                else => {
                    client.gone();
                    return false;
                },
            }
            wipe(&login.password);
            login.password_length = 0;
            login.key_given = 0;
            const methods = sliceTo(&login.methods);
            if (!hasMethod(methods, "password") or tries == password_tries or !dl.IsInteractive(client.input)) {
                _ = Printf(dl, MSG_DENIED, .{ client.program, @as([*:0]const u8, @ptrCast(&login.methods)) });
                return false;
            }
            tries += 1;
            if (!client.askPassword()) return false;
        }
    }

    /// The banner the last SSHCMD_LOGIN brought, if any, shown as the
    /// console can show it: UTF-8 taken to Latin-1, a character Latin-1
    /// has not as `?`, the control characters left out but for tabs and
    /// line ends.
    fn showBanner(client: *Client) void {
        const dl = client.dl;
        const text = sliceTo(&client.login.banner);
        if (text.len == 0) return;
        _ = dl.Flush(client.output);
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
                _ = dl.Write(client.output, &shown, @intCast(length));
                length = 0;
            }
        }
        if (last != '\n') {
            shown[length] = '\n';
            length += 1;
        }
        _ = dl.Write(client.output, &shown, @intCast(length));
        client.login.banner[0] = 0;
    }

    /// The password, typed without its echo into the login: false when
    /// the input ended or Ctrl-C came.
    fn askPassword(client: *Client) bool {
        const dl = client.dl;
        const input = client.input;
        if (!dl.IsInteractive(input)) return false;
        _ = Printf(dl, MSG_PASSWORD, .{ @as([*:0]const u8, @ptrCast(&client.user)), @as([*:0]const u8, &client.host) });
        _ = dl.Flush(client.output);
        _ = dl.SetMode(input, 1);
        defer _ = dl.SetMode(input, 0);
        const login = &client.login;
        var length: usize = 0;
        while (true) {
            var char: [1]u8 = undefined;
            if (dl.Read(input, &char, 1) != 1 or char[0] == 3 or char[0] == 0x1C) {
                wipe(&login.password);
                _ = dl.Write(client.output, "\n", 1);
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
        _ = dl.Write(client.output, "\n", 1);
        login.password_length = @intCast(length);
        return true;
    }
};

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

/// The text in `bytes` up to its first NUL.
pub fn sliceTo(bytes: []const u8) []const u8 {
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
pub fn wipe(bytes: []u8) void {
    const volatile_bytes: []volatile u8 = bytes;
    for (volatile_bytes) |*byte| byte.* = 0;
}
