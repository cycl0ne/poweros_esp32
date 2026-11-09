// SPDX-License-Identifier: MIT
//! The clock's face: a dial and three hands, in the palette's metal, paper,
//! iron and red.
//!
//! The dial is a metal bezel, shaded and with a gloss over its top, round
//! a paper face that a faint shadow at its top sets back into it; sixty
//! marks, the minutes' fine, the hours' wide and shaded iron, the four
//! quarters longest; and a soft shadow under the whole of it. The hour and
//! minute hands are iron blades tapering to a point, the second hand a
//! thin red one with a weight at its tail, each throwing its own shadow
//! down and to the right - the higher a hand stands over the dial, the
//! farther.
//!
//! It is three pictures as big as the dial: the dial alone, made when the
//! size changes; the dial with the hour and minute hands, made again when
//! the minute does; and that with the second hand, made each second. A
//! second costs one copy and one hand.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const shapes = sdk.gadgets.shapes;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const picture = @import("picture.zig");
const time = @import("time.zig");
const Surface = picture.Surface;
const Shape = picture.Shape;

const pi: f32 = 3.14159265;

/// The dial's measures, in design units from its middle.
const bezel = 46.5;
const face_edge = 41.0;
const face = 40.2;
const marks_out = 38.6;
const minute_in = 36.3;
const hour_in = 31.4;
const quarter_in = 29.2;

const metal = shapes.tones(.metal);
const paper = shapes.tones(.paper);
const iron = shapes.tones(.iron);
const red = shapes.tones(.red);

pub const Face = struct {
    /// How many pixels across; 0 before the first `fit`.
    size: i32 = 0,
    dial: ?*Surface = null,
    hands: ?*Surface = null,
    whole: ?*Surface = null,
    /// The minute of the day the hands picture shows; -1 for none.
    drawn: i32 = -1,

    /// Its pictures for a dial `size` pixels across, the dial painted;
    /// false without the memory, and nothing then to put down.
    pub fn fit(own: *Face, gb: *GraphicsBase, rp: *graphics.RastPort, size: i32) bool {
        if (size == own.size and own.whole != null) return true;
        own.free(gb);
        if (size < 8) return false;
        own.dial = picture.make(gb, size, size);
        own.hands = picture.make(gb, size, size);
        own.whole = picture.make(gb, size, size);
        if (own.dial == null or own.hands == null or own.whole == null) {
            own.free(gb);
            return false;
        }
        own.size = size;
        paintDial(gb, rp, own.dial.?, size);
        return true;
    }

    pub fn free(own: *Face, gb: *GraphicsBase) void {
        gb.FreeBitMap(own.dial);
        gb.FreeBitMap(own.hands);
        gb.FreeBitMap(own.whole);
        own.* = .{};
    }

    /// The picture of the clock at `shown`, the second hand on it with
    /// `seconds`. Null before a `fit` that worked.
    pub fn at(own: *Face, gb: *GraphicsBase, rp: *graphics.RastPort, shown: time.Shown, seconds: bool) ?*const Surface {
        const hands = own.hands orelse return null;
        const whole = own.whole orelse return null;
        const hands_of = time.Hands.of(shown);
        const minute: i32 = @intCast(shown.hour * 60 + shown.minute);
        if (minute != own.drawn) {
            picture.copy(hands, own.dial.?);
            var p = picture.painter(gb, rp, hands, own.size);
            defer p.end();
            hourAndMinute(&p, own.size, hands_of, !seconds);
            own.drawn = minute;
        }
        if (!seconds) return hands;
        picture.copy(whole, hands);
        var p = picture.painter(gb, rp, whole, own.size);
        defer p.end();
        secondHand(&p, own.size, hands_of.second);
        return whole;
    }
};

/// (`along`, `across`) from the middle turned to `degrees` clockwise from
/// twelve: `along` towards where it points, `across` to its right.
fn turned(degrees: f32, along: f32, across: f32) [2]f32 {
    const angle = degrees * pi / 180;
    const sin = @sin(angle);
    const cos = @cos(angle);
    return .{ 50 + along * sin + across * cos, 50 - along * cos + across * sin };
}

/// A bar along the line at `degrees` from `from` to `to` units out,
/// `width` across.
fn spoke(degrees: f32, from: f32, to: f32, width: f32) [4][2]f32 {
    return .{
        turned(degrees, from, -width / 2),
        turned(degrees, to, -width / 2),
        turned(degrees, to, width / 2),
        turned(degrees, from, width / 2),
    };
}

/// A blade at `degrees`: `tail` units behind the middle and `base` wide
/// there, narrowing to `shoulder` wide at `shoulder_at` out, and to a
/// point at `tip`.
fn blade(degrees: f32, tail: f32, base: f32, shoulder_at: f32, shoulder: f32, tip: f32) [5][2]f32 {
    return .{
        turned(degrees, -tail, -base / 2),
        turned(degrees, shoulder_at, -shoulder / 2),
        turned(degrees, tip, 0),
        turned(degrees, shoulder_at, shoulder / 2),
        turned(degrees, -tail, base / 2),
    };
}

