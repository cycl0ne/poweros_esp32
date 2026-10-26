// SPDX-License-Identifier: MIT
//! The user and token a server asks for: from the remote's URL, from
//! `ENVARC:Sys/net/git-credentials`, or typed on the console.
//!
//! The file is git's credential store: a URL a line, with the user and
//! the token in it, `%XX` for what a URL cannot hold -
//! `https://claus:ghp_abc123@github.com`. The first line whose scheme and
//! host (and user, when the remote's URL names one) are the server's is
//! taken. Typed credentials - the token without its echo - are offered
//! to the file once the server has taken them.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const url = @import("url.zig");
const files = @import("files.zig");
const Git = @import("context.zig").Git;

pub const FILE = "ENVARC:Sys/net/git-credentials";
const file_most = 64 * 1024;
const tries_most = 3;

pub const Credentials = struct {
    user: [url.secret_most + 1]u8 = @splat(0),
    user_length: usize = 0,
    password: [url.secret_most + 1]u8 = @splat(0),
    password_length: usize = 0,
    /// A user and a token to send.
    have: bool = false,
    /// They came with the URL: a server refusing them is not asked again.
    from_url: bool = false,
    /// The file has been looked in.
    looked: bool = false,
    /// Typed on the console, so many times: offered to the file once
    /// they worked.
    asked: u8 = 0,

    pub fn userText(credentials: *const Credentials) [*:0]const u8 {
        return @ptrCast(&credentials.user);
    }

    pub fn passwordText(credentials: *const Credentials) [*:0]const u8 {
        return @ptrCast(&credentials.password);
    }

    /// The token gone from memory.
    pub fn wipe(credentials: *Credentials) void {
        const volatile_password: *volatile [url.secret_most + 1]u8 = &credentials.password;
        for (volatile_password) |*byte| byte.* = 0;
        credentials.password_length = 0;
    }
};

/// The credentials a URL holds, taken.
pub fn fromUrl(remote: *const url.RemoteUrl, into: *Credentials) void {
    if (!remote.has_user) return;
    @memcpy(into.user[0..remote.user_length], remote.user[0..remote.user_length]);
    into.user[remote.user_length] = 0;
    into.user_length = remote.user_length;
    if (remote.has_password) {
        @memcpy(into.password[0..remote.password_length], remote.password[0..remote.password_length]);
        into.password[remote.password_length] = 0;
        into.password_length = remote.password_length;
        into.have = true;
        into.from_url = true;
    }
}

/// The next credentials to try after the server refused the last: from
/// the file first, then typed. False when there are no more to try.
pub fn next(git: *Git, remote: *const url.RemoteUrl, credentials: *Credentials) bool {
    if (credentials.from_url) return false;
    if (!credentials.looked) {
        credentials.looked = true;
        if (lookUp(git, remote, credentials)) return true;
    }
    if (credentials.asked == tries_most) return false;
    return ask(git, remote, credentials);
}

/// The file's first line for the remote's server: false when it has
/// none.
fn lookUp(git: *Git, remote: *const url.RemoteUrl, credentials: *Credentials) bool {
    const text = files.readWhole(git, FILE, file_most) orelse return false;
    defer {
        const volatile_text: [*]volatile u8 = text.ptr;
        for (0..text.len) |index| volatile_text[index] = 0;
        git.free(text.ptr);
    }
    const line_url = git.create(url.RemoteUrl) orelse return false;
    defer {
        const volatile_line: *volatile url.RemoteUrl = line_url;
        for (&volatile_line.password) |*byte| byte.* = 0;
        git.free(line_url);
    }
    var at: usize = 0;
    while (at < text.len) {
        var end = at;
        while (end < text.len and text[end] != '\n') end += 1;
        var line = text[at..end];
        at = end + 1;
        while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == ' ')) line = line[0 .. line.len - 1];
        if (!url.parse(line, line_url) or !line_url.has_user or !line_url.has_password) continue;
        if (!sameOrigin(line_url.origin(), remote.origin())) continue;
        if (credentials.user_length != 0 and !_git.same(line_url.user[0..line_url.user_length], credentials.user[0..credentials.user_length])) continue;
        @memcpy(credentials.user[0..line_url.user_length], line_url.user[0..line_url.user_length]);
        credentials.user[line_url.user_length] = 0;
        credentials.user_length = line_url.user_length;
        @memcpy(credentials.password[0..line_url.password_length], line_url.password[0..line_url.password_length]);
        credentials.password[line_url.password_length] = 0;
        credentials.password_length = line_url.password_length;
        credentials.have = true;
        return true;
    }
    return false;
}

