// SPDX-License-Identifier: MPL-2.0
//! What a console's name asks for, and the window it opens.
//!
//! A console in a window is named by the string that opened it:
//!
//!   CON:left/top/width/height/title/OPTION/OPTION...
//!
//! The four numbers are the window's box, any of them empty or 0 meaning
//! "as much as the screen has left"; the text after them is the title; each
//! word after that is an option. What is not asked for is a window with a
//! drag bar, a depth gadget and a sizing gadget, activated when it opens,
//! smart refresh, and no close gadget - so a program that writes to a plain
//! `CON:` cannot have its output taken away from it.
//!
//! The options:
//!
//! - `CLOSE`, `NOCLOSE`: whether it has a close gadget. Using it is the end
//!   of the input, as Ctrl-\ is.
//! - `AUTO`: open the window at the first read, write, WAIT_CHAR or
//!   DISK_INFO rather than when the name is opened, so a console that is
//!   never spoken to never appears.
//! - `WAIT`: at the last close, keep the window until a key is pressed.
//! - `SMART`, `SIMPLE`: what covered pixels cost. Smart keeps them and is
//!   the default; simple gives them up and the console draws the text again.
//! - `INACTIVE`: do not activate it when it opens.
//! - `BACKDROP`: behind every ordinary window, and staying there.
//! - `NOBORDER`: no border, and no title.
//! - `NOSIZE`, `NODRAG`, `NODEPTH`: without that gadget.
//! - `SCREEN <name>`: open on that public screen rather than the default
//!   one; if it is not there, on the default one after all.
//! - `ALT left,top,width,height`: the box the zoom gadget flips to.
//!
//! `WINDOW <address>` is for a program that has opened a window of its own
//! and wants a console in it: the window's address, in hexadecimal, with
//! `0x` in front of it if it likes. **The console takes that window over**
//! and closes it when its last handle closes, so a program hands its window
//! away rather than lending it. What the console does not take is the
//! window's own event port - a program's gadgets and messages stay its own,
//! which is also why such a console has no close gadget of its own to hear.

const std = @import("std");
const sdk = @import("sdk");
const intuition = sdk.intuition;
const wn = intuition.windows;
const sc = intuition.screens;
const TagItem = sdk.utility.TagItem;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;

/// As much as the title and the screen name may be.
pub const max_title = 64;
pub const max_screen = 32;

/// How small a console may be sized: the border plus a line or two of
/// characters. intuition keeps a window on its screen by itself.
const min_width = 160;
const min_height = 60;

/// What the name asked for.
pub const Spec = struct {
    left: i32 = 0,
    top: i32 = 0,
    /// 0: as much as the screen has left.
    width: i32 = 0,
    height: i32 = 0,
    title: [max_title:0]u8 = @splat(0),
    screen: [max_screen:0]u8 = @splat(0),
    zoom: wn.WindowBox = .{ .left = -1, .top = -1, .width = 0, .height = 0 },
    has_zoom: bool = false,
    close: bool = false,
    simple: bool = false,
    activate: bool = true,
    backdrop: bool = false,
    borderless: bool = false,
    size: bool = true,
    drag: bool = true,
    depth: bool = true,
    /// Keep the window at the last close until a key is pressed.
    wait: bool = false,
    /// Do not open the window until something is read or written.
    auto: bool = false,
    /// A window the name handed over, for a program that wants its console
    /// in a window of its own making. 0: open one. It is kept as a number
    /// because that is all a string can carry; `adopted` makes it a window
    /// once something has looked at it.
    window: usize = 0,

    pub fn titleText(s: *const Spec) ?[*:0]const u8 {
        if (s.title[0] == 0) return null;
        return &s.title;
    }

    pub fn screenName(s: *const Spec) ?[*:0]const u8 {
        if (s.screen[0] == 0) return null;
        return &s.screen;
    }

    pub fn adopted(s: *const Spec) ?*wn.Window {
        return @ptrFromInt(s.window);
    }
};

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

/// `word` is at the front of `text`, whatever case it is written in. How
/// many characters it took, or 0.
fn takesWord(text: [*:0]const u8, word: []const u8) usize {
    for (word, 0..) |w, i| {
        if (upper(text[i]) != w) return 0;
    }
    return word.len;
}

