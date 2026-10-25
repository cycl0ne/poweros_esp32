// SPDX-License-Identifier: MIT
//! What a share file says: DEVS:Shares/<NAME>, its keywords read into a
//! ShareFile, with the place of anything wrong in it - and the password
//! file beside it in ENVARC:, read as a password or its NT hash.
//!
//! ```
//! /* DEVS:Shares/NAS */
//! Share   = //nas.lan/public
//! User    = claus
//! Encrypt = YES
//! ```
//!
//! | Keyword | What it sets |
//! |---------|--------------|
//! | `Share` | where the share is: `//server/share`, a port after a colon if not 445, an IPv6 address in brackets; in quotes when it holds a space |
//! | `User`, `Domain` | who logs on, and in which domain |
//! | `Volume` | the volume's name; the share's without it |
//! | `Port` | the server's port, when `Share` does not say it |
//! | `ReadOnly` | `YES`: nothing is written, whatever the server allows; `NO` (the default) |
//! | `Encrypt` | `YES`: mounted only if every message can be encrypted; `NO` (the default) |
//!
//! Every keyword not in the table is an error, reported with its line and
//! column: a misspelt one would otherwise mount the share without what
//! the file was meant to say.
//!
//! **The password** is never in the share file, which anyone reading
//! DEVS: sees: it is the first line of ENVARC:Sys/net/shares/<NAME>. 32
//! hex digits there are taken as the password's NT hash, which is all a
//! logon needs - what MountShare's SAVE writes, so that the password
//! itself, which may open more than this share, is kept nowhere.

const sdk = @import("sdk");
const dos = sdk.dos;
const smb = dos.smb;
const keywords = dos.keywords;
const Scanner = keywords.Scanner;
const placeOf = @import("place.zig").placeOf;

pub const Keyword = enum { share, user, domain, volume, port, readonly, encrypt };

const names = [_]struct { name: []const u8, keyword: Keyword }{
    .{ .name = "SHARE", .keyword = .share },
    .{ .name = "USER", .keyword = .user },
    .{ .name = "DOMAIN", .keyword = .domain },
    .{ .name = "VOLUME", .keyword = .volume },
    .{ .name = "PORT", .keyword = .port },
    .{ .name = "READONLY", .keyword = .readonly },
    .{ .name = "ENCRYPT", .keyword = .encrypt },
};

/// The share files' directory, and the password files'.
pub const directory = "DEVS:Shares/";
pub const password_directory = "ENVARC:Sys/net/shares/";

/// The longest password a password file holds.
pub const password_max = 127;

/// What a share file says; an empty text was not given, a port of 0 is
/// none.
pub const ShareFile = struct {
    share: [keywords.max_token:0]u8 = @splat(0),
    user: [smb.SMB_USER_MAX:0]u8 = @splat(0),
    domain: [keywords.max_token:0]u8 = @splat(0),
    volume: [dos.name_max:0]u8 = @splat(0),
    port: u16 = 0,
    readonly: bool = false,
    encrypt: bool = false,
};

/// What is wrong, and where.
pub const Problem = struct {
    kind: enum { none, unknown, equal, text, long, place, number, yes_no, missing } = .none,
    /// The token it is about, and where it began.
    token: [keywords.max_token:0]u8 = @splat(0),
    line: u32 = 0,
    column: u32 = 0,
};

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 32 else char;
}

fn same(value: []const u8, want: []const u8) bool {
    if (value.len != want.len) return false;
    for (value, want) |got, expected| {
        if (upper(got) != expected) return false;
    }
    return true;
}

fn keywordOf(token: []const u8) ?Keyword {
    for (names) |entry| {
        if (same(token, entry.name)) return entry.keyword;
    }
    return null;
}

fn problem(scanner: *const Scanner, kind: @FieldType(Problem, "kind")) Problem {
    var found: Problem = .{ .kind = kind, .line = scanner.token_line, .column = scanner.token_column };
    @memcpy(found.token[0..scanner.len], scanner.token[0..scanner.len]);
    return found;
}

/// The token into `into` with its NUL: false when it does not fit, or
/// was cut at the scanner's longest.
fn copyText(into: []u8, scanner: *const Scanner) bool {
    if (scanner.len >= into.len or scanner.len == keywords.max_token) return false;
    @memcpy(into[0..scanner.len], scanner.token[0..scanner.len]);
    into[scanner.len] = 0;
    return true;
}

/// Every keyword in the file read into `file`: the first problem found,
/// or `.none`.
pub fn read(scanner: *Scanner, file: *ShareFile) Problem {
    while (scanner.next()) {
        const keyword = keywordOf(scanner.token[0..scanner.len]) orelse return problem(scanner, .unknown);
        if (!scanner.next() or scanner.len != 1 or scanner.token[0] != '=') return problem(scanner, .equal);
        if (!scanner.next()) return problem(scanner, .text);
        const value = scanner.token[0..scanner.len];
        switch (keyword) {
            .share => {
                if (!copyText(&file.share, scanner)) return problem(scanner, .long);
                if (placeOf(value) == null) return problem(scanner, .place);
            },
            .user => if (!copyText(&file.user, scanner)) return problem(scanner, .long),
            .domain => if (!copyText(&file.domain, scanner)) return problem(scanner, .long),
            .volume => if (!copyText(&file.volume, scanner)) return problem(scanner, .long),
            .port => {
                if (scanner.kind != .number or scanner.number < 1 or scanner.number > 0xFFFF) return problem(scanner, .number);
                file.port = @intCast(scanner.number);
            },
            .readonly, .encrypt => {
                const yes = if (same(value, "YES")) true else if (same(value, "NO")) false else return problem(scanner, .yes_no);
                if (keyword == .readonly) file.readonly = yes else file.encrypt = yes;
            },
        }
    }
    if (file.share[0] == 0) return .{ .kind = .missing, .token = tokenOf("Share") };
    return .{};
}