fn paintDial(gb: *GraphicsBase, rp: *graphics.RastPort, into: *Surface, size: i32) void {
    var p = picture.painter(gb, rp, into, size);
    defer p.end();
    // The shadow under it, soft: a near one and a wider, fainter one.
    p.fill(picture.disc(size, 50.6, 51.4, bezel), .{ .colour = 0x2600_0000 });
    p.fill(picture.disc(size, 51.2, 52.6, bezel), .{ .colour = 0x1400_0000 });
    // The bezel, its edge into the face, and the face set back in it.
    p.solid(&.{picture.disc(size, 50, 50, bezel)}, .metal, .{ .no_shadow = true });
    p.fill(picture.disc(size, 50, 50, face_edge), .{ .colour = metal.dark });
    p.fill(picture.disc(size, 50, 50, face), shapes.downward(paper.base, paper.light));
    p.fill(picture.ring(size, 50, 50, face, face - 3.0), picture.downwardThrough(0x2400_0000, 0x0000_0000, 90, 0x0000_0000));
    // The minutes' marks, each on its own: a list of them all would be
    // worked out over the whole face.
    for (0..60) |minute| {
        if (minute % 5 == 0) continue;
        const degrees = @as(f32, @floatFromInt(minute)) * 6;
        p.fill(picture.edges(size, &spoke(degrees, minute_in, marks_out, 0.75), 0, 0), .{ .colour = metal.dark });
    }
    // The hours', with a shadow of their own.
    for (0..12) |hour| {
        const quarter = hour % 3 == 0;
        const degrees = @as(f32, @floatFromInt(hour)) * 30;
        const corners = spoke(degrees, if (quarter) quarter_in else hour_in, marks_out, if (quarter) 3.4 else 2.4);
        p.fill(picture.edges(size, &corners, 0.3, 0.7), .{ .colour = 0x3000_0000 });
        p.solid(&.{picture.edges(size, &corners, 0, 0)}, .iron, .{ .no_shadow = true, .no_gloss = true });
    }
}

/// `list` laid as one in `colour`: where two of its shapes meet the
/// colour is laid once, which a shadow of several parts needs.
fn layAll(p: *shapes.Painter, list: []const Shape, colour: graphics.Pen) void {
    const ink = p.look.ink;
    defer p.look.ink = ink;
    p.look.ink = colour;
    p.ink(list);
}

/// A shadow's offset for something `lift` units over the dial: down, and
/// a little to the right.
fn shadowX(lift: f32) f32 {
    return lift * 0.45;
}

/// An iron hand: a dark rim and its body shaded downward.
fn ironHand(p: *shapes.Painter, size: i32, corners: []const [2]f32) void {
    const hand = picture.edges(size, corners, 0, 0);
    p.fill(hand, .{ .colour = shapes.darker(iron.dark, 170) });
    p.fill(hand.inset(@floatFromInt(p.rim)), shapes.downward(iron.base, iron.dark));
}

fn hourAndMinute(p: *shapes.Painter, size: i32, hands: time.Hands, with_pin: bool) void {
    const hour = blade(hands.hour, 7, 5.4, 23.5, 3.8, 27.5);
    const minute = blade(hands.minute, 8, 4.2, 34.5, 2.7, 38.4);
    // The minute hand stands higher, and throws its shadow farther.
    layAll(p, &.{
        picture.edges(size, &hour, shadowX(1.3), 1.3),
        picture.edges(size, &minute, shadowX(1.7), 1.7),
        picture.disc(size, 50 + shadowX(1.1), 51.1, 3.6),
    }, 0x4000_0000);
    ironHand(p, size, &hour);
    ironHand(p, size, &minute);
    // The cap the two turn on.
    p.solid(&.{picture.disc(size, 50, 50, 3.6)}, .iron, .{ .no_shadow = true });
    if (with_pin) p.fill(picture.disc(size, 50, 50, 1.1), .{ .colour = metal.base });
}

fn secondHand(p: *shapes.Painter, size: i32, degrees: f32) void {
    const bar = spoke(degrees, -12.5, 39.2, 0.95);
    const weight = turned(degrees, -9, 0);
    const lift = 2.1;
    const dx = shadowX(lift);
    layAll(p, &.{
        picture.edges(size, &bar, dx, lift),
        picture.disc(size, weight[0] + dx, weight[1] + lift, 2.5),
        picture.disc(size, 50 + dx, 50 + lift, 2.3),
    }, 0x3800_0000);
    layAll(p, &.{
        picture.edges(size, &bar, 0, 0),
        picture.disc(size, weight[0], weight[1], 2.5),
        picture.disc(size, 50, 50, 2.3),
    }, red.base);
    // A darker ring round the pin, and the pin.
    p.fill(picture.ring(size, 50, 50, 2.3, 1.5), .{ .colour = red.dark });
    p.fill(picture.disc(size, 50, 50, 0.7), .{ .colour = metal.light });
}
