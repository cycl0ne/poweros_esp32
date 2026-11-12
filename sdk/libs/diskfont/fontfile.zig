// SPDX-License-Identifier: MIT
//! A font family's contents file: `FONTS:<family>.font`.
//!
//! It says which sizes of the family there are, where each one's file is,
//! and what each is - height, drawn style, flags, kind of pixels - so a
//! font can be chosen before any size is read. It is written by the tool
//! that converts fonts on the host and by `NewFontContents` on the
//! machine, and read by diskfont.library.
//!
//! **A file of outlines is an entry a style.** A TrueType or OpenType
//! file is listed with height 0, rendered at whatever height is asked.
//! A variable font - one file that is every weight between its
//! lightest and its boldest - is listed once for each style it can be
//! drawn in, every entry naming the same file and its own place on the
//! file's axes: up to `MAXFONTAXES` axes, each by its tag and a value.
//! `variableEntries` says which styles a file has and where they are.
//!
//! **A collection is a file of several fonts**, each a family of its
//! own. An outline entry says which font of its file it is (`face`), and
//! its path may lead into another family's directory: the families of
//! one collection each have a contents file, and the file is on the
//! disk once, with the first of them.
//!
//! A `ContentsHeader`, then `count` `FontContents`, little-endian and in
//! 32-bit alignment. The longwords of the whole file add up to zero, the
//! header's `checksum` making them, so a file that lost a byte is refused
//! rather than half believed.

const graphics = @import("../graphics/graphics.zig");
const truetype = @import("../truetype/truetype.zig");

/// The first four bytes of a contents file: "PFCT".
pub const MAGIC: u32 = 0x5443_4650;

/// The layout this file describes.
pub const VERSION: u16 = 2;

/// How long an entry's path can be, its NUL included.
pub const MAXFONTPATH = 64;

/// How many axes of a variable font an entry's place names. An axis
/// not named is at the file's default, so only the axes a style moves
/// count: the five every font means the same by - weight, width, slant,
/// italic, optical size - and three of a font's own.
pub const MAXFONTAXES = 8;

/// The start of the file.
pub const ContentsHeader = extern struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    /// How many entries follow.
    count: u16 = 0,
    /// What makes the longwords of the file add up to zero.
    checksum: u32 = 0,
};

/// One size of the family.
pub const FontContents = extern struct {
    /// The size's file, from `FONTS:`: "spleen/16". NUL-padded.
    path: [MAXFONTPATH]u8 = @splat(0),
    /// Rows tall.
    y_size: u16 = 0,
    /// The styles it was drawn with (`FSF_`).
    style: graphics.FontStyle = graphics.FS_NORMAL,
    /// `FPF_` flags: proportional, designed.
    flags: graphics.FontFlags = 0,
    /// Its pixels: a `fontimage.Kind`.
    kind: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The nominal width.
    x_size: u16 = 0,
    /// 1: `path` is a TrueType or OpenType file, rendered at whatever
    /// height is asked (truetype.library), and `y_size` is 0. 0: a size
    /// file.
    outline: u8 = 0,
    /// How many of `axes` say where on the file's axes this entry is. 0:
    /// every axis at the file's default, which is all a file without
    /// axes has.
    axis_count: u8 = 0,
    /// Which font of its file an outline entry is, from 0: a collection
    /// holds several, a TrueType file the one (truetype.library's
    /// `TTA_FontIndex`).
    face: u8 = 0,
    /// Nothing yet; zero.
    reserved: [3]u8 = @splat(0),
    /// The entry's place on a variable font's axes: the first
    /// `axis_count` name an axis by its tag and its value there, in the
    /// form truetype.library's `TTA_Axes` takes. The others are zero.
    axes: [MAXFONTAXES]truetype.AxisValue = @splat(.{ .tag = 0, .value = 0 }),
};

comptime {
    if (@sizeOf(ContentsHeader) != 12) @compileError("ContentsHeader is not 12 bytes");
    if (@sizeOf(FontContents) != 144) @compileError("FontContents is not 144 bytes");
}

/// How many bytes a contents file of `count` entries is.
///
/// INPUTS:
/// - `count` - how many sizes it lists.
pub fn contentsSize(count: u32) u32 {
    return @sizeOf(ContentsHeader) + count * @sizeOf(FontContents);
}