/// A decimal number, with a sign. The characters it took.
fn readNumber(text: [*:0]const u8, value: *i32) usize {
    var i: usize = 0;
    var negative = false;
    if (text[0] == '-') {
        negative = true;
        i = 1;
    }
    var n: i32 = 0;
    var digits: usize = 0;
    while (text[i] >= '0' and text[i] <= '9') : (i += 1) {
        n = n * 10 + @as(i32, text[i] - '0');
        digits += 1;
    }
    if (digits == 0) return 0;
    value.* = if (negative) -n else n;
    return i;
}

/// A hexadecimal number, with `0x`, `0X`, `x` or `X` in front of it if it
/// likes. The characters it took.
fn readHex(text: [*:0]const u8, value: *usize) usize {
    var i: usize = 0;
    if (text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        i = 2;
    } else if (text[0] == 'x' or text[0] == 'X') {
        i = 1;
    }
    var n: usize = 0;
    var digits: usize = 0;
    while (true) : (i += 1) {
        const d: usize = switch (text[i]) {
            '0'...'9' => text[i] - '0',
            'a'...'f' => text[i] - 'a' + 10,
            'A'...'F' => text[i] - 'A' + 10,
            else => break,
        };
        n = (n << 4) | d;
        digits += 1;
    }
    if (digits == 0) return 0;
    value.* = n;
    return i;
}

/// Up to four numbers, `delimiter` or '/' between them, into `out`. Where
/// the numbers stopped.
fn readBox(text: [*:0]const u8, out: []i32, delimiter: u8) usize {
    var i: usize = 0;
    for (out) |*field| {
        if (text[i] == 0) break;
        i += readNumber(text + i, field);
        while (text[i] != 0 and text[i] != delimiter and text[i] != '/') i += 1;
        if (text[i] != 0) i += 1;
    }
    return i;
}

/// The name a console was opened by, as a Spec. Everything before and
/// including the first ':' is the device's name and is skipped; a name
/// that is only "CON:" asks for the default window.
pub fn parse(name: [*:0]const u8) Spec {
    var spec: Spec = .{};
    var i: usize = 0;
    while (name[i] != 0 and name[i] != ':') i += 1;
    if (name[i] == ':') i += 1;
    if (name[i] == 0) return spec;

    var box: [4]i32 = .{ 0, 0, 0, 0 };
    i += readBox(name + i, &box, '/');
    spec.left = box[0];
    spec.top = box[1];
    spec.width = box[2];
    spec.height = box[3];

    // The title, up to the next '/'.
    var n: usize = 0;
    while (name[i] != 0 and name[i] != '/') : (i += 1) {
        if (n < max_title) {
            spec.title[n] = name[i];
            n += 1;
        }
    }

    // The options, one per '/'.
    while (name[i] != 0) {
        if (name[i] != '/') {
            i += 1;
            continue;
        }
        i += 1;
        i += readOption(name + i, &spec);
    }
    return spec;
}

/// One option word and whatever belongs to it. The characters it took.
fn readOption(text: [*:0]const u8, spec: *Spec) usize {
    // In this order, so that a prefix like
    // "NOC" cannot be read as "NOCLOSE" before "NOCARE..." would be.
    const words = [_][]const u8{
        "WAIT",     "AUTO",     "CLOSE",    "NOCLOSE", "SMART",  "SIMPLE",
        "INACTIVE", "BACKDROP", "NOBORDER", "NOSIZE",  "NODRAG", "NODEPTH",
        "WINDOW",   "SCREEN",   "ALT",
    };
    var which: usize = words.len;
    var took: usize = 0;
    for (words, 0..) |word, index| {
        const n = takesWord(text, word);
        if (n == 0) continue;
        which = index;
        took = n;
        break;
    }
    if (which == words.len) return 0;
    if (text[took] == ' ') took += 1;
    switch (which) {
        0 => spec.wait = true,
        1 => {
            spec.auto = true;
            spec.close = true; // AUTO implies a close gadget
        },
        2 => spec.close = true,
        3 => spec.close = false,
        4 => spec.simple = false,
        5 => spec.simple = true,
        6 => spec.activate = false,
        7 => spec.backdrop = true,
        8 => {
            spec.borderless = true;
            spec.title[0] = 0;
        },
        9 => spec.size = false,
        10 => spec.drag = false,
        11 => spec.depth = false,
        12 => {
            took += readHex(text + took, &spec.window);
            // As much as a string can be asked to prove about a pointer:
            // a window is a structure, and a structure here is aligned.
            if (spec.window & 3 != 0) spec.window = 0;
        },
        13 => {
            var n: usize = 0;
            while (text[took] != 0 and text[took] != '/') : (took += 1) {
                if (n < max_screen) {
                    spec.screen[n] = text[took];
                    n += 1;
                }
            }
        },
        14 => {
            var box: [4]i32 = .{ 0, 0, 0, 0 };
            took += readBox(text + took, &box, ',');
            spec.zoom = .{ .left = box[0], .top = box[1], .width = box[2], .height = box[3] };
            spec.has_zoom = true;
        },
        else => {},
    }
    return took;
}

