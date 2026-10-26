// SPDX-License-Identifier: MIT
//! A remote's service over SSH (DEVS:ssh.device): the connection, the
//! host key checked against ENVARC:Sys/net/known_hosts, and the login -
//! with the key ENVARC:Sys/net/id_ed25519, else a password asked for on
//! the console - as C:net/SSH makes them; then the service run on the
//! server as a command, `git-upload-pack '<path>'`, with
//! `GIT_PROTOCOL=version=2` among its variables. The command's output is
//! the server's answers and its input the requests: one stream each way,
//! for as long as the link is open; its end is the end of the input.
//!
//! The command's error output comes on the same stream. What comes
//! before the protocol has started - a server without the repository
//! says so there - is shown as the server's words.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ssh = sdk.devices.ssh;
const connect = ssh.connect;
const _git = @import("_git.zig");
const url = @import("url.zig");
const transport = @import("transport.zig");
const files = @import("files.zig");
const context = @import("context.zig");
const Git = context.Git;

const MSG_REFUSED = "the server would not run %s\n";
const MSG_STOPPED = "stopped\n";
const MSG_NOCONSOLE = "SSH needs a console, for the questions it may ask\n";

/// The most of what the server says before the protocol starts.
const words_most = 512;

pub const SshLink = struct {
    git: *Git,
    reply_port: *exec.MsgPort,
    /// The client's steps; the session's reads and writes beside them.
    step_io: *exec.IOStdReq,
    read_io: *exec.IOStdReq,
    write_io: *exec.IOStdReq,
    /// The device is open, and the session runs.
    running: bool = false,
    /// The first bytes have come and are the protocol's.
    started: bool = false,
    client: connect.Client,

    /// `service` run at the remote: null when it could not be (said).
    pub fn open(git: *Git, remote: *const url.RemoteUrl, service: []const u8) ?*SshLink {
        const sys = git.sys;
        const dl = git.dl;
        const input = dl.Input() orelse {
            git.say(MSG_NOCONSOLE, .{});
            return null;
        };
        const output = git.output orelse {
            git.say(MSG_NOCONSOLE, .{});
            return null;
        };
        const link = git.create(SshLink) orelse return null;
        link.git = git;
        link.running = false;
        link.started = false;
        link.reply_port = sys.CreateMsgPort() orelse {
            git.free(link);
            git.say("no memory\n", .{});
            return null;
        };
        var requests: [3]*exec.IOStdReq = undefined;
        for (&requests, 0..) |*slot, made| {
            const io = sys.CreateIORequest(link.reply_port, @sizeOf(exec.IOStdReq)) orelse {
                for (requests[0..made]) |done| sys.DeleteIORequest(&done.req);
                sys.DeleteMsgPort(link.reply_port);
                git.free(link);
                git.say("no memory\n", .{});
                return null;
            };
            slot.* = @fieldParentPtr("req", io);
        }
        link.step_io = requests[0];
        link.read_io = requests[1];
        link.write_io = requests[2];
        link.client = .{
            .sys = sys,
            .dl = dl,
            .sb = git.sb.?,
            .cb = git.cb,
            .program = context.COMMAND_NAME,
            .input = input,
            .output = output,
            .reply_port = link.reply_port,
            .io = link.step_io,
        };
        if (!link.start(remote, service)) {
            link.close();
            return null;
        }
        return link;
    }

    /// Logged in, and the service running.
    fn start(link: *SshLink, remote: *const url.RemoteUrl, service: []const u8) bool {
        const git = link.git;
        const client = &link.client;
        if (!client.names(remote.hostText(), remote.userText())) return false;
        if (remote.port != 0) client.port = remote.port;
        git.endProgress();
        if (!client.start()) return false;
        link.running = true;
        client.share(link.read_io);
        client.share(link.write_io);

        var session: ssh.SshSession = .{};
        var out: _git.Out = .{ .into = session.command[0 .. session.command.len - 1] };
        out.put(service);
        out.put(" '");
        // A quote in the path closed, given escaped, and opened again.
        for (remote.pathText()) |char| {
            if (char == '\'') out.put("'\\''") else out.byte(char);
        }
        out.byte('\'');
        if (out.overflow) {
            git.say("the path is too long\n", .{});
            return false;
        }
        const variables = "GIT_PROTOCOL=version=2\x00\x00";
        @memcpy(session.environment[0..variables.len], variables);
        switch (client.step(ssh.SSHCMD_SESSION, &session, @sizeOf(ssh.SshSession))) {
            0 => return true,
            ssh.SSHERR_SESSION => {
                var name: [32]u8 = @splat(0);
                @memcpy(name[0..@min(service.len, name.len - 1)], service[0..@min(service.len, name.len - 1)]);
                git.say(MSG_REFUSED, .{@as([*:0]const u8, @ptrCast(&name))});
                return false;
            },
            exec.IOERR_ABORTED => return false,
            else => {
                client.gone();
                return false;
            },
        }
    }

    /// A flush packet - no more requests - and the session's input
    /// ended, the connection closed.
    pub fn close(link: *SshLink) void {
        const git = link.git;
        const sys = git.sys;
        if (link.running) {
            const flush = "0000";
            _ = link.request(link.write_io, exec.CMD_WRITE, @constCast(flush.ptr), flush.len);
            _ = link.client.step(ssh.SSHCMD_EOF, null, 0);
        }
        link.client.stop();
        sys.DeleteIORequest(&link.step_io.req);
        sys.DeleteIORequest(&link.read_io.req);
        sys.DeleteIORequest(&link.write_io.req);
        sys.DeleteMsgPort(link.reply_port);
        git.free(link);
    }

    pub fn asLink(link: *SshLink) transport.Link {
        return .{ .context = link, .exchange = exchange, .read = read, .begin = begin, .write = write, .end = end };
    }

    /// A request to the device on `io`, waited for - Ctrl-C aborts it:
    /// its io_Error, IOERR_ABORTED for Ctrl-C (said).
    fn request(link: *SshLink, io: *exec.IOStdReq, command: u16, data: ?*anyopaque, length: usize) i8 {
        const sys = link.git.sys;
        io.req.command = command;
        io.data = data;
        io.length = length;
        sys.SendIO(&io.req);
        while (sys.CheckIO(&io.req) == null) {
            const got = sys.Wait(link.reply_port.sigMask() | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0 and sys.CheckIO(&io.req) == null) {
                _ = sys.AbortIO(&io.req);
                _ = sys.WaitIO(&io.req);
                link.git.say(MSG_STOPPED, .{});
                return exec.IOERR_ABORTED;
            }
        }
        _ = sys.WaitIO(&io.req);
        return io.req.err;
    }

    /// Why the connection went, said as a step's would be.
    fn gone(link: *SshLink, io: *const exec.IOStdReq) void {
        link.client.io.req.err = io.req.err;
        link.client.io.actual = io.actual;
        link.git.endProgress();
        link.client.gone();
    }

    fn exchange(opaque_link: *anyopaque, body: []const u8, version: u8) bool {
        _ = version;
        return write(opaque_link, body);
    }

    /// A request in pieces is the stream's bytes, as any other: nothing
    /// to begin or end.
    fn begin(opaque_link: *anyopaque, length: u64, version: u8) bool {
        _ = opaque_link;
        _ = length;
        _ = version;
        return true;
    }

    fn write(opaque_link: *anyopaque, bytes: []const u8) bool {
        const link: *SshLink = @ptrCast(@alignCast(opaque_link));
        if (bytes.len == 0) return true;
        switch (link.request(link.write_io, exec.CMD_WRITE, @constCast(bytes.ptr), bytes.len)) {
            0 => return true,
            exec.IOERR_ABORTED => return false,
            else => {
                link.gone(link.write_io);
                return false;
            },
        }
    }

    fn end(opaque_link: *anyopaque) bool {
        _ = opaque_link;
        return true;
    }

    /// Some of what the session printed: how many bytes, 0 at its end,
    /// below 0 when it failed (said).
    fn readSome(link: *SshLink, into: []u8) i32 {
        switch (link.request(link.read_io, exec.CMD_READ, into.ptr, @min(into.len, 0x10000))) {
            0 => return @intCast(link.read_io.actual),
            exec.IOERR_ENDOFSTREAM => return 0,
            exec.IOERR_ABORTED => return -1,
            else => {
                link.gone(link.read_io);
                return -1;
            },
        }
    }

    fn read(opaque_link: *anyopaque, into: []u8) i32 {
        const link: *SshLink = @ptrCast(@alignCast(opaque_link));
        if (link.started) return link.readSome(into);
        // The first four bytes: a packet's length in hex, or words.
        var got: usize = 0;
        while (got < 4) {
            const more = link.readSome(into[got..]);
            if (more < 0) return more;
            if (more == 0) break;
            got += @intCast(more);
        }
        if (got >= 4 and isHex(into[0..4])) {
            link.started = true;
            return @intCast(got);
        }
        if (got == 0) return 0;
        // The server's words, to their end or as many as are kept.
        var words: [words_most]u8 = undefined;
        var length = @min(got, words.len);
        @memcpy(words[0..length], into[0..length]);
        while (length < words.len) {
            const more = link.readSome(words[length..]);
            if (more <= 0) break;
            length += @intCast(more);
        }
        link.say(words[0..length]);
        return -1;
    }

    /// `text` shown after `remote: `, a line each, made Latin-1, its
    /// control characters as `?`.
    fn say(link: *SshLink, text: []const u8) void {
        const git = link.git;
        git.endProgress();
        var rest = text;
        while (rest.len > 0) {
            var line_end: usize = 0;
            while (line_end < rest.len and rest[line_end] != '\n') line_end += 1;
            var line = rest[0..line_end];
            rest = if (line_end < rest.len) rest[line_end + 1 ..] else rest[rest.len..];
            while (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len == 0) continue;
            git.put("remote: ");
            var clean: [128]u8 = undefined;
            var at: usize = 0;
            var latin: files.Latin1 = .{};
            for (line) |byte| {
                const char = latin.take(byte) orelse continue;
                clean[at] = if (char < ' ' or (char >= 0x7F and char < 0xA0)) '?' else char;
                at += 1;
                if (at == clean.len) {
                    git.put(&clean);
                    at = 0;
                }
            }
            git.put(clean[0..at]);
            git.put("\n");
        }
    }
};

fn isHex(bytes: []const u8) bool {
    for (bytes) |char| {
        const digit = (char >= '0' and char <= '9') or (char >= 'a' and char <= 'f') or (char >= 'A' and char <= 'F');
        if (!digit) return false;
    }
    return true;
}
