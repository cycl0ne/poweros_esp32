// SPDX-License-Identifier: MIT
//! A remote reached for a verb: its URL taken apart, the link opened -
//! smart HTTP or SSH, as the URL says - the advertisement read. What
//! went wrong in the conversation is said here, and the server's
//! progress shown, `remote: ` before each of its lines, in UTF-8 as it
//! comes, its control characters - but for the line ends - as `?`.

const _git = @import("_git.zig");
const url = @import("url.zig");
const transport = @import("transport.zig");
const http_link = @import("http.zig");
const ssh_link = @import("ssh.zig");
const files = @import("files.zig");
const utility = @import("sdk").utility;
const Git = @import("context.zig").Git;

const MSG_BADURL = "%s is no URL Git can reach\n";

const Link = union(url.Kind) {
    http: *http_link.HttpLink,
    ssh: *ssh_link.SshLink,
};

pub const Connection = struct {
    git: *Git,
    remote_url: url.RemoteUrl,
    link: Link,
    remote: transport.Remote,
    /// The server's progress is at a line's start.
    line_start: bool = true,

    /// The remote at `text`, its `service` asked for its advertisement:
    /// null when it cannot be reached (said).
    pub fn open(git: *Git, text: [*:0]const u8, service: []const u8) ?*Connection {
        const connection = git.create(Connection) orelse return null;
        connection.git = git;
        connection.line_start = true;
        if (!url.parse(git.ub, spanOf(text), &connection.remote_url)) {
            git.say(MSG_BADURL, .{text});
            git.free(connection);
            return null;
        }
        if (!git.network()) {
            git.free(connection);
            return null;
        }
        connection.link = switch (connection.remote_url.kind) {
            .http => .{ .http = http_link.HttpLink.open(git, &connection.remote_url, service) orelse {
                git.free(connection);
                return null;
            } },
            .ssh => .{ .ssh = ssh_link.SshLink.open(git, &connection.remote_url, service) orelse {
                git.free(connection);
                return null;
            } },
        };
        connection.remote.init(switch (connection.link) {
            inline else => |link| link.asLink(),
        }, git.cb);
        connection.remote.listener = .{ .context = connection, .text = remoteText, .received = received };
        if (!connection.remote.start()) {
            connection.sayFailure();
            connection.close();
            return null;
        }
        return connection;
    }

    pub fn close(connection: *Connection) void {
        const git = connection.git;
        switch (connection.link) {
            inline else => |link| link.close(),
        }
        git.free(connection);
    }

    /// Why the conversation failed, said; nothing when the link said it.
    pub fn sayFailure(connection: *Connection) void {
        const git = connection.git;
        const remote = &connection.remote;
        switch (remote.failure) {
            .none, .link => {},
            .ended => git.say("the server's answer ended early\n", .{}),
            .malformed => git.say("the server's answer is no git protocol Git knows\n", .{}),
            .remote => git.say("the server says: %s\n", .{@as([*:0]const u8, @ptrCast(&remote.message))}),
            .object_format => git.say("the repository names its objects by SHA-256, which Git does not read\n", .{}),
            .no_shallow => git.say("the server cannot cut history short\n", .{}),
            .too_long => git.say("the request is too long\n", .{}),
            .pack => git.say("the pack is broken: its checksum is wrong\n", .{}),
            .sink => _ = git.dl.PrintFault(git.dl.IoErr(), "Git"),
            .stopped => git.say("stopped\n", .{}),
            .source => _ = git.dl.PrintFault(git.dl.IoErr(), "Git"),
            .unpack => git.say("the server could not take the pack: %s\n", .{@as([*:0]const u8, @ptrCast(&remote.message))}),
        }
    }

    fn remoteText(context: *anyopaque, text: []const u8) bool {
        const connection: *Connection = @ptrCast(@alignCast(context));
        const git = connection.git;
        if (git.quiet) return true;
        git.endProgress();
        var clean: [128]u8 = undefined;
        var length: usize = 0;
        for (text) |char| connection.show(&clean, &length, char);
        git.put(clean[0..length]);
        return !git.stopped();
    }

    /// One byte of the server's text onto the output, `remote: ` before
    /// each line, a control character as `?`.
    fn show(connection: *Connection, clean: *[128]u8, length: *usize, char: u8) void {
        const git = connection.git;
        if (connection.line_start) {
            git.put(clean[0..length.*]);
            length.* = 0;
            git.put("remote: ");
            connection.line_start = false;
        }
        clean[length.*] = if (char == '\n' or char == '\r') char else files.shown(char);
        length.* += 1;
        if (char == '\n' or char == '\r') connection.line_start = true;
        if (length.* == clean.len) {
            git.put(clean);
            length.* = 0;
        }
    }

    fn received(context: *anyopaque, bytes: u64) bool {
        const connection: *Connection = @ptrCast(@alignCast(context));
        const git = connection.git;
        if (!connection.line_start) {
            git.put("\n");
            connection.line_start = true;
        }
        git.progress("Receiving the pack: %lu KiB", .{bytes / 1024});
        return !git.stopped();
    }
};

fn spanOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}