fn tokenOf(comptime text: []const u8) [keywords.max_token:0]u8 {
    var token: [keywords.max_token:0]u8 = @splat(0);
    @memcpy(token[0..text.len], text);
    return token;
}

fn hexDigit(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// A password file's first line as an NT hash, when it is 32 hex digits.
pub fn hashOf(line: []const u8) ?[16]u8 {
    if (line.len != 32) return null;
    var hash: [16]u8 = undefined;
    for (&hash, 0..) |*byte, index| {
        const high = hexDigit(line[2 * index]) orelse return null;
        const low = hexDigit(line[2 * index + 1]) orelse return null;
        byte.* = high << 4 | low;
    }
    return hash;
}

/// A password file's first line: up to its end, without the spaces after
/// it; null when it is empty.
pub fn firstLine(bytes: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < bytes.len and bytes[end] != '\n' and bytes[end] != '\r') end += 1;
    while (end > 0 and (bytes[end - 1] == ' ' or bytes[end - 1] == '\t')) end -= 1;
    if (end == 0) return null;
    return bytes[0..end];
}

/// A value SAVE can write: one the scanner reads back whole, in quotes -
/// no quote and no line's end in it.
pub fn savable(text: []const u8) bool {
    for (text) |char| {
        if (char == '"' or char == '\n' or char == '\r') return false;
    }
    return true;
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

fn readText(text: []const u8, file: *ShareFile) Problem {
    var scanner = Scanner.ofText(text);
    return read(&scanner, file);
}

test "a share file with every keyword" {
    var file: ShareFile = .{};
    const found = readText(
        \\/* the NAS in the cellar */
        \\Share = "//nas.lan:4445/My Files"; user = claus
        \\Domain = HOME
        \\Volume = Cellar
        \\Port = 446
        \\ReadOnly = yes
        \\Encrypt = YES
    , &file);
    try testing.expectEqual(.none, found.kind);
    try testing.expectEqualStrings("//nas.lan:4445/My Files", std.mem.sliceTo(&file.share, 0));
    try testing.expectEqualStrings("claus", std.mem.sliceTo(&file.user, 0));
    try testing.expectEqualStrings("HOME", std.mem.sliceTo(&file.domain, 0));
    try testing.expectEqualStrings("Cellar", std.mem.sliceTo(&file.volume, 0));
    try testing.expectEqual(@as(u16, 446), file.port);
    try testing.expect(file.readonly and file.encrypt);
}

test "a share file's mistakes, with their places" {
    var file: ShareFile = .{};
    const unknown = readText("Share = //a/b\nPasswrd = x", &file);
    try testing.expectEqual(.unknown, unknown.kind);
    try testing.expectEqualStrings("Passwrd", std.mem.sliceTo(&unknown.token, 0));
    try testing.expectEqual(@as(u32, 2), unknown.line);
    try testing.expectEqual(@as(u32, 1), unknown.column);

    file = .{};
    try testing.expectEqual(.equal, readText("Share //a/b", &file).kind);
    file = .{};
    try testing.expectEqual(.text, readText("Share =", &file).kind);
    file = .{};
    const place = readText("Share = //nas", &file);
    try testing.expectEqual(.place, place.kind);
    try testing.expectEqual(@as(u32, 9), place.column);
    file = .{};
    try testing.expectEqual(.number, readText("Share = //a/b\nPort = 70000", &file).kind);
    file = .{};
    try testing.expectEqual(.number, readText("Share = //a/b\nPort = x", &file).kind);
    file = .{};
    try testing.expectEqual(.yes_no, readText("Share = //a/b\nEncrypt = maybe", &file).kind);
    file = .{};
    try testing.expectEqual(.long, readText("Share = //a/b\nVolume = " ++ "v" ** (dos.name_max + 1), &file).kind);
    file = .{};
    const missing = readText("User = claus", &file);
    try testing.expectEqual(.missing, missing.kind);
    try testing.expectEqualStrings("Share", std.mem.sliceTo(&missing.token, 0));
}

test "a password file: its first line, as a password or an NT hash" {
    try testing.expectEqualStrings("secret", firstLine("secret  \r\nmore").?);
    try testing.expect(firstLine("\n") == null);
    try testing.expect(firstLine("") == null);
    const hash = hashOf("878D8014606CDA29677A44EFA1353FC7").?;
    try testing.expectEqual(@as(u8, 0x87), hash[0]);
    try testing.expectEqual(@as(u8, 0xC7), hash[15]);
    try testing.expect(hashOf("878d8014606cda29677a44efa1353fc") == null);
    try testing.expect(hashOf("878d8014606cda29677a44efa1353fcz") == null);
    try testing.expect(savable("//nas/My Files"));
    try testing.expect(!savable("a\"b"));
}
