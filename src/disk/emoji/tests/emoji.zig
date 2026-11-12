// SPDX-License-Identifier: MIT
//! Host tests of the files of `LOCALE:Emoji` as a program reads them
//! (`sdk.emoji`): the list with its groups and skin tones, a names file
//! with its keywords, what is refused and what is passed by.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const emoji = sdk.emoji;

const list_file = "emoji-list 1 2 3\n" ++
    "@Smileys & Emotion\n" ++
    "\u{1F600}\n" ++
    "@People & Body\n" ++
    "\u{1F44B}\t\u{1F44B}\u{1F3FB}\t\u{1F44B}\u{1F3FC}\t\u{1F44B}\u{1F3FD}\t\u{1F44B}\u{1F3FE}\t\u{1F44B}\u{1F3FF}\n" ++
    "\u{1F9D1}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}\n";

test "the list: its counts, the groups and the emoji in order" {
    var list = emoji.List.open(list_file).?;
    try testing.expectEqual(@as(u32, 2), list.groups);
    try testing.expectEqual(@as(u32, 3), list.emoji);
    try testing.expectEqualStrings("Smileys & Emotion", list.next().?.group);
    const face = list.next().?.emoji;
    try testing.expectEqualStrings("\u{1F600}", face.text);
    try testing.expect(!face.hasTones());
    try testing.expectEqualStrings("\u{1F600}", face.toned(2));
    try testing.expectEqualStrings("People & Body", list.next().?.group);
    const hand = list.next().?.emoji;
    try testing.expectEqualStrings("\u{1F44B}", hand.text);
    try testing.expect(hand.hasTones());
    try testing.expectEqualStrings("\u{1F44B}", hand.toned(null));
    try testing.expectEqualStrings("\u{1F44B}\u{1F3FB}", hand.toned(0));
    try testing.expectEqualStrings("\u{1F44B}\u{1F3FF}", hand.toned(emoji.TONES - 1));
    try testing.expectEqualStrings("\u{1F44B}", hand.toned(emoji.TONES));
    try testing.expectEqualStrings("\u{1F9D1}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}", list.next().?.emoji.text);
    try testing.expect(list.next() == null);
    try testing.expect(list.next() == null);
}

test "the list: what is no list is refused, a line not as described passed by" {
    try testing.expect(emoji.List.open("") == null);
    try testing.expect(emoji.List.open("emoji-names 1 2 3\n") == null);
    try testing.expect(emoji.List.open("emoji-list 2 2 3\n") == null);
    try testing.expect(emoji.List.open("emoji-list 1 2\n") == null);
    try testing.expect(emoji.List.open("emoji-list 1 two 3\n") == null);
    // An empty line, an empty first field, fewer tones than five, and
    // a last line without its line feed.
    var list = emoji.List.open("emoji-list 1 0 2\n\n\t\u{1F600}\n\u{1F44B}\t\u{1F44B}\u{1F3FB}\n\u{1F600}").?;
    const hand = list.next().?.emoji;
    try testing.expectEqualStrings("\u{1F44B}", hand.text);
    try testing.expect(!hand.hasTones());
    try testing.expectEqualStrings("\u{1F600}", list.next().?.emoji.text);
    try testing.expect(list.next() == null);
}

test "the names: the language, a name and its keywords" {
    var names = emoji.Names.open("emoji-names 1 2 deutsch\n" ++
        "\u{1F600}\tgrinsendes Gesicht\tGesicht|lol\n" ++
        "broken\n" ++
        "\u{1F1E9}\u{1F1EA}\tFlagge: Deutschland\n").?;
    try testing.expectEqual(@as(u32, 2), names.count);
    try testing.expectEqualStrings("deutsch", names.language);
    const face = names.next().?;
    try testing.expectEqualStrings("\u{1F600}", face.emoji);
    try testing.expectEqualStrings("grinsendes Gesicht", face.name);
    var words = face.words();
    try testing.expectEqualStrings("Gesicht", words.next().?);
    try testing.expectEqualStrings("lol", words.next().?);
    try testing.expect(words.next() == null);
    const flag = names.next().?;
    try testing.expectEqualStrings("Flagge: Deutschland", flag.name);
    try testing.expectEqualStrings("", flag.keywords);
    try testing.expect(names.next() == null);
    try testing.expect(emoji.Names.open(list_file) == null);
    try testing.expect(emoji.Names.open("emoji-names 1 2\n") == null);
}

test "the names file's path" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("LOCALE:Emoji/deutsch.names", std.mem.span(emoji.namesPath(&buffer, "deutsch").?));
    var short: [26]u8 = undefined;
    try testing.expect(emoji.namesPath(&short, "deutsch") == null);
    var fits: [27]u8 = undefined;
    try testing.expect(emoji.namesPath(&fits, "deutsch") != null);
}