/// The entries of a contents file `sound` has passed.
///
/// INPUTS:
/// - `block` - the file, four-byte aligned.
pub fn entriesOf(block: [*]const u8) []const FontContents {
    const header: *const ContentsHeader = @ptrCast(@alignCast(block));
    const at: [*]const FontContents = @ptrCast(@alignCast(block + @sizeOf(ContentsHeader)));
    return at[0..header.count];
}

/// An entry's path, without the padding.
///
/// INPUTS:
/// - `entry` - the entry.
pub fn pathOf(entry: *const FontContents) []const u8 {
    var len: usize = 0;
    while (len < MAXFONTPATH and entry.path[len] != 0) len += 1;
    return entry.path[0..len];
}

/// Whether `size` bytes at `block` are a contents file: the magic and
/// version, as many bytes as the count says, every path ended within its
/// field, no place of more axes than an entry holds, and the longwords
/// adding up to zero.
///
/// INPUTS:
/// - `block` - the start of the file, four-byte aligned.
/// - `size` - how many bytes were read.
pub fn sound(block: [*]const u8, size: u32) bool {
    if (size < @sizeOf(ContentsHeader) or @intFromPtr(block) % 4 != 0) return false;
    const header: *const ContentsHeader = @ptrCast(@alignCast(block));
    if (header.magic != MAGIC or header.version != VERSION) return false;
    if (size != contentsSize(header.count)) return false;
    if (graphics.fontimage.sumOf(block, size) != 0) return false;
    for (entriesOf(block)) |*entry| {
        if (entry.path[MAXFONTPATH - 1] != 0 or entry.path[0] == 0) return false;
        if (entry.axis_count > MAXFONTAXES) return false;
    }
    return true;
}

/// Make the file's checksum right, once everything else is written.
///
/// INPUTS:
/// - `block` - the file, four-byte aligned.
/// - `size` - its size in bytes.
pub fn seal(block: [*]u8, size: u32) void {
    const header: *ContentsHeader = @ptrCast(@alignCast(block));
    header.checksum = 0;
    header.checksum = 0 -% graphics.fontimage.sumOf(block, size);
}

/// The entry of an outline font, whose font file is `path`.
///
/// INPUTS:
/// - `path` - the file, from `FONTS:`; at most `MAXFONTPATH - 1` bytes.
/// - `style` - the styles the file is drawn in at `place`: what every
///   size rendered from the entry is. For a file without axes, what the
///   font says of itself (`truetype.styleOfFont`).
/// - `place` - where on the file's axes; `.{}` for its default.
/// - `face` - which font of the file, from 0; 0 for a file of one font.
pub fn outlineEntry(path: []const u8, style: graphics.FontStyle, place: Place, face: u8) FontContents {
    var entry = FontContents{
        .style = style,
        .flags = graphics.FPF_DESIGNED,
        .kind = @intFromEnum(graphics.fontimage.Kind.alpha4),
        .outline = 1,
        .axis_count = place.count,
        .face = face,
    };
    for (place.axes[0..place.count], 0..) |axis, i| entry.axes[i] = axis;
    const len = @min(path.len, MAXFONTPATH - 1);
    for (path[0..len], 0..) |c, i| entry.path[i] = c;
    return entry;
}

/// The entry that describes the image `image`, whose file is `path`.
///
/// INPUTS:
/// - `path` - the size file, from `FONTS:`; at most `MAXFONTPATH - 1`
///   bytes.
/// - `image` - the size's image.
pub fn entryFor(path: []const u8, image: *const graphics.fontimage.FontImage) FontContents {
    var entry = FontContents{
        .y_size = image.height,
        .style = image.style,
        .flags = image.flags,
        .kind = @intFromEnum(image.kind),
        .x_size = image.x_size,
    };
    const len = @min(path.len, MAXFONTPATH - 1);
    for (path[0..len], 0..) |c, i| entry.path[i] = c;
    return entry;
}

// --- the styles of a variable font ----------------------------------------------

/// The styles a file of outlines is listed in: bold and italic.
pub const listed_styles = graphics.FSF_BOLD | graphics.FSF_ITALIC;

