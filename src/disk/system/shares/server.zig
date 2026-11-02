// SPDX-License-Identifier: MIT
//! The session to one server, and what it came to in words: where the
//! server is, who logs on, and the shares it says it has.
//!
//! **A look at a server is one session.** It is opened, `srvsvc` is asked
//! what shares there are (`smbclient`), and it is closed again - the tool
//! holds nothing open while somebody reads the list. The shares' names
//! point into the gathering buffer, which is kept until the next look.
//!
//! **Anonymous first, then asked for.** A look with nothing filled in
//! logs on anonymously; a server that refuses that, or that answers the
//! logon but not the question, is one that wants a user and a password,
//! and `Link.wants_user` says so, which is when the tool asks.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const smb = dos.smb;
const crypto = sdk.crypto;
const bsd = sdk.bsdsocket;
const client = @import("smbclient");
const browse = client.browse;
const share_area = client.shares;
const sharefile = client.sharefile;
const words = @import("words.zig");
const Line = words.Line;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;

/// The most shares shown of one server.
pub const max_shares: usize = 64;

/// The room a server takes in a field: its name, brackets round an
/// address with colons in it, and `:65535`.
pub const shown_max: usize = smb.SMB_SERVER_MAX + 8;

/// Where a listing is gathered: the answer's fragments and then the names
/// and comments themselves. A server with a few dozen shares is far below
/// it.
pub const gather_size: usize = 32 * 1024;

/// Who logs on. Nothing filled in is an anonymous logon.
pub const Account = struct {
    user: [smb.SMB_USER_MAX + 1:0]u8 = @splat(0),
    domain: [smb.SMB_DOMAIN_MAX + 1:0]u8 = @splat(0),
    /// What was typed, which is hashed and then never kept anywhere else.
    password: [sharefile.password_max + 1:0]u8 = @splat(0),
    /// The password's NT hash, once there was a password to hash.
    nt_hash: [16]u8 = @splat(0),
    has_hash: bool = false,
    /// Whether the password's hash is to be written beside the share
    /// file, so a later start can log on by itself.
    keep: bool = true,

    pub fn userName(account: *const Account) []const u8 {
        return words.untilNul(&account.user);
    }

    pub fn domainName(account: *const Account) []const u8 {
        return words.untilNul(&account.domain);
    }

    pub fn anonymous(account: *const Account) bool {
        return account.userName().len == 0 and !account.has_hash;
    }

    /// The password hashed and forgotten: the hash is all a logon needs,
    /// and all that is ever written down.
    pub fn takePassword(account: *const Account, cb: *CryptoBase) [16]u8 {
        var context: crypto.HashContext = .{};
        _ = cb.InitHash(&context, crypto.HASH_MD4);
        for (words.untilNul(&account.password)) |char| cb.UpdateHash(&context, &[2]u8{ char, 0 }, 2);
        var digest: [crypto.DIGEST_MAX]u8 = undefined;
        _ = cb.FinishHash(&context, &digest);
        return digest[0..16].*;
    }

    pub fn forgetPassword(account: *Account) void {
        @memset(&account.password, 0);
    }

    fn asGiven(account: *const Account) browse.Account {
        return .{
            .user = account.userName(),
            .domain = account.domainName(),
            .nt_hash = if (account.has_hash) account.nt_hash else null,
        };
    }
};

