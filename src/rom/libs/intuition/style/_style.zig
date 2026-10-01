// SPDX-License-Identifier: MPL-2.0
//! What a style is once intuition has read it, and how a property is found.
//!
//! A style is given as a tag list (`sdk/libs/intuition/style.zig`) and read
//! once, by `keep`, into a block of entries: one for each part and state the
//! list names, holding the properties the list gave it. Within one list the
//! first value met for a part, a state and a property is the one kept,
//! `TAG_MORE` included. Drawing never walks a tag list again.
//!
//! **Finding a property** (`look`) asks up to three kept styles - a gadget's
//! own, its screen's, the system's default - in this order:
//!
//! 1. the most particular state first: the exact combination of states,
//!    then each single state by `style.state_order`, then normal;
//! 2. for each state, the gadget's, then the screen's, then the default;
//! 3. within each, the exact part, then the part it falls back to.
//!
//! Every property is found on its own, so a list that gives a pressed
//! button a colour and nothing else leaves its border to whatever the
//! normal state, or the default, says. What no style says at all is the
//! fixed value of `Look`'s fields.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const style = sdk.intuition.style;
const sc = sdk.intuition.screens;
const ic = sdk.intuition.imageclass;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// The properties an entry may hold, each a bit in `Entry.set`.
pub const Prop = enum(u5) {
    background,
    border,
    border_colour,
    shine,
    shadow,
    border_x,
    border_y,
    joins,
    radius,
    text,
    padding_x,
    padding_y,
    opacity,
    transition,
};
const prop_count = @typeInfo(Prop).@"enum".fields.len;
const all_props: u32 = (1 << prop_count) - 1;

/// One part in one state, and what a list said about it.
const Entry = extern struct {
    part: u32,
    states: u32,
    /// A bit per `Prop` the list gave a value for.
    set: u32 = 0,
    /// A bit per `Prop` whose value is 0xAARRGGBB rather than a pen index.
    rgb: u32 = 0,
    values: [prop_count]u32 = @splat(0),
};

/// A kept style: its entries, in the one block `keep` allocated. What
/// `sdk.intuition.Style` stands for.
const Kept = extern struct {
    count: u32,
    entries: [0]Entry,

    fn all(kept: *const Kept) []const Entry {
        const first: [*]const Entry = @ptrCast(&kept.entries);
        return first[0..kept.count];
    }
};

/// Which properties a tag sets, and whether its value is a colour of its
/// own. Null for a tag that is not a property.
fn propsOf(tag: utility.Tag) ?struct { props: u32, rgb: bool } {
    const bit = struct {
        fn of(p: Prop) u32 {
            return @as(u32, 1) << @intFromEnum(p);
        }
    }.of;
    return switch (tag) {
        style.STYLE_Background => .{ .props = bit(.background), .rgb = false },
        style.STYLE_BackgroundRGB => .{ .props = bit(.background), .rgb = true },
        style.STYLE_Border => .{ .props = bit(.border), .rgb = false },
        style.STYLE_BorderPen => .{ .props = bit(.border_colour), .rgb = false },
        style.STYLE_BorderRGB => .{ .props = bit(.border_colour), .rgb = true },
        style.STYLE_ShinePen => .{ .props = bit(.shine), .rgb = false },
        style.STYLE_ShineRGB => .{ .props = bit(.shine), .rgb = true },
        style.STYLE_ShadowPen => .{ .props = bit(.shadow), .rgb = false },
        style.STYLE_ShadowRGB => .{ .props = bit(.shadow), .rgb = true },
        style.STYLE_BorderWidth => .{ .props = bit(.border_x) | bit(.border_y), .rgb = false },
        style.STYLE_BorderX => .{ .props = bit(.border_x), .rgb = false },
        style.STYLE_BorderY => .{ .props = bit(.border_y), .rgb = false },
        style.STYLE_Joins => .{ .props = bit(.joins), .rgb = false },
        style.STYLE_Radius => .{ .props = bit(.radius), .rgb = false },
        style.STYLE_TextPen => .{ .props = bit(.text), .rgb = false },
        style.STYLE_TextRGB => .{ .props = bit(.text), .rgb = true },
        style.STYLE_Padding => .{ .props = bit(.padding_x) | bit(.padding_y), .rgb = false },
        style.STYLE_PaddingX => .{ .props = bit(.padding_x), .rgb = false },
        style.STYLE_PaddingY => .{ .props = bit(.padding_y), .rgb = false },
        style.STYLE_Opacity => .{ .props = bit(.opacity), .rgb = false },
        style.STYLE_Transition => .{ .props = bit(.transition), .rgb = false },
        else => null,
    };
}