/// Whether two `scheme://host[:port]` are one server: the host's case
/// does not count.
fn sameOrigin(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

/// The user (unless known) and the token typed on the console: false
/// when there is no console, or the input ended or Ctrl-C came.
fn ask(git: *Git, remote: *const url.RemoteUrl, credentials: *Credentials) bool {
    const dl = git.dl;
    const input = dl.Input();
    if (!dl.IsInteractive(input)) return false;
    git.endProgress();
    credentials.asked += 1;
    if (!remote.has_user) {
        git.put("Username for '");
        git.put(remote.origin());
        git.put("': ");
        _ = dl.Flush(git.output);
        var line: [url.secret_most + 2]u8 = undefined;
        const got = dl.FGets(input, &line, line.len) orelse return false;
        _ = got;
        var length: usize = 0;
        while (length < url.secret_most and line[length] != 0 and line[length] != '\n' and line[length] != '\r') length += 1;
        if (length == 0) return false;
        @memcpy(credentials.user[0..length], line[0..length]);
        credentials.user[length] = 0;
        credentials.user_length = length;
    }
    git.put("Password for '");
    const scheme_end = (indexOf(remote.origin(), "://") orelse 0) + 3;
    git.put(remote.origin()[0..scheme_end]);
    git.put(credentials.user[0..credentials.user_length]);
    git.put("@");
    git.put(remote.origin()[scheme_end..]);
    git.put("': ");
    _ = dl.Flush(git.output);
    _ = dl.SetMode(input, 1);
    defer _ = dl.SetMode(input, 0);
    var length: usize = 0;
    while (true) {
        var char: [1]u8 = undefined;
        if (dl.Read(input, &char, 1) != 1 or char[0] == 3 or char[0] == 0x1C) {
            credentials.wipe();
            git.put("\n");
            return false;
        }
        if (char[0] == '\r' or char[0] == '\n') break;
        if (char[0] == 8 or char[0] == 127) {
            if (length > 0) length -= 1;
        } else if (length < url.secret_most and char[0] >= ' ') {
            credentials.password[length] = char[0];
            length += 1;
        }
    }
    git.put("\n");
    credentials.password[length] = 0;
    credentials.password_length = length;
    credentials.have = true;
    return true;
}

/// Typed credentials that worked offered to the file: kept when the
/// answer is yes.
pub fn offer(git: *Git, remote: *const url.RemoteUrl, credentials: *const Credentials) void {
    if (credentials.asked == 0 or !credentials.have) return;
    const dl = git.dl;
    const input = dl.Input();
    if (!dl.IsInteractive(input)) return;
    git.endProgress();
    git.put("Keep them in " ++ FILE ++ " (yes/no)? ");
    _ = dl.Flush(git.output);
    var answer: [16]u8 = @splat(0);
    _ = dl.FGets(input, &answer, answer.len) orelse return;
    if (lower(answer[0]) != 'y') return;

    var line: [3 * (2 * url.secret_most + 1) + url.url_most + 8]u8 = undefined;
    defer {
        const volatile_line: *volatile @TypeOf(line) = &line;
        for (volatile_line) |*byte| byte.* = 0;
    }
    var out: _git.Out = .{ .into = &line };
    const origin = remote.origin();
    const scheme_end = (indexOf(origin, "://") orelse 0) + 3;
    out.put(origin[0..scheme_end]);
    url.encode(&out, credentials.user[0..credentials.user_length]);
    out.byte(':');
    url.encode(&out, credentials.password[0..credentials.password_length]);
    out.byte('@');
    out.put(origin[scheme_end..]);
    out.byte('\n');
    if (out.overflow) return;
    const old = files.readWhole(git, FILE, file_most);
    defer if (old) |text| {
        const volatile_text: [*]volatile u8 = text.ptr;
        for (0..text.len) |index| volatile_text[index] = 0;
        git.free(text.ptr);
    };
    if (!files.writeWhole(git, FILE, &.{ old orelse "", out.written() })) {
        _ = dl.PrintFault(dl.IoErr(), FILE);
        return;
    }
    git.put("Kept.\n");
}

fn indexOf(text: []const u8, wanted: []const u8) ?usize {
    if (text.len < wanted.len) return null;
    for (0..text.len - wanted.len + 1) |at| {
        if (_git.same(text[at..][0..wanted.len], wanted)) return at;
    }
    return null;
}
