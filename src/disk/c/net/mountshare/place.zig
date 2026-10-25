// SPDX-License-Identifier: MIT
//! Where a share is, from MountShare's SHARE: `//server/share`, with
//! forward or back slashes, an IPv6 address in brackets, and a port after
//! a colon when it is not the default.

/// Where a share is: the server, its port and the share's name, cut out
/// of `//server[:port]/share`.
pub const Place = struct {
    server: []const u8,
    port: u16 = 0,
    share: []const u8,
};

/// `//server/share` taken apart: forward or back slashes, an IPv6
/// address in brackets, a port after a colon; null when it is not one.
pub fn placeOf(text: []const u8) ?Place {
    var rest = text;
    while (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
    var cut: usize = 0;
    while (cut < rest.len and rest[cut] != '/' and rest[cut] != '\\') cut += 1;
    if (cut == rest.len) return null;
    const host = rest[0..cut];
    var share = rest[cut + 1 ..];
    while (share.len > 0 and (share[share.len - 1] == '/' or share[share.len - 1] == '\\')) share = share[0 .. share.len - 1];
    for (share) |char| if (char == '/' or char == '\\') return null;
    if (host.len == 0 or share.len == 0) return null;
    var place: Place = .{ .server = host, .share = share };
    // A port: after the brackets of an IPv6 address, or after the one
    // colon of a name.
    var colon: ?usize = null;
    if (host[0] == '[') {
        const close = indexOf(host, ']') orelse return null;
        if (close + 1 < host.len) {
            if (host[close + 1] != ':') return null;
            colon = close + 1;
        }
        place.server = host[1..close];
    } else if (indexOf(host, ':')) |at| {
        if (indexOf(host[at + 1 ..], ':') == null) colon = at;
    }
    if (colon) |at| {
        if (host[0] != '[') place.server = host[0..at];
        place.port = portOf(host[at + 1 ..]) orelse return null;
    }
    if (place.server.len == 0) return null;
    return place;
}

fn indexOf(text: []const u8, wanted: u8) ?usize {
    for (text, 0..) |char, at| if (char == wanted) return at;
    return null;
}

fn portOf(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > 5) return null;
    var value: u32 = 0;
    for (text) |char| {
        if (char < '0' or char > '9') return null;
        value = value * 10 + (char - '0');
    }
    if (value == 0 or value > 0xFFFF) return null;
    return @intCast(value);
}

const testing = @import("std").testing;

test "a share's place: names, ports, IPv6 and slashes either way" {
    const plain = placeOf("//nas/public").?;
    try testing.expectEqualStrings("nas", plain.server);
    try testing.expectEqualStrings("public", plain.share);
    try testing.expectEqual(@as(u16, 0), plain.port);
    const ported = placeOf("\\\\10.0.2.2:4445\\share\\").?;
    try testing.expectEqualStrings("10.0.2.2", ported.server);
    try testing.expectEqual(@as(u16, 4445), ported.port);
    try testing.expectEqualStrings("share", ported.share);
    const six = placeOf("//[fe80::1]:446/x").?;
    try testing.expectEqualStrings("fe80::1", six.server);
    try testing.expectEqual(@as(u16, 446), six.port);
    const bare_six = placeOf("//[::1]/x").?;
    try testing.expectEqualStrings("::1", bare_six.server);
    try testing.expect(placeOf("//nas") == null);
    try testing.expect(placeOf("//nas/a/b") == null);
    try testing.expect(placeOf("//nas:99999/a") == null);
    try testing.expect(placeOf("//:445/a") == null);
}
