// SPDX-License-Identifier: MIT
//! Smart HTTP: a remote's service (`git-upload-pack`, `git-receive-pack`)
//! reached through http.library. The advertisement is `GET
//! <url>/info/refs?service=<service>`; each exchange after it a `POST
//! <url>/<service>` whose body is the request, its answer read as it
//! comes - or, for a push's pack, sent a piece at a time, its length
//! said first. `Git-Protocol: version=2` goes with the advertisement's
//! request and, when the server answered in version 2, with every one
//! after it.
//!
//! A redirect of the first request moves the repository: the requests
//! after it go where it went. A 401 is answered with credentials
//! (credentials.zig) and the request made again, while there are any to
//! try. An answer that is not the service's own content type comes from a
//! server without smart HTTP, or from something that is no repository.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const http = sdk.http;
const utility = sdk.utility;
const _git = @import("_git.zig");
const url = @import("url.zig");
const files = @import("files.zig");
const credentials = @import("credentials.zig");
const transport = @import("transport.zig");
const Git = @import("context.zig").Git;

const MSG_STOPPED = "stopped\n";
const MSG_FAULT = "%s\n";
const MSG_STATUS = "%s: %s\n";
const MSG_NOTFOUND = "%s: no repository there\n";
const MSG_DENIED = "%s: the server wants credentials it was not given\n";
const MSG_NOTSMART = "%s: no repository Git can talk to answers there\n";
const MSG_BADURL = "%s is no URL Git can reach\n";
const MSG_TOOLARGE = "the request is larger than 2 GiB\n";

const redirects_most = 5;
const timeout_seconds = 120;

