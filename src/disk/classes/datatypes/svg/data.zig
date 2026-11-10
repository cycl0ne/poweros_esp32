// SPDX-License-Identifier: MIT
//! An `image`'s `data:` address (since 1.3): the picture it holds, in
//! the address itself, as RFC 2397 has it - a media type, `;base64`, a
//! comma, the bytes. Only base64's are read: a picture's bytes are binary,
//! and a percent-encoded one is not what the drawing programs write. No
//! other address is followed: a picture reads no other file.

const std = @import("std");

/// The base64 text of a `data:` address, spaces still in it; null for an
/// address of another kind, or data not in base64.
pub fn base64Of(href_in: []const u8) ?[]const u8 {
    const href = std.mem.trim(u8, href_in, " \t\r\n");
    if (href.len < 5 or !std.ascii.eqlIgnoreCase(href[0..5], "data:")) return null;
    const comma = std.mem.indexOfScalar(u8, href, ',') orelse return null;
    const header = href[5..comma];
    var parts = std.mem.splitScalar(u8, header, ';');
    var base64 = false;
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t\r\n"), "base64")) base64 = true;
    }
    if (!base64) return null;
    return href[comma + 1 ..];
}

/// The most bytes `text` decodes to.
pub fn decodedMost(text: []const u8) usize {
    return text.len / 4 * 3 + 3;
}

/// `text` decoded into `into`, which holds `decodedMost(text)`: the bytes
/// it held. Spaces and line ends are passed over, and so is `=` at the
/// end; null for a character that is not base64's.
pub fn decode(text: []const u8, into: []u8) ?[]u8 {
    var bits: u32 = 0;
    var held: u5 = 0;
    var n: usize = 0;
    for (text) |c| {
        const v: u32 = switch (c) {
            'A'...'Z' => c - 'A',
            'a'...'z' => c - 'a' + 26,
            '0'...'9' => c - '0' + 52,
            '+', '-' => 62,
            '/', '_' => 63,
            ' ', '\t', '\r', '\n', '=' => continue,
            // The URL's own escapes for the two: %2B and %2F.
            else => return null,
        };
        bits = bits << 6 | v;
        held += 6;
        if (held >= 8) {
            held -= 8;
            if (n == into.len) return null;
            into[n] = @truncate(bits >> held);
            n += 1;
        }
    }
    return into[0..n];
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

test "a data address's base64, decoded across line ends; other addresses none" {
    const text = base64Of(" data:image/png;base64,iVBO\n Rw0K ").?;
    var bytes: [16]u8 = undefined;
    try testing.expectEqualSlices(u8, "\x89PNG\r\n", decode(text, &bytes).?);
    try testing.expectEqualStrings("YQ==", base64Of("DATA:;BASE64,YQ==").?);
    try testing.expectEqualSlices(u8, "a", decode("YQ==", &bytes).?);
    try testing.expect(base64Of("data:image/svg+xml,%3Csvg") == null);
    try testing.expect(base64Of("picture.png") == null);
    try testing.expect(base64Of("#local") == null);
    try testing.expect(decode("YQ*=", &bytes) == null);
}