/// Read a style's tag list into a block of its own. Null for no list, a
/// list with no properties in it, or no memory.
///
/// INPUTS:
/// - `ib` - the library: utility.library to walk the list, exec for the
///   memory.
/// - `tags` - the list.
pub fn keep(ib: *IntuitionBase, tags: ?[*]const TagItem) ?*style.Style {
    const ub = ib.utility_base;
    // As many entries as the list could need: one before any marker, and
    // one more for each `STYLE_Part` or `STYLE_State`.
    var bound: u32 = 1;
    var walk: ?[*]const TagItem = tags;
    while (ub.NextTagItem(&walk)) |item| {
        if (item.tag == style.STYLE_Part or item.tag == style.STYLE_State) bound += 1;
    }

    const bytes = @sizeOf(Kept) + bound * @sizeOf(Entry);
    const memory = ib.sys_base.AllocVec(bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const kept: *Kept = @ptrCast(@alignCast(memory));
    const room: [*]Entry = @ptrCast(&kept.entries);

    var part: u32 = style.PART_MAIN;
    var states: u32 = style.STATE_NORMAL;
    var current: ?*Entry = null;
    walk = tags;
    while (ub.NextTagItem(&walk)) |item| {
        switch (item.tag) {
            style.STYLE_Part => {
                part = @truncate(item.data);
                states = style.STATE_NORMAL;
                current = null;
            },
            style.STYLE_State => {
                states = @truncate(item.data);
                current = null;
            },
            else => {
                const what = propsOf(item.tag) orelse continue;
                const entry = current orelse found: {
                    // The same part and state named a second time - further
                    // down, or through TAG_MORE - adds to the entry already
                    // there rather than starting another.
                    for (room[0..kept.count]) |*e| {
                        if (e.part == part and e.states == states) break :found e;
                    }
                    room[kept.count] = .{ .part = part, .states = states };
                    kept.count += 1;
                    break :found &room[kept.count - 1];
                };
                current = entry;
                // First one wins: a property already given is left alone.
                const fresh = what.props & ~entry.set;
                var bits = fresh;
                while (bits != 0) : (bits &= bits - 1) {
                    entry.values[@ctz(bits)] = @truncate(item.data);
                }
                entry.set |= fresh;
                if (what.rgb) entry.rgb |= fresh;
            },
        }
    }
    if (kept.count == 0) {
        ib.sys_base.FreeVec(memory);
        return null;
    }
    return @ptrCast(kept);
}

/// Give back what `keep` made. Null is allowed.
pub fn drop(ib: *IntuitionBase, kept: ?*style.Style) void {
    if (kept) |k| ib.sys_base.FreeVec(k);
}

/// A part in a state, every property found. What no style says is the
/// value given here.
pub const Look = struct {
    values: [prop_count]u32 = blk: {
        var v: [prop_count]u32 = @splat(0);
        v[@intFromEnum(Prop.opacity)] = 255;
        break :blk v;
    },
    rgb: u32 = 0,

    pub fn get(l: *const Look, p: Prop) u32 {
        return l.values[@intFromEnum(p)];
    }

    /// A colour property as a pen: its own colour, or the screen pen it
    /// names. A pen index the screen does not have is its first pen.
    pub fn colour(l: *const Look, p: Prop, pens: [*]const Pen, num_pens: u32) Pen {
        const value = l.get(p);
        if (l.rgb & @as(u32, 1) << @intFromEnum(p) != 0) return value;
        return pens[if (value < num_pens) value else 0];
    }
};

/// The entry for a part in a state exactly, in one kept style.
fn entryOf(kept: *const Kept, part: u32, states: u32) ?*const Entry {
    for (kept.all()) |*e| {
        if (e.part == part and e.states == states) return e;
    }
    return null;
}

/// Every property of a part in a state, found by the rule at the top of
/// this file.
///
/// INPUTS:
/// - `ib` - the library, for the default style.
/// - `own` - a gadget's own style, or null.
/// - `screen` - its screen's, or null.
/// - `part` - the part.
/// - `states` - the states it is in.
pub fn look(ib: *const IntuitionBase, own: ?*const style.Style, screen: ?*const style.Style, part: u32, states: u32) Look {
    var result = Look{};
    var have: u32 = 0;

    // The states to ask, most particular first.
    var asks: [style.state_order.len + 2]u32 = undefined;
    var ask_count: usize = 0;
    if (@popCount(states) > 1) {
        asks[ask_count] = states;
        ask_count += 1;
    }
    for (style.state_order) |single| {
        if (states & single != 0) {
            asks[ask_count] = single;
            ask_count += 1;
        }
    }
    asks[ask_count] = style.STATE_NORMAL;
    ask_count += 1;

    const layers = [_]?*const style.Style{ own, screen, ib.default_style };
    const base = part & style.PART_BASE_MASK;
    const parts = [_]u32{ part, base };
    const part_count: usize = if (base != part) 2 else 1;

    for (asks[0..ask_count]) |st| {
        for (layers) |maybe| {
            const kept: *const Kept = @ptrCast(@alignCast(maybe orelse continue));
            for (parts[0..part_count]) |p| {
                const e = entryOf(kept, p, st) orelse continue;
                const take = e.set & ~have;
                var bits = take;
                while (bits != 0) : (bits &= bits - 1) result.values[@ctz(bits)] = e.values[@ctz(bits)];
                result.rgb = (result.rgb & ~take) | (e.rgb & take);
                have |= take;
                if (have == all_props) return result;
            }
        }
    }
    return result;
}

/// The state bits an image state stands for. `IDS_SELECTED` is pressed:
/// an image is told it is selected, not why.
pub fn statesOfImage(ids: u32) u32 {
    return switch (ids) {
        ic.IDS_SELECTED, ic.IDS_INACTIVESELECTED => style.STATE_PRESSED,
        ic.IDS_DISABLED, ic.IDS_INACTIVEDISABLED => style.STATE_DISABLED,
        ic.IDS_SELECTEDDISABLED => style.STATE_PRESSED | style.STATE_DISABLED,
        else => style.STATE_NORMAL,
    };
}

// --- the system's default ---------------------------------------------------

fn pair(t: utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

/// A part's normal entry: everything a fixed part must say, so that a
/// lookup always ends somewhere.
fn complete(part: u32, border: u32, background: u32, text: u32, bx: u32, by: u32, px: u32, py: u32) [16]TagItem {
    return .{
        pair(style.STYLE_Part, part),
        pair(style.STYLE_State, style.STATE_NORMAL),
        pair(style.STYLE_Border, border),
        pair(style.STYLE_BorderPen, sc.SHADOWPEN),
        pair(style.STYLE_ShinePen, sc.SHINEPEN),
        pair(style.STYLE_ShadowPen, sc.SHADOWPEN),
        pair(style.STYLE_BorderX, bx),
        pair(style.STYLE_BorderY, by),
        pair(style.STYLE_Joins, style.JOINS_ANGLED),
        pair(style.STYLE_Radius, 0),
        pair(style.STYLE_Background, background),
        pair(style.STYLE_TextPen, text),
        pair(style.STYLE_PaddingX, px),
        pair(style.STYLE_PaddingY, py),
        pair(style.STYLE_Opacity, 255),
        pair(style.STYLE_Transition, 0),
    };
}

/// The system's default style: the look every frame had before there were
/// styles, in the screen's pens, so that a screen given no style looks
/// exactly as it always has.
///
/// A bevel's side strokes are two pixels and its top and bottom one, since
/// a pixel is taller than it is wide on the displays this look came from,
/// and the room inside is one stroke of each. A plain frame is one pixel
/// all round and meets at its corners square; the rest meet on the
/// diagonal. A pressed or checked thing is sunk and filled with the fill
/// pen; a disabled one keeps its normal look, and the gadget lays its
/// ghost over it.
pub const default_tags = complete(style.PART_MAIN, style.BORDER_RAISED, sc.BACKGROUNDPEN, sc.TEXTPEN, 2, 1, 2, 1) ++ [_]TagItem{
    pair(style.STYLE_State, style.STATE_PRESSED),
    pair(style.STYLE_Border, style.BORDER_RECESSED),
    pair(style.STYLE_Background, sc.FILLPEN),
    pair(style.STYLE_TextPen, sc.FILLTEXTPEN),
    pair(style.STYLE_State, style.STATE_CHECKED),
    pair(style.STYLE_Border, style.BORDER_RECESSED),
    pair(style.STYLE_Background, sc.FILLPEN),
    pair(style.STYLE_TextPen, sc.FILLTEXTPEN),
    pair(style.STYLE_State, style.STATE_DISABLED),
    pair(style.STYLE_Border, style.BORDER_RAISED),
    pair(style.STYLE_Background, sc.BACKGROUNDPEN),
    pair(style.STYLE_TextPen, sc.TEXTPEN),
    // frameiclass's plain frame: one pixel all round, square corners.
    pair(style.STYLE_Part, ic.PART_FRAME_PLAIN),
    pair(style.STYLE_BorderX, 1),
    pair(style.STYLE_PaddingX, 1),
    pair(style.STYLE_Joins, style.JOINS_NONE),
} ++ complete(style.PART_GROUP, style.BORDER_RIDGE, sc.BACKGROUNDPEN, sc.TEXTPEN, 2, 1, 2, 1) ++ [_]TagItem{
    pair(style.STYLE_State, style.STATE_PRESSED),
    pair(style.STYLE_Border, style.BORDER_GROOVE),
    pair(style.STYLE_Background, sc.FILLPEN),
    pair(style.STYLE_State, style.STATE_CHECKED),
    pair(style.STYLE_Border, style.BORDER_GROOVE),
    pair(style.STYLE_Background, sc.FILLPEN),
    pair(style.STYLE_State, style.STATE_DISABLED),
    pair(style.STYLE_Border, style.BORDER_RIDGE),
    pair(style.STYLE_Background, sc.BACKGROUNDPEN),
    // frameiclass's drop box: a ridge with room inside it for an icon.
    pair(style.STYLE_Part, ic.PART_FRAME_DROPBOX),
    pair(style.STYLE_PaddingX, 4),
    pair(style.STYLE_PaddingY, 2),
} ++ complete(style.PART_INDICATOR, style.BORDER_NONE, sc.FILLPEN, sc.FILLTEXTPEN, 0, 0, 0, 0) ++
    complete(style.PART_KNOB, style.BORDER_RAISED, sc.BACKGROUNDPEN, sc.TEXTPEN, 2, 1, 0, 0) ++
    complete(style.PART_TRACK, style.BORDER_RECESSED, sc.BACKGROUNDPEN, sc.TEXTPEN, 2, 1, 0, 0) ++
    complete(style.PART_SELECTION, style.BORDER_NONE, sc.FILLPEN, sc.FILLTEXTPEN, 0, 0, 0, 0) ++
    complete(style.PART_TITLE, style.BORDER_NONE, sc.FILLPEN, sc.FILLTEXTPEN, 0, 0, 0, 0) ++
    [_]TagItem{.{}};