/// The session to one server and what it found.
pub const Link = struct {
    sys: *ExecBase,
    sb: *SocketBase,
    cb: *CryptoBase,
    session: client.Session,
    gather: []u8,

    /// Where the server is, as it was typed and taken apart.
    server: [smb.SMB_SERVER_MAX + 1:0]u8 = @splat(0),
    port: u16 = 0,
    /// How far the last look got.
    result: smb.SmbResult = .{},
    /// What the last question came to.
    listing: share_area.Listing = .{},
    /// The shares, as many as there was room for.
    shares: [max_shares]share_area.Share = @splat(.{}),
    count: usize = 0,
    /// The last look got a list.
    listed: bool = false,
    /// It wants a user and a password: it refused the logon, or answered
    /// it and then refused the question.
    wants_user: bool = false,
    /// There was no memory for the stack the look wanted, so it never
    /// went out.
    no_stack: bool = false,

    pub fn serverName(link: *const Link) []const u8 {
        return words.untilNul(&link.server);
    }

    /// The server as a field holds it: the name, and `:port` after it
    /// where the server is not on the usual port. An address with colons
    /// in it keeps brackets round it when a port follows, so that reading
    /// the line back finds the same place. The text is NUL-terminated in
    /// `into` and comes back without the NUL.
    pub fn shownIn(link: *const Link, into: *[shown_max:0]u8) []const u8 {
        @memset(into, 0);
        const name = link.serverName();
        if (link.port == 0) {
            _ = words.copyInto(into, name);
            return words.untilNul(into);
        }
        var at: usize = 0;
        const bracketed = indexOfColon(name) != null;
        if (bracketed) {
            into[at] = '[';
            at += 1;
        }
        for (name) |char| {
            into[at] = char;
            at += 1;
        }
        if (bracketed) {
            into[at] = ']';
            at += 1;
        }
        into[at] = ':';
        at += 1;
        at += words.putNumber(into[at..], link.port);
        into[at] = 0;
        return into[0..at];
    }

    /// Where the server is, from what was typed: `//nas`, `\\nas`,
    /// `smb://nas`, `nas`, any of them with `:port` after the name and an
    /// IPv6 address in brackets. False when there is no name in it.
    pub fn setServer(link: *Link, typed: []const u8) bool {
        var rest = typed;
        while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];
        while (rest.len > 0 and (rest[rest.len - 1] == ' ' or rest[rest.len - 1] == '\t')) rest = rest[0 .. rest.len - 1];
        rest = client.place.withoutScheme(rest);
        while (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
        // A share typed after the server is not an error: the share is
        // what the list is for, so only the server is taken.
        var cut: usize = 0;
        while (cut < rest.len and rest[cut] != '/' and rest[cut] != '\\') cut += 1;
        const host = rest[0..cut];
        if (host.len == 0 or host.len > smb.SMB_SERVER_MAX) return false;
        // `placeOf` knows where a port and an IPv6 address's brackets
        // are; it wants a share after the server, so one is lent to it.
        var with_share: [smb.SMB_SERVER_MAX + 8]u8 = undefined;
        with_share[0] = '/';
        with_share[1] = '/';
        @memcpy(with_share[2..][0..host.len], host);
        @memcpy(with_share[2 + host.len ..][0..2], "/x");
        const place = client.place.placeOf(with_share[0 .. 4 + host.len]) orelse return false;
        _ = words.copyInto(&link.server, place.server);
        link.port = place.port;
        return place.server.len > 0;
    }

    /// The server looked at: logged on, asked, and left again. Whatever
    /// came of it is in `result`, `listing` and `shares`.
    ///
    /// The work runs on a stack of its own, since a window's input loop
    /// is run on a stack that a logon and a share list together go
    /// deeper than.
    pub fn look(link: *Link, account: *const Account) void {
        link.listed = false;
        link.wants_user = false;
        link.count = 0;
        link.listing = .{};
        link.no_stack = false;
        var work: Work = .{ .link = link, .account = account };
        if (link.sys.NewStackRun(&onOwnStack, &work, client.stack_bytes) < 0) link.no_stack = true;
    }

    /// The look itself, on the stack `look` made for it.
    fn ask(link: *Link, account: *const Account) void {
        const given = account.asGiven();
        if (!browse.open(&link.session, @ptrCast(&link.server), link.port, &given, &link.result)) {
            link.wants_user = browse.refusedCredentials(&link.result) and account.anonymous();
            browse.close(&link.session);
            return;
        }
        defer browse.close(&link.session);
        link.listing = browse.list(&link.session, link.serverName(), &link.shares, link.gather) catch |err| {
            link.result.stage = smb.SMBSTAGE_TREE;
            if (err == error.Security) {
                link.result.stage = smb.SMBSTAGE_SECURITY;
                link.result.@"error" = smb.SMBSECURITY_SIGNATURE;
            }
            return;
        };
        if (!link.listing.ok()) {
            link.wants_user = browse.refusedQuestion(&link.listing) and account.anonymous();
            return;
        }
        link.count = link.listing.count;
        link.listed = true;
    }

    /// What `onOwnStack` is handed: the look's two arguments.
    const Work = struct {
        link: *Link,
        account: *const Account,
    };

    fn onOwnStack(arg: ?*anyopaque) callconv(.c) i32 {
        const work: *Work = @ptrCast(@alignCast(arg.?));
        work.link.ask(work.account);
        return 0;
    }
};