/// An attribute of a screen.
fn screenAttr(ib: *IntuitionBase, screen: *intuition.Screen, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetScreenAttrs(screen, &ask);
    return value;
}

/// An attribute of a window.
pub fn windowAttr(ib: *IntuitionBase, window: *wn.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(window, &ask);
    return value;
}

/// The window a name handed over, if it is one. Nothing here can look a
/// pointer up in a list of windows, so what can be asked of it is that
/// intuition knows a screen and a size for it - which is what the address
/// of something that is not a window would fail.
pub fn adopt(ib: *IntuitionBase, spec: *const Spec) ?*wn.Window {
    const w = spec.adopted() orelse return null;
    const screen = windowAttr(ib, w, wn.WA_Screen);
    if (screen == 0 or screen & 3 != 0) return null;
    if (windowAttr(ib, w, wn.WA_Width) == 0) return null;
    return w;
}

/// The window a Spec asks for, on the public screen it names or the
/// default one. The screen is held only while the window opens, as
/// intuition counts a window on a screen itself.
pub fn open(ib: *IntuitionBase, spec: *const Spec, idcmp: u32) ?*wn.Window {
    const screen = ib.LockPubScreen(spec.screenName()) orelse ib.LockPubScreen(null) orelse return null;
    defer ib.UnlockPubScreen(null, screen);
    const screen_width: i32 = @intCast(screenAttr(ib, screen, sc.SA_Width));
    const screen_height: i32 = @intCast(screenAttr(ib, screen, sc.SA_Height));
    const bar: i32 = @intCast(screenAttr(ib, screen, sc.SA_BarHeight));

    var left = spec.left;
    var top = spec.top;
    if (left < 0 or left >= screen_width) left = 0;
    if (top < 0 or top >= screen_height) top = bar + 1;
    // A size the name did not give, or one that would hang off the screen:
    // the rest of the screen from that corner.
    var width = spec.width;
    var height = spec.height;
    if (width < min_width or left + width > screen_width) width = screen_width - left;
    if (height < min_height or top + height > screen_height) height = screen_height - top;

    var tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = @bitCast(@as(isize, left)) },
        .{ .tag = wn.WA_Top, .data = @bitCast(@as(isize, top)) },
        .{ .tag = wn.WA_Width, .data = @bitCast(@as(isize, width)) },
        .{ .tag = wn.WA_Height, .data = @bitCast(@as(isize, height)) },
        .{ .tag = wn.WA_MinWidth, .data = min_width },
        .{ .tag = wn.WA_MinHeight, .data = min_height },
        .{ .tag = wn.WA_IDCMP, .data = idcmp },
        .{ .tag = wn.WA_Title, .data = @intFromPtr(spec.titleText()) },
        .{ .tag = wn.WA_CloseGadget, .data = @intFromBool(spec.close) },
        .{ .tag = wn.WA_SizeGadget, .data = @intFromBool(spec.size) },
        .{ .tag = wn.WA_DragBar, .data = @intFromBool(spec.drag) },
        .{ .tag = wn.WA_DepthGadget, .data = @intFromBool(spec.depth) },
        .{ .tag = wn.WA_Activate, .data = @intFromBool(spec.activate) },
        .{ .tag = wn.WA_Backdrop, .data = @intFromBool(spec.backdrop) },
        .{ .tag = wn.WA_Borderless, .data = @intFromBool(spec.borderless) },
        .{ .tag = wn.WA_SimpleRefresh, .data = @intFromBool(spec.simple) },
        .{ .tag = if (spec.has_zoom) wn.WA_Zoom else sdk.utility.TAG_IGNORE, .data = @intFromPtr(&spec.zoom) },
        .{},
    };
    return ib.OpenWindowTagList(&tags);
}