pub const HttpLink = struct {
    git: *Git,
    client: *http.Client,
    request: ?*http.Request = null,
    /// The repository, moved by a redirect of the first request.
    remote: url.RemoteUrl,
    service: []const u8,
    login: credentials.Credentials = .{},
    /// The URL of the request being made.
    target: [url.url_most + 1]u8 = undefined,

    /// The service at `remote` asked for its advertisement: the link, or
    /// null when it did not answer (said).
    pub fn open(git: *Git, remote: *const url.RemoteUrl, service: []const u8) ?*HttpLink {
        const hb = git.hb.?;
        const link = git.create(HttpLink) orelse return null;
        link.git = git;
        link.request = null;
        link.remote = remote.*;
        link.service = service;
        link.login = .{};
        credentials.fromUrl(remote, &link.login);
        link.client = hb.CreateClient(git.sb.?, &[_]utility.TagItem{
            .{ .tag = http.HTTP_Verify, .data = 1 },
            .{ .tag = http.HTTP_UserAgent, .data = @intFromPtr(transport.agent) },
            .{ .tag = http.HTTP_Timeout, .data = timeout_seconds },
            .{},
        }) orelse {
            git.say("no memory\n", .{});
            git.free(link);
            return null;
        };
        if (!link.advertise()) {
            link.close();
            return null;
        }
        return link;
    }

    pub fn close(link: *HttpLink) void {
        const git = link.git;
        const hb = git.hb.?;
        if (link.request) |request| hb.CloseRequest(request);
        hb.DeleteClient(link.client);
        link.login.wipe();
        git.free(link);
    }

    pub fn asLink(link: *HttpLink) transport.Link {
        return .{ .context = link, .exchange = exchange, .read = read, .begin = begin, .write = write, .end = end };
    }

    /// `GET <url>/info/refs?service=<service>`, answered with the
    /// credentials it takes.
    fn advertise(link: *HttpLink) bool {
        const git = link.git;
        const hb = git.hb.?;
        const suffix_start = "/info/refs?service=";
        while (true) {
            if (!link.setTarget(&.{ suffix_start, link.service })) return false;
            const request = link.openRequest("GET", &.{"Git-Protocol: version=2"}, .none, redirects_most) orelse return false;
            const status = hb.GetRequestAttr(request, http.HTTP_Status);
            if (status == 401) {
                hb.CloseRequest(request);
                link.request = null;
                if (credentials.next(git, &link.remote, &link.login)) continue;
                git.say(MSG_DENIED, .{link.remoteText()});
                return false;
            }
            if (!link.answered(status, "-advertisement")) return false;
            // Where the advertisement came from is where the repository
            // is now.
            const final = files.span(@ptrFromInt(hb.GetRequestAttr(request, http.HTTP_URL)));
            var suffix: [64]u8 = undefined;
            var out: _git.Out = .{ .into = &suffix };
            out.put(suffix_start);
            out.put(link.service);
            const ending = out.written();
            if (final.len > ending.len and _git.same(final[final.len - ending.len ..], ending)) {
                const base = final[0 .. final.len - ending.len];
                if (!_git.same(base, link.remote.text())) _ = url.parse(link.git.ub, base, &link.remote);
            }
            credentials.offer(git, &link.remote, &link.login);
            return true;
        }
    }

    /// Whether the answer is the service's: 200 and its content type
    /// (`application/x-<service><ending>`); said when not.
    fn answered(link: *HttpLink, status: usize, ending: []const u8) bool {
        const git = link.git;
        const hb = git.hb.?;
        const request = link.request.?;
        if (status == 404) {
            git.say(MSG_NOTFOUND, .{link.remoteText()});
            return false;
        }
        if (status != 200) {
            git.say(MSG_STATUS, .{ link.remoteText(), @as([*:0]const u8, @ptrFromInt(hb.GetRequestAttr(request, http.HTTP_StatusLine))) });
            return false;
        }
        var wanted: [64]u8 = undefined;
        var out: _git.Out = .{ .into = &wanted };
        out.put("application/x-");
        out.put(link.service);
        out.put(ending);
        const given = hb.GetHeader(request, "Content-Type") orelse {
            git.say(MSG_NOTSMART, .{link.remoteText()});
            return false;
        };
        if (!_git.startsWith(files.span(given), out.written())) {
            git.say(MSG_NOTSMART, .{link.remoteText()});
            return false;
        }
        return true;
    }

    /// `<url><parts>` as the next request's URL.
    fn setTarget(link: *HttpLink, parts: []const []const u8) bool {
        var out: _git.Out = .{ .into = link.target[0..url.url_most] };
        out.put(link.remote.text());
        for (parts) |part| out.put(part);
        if (out.overflow) {
            link.git.say(MSG_BADURL, .{link.remoteText()});
            return false;
        }
        link.target[out.at] = 0;
        return true;
    }

    fn remoteText(link: *const HttpLink) [*:0]const u8 {
        return @ptrCast(&link.remote.url);
    }

    /// The request made, the one before it closed: null when it failed
    /// (said).
    fn openRequest(link: *HttpLink, method: [*:0]const u8, headers: []const [*:0]const u8, body: Body, redirects: u32) ?*http.Request {
        const git = link.git;
        const hb = git.hb.?;
        if (link.request) |old| hb.CloseRequest(old);
        link.request = null;
        var tags: [12]utility.TagItem = undefined;
        var count: usize = 0;
        for (headers) |line| {
            tags[count] = .{ .tag = http.HTTP_Header, .data = @intFromPtr(line) };
            count += 1;
        }
        switch (body) {
            .none => {},
            .bytes => |bytes| {
                tags[count] = .{ .tag = http.HTTP_Body, .data = @intFromPtr(bytes.ptr) };
                tags[count + 1] = .{ .tag = http.HTTP_BodyLength, .data = bytes.len };
                count += 2;
            },
            .length => |length| {
                tags[count] = .{ .tag = http.HTTP_BodyLength, .data = length };
                count += 1;
            },
        }
        if (link.login.have) {
            tags[count] = .{ .tag = http.HTTP_User, .data = @intFromPtr(link.login.userText()) };
            tags[count + 1] = .{ .tag = http.HTTP_Password, .data = @intFromPtr(link.login.passwordText()) };
            count += 2;
        }
        tags[count] = .{ .tag = http.HTTP_Redirects, .data = redirects };
        tags[count + 1] = .{};
        var err: i32 = http.HTTPERR_OK;
        link.request = hb.OpenRequest(link.client, method, @ptrCast(&link.target), &tags, &err) orelse {
            link.failed(err);
            return null;
        };
        return link.request;
    }

    /// `POST <url>/<service>`, the request's content type and the
    /// answer's said, with `body`.
    fn post(link: *HttpLink, body: Body, version: u8) ?*http.Request {
        if (!link.setTarget(&.{ "/", link.service })) return null;
        var content_type: [64]u8 = undefined;
        var accept: [64]u8 = undefined;
        const headers = [_][*:0]const u8{
            header(&content_type, &.{ "Content-Type: application/x-", link.service, "-request" }),
            header(&accept, &.{ "Accept: application/x-", link.service, "-result" }),
            "Git-Protocol: version=2",
        };
        return link.openRequest("POST", headers[0..if (version == 2) 3 else 2], body, 0);
    }

    fn exchange(context: *anyopaque, body: []const u8, version: u8) bool {
        const link: *HttpLink = @ptrCast(@alignCast(context));
        const request = link.post(.{ .bytes = body }, version) orelse return false;
        return link.answered(link.git.hb.?.GetRequestAttr(request, http.HTTP_Status), "-result");
    }

    fn begin(context: *anyopaque, length: u64, version: u8) bool {
        const link: *HttpLink = @ptrCast(@alignCast(context));
        if (length > 0x7FFF_FFFF) {
            link.git.say(MSG_TOOLARGE, .{});
            return false;
        }
        return link.post(.{ .length = @intCast(length) }, version) != null;
    }

    fn write(context: *anyopaque, bytes: []const u8) bool {
        const link: *HttpLink = @ptrCast(@alignCast(context));
        const git = link.git;
        if (git.stopped()) {
            git.say(MSG_STOPPED, .{});
            return false;
        }
        const done = git.hb.?.WriteRequest(link.request.?, bytes.ptr, @intCast(bytes.len));
        if (done < 0) {
            link.failed(done);
            return false;
        }
        return true;
    }

    /// The body ended, and the answer's head read.
    fn end(context: *anyopaque) bool {
        const link: *HttpLink = @ptrCast(@alignCast(context));
        const status = link.git.hb.?.WriteRequest(link.request.?, null, 0);
        if (status < 0) {
            link.failed(status);
            return false;
        }
        return link.answered(@intCast(status), "-result");
    }

    fn read(context: *anyopaque, into: []u8) i32 {
        const link: *HttpLink = @ptrCast(@alignCast(context));
        const git = link.git;
        if (git.stopped()) {
            git.say(MSG_STOPPED, .{});
            return http.HTTPERR_IO;
        }
        const got = git.hb.?.ReadRequest(link.request.?, into.ptr, @intCast(@min(into.len, 0x10000)));
        if (got < 0) link.failed(got);
        return got;
    }

    /// A failed request said: a URL Git cannot reach, or Ctrl-C's stop,
    /// in Git's words, anything else in http.library's (Fault) - what
    /// was wrong with a certificate, the host without an address, why
    /// the connection failed.
    fn failed(link: *HttpLink, code: i32) void {
        const git = link.git;
        const sb = git.sb.?;
        if (code == http.HTTPERR_URL) return git.say(MSG_BADURL, .{link.remoteText()});
        if (code == http.HTTPERR_IO and sb.Errno() == bsd.EINTR) return git.say(MSG_STOPPED, .{});
        var why: [256]u8 = undefined;
        _ = git.hb.?.Fault(link.client, code, null, &why, why.len);
        git.say(MSG_FAULT, .{@as([*:0]const u8, @ptrCast(&why))});
    }
};

/// A request's body: none, the bytes, or their length alone - the bytes
/// written after.
const Body = union(enum) {
    none,
    bytes: []const u8,
    length: usize,
};

/// `parts` joined into `into` as a header line.
fn header(into: *[64]u8, parts: []const []const u8) [*:0]const u8 {
    var out: _git.Out = .{ .into = into[0..63] };
    for (parts) |part| out.put(part);
    into[out.at] = 0;
    return @ptrCast(into);
}