/// How the last look went, in words: the dialect and who the server took
/// the logon for when it worked, and where it stopped when it did not.
pub fn say(link: *const Link, line: *Line) void {
    const sys = link.sys;
    const server: [*:0]const u8 = @ptrCast(&link.server);
    const result = &link.result;
    line.clear();
    if (link.no_stack) {
        line.put("no memory for the stack the look wants");
        return;
    }
    if (link.listed) {
        line.add(sys, "%s: SMB %s", .{ server, dialectName(result.dialect) });
        if (result.signing != smb.SMB2_SIGNING_NONE) line.add(sys, ", signed with %s", .{signingName(result.signing)});
        if (result.cipher != smb.SMB2_CIPHER_NONE) line.add(sys, ", encrypted with %s", .{cipherName(result.cipher)});
        if (result.session_flags & smb.SMB2_SESSION_FLAG_IS_GUEST != 0) {
            line.add(sys, ", as a guest", .{});
        } else if (result.session_flags & smb.SMB2_SESSION_FLAG_IS_NULL != 0) {
            line.add(sys, ", anonymously", .{});
        }
        const total = link.listing.total;
        if (total > link.count) {
            line.add(sys, " - %u shares of %u", .{ @as(u32, @intCast(link.count)), total });
        } else {
            line.add(sys, " - %u shares", .{@as(u32, @intCast(link.count))});
        }
        return;
    }
    if (link.listing.refused or link.listing.status != share_area.NERR_SUCCESS or link.listing.pipe_status != smb.STATUS_SUCCESS) {
        sayQuestion(link, line, server);
        return;
    }
    switch (result.stage) {
        smb.SMBSTAGE_RESOLVE => line.add(sys, "%s: no address for that name", .{server}),
        smb.SMBSTAGE_CONNECT => if (result.@"error" == bsd.ECONNREFUSED) {
            line.add(sys, "%s: nothing answers on port %u", .{ server, @as(u32, portOf(link)) });
        } else {
            line.add(sys, "%s: no answer on port %u", .{ server, @as(u32, portOf(link)) });
        },
        smb.SMBSTAGE_NEGOTIATE => line.add(sys, "%s: speaks no SMB this one knows (status 0x%x)", .{ server, result.status }),
        smb.SMBSTAGE_LOGON => if (logonReason(result.status)) |reason| {
            line.add(sys, "%s: %s", .{ server, reason });
        } else {
            line.add(sys, "%s: the logon was refused (status 0x%x)", .{ server, result.status });
        },
        smb.SMBSTAGE_TREE => line.add(sys, "%s: would not open its own pipe (status 0x%x)", .{ server, result.status }),
        smb.SMBSTAGE_SECURITY => if (result.@"error" == smb.SMBSECURITY_SIGNATURE) {
            line.add(sys, "%s: an answer's signature was wrong", .{server});
        } else {
            line.add(sys, "%s: wants its messages encrypted, which this session cannot be", .{server});
        },
        smb.SMBSTAGE_NETWORK => line.put("no network or no crypto.library"),
        smb.SMBSTAGE_MEMORY => line.put("no memory"),
        else => line.add(sys, "%s: nothing came of it", .{server}),
    }
}

fn sayQuestion(link: *const Link, line: *Line, server: [*:0]const u8) void {
    const sys = link.sys;
    const listing = &link.listing;
    if (listing.pipe_status != smb.STATUS_SUCCESS) {
        switch (listing.pipe_status) {
            smb.STATUS_ACCESS_DENIED, smb.STATUS_NETWORK_ACCESS_DENIED => line.add(sys, "%s: will not say what shares it has", .{server}),
            smb.STATUS_BAD_NETWORK_NAME => line.add(sys, "%s: has no pipe to ask", .{server}),
            else => line.add(sys, "%s: would not answer what shares it has (status 0x%x)", .{ server, listing.pipe_status }),
        }
        return;
    }
    if (listing.status == share_area.ERROR_ACCESS_DENIED) {
        line.add(sys, "%s: will not say what shares it has", .{server});
        return;
    }
    if (listing.refused) {
        line.add(sys, "%s: answered its share list with something else", .{server});
        return;
    }
    line.add(sys, "%s: would not say what shares it has (%u)", .{ server, listing.status });
}

fn portOf(link: *const Link) u16 {
    return if (link.port == 0) smb.SMB_PORT else link.port;
}

/// What a share's kind is called in the list.
fn indexOfColon(text: []const u8) ?usize {
    for (text, 0..) |char, at| if (char == ':') return at;
    return null;
}

pub fn kindName(share: *const share_area.Share) [*:0]const u8 {
    return switch (share.kind()) {
        share_area.STYPE_DISKTREE => if (share.isSpecial()) "Disk*" else "Disk",
        share_area.STYPE_PRINTQ => "Printer",
        share_area.STYPE_DEVICE => "Device",
        share_area.STYPE_IPC => "Pipe",
        else => "?",
    };
}

/// The names of the dialects, ciphers and signing algorithms, as they are
/// said.
pub fn dialectName(dialect: u16) [*:0]const u8 {
    return switch (dialect) {
        smb.SMB2_DIALECT_0202 => "2.0.2",
        smb.SMB2_DIALECT_0210 => "2.1",
        smb.SMB2_DIALECT_0300 => "3.0",
        smb.SMB2_DIALECT_0302 => "3.0.2",
        smb.SMB2_DIALECT_0311 => "3.1.1",
        else => "?",
    };
}

fn signingName(algorithm: u16) [*:0]const u8 {
    return switch (algorithm) {
        smb.SMB2_SIGNING_HMAC_SHA256 => "HMAC-SHA256",
        smb.SMB2_SIGNING_AES_CMAC => "AES-CMAC",
        smb.SMB2_SIGNING_AES_GMAC => "AES-GMAC",
        else => "?",
    };
}