/// A place on a file's axes: the axes that are not at the file's
/// default, each by its tag and its value. What an entry holds.
pub const Place = struct {
    count: u8 = 0,
    axes: [MAXFONTAXES]truetype.AxisValue = @splat(.{ .tag = 0, .value = 0 }),

    /// The value of the axis `tag` put at `value`; false when the place
    /// names as many axes as it can and this is another.
    pub fn put(place: *Place, tag: u32, value: f32) bool {
        for (place.axes[0..place.count]) |*axis| {
            if (axis.tag != tag) continue;
            axis.value = value;
            return true;
        }
        if (place.count == MAXFONTAXES) return false;
        place.axes[place.count] = .{ .tag = tag, .value = value };
        place.count += 1;
        return true;
    }
};

/// The place an entry holds.
///
/// INPUTS:
/// - `entry` - the entry, of a file `sound` has passed.
pub fn placeOfEntry(entry: *const FontContents) Place {
    var place = Place{ .count = entry.axis_count };
    for (entry.axes[0..entry.axis_count], 0..) |axis, i| place.axes[i] = axis;
    return place;
}

/// The style a named instance of a variable font is, by its name:
/// "Regular" none, "Bold", "Italic", "Bold Italic". Letters of either
/// case, with or without the space. Null for any other name: "Light",
/// "Semibold Italic".
///
/// INPUTS:
/// - `name` - the instance's name, as `FontName` writes it.
pub fn styleOfName(name: []const u8) ?graphics.FontStyle {
    const Named = struct { text: []const u8, style: graphics.FontStyle };
    const names = [_]Named{
        .{ .text = "regular", .style = graphics.FS_NORMAL },
        .{ .text = "bold", .style = graphics.FSF_BOLD },
        .{ .text = "italic", .style = graphics.FSF_ITALIC },
        .{ .text = "bolditalic", .style = graphics.FSF_BOLD | graphics.FSF_ITALIC },
    };
    for (names) |one| {
        var at: usize = 0;
        const same = for (name) |c| {
            if (c == ' ') continue;
            if (at == one.text.len or (c | 0x20) != one.text[at]) break false;
            at += 1;
        } else at == one.text.len;
        if (same) return one.style;
    }
    return null;
}

/// The place of a named instance: its value on every axis where that is
/// not the axis' default, held to the axis' range.
///
/// INPUTS:
/// - `axes` - the file's axes, as `FontAxes` gives them.
/// - `values` - the instance's values, as `FontInstance` gives them.
///
/// RESULT:
/// The place; null when it is away from the default on more axes than
/// an entry holds.
pub fn placeOf(axes: []const truetype.Axis, values: []const truetype.AxisValue) ?Place {
    var place = Place{};
    for (values) |one| {
        const axis = axisOf(axes, one.tag) orelse continue;
        const value = held(axis, one.value);
        if (value == axis.default) continue;
        if (!place.put(axis.tag, value)) return null;
    }
    return place;
}

/// The entries of a variable font: one for each style the file can be
/// drawn in, all of them naming the file, each at its own place.
///
/// INPUTS:
/// - `path` - the file, from `FONTS:`.
/// - `style` - the styles the file says it is drawn in
///   (`truetype.styleOf`).
/// - `axes` - the file's axes, as `FontAxes` gives them; at least one.
/// - `named` - the places of the file's named instances whose names say
///   a style (`styleOfName`, `placeOf`), at the index that is the style's
///   bold and italic bits; null where the file names none.
/// - `into` - where the entries go.
///
/// RESULT:
/// How many entries were made: 1 to 4.
///
/// BEHAVIOR:
/// The styles are the file's own, then with bold, with italic, and with
/// both, each only where the file is not that already. A style is at
/// the place of the instance the file names for it. Where it names
/// none, the place is made from the axes by what they mean:
///
/// - the file's own style has `wght` at 400, held to the axis' range: a
///   file's default may be its lightest weight, which is not regular. A
///   file that says it is bold is left at its default;
/// - bold is the file's own style with `wght` at 700, held to the
///   range, and is left out when that is no bolder, or the file has no
///   `wght`;
/// - italic is the file's own style with `ital` at 1, or failing that
///   axis with `slnt` at the end of its range away from 0, and is left
///   out when the file has neither or the axis does not move;
/// - bold italic is bold, moved on every axis italic differs on from
///   the file's own style, and is left out when either is.
///
/// A style left out is drawn from another by graphics' soft styles, as
/// for any font.
pub fn variableEntries(path: []const u8, style: graphics.FontStyle, axes: []const truetype.Axis, named: *const [4]?Place, into: *[4]FontContents) u32 {
    const bold = graphics.FSF_BOLD;
    const italic = graphics.FSF_ITALIC;
    const own = style & listed_styles;
    // By what is added to the file's own style.
    var places: [4]?Place = @splat(null);
    const plain = named[own] orelse plainPlace(axes, own);
    places[0] = plain;
    if (own & bold == 0) places[bold] = named[own | bold] orelse boldPlace(axes, &plain);
    if (own & italic == 0) places[italic] = named[own | italic] orelse italicPlace(axes, &plain);
    if (own == 0) places[bold | italic] = named[bold | italic] orelse bothPlace(axes, &plain, places[bold], places[italic]);

    var count: u32 = 0;
    for (places, 0..) |place, add| {
        const at = place orelse continue;
        into[count] = outlineEntry(path, style | @as(graphics.FontStyle, @intCast(add)), at, 0);
        count += 1;
    }
    return count;
}

