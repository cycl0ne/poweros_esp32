// SPDX-License-Identifier: MIT
//! Where WiFi keeps a network's passphrase: the first line of its file in
//! ENVARC:Sys/net/networks/ (`wireless.NETWORKS_DIRECTORY`), the file
//! named after the network - which C:net/AddNetInterface reads when it
//! joins the network at start.
//!
//! A network whose name holds a colon or a slash names no file, and one
//! with a quote or a line's end in it cannot be written as a value of the
//! interface file either (`keepable`).

const sdk = @import("sdk");
const wireless = sdk.devices.wireless;
const netinterface = @import("netinterface");

/// The room the path is made in.
pub const Path = [wireless.NETWORKS_DIRECTORY.len + 33:0]u8;

/// Whether `name` can name the file its passphrase is kept in.
pub fn keepable(name: []const u8) bool {
    if (!netinterface.writable(name) or name.len > 32) return false;
    for (name) |char| if (char == ':' or char == '/') return false;
    return true;
}

/// Where the passphrase for `ssid` is kept; null for a name that cannot
/// be a file's.
pub fn pathOf(ssid: []const u8, into: *Path) ?[*:0]const u8 {
    if (!keepable(ssid)) return null;
    @memset(into, 0);
    const directory = wireless.NETWORKS_DIRECTORY;
    @memcpy(into[0..directory.len], directory);
    @memcpy(into[directory.len..][0..ssid.len], ssid);
    return @ptrCast(into);
}

const testing = @import("std").testing;

test "a network's passphrase file, and the names that can have none" {
    try testing.expect(keepable("Home net"));
    try testing.expect(!keepable("a/b"));
    try testing.expect(!keepable("a:b"));
    try testing.expect(!keepable("say \"hi\""));
    var path: Path = undefined;
    const at = pathOf("Home net", &path).?;
    var length: usize = 0;
    while (at[length] != 0) length += 1;
    try testing.expectEqualStrings("ENVARC:Sys/net/networks/Home net", at[0..length]);
}
