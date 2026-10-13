// SPDX-License-Identifier: MIT
//! Terminal's settings: the line they are kept as, read and written, and
//! what they do to the bytes that cross the line.

const std = @import("std");
const testing = std.testing;
const settings_file = @import("../settings.zig");
const Settings = settings_file.Settings;

test "the settings' line read back as it was written" {
    var settings: Settings = .{};
    try testing.expect(settings.setDevice("usb/ftdi.device"));
    settings.unit = 2;
    settings.baud = 9600;
    settings.frame = 4; // 7E1
    settings.handshake = .xonxoff;
    settings.send_return = .crlf;
    settings.echo = true;
    settings.lf_newline = false;
    var text: [160]u8 = undefined;
    const n = settings_file.write(&settings, &text);
    try testing.expectEqualStrings(
        "DEVICE=\"usb/ftdi.device\" UNIT=2 BAUD=9600 FRAME=7E1 HANDSHAKE=XONXOFF RETURN=CRLF ECHO=ON LFNEWLINE=OFF\n",
        text[0..n],
    );
    var back: Settings = .{};
    try testing.expectEqual(@as(?[*:0]const u8, null), settings_file.parse(text[0..n], &back));
    try testing.expect(back.sameLine(&settings));
    try testing.expectEqual(settings.baud, back.baud);
    try testing.expectEqual(settings.frame, back.frame);
    try testing.expectEqual(settings.handshake, back.handshake);
    try testing.expectEqual(settings.send_return, back.send_return);
    try testing.expectEqual(settings.echo, back.echo);
    try testing.expectEqual(settings.lf_newline, back.lf_newline);
}

test "a word left out keeps its value; case does not matter" {
    var settings: Settings = .{};
    _ = settings.setDevice("serial.device");
    settings.unit = 1;
    try testing.expectEqual(@as(?[*:0]const u8, null), settings_file.parse("baud=57600 frame=8o1", &settings));
    try testing.expectEqualStrings("serial.device", settings.deviceName().?);
    try testing.expectEqual(@as(u32, 1), settings.unit);
    try testing.expectEqual(@as(u32, 57600), settings.baud);
    try testing.expectEqualStrings("8O1", settings.frameOf().name);
}

test "words that make no sense are told" {
    var settings: Settings = .{};
    try testing.expect(settings_file.parse("FRAME=9X1", &settings) != null);
    try testing.expect(settings_file.parse("BAUD=fast", &settings) != null);
    try testing.expect(settings_file.parse("COLOUR=RED", &settings) != null);
    try testing.expect(settings_file.parse("DEVICE=\"serial.device", &settings) != null);
    try testing.expectEqual(@as(?[:0]const u8, null), settings.deviceName());
}

test "Return as the settings say" {
    var settings: Settings = .{};
    try testing.expectEqualStrings("\r", settings_file.returnBytes(&settings));
    settings.send_return = .lf;
    try testing.expectEqualStrings("\n", settings_file.returnBytes(&settings));
    settings.send_return = .crlf;
    try testing.expectEqualStrings("\r\n", settings_file.returnBytes(&settings));
}

test "a line feed alone starts a new line, across calls" {
    var settings: Settings = .{};
    var last: u8 = 0;
    var into: [32]u8 = undefined;
    var n = settings_file.shown(&settings, "one\ntwo\r\n", &last, &into);
    try testing.expectEqualStrings("one\r\ntwo\r\n", into[0..n]);
    // A carriage return at the end of one burst, its line feed in the next.
    n = settings_file.shown(&settings, "three\r", &last, &into);
    try testing.expectEqualStrings("three\r", into[0..n]);
    n = settings_file.shown(&settings, "\nfour", &last, &into);
    try testing.expectEqualStrings("\nfour", into[0..n]);
    settings.lf_newline = false;
    n = settings_file.shown(&settings, "a\nb", &last, &into);
    try testing.expectEqualStrings("a\nb", into[0..n]);
}