/// The place of the file's own style, by what the axes mean: `wght` at
/// 400, unless the file says it is bold.
fn plainPlace(axes: []const truetype.Axis, own: graphics.FontStyle) Place {
    var place = Place{};
    if (own & graphics.FSF_BOLD != 0) return place;
    const weight = axisOf(axes, truetype.tableTag("wght")) orelse return place;
    _ = move(&place, weight, 400);
    return place;
}

/// `plain` made bold by what the axes mean; null when they cannot.
fn boldPlace(axes: []const truetype.Axis, plain: *const Place) ?Place {
    const weight = axisOf(axes, truetype.tableTag("wght")) orelse return null;
    if (!(held(weight, 700) > valueAt(plain, weight))) return null;
    var place = plain.*;
    return if (move(&place, weight, 700)) place else null;
}

/// `plain` made italic by what the axes mean; null when they cannot.
fn italicPlace(axes: []const truetype.Axis, plain: *const Place) ?Place {
    var place = plain.*;
    if (axisOf(axes, truetype.tableTag("ital"))) |axis| {
        if (!(held(axis, 1) > valueAt(plain, axis))) return null;
        return if (move(&place, axis, 1)) place else null;
    }
    const slant = axisOf(axes, truetype.tableTag("slnt")) orelse return null;
    const end = if (slant.minimum < 0) slant.minimum else slant.maximum;
    if (end == 0 or end == valueAt(plain, slant)) return null;
    return if (move(&place, slant, end)) place else null;
}

/// Bold and italic at once: `bold`, moved on every axis `italic` is not
/// where `plain` is. Null when either is, or the place names more axes
/// than an entry holds.
fn bothPlace(axes: []const truetype.Axis, plain: *const Place, bold: ?Place, italic: ?Place) ?Place {
    var place = bold orelse return null;
    const leaned = italic orelse return null;
    for (axes) |*axis| {
        const value = valueAt(&leaned, axis);
        if (value == valueAt(plain, axis)) continue;
        if (!move(&place, axis, value)) return null;
    }
    return place;
}

/// Where `place` is on `axis`: the value it names, or the default.
fn valueAt(place: *const Place, axis: *const truetype.Axis) f32 {
    for (place.axes[0..place.count]) |one| {
        if (one.tag == axis.tag) return one.value;
    }
    return axis.default;
}

/// `place` moved to `value` on `axis`, held to its range: the axis
/// named, or no longer named when that is its default. False when the
/// place names as many axes as it can and this is another.
fn move(place: *Place, axis: *const truetype.Axis, value: f32) bool {
    const to = held(axis, value);
    if (to != axis.default) return place.put(axis.tag, to);
    for (place.axes[0..place.count], 0..) |one, index| {
        if (one.tag != axis.tag) continue;
        place.count -= 1;
        place.axes[index] = place.axes[place.count];
        place.axes[place.count] = .{ .tag = 0, .value = 0 };
        break;
    }
    return true;
}

/// The axis of the tag `tag`, if the file has one.
fn axisOf(axes: []const truetype.Axis, tag: u32) ?*const truetype.Axis {
    for (axes) |*axis| {
        if (axis.tag == tag) return axis;
    }
    return null;
}

/// `value` held to the axis' range; what is not a number is its default.
fn held(axis: *const truetype.Axis, value: f32) f32 {
    if (!(value == value)) return axis.default;
    if (value < axis.minimum) return axis.minimum;
    if (value > axis.maximum) return axis.maximum;
    return value;
}
