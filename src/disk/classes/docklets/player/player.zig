// SPDX-License-Identifier: MIT
//! player.docklet: what the Player plays (`SYS:Programs/Player`), as a
//! note in a ring that fills with the song's progress.
//!
//! The ring is in the track's pen, and as much of it as the song has
//! played, from the top round to the right, in the fill pen - all of it
//! while a station plays, which has no end. The note is in the text pen,
//! and while the Player pauses two bars stand in its place. With no
//! Player running, the note and the ring are in the track's pen alone.
//! What it says: "Playing: Title - Artist, 1:23 of 4:56", "Paused: ...",
//! "Player: stopped", "Player: not running". A click on it runs the
//! Player, which brings the window of the one running to the front.
//!
//! **It asks the Player** at its public port (`sdk.player`) twice a
//! second, without waiting: a look takes the answer to the question the
//! look before sent, and sends the next. So the dock, which calls it,
//! never waits on the Player; what it shows is half a second old. A
//! question the Player has not yet answered is waited for when the
//! docklet goes, as the Player answers each one, even as it ends.

const sdk = @import("sdk");
const exec = sdk.exec;
const docklets = sdk.docklets;
const player = sdk.player;

pub const Data = struct {
    /// Where the Player's answers come back.
    reply: ?*exec.MsgPort = null,
    /// The question; the Player's while `asked`.
    question: player.State = .{},
    asked: bool = false,
    /// What it shows: the last answer, or `PLAYER_GONE`.
    doing: u32 = player.PLAYER_GONE,
    seconds: u32 = 0,
    length: u32 = 0,
    title: [96]u8 = @splat(0),
    artist: [64]u8 = @splat(0),
    read: bool = false,
    text: [192]u8 = @splat(0),
};

const Class = docklets.DockletClass(Data, .{
    .name = docklets.PLAYER_CLASS,
    .version = 1,
    .date = "29.10.2026",
    .title = "Player",
    .command = "SYS:Programs/Player",
    .every = 500,
    .begin = begin,
    .end = end,
    .look = look,
    .text = text,
    .draw = draw,
});
pub const Library = Class.Library;
comptime {
    _ = Library;
}

fn begin(base: *sdk.gadgets.Base, own: *Data) bool {
    own.reply = base.sys_base.CreateMsgPort() orelse return false;
    return true;
}

fn end(base: *sdk.gadgets.Base, own: *Data) void {
    const sys = base.sys_base;
    const port = own.reply orelse return;
    if (own.asked) {
        _ = sys.WaitPort(port);
        _ = sys.GetMsg(port);
        own.asked = false;
    }
    sys.DeleteMsgPort(port);
    own.reply = null;
}

fn look(base: *sdk.gadgets.Base, own: *Data) bool {
    const sys = base.sys_base;
    const port = own.reply orelse return false;
    var heard = player.State{ .doing = own.doing, .seconds = own.seconds, .length = own.length, .title = own.title, .artist = own.artist };
    if (own.asked) {
        // Not answered yet: what it shows stands.
        if (sys.GetMsg(port) == null) return false;
        own.asked = false;
        heard = own.question;
    }
    own.question = player.State.asking(port);
    if (sys.SafePutToPort(&own.question.message, player.PORT_NAME)) {
        own.asked = true;
    } else {
        heard = .{};
    }
    if (own.read and heard.doing == own.doing and heard.seconds == own.seconds and heard.length == own.length and
        same(&heard.title, &own.title) and same(&heard.artist, &own.artist)) return false;
    own.read = true;
    own.doing = heard.doing;
    own.seconds = heard.seconds;
    own.length = heard.length;
    own.title = heard.title;
    own.artist = heard.artist;
    own.title[own.title.len - 1] = 0;
    own.artist[own.artist.len - 1] = 0;
    say(base.sys_base, own);
    return true;
}

/// What it shows, in words.
fn say(sys: *sdk.interface.exec.ExecBase, own: *Data) void {
    const doing: [*:0]const u8 = switch (own.doing) {
        player.PLAYER_PLAYING => "Playing",
        player.PLAYER_PAUSED => "Paused",
        player.PLAYER_STOPPED => if (own.title[0] == 0) return docklets.say(&own.text, "Player: stopped") else "Stopped",
        else => return docklets.say(&own.text, "Player: not running"),
    };
    const title: [*:0]const u8 = @ptrCast(&own.title);
    const artist: [*:0]const u8 = @ptrCast(&own.artist);
    const by: [*:0]const u8 = if (own.artist[0] != 0) " - " else "";
    const minutes = own.seconds / 60;
    const rest = own.seconds % 60;
    if (own.length == 0) {
        _ = docklets.format(sys, &own.text, "%s: %s%s%s, %u:%02u", .{ doing, title, by, artist, minutes, rest });
    } else {
        _ = docklets.format(sys, &own.text, "%s: %s%s%s, %u:%02u of %u:%02u", .{ doing, title, by, artist, minutes, rest, own.length / 60, own.length % 60 });
    }
}

fn same(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
        if (x == 0) return true;
    }
    return true;
}

fn text(own: *Data) [*:0]const u8 {
    return @ptrCast(&own.text);
}

/// How much of the ring the song has played, in degrees.
pub fn playedDegrees(seconds: u32, length: u32) i32 {
    if (length == 0) return 360;
    const share = @as(u64, @min(seconds, length)) * 360 / length;
    return @intCast(share);
}

fn draw(own: *Data, f: *const docklets.Frame) void {
    const p = f.pens;
    const middle = f.part(1, 2);
    const outer = f.part(47, 100);
    const inner = f.part(39, 100);
    const running = own.doing != player.PLAYER_GONE;
    f.arc(middle, middle, outer, inner, 0, 360, p.track);
    if (own.doing == player.PLAYER_PLAYING or own.doing == player.PLAYER_PAUSED) {
        const played = playedDegrees(own.seconds, own.length);
        // From the top, round to the right.
        if (played > 0) f.arc(middle, middle, outer, inner, 90 - played, 90, p.fill);
    }
    const ink = if (running) p.text else p.track;
    if (own.doing == player.PLAYER_PAUSED) {
        f.box(f.part(37, 100), f.part(32, 100), f.part(46, 100), f.part(68, 100), ink);
        f.box(f.part(54, 100), f.part(32, 100), f.part(63, 100), f.part(68, 100), ink);
        return;
    }
    // A note: its head, its stem on the head's right, a flag from the top.
    f.disc(f.part(43, 100), f.part(62, 100), f.part(10, 100), ink);
    f.box(f.part(48, 100), f.part(28, 100), f.part(53, 100), f.part(62, 100), ink);
    f.polygon(&.{ .{ f.part(52, 100), f.part(28, 100) }, .{ f.part(65, 100), f.part(38, 100) }, .{ f.part(65, 100), f.part(47, 100) }, .{ f.part(52, 100), f.part(37, 100) } }, ink);
}