// --- tests ------------------------------------------------------------------

const testing = @import("std").testing;

test "a console's name is its window" {
    const plain = parse("CON:");
    try testing.expectEqual(@as(i32, 0), plain.width);
    try testing.expect(plain.titleText() == null);
    try testing.expect(!plain.close);
    try testing.expect(plain.size and plain.drag and plain.depth and plain.activate);
    try testing.expect(!plain.simple);

    const box = parse("CON:10/20/300/120/Hello");
    try testing.expectEqual(@as(i32, 10), box.left);
    try testing.expectEqual(@as(i32, 20), box.top);
    try testing.expectEqual(@as(i32, 300), box.width);
    try testing.expectEqual(@as(i32, 120), box.height);
    try testing.expectEqualStrings("Hello", std.mem.span(box.titleText().?));

    // A size left out is a size the screen decides, and the title may be
    // empty while options follow it.
    const some = parse("CON:0/0//130//CLOSE");
    try testing.expectEqual(@as(i32, 0), some.width);
    try testing.expectEqual(@as(i32, 130), some.height);
    try testing.expect(some.titleText() == null);
    try testing.expect(some.close);
}

test "the options a console's name may carry" {
    const spec = parse("CON:0/0/640/200/Shell/NOCLOSE/SIMPLE/NOSIZE/NODRAG/NODEPTH/INACTIVE/WAIT/SCREEN Workbench");
    try testing.expect(!spec.close);
    try testing.expect(spec.simple);
    try testing.expect(!spec.size and !spec.drag and !spec.depth);
    try testing.expect(!spec.activate);
    try testing.expect(spec.wait);
    try testing.expectEqualStrings("Workbench", std.mem.span(spec.screenName().?));

    // AUTO asks for a close gadget as well, and a window that is not there
    // until something is said on it.
    const auto = parse("CON:///-1/PowerOS/AUTO/SMART");
    try testing.expect(auto.auto and auto.close and !auto.simple);

    // NOBORDER takes the title with it: there is nowhere to put it.
    const bare = parse("CON:0/0/100/50/Title/NOBORDER");
    try testing.expect(bare.borderless);
    try testing.expect(bare.titleText() == null);

    const alt = parse("CON:0/0/640/200/Shell/ALT 10,20,300,120");
    try testing.expect(alt.has_zoom);
    try testing.expectEqual(@as(i32, 10), alt.zoom.left);
    try testing.expectEqual(@as(i32, 300), alt.zoom.width);

    // A name with no window part at all, and one that is not a window's.
    const nothing = parse("AUX:");
    try testing.expectEqual(@as(i32, 0), nothing.left);
    try testing.expect(nothing.titleText() == null);
}

test "a name can hand the console a window" {
    // The address, with or without the 0x in front of it, and in either
    // case.
    try testing.expectEqual(@as(usize, 0x1234ABC0), parse("CON:0/0/640/200/T/WINDOW 0x1234ABC0").window);
    try testing.expectEqual(@as(usize, 0x1234abc0), parse("CON://///WINDOW 0X1234abc0").window);
    try testing.expectEqual(@as(usize, 0x40000000), parse("CON://///WINDOW x40000000").window);
    try testing.expectEqual(@as(usize, 0x40000000), parse("CON://///WINDOW 40000000").window);

    // Options after it are still read, so the address stops where it ends.
    const both = parse("CON://///WINDOW 0x40000000/CLOSE/NOSIZE");
    try testing.expectEqual(@as(usize, 0x40000000), both.window);
    try testing.expect(both.close and !both.size);

    // An address that cannot be a window is no address at all, and the
    // console opens one of its own instead.
    try testing.expectEqual(@as(usize, 0), parse("CON://///WINDOW 0x1234ABC2").window);
    try testing.expectEqual(@as(usize, 0), parse("CON://///WINDOW 0").window);
    try testing.expectEqual(@as(usize, 0), parse("CON://///WINDOW").window);
    try testing.expectEqual(@as(usize, 0), parse("CON:0/0/640/200/Plain").window);
}
