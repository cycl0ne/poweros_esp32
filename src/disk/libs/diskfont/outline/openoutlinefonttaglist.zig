// SPDX-License-Identifier: MIT
//! OpenOutlineFontTagList: a family's outline in the face nearest a
//! weight, a width and a slant, as a document asks for them.
//!
//! The faces are the outline entries of the family's contents file and
//! of its faces' - `sans-bold.font`, `sans-italic.font`,
//! `sans-bolditalic.font` beside `sans.font` - and one is chosen as CSS
//! chooses a face: the nearest width first, then the slant, then the
//! nearest weight, each by the order CSS gives (`rankOf`). A variable
//! font is then moved on its axes to what was asked: `wght` to the
//! weight, `wdth` to the width, and on to the values the caller names,
//! which come last. The outline is the library's, as `OpenOutlineFont`'s
//! is (`_outline.openEntry`).

const sdk = @import("sdk");
const graphics = sdk.graphics;
const diskfont = sdk.diskfont;
const fontfile = sdk.diskfont.fontfile;
const truetype = sdk.truetype;
const utility = sdk.utility;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _font = @import("../font/_font.zig");
const opendiskfont = @import("../font/opendiskfont.zig");
const _outline = @import("_outline.zig");

/// A family's outline in the face nearest the weight, width and slant
/// asked.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenOutlineFontTagList(dfb: *DiskfontBase, name: [*:0]const u8, tags: ?[*]const utility.TagItem) ?*diskfont.OutlineFont
/// ```
///
/// SINCE: 1.16. LVO -60.
///
/// INPUTS:
/// - `name` - the family, "sans.font", as `OpenOutlineFont` takes it.
/// - `tags` - what is asked, `DFA_` tags; null asks for regular:
///   - `DFA_Weight` (u32) - how heavy, 1 to 1000; default 400.
///   - `DFA_Stretch` (u32) - how wide, in tenths of a percent; default
///     1000.
///   - `DFA_Italic` (bool) - an italic face; default false.
///   - `DFA_Axes` (`[*]const truetype.AxisValue`) and `DFA_AxisCount`
///     (u32) - values on a variable font's axes; default none.
///
/// RESULT:
/// The outline, for truetype.library's calls, given back with
/// `CloseOutlineFont`; null when the family has no outline, or its file
/// cannot be read or opened.
///
/// BEHAVIOR:
/// The faces looked at are the family's outline entries and those of
/// its faces' families, `name` with "-bold", "-italic" and
/// "-bolditalic" before its ".font". Each entry says how heavy and how
/// wide it is drawn (`NewFontContents`). Of them, as CSS chooses:
///
/// 1. the nearest width: the width asked, else for a width at or below
///    normal the nearest narrower one, then the nearest wider; for a
///    wider one the other way round;
/// 2. of those, an italic face for italic, a plain one for plain, the
///    other where there is none;
/// 3. of those, the nearest weight: for 400 to 500 the weight asked or
///    the nearest heavier up to 500, then the nearest lighter, then the
///    nearest heavier past 500; below 400 the nearest lighter, then the
///    nearest heavier; above 500 the nearest heavier, then the nearest
///    lighter.
///
/// A face that is a variable font is then opened where the asked
/// weight and width are on its `wght` and `wdth`, held to their
/// ranges, and then where `DFA_Axes` puts it - so a value it names wins
/// over the weight and the width, and the later of two for one axis
/// over the earlier. An axis the font has not is passed over.
///
/// The outline's `style` says it is bold when it is drawn at 600 or
/// heavier, and italic for an italic face or one leaned on its `slnt`
/// or `ital`; truetype.library's
/// `FontMetrics` says the weight and width it is drawn at. What was
/// asked and is not drawn a program draws itself, if it will.
///
/// CONTEXT:
/// - Waits: yes: for another task loading a font, and for the disk.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process, since it reads files.
///
/// OWNERSHIP:
/// The outline is the library's, shared by everyone who opened it at
/// that place; the caller holds it until `CloseOutlineFont`. `tags` and
/// what they point to are the caller's, read during the call only.
///
/// NOTES:
/// diskfont.library opens truetype.library for the first outline it
/// opens.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// OpenOutlineFont, CloseOutlineFont, FindFamily, GenericFamily,
/// truetype.library/FontMetrics
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]utility.TagItem{
///     .{ .tag = diskfont.DFA_Weight, .data = 600 },
///     .{ .tag = diskfont.DFA_Italic, .data = 1 },
///     .{ .tag = utility.TAG_DONE, .data = 0 },
/// };
/// const font = dfb.OpenOutlineFontTagList("sans.font", &tags) orelse return;
/// defer dfb.CloseOutlineFont(font);
/// ```
pub fn OpenOutlineFontTagList(dfb: *DiskfontBase, name: [*:0]const u8, tags: ?[*]const utility.TagItem) ?*diskfont.OutlineFont {
    const ub = dfb.utility_base;
    const asked = Asked{
        .weight = @intCast(@max(1, @min(1000, ub.GetTagData(diskfont.DFA_Weight, 400, tags)))),
        .stretch = @intCast(@max(1, @min(65535, ub.GetTagData(diskfont.DFA_Stretch, 1000, tags)))),
        .italic = ub.GetTagData(diskfont.DFA_Italic, 0, tags) != 0,
        .axes = @ptrFromInt(ub.GetTagData(diskfont.DFA_Axes, 0, tags)),
        .axis_count = @intCast(@min(256, ub.GetTagData(diskfont.DFA_AxisCount, 0, tags))),
    };
    const sys = dfb.sys_base;
    sys.ObtainSemaphore(&dfb.load_lock);
    defer sys.ReleaseSemaphore(&dfb.load_lock);
    return openNearest(dfb, name, &asked);
}

/// What the tags ask.
const Asked = struct {
    weight: u16,
    stretch: u16,
    italic: bool,
    axes: ?[*]const truetype.AxisValue,
    axis_count: u32,
};

/// The family and its faces' families: their contents files read, and
/// where each is.
const families = 1 + opendiskfont.faces.len;

/// The face nearest `asked` of the family `name` and its faces, opened
/// and moved to what was asked. The caller holds the load lock.
fn openNearest(dfb: *DiskfontBase, name: [*:0]const u8, asked: *const Asked) ?*diskfont.OutlineFont {
    var paths: [families][256:0]u8 = @splat(@splat(0));
    var contents: [families]_font.Contents = @splat(.{});
    defer for (&contents) |*one| one.free(dfb);
    opendiskfont.contentsPath(dfb, name, &paths[0]);
    contents[0] = _font.readContents(dfb, &paths[0]);
    for (opendiskfont.faces, 1..) |face, index| {
        var face_name: [256:0]u8 = @splat(0);
        if (!opendiskfont.faceName(name, face.suffix, &face_name)) continue;
        opendiskfont.contentsPath(dfb, &face_name, &paths[index]);
        contents[index] = _font.readContents(dfb, &paths[index]);
    }

    var best: ?*const fontfile.FontContents = null;
    var best_family: usize = 0;
    var best_rank: u64 = 0;
    for (&contents, 0..) |*family, index| {
        for (family.entries()) |*entry| {
            if (entry.outline == 0) continue;
            const rank = rankOf(asked, entry);
            if (best != null and rank >= best_rank) continue;
            best = entry;
            best_family = index;
            best_rank = rank;
        }
    }
    const entry = best orelse return null;
    const font = _outline.openEntry(dfb, &paths[best_family], &contents[best_family], entry) orelse return null;
    const moved = movedEntry(dfb, font.outline, entry, asked) orelse return font;
    // The file is read once: the record moved shares it.
    const at = _outline.openEntry(dfb, &paths[best_family], &contents[best_family], &moved) orelse return font;
    _outline.close(font);
    return at;
}

/// How far an entry is from what was asked, as CSS orders the faces:
/// the width's rank first, then the slant's, then the weight's; the
/// lowest is the nearest.
fn rankOf(asked: *const Asked, entry: *const fontfile.FontContents) u64 {
    const stretch: u64 = stretchRank(asked.stretch, fontfile.stretchOf(entry));
    const leans = entry.style & graphics.FSF_ITALIC != 0;
    const slant: u64 = if (leans == asked.italic) 0 else 1;
    const weight: u64 = weightRank(asked.weight, fontfile.weightOf(entry));
    return (stretch << 34) | (slant << 33) | weight;
}

/// A width's rank: for a width asked at or below normal, the narrower
/// ones first, nearest first, then the wider ones; above normal the
/// other way round.
fn stretchRank(asked: u16, have: u16) u32 {
    const narrower_first = asked <= 1000;
    if (have == asked) return 0;
    if ((have < asked) == narrower_first) return distance(asked, have);
    return 0x10000 + distance(asked, have);
}

/// A weight's rank, as CSS orders them for the weight asked.
fn weightRank(asked: u16, have: u16) u32 {
    if (asked >= 400 and asked <= 500) {
        if (have >= asked and have <= 500) return distance(asked, have);
        if (have < asked) return 0x1000 + distance(asked, have);
        return 0x2000 + distance(asked, have);
    }
    if (asked < 400) {
        if (have <= asked) return distance(asked, have);
        return 0x1000 + distance(asked, have);
    }
    if (have >= asked) return distance(asked, have);
    return 0x1000 + distance(asked, have);
}

fn distance(a: u16, b: u16) u32 {
    return if (a > b) a - b else b - a;
}

/// The entry `entry` moved on the axes of its font, `outline`, to the
/// weight and width asked and then to the values the caller names; null
/// for a font without axes, or one that is where it is asked already.
fn movedEntry(dfb: *DiskfontBase, outline: *truetype.Outline, entry: *const fontfile.FontContents, asked: *const Asked) ?fontfile.FontContents {
    const tb = _font.trueType(dfb) orelse return null;
    var axes: [16]truetype.Axis = undefined;
    const axis_count = tb.FontAxes(outline, &axes, axes.len);
    if (axis_count == 0 or axis_count > axes.len) return null;
    const own = axes[0..axis_count];
    var place = fontfile.placeOfEntry(entry);
    var weight = fontfile.weightOf(entry);
    var stretch = fontfile.stretchOf(entry);
    for (own) |*axis| {
        if (axis.tag == truetype.tableTag("wght")) _ = fontfile.move(&place, axis, @floatFromInt(asked.weight));
        if (axis.tag == truetype.tableTag("wdth")) _ = fontfile.move(&place, axis, @as(f32, @floatFromInt(asked.stretch)) / 10);
    }
    if (asked.axes) |values| {
        for (values[0..asked.axis_count]) |value| {
            for (own) |*axis| {
                if (axis.tag == value.tag) _ = fontfile.move(&place, axis, value.value);
            }
        }
    }
    // The weight and width it is drawn at now, and whether it leans, as
    // its axes say.
    var style = entry.style & ~graphics.FSF_BOLD;
    for (own) |*axis| {
        const value = valueAt(&place, axis);
        if (axis.tag == truetype.tableTag("wght")) weight = @intFromFloat(@max(1, @min(1000, @round(value))));
        if (axis.tag == truetype.tableTag("wdth")) stretch = @intFromFloat(@max(1, @min(65535, @round(value * 10))));
        if (axis.tag == truetype.tableTag("slnt") and value != 0) style |= graphics.FSF_ITALIC;
        if (axis.tag == truetype.tableTag("ital") and value >= 0.5) style |= graphics.FSF_ITALIC;
    }
    if (weight >= 600) style |= graphics.FSF_BOLD;
    const moved = fontfile.outlineEntry(fontfile.pathOf(entry), style, place, entry.face, weight, stretch);
    if (sameAxes(&moved, entry) and moved.style == entry.style) return null;
    return moved;
}

/// Where `place` is on `axis`: the value it names, or the default.
fn valueAt(place: *const fontfile.Place, axis: *const truetype.Axis) f32 {
    for (place.axes[0..place.count]) |one| {
        if (one.tag == axis.tag) return one.value;
    }
    return axis.default;
}

/// Whether two entries are at one place: the same axes at the same
/// values, in any order.
fn sameAxes(a: *const fontfile.FontContents, b: *const fontfile.FontContents) bool {
    if (a.axis_count != b.axis_count) return false;
    for (a.axes[0..a.axis_count]) |one| {
        const found = for (b.axes[0..b.axis_count]) |other| {
            if (other.tag == one.tag) break other.value == one.value;
        } else false;
        if (!found) return false;
    }
    return true;
}