fn cipherName(cipher: u16) [*:0]const u8 {
    return switch (cipher) {
        smb.SMB2_CIPHER_AES_128_GCM => "AES-128-GCM",
        smb.SMB2_CIPHER_AES_256_GCM => "AES-256-GCM",
        smb.SMB2_CIPHER_AES_128_CCM => "AES-128-CCM",
        smb.SMB2_CIPHER_AES_256_CCM => "AES-256-CCM",
        else => "?",
    };
}

/// What a logon's refusal means, when it says.
pub fn logonReason(status: u32) ?[*:0]const u8 {
    return switch (status) {
        smb.STATUS_LOGON_FAILURE, smb.STATUS_WRONG_PASSWORD, smb.STATUS_NO_SUCH_USER => "wrong user or password",
        smb.STATUS_ACCOUNT_DISABLED => "the account is disabled",
        smb.STATUS_ACCOUNT_LOCKED_OUT => "the account is locked out",
        smb.STATUS_PASSWORD_EXPIRED => "the password has expired",
        smb.STATUS_ACCOUNT_RESTRICTION, smb.STATUS_INVALID_LOGON_HOURS => "the account may not log on now",
        smb.STATUS_ACCESS_DENIED, smb.STATUS_NETWORK_ACCESS_DENIED => "it will not have an anonymous logon",
        else => null,
    };
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// A link with nothing behind it: `setServer` touches neither the network
/// nor the session.
fn bare() Link {
    return .{
        .sys = undefined,
        .sb = undefined,
        .cb = undefined,
        .session = undefined,
        .gather = &.{},
    };
}

test "where the server is, however it was typed" {
    var link = bare();
    for ([_][]const u8{ "//nas.lan", "\\\\nas.lan", "nas.lan", "smb://nas.lan", "  nas.lan  ", "//nas.lan/", "//nas.lan/public" }) |typed| {
        try testing.expect(link.setServer(typed));
        try testing.expectEqualStrings("nas.lan", link.serverName());
        try testing.expectEqual(@as(u16, 0), link.port);
    }
    try testing.expect(link.setServer("//nas.lan:4445"));
    try testing.expectEqualStrings("nas.lan", link.serverName());
    try testing.expectEqual(@as(u16, 4445), link.port);
    try testing.expect(link.setServer("//[fe80::1]:446/x"));
    try testing.expectEqualStrings("fe80::1", link.serverName());
    try testing.expectEqual(@as(u16, 446), link.port);
    try testing.expect(link.setServer("[::1]"));
    try testing.expectEqualStrings("::1", link.serverName());
    try testing.expect(!link.setServer(""));
    try testing.expect(!link.setServer("//"));
    try testing.expect(!link.setServer("//nas:99999"));
}

test "the server as a field holds it, port and all" {
    var link = bare();
    var shown: [shown_max:0]u8 = @splat(0);
    try testing.expect(link.setServer("//nas.lan"));
    try testing.expectEqualStrings("nas.lan", link.shownIn(&shown));
    try testing.expect(link.setServer("//nas.lan:4445"));
    try testing.expectEqualStrings("nas.lan:4445", link.shownIn(&shown));
    try testing.expect(link.setServer("//[fe80::1]:446/x"));
    try testing.expectEqualStrings("[fe80::1]:446", link.shownIn(&shown));
    // What it shows is read back as the same place.
    try testing.expect(link.setServer(link.shownIn(&shown)));
    try testing.expectEqualStrings("fe80::1", link.serverName());
    try testing.expectEqual(@as(u16, 446), link.port);
    try testing.expect(link.setServer("[::1]"));
    try testing.expectEqualStrings("::1", link.shownIn(&shown));
}

test "a share's kind, as the list says it" {
    const disk: share_area.Share = .{ .kind_word = share_area.STYPE_DISKTREE };
    const hidden: share_area.Share = .{ .kind_word = share_area.STYPE_DISKTREE | share_area.STYPE_SPECIAL };
    const pipe: share_area.Share = .{ .kind_word = share_area.STYPE_IPC | share_area.STYPE_SPECIAL };
    try testing.expectEqualStrings("Disk", std.mem.span(kindName(&disk)));
    try testing.expectEqualStrings("Disk*", std.mem.span(kindName(&hidden)));
    try testing.expectEqualStrings("Pipe", std.mem.span(kindName(&pipe)));
    try testing.expectEqualStrings("3.1.1", std.mem.span(dialectName(smb.SMB2_DIALECT_0311)));
    try testing.expect(logonReason(smb.STATUS_LOGON_FAILURE) != null);
    try testing.expect(logonReason(smb.STATUS_SUCCESS) == null);
}
