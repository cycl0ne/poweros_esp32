// SPDX-License-Identifier: MIT
//! Host tests of csv.zig: plain and quoted fields, a quote as two, commas
//! and line ends in quotes, carriage returns, empty fields, a last record
//! without a line end, and more fields than asked for.

const std = @import("std");
const csv = @import("../csv.zig");

const testing = std.testing;

fn expectRecord(reader: *csv.Reader, wanted: []const []const u8) !void {
    var fields: [8][]const u8 = undefined;
    const count = reader.next(&fields) orelse return error.TestExpectedRecord;
    try testing.expectEqual(wanted.len, count);
    for (wanted, fields[0..count]) |want, got| try testing.expectEqualStrings(want, got);
}

test "Player's CSV: a search's answer read record by record" {
    const answer =
        "name,url_resolved,tags,bitrate\r\n" ++
        "Groove Salad,http://ice1.example/gs,\"ambient,chillout\",128\r\n" ++
        "\"A \"\"quoted\"\" name\",http://x.example/,,\r\n" ++
        "\"Two\nlines\",http://y.example/,jazz,64\n" ++
        "Last,http://z.example/,,320";
    var text: [answer.len]u8 = answer.*;
    var reader = csv.Reader.init(&text);
    var names: [8][]const u8 = undefined;
    const count = reader.next(&names).?;
    try testing.expectEqual(@as(usize, 4), count);
    try testing.expectEqual(@as(usize, 2), csv.column(names[0..count], "tags").?);
    try testing.expectEqual(@as(usize, 3), csv.column(names[0..count], "bitrate").?);
    try testing.expect(csv.column(names[0..count], "favicon") == null);
    try expectRecord(&reader, &.{ "Groove Salad", "http://ice1.example/gs", "ambient,chillout", "128" });
    try expectRecord(&reader, &.{ "A \"quoted\" name", "http://x.example/", "", "" });
    try expectRecord(&reader, &.{ "Two\nlines", "http://y.example/", "jazz", "64" });
    try expectRecord(&reader, &.{ "Last", "http://z.example/", "", "320" });
    var fields: [4][]const u8 = undefined;
    try testing.expect(reader.next(&fields) == null);
}

test "Player's CSV: more fields than room, an empty line, a comma at the end" {
    const answer = "a,b,c,d\n\nx,\n";
    var text: [answer.len]u8 = answer.*;
    var reader = csv.Reader.init(&text);
    var two: [2][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 4), reader.next(&two).?);
    try testing.expectEqualStrings("a", two[0]);
    try testing.expectEqualStrings("b", two[1]);
    try expectRecord(&reader, &.{""});
    try expectRecord(&reader, &.{ "x", "" });
    try testing.expect(reader.next(&two) == null);

    const ended = "p,";
    var more: [ended.len]u8 = ended.*;
    var last = csv.Reader.init(&more);
    try expectRecord(&last, &.{ "p", "" });
}
