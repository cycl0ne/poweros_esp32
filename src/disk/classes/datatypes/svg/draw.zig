// SPDX-License-Identifier: MIT
//! An SVG document drawn through vector.library.
//!
//! The tree is walked in the order of the file, each element's style
//! worked out from its parent's: the presentation attributes first, then
//! the rules of the file's `style` elements that are for it (`css.zig`,
//! since 1.2), then the `style` attribute's declarations over them, the
//! inherited properties carried down and the others - `opacity`,
//! `display`, `filter`, `clip-path`, `mask` - not. A shape is built into the one path, filled and then
//! stroked through its matrix: the parents' transforms, the `viewBox`'s
//! and the size the picture is drawn at, so a stroke is made in the
//! shape's own units and comes out stretched where they are.
//!
//! **Opacity**: a group's, and a shape's that is both filled and stroked,
//! goes onto a layer of its own put down at it; a shape painted only one
//! way has it in its paint, which comes to the same. Since 1.7 a layer
//! is put down by its `mix-blend-mode` - vector.library's sixteen - and
//! `isolation: isolate` gives a group a layer of its own, so what is
//! blended in it is blended with its own content alone.
//!
//! **Paint**: a colour, `currentColor`, a gradient, a pattern, or - since
//! 1.7 - `context-fill` and `context-stroke`, the fill or the stroke of
//! the shape whose marker is drawn or of the nearest `use` drawing the
//! element. `paint-order` puts the stroke under the fill, and the
//! markers under both or between them. The root's `background-color`
//! is put under all it draws.
//!
//! **Gradients** are found by id, and an `href` chain followed for what
//! a gradient leaves out - its stops, its units, its transform, its
//! coordinates - as far as `max_hops`. Their units are the shape's box
//! (`objectBoundingBox`, the default) or the user's. A radial one's focus
//! outside its circle is moved onto it.
//!
//! **Patterns** (since 1.7): the tile is drawn aside, as many pixels as
//! it covers where it is painted, and repeated; what a pattern leaves
//! out comes along its `href`s, its content from the first that has
//! any.
//!
//! **Markers** (since 1.7): `marker-start`, `marker-mid` and
//! `marker-end` on a path, a line, a polyline and a polygon, each in its
//! `viewBox` at its `refX` and `refY`, turned by `orient` - an angle,
//! `auto` along the path, `auto-start-reverse` - scaled by the stroke's
//! width unless `markerUnits` says the user's, and clipped to its box
//! unless its `overflow` is visible; `max_marker_depth` deep.
//!
//! **Clips and masks** (since 1.2) are vector.library's. A `clipPath`
//! of one shape is that shape's clip (`PushClip`); one of more, or whose
//! shapes are clipped themselves, is drawn as a mask of their coverage,
//! each filled white by its `clip-rule` (`BeginMask`, `EndMask`); since
//! 1.7 a text in it clips through its glyphs. A
//! `mask` is drawn as a group is, inside its region, and its luminance -
//! or its coverage, for `mask-type: alpha` - is the mask. Either is in
//! the units of the element it is on, or its box (`clipPathUnits`,
//! `maskUnits`, `maskContentUnits`): the box of what it draws, not of
//! its strokes. A group under a mask is drawn on a layer of its own, so
//! it goes through it whole. A nested `svg`, and a `symbol`, clip what
//! they draw to their viewport unless `overflow` says otherwise. A clip
//! or a mask that is not there clips nothing; one with nothing in it
//! lets nothing through.
//!
//! **`use`** (since 1.2) draws the element it names as a group's one
//! child, moved by its `x` and `y`, its style carried in from the `use`;
//! a `symbol` it names is drawn as a nested `svg` the `use`'s width and
//! height. A `use` that names one of the elements it is drawn inside is
//! not drawn, and no more than `max_uses` are drawn in all.
//!
//! **Loops** (since 1.7, `loops.zig`): a clip, a mask, a pattern, a
//! filter or a marker that reaches itself again through what it draws
//! has the reference that closes the loop dropped, and the rest is
//! drawn.
//!
//! **Text** (since 1.3) is drawn in the disk's outline fonts
//! (`text.zig`): a `text` and its `tspan`s laid out from where `x`, `y`,
//! `dx`, `dy` and `rotate` put their characters, each glyph's outline
//! from truetype.library filled and stroked as a shape is, moved by
//! `letter-spacing` and `word-spacing`, and each piece that starts at a
//! place of its own - a chunk - moved by its `text-anchor`. The white
//! space is SVG's, `xml:space` and `white-space` both. A family without
//! a bold or an italic face is drawn thicker or leaned for it, and
//! `text-decoration` draws its lines from the font's measures, breaking
//! where a glyph is placed apart.
//!
//! Since 1.4 the font shapes the text (truetypeshaping.library's
//! `ShapeText`): its pairs are kerned, its ligatures joined, a mark is
//! put on its letter. What is shaped at once is a stretch - characters
//! one behind the other in one font, at one size, one language, one
//! `letter-spacing` and one direction, whatever spans they are in, up
//! to a chunk's end or `max_stretch` bytes. A glyph that stands for
//! several characters is drawn as the span of its first one. Letters
//! set apart by a `letter-spacing` are not joined into the ligatures a
//! font offers (`liga`, `clig`); the spacing goes behind a character
//! and its marks once, however many glyphs they have, and not between
//! the letters of a script whose letters join.
//!
//! Since 1.6 a text's language - `xml:lang` or `lang`, inherited - is
//! handed to the shaper as the tag fonts list the language under
//! (`truetypeshaping.languageOf`).
//!
//! Since 1.7:
//!
//!   - A character its span's font lacks is drawn in the first of the
//!     rest of its `font-family` list that has it, else in the first of
//!     the fallback families `ext` names that has it (`FallbackFamily`).
//!   - A glyph its font draws in colour is drawn so: the first of its
//!     colour layers (`GlyphPaints`, put down by vector.library's
//!     layers, clips and Porter and Duff's operators), the SVG document
//!     that draws it (`GlyphDocument`) and its picture (`GlyphPicture`,
//!     read by datatypes.library) that the font has; the text's fill is
//!     the colour the layers call the text's own. In a clip its outline
//!     alone counts.
//!   - A colour with an `icc-color` is taken through the ICC profile of
//!     the `color-profile` it names, read through `ext` (`OpenFile`) and
//!     converted by `icc.zig`; without one, the colour before it.
//!   - A span's font is the face of its family nearest its
//!     `font-weight`, `font-stretch` and `font-style`, as CSS chooses
//!     one (diskfont.library's `OpenOutlineFontTagList`): a family is
//!     found by its fonts' own name (`FindFamily`) and a generic one as
//!     font.prefs names it (`GenericFamily`, `text.zig`). A variable
//!     font is set on its axes to the weight and width asked, `slnt` to
//!     -12 for `oblique` and `ital` to 1 for `italic`, `opsz` to the
//!     font's size under `font-optical-sizing: auto`, and then to what
//!     `font-variation-settings` says, which wins. A bold asked of a
//!     face drawn lighter than 600 is drawn thicker - but for a font of
//!     a `wght` axis, which is drawn at the weight set on it - and a lean
//!     asked of one that does not lean is slanted.
//!   - `textPath` sets a chunk along a path - its own `path` or `d`, or
//!     the shape its `href` names - from its `startOffset`, each glyph's
//!     middle on the path and turned the way it goes there; one past
//!     either end is not drawn. `side="right"` walks the path backwards.
//!   - `tref` draws the characters of the element it names.
//!   - `textLength` spaces a span's glyphs out to it, or stretches them
//!     with `lengthAdjust="spacingAndGlyphs"`.
//!   - `dominant-baseline`, `alignment-baseline` and `baseline-shift`
//!     set a span on the baseline they name, by its font's measures.
//!   - `writing-mode` sets a text in columns: the ideographs, kana and
//!     the like upright, the rest turned with the line - or, by
//!     `text-orientation` or `glyph-orientation-vertical`, every glyph
//!     upright or every glyph turned (since 1.7).
//!   - `font-kerning`, `font-variant: small-caps` and `text-rendering:
//!     optimizeSpeed`, edges not smoothed.
//!   - A text of both directions is read as Unicode's bidirectional
//!     algorithm reads it (truetypeshaping.library's `BidiLevels`), each
//!     chunk a paragraph of the text's `direction` - in a column, `ltr`
//!     reads from the top down and `rtl` from the bottom up - and a
//!     span's `unicode-bidi` the embedding, override or isolate it says
//!     round its characters; a column's upright span is read from the
//!     top down whatever its characters, an override of its own. Each stretch of one level is shaped in its
//!     direction - Arabic's letters joined - and the clusters of a chunk
//!     put in the order they are drawn; its `dx` and `dy` still add up
//!     in the order the characters are read, and its `text-anchor`'s
//!     start is its right end - in a column its lower end - where its
//!     `direction` is `rtl`.
//!
//! A glyph's outline is read into the work block. Since 1.5 one of
//! more verbs or points than the block holds (`glyph_verbs`,
//! `glyph_points`) is read into room of its own: `ext` allocates it
//! for that glyph, as long as the outline says it has to be, and gets
//! it back once the glyph is in the path. Without the room the glyph
//! is left out and the rest of the text drawn.
//!
//! **Images** (since 1.3): an `image` whose `href` is a `data:` address
//! of a picture (`data.zig`) is drawn in its place as
//! `preserveAspectRatio` says, through vector.library's image paint,
//! read smoothly, or - `image-rendering` of pixels - at the pixel each
//! point falls in. Since 1.7 one of an SVG file is drawn as a document
//! of its own, `max_nesting` deep, and an `href` that names a file
//! (`address.zig`) is read from it: `ext` finds it from the place of the
//! picture's own file, and an address of a scheme that names no file,
//! `http:`, is not read. A document an `image` draws reads no file of
//! its own: a picture is the file it is, and its `data:` addresses.
//!
//! **Filters** (since 1.3, every primitive since 1.7; `filter.zig`): an
//! element with a `filter` is drawn on a layer of its own, its filters
//! run on it one after another by `FilterLayer`, and the result put
//! down inside the filter's region. Where the element's matrix turns or
//! slants it, or its region reaches past the canvas, the element is
//! drawn aside along its own axes first (`straighten`), so a filter
//! works along them and reads what lies past the canvas's edge. A
//! filter that comes to nothing draws nothing; one that cannot be read
//! leaves the element drawn without it.
//!
//! **Conditions** (since 1.7): an element with `requiredExtensions` -
//! none is had - or with a `systemLanguage` that names none of the
//! user's languages is not drawn; in a `switch` the first element whose
//! conditions hold is.
//!
//! **Not drawn** where they are, nor anything in them: `defs`, and the
//! elements drawn only where they are named - gradients, `symbol`,
//! `clipPath`, `mask`, `pattern`, `marker`, `style`, `filter` - and an
//! element of another namespace.
//!
//! Elements nested deeper than `max_depth` are not drawn, and clips and
//! masks inside one another deeper than `max_references` clip nothing.
//!
//! `vb` is anything with vector.library's calls by their names: the
//! library itself on the machine, its module straight on the host.
//! `ext` is what the picture reads besides: fonts by their families and
//! their glyphs, the pictures of `data:` addresses, and the memory for
//! a glyph the work block is too short for (`Without` has none of
//! them).

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
pub const document = @import("document.zig");
/// An `image`'s `data:` address read: for an `ext` to decode a picture.
pub const data = @import("data.zig");
/// An `image`'s address of a file: for an `ext` to find it.
pub const address = @import("address.zig");
pub const entity = @import("entity.zig");
const values = @import("values.zig");
const css = @import("css.zig");
const filter_ = @import("filter.zig");
const loops = @import("loops.zig");
const text_ = @import("text.zig");
const icc = @import("icc.zig");
const truetype = sdk.truetype;
const tts = sdk.truetypeshaping;
const utf8 = sdk.utility.utf8;
const graphics = sdk.graphics;
const Document = document.Document;
const Name = document.Name;
const Tag = document.Tag;
const none = document.none;
const Matrix = vector.Matrix;
const Colour = vector.Colour;
const Length = values.Length;

pub const max_depth = 48;
pub const max_stops = 64;
pub const max_dashes = 32;
pub const max_hops = 16;
/// Clips and masks being made inside one another: a mask's content
/// masked again, a clip's shapes clipped.
pub const max_references = 8;
/// The most `use` elements drawn in one picture, however they nest.
pub const max_uses = 16384;
/// Points of a `polyline` or a `polygon` handed over at a time.
const chunk = 128;
/// The most characters of one `text` laid out, and the most clusters and
/// glyphs they come to; the rest are not drawn.
pub const max_characters = 1024;
pub const max_glyphs = 1024;
/// The most pieces of a `text`'s characters - its text nodes - and the
/// most bytes they hold.
pub const max_pieces = 128;
pub const max_text_bytes = 4096;
/// The most bytes of a `text` shaped at once, and the most glyphs they
/// come back as: a longer stretch is shaped in parts - no pair kerned
/// across the border of two - and one of more glyphs is not drawn.
pub const max_stretch = 512;
/// A chunk's characters in UTF-8, and the marks of up to two
/// embeddings each span opens and closes.
pub const bidi_room = max_characters * 4 + max_runs * 12;
pub const max_shaped = 512;
/// The most spans of one `text` drawn - the text, its `tspan`s, `tref`s
/// and `textPath`s - and how deep they nest.
pub const max_runs = 64;
pub const max_span_depth = 8;
/// The most fonts one picture draws in, and the most families its
/// characters are looked for in that a font has no glyph for.
pub const max_faces = 16;
pub const max_fallbacks = 8;
/// The longest name of a fallback family.
pub const fallback_name = 31;
/// The verbs and points of one glyph's outline the work block holds; a
/// glyph of more is read into room of its own.
pub const glyph_verbs = 1024;
pub const glyph_points = 2048;
/// The most pictures the filters being run and the patterns being
/// painted hold at once (since 1.7).
pub const max_pictures = 16;
/// The most vertices a shape's markers are put at from the work block;
/// one of more has room of its own.
pub const max_vertices = 512;
/// The most markers being drawn inside one another.
const max_marker_depth = 4;
/// The most bytes of room asked for one glyph: what a 32-bit machine
/// can give in one piece.
const most_room = 0x7FFF_FFFF;
/// Room for a glyph the work block is too short for, as `ext.AllocRoom`
/// gives it and `ext.FreeRoom` takes it back.
pub const Room = []align(@alignOf(vector.Point)) u8;

/// A picture an `image` draws, as `ext.OpenImage` gives it: its pens,
/// 0xAARRGGBB and not premultiplied - or, for an SVG document, its text,
/// unpacked, which is drawn as shapes are - and whatever its giver
/// needs back to free it.
pub const Image = struct {
    pens: [*]const sdk.graphics.Pen = undefined,
    width: u32 = 0,
    height: u32 = 0,
    bytes_per_row: u32 = 0,
    /// An SVG document's text (since 1.7); its pens and size are none.
    document: ?[]u8 = null,
    handle: ?*anyopaque = null,
};

/// A file's bytes, read whole for the picture (since 1.7): an ICC
/// profile a `color-profile` names.
pub const Bytes = struct {
    bytes: []const u8 = &.{},
    handle: ?*anyopaque = null,
};

/// How deep SVG documents drawn as an `image` go inside one another.
const max_nesting = 4;

/// The blend mode each of a colour glyph's ways of putting a layer down
/// (`truetype.COMPOSE_*`) is.
const blend_of_compose = [_]u32{
    vector.BLEND_CLEAR,            vector.BLEND_COPY,         vector.BLEND_DESTINATION,      vector.BLEND_NORMAL,
    vector.BLEND_DESTINATION_OVER, vector.BLEND_SOURCE_IN,    vector.BLEND_DESTINATION_IN,   vector.BLEND_SOURCE_OUT,
    vector.BLEND_DESTINATION_OUT,  vector.BLEND_SOURCE_ATOP,  vector.BLEND_DESTINATION_ATOP, vector.BLEND_XOR,
    vector.BLEND_PLUS_LIGHTER,     vector.BLEND_SCREEN,       vector.BLEND_OVERLAY,          vector.BLEND_DARKEN,
    vector.BLEND_LIGHTEN,          vector.BLEND_COLOUR_DODGE, vector.BLEND_COLOUR_BURN,      vector.BLEND_HARD_LIGHT,
    vector.BLEND_SOFT_LIGHT,       vector.BLEND_DIFFERENCE,   vector.BLEND_EXCLUSION,        vector.BLEND_MULTIPLY,
    vector.BLEND_HUE,              vector.BLEND_SATURATION,   vector.BLEND_COLOUR,           vector.BLEND_LUMINOSITY,
};

comptime {
    if (blend_of_compose.len != truetype.COMPOSE_LUMINOSITY + 1) @compileError("a way of putting a layer down without its blend mode");
}

/// The paint of a colour glyph's step: its colour, or its gradient with
/// the stops that follow it put in `stops`; `foreground` for a colour
/// that is the text's.
fn brushOf(step: *const truetype.PaintStep, following: []const truetype.PaintStep, stops: [*]vector.Stop, foreground: vector.Colour) vector.Paint {
    if (step.brush == truetype.BRUSH_SOLID) return .{ .colour = stepColour(step, foreground) };
    for (following, 0..) |stop, nth| stops[nth] = .{ .offset = stop.offset, .colour = stepColour(&stop, foreground) };
    var paint = vector.Paint{
        .stops = stops,
        .stop_count = @intCast(following.len),
        .spread = switch (step.extend) {
            truetype.EXTEND_REPEAT => vector.SPREAD_REPEAT,
            truetype.EXTEND_REFLECT => vector.SPREAD_REFLECT,
            else => vector.SPREAD_PAD,
        },
    };
    switch (step.brush) {
        truetype.BRUSH_LINEAR => {
            paint.kind = vector.PAINT_LINEAR;
            paint.x1 = step.x0;
            paint.y1 = step.y0;
            paint.x2 = step.x1;
            paint.y2 = step.y1;
        },
        truetype.BRUSH_RADIAL => {
            paint.kind = vector.PAINT_RADIAL;
            paint.fx = step.x0;
            paint.fy = step.y0;
            paint.fr = step.r0;
            paint.cx = step.x1;
            paint.cy = step.y1;
            paint.r = step.r1;
        },
        else => {
            paint.kind = vector.PAINT_SWEEP;
            paint.cx = step.x0;
            paint.cy = step.y0;
            paint.start_angle = step.start_angle;
            paint.end_angle = step.end_angle;
        },
    }
    return paint;
}

fn stepColour(step: *const truetype.PaintStep, foreground: vector.Colour) vector.Colour {
    if (step.flags & truetype.STEPF_FOREGROUND != 0) return .{ .r = foreground.r, .g = foreground.g, .b = foreground.b, .a = foreground.a * step.alpha };
    return .{ .r = step.red, .g = step.green, .b = step.blue, .a = step.alpha };
}

/// Where two boxes overlap; null where they do not.
fn meet(box: vector.Rect, other: vector.Rect) ?vector.Rect {
    const left = @max(box.x, other.x);
    const top = @max(box.y, other.y);
    const right = @min(box.x + box.width, other.x + other.width);
    const bottom = @min(box.y + box.height, other.y + other.height);
    if (!(right > left) or !(bottom > top)) return null;
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

/// An `ext` of no fonts and no pictures: text and images are not drawn.
pub const Without = struct {
    pub fn OpenFace(_: *Without, _: [*:0]const u8, _: *const Want) ?*sdk.diskfont.OutlineFont {
        return null;
    }
    pub fn FindFamily(_: *Without, _: [*:0]const u8, _: [*]u8, _: u32) bool {
        return false;
    }
    pub fn GenericFamily(_: *Without, _: u32, _: [*]u8, _: u32) bool {
        return false;
    }
    pub fn FontAxes(_: *Without, _: *sdk.truetype.Outline, _: ?[*]sdk.truetype.Axis, _: u32) u32 {
        return 0;
    }
    pub fn CloseFace(_: *Without, _: *sdk.diskfont.OutlineFont) void {}
    pub fn FallbackFamily(_: *Without, _: u32, _: [*]u8, _: u32) bool {
        return false;
    }
    pub fn GlyphIndex(_: *Without, _: *sdk.truetype.Outline, _: u32) u32 {
        return 0;
    }
    pub fn UserLanguage(_: *Without, index: u32) ?[*:0]const u8 {
        return if (index == 0) "en" else null;
    }
    pub fn ShapeText(_: *Without, _: *sdk.truetype.Outline, _: []const u8, _: u32, _: u32, _: ?[*]const tts.Feature, _: *tts.ShapedRun) i32 {
        return tts.TTSERR_NOMEM;
    }
    pub fn BidiLevels(_: *Without, _: []const u8, _: u32, _: []u8) i32 {
        return tts.TTSERR_NOMEM;
    }
    pub fn GlyphMetrics(_: *Without, _: *sdk.truetype.Outline, _: u32, _: *sdk.truetype.GlyphMetrics) bool {
        return false;
    }
    pub fn GlyphVerticalMetrics(_: *Without, _: *sdk.truetype.Outline, _: u32, _: *sdk.truetype.VerticalMetrics) bool {
        return false;
    }
    pub fn GlyphSegments(_: *Without, _: *sdk.truetype.Outline, _: u32, _: *sdk.truetype.Segments) i32 {
        return sdk.truetype.TRUETYPEERR_GLYPH;
    }
    pub fn FontMetrics(_: *Without, _: *sdk.truetype.Outline, _: *sdk.truetype.FontMetrics) void {}
    pub fn GlyphPaints(_: *Without, _: *sdk.truetype.Outline, _: u32, _: ?[*]sdk.truetype.PaintStep, _: u32) u32 {
        return 0;
    }
    pub fn GlyphPicture(_: *Without, _: *sdk.truetype.Outline, _: u32, _: *sdk.truetype.Picture) bool {
        return false;
    }
    pub fn GlyphDocument(_: *Without, _: *sdk.truetype.Outline, _: u32, _: *sdk.truetype.Document) bool {
        return false;
    }
    pub fn OpenImage(_: *Without, _: []const u8) ?Image {
        return null;
    }
    pub fn OpenImageBytes(_: *Without, _: []const u8) ?Image {
        return null;
    }
    pub fn OpenFile(_: *Without, _: []const u8) ?Bytes {
        return null;
    }
    pub fn CloseFile(_: *Without, _: Bytes) void {}
    pub fn CloseImage(_: *Without, _: Image) void {}
    pub fn AllocRoom(_: *Without, _: usize) ?Room {
        return null;
    }
    pub fn FreeRoom(_: *Without, _: Room) void {}
};

/// What drawing needs besides the document, in one block of the
/// caller's: it is too much for a stack.
pub const Work = struct {
    frames: [max_depth]Frame = undefined,
    stops: [max_stops]vector.Stop = undefined,
    dashes: [max_dashes]f32 = undefined,
    points: [chunk]vector.Point = undefined,
    verbs: [chunk]u8 = undefined,
    /// The rules of the file's `style` elements, in the order they apply.
    rules: [css.max_rules]css.Rule = undefined,
    /// A `text` laid out (since 1.7): its spans, its pieces of characters
    /// and their bytes, its characters, and the clusters and glyphs they
    /// are shaped into.
    runs: [max_runs]Run = undefined,
    pieces: [max_pieces]text_.Piece = undefined,
    text_bytes: [max_text_bytes]u8 = undefined,
    characters: [max_characters]Character = undefined,
    clusters: [max_glyphs]Cluster = undefined,
    glyphs: [max_glyphs]Glyph = undefined,
    /// A stretch of a `text` being shaped: its characters in UTF-8, the
    /// character of each byte, and the glyphs they come back as.
    stretch: [max_stretch]u8 = undefined,
    stretch_characters: [max_stretch]u16 = undefined,
    shaped: [max_shaped]tts.ShapedGlyph = undefined,
    /// A chunk's characters as the bidirectional levels are found for
    /// them (since 1.7): in UTF-8 with the marks of its spans'
    /// embeddings, the place of each character's first byte there, the
    /// level of each byte, and of each character.
    bidi_text: [bidi_room]u8 = undefined,
    bidi_levels: [bidi_room]u8 = undefined,
    bidi_starts: [max_characters]u16 = undefined,
    levels: [max_characters]u8 = undefined,
    /// The fonts opened, closed when the picture is drawn.
    faces: [max_faces]Face = undefined,
    /// The families a character no font of its span has is looked for
    /// in, as `FallbackFamily` names them (since 1.7).
    fallbacks: [max_fallbacks][fallback_name:0]u8 = undefined,
    /// One glyph's outline, as truetype.library gives it and moved; one
    /// that does not fit has room of its own.
    glyph_verbs: [glyph_verbs]u8 = undefined,
    glyph_points: [glyph_points]vector.Point = undefined,
    /// A filter being made (since 1.7); one made inside another's
    /// `feImage` has room of its own.
    filter: filter_.Built = undefined,
    /// What `feImage`s and patterns drew, given back once used.
    pictures: [max_pictures]Room = undefined,
    /// A shape's vertices, for its markers.
    vertices: [max_vertices]vector.Vertex = undefined,
    /// The references that close loops, dropped (since 1.7, `loops.zig`).
    dropped: [loops.max_dropped]loops.Dropped = undefined,
};

/// A character of a `text` laid out: its span, the place its spans give
/// it - null where none does - how far its `dx` and `dy` move it and its
/// `rotate` turns it, in degrees, and whether it starts a chunk.
const Character = struct {
    code: u32,
    run: u8,
    /// The font its glyph is in: its span's, or a fallback family's.
    face: u8,
    x: ?f32,
    y: ?f32,
    dx: f32,
    dy: f32,
    rotate: f32,
    starts: bool,
};

/// A cluster of glyphs - a character and its marks, or the letters of a
/// ligature - laid out: its glyphs, the character it starts at and its
/// span, how far it moves the next and how wide its widest glyph is, in
/// the text's units.
const Cluster = struct {
    first: u32,
    count: u32 = 0,
    character: u32,
    run: u8,
    /// The font its glyphs are in, and its units' size in the text's.
    face: u8,
    scale: f32,
    advance: f32 = 0,
    width: f32 = 0,
    /// Its font's ascent and descent, y up.
    ascent: f32,
    descent: f32,
    /// What `textLength` spaced it out by, and stretched it by.
    spacing: f32 = 0,
    stretch: f32 = 1,
    /// What `dx` and `dy` move it by, all added up.
    shift_x: f32 = 0,
    shift_y: f32 = 0,
    /// In vertical text, how far it is moved down the line before the
    /// line is turned.
    lift: f32 = 0,
    /// Placed apart from the one before - moved, turned, on a path, a
    /// chunk's first at a place of its own: a line under it breaks there.
    apart: bool = false,
    /// Past the ends of its path: not drawn.
    hidden: bool = false,
    /// Its bidirectional level: odd for one read from right to left.
    level: u8 = 0,
    /// Its units into the text's; and what its glyphs are drawn through
    /// first, a glyph upright in vertical text turned.
    matrix: Matrix = .{},
    inner: Matrix = .{},
};

/// A glyph of a cluster: where it is drawn from the cluster's place, in
/// the text's units.
const Glyph = struct { glyph: u32, x: f32, y: f32 };

/// A span of a `text` - the text itself, a `tspan`, a `tref`, a
/// `textPath` - as its characters are laid out and its glyphs drawn.
const Run = struct {
    style: Style,
    node: u32 = none,
    /// The span it is in; itself for the text.
    parent: u8 = 0,
    /// How many of its characters - its own and its spans' - have been
    /// laid out: which of its `x`, `y`, `dx`, `dy` and `rotate` the next
    /// takes.
    chars: u32 = 0,
    /// Its characters are counted but not drawn: it is not displayed, or
    /// a `textPath` with no path.
    hidden: bool = false,
    /// Its `x`, `y`, `dx`, `dy` and `rotate`, as its characters take
    /// them; a `textPath`'s positions are not taken.
    lists: [5]List = .{ .{}, .{}, .{}, .{}, .{} },
    /// The `textPath` its characters follow; `none` for none.
    path: u32 = none,
    /// The text is set in columns.
    vertical: bool = false,
    /// Into the work's faces; `no_face` for none.
    face: u8,
    /// Font units into the text's.
    scale: f32 = 0,
    /// The lean an italic is drawn with, and the stroke a bold, where the
    /// font has no face of its own for them.
    lean: f32 = 0,
    thicken: f32 = 0,
    /// Its font's measures in the text's units, y up: ascent, descent,
    /// x height, the middle of an underline and of a line through, how
    /// thick a line is, and how far a subscript is set down and a
    /// superscript up.
    ascent: f32 = 0,
    descent: f32 = 0,
    x_height: f32 = 0,
    under: f32 = 0,
    strike: f32 = 0,
    thickness: f32 = 0,
    sub: f32 = 0,
    super: f32 = 0,
    /// `letter-spacing` and `word-spacing`, in the text's units.
    letter: f32 = 0,
    word: f32 = 0,
    /// How far its spans' `baseline-shift`s raise it, and how far down
    /// its glyphs are drawn from the line, its baselines with them.
    raised: f32 = 0,
    baseline: f32 = 0,
    /// The spans whose paint draws its lines under, through and over it;
    /// `no_run` for none.
    lines: [3]u8 = .{ no_run, no_run, no_run },
    /// Its `textLength`, null for none; `lengthAdjust` stretching its
    /// glyphs to it.
    length: ?f32 = null,
    stretch_glyphs: bool = false,
};

/// A span's list of positions or of turns, read as its characters take
/// them: its text - empty for none, or for one that does not read
/// whole - where value `index` starts in it, and its last value.
const List = struct {
    text: []const u8 = "",
    at: usize = 0,
    index: u32 = 0,
    last: ?Length = null,

    /// The list read: empty, with no last value, when any of it is not
    /// a length - or, `numbers`, not a number.
    fn of(text: ?[]const u8, numbers: bool) List {
        const given = text orelse return .{};
        var scanner = values.Scanner{ .text = given };
        var last: ?Length = null;
        while (true) {
            scanner.skipSeparator();
            if (scanner.at >= given.len) break;
            const one = (if (numbers) numberLength(&scanner) else values.lengthAt(&scanner)) orelse return .{};
            last = one;
        }
        return .{ .text = given, .last = last };
    }

    /// Value `index`, null past the end; `index` only grows from one
    /// call to the next.
    fn valueAt(list: *List, index: u32) ?Length {
        if (list.text.len == 0) return null;
        var scanner = values.Scanner{ .text = list.text, .at = list.at };
        while (list.index < index) {
            scanner.skipSeparator();
            _ = values.lengthAt(&scanner) orelse return null;
            list.index += 1;
            list.at = scanner.at;
        }
        scanner.skipSeparator();
        return values.lengthAt(&scanner);
    }
};

/// A number with no unit, as a length.
fn numberLength(scanner: *values.Scanner) ?Length {
    const number = scanner.number() orelse return null;
    if (scanner.unit().len != 0) return null;
    return .{ .value = number };
}

const list_x = 0;
const list_y = 1;
const list_dx = 2;
const list_dy = 3;
const list_rotate = 4;

const no_run: u8 = 0xFF;
const line_under = 0;
const line_through = 1;
const line_over = 2;

const no_face: u8 = 0xFF;

/// A font opened for the picture: its family's file, the styles asked,
/// and what it is.
const Face = struct {
    /// Its family, as diskfont.library names its contents file.
    family: [face_name:0]u8 = @splat(0),
    family_len: u8 = 0,
    want: Want,
    /// Null for one that could not be opened, remembered as such.
    opened: ?*sdk.diskfont.OutlineFont,
    metrics: sdk.truetype.FontMetrics,
    /// The font has an `opsz` axis, so it is opened again at each size
    /// asked of it under `font-optical-sizing: auto`; and a `wght` axis,
    /// so it is drawn at the weight set on it and never thicker.
    optical: bool = false,
    weighted: bool = false,

    fn familyName(face: *const Face) []const u8 {
        return face.family[0..face.family_len];
    }
};

/// The longest name of a family a face is opened from.
pub const face_name = 63;

/// What a span asks of its font (since 1.7): the face nearest its
/// weight, width and slant, and the values on a variable font's axes -
/// the slant's own, then `font-variation-settings`, which win - with
/// `opsz` at the font's size before them when `optical` is not 0. What
/// `ext.OpenFace` is handed.
pub const Want = struct {
    weight: u16 = 400,
    stretch: u16 = 1000,
    italic: bool = false,
    /// The font's size, for `opsz`; 0 for none.
    optical: f32 = 0,
    axes: [max_axes]sdk.truetype.AxisValue = undefined,
    axis_count: u8 = 0,

    pub fn same(a: *const Want, b: *const Want) bool {
        if (a.weight != b.weight or a.stretch != b.stretch or a.italic != b.italic or a.optical != b.optical or a.axis_count != b.axis_count) return false;
        for (a.axes[0..a.axis_count], b.axes[0..b.axis_count]) |one, other| {
            if (one.tag != other.tag or one.value != other.value) return false;
        }
        return true;
    }

    /// Its axes as diskfont.library takes them: `opsz` first, then the
    /// rest, into `into`; how many.
    pub fn axesInto(want: *const Want, into: *[max_axes + 1]sdk.truetype.AxisValue) u32 {
        var count: u32 = 0;
        if (want.optical != 0) {
            into[0] = .{ .tag = sdk.truetype.tableTag("opsz"), .value = want.optical };
            count = 1;
        }
        for (want.axes[0..want.axis_count]) |axis| {
            into[count] = axis;
            count += 1;
        }
        return count;
    }
};

/// The most values a span sets on a variable font's axes: its slant's,
/// and `font-variation-settings`' own.
pub const max_axes = 1 + text_.max_variations;

/// What a span of `style` asks of its font: its weight, width and
/// slant; `opsz` at its size under `font-optical-sizing: auto`; `slnt`
/// at -12 for `oblique` and `ital` at 1 for `italic`, as a variable
/// font is slanted for them; then `font-variation-settings`.
fn wantOf(style: *const Style) Want {
    var want = Want{ .weight = style.weight, .stretch = style.stretch, .italic = style.italic };
    if (style.optical) want.optical = style.font_size;
    if (style.oblique) {
        want.axes[0] = .{ .tag = sdk.truetype.tableTag("slnt"), .value = -12 };
        want.axis_count = 1;
    } else if (style.italic) {
        want.axes[0] = .{ .tag = sdk.truetype.tableTag("ital"), .value = 1 };
        want.axis_count = 1;
    }
    var set: [text_.max_variations]sdk.truetype.AxisValue = undefined;
    const count = text_.variationsOf(style.variations, &set);
    for (set[0..count]) |axis| {
        want.axes[want.axis_count] = axis;
        want.axis_count += 1;
    }
    return want;
}

/// A group being drawn: its element, its style, its matrix.
/// A shape whose markers are drawn: their context element. `base` is
/// the frame their content starts at.
const Marked = struct {
    style: *const Style,
    matrix: Matrix,
    node: u32,
    viewport: [2]f32,
    base: usize,
};

/// The element `context-fill` and `context-stroke` are of: its style,
/// its units into pixels, its node and the viewport it is in; the frame
/// it is found at and the markers open there.
const Context = struct {
    style: *const Style,
    matrix: Matrix,
    node: u32,
    viewport: [2]f32,
    depth: usize,
    level: u32,
};

/// What `beginAside` set up: pens of their own and a canvas on them, and
/// the canvas drawn on before.
/// The path drawn before, when the aside has one of its own.
const Aside = struct { room: Room, canvas: *vector.Canvas, saved: *vector.Canvas, saved_size: [2]u32, saved_path: ?*vector.Path, saved_box: ?vector.Rect };

/// An element drawn aside for its filters (`straighten`): the aside, its
/// size, and the canvas's pixels into its.
const Straight = struct { aside: Aside, into: Matrix, width: u32, height: u32 };

const Frame = struct {
    node: u32,
    style: Style,
    matrix: Matrix,
    /// The width and height percentages are of.
    viewport: [2]f32,
    /// A layer pushed for its opacity, to be put down when it ends.
    layered: bool = false,
    /// A `switch`, and whether it has drawn its one.
    choosing: bool = false,
    chosen: bool = false,
    /// A `use`: the element it names, its one child; `none` otherwise.
    use: u32 = none,
    /// Clips and masks pushed for it, to be popped when it ends.
    clips: u8 = 0,
    /// Its filters run on its layer before it is put down.
    filtered: bool = false,
    /// Its filters run aside, its matrix's turn and slant taken out.
    straight: ?Straight = null,
    /// Its own units into pixels, before its viewport's, and the
    /// viewport they are in: what its filters are made in.
    space: Matrix = .{},
    outer: [2]f32 = .{ 0, 0 },
};

const Style = struct {
    // Inherited.
    fill: values.Paint = .{ .colour = .{} },
    fill_opacity: f32 = 1,
    fill_rule: u32 = vector.RULE_NONZERO,
    stroke: values.Paint = .none,
    stroke_opacity: f32 = 1,
    stroke_width: Length = .{ .value = 1 },
    cap: u32 = vector.CAP_BUTT,
    join: u32 = vector.JOIN_MITER,
    miter_limit: f32 = 4,
    /// The dash lengths' text, empty for none.
    dashes: []const u8 = "",
    dash_offset: Length = .{ .value = 0 },
    colour: Colour = .{},
    visible: bool = true,
    clip_rule: u32 = vector.RULE_NONZERO,
    /// `paint-order` puts the stroke under the fill (SVG 2; since 1.3),
    /// and the markers - since 1.7 - under both, or between them.
    stroke_first: bool = false,
    markers_at: MarkersAt = .last,
    /// The markers, their `url(#...)`; empty for none (since 1.7).
    marker_start: []const u8 = "",
    marker_mid: []const u8 = "",
    marker_end: []const u8 = "",
    /// `shape-rendering: crispEdges` or `optimizeSpeed` - edges not
    /// smoothed, the faster way -, `image-rendering` of pixels, and
    /// `color-interpolation: linearRGB` (since 1.7).
    aliased: bool = false,
    /// `text-rendering: optimizeSpeed` (since 1.7): a text's edges not
    /// smoothed - `shape-rendering` is the shapes' alone.
    text_aliased: bool = false,
    nearest: bool = false,
    linear_gradients: bool = false,
    // Text's (since 1.3), inherited.
    font_family: []const u8 = "",
    font_size: f32 = 16,
    weight: u16 = 400,
    italic: bool = false,
    /// `font-style: oblique`, `italic` set with it; `font-stretch` in
    /// tenths of a percent; `font-variation-settings` as written; and
    /// `font-optical-sizing: auto` (since 1.7).
    oblique: bool = false,
    stretch: u16 = 1000,
    variations: []const u8 = "",
    optical: bool = true,
    anchor: Anchor = .start,
    letter_spacing: Length = .{ .value = 0 },
    word_spacing: Length = .{ .value = 0 },
    /// `decoration_*`: lines drawn with the text, those of the spans it
    /// is in with them.
    decoration: u8 = 0,
    /// `dominant-baseline`, `writing-mode` set in columns, `font-kerning`
    /// and `font-variant: small-caps` (since 1.7).
    dominant: Baseline = .auto,
    vertical: bool = false,
    /// `text-orientation`, or `glyph-orientation-vertical` (since 1.7).
    orientation: Orientation = .mixed,
    kerning: bool = true,
    small_caps: bool = false,
    /// White space kept as it is.
    preserve: bool = false,
    /// `direction: rtl` (since 1.7).
    rtl: bool = false,
    /// The language the text is in (`xml:lang`), as the tag fonts list
    /// it under; 0 for none said, or one no tag is known for.
    language: u32 = 0,
    // Not inherited.
    opacity: f32 = 1,
    shown: bool = true,
    /// The `filter`, its `url(#...)`; empty for none.
    filter: []const u8 = "",
    /// The `clip-path` and the `mask` it is drawn through, their
    /// `url(#...)`; empty for none.
    clip: []const u8 = "",
    mask: []const u8 = "",
    /// A `mask` by its coverage, not its luminance.
    mask_alpha: bool = false,
    /// What a viewport does with what is drawn outside it: null for what
    /// it does unless told, which for `svg` and `symbol` is to clip it.
    overflow_visible: ?bool = null,
    /// `mix-blend-mode` and `isolation` (since 1.7).
    blend: u32 = vector.BLEND_NORMAL,
    isolate: bool = false,
    /// The decoration lines the element says itself, `alignment-baseline`,
    /// `baseline-shift` and `unicode-bidi` (since 1.7).
    decoration_own: u8 = 0,
    alignment: Baseline = .auto,
    shift: Shift = .none,
    bidi: Bidi = .normal,

    /// What a child starts from.
    fn inherited(parent: *const Style) Style {
        var s = parent.*;
        s.opacity = 1;
        s.shown = true;
        s.filter = "";
        s.clip = "";
        s.mask = "";
        s.mask_alpha = false;
        s.overflow_visible = null;
        s.blend = vector.BLEND_NORMAL;
        s.isolate = false;
        s.decoration_own = 0;
        s.alignment = .auto;
        s.shift = .none;
        s.bidi = .normal;
        return s;
    }
};

const Anchor = enum { start, middle, end };

/// What `unicode-bidi` makes of a span (since 1.7): nothing, an
/// embedding, an isolate, an override, an isolate whose inside is
/// overridden, or an isolate of the direction of its first letter.
const Bidi = enum { normal, embed, isolate, override, isolate_override, plaintext };

/// How a column's glyphs stand (`text-orientation`): the ideographs,
/// kana and the like upright and the rest turned with the line, every
/// glyph upright, or every glyph turned.
const Orientation = enum { mixed, upright, sideways };

/// The baseline a span is set on: `auto` and `baseline` the alphabetic,
/// `before` and `after` the edges of its font's ascent and descent.
const Baseline = enum { auto, baseline, alphabetic, ideographic, hanging, mathematical, central, middle, before, after };

/// A `baseline-shift`: none, a font's sub- or superscript, or a length.
const Shift = union(enum) { none, sub, super, length: Length };

/// Where `paint-order` puts the markers among the fill and the stroke.
const MarkersAt = enum { first, between, last };

const decoration_under: u8 = 1;
const decoration_through: u8 = 2;
const decoration_over: u8 = 4;

/// The size an SVG file gives its picture, in pixels, and what takes its
/// units into them.
pub const Intrinsic = struct {
    width: f32,
    height: f32,
    /// The `viewBox` into the picture's width and height.
    view: Matrix,
    /// What the outermost element's percentages are of.
    viewport: [2]f32,
};

/// The root's `width` and `height`; what one leaves out comes from the
/// `viewBox`'s shape, and without one from CSS's 300 by 150. Its
/// `transform` (SVG 2; since 1.7) is applied after the `viewBox`, about
/// its `transform-origin` - by default the middle of its size.
pub fn intrinsic(doc: *const Document) Intrinsic {
    const box = viewBox(doc.get(0, .viewBox));
    var width = absolute(doc.get(0, .width));
    var height = absolute(doc.get(0, .height));
    if (box) |b| {
        if (width == null and height == null) {
            width = b.width;
            height = b.height;
        } else if (width == null) {
            width = height.? * b.width / b.height;
        } else if (height == null) {
            height = width.? * b.height / b.width;
        }
    }
    const w = width orelse 300;
    const h = height orelse 150;
    var view: Matrix = if (box) |given| viewBoxMatrix(given, doc.get(0, .preserveAspectRatio) orelse "", w, h) else .{};
    if (doc.get(0, .transform)) |text| {
        if (values.transform(text)) |m| {
            const origin = originOf(doc.get(0, .@"transform-origin") orelse "50% 50%", .{ w, h }) orelse [2]f32{ w / 2, h / 2 };
            view = Matrix.translate(origin[0], origin[1]).then(m).then(Matrix.translate(-origin[0], -origin[1])).then(view);
        }
    }
    return .{
        .width = w,
        .height = h,
        .view = view,
        .viewport = if (box) |b| .{ b.width, b.height } else .{ w, h },
    };
}

fn absolute(text: ?[]const u8) ?f32 {
    const l = values.length(text orelse return null) orelse return null;
    if (l.percent or !(l.value > 0)) return null;
    return l.value;
}

/// A `viewBox`: four numbers, its width and height more than 0.
fn viewBox(text: ?[]const u8) ?vector.Rect {
    var s = values.Scanner{ .text = text orelse return null };
    var v: [4]f32 = undefined;
    for (&v, 0..) |*n, i| {
        if (i > 0) s.skipSeparator();
        n.* = s.number() orelse return null;
    }
    if (!s.done() or !(v[2] > 0) or !(v[3] > 0)) return null;
    return .{ .x = v[0], .y = v[1], .width = v[2], .height = v[3] };
}

/// The `viewBox` fitted into `width` by `height` as `preserveAspectRatio`
/// says: stretched, or scaled the same both ways to fit inside (`meet`,
/// the default) or to cover (`slice`), and moved to one side, the middle
/// or the other.
fn viewBoxMatrix(box: vector.Rect, aspect: []const u8, width: f32, height: f32) Matrix {
    var s = values.Scanner{ .text = aspect };
    var align_word = s.word();
    if (values.eqlLower(align_word, "defer")) align_word = s.word();
    const slice = values.eqlLower(s.word(), "slice");
    var sx = width / box.width;
    var sy = height / box.height;
    if (align_word.len != 0 and values.eqlLower(align_word, "none")) {
        return Matrix.scale(sx, sy).then(Matrix.translate(-box.x, -box.y));
    }
    const scale = if (slice) @max(sx, sy) else @min(sx, sy);
    sx = scale;
    sy = scale;
    // xMinYMin ... xMaxYMax; anything else is xMidYMid.
    var ax: f32 = 0.5;
    var ay: f32 = 0.5;
    if (align_word.len == 8) {
        ax = position(align_word[1..4]) orelse 0.5;
        ay = position(align_word[5..8]) orelse 0.5;
    }
    const tx = (width - box.width * sx) * ax;
    const ty = (height - box.height * sy) * ay;
    return Matrix.translate(tx, ty).then(Matrix.scale(sx, sy)).then(Matrix.translate(-box.x, -box.y));
}

fn position(word: []const u8) ?f32 {
    if (std.mem.eql(u8, word, "Min")) return 0;
    if (std.mem.eql(u8, word, "Mid")) return 0.5;
    if (std.mem.eql(u8, word, "Max")) return 1;
    return null;
}

/// The largest a picture is drawn, either way, in pixels.
pub const max_side = 16384;

/// The size the file gives, in whole pixels, made smaller to fit in
/// `max_side` either way.
pub fn fullSize(size: Intrinsic) [2]u32 {
    return wantedSize(size, 0, 0);
}

/// The size a program wants (`PDTA_WantedWidth`, `PDTA_WantedHeight`; 0
/// for not given): the file's shape fitted inside both, or scaled to the
/// one given, or the file's own size without either - in whole pixels,
/// and made smaller to fit in `max_side` either way.
pub fn wantedSize(size: Intrinsic, wanted_width: u32, wanted_height: u32) [2]u32 {
    const ww: f32 = @floatFromInt(@min(wanted_width, max_side));
    const wh: f32 = @floatFromInt(@min(wanted_height, max_side));
    const by: f32 = if (wanted_width != 0 and wanted_height != 0)
        @min(ww / size.width, wh / size.height)
    else if (wanted_width != 0)
        ww / size.width
    else if (wanted_height != 0)
        wh / size.height
    else
        1;
    var w = size.width * by;
    var h = size.height * by;
    const side = @max(w, h);
    if (side > max_side) {
        w = w * max_side / side;
        h = h * max_side / side;
    }
    return .{ @max(1, @as(u32, @intFromFloat(@round(@min(w, max_side))))), @max(1, @as(u32, @intFromFloat(@round(@min(h, max_side))))) };
}

/// What the document is drawn through to come out `width` by `height`
/// pixels: the root's units into its size, and that stretched to them.
pub fn baseMatrix(size: Intrinsic, width: u32, height: u32) Matrix {
    const sx = @as(f32, @floatFromInt(width)) / size.width;
    const sy = @as(f32, @floatFromInt(height)) / size.height;
    return Matrix.scale(sx, sy).then(size.view);
}

/// The document drawn onto `canvas`, `path` the one every shape is built
/// in. `base` takes the root's units to pixels: the picture's size over
/// its intrinsic one, then `Intrinsic.view`.
pub fn draw(vb: anytype, ext: anytype, doc: *const Document, canvas: *vector.Canvas, size: [2]u32, path: *vector.Path, work: *Work, base: Matrix, viewport: [2]f32) void {
    var p = Painter(@TypeOf(vb), @TypeOf(ext)){ .vb = vb, .ext = ext, .doc = doc, .canvas = canvas, .size = size, .path = path, .work = work };
    p.walk(base, viewport);
    p.closeFaces();
    p.closeProfile();
}

fn Painter(comptime VB: type, comptime EXT: type) type {
    return struct {
        const P = @This();

        vb: VB,
        ext: EXT,
        doc: *const Document,
        canvas: *vector.Canvas,
        path: *vector.Path,
        work: *Work,
        /// How many of the work's rules there are.
        rule_count: u32 = 0,
        /// The frame drawn in now.
        depth: usize = 0,
        /// Clips and masks being made, one inside another.
        references: u32 = 0,
        /// `use` elements drawn so far.
        uses: u32 = 0,
        /// How many of the work's faces are open.
        face_count: u32 = 0,
        /// How many fallback families the work names; null until they
        /// are first asked for.
        fallback_count: ?u32 = null,
        /// The canvas's width and height in pixels: the one drawn on now.
        size: [2]u32,
        /// Filters being made only to see whether they come to anything:
        /// an `feImage` draws nothing for them.
        checking_filters: u32 = 0,
        /// The font size of the element whose lengths are being read:
        /// what an `em` of them is.
        em: f32 = 16,
        /// The box a paint of the box's units is of while a `text` is
        /// drawn: the whole text's, not the path's (since 1.7).
        paint_box: ?vector.Rect = null,
        /// Which laying out of a text the work holds.
        laid_serial: u32 = 0,
        /// How many documents drawn as an `image` this one is inside.
        nesting: u32 = 0,
        /// A `text` drawn into a `clipPath`'s coverage: its glyphs filled
        /// by this rule, whatever its paints (since 1.7).
        clipping: ?u32 = null,
        /// The ICC profile last read for an `icc-color`, and the
        /// `color-profile` that named it (since 1.7).
        profile: ?Bytes = null,
        profile_node: u32 = none,
        /// How many of the work's dropped references there are.
        dropped_count: u32 = 0,
        /// Filters being made one inside another, the first in the work.
        filter_depth: u32 = 0,
        /// How many of the work's pictures are held.
        picture_count: u32 = 0,
        /// Markers being drawn, one inside another, and the shape each is
        /// on: what their `context-fill` and `context-stroke` are of.
        markers: [max_marker_depth]u32 = undefined,
        marked: [max_marker_depth]Marked = undefined,
        marker_depth: u32 = 0,

        fn walk(p: *P, base: Matrix, viewport: [2]f32) void {
            p.readRules();
            p.findLoops();
            const frames = &p.work.frames;
            const root_default = Style{};
            const root_style = p.styleOf(0, &root_default);
            if (!root_style.shown or !p.conditionsHold(0)) return;
            // A width or a height of none disables the drawing.
            for ([_]Name{ .width, .height }) |name| {
                const given = values.length(p.doc.get(0, name) orelse continue) orelse continue;
                if (!(given.value > 0)) return;
            }
            const filtered = p.filterBy(&root_style, 0, base, viewport);
            if (filtered == .hidden) return;
            p.background(base, viewport);
            frames[0] = .{ .node = 0, .style = root_style, .matrix = base, .viewport = viewport };
            p.depth = 0;
            p.enter(&frames[0], base, viewport, null, filtered);
            p.drawFrom(0);
        }

        /// The references that close loops found, for `styleOf` to drop;
        /// none looked for in a document without resources, or without
        /// the room.
        fn findLoops(p: *P) void {
            const nodes = p.doc.nodes;
            for (nodes) |node| {
                switch (node.tag) {
                    .clipPath, .mask, .pattern, .filter, .marker => break,
                    else => {},
                }
            } else return;
            const room = p.ext.AllocRoom(nodes.len) orelse return;
            defer p.ext.FreeRoom(room);
            p.dropped_count = loops.find(p, room[0..nodes.len], &p.work.dropped);
        }

        /// What of `node`'s style a dropped reference names none: of
        /// its own, `styleOf`'s, the properties not inherited; with
        /// `paints` - a shape being drawn - its paints and markers too,
        /// which what is inside an element still inherits whole.
        fn dropLoops(p: *P, node: u32, style: *Style, paints: bool) void {
            for (p.work.dropped[0..p.dropped_count]) |dropped| {
                if (dropped.node != node) continue;
                switch (dropped.name) {
                    .@"clip-path" => style.clip = "",
                    .mask => style.mask = "",
                    .filter => style.filter = "",
                    .fill => if (paints) {
                        style.fill = .none;
                    },
                    .stroke => if (paints) {
                        style.stroke = .none;
                    },
                    .@"marker-start" => if (paints) {
                        style.marker_start = "";
                    },
                    .@"marker-mid" => if (paints) {
                        style.marker_mid = "";
                    },
                    .@"marker-end" => if (paints) {
                        style.marker_end = "";
                    },
                    else => {},
                }
            }
        }

        /// Whether `node`'s reference by `name` is dropped.
        pub fn isDropped(p: *P, node: u32, name: Name) bool {
            for (p.work.dropped[0..p.dropped_count]) |dropped| {
                if (dropped.node == node and dropped.name == name) return true;
            }
            return false;
        }

        /// A colour as `text` gives it: through the ICC profile its
        /// `icc-color` names, where a `color-profile` of the document
        /// names that and the colour comes through it, else the colour
        /// before it (since 1.7).
        pub fn colourOf(p: *P, text: []const u8) ?Colour {
            if (values.iccColour(text)) |given| {
                if (p.iccToSrgb(&given)) |made| return made;
            }
            return values.colour(text);
        }

        /// A paint as `text` gives it, its colour or its fallback colour
        /// through `colourOf`.
        fn paintIn(p: *P, text: []const u8) ?values.Paint {
            var paint = values.paint(text) orelse return null;
            const given = values.iccColour(text) orelse return paint;
            const made = p.iccToSrgb(&given) orelse return paint;
            switch (paint) {
                .colour => paint = .{ .colour = made },
                .url => |*url| if (url.fallback == .colour) {
                    url.fallback = .{ .colour = made };
                },
                else => {},
            }
            return paint;
        }

        /// An ICC colour in sRGB, through the profile of the
        /// `color-profile` named as it says - read through `ext`, and held
        /// until another is asked for or the drawing ends - at its
        /// `rendering-intent`. Null for no such profile, one that cannot
        /// be read, or a colour it does not take.
        fn iccToSrgb(p: *P, given: *const values.IccColour) ?Colour {
            const nodes = p.doc.nodes;
            var found: u32 = none;
            for (nodes, 0..) |node, at| {
                if (node.tag != .@"color-profile") continue;
                const name = p.doc.get(@intCast(at), .name) orelse continue;
                if (!std.mem.eql(u8, values.trim(name), given.name)) continue;
                found = @intCast(at);
                break;
            }
            if (found == none) return null;
            if (p.profile_node != found) {
                p.closeProfile();
                const href = p.doc.get(found, .href) orelse p.doc.get(found, .@"xlink:href") orelse return null;
                if (p.nesting != 0 and data.payloadOf(href) == null) return null;
                p.profile = p.ext.OpenFile(href) orelse return null;
                p.profile_node = found;
            }
            const intent_text = values.trim(p.doc.get(found, .@"rendering-intent") orelse "");
            const intent: u32 = if (std.mem.eql(u8, intent_text, "relative-colorimetric"))
                icc.INTENT_RELATIVE
            else if (std.mem.eql(u8, intent_text, "saturation"))
                icc.INTENT_SATURATION
            else if (std.mem.eql(u8, intent_text, "absolute-colorimetric"))
                icc.INTENT_ABSOLUTE
            else
                icc.INTENT_PERCEPTUAL;
            return icc.toSrgb(p.profile.?.bytes, intent, given.values[0..given.count]);
        }

        fn closeProfile(p: *P) void {
            if (p.profile) |held| p.ext.CloseFile(held);
            p.profile = null;
            p.profile_node = none;
        }

        /// The root's `background-color` (since 1.7) over its `viewBox`,
        /// under all it draws and none of its opacity or filters.
        fn background(p: *P, base: Matrix, viewport: [2]f32) void {
            var colour: ?vector.Colour = null;
            var cascaded = p.cascade(0);
            while (cascaded.next()) |one| {
                if (one.name == .@"background-color") colour = p.colourOf(one.value) orelse colour;
            }
            const paint = vector.Paint{ .colour = colour orelse return };
            const box = viewBox(p.doc.get(0, .viewBox)) orelse vector.Rect{ .width = viewport[0], .height = viewport[1] };
            p.vb.ClearPath(p.path);
            p.vb.AddRect(p.path, &box, 0, 0);
            _ = p.vb.FillPath(p.canvas, p.path, &base, &paint, vector.RULE_NONZERO);
        }

        /// Whether `node`'s conditions hold: it asks for no extension -
        /// none is had - and a `systemLanguage` names one of the user's
        /// languages, or one of its dialects (`en` is `en-US`'s).
        fn conditionsHold(p: *P, node: u32) bool {
            if (p.doc.get(node, .requiredExtensions) != null) return false;
            const list = p.doc.get(node, .systemLanguage) orelse return true;
            var tags = std.mem.tokenizeAny(u8, list, ",");
            while (tags.next()) |one| {
                const tag = values.trim(one);
                if (tag.len == 0) continue;
                var index: u32 = 0;
                while (p.ext.UserLanguage(index)) |code| : (index += 1) {
                    const own = std.mem.span(code);
                    if (own.len == 0 or own.len > tag.len) continue;
                    if (!values.eqlLower(tag[0..own.len], own)) continue;
                    if (own.len == tag.len or tag[own.len] == '-') return true;
                }
            }
            return false;
        }

        /// The children of the frame at `base` drawn, and it ended. A
        /// mask's content is drawn the same way, in the frames above the
        /// one it is for.
        fn drawFrom(p: *P, base: usize) void {
            const frames = &p.work.frames;
            var depth = base;
            p.depth = depth;
            // A frame of one element drawn on its own: that one alone.
            var child = if (frames[base].use != none) frames[base].use else p.doc.nodes[frames[base].node].first_child;
            while (true) {
                if (child == none) {
                    const ending = &frames[depth];
                    p.leave(ending);
                    if (depth == base) return;
                    depth -= 1;
                    p.depth = depth;
                    child = if (frames[depth].use != none) none else p.doc.nodes[ending.node].next;
                    continue;
                }
                const node = child;
                const top = &frames[depth];
                child = if (top.use != none) none else p.doc.nodes[node].next;
                const tag = p.doc.nodes[node].tag;
                if (!p.conditionsHold(node)) continue;
                if (top.choosing) {
                    if (top.chosen or !drawable(tag)) continue;
                    top.chosen = true;
                }
                switch (tag) {
                    .g, .a, .@"switch", .svg, .symbol, .use => {
                        if (depth + 1 == max_depth) continue;
                        // A symbol only as what a `use` names.
                        if (tag == .symbol and top.use != node) continue;
                        var target: u32 = none;
                        if (tag == .use) {
                            if (p.uses >= max_uses) continue;
                            target = p.useTarget(node, depth) orelse continue;
                        }
                        const style = p.styleOf(node, &top.style);
                        if (!style.shown) continue;
                        p.em = style.font_size;
                        const space = top.matrix.then(p.ownTransform(node, top.viewport));
                        var matrix = space;
                        var inner = top.viewport;
                        var overflow: ?vector.Rect = null;
                        if (tag == .svg or tag == .symbol) {
                            const sized_by = if (top.use == node) top.node else none;
                            const view = p.viewportOf(node, sized_by, top.viewport) orelse continue;
                            matrix = view.matrix(space);
                            inner = view.inner;
                            if (!(style.overflow_visible orelse false)) overflow = view.rect;
                        }
                        const filtered = p.filterBy(&style, node, space, top.viewport);
                        if (filtered == .hidden) continue;
                        if (tag == .use) p.uses += 1;
                        depth += 1;
                        p.depth = depth;
                        frames[depth] = .{ .node = node, .style = style, .matrix = matrix, .viewport = inner, .choosing = tag == .@"switch", .use = target };
                        p.enter(&frames[depth], space, top.viewport, overflow, filtered);
                        child = if (target != none) target else p.doc.nodes[node].first_child;
                    },
                    .path, .rect, .circle, .ellipse, .line, .polyline, .polygon => p.shape(node, top),
                    .text => p.drawText(node, top),
                    .image => p.drawImage(node, top),
                    else => {},
                }
            }
        }

        /// What a group needs before its children: its clip and its mask,
        /// in `space` - its own units into pixels - its viewport's clip,
        /// and a layer for its opacity, its blend mode and its filters.
        /// The clips go onto what is under the layer, so they cut what the
        /// filters made of it. One under a mask always has a layer, so it
        /// goes through it whole, and so does one filtered, blended or
        /// isolated.
        fn enter(p: *P, frame: *Frame, space: Matrix, viewport: [2]f32, overflow: ?vector.Rect, filtered: Filtered) void {
            const style = &frame.style;
            frame.space = space;
            frame.outer = viewport;
            if (style.clip.len != 0) frame.clips += p.clipBy(style.clip, frame.node, space, viewport);
            var masked = false;
            if (style.mask.len != 0) {
                const owed = p.maskBy(style.mask, frame.node, space, viewport);
                frame.clips += owed;
                masked = owed != 0;
            }
            if (overflow) |rect| {
                p.vb.ClearPath(p.path);
                p.vb.AddRect(p.path, &rect, 0, 0);
                _ = p.vb.PushClip(p.canvas, p.path, &space, vector.RULE_NONZERO);
                frame.clips += 1;
            }
            frame.filtered = filtered == .run;
            // One the canvas had no room for is still pushed, its opacity
            // going into every paint, and is put down the same.
            frame.layered = masked or style.opacity < 1 or frame.filtered or style.blend != vector.BLEND_NORMAL or style.isolate;
            if (frame.layered) p.pushLayer(style);
            if (frame.filtered) {
                frame.straight = p.straighten(frame.node, style, space, viewport);
                if (frame.straight) |aside| frame.matrix = aside.into.then(frame.matrix);
            }
        }

        fn leave(p: *P, frame: *const Frame) void {
            if (frame.layered) {
                if (frame.straight) |aside| {
                    p.putStraight(aside, frame.node, frame.space, &frame.style, frame.outer);
                } else if (frame.filtered) p.runFilters(frame.node, frame.space, &frame.style, frame.outer);
                p.vb.PopLayer(p.canvas);
            }
            for (0..frame.clips) |_| p.vb.PopClip(p.canvas);
        }

        /// A layer for an element's opacity and its blend mode.
        fn pushLayer(p: *P, style: *const Style) void {
            if (style.blend != vector.BLEND_NORMAL) {
                _ = p.vb.PushBlendLayer(p.canvas, style.opacity, style.blend);
            } else _ = p.vb.PushLayer(p.canvas, style.opacity);
        }

        // --- drawing aside ----------------------------------------------------------

        /// Pens of their own, `width` by `height` and clear, and a canvas
        /// on them made the one drawn on - and, `own_path`, a path of its
        /// own, the one in use kept for after; null when there is no room
        /// for them, or the drawing is nested too deep. Put back with
        /// `endAside`.
        fn beginAside(p: *P, width: u32, height: u32, own_path: bool) ?Aside {
            if (width == 0 or height == 0 or width > max_side or height > max_side) return null;
            if (p.references >= max_references or p.depth + 2 >= max_depth) return null;
            const bytes = @as(usize, width) * height * @sizeOf(graphics.Pen);
            const room = p.ext.AllocRoom(bytes) orelse return null;
            @memset(room, 0);
            const tags = [_]sdk.utility.TagItem{
                .{ .tag = vector.VCA_Width, .data = width },
                .{ .tag = vector.VCA_Height, .data = height },
                .{ .tag = vector.VCA_Pens, .data = @intFromPtr(room.ptr) },
                .{ .tag = vector.VCA_BytesPerRow, .data = width * @sizeOf(graphics.Pen) },
                .{},
            };
            const canvas = p.vb.CreateCanvasTagList(&tags) orelse {
                p.ext.FreeRoom(room);
                return null;
            };
            const saved_path = if (own_path) p.ownPath() orelse {
                p.vb.DisposeCanvas(canvas);
                p.ext.FreeRoom(room);
                return null;
            } else null;
            const aside = Aside{ .room = room, .canvas = canvas, .saved = p.canvas, .saved_size = p.size, .saved_path = saved_path, .saved_box = p.paint_box };
            p.paint_box = null;
            p.canvas = canvas;
            p.size = .{ width, height };
            p.references += 1;
            return aside;
        }

        /// The canvas drawn on before `beginAside` back; the pens drawn
        /// aside the caller's, to give back with `ext.FreeRoom`.
        fn endAside(p: *P, aside: Aside) Room {
            p.references -= 1;
            p.canvas = aside.saved;
            p.size = aside.saved_size;
            p.vb.DisposeCanvas(aside.canvas);
            if (aside.saved_path) |saved| p.pathBack(saved);
            p.paint_box = aside.saved_box;
            return aside.room;
        }

        /// A path of its own for what is drawn while the one in use - a
        /// shape's, a text's glyphs - is still to be painted; the path it
        /// was, for `pathBack`. Null without the memory.
        fn ownPath(p: *P) ?*vector.Path {
            const path = p.vb.CreatePath() orelse return null;
            const saved = p.path;
            p.path = path;
            return saved;
        }

        fn pathBack(p: *P, saved: *vector.Path) void {
            p.vb.DisposePath(p.path);
            p.path = saved;
        }

        /// The children of `holder` drawn through `matrix`, as a group's
        /// are, styled from where `holder` is - or, `alone` not `none`,
        /// that one element of them.
        fn drawChildren(p: *P, holder: u32, alone: u32, matrix: Matrix, viewport: [2]f32) void {
            const saved = p.depth;
            const frames = &p.work.frames;
            frames[saved + 1] = .{ .node = holder, .style = p.styleChain(holder), .matrix = matrix, .viewport = viewport, .use = alone };
            p.drawFrom(saved + 1);
            p.depth = saved;
        }

        /// A picture held until `freePictures` gives back those held after
        /// a mark; false, and the room given back now, when no more can be
        /// held.
        fn holdPicture(p: *P, room: Room) bool {
            if (p.picture_count >= max_pictures) {
                p.ext.FreeRoom(room);
                return false;
            }
            p.work.pictures[p.picture_count] = room;
            p.picture_count += 1;
            return true;
        }

        fn freePictures(p: *P, mark: u32) void {
            while (p.picture_count > mark) {
                p.picture_count -= 1;
                p.ext.FreeRoom(p.work.pictures[p.picture_count]);
            }
        }

        /// The element a `use` names, unless it is one it is drawn inside.
        fn useTarget(p: *P, node: u32, depth: usize) ?u32 {
            const target = p.doc.byHref(p.doc.get(node, .href) orelse return null) orelse return null;
            var up = node;
            while (up != none) : (up = p.doc.nodes[up].parent) if (up == target) return null;
            for (p.work.frames[0 .. depth + 1]) |frame| {
                if (frame.node == target or frame.use == target) return null;
            }
            return target;
        }

        /// What an element's own units are in its parent's: its
        /// `transform`, and a `use`'s `x` and `y` after it.
        fn ownTransform(p: *P, node: u32, viewport: [2]f32) Matrix {
            // A symbol is placed by the `use` that names it, and its
            // own `x` and `y`: it has no transform.
            if (p.doc.nodes[node].tag == .symbol) return .{};
            const m = p.transformOf(node, .transform, viewport);
            if (p.doc.nodes[node].tag != .use) return m;
            return m.then(Matrix.translate(p.lengthOf(node, .x, .x, viewport, 0), p.lengthOf(node, .y, .y, viewport, 0)));
        }

        const View = struct {
            /// The viewport in its element's units.
            rect: vector.Rect,
            /// Its `viewBox` into it, or null for none.
            box: ?Matrix,
            /// What percentages are of inside it.
            inner: [2]f32,

            fn matrix(view: View, space: Matrix) Matrix {
                const at = space.then(Matrix.translate(view.rect.x, view.rect.y));
                return if (view.box) |box| at.then(box) else at;
            }
        };

        /// A nested `svg`'s or a `symbol`'s viewport: its place, its size -
        /// the `use`'s that names it when one does, `sized_by`, else its
        /// own, 100% unless given - and its `viewBox` into that. Null for
        /// one of no size, which is not drawn.
        fn viewportOf(p: *P, node: u32, sized_by: u32, outer: [2]f32) ?View {
            const full = Length{ .value = 100, .percent = true };
            const sizer = if (sized_by != none and p.doc.get(sized_by, .width) != null) sized_by else node;
            const w = (if (p.doc.get(sizer, .width)) |t| values.length(t) else null) orelse full;
            const sizer_h = if (sized_by != none and p.doc.get(sized_by, .height) != null) sized_by else node;
            const h = (if (p.doc.get(sizer_h, .height)) |t| values.length(t) else null) orelse full;
            const width = w.resolveAt(.x, outer, p.em);
            const height = h.resolveAt(.y, outer, p.em);
            if (!(width > 0) or !(height > 0)) return null;
            var view = View{
                .rect = .{
                    .x = p.lengthOf(node, .x, .x, outer, 0),
                    .y = p.lengthOf(node, .y, .y, outer, 0),
                    .width = width,
                    .height = height,
                },
                .box = null,
                .inner = .{ width, height },
            };
            if (viewBox(p.doc.get(node, .viewBox))) |box| {
                view.box = viewBoxMatrix(box, p.doc.get(node, .preserveAspectRatio) orelse "", width, height);
                view.inner = .{ box.width, box.height };
            }
            return view;
        }

        /// What an element is drawn through, pushed: its clip and its
        /// mask, in `space`; whether it has filters to run, and whether it
        /// is to be drawn at all.
        const Through = struct {
            clips: u8 = 0,
            masked: bool = false,
            filtered: bool = false,
            hidden: bool = false,
        };

        fn through(p: *P, node: u32, style: *const Style, space: Matrix, viewport: [2]f32) Through {
            var t = Through{};
            switch (p.filterBy(style, node, space, viewport)) {
                .none => {},
                .hidden => {
                    t.hidden = true;
                    return t;
                },
                .run => t.filtered = true,
            }
            if (style.clip.len != 0) t.clips += p.clipBy(style.clip, node, space, viewport);
            if (style.mask.len != 0) {
                const owed = p.maskBy(style.mask, node, space, viewport);
                t.clips += owed;
                t.masked = owed != 0;
            }
            return t;
        }

        /// Whether an element drawn more than one way at once - a shape
        /// filled and stroked, a text's glyphs - goes onto a layer of its
        /// own; one drawn one way has its opacity in its paint.
        fn layerFor(drawn_through: *const Through, style: *const Style, overlapping: bool) bool {
            if (drawn_through.filtered or style.blend != vector.BLEND_NORMAL or style.isolate) return true;
            return overlapping and (style.opacity < 1 or drawn_through.masked);
        }

        fn shape(p: *P, node: u32, top: *const Frame) void {
            var style = p.styleOf(node, &top.style);
            if (!style.shown) return;
            if (p.dropped_count != 0) p.dropLoops(node, &style, true);
            p.em = style.font_size;
            const vb = p.vb;
            const viewport = top.viewport;
            const matrix = top.matrix.then(p.ownTransform(node, viewport));
            const t = p.through(node, &style, matrix, viewport);
            defer for (0..t.clips) |_| vb.PopClip(p.canvas);
            if (t.hidden) return;
            if (!p.buildShape(node, viewport)) return;
            const filled = p.doc.nodes[node].tag != .line and style.fill != .none;
            const stroked = style.stroke != .none and style.stroke_width.resolveAt(.other, viewport, style.font_size) > 0;
            if (!style.visible) return;
            const marked = p.hasMarkers(node, &style);
            // More than one way at once, the opacity - and a mask - on a
            // layer over them all; one way, in the paint.
            const ways = @as(u32, @intFromBool(filled)) + @intFromBool(stroked) + @intFromBool(marked);
            const layered = layerFor(&t, &style, ways > 1);
            const paint_opacity: f32 = if (layered) 1 else style.opacity;
            if (layered) p.pushLayer(&style);
            const straight = if (t.filtered) p.straighten(node, &style, matrix, viewport) else null;
            const drawn = if (straight) |aside| aside.into.then(matrix) else matrix;
            // The first of fill and stroke, the markers between them
            // where they are, the second.
            if (marked and style.markers_at == .first) p.drawMarkers(node, &style, drawn, viewport);
            if (style.stroke_first) {
                if (stroked) p.strokeShape(&style, &drawn, paint_opacity, viewport);
            } else if (filled) p.fillShape(&style, &drawn, paint_opacity, viewport);
            if (marked and style.markers_at == .between) p.drawMarkers(node, &style, drawn, viewport);
            if (style.stroke_first) {
                if (filled) p.fillShape(&style, &drawn, paint_opacity, viewport);
            } else if (stroked) p.strokeShape(&style, &drawn, paint_opacity, viewport);
            if (marked and style.markers_at == .last) p.drawMarkers(node, &style, drawn, viewport);
            if (layered) {
                if (straight) |aside| {
                    p.putStraight(aside, node, matrix, &style, viewport);
                } else if (t.filtered) p.runFilters(node, matrix, &style, viewport);
                vb.PopLayer(p.canvas);
            }
        }

        /// The path filled as `style` says.
        fn fillShape(p: *P, style: *const Style, matrix: *const Matrix, opacity: f32, viewport: [2]f32) void {
            const mark = p.picture_count;
            defer p.freePictures(mark);
            const paint = p.paintOf(style.fill, style.fill_opacity * opacity, style, matrix, viewport) orelse return;
            _ = p.vb.FillPath(p.canvas, p.path, matrix, &paint, style.fill_rule);
        }

        /// The path stroked as `style` says.
        fn strokeShape(p: *P, style: *const Style, matrix: *const Matrix, opacity: f32, viewport: [2]f32) void {
            const mark = p.picture_count;
            defer p.freePictures(mark);
            if (p.paintOf(style.stroke, style.stroke_opacity * opacity, style, matrix, viewport)) |paint| {
                const stroke = p.strokeOf(style, viewport);
                _ = p.vb.StrokePath(p.canvas, p.path, matrix, &paint, &stroke);
            }
        }

        /// A shape element's outline built into the path, in its own
        /// units; false for one that has none.
        fn buildShape(p: *P, node: u32, viewport: [2]f32) bool {
            const vb = p.vb;
            const path = p.path;
            vb.ClearPath(path);
            switch (p.doc.nodes[node].tag) {
                .path => {
                    const d = p.doc.get(node, .d) orelse return false;
                    _ = vb.AddPathData(path, d.ptr, @intCast(d.len));
                },
                .rect => {
                    const w = p.lengthOf(node, .width, .x, viewport, 0);
                    const h = p.lengthOf(node, .height, .y, viewport, 0);
                    if (!(w > 0) or !(h > 0)) return false;
                    var rx = p.optionalLength(node, .rx, .x, viewport);
                    var ry = p.optionalLength(node, .ry, .y, viewport);
                    if (rx == null) rx = ry;
                    if (ry == null) ry = rx;
                    const rect = vector.Rect{ .x = p.lengthOf(node, .x, .x, viewport, 0), .y = p.lengthOf(node, .y, .y, viewport, 0), .width = w, .height = h };
                    vb.AddRect(path, &rect, rx orelse 0, ry orelse 0);
                },
                .circle => {
                    const r = p.lengthOf(node, .r, .other, viewport, 0);
                    vb.AddEllipse(path, p.lengthOf(node, .cx, .x, viewport, 0), p.lengthOf(node, .cy, .y, viewport, 0), r, r);
                },
                .ellipse => {
                    var rx = p.optionalLength(node, .rx, .x, viewport);
                    var ry = p.optionalLength(node, .ry, .y, viewport);
                    if (rx == null) rx = ry;
                    if (ry == null) ry = rx;
                    vb.AddEllipse(path, p.lengthOf(node, .cx, .x, viewport, 0), p.lengthOf(node, .cy, .y, viewport, 0), rx orelse 0, ry orelse 0);
                },
                .line => {
                    vb.MoveTo(path, p.lengthOf(node, .x1, .x, viewport, 0), p.lengthOf(node, .y1, .y, viewport, 0));
                    vb.LineTo(path, p.lengthOf(node, .x2, .x, viewport, 0), p.lengthOf(node, .y2, .y, viewport, 0));
                },
                .polyline, .polygon => {
                    if (!p.points(node)) return false;
                    if (p.doc.nodes[node].tag == .polygon) vb.ClosePath(path);
                },
                else => return false,
            }
            return true;
        }

        // --- markers -----------------------------------------------------------------

        /// Whether a shape has a marker to draw: one of its `marker-*`
        /// names a `marker`, and it is in no `clipPath`.
        fn hasMarkers(p: *P, node: u32, style: *const Style) bool {
            if (style.marker_start.len == 0 and style.marker_mid.len == 0 and style.marker_end.len == 0) return false;
            var up = p.doc.nodes[node].parent;
            while (up != none) : (up = p.doc.nodes[up].parent) {
                if (p.doc.nodes[up].tag == .clipPath) return false;
            }
            for ([_][]const u8{ style.marker_start, style.marker_mid, style.marker_end }) |text| {
                if (text.len != 0 and p.referenced(text, .marker) != null) return true;
            }
            return false;
        }

        /// A shape's markers - in the path, in its units - drawn at its
        /// vertices: `marker-start` at the first, `marker-mid` at each but
        /// the first, the last and a close, `marker-end` at the last.
        fn drawMarkers(p: *P, node: u32, style: *const Style, matrix: Matrix, viewport: [2]f32) void {
            if (p.marker_depth >= max_marker_depth) return;
            // The shape again, its vertices read from it, on a path of the
            // markers' own: the shape's is still to be painted.
            const saved_path = p.ownPath() orelse return;
            defer p.pathBack(saved_path);
            if (!p.buildShape(node, viewport)) return;
            const total = p.vb.PathVertices(p.path, null, 0);
            if (total == 0) return;
            var vertices: []vector.Vertex = p.work.vertices[0..@min(total, max_vertices)];
            var own: ?Room = null;
            defer if (own) |room| p.ext.FreeRoom(room);
            // A marker's own markers are drawn while the work's vertices
            // are still the shape's: theirs have room of their own.
            if (total > max_vertices or p.marker_depth > 0) {
                const room = p.ext.AllocRoom(@as(usize, total) * @sizeOf(vector.Vertex)) orelse return;
                own = room;
                const all: [*]vector.Vertex = @ptrCast(@alignCast(room.ptr));
                vertices = all[0..total];
            }
            _ = p.vb.PathVertices(p.path, vertices.ptr, @intCast(vertices.len));
            const stroke_width = style.stroke_width.resolveAt(.other, viewport, style.font_size);
            // The shape is the markers' context; the frame their content
            // starts at is `drawMarker`'s to say.
            p.marked[p.marker_depth] = .{ .style = style, .matrix = matrix, .node = node, .viewport = viewport, .base = 0 };
            if (p.referenced(style.marker_start, .marker)) |marker| {
                if (vertices[0].flags & vector.VERTEXF_START != 0) p.drawMarker(marker, &vertices[0], 0, stroke_width, matrix, viewport);
            }
            if (p.referenced(style.marker_mid, .marker)) |marker| {
                var i: usize = 1;
                while (i + 1 < vertices.len) : (i += 1) {
                    if (vertices[i].flags & vector.VERTEXF_CLOSED != 0) continue;
                    p.drawMarker(marker, &vertices[i], i, stroke_width, matrix, viewport);
                }
            }
            if (p.referenced(style.marker_end, .marker)) |marker| {
                const last = vertices.len - 1;
                if (vertices[last].flags & vector.VERTEXF_START == 0) p.drawMarker(marker, &vertices[last], last, stroke_width, matrix, viewport);
            }
        }

        /// One marker at a vertex: its content in its `viewBox`, at its
        /// `refX`, `refY`, turned as `orient` says, scaled by the stroke's
        /// width unless `markerUnits` says the user's, and clipped to its
        /// box unless its `overflow` is visible.
        fn drawMarker(p: *P, marker: u32, vertex: *const vector.Vertex, index: usize, stroke_width: f32, matrix: Matrix, viewport: [2]f32) void {
            for (p.markers[0..p.marker_depth]) |drawing| if (drawing == marker) return;
            if (p.depth + 2 >= max_depth) return;
            const doc = p.doc;
            const width = p.lengthOr(marker, .markerWidth, .x, viewport, .{ .value = 3 });
            const height = p.lengthOr(marker, .markerHeight, .y, viewport, .{ .value = 3 });
            if (!(width > 0) or !(height > 0)) return;
            const ref_x = p.lengthOf(marker, .refX, .x, viewport, 0);
            const ref_y = p.lengthOf(marker, .refY, .y, viewport, 0);
            var scale: f32 = stroke_width;
            if (doc.get(marker, .markerUnits)) |units| {
                if (std.mem.eql(u8, values.trim(units), "userSpaceOnUse")) scale = 1;
            }
            if (!(scale > 0)) return;
            var box_matrix = Matrix{};
            var inner = [2]f32{ width, height };
            if (viewBox(doc.get(marker, .viewBox))) |box| {
                box_matrix = viewBoxMatrix(box, doc.get(marker, .preserveAspectRatio) orelse "", width, height);
                inner = .{ box.width, box.height };
            }
            const angle = markerAngle(doc.get(marker, .orient), vertex, index);
            const box_scale = filter_.stretchOf(box_matrix);
            const at = matrix.then(Matrix.translate(vertex.point.x, vertex.point.y))
                .then(Matrix.rotate(angle))
                .then(Matrix.scale(box_scale[0] * scale, box_scale[1] * scale))
                .then(Matrix.translate(-ref_x, -ref_y));
            var marker_style = p.styleChain(marker);
            marker_style.opacity = 1;
            marker_style.filter = "";
            marker_style.clip = "";
            marker_style.mask = "";
            var clips: u8 = 0;
            // A marker clips to its box unless told.
            if (!(marker_style.overflow_visible orelse false)) {
                // Its box, in the units of its content.
                const inverse = box_matrix.invert() orelse return;
                const clip = filter_.boxThrough(inverse, .{ .width = width, .height = height });
                p.vb.ClearPath(p.path);
                p.vb.AddRect(p.path, &clip, 0, 0);
                _ = p.vb.PushClip(p.canvas, p.path, &at, vector.RULE_NONZERO);
                clips = 1;
            }
            defer for (0..clips) |_| p.vb.PopClip(p.canvas);
            const saved = p.depth;
            p.markers[p.marker_depth] = marker;
            p.marked[p.marker_depth].base = saved + 1;
            p.marker_depth += 1;
            defer p.marker_depth -= 1;
            p.work.frames[saved + 1] = .{ .node = marker, .style = marker_style, .matrix = at, .viewport = inner };
            p.drawFrom(saved + 1);
            p.depth = saved;
        }

        // --- filters -----------------------------------------------------------------

        /// What `style`'s filters come to for `node` drawn through `space`:
        /// filters to run, none - none given, or a list in error - or
        /// nothing drawn, for a list of filters none of which is made.
        fn filterBy(p: *P, style: *const Style, node: u32, space: Matrix, viewport: [2]f32) Filtered {
            if (style.filter.len == 0) return .none;
            const built = p.filterRoom() orelse return .none;
            defer p.freeFilterRoom(built);
            p.checking_filters += 1;
            defer p.checking_filters -= 1;
            var entries = filter_.Entries.of(style.filter, style.font_size);
            var made = false;
            var failed = false;
            var setup: ?filter_.Setup = null;
            while (entries.next()) |entry| {
                if (setup == null) setup = p.setupOf(node, space, style, viewport);
                switch (entry) {
                    .url => |id| {
                        const filter = p.filterNamed(id) orelse {
                            failed = true;
                            continue;
                        };
                        if (filter_.build(p, filter, &setup.?, built)) made = true else failed = true;
                    },
                    .function => |function| {
                        if (filter_.buildFunction(function, &setup.?, built)) made = true;
                    },
                }
            }
            if (entries.failed) return .none;
            if (made) return .run;
            return if (failed) .hidden else .none;
        }

        /// `style`'s filters run, one after another, on the layer `node`
        /// was drawn on through `space`.
        fn runFilters(p: *P, node: u32, space: Matrix, style: *const Style, viewport: [2]f32) void {
            const built = p.filterRoom() orelse return;
            defer p.freeFilterRoom(built);
            const setup = p.setupOf(node, space, style, viewport);
            var entries = filter_.Entries.of(style.filter, style.font_size);
            while (entries.next()) |entry| {
                const mark = p.picture_count;
                defer p.freePictures(mark);
                const made = switch (entry) {
                    .url => |id| if (p.filterNamed(id)) |filter| filter_.build(p, filter, &setup, built) else false,
                    .function => |function| filter_.buildFunction(function, &setup, built),
                };
                if (made) _ = p.vb.FilterLayer(p.canvas, &built.primitives, built.count, &built.pixels);
            }
        }

        /// The filters' regions, in pixels, of `node` drawn through
        /// `space`; null for none made.
        fn filterRegion(p: *P, node: u32, style: *const Style, space: Matrix, viewport: [2]f32) ?vector.Rect {
            const built = p.filterRoom() orelse return null;
            defer p.freeFilterRoom(built);
            p.checking_filters += 1;
            defer p.checking_filters -= 1;
            const setup = p.setupOf(node, space, style, viewport);
            var entries = filter_.Entries.of(style.filter, style.font_size);
            var all: ?vector.Rect = null;
            while (entries.next()) |entry| {
                const mark = p.picture_count;
                defer p.freePictures(mark);
                const made = switch (entry) {
                    .url => |id| if (p.filterNamed(id)) |filter| filter_.build(p, filter, &setup, built) else false,
                    .function => |function| filter_.buildFunction(function, &setup, built),
                };
                if (made) all = unite(all, built.pixels);
            }
            return all;
        }

        /// A filtered element is drawn aside, through its matrix with
        /// any turn and slant taken out - stretched only, each way along
        /// its own axis - so that its filters work along its axes, and
        /// put down through them after (`putStraight`): when the matrix
        /// turns or slants it, or when its filter region reaches past the
        /// canvas, which a blur, say, reads from (since 1.7). The aside
        /// is the whole region when that is at most four canvases' pixels,
        /// else what of it the canvas shows. Null for neither, or without
        /// the room: the filters run where it is drawn, on what the
        /// canvas shows, in the canvas's axes.
        fn straighten(p: *P, node: u32, style: *const Style, space: Matrix, viewport: [2]f32) ?Straight {
            const tolerance = 1e-5 * (@abs(space.a) + @abs(space.b) + @abs(space.c) + @abs(space.d));
            const turned = !(@abs(space.b) <= tolerance and @abs(space.c) <= tolerance);
            const across = @sqrt(space.a * space.a + space.b * space.b);
            const down = @sqrt(space.c * space.c + space.d * space.d);
            if (!(across > 0) or !(down > 0)) return null;
            // The matrix's columns made a unit long: its turn and slant.
            const turn = Matrix{ .a = space.a / across, .b = space.b / across, .c = space.c / down, .d = space.d / down };
            const unturn = turn.invert() orelse return null;
            const region = p.filterRegion(node, style, unturn.then(space), viewport) orelse return null;
            const shown = boxThrough(unturn, .{ .width = @floatFromInt(p.size[0]), .height = @floatFromInt(p.size[1]) });
            const inside = region.x >= shown.x and region.y >= shown.y and region.x + region.width <= shown.x + shown.width and region.y + region.height <= shown.y + shown.height;
            const canvas_pixels = @as(f32, @floatFromInt(p.size[0])) * @as(f32, @floatFromInt(p.size[1]));
            const whole = region.width * region.height <= 4 * canvas_pixels;
            if (!turned and (inside or !whole)) return null;
            const left = @floor(if (whole) region.x else @max(region.x, shown.x));
            const top = @floor(if (whole) region.y else @max(region.y, shown.y));
            const right = @ceil(if (whole) region.x + region.width else @min(region.x + region.width, shown.x + shown.width));
            const bottom = @ceil(if (whole) region.y + region.height else @min(region.y + region.height, shown.y + shown.height));
            if (!(right - left >= 1) or !(bottom - top >= 1)) return null;
            if (right - left > max_side or bottom - top > max_side) return null;
            const width: u32 = @intFromFloat(right - left);
            const height: u32 = @intFromFloat(bottom - top);
            // A shape's path, made already, drawn aside.
            const aside = p.beginAside(width, height, false) orelse return null;
            _ = p.vb.PushLayer(p.canvas, 1);
            return .{ .aside = aside, .into = Matrix.translate(-left, -top).then(unturn), .width = width, .height = height };
        }

        /// What `straighten` set aside: its filters run, and its pixels
        /// put down through the turn onto the canvas drawn on before.
        fn putStraight(p: *P, straight: Straight, node: u32, space: Matrix, style: *const Style, viewport: [2]f32) void {
            p.runFilters(node, straight.into.then(space), style, viewport);
            p.vb.PopLayer(p.canvas);
            const room = p.endAside(straight.aside);
            defer p.ext.FreeRoom(room);
            const back = straight.into.invert() orelse return;
            const paint = vector.Paint{
                .kind = vector.PAINT_IMAGE,
                .image = @ptrCast(@alignCast(room.ptr)),
                .image_width = straight.width,
                .image_height = straight.height,
                .image_bytes_per_row = straight.width * @sizeOf(graphics.Pen),
            };
            const saved = p.ownPath() orelse return;
            defer p.pathBack(saved);
            const all = vector.Rect{ .width = @floatFromInt(straight.width), .height = @floatFromInt(straight.height) };
            p.vb.AddRect(p.path, &all, 0, 0);
            _ = p.vb.FillPath(p.canvas, p.path, &back, &paint, vector.RULE_NONZERO);
        }

        fn setupOf(p: *P, node: u32, space: Matrix, style: *const Style, viewport: [2]f32) filter_.Setup {
            return .{ .space = space, .box = p.boundsOf(node, viewport), .viewport = viewport, .colour = style.colour, .font_size = style.font_size };
        }

        /// The `filter` element by `id`.
        fn filterNamed(p: *P, id: []const u8) ?u32 {
            const node = p.doc.byId(id) orelse return null;
            return if (p.doc.nodes[node].tag == .filter) node else null;
        }

        /// Room for a filter being made: the work's for the first, its own
        /// for one inside another's `feImage`.
        fn filterRoom(p: *P) ?*filter_.Built {
            if (p.filter_depth == 0) {
                p.filter_depth = 1;
                return &p.work.filter;
            }
            if (p.filter_depth >= max_references) return null;
            const room = p.ext.AllocRoom(@sizeOf(filter_.Built)) orelse return null;
            p.filter_depth += 1;
            return @ptrCast(@alignCast(room.ptr));
        }

        fn freeFilterRoom(p: *P, built: *filter_.Built) void {
            p.filter_depth -= 1;
            if (built == &p.work.filter) return;
            const bytes: [*]align(@alignOf(vector.Point)) u8 = @ptrCast(built);
            p.ext.FreeRoom(bytes[0..@sizeOf(filter_.Built)]);
        }

        /// A property of an element as its style has it - the last of its
        /// attribute, the rules for it and its `style` attribute - for a
        /// filter primitive.
        pub fn propertyOf(p: *P, node: u32, name: Name) ?[]const u8 {
            var found: ?[]const u8 = null;
            var cascaded = p.cascade(node);
            while (cascaded.next()) |one| {
                if (one.name == name) found = one.value;
            }
            return found;
        }

        /// The `color` an element has.
        pub fn colourAt(p: *P, node: u32) Colour {
            return p.styleChain(node).colour;
        }

        /// What an `feImage` draws, in the pixels of its subregion `rect`
        /// - in user units - cut to the canvas: the picture its `href`
        /// names, fitted to the subregion as `preserveAspectRatio` says,
        /// or the element it names, its units' origin at the subregion's
        /// corner. Stretched as the filter's matrix stretches, not turned.
        /// Null for nothing.
        pub fn filterPicture(p: *P, fe: u32, rect: vector.Rect, setup: *const filter_.Setup) ?vector.FilterImage {
            if (p.checking_filters != 0) return .{};
            // A picture of what draws this filter again: none.
            if (p.isDropped(fe, .href)) return null;
            const href = p.doc.get(fe, .href) orelse return null;
            const pixels = filter_.boxThrough(setup.space, rect);
            const left = @round(pixels.x);
            const top = @round(pixels.y);
            const right = @min(@round(pixels.x + pixels.width), @as(f32, @floatFromInt(p.size[0])));
            const bottom = @min(@round(pixels.y + pixels.height), @as(f32, @floatFromInt(p.size[1])));
            const from_x = @max(left, 0);
            const from_y = @max(top, 0);
            if (!(right > from_x) or !(bottom > from_y)) return null;
            const width: u32 = @intFromFloat(right - from_x);
            const height: u32 = @intFromFloat(bottom - from_y);
            const stretch = filter_.stretchOf(setup.space);
            const at = Matrix.translate(left - from_x, top - from_y).then(Matrix.scale(stretch[0], stretch[1]));
            const target = p.doc.byHref(href);
            const picture = if (target == null) p.openImage(href) else null;
            defer if (picture) |opened| p.ext.CloseImage(opened);
            if (target == null and picture == null) return null;
            const aside = p.beginAside(width, height, true) orelse return null;
            if (target) |element| {
                if (element != fe and drawable(p.doc.nodes[element].tag)) {
                    const parent = p.doc.nodes[element].parent;
                    if (parent != none) p.drawChildren(parent, element, at, setup.viewport);
                }
            } else if (picture) |opened| {
                const place = vector.Rect{ .width = rect.width, .height = rect.height };
                const aspect = p.doc.get(fe, .preserveAspectRatio) orelse "";
                if (opened.document) |text| {
                    if (p.openDocument(text)) |nested| {
                        var held = nested;
                        p.drawDocument(&held, place, aspect, at);
                        p.closeDocument(&held);
                    }
                } else p.drawPicture(&opened, place, aspect, at, 1, p.styleChain(fe).nearest);
            }
            const room = p.endAside(aside);
            if (!p.holdPicture(room)) return null;
            return .{
                .pens = @ptrCast(@alignCast(room.ptr)),
                .width = width,
                .height = height,
                .bytes_per_row = width * @sizeOf(graphics.Pen),
                .x = @intFromFloat(from_x),
                .y = @intFromFloat(from_y),
            };
        }

        /// A `filter`'s or a `mask`'s region: in the box's units, by default
        /// a tenth of the box more each way; or the user's, a tenth of the
        /// viewport.
        fn regionOf(p: *P, element: u32, box_units: bool, box: vector.Rect, viewport: [2]f32) vector.Rect {
            if (box_units) {
                return .{
                    .x = box.x + boxFraction(p.doc.get(element, .x), -0.1) * box.width,
                    .y = box.y + boxFraction(p.doc.get(element, .y), -0.1) * box.height,
                    .width = boxFraction(p.doc.get(element, .width), 1.2) * box.width,
                    .height = boxFraction(p.doc.get(element, .height), 1.2) * box.height,
                };
            }
            const tenth = Length{ .value = -10, .percent = true };
            const more = Length{ .value = 120, .percent = true };
            return .{
                .x = p.lengthOr(element, .x, .x, viewport, tenth),
                .y = p.lengthOr(element, .y, .y, viewport, tenth),
                .width = p.lengthOr(element, .width, .x, viewport, more),
                .height = p.lengthOr(element, .height, .y, viewport, more),
            };
        }

        // --- text ---------------------------------------------------------------------

        /// A `text` drawn: laid out, then span by span - the lines under
        /// and over it, its glyphs, the line through it.
        fn drawText(p: *P, node: u32, top: *const Frame) void {
            const style = p.styleOf(node, &top.style);
            if (!style.shown) return;
            p.em = style.font_size;
            const viewport = top.viewport;
            const matrix = top.matrix.then(p.ownTransform(node, viewport));
            // In a clip, the glyphs alone.
            const drawn_through = if (p.clipping != null) Through{} else p.through(node, &style, matrix, viewport);
            defer for (0..drawn_through.clips) |_| p.vb.PopClip(p.canvas);
            if (drawn_through.hidden) return;
            const laid = p.layOut(node, &style, viewport, .{});
            if (laid.count == 0) return;
            // Its glyphs may overlap, and its spans: its opacity on a layer.
            const layered = p.clipping == null and layerFor(&drawn_through, &style, true);
            if (layered) p.pushLayer(&style);
            const straight = if (drawn_through.filtered) p.straighten(node, &style, matrix, viewport) else null;
            const drawn = if (straight) |aside| aside.into.then(matrix) else matrix;
            // A paint of the box's units is of the whole text's box.
            const saved_box = p.paint_box;
            p.paint_box = laid.box;
            var again = Again{ .node = node, .style = &style, .viewport = viewport, .serial = laid.serial };
            var start: u32 = 0;
            while (start < laid.count) {
                const run = p.work.clusters[start].run;
                var end = start + 1;
                while (end < laid.count and p.work.clusters[end].run == run) end += 1;
                p.drawClusters(start, end, &drawn, viewport, &again);
                start = end;
            }
            p.paint_box = saved_box;
            if (layered) {
                if (straight) |aside| {
                    p.putStraight(aside, node, matrix, &style, viewport);
                } else if (drawn_through.filtered) p.runFilters(node, matrix, &style, viewport);
                p.vb.PopLayer(p.canvas);
            }
        }

        /// A `text` laid out: how many clusters the work holds, the box of
        /// them all - by their fonts' measures and their lines, through the
        /// matrix asked - and which laying out it was.
        const Laid = struct { count: u32 = 0, box: ?vector.Rect = null, serial: u32 = 0 };

        /// What lays a `text` out again when a paint drew another text - in
        /// a pattern - in the same work.
        const Again = struct { node: u32, style: *const Style, viewport: [2]f32, serial: u32 };

        fn layAgain(p: *P, again: *Again) void {
            if (p.laid_serial == again.serial) return;
            again.serial = p.layOut(again.node, again.style, again.viewport, .{}).serial;
        }

        /// A `text` being laid out: how much of the work it has taken, the
        /// `textPath` the last character follows, and where the next chunk
        /// goes when no `x` or `y` says.
        const Lay = struct {
            text: u32,
            viewport: [2]f32,
            vertical: bool,
            run_count: u32 = 0,
            piece_count: u32 = 0,
            bytes: u32 = 0,
            character_count: u32 = 0,
            cluster_count: u32 = 0,
            glyph_count: u32 = 0,
            path: u32 = none,
            x: f32 = 0,
            y: f32 = 0,
            /// The place of a character with no font, for the next one.
            pending: bool = false,
            pending_x: ?f32 = null,
            pending_y: ?f32 = null,
        };

        /// The `text` `node`, its style `style`, laid out into the work:
        /// its spans and pieces of characters gathered, the white space
        /// where they meet taken off, its characters given their places,
        /// and chunk by chunk - a piece of text at a place of its own -
        /// shaped, spaced, stretched and set on a line or along a path.
        fn layOut(p: *P, node: u32, style: *const Style, viewport: [2]f32, outer: Matrix) Laid {
            p.laid_serial +%= 1;
            var l = Lay{ .text = node, .viewport = viewport, .vertical = style.vertical };
            const work = p.work;
            if (p.addRun(&l, node, style, no_run) == no_run) return .{ .serial = p.laid_serial };
            p.gather(&l, node, 0, 0);
            text_.trimPieces(work.pieces[0..l.piece_count], work.text_bytes[0..l.bytes]);
            for (work.pieces[0..l.piece_count]) |piece| {
                var at: usize = piece.start;
                while (at < piece.end) p.addCharacter(&l, text_.nextCode(work.text_bytes[0..piece.end], &at), piece.run);
            }
            var start: u32 = 0;
            while (start < l.character_count) {
                var end = start + 1;
                while (end < l.character_count and !work.characters[end].starts) end += 1;
                p.layChunk(&l, start, end);
                start = end;
            }
            return .{ .count = l.cluster_count, .box = p.boxOf(l.cluster_count, outer), .serial = p.laid_serial };
        }

        /// A span of the text - the `text`, a `tspan`, `tref`, `textPath`
        /// or `a` - in the work's runs, of `parent`'s; `no_run` when they
        /// are full.
        fn addRun(p: *P, l: *Lay, node: u32, style: *const Style, parent: u8) u8 {
            if (l.run_count == max_runs) return no_run;
            const index: u8 = @intCast(l.run_count);
            l.run_count += 1;
            const work = p.work;
            const run = &work.runs[index];
            run.* = p.runOf(style);
            run.node = node;
            run.vertical = l.vertical;
            const tag = p.doc.nodes[node].tag;
            if (tag != .textPath) {
                for ([_]Name{ .x, .y, .dx, .dy }, 0..) |name, which| run.lists[which] = List.of(p.doc.get(node, name), false);
            }
            run.lists[list_rotate] = List.of(p.doc.get(node, .rotate), true);
            const above: ?*const Run = if (parent == no_run) null else &work.runs[parent];
            run.parent = if (above != null) parent else index;
            run.hidden = !style.shown or (if (above) |outer| outer.hidden else false);
            run.path = if (above) |outer| outer.path else none;
            if (tag == .textPath) {
                if (p.pathOfText(node, l.viewport)) run.path = node else run.hidden = true;
            }
            run.letter = style.letter_spacing.resolveAt(.x, l.viewport, style.font_size);
            run.word = style.word_spacing.resolveAt(.x, l.viewport, style.font_size);
            // Its baseline: the shifts of the spans it is in, the text's
            // own not counted, and where its font's baselines put it.
            run.raised = if (above) |outer| outer.raised + p.shiftOf(run, l.viewport) else 0;
            run.baseline = -run.raised;
            if (!l.vertical) {
                const which = if (style.alignment == .auto or style.alignment == .baseline) style.dominant else style.alignment;
                run.baseline += alignmentShift(run, which);
            }
            // The lines it is decorated with: those it says, drawn in its
            // paint, and those of the spans it is in, in theirs.
            for (&run.lines, 0..) |*line, kind| {
                const bit = @as(u8, 1) << @intCast(kind);
                line.* = if (style.decoration_own & bit != 0 or (above == null and style.decoration & bit != 0)) index else if (above) |outer| outer.lines[kind] else no_run;
            }
            run.length = null;
            if (p.doc.get(node, .textLength)) |text| if (values.length(text)) |given| {
                const target = given.resolveAt(.other, l.viewport, style.font_size);
                if (target >= 0) run.length = target;
            };
            run.stretch_glyphs = if (p.doc.get(node, .lengthAdjust)) |text| std.mem.eql(u8, values.trim(text), "spacingAndGlyphs") else false;
            return index;
        }

        /// How far a span's own `baseline-shift` raises it: by its font's
        /// measures, by a length, or by a percentage of its font's size.
        fn shiftOf(p: *P, run: *const Run, viewport: [2]f32) f32 {
            _ = p;
            const style = &run.style;
            return switch (style.shift) {
                .none => 0,
                .sub => -run.sub,
                .super => run.super,
                .length => |given| if (given.percent) style.font_size * given.value / 100 else given.resolveAt(.other, viewport, style.font_size),
            };
        }

        /// The spans and pieces of characters inside `element`, of the run
        /// `run_index`, `depth` spans into the text. A `textPath` is only a
        /// `text`'s own child.
        fn gather(p: *P, l: *Lay, element: u32, run_index: u8, depth: u32) void {
            var child = p.doc.nodes[element].first_child;
            while (child != none) : (child = p.doc.nodes[child].next) {
                const tag = p.doc.nodes[child].tag;
                switch (tag) {
                    .@"#text" => {
                        var last: u8 = 0;
                        const start = l.bytes;
                        _ = text_.collapse(&p.work.text_bytes, &l.bytes, p.doc.get(child, .@"#text") orelse "", p.work.runs[run_index].style.preserve, &last);
                        p.addPiece(l, start, run_index, depth);
                    },
                    .tspan, .a, .tref, .textPath => {
                        if (tag == .textPath and element != l.text) continue;
                        if (depth + 1 >= max_span_depth) continue;
                        if (!p.conditionsHold(child)) continue;
                        const style = p.styleOf(child, &p.work.runs[run_index].style);
                        const index = p.addRun(l, child, &style, run_index);
                        if (index == no_run) continue;
                        if (tag == .tref) p.gatherTref(l, child, index, depth + 1) else p.gather(l, child, index, depth + 1);
                    },
                    else => {},
                }
            }
        }

        /// A `tref`'s characters: all those of the element it names, one
        /// piece; none for an element with none.
        fn gatherTref(p: *P, l: *Lay, tref: u32, run_index: u8, depth: u32) void {
            const named = p.doc.byHref(p.doc.get(tref, .href) orelse return) orelse return;
            const start = l.bytes;
            var last: u8 = 0;
            const preserve = p.work.runs[run_index].style.preserve;
            var node = named;
            const end = p.doc.nodes[named].next;
            // Its text nodes, at any depth, in order.
            while (true) {
                if (p.doc.nodes[node].tag == .@"#text") {
                    if (!text_.collapse(&p.work.text_bytes, &l.bytes, p.doc.get(node, .@"#text") orelse "", preserve, &last)) break;
                }
                if (p.doc.nodes[node].first_child != none) {
                    node = p.doc.nodes[node].first_child;
                    continue;
                }
                while (node != named and p.doc.nodes[node].next == none) node = p.doc.nodes[node].parent;
                if (node == named) break;
                node = p.doc.nodes[node].next;
                if (node == end) break;
            }
            if (l.bytes > start) p.addPiece(l, start, run_index, depth);
        }

        fn addPiece(p: *P, l: *Lay, start: u32, run_index: u8, depth: u32) void {
            if (l.piece_count == max_pieces) {
                l.bytes = start;
                return;
            }
            p.work.pieces[l.piece_count] = .{ .start = start, .end = l.bytes, .depth = depth, .preserve = p.work.runs[run_index].style.preserve, .run = run_index };
            l.piece_count += 1;
        }

        /// One character of the span `run_index` taken into the work with
        /// its place: the `x`, `y`, `dx`, `dy` and `rotate` of the
        /// innermost span that has one for it. It is counted in each span
        /// it is in; one of a span not shown is no character of the text's.
        /// One with an `x` or a `y`, or the first on a path or after one,
        /// starts a chunk; one of no font passes its place on to the next.
        fn addCharacter(p: *P, l: *Lay, code: u32, run_index: u8) void {
            const work = p.work;
            const run = &work.runs[run_index];
            // Not shown, it is no character of the text's.
            if (run.hidden) return;
            const x = p.positionOf(l, run_index, list_x, .x);
            const y = p.positionOf(l, run_index, list_y, .y);
            const dx = p.positionOf(l, run_index, list_dx, .x) orelse 0;
            const dy = p.positionOf(l, run_index, list_dy, .y) orelse 0;
            const angle = p.rotateOf(run_index);
            var at = run_index;
            while (true) {
                work.runs[at].chars += 1;
                if (work.runs[at].parent == at) break;
                at = work.runs[at].parent;
            }
            const starts = x != null or y != null or run.path != l.path or l.character_count == 0;
            l.path = run.path;
            if (run.face == no_face or l.character_count == max_characters) {
                if (starts) {
                    l.pending = true;
                    if (x) |given| l.pending_x = given;
                    if (y) |given| l.pending_y = given;
                }
                return;
            }
            work.characters[l.character_count] = .{
                .code = code,
                .run = run_index,
                .face = p.faceOfCharacter(run, code),
                .x = x orelse l.pending_x,
                .y = y orelse l.pending_y,
                .dx = dx,
                .dy = dy,
                .rotate = angle,
                .starts = starts or l.pending,
            };
            l.character_count += 1;
            l.pending = false;
            l.pending_x = null;
            l.pending_y = null;
        }

        /// The next character's `x`, `y`, `dx` or `dy` - list `which` -:
        /// the innermost span's that has one for it.
        fn positionOf(p: *P, l: *const Lay, run_index: u8, which: usize, axis: values.Axis) ?f32 {
            var at = run_index;
            while (true) {
                const span = &p.work.runs[at];
                if (span.lists[which].valueAt(span.chars)) |one| return one.resolveAt(axis, l.viewport, span.style.font_size);
                if (span.parent == at) return null;
                at = span.parent;
            }
        }

        /// The next character's turn, in degrees: of the innermost span
        /// with a `rotate`, its last for a character past the list.
        fn rotateOf(p: *P, run_index: u8) f32 {
            var at = run_index;
            while (true) {
                const span = &p.work.runs[at];
                const list = &span.lists[list_rotate];
                if (list.last) |last| return (list.valueAt(span.chars) orelse last).value;
                if (span.parent == at) return 0;
                at = span.parent;
            }
        }

        /// The characters `first` to `end`, one chunk, made clusters of
        /// glyphs and set in place.
        fn layChunk(p: *P, l: *Lay, first: u32, end: u32) void {
            const work = p.work;
            const from = l.cluster_count;
            p.shapeChunk(l, first, end);
            if (l.cluster_count == from) return;
            const clusters = work.clusters[from..l.cluster_count];
            if (l.vertical) p.turnUpright(clusters);
            p.spaceOut(clusters);
            p.fitLength(clusters);
            const head = &work.characters[first];
            const path = work.runs[head.run].path;
            p.shiftClusters(clusters, path == none and l.vertical);
            orderClusters(clusters);
            if (path != none) p.layOnPath(l, clusters, head, path) else p.layOnLine(l, clusters, head);
        }

        /// The bidirectional level of each of the characters `first` to
        /// `end` (since 1.7): the chunk read as a paragraph of the text's
        /// `direction` - of the direction of its first letter for
        /// `unicode-bidi: plaintext` - and each span's `unicode-bidi` the
        /// marks of an embedding, an override or an isolate round its
        /// characters. In a column the paragraph is read from the top
        /// down or from the bottom up; a text or a span set upright there
        /// is read as an override from the top down, its characters all
        /// read from left to right. A chunk of no character that may be read from right
        /// to left, in a paragraph read from left to right, is all at 0
        /// without asking; one whose levels cannot be had is all at the
        /// paragraph's.
        fn levelChunk(p: *P, l: *const Lay, first: u32, end: u32) void {
            const work = p.work;
            const text_style = &work.runs[0].style;
            const upright = l.vertical and text_style.orientation == .upright;
            const rtl = text_style.rtl and !upright;
            @memset(work.levels[first..end], @intFromBool(rtl));
            const plain = text_style.bidi == .plaintext and !upright;
            const overridden = upright or text_style.bidi == .override or text_style.bidi == .isolate_override;
            var asked = rtl or plain or overridden;
            for (work.characters[first..end]) |character| {
                // Hebrew, from U+0590, is the first script read from right
                // to left.
                if (character.code >= 0x0590 or work.runs[character.run].style.bidi != .normal) asked = true;
            }
            if (!asked) return;
            var bytes: usize = 0;
            if (overridden) {
                bytes += utf8.encode(if (rtl) 0x202E else 0x202D, work.bidi_text[bytes..][0..4]);
            }
            // The spans whose marks are open, the outermost first.
            var open: [max_span_depth + 1]u8 = undefined;
            var open_count: usize = 0;
            for (first..end) |index| {
                // The spans with a `unicode-bidi` the character is in, the
                // innermost first.
                var chain: [max_span_depth + 1]u8 = undefined;
                var depth: usize = 0;
                var at = work.characters[index].run;
                while (work.runs[at].parent != at) : (at = work.runs[at].parent) {
                    if (!bidiMarked(&work.runs[at].style, l.vertical) or depth == chain.len) continue;
                    chain[depth] = at;
                    depth += 1;
                }
                if (bytes + 4 + 2 * chain.len * 6 > bidi_room) return;
                var kept: usize = 0;
                while (kept < open_count and kept < depth and open[kept] == chain[depth - 1 - kept]) kept += 1;
                while (open_count > kept) {
                    open_count -= 1;
                    bytes += closeMarks(&work.runs[open[open_count]].style, l.vertical, work.bidi_text[bytes..]);
                }
                while (open_count < depth) {
                    open[open_count] = chain[depth - 1 - open_count];
                    bytes += openMarks(&work.runs[open[open_count]].style, l.vertical, work.bidi_text[bytes..]);
                    open_count += 1;
                }
                work.bidi_starts[index] = @intCast(bytes);
                bytes += utf8.encode(work.characters[index].code, work.bidi_text[bytes..][0..4]);
            }
            const direction = if (plain) tts.TTS_FIRST_STRONG else if (rtl) tts.TTS_RIGHT_TO_LEFT else tts.TTS_LEFT_TO_RIGHT;
            if (p.ext.BidiLevels(work.bidi_text[0..bytes], direction, work.bidi_levels[0..bytes]) != tts.TTS_OK) return;
            for (first..end) |index| work.levels[index] = work.bidi_levels[work.bidi_starts[index]];
        }

        /// The clusters of a chunk, in the order they are read, put in the
        /// order they are drawn (since 1.7): from the highest level down to
        /// the lowest odd one, each row of clusters at that level or above
        /// turned around.
        fn orderClusters(clusters: []Cluster) void {
            var highest: u8 = 0;
            var lowest_odd: u8 = 0xFF;
            for (clusters) |cluster| {
                highest = @max(highest, cluster.level);
                if (cluster.level & 1 != 0) lowest_odd = @min(lowest_odd, cluster.level);
            }
            if (lowest_odd == 0xFF) lowest_odd = 1;
            var level = highest;
            while (level >= lowest_odd) : (level -= 1) {
                var at: usize = 0;
                while (at < clusters.len) {
                    if (clusters[at].level < level) {
                        at += 1;
                        continue;
                    }
                    var stop = at;
                    while (stop < clusters.len and clusters[stop].level >= level) stop += 1;
                    std.mem.reverse(Cluster, clusters[at..stop]);
                    at = stop;
                }
            }
        }

        /// The characters `first` to `end` shaped, stretch by stretch - a
        /// stretch of one font, size, language and setting - into clusters:
        /// a character and its marks, or the letters of a ligature.
        fn shapeChunk(p: *P, l: *Lay, first: u32, end: u32) void {
            const work = p.work;
            p.levelChunk(l, first, end);
            var at = first;
            while (at < end) {
                const leader = &work.runs[work.characters[at].run];
                const face = work.characters[at].face;
                const level = work.levels[at];
                var length: u32 = 0;
                var next = at;
                while (next < end) : (next += 1) {
                    if (next > at and (work.characters[next].face != face or work.levels[next] != level or !joins(leader, &work.runs[work.characters[next].run]))) break;
                    var bytes: [4]u8 = undefined;
                    const count = utf8.encode(work.characters[next].code, &bytes);
                    if (length + count > max_stretch) break;
                    @memcpy(work.stretch[length..][0..count], bytes[0..count]);
                    @memset(work.stretch_characters[length..][0..count], @intCast(next));
                    length += @intCast(count);
                }
                if (next == at) next = at + 1;
                const from = l.cluster_count;
                p.shapeStretch(l, length, leader, face, level);
                // Read from right to left, the stretch comes as it is
                // drawn: it is put in the order it is read until the chunk
                // is ordered as a whole.
                if (level & 1 != 0) std.mem.reverse(Cluster, work.clusters[from..l.cluster_count]);
                at = next;
            }
        }

        /// Whether a character of `run` goes on in a stretch `leader`
        /// started: in its font, at its size, in its language, with its
        /// spacing, kerning and capitals.
        fn joins(leader: *const Run, run: *const Run) bool {
            if (leader.face != run.face or leader.style.font_size != run.style.font_size) return false;
            if (leader.style.language != run.style.language) return false;
            if (leader.style.kerning != run.style.kerning or leader.style.small_caps != run.style.small_caps) return false;
            return leader.letter == run.letter;
        }

        /// The stretch gathered shaped by its font, `face`, in the
        /// direction of its bidirectional `level`, its glyphs taken into
        /// clusters by the character each stands for.
        fn shapeStretch(p: *P, l: *Lay, length: u32, leader: *const Run, face: u8, level: u8) void {
            if (length == 0) return;
            const work = p.work;
            const font = &work.faces[face];
            const scale = leader.style.font_size / @as(f32, @floatFromInt(font.metrics.units_per_em));
            // The font's own height where the glyph is not the span's.
            const ascent = if (face == leader.face) leader.ascent else @as(f32, @floatFromInt(font.metrics.ascender)) * scale;
            const descent = if (face == leader.face) leader.descent else @as(f32, @floatFromInt(font.metrics.descender)) * scale;
            var features: [5]tts.Feature = undefined;
            var feature_count: usize = 0;
            // Letters set apart are not joined into the ligatures a font
            // offers.
            if (leader.letter != 0) {
                features[0] = .{ .tag = tts.featureTag("liga"), .value = 0 };
                features[1] = .{ .tag = tts.featureTag("clig"), .value = 0 };
                feature_count = 2;
            }
            if (!leader.style.kerning) {
                features[feature_count] = .{ .tag = tts.featureTag("kern"), .value = 0 };
                feature_count += 1;
            }
            if (leader.style.small_caps) {
                features[feature_count] = .{ .tag = tts.featureTag("smcp") };
                feature_count += 1;
            }
            features[feature_count] = .{};
            var shaped: tts.ShapedRun = .{ .glyphs = &work.shaped, .room = max_shaped };
            const outline = font.opened.?.outline;
            const direction = if (level & 1 != 0) tts.TTS_RIGHT_TO_LEFT else tts.TTS_LEFT_TO_RIGHT;
            if (p.ext.ShapeText(outline, work.stretch[0..length], direction, leader.style.language, if (feature_count > 0) &features else null, &shaped) != tts.TTS_OK) return;
            var cluster: ?*Cluster = null;
            var byte: u32 = 0;
            var units: i32 = 0;
            for (work.shaped[0..@min(shaped.count, max_shaped)]) |glyph| {
                if (cluster == null or glyph.cluster != byte) {
                    if (l.cluster_count == max_glyphs or glyph.cluster >= length) return;
                    byte = glyph.cluster;
                    const character = work.stretch_characters[glyph.cluster];
                    const run_index = work.characters[character].run;
                    const run = &work.runs[run_index];
                    cluster = &work.clusters[l.cluster_count];
                    const own = face == run.face;
                    cluster.?.* = .{ .first = l.glyph_count, .character = character, .run = run_index, .face = face, .scale = scale, .ascent = if (own) run.ascent else ascent, .descent = if (own) run.descent else descent, .level = level };
                    l.cluster_count += 1;
                    units = 0;
                }
                if (l.glyph_count == max_glyphs) return;
                const into = cluster.?;
                // Font units, y up, into the text's.
                work.glyphs[l.glyph_count] = .{
                    .glyph = glyph.glyph,
                    .x = @as(f32, @floatFromInt(units + glyph.x_offset)) * scale,
                    .y = -@as(f32, @floatFromInt(glyph.y_offset)) * scale,
                };
                l.glyph_count += 1;
                into.count += 1;
                const advance = @as(f32, @floatFromInt(glyph.advance)) * scale;
                into.advance += advance;
                into.width = @max(into.width, advance);
                units += glyph.advance;
            }
        }

        /// In vertical text, each cluster set for its column: one that
        /// stands upright - by its character, or every one of a span
        /// whose `text-orientation` is `upright` - turned back up and set
        /// by its first glyph's vertical measures (since 1.7): its
        /// vertical origin on the line, its middle across the column,
        /// and the column's advance. The others are moved so their
        /// middle is on the line. Where the font gives no vertical
        /// measures, an upright cluster is turned about its middle.
        fn turnUpright(p: *P, clusters: []Cluster) void {
            for (clusters) |*cluster| {
                const middle = (cluster.ascent + cluster.descent) / 2;
                const stands = switch (p.work.runs[cluster.run].style.orientation) {
                    .mixed => text_.upright(p.work.characters[cluster.character].code),
                    .upright => true,
                    .sideways => false,
                };
                var column: sdk.truetype.VerticalMetrics = undefined;
                const outline = p.work.faces[cluster.face].opened.?.outline;
                if (stands and cluster.count != 0 and p.ext.GlyphVerticalMetrics(outline, p.work.glyphs[cluster.first].glyph, &column)) {
                    // A point of the glyph, x right and y down from its
                    // origin, onto the line before it is turned: down
                    // the column from the vertical origin, across it
                    // from the middle of the advance.
                    const origin_x = @as(f32, @floatFromInt(column.origin_x)) * cluster.scale;
                    const origin_y = @as(f32, @floatFromInt(column.origin_y)) * cluster.scale;
                    cluster.inner = .{ .a = 0, .b = -1, .c = 1, .d = 0, .e = origin_y, .f = origin_x };
                    cluster.advance = @as(f32, @floatFromInt(column.advance)) * cluster.scale;
                    cluster.width = cluster.advance;
                    cluster.ascent = origin_x;
                    cluster.descent = -origin_x;
                } else if (stands) {
                    cluster.inner = Matrix.translate(0, middle).then(rotateAt(-90, cluster.width / 2, -middle));
                    cluster.ascent = cluster.width / 2;
                    cluster.descent = -cluster.width / 2;
                } else cluster.lift = middle;
            }
        }

        /// `letter-spacing` after each cluster of a script that is set
        /// apart but the chunk's last - a cluster it brings to no advance
        /// is not drawn - and `word-spacing` after each that separates
        /// words.
        fn spaceOut(p: *P, clusters: []Cluster) void {
            const work = p.work;
            var letters = false;
            var words = false;
            for (clusters) |cluster| {
                if (work.runs[cluster.run].letter != 0) letters = true;
                if (work.runs[cluster.run].word != 0) words = true;
            }
            if (letters) for (clusters, 0..) |*cluster, index| {
                if (!text_.spaceable(work.characters[cluster.character].code)) continue;
                if (index + 1 < clusters.len) cluster.advance += work.runs[cluster.run].letter;
                if (!(cluster.advance > 0)) {
                    cluster.advance = 0;
                    cluster.width = 0;
                    cluster.count = 0;
                }
            };
            if (words) for (clusters) |*cluster| {
                if (text_.separatesWords(work.characters[cluster.character].code)) cluster.advance += work.runs[cluster.run].word;
            };
        }

        /// Each span's `textLength`: its clusters in a row spaced out to
        /// it, or - `lengthAdjust="spacingAndGlyphs"` - stretched to it.
        /// Their own widths are what is fitted, any other spacing left out.
        fn fitLength(p: *P, clusters: []Cluster) void {
            var start: usize = 0;
            while (start < clusters.len) {
                const run_index = clusters[start].run;
                var end = start + 1;
                while (end < clusters.len and clusters[end].run == run_index) end += 1;
                const segment = clusters[start..end];
                start = end;
                const run = &p.work.runs[run_index];
                const target = run.length orelse continue;
                var width: f32 = 0;
                for (segment) |cluster| width += cluster.width;
                if (!run.stretch_glyphs) {
                    const gap = if (segment.len > 1) (target - width) / @as(f32, @floatFromInt(segment.len - 1)) else 0;
                    for (segment) |*cluster| {
                        cluster.advance = cluster.width + gap;
                        cluster.spacing = gap;
                    }
                } else {
                    const factor = target / width;
                    if (!(factor >= 0.001)) continue;
                    for (segment) |*cluster| {
                        cluster.stretch = factor;
                        cluster.advance *= factor;
                        cluster.width *= factor;
                    }
                }
            }
        }

        /// What `dx` and `dy` move each cluster by: those of the
        /// characters up to its own, added up.
        fn shiftClusters(p: *P, clusters: []Cluster, vertical: bool) void {
            var sum_x: f32 = 0;
            var sum_y: f32 = 0;
            for (clusters) |*cluster| {
                const character = &p.work.characters[cluster.character];
                sum_x += character.dx;
                sum_y += character.dy;
                // Vertical text is laid out across and turned.
                cluster.shift_x = if (vertical) sum_y else sum_x;
                cluster.shift_y = if (vertical) -sum_x else sum_y;
            }
        }

        /// A chunk set on a line at its place - or where the last one ended
        /// - moved by its `text-anchor`, each cluster by its shifts and
        /// turned by its `rotate`. Vertical text is set across and turned
        /// down the column.
        fn layOnLine(p: *P, l: *Lay, clusters: []Cluster, head: *const Character) void {
            const work = p.work;
            const x0 = head.x orelse l.x;
            const y0 = head.y orelse l.y;
            clusters[0].apart = true;
            for (clusters[1..], 1..) |*cluster, index| {
                const before = &clusters[index - 1];
                if (cluster.shift_x != before.shift_x or cluster.shift_y != before.shift_y) cluster.apart = true;
            }
            var left: f32 = std.math.inf(f32);
            var right: f32 = -std.math.inf(f32);
            var advance: f32 = 0;
            for (clusters) |cluster| {
                const from = advance + cluster.shift_x;
                const to = from + cluster.advance - cluster.spacing;
                left = @min(left, @min(from, to));
                right = @max(right, @max(from, to));
                advance += cluster.advance;
            }
            // The shifts of the first and the last read: the chunk starts
            // at the first, and the next goes on from the last.
            var x = readEnd(clusters, .first).shift_x - left + anchorOffset(anchorOf(&work.runs[head.run].style, l.vertical), right - left);
            const line = if (l.vertical) rotateAt(90, x0, y0) else Matrix{};
            for (clusters) |*cluster| {
                const run = &work.runs[cluster.run];
                var m = line.then(Matrix.translate(x0 + x + cluster.shift_x, y0 + run.baseline + cluster.lift + cluster.shift_y));
                if (cluster.stretch != 1) m = m.then(Matrix.scale(cluster.stretch, 1));
                const angle = work.characters[cluster.character].rotate;
                if (angle != 0) {
                    m = m.then(Matrix.rotate(angle));
                    cluster.apart = true;
                }
                cluster.matrix = m;
                x += cluster.advance;
            }
            const last = readEnd(clusters, .last);
            var end_x = x + last.shift_x;
            var end_y = last.shift_y;
            if (l.vertical) std.mem.swap(f32, &end_x, &end_y);
            l.x = x0 + end_x;
            l.y = y0 + end_y;
        }

        /// A chunk set along its `textPath`: each cluster's middle at its
        /// distance along the path - from the `startOffset`, the chunk's
        /// `x` and its anchor - turned the way the path goes there, and
        /// moved off it by its `dy` and its baseline. One past either end
        /// is not drawn. `side="right"` sets it along the path walked
        /// backwards.
        fn layOnPath(p: *P, l: *Lay, clusters: []Cluster, head: *const Character, path_node: u32) void {
            const work = p.work;
            l.x = 0;
            l.y = 0;
            const saved = p.ownPath() orelse {
                for (clusters) |*cluster| cluster.hidden = true;
                return;
            };
            defer p.pathBack(saved);
            var path_matrix: Matrix = .{};
            if (!p.buildTextPath(path_node, l.viewport, &path_matrix)) {
                for (clusters) |*cluster| cluster.hidden = true;
                return;
            }
            const length = p.vb.PathLength(p.path, &path_matrix);
            var start: f32 = 0;
            if (p.doc.get(path_node, .startOffset)) |text| if (values.length(text)) |given| {
                start = if (given.percent) length * given.value / 100 else given.resolveAt(.other, l.viewport, work.runs[head.run].style.font_size);
            };
            const backwards = if (p.doc.get(path_node, .side)) |text| std.mem.eql(u8, values.trim(text), "right") else false;
            var total: f32 = 0;
            for (clusters) |cluster| total += cluster.advance;
            const own = if (l.vertical) head.y else head.x;
            var advance = (own orelse 0) + start + anchorOffset(anchorOf(&work.runs[head.run].style, l.vertical), total);
            for (clusters) |*cluster| {
                const run = &work.runs[cluster.run];
                const half = cluster.width / 2;
                const along = advance + cluster.shift_x + half;
                advance += cluster.advance;
                cluster.apart = true;
                var point: vector.Point = undefined;
                var angle: f32 = undefined;
                const distance = if (backwards) length - along else along;
                if (!(along >= 0) or !p.vb.PathPointAt(p.path, &path_matrix, distance, &point, &angle)) {
                    cluster.hidden = true;
                    continue;
                }
                if (backwards) angle += 180;
                var m = Matrix.translate(point.x, point.y).then(Matrix.rotate(angle)).then(Matrix.translate(-half, cluster.shift_y + run.baseline));
                const turn = work.characters[cluster.character].rotate;
                if (turn != 0) m = m.then(Matrix.rotate(turn));
                if (cluster.lift != 0) m = m.then(Matrix.translate(0, cluster.lift));
                if (cluster.stretch != 1) m = m.then(Matrix.scale(cluster.stretch, 1));
                cluster.matrix = m;
                l.x = point.x + cluster.advance;
                l.y = point.y;
            }
        }

        /// The path a `textPath` follows into the work's path: its own
        /// `path`, unless that draws nothing, or the shape its `href`
        /// names, with that one's transform in `path_matrix`. False for
        /// none.
        fn buildTextPath(p: *P, node: u32, viewport: [2]f32, path_matrix: *Matrix) bool {
            path_matrix.* = .{};
            if (p.doc.get(node, .path)) |path_data| {
                p.vb.ClearPath(p.path);
                _ = p.vb.AddPathData(p.path, path_data.ptr, @intCast(path_data.len));
                if (p.vb.PathLength(p.path, null) > 0) return true;
            }
            const named = p.doc.byHref(p.doc.get(node, .href) orelse return false) orelse return false;
            if (!isShape(p.doc.nodes[named].tag)) return false;
            if (!p.buildShape(named, viewport)) return false;
            path_matrix.* = p.ownTransform(named, viewport);
            return true;
        }

        /// Whether a `textPath` has a path to follow.
        fn pathOfText(p: *P, node: u32, viewport: [2]f32) bool {
            const saved = p.ownPath() orelse return false;
            defer p.pathBack(saved);
            var path_matrix: Matrix = undefined;
            return p.buildTextPath(node, viewport, &path_matrix);
        }

        /// The box of the clusters laid out, through `outer`: each one's
        /// advance by its font's height, and the lines decorating them.
        fn boxOf(p: *P, count: u32, outer: Matrix) ?vector.Rect {
            const work = p.work;
            var box: ?vector.Rect = null;
            for (work.clusters[0..count]) |cluster| {
                if (cluster.hidden) continue;
                const m = outer.then(cluster.matrix).then(cluster.inner);
                const width = if (cluster.advance > 0) cluster.advance else 1;
                const corners = [4]vector.Point{ .{ .x = 0, .y = -cluster.ascent }, .{ .x = width, .y = -cluster.ascent }, .{ .x = width, .y = -cluster.descent }, .{ .x = 0, .y = -cluster.descent } };
                for (corners) |corner| box = unite(box, pointBox(m.apply(corner)));
            }
            var start: u32 = 0;
            while (start < count) {
                var end = start + 1;
                while (end < count and work.clusters[end].run == work.clusters[start].run) end += 1;
                for (0..3) |kind| _ = p.decorate(start, end, kind, &box, outer);
                start = end;
            }
            return box;
        }

        /// A span's font, and what it draws itself of the styles the font
        /// has no face for.
        fn runOf(p: *P, style: *const Style) Run {
            var want = wantOf(style);
            const face = p.faceFor(style.font_family, &want);
            var run = Run{ .style = style.*, .face = face };
            if (face == no_face) return run;
            const f = &p.work.faces[face];
            const m = &f.metrics;
            const em: f32 = @floatFromInt(m.units_per_em);
            const scale = style.font_size / em;
            run.scale = scale;
            const drawn = f.opened.?.style;
            // About twelve degrees.
            if (want.italic and drawn & graphics.FSF_ITALIC == 0) run.lean = 0.21;
            const drawn_bold = f.weighted or m.weight >= text_.bold_weight or drawn & graphics.FSF_BOLD != 0;
            if (want.weight >= text_.bold_weight and !drawn_bold) run.thicken = style.font_size / 24;
            // Its measures, where the font gives them and where most
            // fonts have them where it does not.
            run.ascent = @as(f32, @floatFromInt(m.ascender)) * scale;
            run.descent = @as(f32, @floatFromInt(m.descender)) * scale;
            run.x_height = if (m.x_height > 0) @as(f32, @floatFromInt(m.x_height)) * scale else (run.ascent - run.descent) * 0.45;
            run.under = (if (m.underline_position != 0) @as(f32, @floatFromInt(m.underline_position)) else -em / 9) * scale;
            run.thickness = (if (m.underline_thickness > 0) @as(f32, @floatFromInt(m.underline_thickness)) else em / 12) * scale;
            run.strike = if (m.strikeout_position != 0) @as(f32, @floatFromInt(m.strikeout_position)) * scale else run.x_height / 2;
            run.sub = (if (m.subscript_offset > 0) @as(f32, @floatFromInt(m.subscript_offset)) else em / 5) * scale;
            run.super = (if (m.superscript_offset > 0) @as(f32, @floatFromInt(m.superscript_offset)) else em * 2 / 5) * scale;
            return run;
        }

        /// The font for a `font-family` list and what is wanted of it,
        /// which the words of a name the disk has nothing of may add to;
        /// `no_face` for none (`text.zig` says how a name is read). The
        /// generic family the first such name looks like, else a serif,
        /// is the font when no name of the list is found; a disk without
        /// it has sans, then Go's.
        fn faceFor(p: *P, family: []const u8, want: *Want) u8 {
            var names = text_.Names{ .list = family };
            var guessed = false;
            var look: ?text_.Generic = null;
            while (names.next()) |name| {
                if (p.listedFace(name, want)) |at| {
                    if (at != no_face) return at;
                    continue;
                }
                // A drawing program's own font, "Arial-BoldMT": what its
                // name says of it.
                if (!guessed) {
                    guessed = true;
                    look = text_.lookOf(name);
                    if (text_.nameSaysBold(name)) want.weight = @max(want.weight, 700);
                    if (text_.nameSaysItalic(name)) want.italic = true;
                }
            }
            const last = look orelse .serif;
            if (p.genericFace(last, want)) |at| return at;
            if (last != .serif) {
                if (p.genericFace(.serif, want)) |at| return at;
            }
            const sans = p.faceOf("sans.font", want);
            if (sans != no_face) return sans;
            return p.faceOf("go.font", want);
        }

        /// The face a name of a `font-family` list is: of a generic family
        /// as font.prefs names it, of the disk's family by the name, or of
        /// the generic family a well-known font's name stands for;
        /// `no_face` for one of them that does not open, and null for a
        /// name that is none of them.
        fn listedFace(p: *P, name: []const u8, want: *const Want) ?u8 {
            if (text_.genericOf(name)) |generic| return p.genericFace(generic, want) orelse no_face;
            if (name.len <= face_name) {
                var named: [face_name + 1]u8 = undefined;
                @memcpy(named[0..name.len], name);
                named[name.len] = 0;
                var found: [face_name + 1]u8 = undefined;
                if (p.ext.FindFamily(@ptrCast(&named), &found, found.len)) return p.faceOf(std.mem.sliceTo(&found, 0), want);
            }
            if (text_.standInOf(name)) |generic| return p.genericFace(generic, want) orelse no_face;
            return null;
        }

        /// The face of the family font.prefs names for `generic`; null
        /// when it names none or it does not open.
        fn genericFace(p: *P, generic: text_.Generic, want: *const Want) ?u8 {
            var found: [face_name + 1]u8 = undefined;
            if (!p.ext.GenericFamily(@intFromEnum(generic), &found, found.len)) return null;
            const at = p.faceOf(std.mem.sliceTo(&found, 0), want);
            return if (at != no_face) at else null;
        }

        /// The face of `family` nearest `want`: the one opened for it, or
        /// opened now - at `opsz` the size `want.optical` names when the
        /// font has that axis, and at its default where it has not.
        fn faceOf(p: *P, family: []const u8, want: *const Want) u8 {
            var plain = want.*;
            plain.optical = 0;
            const base = p.faceAt(family, &plain);
            if (base == no_face or want.optical == 0 or !p.work.faces[base].optical) return base;
            const at = p.faceAt(family, want);
            return if (at != no_face) at else base;
        }

        /// A font of the picture's, opened the first time it is asked for;
        /// `no_face` when it cannot be - which is remembered too.
        fn faceAt(p: *P, family: []const u8, want: *const Want) u8 {
            const faces = p.work.faces[0..p.face_count];
            for (faces, 0..) |*f, i| {
                if (f.want.same(want) and std.mem.eql(u8, f.familyName(), family)) return if (f.opened != null) @intCast(i) else no_face;
            }
            if (p.face_count == max_faces or family.len > face_name) return no_face;
            var face = Face{ .want = want.*, .opened = null, .metrics = .{} };
            @memcpy(face.family[0..family.len], family);
            face.family_len = @intCast(family.len);
            face.opened = p.ext.OpenFace(&face.family, want);
            if (face.opened) |opened| {
                p.ext.FontMetrics(opened.outline, &face.metrics);
                if (face.metrics.units_per_em == 0) {
                    p.ext.CloseFace(opened);
                    face.opened = null;
                } else {
                    var axes: [16]sdk.truetype.Axis = undefined;
                    const count = p.ext.FontAxes(opened.outline, &axes, axes.len);
                    for (axes[0..@min(count, axes.len)]) |axis| {
                        if (axis.tag == sdk.truetype.tableTag("opsz")) face.optical = true;
                        if (axis.tag == sdk.truetype.tableTag("wght")) face.weighted = true;
                    }
                }
            }
            p.work.faces[p.face_count] = face;
            p.face_count += 1;
            return if (face.opened != null) @intCast(p.face_count - 1) else no_face;
        }

        /// The font a character of `run` is drawn in: the span's own
        /// where it has a glyph for it, else the first of the rest of its
        /// `font-family` list that has, else the first fallback family
        /// that has - in the styles the span asks for - else the span's
        /// own again, which draws what it draws for a character it lacks.
        fn faceOfCharacter(p: *P, run: *const Run, code: u32) u8 {
            const own = run.face;
            if (code < 0x20 or p.hasGlyph(own, code)) return own;
            const want = wantOf(&run.style);
            var names = text_.Names{ .list = run.style.font_family };
            while (names.next()) |name| {
                const face = p.listedFace(name, &want) orelse continue;
                if (face != no_face and face != own and p.hasGlyph(face, code)) return face;
            }
            const count = p.fallbackCount();
            for (p.work.fallbacks[0..count]) |*name| {
                const face = p.faceOf(std.mem.sliceTo(name, 0), &want);
                if (face != no_face and face != own and p.hasGlyph(face, code)) return face;
            }
            return own;
        }

        fn hasGlyph(p: *P, face: u8, code: u32) bool {
            return p.ext.GlyphIndex(p.work.faces[face].opened.?.outline, code) != 0;
        }

        /// How many fallback families there are, their names read into
        /// the work the first time.
        fn fallbackCount(p: *P) u32 {
            if (p.fallback_count) |count| return count;
            var count: u32 = 0;
            while (count < max_fallbacks) : (count += 1) {
                const name = &p.work.fallbacks[count];
                if (!p.ext.FallbackFamily(count, name, fallback_name + 1)) break;
            }
            p.fallback_count = count;
            return count;
        }

        fn closeFaces(p: *P) void {
            for (p.work.faces[0..p.face_count]) |f| if (f.opened) |opened| p.ext.CloseFace(opened);
            p.face_count = 0;
        }

        /// The clusters `start` to `end`, of one span: the lines under and
        /// over it, its glyphs as one shape, filled and stroked as a shape
        /// of the span's style is, and the line through it - as SVG 2 has
        /// it, each a shape of its own, so a line crossing a glyph the
        /// other way round is no hole.
        fn drawClusters(p: *P, start: u32, end: u32, matrix: *const Matrix, viewport: [2]f32, again: *Again) void {
            const work = p.work;
            const run_index = work.clusters[start].run;
            if (!work.runs[run_index].style.visible) return;
            for ([_]usize{ line_under, line_over }) |kind| {
                p.vb.ClearPath(p.path);
                if (p.decorate(start, end, kind, null, .{})) {
                    p.paintRun(&work.runs[work.runs[run_index].lines[kind]], matrix, false, viewport);
                    p.layAgain(again);
                }
            }
            p.vb.ClearPath(p.path);
            const run = &work.runs[run_index];
            var pending = false;
            for (work.clusters[start..end]) |cluster| {
                if (cluster.hidden) continue;
                const m = cluster.matrix.then(cluster.inner);
                const outline = work.faces[cluster.face].opened.?.outline;
                for (work.glyphs[cluster.first..][0..cluster.count]) |glyph| {
                    // A glyph the font draws in colour is drawn so, in
                    // its place - but in a clip its outline alone counts.
                    if (p.clipping == null) {
                        const placed = matrix.then(m).then(.{ .a = cluster.scale, .c = run.lean * cluster.scale, .d = -cluster.scale, .e = glyph.x, .f = glyph.y });
                        const flush: Flush = .{ .run = run, .matrix = matrix, .viewport = viewport, .again = again, .pending = &pending };
                        if (p.drawInColour(outline, glyph.glyph, placed, &flush)) continue;
                    }
                    var segments = truetype.Segments{ .verbs = &work.glyph_verbs, .points = &work.glyph_points, .verb_room = glyph_verbs, .point_room = glyph_points };
                    var result = p.ext.GlyphSegments(outline, glyph.glyph, &segments);
                    var own_room: ?Room = null;
                    defer if (own_room) |room| p.ext.FreeRoom(room);
                    if (result == truetype.TRUETYPEERR_ROOM) {
                        // More than the block holds: room for this glyph
                        // alone, its points first and its verbs behind them.
                        const verb_count = segments.verb_count;
                        const point_count = segments.point_count;
                        const points_bytes = @as(u64, point_count) * @sizeOf(vector.Point);
                        // More than one allocation can be.
                        if (points_bytes + verb_count > most_room) continue;
                        const room = p.ext.AllocRoom(@intCast(points_bytes + verb_count)) orelse continue;
                        own_room = room;
                        segments = .{ .verbs = room.ptr + @as(usize, @intCast(points_bytes)), .points = @ptrCast(room.ptr), .verb_room = verb_count, .point_room = point_count };
                        result = p.ext.GlyphSegments(outline, glyph.glyph, &segments);
                    }
                    if (result != truetype.TRUETYPE_OK) continue;
                    // Font units, y up, into the cluster's - scaled,
                    // leaned, turned over - and the cluster's into the
                    // text's.
                    for (segments.points[0..segments.point_count]) |*point| {
                        point.* = m.apply(.{ .x = glyph.x + (point.x + run.lean * point.y) * cluster.scale, .y = glyph.y - point.y * cluster.scale });
                    }
                    _ = p.vb.AddSegments(p.path, segments.verbs, segments.verb_count, segments.points, segments.point_count);
                    pending = true;
                }
            }
            p.paintRun(run, matrix, true, viewport);
            p.layAgain(again);
            p.vb.ClearPath(p.path);
            if (p.decorate(start, end, line_through, null, .{})) {
                p.paintRun(&work.runs[work.runs[run_index].lines[line_through]], matrix, false, viewport);
                p.layAgain(again);
            }
        }

        /// The glyphs of a span gathered in the path so far, and what they
        /// are painted with: painted, before a glyph in colour is drawn
        /// over them.
        const Flush = struct {
            run: *const Run,
            matrix: *const Matrix,
            viewport: [2]f32,
            again: *Again,
            pending: *bool,

            fn now(flush: *const Flush, p: *P) void {
                if (!flush.pending.*) return;
                p.paintRun(flush.run, flush.matrix, true, flush.viewport);
                p.layAgain(flush.again);
                p.vb.ClearPath(p.path);
                flush.pending.* = false;
            }
        };

        /// A glyph drawn in colour, through `placed` - the font's units, y
        /// up, into pixels: by the first of its colour layers, the SVG
        /// document that draws it and its picture that the font has and
        /// that can be read, the span's glyphs before it painted first.
        /// False for a glyph drawn in none of them, whose outline is then
        /// drawn as any other's.
        fn drawInColour(p: *P, outline: *truetype.Outline, glyph: u32, placed: Matrix, flush: *const Flush) bool {
            const count = p.ext.GlyphPaints(outline, glyph, null, 0);
            if (count != 0) {
                flush.now(p);
                if (p.drawPaints(outline, glyph, count, placed, foregroundOf(&flush.run.style))) return true;
            }
            var glyph_document: truetype.Document = undefined;
            if (p.ext.GlyphDocument(outline, glyph, &glyph_document)) {
                // A document drawn y down, the glyph above its line.
                if (p.drawGlyphDocument(&glyph_document, glyph, placed.then(Matrix.scale(1, -1)), flush)) return true;
            }
            var picture: truetype.Picture = undefined;
            if (p.ext.GlyphPicture(outline, glyph, &picture)) {
                if (p.drawGlyphPicture(&picture, placed, flush)) return true;
            }
            return false;
        }

        /// The colour of a text that a glyph's colour layers draw in where
        /// they say the text's own: its fill's, when that is one colour,
        /// at its opacity; else black.
        fn foregroundOf(style: *const Style) vector.Colour {
            var colour: vector.Colour = switch (style.fill) {
                .colour => |given| given,
                .current => style.colour,
                else => .{},
            };
            colour.a *= style.fill_opacity;
            return colour;
        }

        /// A glyph's outline added to the path, in the font's units, y up.
        /// False for a glyph of none, or without the room for it.
        fn addGlyph(p: *P, outline: *truetype.Outline, glyph: u32) bool {
            const work = p.work;
            var segments = truetype.Segments{ .verbs = &work.glyph_verbs, .points = &work.glyph_points, .verb_room = glyph_verbs, .point_room = glyph_points };
            var result = p.ext.GlyphSegments(outline, glyph, &segments);
            var own_room: ?Room = null;
            defer if (own_room) |room| p.ext.FreeRoom(room);
            if (result == truetype.TRUETYPEERR_ROOM) {
                const points_bytes = @as(u64, segments.point_count) * @sizeOf(vector.Point);
                if (points_bytes + segments.verb_count > most_room) return false;
                const room = p.ext.AllocRoom(@intCast(points_bytes + segments.verb_count)) orelse return false;
                own_room = room;
                segments = .{ .verbs = room.ptr + @as(usize, @intCast(points_bytes)), .points = @ptrCast(room.ptr), .verb_room = segments.verb_count, .point_room = segments.point_count };
                result = p.ext.GlyphSegments(outline, glyph, &segments);
            }
            if (result != truetype.TRUETYPE_OK) return false;
            return p.vb.AddSegments(p.path, segments.verbs, segments.verb_count, segments.points, segments.point_count) == vector.VECTOR_OK;
        }

        /// A glyph of colour layers drawn: its `count` steps, through
        /// `placed` - the font's units, y up, into pixels - the text's
        /// own colour `foreground`. Each step's transform, clip and layer
        /// are vector.library's; a fill inside the clips fills the box
        /// where they all are. False without the memory for the steps.
        fn drawPaints(p: *P, outline: *truetype.Outline, glyph: u32, count: u32, placed: Matrix, foreground: vector.Colour) bool {
            // The steps; a stop for each; and room for as many transforms
            // and clips' boxes as there are steps, which none outnumber.
            const each = @sizeOf(truetype.PaintStep) + @sizeOf(vector.Stop) + @sizeOf(Matrix) + @sizeOf(vector.Rect);
            const bytes = @as(u64, count) * each;
            if (bytes > most_room) return false;
            const room = p.ext.AllocRoom(@intCast(bytes)) orelse return false;
            defer p.ext.FreeRoom(room);
            var at_byte: usize = 0;
            const steps: [*]truetype.PaintStep = @ptrCast(@alignCast(room.ptr));
            at_byte += @as(usize, count) * @sizeOf(truetype.PaintStep);
            const stops: [*]vector.Stop = @ptrCast(@alignCast(room.ptr + at_byte));
            at_byte += @as(usize, count) * @sizeOf(vector.Stop);
            const transforms: [*]Matrix = @ptrCast(@alignCast(room.ptr + at_byte));
            at_byte += @as(usize, count) * @sizeOf(Matrix);
            const boxes: [*]vector.Rect = @ptrCast(@alignCast(room.ptr + at_byte));
            const written = @min(p.ext.GlyphPaints(outline, glyph, steps, count), count);

            const whole = vector.Rect{ .width = @floatFromInt(p.size[0]), .height = @floatFromInt(p.size[1]) };
            var current = placed;
            var transform_count: u32 = 0;
            var clip_count: u32 = 0;
            var layer_count: u32 = 0;
            var at: u32 = 0;
            while (at < written) : (at += 1) {
                const step = &steps[at];
                switch (step.kind) {
                    truetype.STEP_PUSH_TRANSFORM => {
                        transforms[transform_count] = current;
                        transform_count += 1;
                        current = current.then(step.matrix);
                    },
                    truetype.STEP_POP_TRANSFORM => if (transform_count > 0) {
                        transform_count -= 1;
                        current = transforms[transform_count];
                    },
                    truetype.STEP_PUSH_CLIP_GLYPH, truetype.STEP_PUSH_CLIP_BOX => {
                        p.vb.ClearPath(p.path);
                        if (step.kind == truetype.STEP_PUSH_CLIP_GLYPH) {
                            _ = p.addGlyph(outline, step.glyph);
                        } else {
                            p.vb.AddRect(p.path, &.{ .x = step.x0, .y = step.y0, .width = step.x1 - step.x0, .height = step.y1 - step.y0 }, 0, 0);
                        }
                        var box: vector.Rect = .{};
                        if (!p.vb.PathBounds(p.path, &current, &box)) box = .{};
                        boxes[clip_count] = box;
                        clip_count += 1;
                        _ = p.vb.PushClip(p.canvas, p.path, &current, vector.RULE_NONZERO);
                    },
                    truetype.STEP_POP_CLIP => if (clip_count > 0) {
                        clip_count -= 1;
                        p.vb.PopClip(p.canvas);
                    },
                    truetype.STEP_FILL, truetype.STEP_FILL_GLYPH => {
                        const following = steps[at + 1 ..][0..@min(step.stop_count, written - at - 1)];
                        at += @intCast(following.len);
                        var paint = brushOf(step, following, stops, foreground);
                        p.vb.ClearPath(p.path);
                        if (step.kind == truetype.STEP_FILL) {
                            // The box all the clips are in, in pixels.
                            var region: ?vector.Rect = whole;
                            for (boxes[0..clip_count]) |box| region = meet(region orelse break, box);
                            const filled = region orelse continue;
                            if (!(filled.width > 0) or !(filled.height > 0)) continue;
                            p.vb.AddRect(p.path, &filled, 0, 0);
                            paint.matrix = current;
                            _ = p.vb.FillPath(p.canvas, p.path, null, &paint, vector.RULE_NONZERO);
                        } else {
                            if (!p.addGlyph(outline, step.glyph)) continue;
                            paint.matrix = step.matrix;
                            _ = p.vb.FillPath(p.canvas, p.path, &current, &paint, vector.RULE_NONZERO);
                        }
                    },
                    truetype.STEP_PUSH_LAYER => {
                        _ = p.vb.PushBlendLayer(p.canvas, 1, blend_of_compose[@min(step.mode, blend_of_compose.len - 1)]);
                        layer_count += 1;
                    },
                    truetype.STEP_POP_LAYER => if (layer_count > 0) {
                        layer_count -= 1;
                        p.vb.PopLayer(p.canvas);
                    },
                    else => {},
                }
            }
            while (clip_count > 0) : (clip_count -= 1) p.vb.PopClip(p.canvas);
            while (layer_count > 0) : (layer_count -= 1) p.vb.PopLayer(p.canvas);
            p.vb.ClearPath(p.path);
            return true;
        }

        /// The SVG document that draws a glyph, through `placed` - the
        /// font's units, y down, into pixels: the document whole, or of
        /// one for more glyphs its element `glyph` and the glyph's number,
        /// drawn in the styles it inherits and without its parents'
        /// transforms. The span's glyphs before it are painted first.
        /// False for a document that cannot be read, or without that
        /// element.
        fn drawGlyphDocument(p: *P, glyph_document: *const truetype.Document, glyph: u32, placed: Matrix, flush: *const Flush) bool {
            const bytes = glyph_document.bytes orelse return false;
            const opened = p.ext.OpenImageBytes(bytes[0..glyph_document.size]) orelse return false;
            defer p.ext.CloseImage(opened);
            const text = opened.document orelse return false;
            var nested = p.openDocument(text) orelse return false;
            defer p.closeDocument(&nested);
            var element: u32 = 0;
            if (glyph_document.first != glyph_document.last) {
                var name: [16]u8 = undefined;
                const prefix = "glyph";
                @memcpy(name[0..prefix.len], prefix);
                var digits: [10]u8 = undefined;
                var digit_count: usize = 0;
                var rest = glyph;
                while (true) {
                    digits[digit_count] = @intCast('0' + rest % 10);
                    digit_count += 1;
                    rest /= 10;
                    if (rest == 0) break;
                }
                for (0..digit_count) |nth| name[prefix.len + nth] = digits[digit_count - 1 - nth];
                element = nested.doc.byId(name[0 .. prefix.len + digit_count]) orelse return false;
            }
            const path = p.vb.CreatePath() orelse return false;
            defer p.vb.DisposePath(path);
            flush.now(p);
            var inner = P{ .vb = p.vb, .ext = p.ext, .doc = &nested.doc, .canvas = p.canvas, .size = p.size, .path = path, .work = nested.work, .nesting = p.nesting + 1 };
            const parent = nested.doc.nodes[element].parent;
            if (element == 0 or parent == none) {
                inner.walk(placed.then(nested.size.view), nested.size.viewport);
            } else {
                inner.readRules();
                inner.findLoops();
                inner.drawChildren(parent, element, placed, nested.size.viewport);
            }
            inner.closeFaces();
            inner.closeProfile();
            return true;
        }

        /// A glyph's picture drawn through `placed` - the font's units, y
        /// up, into pixels - where the font puts it, smoothly. The span's
        /// glyphs before it are painted first. False for a picture no
        /// datatype reads.
        fn drawGlyphPicture(p: *P, picture: *const truetype.Picture, placed: Matrix, flush: *const Flush) bool {
            const bytes = picture.bytes orelse return false;
            const opened = p.ext.OpenImageBytes(bytes[0..picture.size]) orelse return false;
            defer p.ext.CloseImage(opened);
            if (opened.document != null or opened.width == 0 or opened.height == 0) return false;
            flush.now(p);
            const width = @as(f32, @floatFromInt(opened.width)) * picture.pixel_x;
            const height = @as(f32, @floatFromInt(opened.height)) * picture.pixel_y;
            const top = if (picture.flags & truetype.PICTUREF_BOTTOM != 0) picture.y + height else picture.y;
            // Y down, its top left corner at the top.
            p.drawPicture(&opened, .{ .x = picture.x, .y = -top, .width = width, .height = height }, "none", placed.then(Matrix.scale(1, -1)), 1, false);
            p.vb.ClearPath(p.path);
            return true;
        }

        /// The path filled and stroked as a span's style says - `glyphs`,
        /// in its `paint-order`, and thickened where the font has no bold.
        fn paintRun(p: *P, run: *const Run, matrix: *const Matrix, glyphs: bool, viewport: [2]f32) void {
            // Smoothed as its text-rendering says.
            var own = run.style;
            own.aliased = own.text_aliased;
            const style = &own;
            // In a clip, their shape alone, by its rule.
            if (p.clipping) |rule| {
                const white = vector.Paint{ .colour = .{ .r = 1, .g = 1, .b = 1 } };
                _ = p.vb.FillPath(p.canvas, p.path, matrix, &white, rule);
                if (glyphs and run.thicken > 0) {
                    const thicker = vector.Stroke{ .width = run.thicken, .join = vector.JOIN_ROUND };
                    _ = p.vb.StrokePath(p.canvas, p.path, matrix, &white, &thicker);
                }
                return;
            }
            const stroked = style.stroke != .none and style.stroke_width.resolveAt(.other, viewport, style.font_size) > 0;
            const stroke_first = glyphs and style.stroke_first;
            if (stroked and stroke_first) p.strokeShape(style, matrix, 1, viewport);
            if (style.fill != .none) {
                const mark = p.picture_count;
                defer p.freePictures(mark);
                if (p.paintOf(style.fill, style.fill_opacity, style, matrix, viewport)) |paint| {
                    _ = p.vb.FillPath(p.canvas, p.path, matrix, &paint, vector.RULE_NONZERO);
                    if (glyphs and run.thicken > 0) {
                        const thicker = vector.Stroke{ .width = run.thicken, .join = vector.JOIN_ROUND };
                        _ = p.vb.StrokePath(p.canvas, p.path, matrix, &paint, &thicker);
                    }
                }
            }
            if (stroked and !stroke_first) p.strokeShape(style, matrix, 1, viewport);
        }

        /// The lines of decoration `kind` - `line_under`, `line_through`
        /// or `line_over` - of the clusters `start` to `end`, of one span,
        /// where its font has them: added to the path, or with `box` the
        /// box widened by them through `outer`. A line breaks where a
        /// cluster is placed apart from the one before. False for none.
        fn decorate(p: *P, start: u32, end: u32, kind: usize, box: ?*?vector.Rect, outer: Matrix) bool {
            const work = p.work;
            const run = &work.runs[work.clusters[start].run];
            if (run.lines[kind] == no_run) return false;
            const height = run.ascent - run.descent;
            const offset = if (run.vertical) switch (kind) {
                line_under => height / 2,
                line_over => -height / 2,
                else => 0,
            } else switch (kind) {
                line_under => -run.under,
                line_over => -run.ascent,
                else => -run.strike,
            };
            const top = offset - run.thickness / 2;
            const bottom = offset + run.thickness / 2;
            if (!(run.thickness > 0)) return false;
            var any = false;
            var at = start;
            while (at < end) {
                const head = &work.clusters[at];
                var width = head.advance;
                var next = at + 1;
                while (next < end and !work.clusters[next].apart) : (next += 1) width += work.clusters[next].advance;
                defer at = next;
                if (head.hidden or !(width > 0)) continue;
                const corners = [4]vector.Point{ .{ .x = 0, .y = top }, .{ .x = width, .y = top }, .{ .x = width, .y = bottom }, .{ .x = 0, .y = bottom } };
                if (box) |widened| {
                    for (corners) |corner| widened.* = unite(widened.*, pointBox(outer.then(head.matrix).apply(corner)));
                } else {
                    var placed: [4]vector.Point = undefined;
                    for (corners, &placed) |corner, *point| point.* = head.matrix.apply(corner);
                    const verbs = [5]u8{ vector.SEG_MOVE, vector.SEG_LINE, vector.SEG_LINE, vector.SEG_LINE, vector.SEG_CLOSE };
                    _ = p.vb.AddSegments(p.path, &verbs, verbs.len, &placed, placed.len);
                }
                any = true;
            }
            return any;
        }

        /// The box of a `text`'s glyphs in its units, through `m`.
        fn textBounds(p: *P, node: u32, m: Matrix, style: *const Style, viewport: [2]f32) ?vector.Rect {
            return p.layOut(node, style, viewport, m).box;
        }

        // --- images -------------------------------------------------------------------

        /// An `image` drawn in its place: its picture, or the SVG document
        /// its address holds.
        fn drawImage(p: *P, node: u32, top: *const Frame) void {
            const style = p.styleOf(node, &top.style);
            if (!style.shown or !style.visible) return;
            p.em = style.font_size;
            const href = p.doc.get(node, .href) orelse return;
            const picture = p.openImage(href) orelse return;
            defer p.ext.CloseImage(picture);
            const viewport = top.viewport;
            var size = [2]f32{ @floatFromInt(picture.width), @floatFromInt(picture.height) };
            var nested: ?Nested = null;
            defer if (nested) |*opened| p.closeDocument(opened);
            if (picture.document) |text| {
                nested = p.openDocument(text) orelse return;
                size = .{ nested.?.size.width, nested.?.size.height };
            }
            // Without a width or a height, the picture's own (SVG 2).
            const place = p.imageRect(node, viewport, size[0], size[1]) orelse return;
            const matrix = top.matrix.then(p.ownTransform(node, viewport));
            const t = p.through(node, &style, matrix, viewport);
            defer for (0..t.clips) |_| p.vb.PopClip(p.canvas);
            if (t.hidden) return;
            const aspect = p.doc.get(node, .preserveAspectRatio) orelse "";
            // A document's shapes may overlap: its opacity on a layer.
            const layered = layerFor(&t, &style, nested != null);
            if (layered) p.pushLayer(&style);
            const straight = if (t.filtered) p.straighten(node, &style, matrix, viewport) else null;
            const drawn = if (straight) |aside| aside.into.then(matrix) else matrix;
            if (nested) |*opened| {
                p.drawDocument(opened, place, aspect, drawn);
            } else p.drawPicture(&picture, place, aspect, drawn, if (layered) 1 else style.opacity, style.nearest);
            if (layered) {
                if (straight) |aside| {
                    p.putStraight(aside, node, matrix, &style, viewport);
                } else if (t.filtered) p.runFilters(node, matrix, &style, viewport);
                p.vb.PopLayer(p.canvas);
            }
        }

        /// An SVG document an `image` draws: its tree, its size as a
        /// picture, and the room they and its work block are in.
        const Nested = struct { room: Room, grown: ?Room, doc: Document, work: *Work, size: Intrinsic };

        /// The picture an address holds, through `ext`: a document an
        /// `image` draws has its `data:` addresses alone.
        fn openImage(p: *P, href: []const u8) ?Image {
            if (p.nesting != 0 and data.payloadOf(href) == null) return null;
            return p.ext.OpenImage(href);
        }

        /// `text` read into a tree to draw; null for text that is not an
        /// SVG document, too deep inside others, or without the room.
        fn openDocument(p: *P, given: []u8) ?Nested {
            if (p.nesting + 1 >= max_nesting) return null;
            // The entities its DOCTYPE declares put in.
            var text = given;
            var grown: ?Room = null;
            if (entity.declared(given)) |declared| {
                if (entity.expandedSize(given, &declared)) |size| {
                    const room = p.ext.AllocRoom(@max(size, 1)) orelse return null;
                    grown = room;
                    text = entity.expand(given, &declared, room[0..size]);
                }
            }
            const counts = document.count(text) orelse {
                if (grown) |room| p.ext.FreeRoom(room);
                return null;
            };
            const doc_bytes = document.bytesFor(counts);
            // The tree eight aligned, then the work block.
            const room = p.ext.AllocRoom(doc_bytes + 8 + @sizeOf(Work) + @alignOf(Work)) orelse {
                if (grown) |held| p.ext.FreeRoom(held);
                return null;
            };
            const tree_at = (@intFromPtr(room.ptr) + 7) & ~@as(usize, 7);
            const tree: [*]align(8) u8 = @ptrFromInt(tree_at);
            const doc = document.build(text, counts, tree[0..doc_bytes]);
            const work_at = (tree_at + doc_bytes + @alignOf(Work) - 1) & ~@as(usize, @alignOf(Work) - 1);
            return .{ .room = room, .grown = grown, .doc = doc, .work = @ptrFromInt(work_at), .size = intrinsic(&doc) };
        }

        fn closeDocument(p: *P, nested: *Nested) void {
            p.ext.FreeRoom(nested.room);
            if (nested.grown) |room| p.ext.FreeRoom(room);
        }

        /// A document drawn into `place` - in the units `matrix` takes to
        /// pixels - fitted as `aspect` says, as a picture its size is:
        /// its own painter on the same canvas, with its own path; cut to
        /// its place when sliced.
        fn drawDocument(p: *P, nested: *const Nested, place: vector.Rect, aspect: []const u8, matrix: Matrix) void {
            const size = nested.size;
            const fit = Matrix.translate(place.x, place.y).then(viewBoxMatrix(.{ .width = size.width, .height = size.height }, aspect, place.width, place.height));
            var clips: u8 = 0;
            defer for (0..clips) |_| p.vb.PopClip(p.canvas);
            if (sliced(aspect)) {
                p.vb.ClearPath(p.path);
                p.vb.AddRect(p.path, &place, 0, 0);
                if (p.vb.PushClip(p.canvas, p.path, &matrix, vector.RULE_NONZERO) == vector.VECTOR_OK) clips = 1;
            }
            const path = p.vb.CreatePath() orelse return;
            defer p.vb.DisposePath(path);
            var inner = P{ .vb = p.vb, .ext = p.ext, .doc = &nested.doc, .canvas = p.canvas, .size = p.size, .path = path, .work = nested.work, .nesting = p.nesting + 1 };
            inner.walk(matrix.then(fit).then(size.view), size.viewport);
            inner.closeFaces();
            inner.closeProfile();
        }

        /// A picture drawn into `place` - in the units `matrix` takes to
        /// pixels - fitted as `aspect`, a `preserveAspectRatio`, says; read
        /// at the nearest pixel, or smoothly.
        fn drawPicture(p: *P, picture: *const Image, place: vector.Rect, aspect: []const u8, matrix: Matrix, opacity: f32, nearest: bool) void {
            const iw: f32 = @floatFromInt(picture.width);
            const ih: f32 = @floatFromInt(picture.height);
            const fit = Matrix.translate(place.x, place.y).then(viewBoxMatrix(.{ .width = iw, .height = ih }, aspect, place.width, place.height));
            // Where it lands, inside its place: a sliced one is cut to it.
            const landed = boxThrough(fit, .{ .width = iw, .height = ih });
            const left = @max(landed.x, place.x);
            const right = @min(landed.x + landed.width, place.x + place.width);
            const upper = @max(landed.y, place.y);
            const lower = @min(landed.y + landed.height, place.y + place.height);
            if (!(right > left) or !(lower > upper)) return;
            p.vb.ClearPath(p.path);
            p.vb.AddRect(p.path, &.{ .x = left, .y = upper, .width = right - left, .height = lower - upper }, 0, 0);
            const paint = vector.Paint{
                .kind = vector.PAINT_IMAGE,
                .opacity = opacity,
                .image = picture.pens,
                .image_width = picture.width,
                .image_height = picture.height,
                .image_bytes_per_row = picture.bytes_per_row,
                .matrix = fit,
                .flags = if (nearest) vector.PAINTF_NEAREST else 0,
            };
            _ = p.vb.FillPath(p.canvas, p.path, &matrix, &paint, vector.RULE_NONZERO);
        }

        /// An `image`'s place: its `x`, `y`, `width` and `height`, a side not
        /// given the picture's own, or the other's in its shape. Null for
        /// one of no size.
        fn imageRect(p: *P, node: u32, viewport: [2]f32, iw: f32, ih: f32) ?vector.Rect {
            var w = p.optionalLength(node, .width, .x, viewport);
            var h = p.optionalLength(node, .height, .y, viewport);
            if (w == null and h == null) {
                w = iw;
                h = ih;
            } else if (w == null) {
                w = h.? * iw / ih;
            } else if (h == null) {
                h = w.? * ih / iw;
            }
            if (!(w.? > 0) or !(h.? > 0)) return null;
            return .{ .x = p.lengthOf(node, .x, .x, viewport, 0), .y = p.lengthOf(node, .y, .y, viewport, 0), .width = w.?, .height = h.? };
        }

        // --- clips and masks ------------------------------------------------------

        /// The element a `clip-path` or a `mask` names, if it is one of
        /// `tag`.
        fn referenced(p: *P, text: []const u8, tag: Tag) ?u32 {
            const named = values.paint(text) orelse return null;
            if (named != .url) return null;
            const node = p.doc.byId(named.url.id) orelse return null;
            return if (p.doc.nodes[node].tag == tag) node else null;
        }

        /// Whether a `clipPathUnits`, `maskUnits` or `maskContentUnits` says
        /// the box's units.
        fn boxUnits(p: *P, node: u32, name: Name, default: bool) bool {
            const text = values.trim(p.doc.get(node, name) orelse return default);
            if (std.mem.eql(u8, text, "objectBoundingBox")) return true;
            if (std.mem.eql(u8, text, "userSpaceOnUse")) return false;
            return default;
        }

        /// A clip that lets nothing through, pushed.
        fn clipAll(p: *P) u8 {
            p.vb.ClearPath(p.path);
            _ = p.vb.PushClip(p.canvas, p.path, null, vector.RULE_NONZERO);
            return 1;
        }

        /// The `clipPath` `text` names pushed for `node`, drawn through
        /// `space`; how many pops that owes. None for one that is not
        /// there.
        fn clipBy(p: *P, text: []const u8, node: u32, space: Matrix, viewport: [2]f32) u8 {
            const clip = p.referenced(text, .clipPath) orelse return 0;
            if (p.references >= max_references) return 0;
            p.references += 1;
            defer p.references -= 1;
            const style = p.styleChain(clip);
            var owed: u8 = 0;
            // A clipPath clipped itself.
            if (style.clip.len != 0) owed += p.clipBy(style.clip, node, space, viewport);
            var m = space.then(p.transformOf(clip, .transform, viewport));
            if (p.boxUnits(clip, .clipPathUnits, false)) {
                const box = p.boundsOf(node, viewport) orelse return owed + p.clipAll();
                m = m.then(boxMatrix(box));
            }
            var count: u32 = 0;
            var only: Piece = undefined;
            var child = p.doc.nodes[clip].first_child;
            while (child != none) : (child = p.doc.nodes[child].next) {
                const piece = p.pieceOf(child, &style, viewport) orelse continue;
                count += 1;
                only = piece;
            }
            if (count == 0) return owed + p.clipAll();
            if (count == 1 and only.style.clip.len == 0 and p.doc.nodes[only.node].tag != .text) {
                if (!p.buildShape(only.node, viewport)) return owed + p.clipAll();
                const at = m.then(only.matrix);
                _ = p.vb.PushClip(p.canvas, p.path, &at, only.style.clip_rule);
                return owed + 1;
            }
            // More than one, or one clipped itself: their coverage.
            _ = p.vb.BeginMask(p.canvas);
            child = p.doc.nodes[clip].first_child;
            const white = vector.Paint{ .colour = .{ .r = 1, .g = 1, .b = 1 } };
            while (child != none) : (child = p.doc.nodes[child].next) {
                const piece = p.pieceOf(child, &style, viewport) orelse continue;
                const at = m.then(piece.matrix);
                const own = if (piece.style.clip.len != 0) p.clipBy(piece.style.clip, piece.node, at, viewport) else 0;
                if (p.doc.nodes[piece.node].tag == .text) {
                    // Its glyphs, laid out from where it is: inside the
                    // clip, or the `use` that names it.
                    const parent = if (piece.node == child) style else p.styleOf(child, &style);
                    var frame = Frame{ .node = child, .style = parent, .matrix = m.then(piece.around), .viewport = viewport };
                    p.clipping = piece.style.clip_rule;
                    p.drawText(piece.node, &frame);
                    p.clipping = null;
                } else if (p.buildShape(piece.node, viewport)) _ = p.vb.FillPath(p.canvas, p.path, &at, &white, piece.style.clip_rule);
                for (0..own) |_| p.vb.PopClip(p.canvas);
            }
            _ = p.vb.EndMask(p.canvas, vector.MASK_ALPHA);
            return owed + 1;
        }

        /// A shape or a text a `clipPath` is made of: the element, its
        /// style, its units in the clip's, and what its own transform is
        /// inside: a `use`'s, or none.
        const Piece = struct { node: u32, style: Style, matrix: Matrix, around: Matrix = .{} };

        /// A child of a `clipPath` as a piece of it - a shape, a text, or
        /// a `use` of one - or null for what is no part of it.
        fn pieceOf(p: *P, child: u32, clip_style: *const Style, viewport: [2]f32) ?Piece {
            const tag = p.doc.nodes[child].tag;
            var style = p.styleOf(child, clip_style);
            if (!style.shown or !style.visible) return null;
            var matrix = p.ownTransform(child, viewport);
            var node = child;
            var around = Matrix{};
            if (tag == .use) {
                const target = p.doc.byHref(p.doc.get(child, .href) orelse return null) orelse return null;
                const target_tag = p.doc.nodes[target].tag;
                if (!isShape(target_tag) and target_tag != .text) return null;
                const own_clip = style.clip;
                style = p.styleOf(target, &style);
                if (!style.shown or !style.visible) return null;
                if (style.clip.len == 0) style.clip = own_clip;
                around = matrix;
                matrix = matrix.then(p.transformOf(target, .transform, viewport));
                node = target;
            } else if (!isShape(tag) and tag != .text) return null;
            return .{ .node = node, .style = style, .matrix = matrix, .around = around };
        }

        /// The `mask` `text` names pushed for `node`, drawn through
        /// `space`; how many pops that owes. None for one that is not
        /// there.
        fn maskBy(p: *P, text: []const u8, node: u32, space: Matrix, viewport: [2]f32) u8 {
            const mask = p.referenced(text, .mask) orelse return 0;
            if (p.references >= max_references or p.depth + 1 >= max_depth) return 0;
            p.references += 1;
            defer p.references -= 1;
            var style = p.styleChain(mask);
            const box_units = p.boxUnits(mask, .maskUnits, true);
            const content_box = p.boxUnits(mask, .maskContentUnits, false);
            var box: vector.Rect = .{};
            if (box_units or content_box) {
                box = p.boundsOf(node, viewport) orelse return p.clipAll();
            }
            // Its region: by default a tenth of the box more each way.
            const region = p.regionOf(mask, box_units, box, viewport);
            if (!(region.width > 0) or !(region.height > 0)) return p.clipAll();
            _ = p.vb.BeginMask(p.canvas);
            p.vb.ClearPath(p.path);
            p.vb.AddRect(p.path, &region, 0, 0);
            _ = p.vb.PushClip(p.canvas, p.path, &space, vector.RULE_NONZERO);
            // A mask masked itself, as SVG 2 has it.
            const inner: u8 = if (style.mask.len != 0) p.maskBy(style.mask, node, space, viewport) else 0;
            const alpha = style.mask_alpha;
            style.opacity = 1;
            style.shown = true;
            style.filter = "";
            style.clip = "";
            style.mask = "";
            const content = if (content_box) space.then(boxMatrix(box)) else space;
            const saved = p.depth;
            const frames = &p.work.frames;
            frames[saved + 1] = .{ .node = mask, .style = style, .matrix = content, .viewport = viewport };
            p.drawFrom(saved + 1);
            p.depth = saved;
            for (0..inner) |_| p.vb.PopClip(p.canvas);
            p.vb.PopClip(p.canvas);
            // Its luminance of the colours in linear light, for a mask of
            // `color-interpolation: linearRGB`.
            const linear: u32 = if (style.linear_gradients) vector.MASK_LINEARRGB else 0;
            _ = p.vb.EndMask(p.canvas, if (alpha) vector.MASK_ALPHA else vector.MASK_LUMINANCE | linear);
            return 1;
        }

        // --- the box of what an element draws ---------------------------------------

        /// The box of what `node` draws - its shapes' geometry, not their
        /// strokes - in its own units; null for nothing. The path is
        /// built in for it.
        fn boundsOf(p: *P, node: u32, viewport: [2]f32) ?vector.Rect {
            const style = p.styleChain(node);
            const box = p.boundsIn(node, .{}, &style, viewport, 0) orelse return null;
            if (!(box.width > 0) or !(box.height > 0)) return null;
            return box;
        }

        /// The box of what `node` draws through `m`, its style `style`.
        fn boundsIn(p: *P, node: u32, m: Matrix, style: *const Style, viewport: [2]f32, depth: u32) ?vector.Rect {
            if (depth >= max_depth) return null;
            const tag = p.doc.nodes[node].tag;
            if (isShape(tag)) {
                if (!p.buildShape(node, viewport)) return null;
                var box: vector.Rect = undefined;
                return if (p.vb.PathBounds(p.path, &m, &box)) box else null;
            }
            if (tag == .text) return p.textBounds(node, m, style, viewport);
            if (tag == .image) {
                // Its place, as a picture of its shape, unknown here, has it.
                const w = p.optionalLength(node, .width, .x, viewport) orelse return null;
                const h = p.optionalLength(node, .height, .y, viewport) orelse return null;
                if (!(w > 0) or !(h > 0)) return null;
                return boxThrough(m, .{ .x = p.lengthOf(node, .x, .x, viewport, 0), .y = p.lengthOf(node, .y, .y, viewport, 0), .width = w, .height = h });
            }
            var content = m;
            var inner = viewport;
            var first = p.doc.nodes[node].first_child;
            var single = false;
            switch (tag) {
                .g, .a, .@"switch", .mask, .clipPath => {},
                .svg => if (node != 0) {
                    const view = p.viewportOf(node, none, viewport) orelse return null;
                    content = view.matrix(m);
                    inner = view.inner;
                },
                .use => {
                    const target = p.doc.byHref(p.doc.get(node, .href) orelse return null) orelse return null;
                    if (target == node) return null;
                    first = target;
                    single = true;
                },
                else => return null,
            }
            var all: ?vector.Rect = null;
            var child = first;
            while (child != none) : (child = if (single) none else p.doc.nodes[child].next) {
                const child_style = p.styleOf(child, style);
                if (!child_style.shown) continue;
                var at = content.then(p.ownTransform(child, inner));
                var child_inner = inner;
                const child_tag = p.doc.nodes[child].tag;
                if (child_tag == .symbol) {
                    if (!single) continue;
                    const view = p.viewportOf(child, node, inner) orelse continue;
                    at = view.matrix(at);
                    child_inner = view.inner;
                    var grandchild = p.doc.nodes[child].first_child;
                    while (grandchild != none) : (grandchild = p.doc.nodes[grandchild].next) {
                        const grand_style = p.styleOf(grandchild, &child_style);
                        if (!grand_style.shown) continue;
                        const each = p.boundsIn(grandchild, at.then(p.ownTransform(grandchild, child_inner)), &grand_style, child_inner, depth + 2);
                        all = unite(all, each);
                    }
                    continue;
                }
                all = unite(all, p.boundsIn(child, at, &child_style, child_inner, depth + 1));
                if (tag == .@"switch" and drawable(child_tag)) break;
            }
            return all;
        }

        /// A `polyline`'s or a `polygon`'s points onto the path, a chunk
        /// at a time; false for none. A number without its pair ends it.
        fn points(p: *P, node: u32) bool {
            var s = values.Scanner{ .text = p.doc.get(node, .points) orelse return false };
            const work = p.work;
            var any = false;
            while (true) {
                var n: u32 = 0;
                while (n < chunk) : (n += 1) {
                    s.skipSeparator();
                    const x = s.number() orelse break;
                    s.skipSeparator();
                    const y = s.number() orelse break;
                    work.points[n] = .{ .x = x, .y = y };
                    work.verbs[n] = if (!any and n == 0) vector.SEG_MOVE else vector.SEG_LINE;
                }
                if (n == 0) return any;
                _ = p.vb.AddSegments(p.path, &work.verbs, n, &work.points, n);
                any = true;
                if (n < chunk) return true;
            }
        }

        fn strokeOf(p: *P, style: *const Style, viewport: [2]f32) vector.Stroke {
            var stroke = vector.Stroke{
                .width = style.stroke_width.resolveAt(.other, viewport, style.font_size),
                .join = style.join,
                .cap = style.cap,
                .miter_limit = style.miter_limit,
            };
            if (style.dashes.len == 0) return stroke;
            var s = values.Scanner{ .text = style.dashes };
            var n: u32 = 0;
            while (n < max_dashes) {
                s.skipSeparator();
                if (s.at >= s.text.len) break;
                const l = values.lengthAt(&s) orelse return stroke;
                p.work.dashes[n] = l.resolveAt(.other, viewport, style.font_size);
                n += 1;
            }
            if (n == 0) return stroke;
            stroke.dashes = &p.work.dashes;
            stroke.dash_count = n;
            stroke.dash_offset = style.dash_offset.resolveAt(.other, viewport, style.font_size);
            return stroke;
        }

        // --- paints ---------------------------------------------------------------

        /// The paint for `which` on the path, drawn through `matrix`, or
        /// null for none. A pattern's picture is held until the caller's
        /// `freePictures`.
        /// The box a paint of the box's units is of: the text's being
        /// drawn, or the path's.
        fn paintBox(p: *P, box: *vector.Rect) bool {
            if (p.paint_box) |given| {
                box.* = given;
                return true;
            }
            return p.vb.PathBounds(p.path, null, box);
        }

        fn paintOf(p: *P, which: values.Paint, opacity: f32, style: *const Style, matrix: *const Matrix, viewport: [2]f32) ?vector.Paint {
            var paint = p.basePaint(which, opacity, style, matrix, viewport) orelse return null;
            if (style.aliased) paint.flags |= vector.PAINTF_ALIASED;
            return paint;
        }

        fn basePaint(p: *P, which: values.Paint, opacity: f32, style: *const Style, matrix: *const Matrix, viewport: [2]f32) ?vector.Paint {
            return switch (which) {
                .none => null,
                .colour => |c| .{ .colour = c, .opacity = opacity },
                .current => .{ .colour = style.colour, .opacity = opacity },
                .context_fill, .context_stroke => p.contextPaint(which == .context_fill, opacity, matrix),
                .url => |url| {
                    // A paint server that comes to nothing - no stops, no
                    // size, the box of a path of none - is its fallback.
                    if (p.doc.byId(url.id)) |node| {
                        const tag = p.doc.nodes[node].tag;
                        if (tag == .linearGradient or tag == .radialGradient) {
                            if (p.gradientOf(node, opacity, viewport)) |made| return made;
                        } else if (tag == .pattern) {
                            if (p.patternOf(node, opacity, matrix.*, viewport)) |made| return made;
                        } else return null;
                    }
                    return switch (url.fallback) {
                        .colour => |c| .{ .colour = c, .opacity = opacity },
                        .current => .{ .colour = style.colour, .opacity = opacity },
                        .none, .absent => null,
                    };
                },
            };
        }

        /// `context-fill` - `fill` - or `context-stroke`: the fill or the
        /// stroke of the context element - the shape whose marker is
        /// drawn, or the nearest `use` drawing the element - in that
        /// element's units, its box the box of a paint of the box's units,
        /// and taken into the units of the shape drawn through `matrix`.
        /// A context paint of the context element's is its own context's.
        /// Null outside any context.
        fn contextPaint(p: *P, fill: bool, opacity: f32, matrix: *const Matrix) ?vector.Paint {
            var context = p.contextAt(p.depth, p.marker_depth) orelse return null;
            var wants_fill = fill;
            var faded = opacity;
            var hops: u32 = 0;
            while (true) : (hops += 1) {
                const style = context.style;
                const paint = if (wants_fill) style.fill else style.stroke;
                faded *= if (wants_fill) style.fill_opacity else style.stroke_opacity;
                switch (paint) {
                    .context_fill, .context_stroke => {
                        if (hops == max_depth) return null;
                        wants_fill = paint == .context_fill;
                        context = p.outerContext(&context) orelse return null;
                        continue;
                    },
                    else => {},
                }
                const back = matrix.invert() orelse return null;
                const saved_box = p.paint_box;
                defer p.paint_box = saved_box;
                if (paint == .url) p.paint_box = p.contextBox(&context);
                var made = p.basePaint(paint, faded, style, &context.matrix, context.viewport) orelse return null;
                made.matrix = back.then(context.matrix).then(made.matrix);
                return made;
            }
        }

        /// The context element nearest frame `depth`, with `level`
        /// markers open: the innermost marker's shape, when the frames
        /// from `depth` out leave its content before they come to a `use`.
        fn contextAt(p: *P, depth: usize, level: u32) ?Context {
            var at = depth + 1;
            while (at > 0) {
                at -= 1;
                if (level > 0 and at < p.marked[level - 1].base) return p.markerContext(level - 1);
                const frame = &p.work.frames[at];
                if (frame.use != none and p.doc.nodes[frame.node].tag == .use) {
                    return .{ .style = &frame.style, .matrix = frame.matrix, .node = frame.node, .viewport = frame.viewport, .depth = at, .level = level };
                }
            }
            return if (level > 0) p.markerContext(level - 1) else null;
        }

        fn markerContext(p: *P, index: u32) Context {
            const marked = &p.marked[index];
            return .{ .style = marked.style, .matrix = marked.matrix, .node = marked.node, .viewport = marked.viewport, .depth = marked.base - 1, .level = index };
        }

        /// The context of a context element's own: a marker's shape's is
        /// the context of the frame it is drawn in, a `use`'s the one
        /// nearest the frame outside it.
        fn outerContext(p: *P, context: *const Context) ?Context {
            if (p.doc.nodes[context.node].tag == .use) {
                if (context.depth == 0) return if (context.level > 0) p.markerContext(context.level - 1) else null;
                return p.contextAt(context.depth - 1, context.level);
            }
            return p.contextAt(context.depth, context.level);
        }

        /// The box of what a context element draws, in its units.
        fn contextBox(p: *P, context: *const Context) ?vector.Rect {
            const saved = p.ownPath() orelse return null;
            defer p.pathBack(saved);
            return p.boundsOf(context.node, context.viewport);
        }

        /// A `pattern`: its tile drawn aside, as many pixels as it covers
        /// through `matrix`, and painted again and again. What it leaves
        /// out comes from the patterns its `href` names, its content from
        /// the first with any. Null for one of no size, of nothing, or of
        /// the box of a path of none.
        fn patternOf(p: *P, start: u32, opacity: f32, matrix: Matrix, viewport: [2]f32) ?vector.Paint {
            const doc = p.doc;
            const names = [_]Name{ .x, .y, .width, .height, .patternUnits, .patternContentUnits, .patternTransform, .viewBox, .preserveAspectRatio };
            var found: [names.len]?[]const u8 = @splat(null);
            var content: u32 = none;
            var node = start;
            var hops: u32 = 0;
            while (true) {
                for (names, &found) |name, *slot| {
                    if (slot.* == null) {
                        if (doc.get(node, name)) |text| {
                            if (patternValue(name, text)) slot.* = text;
                        }
                    }
                }
                if (content == none and doc.nodes[node].first_child != none) content = node;
                hops += 1;
                if (hops > max_hops) break;
                const next = doc.byHref(doc.get(node, .href) orelse break) orelse break;
                if (doc.nodes[next].tag != .pattern) break;
                node = next;
            }
            if (content == none) return null;
            const box_units = if (found[4]) |given| !std.mem.eql(u8, values.trim(given), "userSpaceOnUse") else true;
            const content_box = if (found[5]) |given| std.mem.eql(u8, values.trim(given), "objectBoundingBox") else false;
            var box: vector.Rect = .{};
            if (box_units or content_box) {
                if (!p.paintBox(&box) or !(box.width > 0) or !(box.height > 0)) return null;
            }
            var tile: vector.Rect = undefined;
            const axes = [4]values.Axis{ .x, .y, .x, .y };
            var sides: [4]f32 = undefined;
            for (found[0..4], axes, &sides) |text, axis, *side| {
                const length = (if (text) |given| values.length(given) else null) orelse Length{ .value = 0 };
                side.* = if (box_units) (if (length.percent) length.value / 100 else length.value) else length.resolve(axis, viewport);
            }
            tile = .{ .x = sides[0], .y = sides[1], .width = sides[2], .height = sides[3] };
            if (box_units) tile = .{ .x = box.x + tile.x * box.width, .y = box.y + tile.y * box.height, .width = tile.width * box.width, .height = tile.height * box.height };
            if (!(tile.width > 0) or !(tile.height > 0)) return null;
            const transform = p.aroundOrigin(node, serverTransform(found[6]), viewport);
            // As many pixels as the tile covers.
            const stretch = filter_.stretchOf(matrix.then(transform));
            const wide = @round(tile.width * stretch[0]);
            const high = @round(tile.height * stretch[1]);
            if (!(wide >= 1) or !(high >= 1) or wide > max_side or high > max_side) return null;
            const width: u32 = @intFromFloat(wide);
            const height: u32 = @intFromFloat(high);
            const sx = wide / tile.width;
            const sy = high / tile.height;
            var inside = Matrix.scale(sx, sy);
            var inner = viewport;
            if (viewBox(found[7])) |view| {
                inside = inside.then(viewBoxMatrix(view, found[8] orelse "", tile.width, tile.height));
                inner = .{ view.width, view.height };
            } else if (content_box) inside = inside.then(Matrix.scale(box.width, box.height));
            const aside = p.beginAside(width, height, true) orelse return null;
            p.drawChildren(content, none, inside, inner);
            const room = p.endAside(aside);
            if (!p.holdPicture(room)) return null;
            return .{
                .kind = vector.PAINT_IMAGE,
                .opacity = opacity,
                .image = @ptrCast(@alignCast(room.ptr)),
                .image_width = width,
                .image_height = height,
                .image_bytes_per_row = width * @sizeOf(graphics.Pen),
                .spread = vector.SPREAD_REPEAT,
                .matrix = transform.then(Matrix.translate(tile.x, tile.y)).then(Matrix.scale(1 / sx, 1 / sy)),
            };
        }

        /// A gradient, what it leaves out taken from the ones its `href`
        /// names; null where it paints nothing. Its colours are mixed as
        /// its own `color-interpolation` says, which it inherits from the
        /// elements around it, not from those its `href` names.
        fn gradientOf(p: *P, start: u32, opacity: f32, viewport: [2]f32) ?vector.Paint {
            const doc = p.doc;
            const radial = doc.nodes[start].tag == .radialGradient;
            var found: [@typeInfo(Name).@"enum".fields.len]?[]const u8 = @splat(null);
            var stops_from: u32 = none;
            var node = start;
            var hops: u32 = 0;
            while (true) {
                const tag = doc.nodes[node].tag;
                for (doc.attributesOf(node)) |a| {
                    const own = switch (a.name) {
                        .gradientUnits, .gradientTransform, .spreadMethod => true,
                        .x1, .y1, .x2, .y2 => tag == .linearGradient and !radial,
                        .cx, .cy, .r, .fx, .fy, .fr => tag == .radialGradient and radial,
                        else => false,
                    };
                    // One in error is not there: the next one names it.
                    if (own and found[@intFromEnum(a.name)] == null and gradientValue(a.name, a.value)) found[@intFromEnum(a.name)] = a.value;
                }
                if (stops_from == none and p.hasStops(node)) stops_from = node;
                hops += 1;
                if (hops > max_hops) break;
                const next = doc.byHref(doc.get(node, .href) orelse break) orelse break;
                const next_tag = doc.nodes[next].tag;
                if (next_tag != .linearGradient and next_tag != .radialGradient) break;
                node = next;
            }
            const stop_count = p.stopsOf(stops_from);
            if (stop_count == 0) return null;
            const get = struct {
                fn get(f: *const [@typeInfo(Name).@"enum".fields.len]?[]const u8, name: Name) ?[]const u8 {
                    return f[@intFromEnum(name)];
                }
            }.get;

            const box_units = if (get(&found, .gradientUnits)) |u| !std.mem.eql(u8, values.trim(u), "userSpaceOnUse") else true;
            var matrix = p.aroundOrigin(start, serverTransform(get(&found, .gradientTransform)), viewport);
            if (box_units) {
                var box: vector.Rect = undefined;
                if (!p.paintBox(&box) or !(box.width > 0) or !(box.height > 0)) return null;
                matrix = (Matrix{ .a = box.width, .d = box.height, .e = box.x, .f = box.y }).then(matrix);
            }
            var paint = vector.Paint{
                .kind = if (radial) vector.PAINT_RADIAL else vector.PAINT_LINEAR,
                .opacity = opacity,
                .stops = &p.work.stops,
                .stop_count = stop_count,
                .matrix = matrix,
                .flags = if (p.styleChain(start).linear_gradients) vector.PAINTF_LINEARRGB else 0,
            };
            if (get(&found, .spreadMethod)) |spread| {
                const word = values.trim(spread);
                if (std.mem.eql(u8, word, "reflect")) paint.spread = vector.SPREAD_REFLECT;
                if (std.mem.eql(u8, word, "repeat")) paint.spread = vector.SPREAD_REPEAT;
            }
            const coordinate = struct {
                fn of(text: ?[]const u8, box: bool, axis: values.Axis, vp: [2]f32, default: Length) f32 {
                    const l = (if (text) |t| values.length(t) else null) orelse default;
                    if (box) return if (l.percent) l.value / 100 else l.value;
                    return l.resolve(axis, vp);
                }
            }.of;
            if (!radial) {
                paint.x1 = coordinate(get(&found, .x1), box_units, .x, viewport, .{ .value = 0 });
                paint.y1 = coordinate(get(&found, .y1), box_units, .y, viewport, .{ .value = 0 });
                paint.x2 = coordinate(get(&found, .x2), box_units, .x, viewport, .{ .value = 100, .percent = true });
                paint.y2 = coordinate(get(&found, .y2), box_units, .y, viewport, .{ .value = 0 });
            } else {
                const half = Length{ .value = 50, .percent = true };
                paint.cx = coordinate(get(&found, .cx), box_units, .x, viewport, half);
                paint.cy = coordinate(get(&found, .cy), box_units, .y, viewport, half);
                paint.r = coordinate(get(&found, .r), box_units, .other, viewport, half);
                paint.fx = if (get(&found, .fx)) |t| coordinate(t, box_units, .x, viewport, half) else paint.cx;
                paint.fy = if (get(&found, .fy)) |t| coordinate(t, box_units, .y, viewport, half) else paint.cy;
                paint.fr = coordinate(get(&found, .fr), box_units, .other, viewport, .{ .value = 0 });
                // A focus outside the circle makes a cone, as SVG 2 has it.
                if (!(paint.r > 0)) return lastStop(&paint);
            }
            return paint;
        }

        /// A gradient of no size: its last stop's colour.
        fn lastStop(paint: *const vector.Paint) vector.Paint {
            const last = paint.stops.?[paint.stop_count - 1].colour;
            return .{ .colour = last, .opacity = paint.opacity };
        }

        fn hasStops(p: *P, node: u32) bool {
            var child = p.doc.nodes[node].first_child;
            while (child != none) : (child = p.doc.nodes[child].next) {
                if (p.doc.nodes[child].tag == .stop) return true;
            }
            return false;
        }

        /// The stops of the gradient `node` into the work's; how many. A
        /// stop's `currentColor` is its own `color`, which it inherits
        /// from the gradient and the elements around it; its `inherit` is
        /// the gradient's `stop-color` or `stop-opacity`.
        fn stopsOf(p: *P, node: u32) u32 {
            if (node == none) return 0;
            const around = p.styleChain(node);
            var parent = StopState{ .current = around.colour };
            var holder = p.cascade(node);
            while (holder.next()) |one| p.stopProperty(one.name, one.value, &parent, &parent);
            var n: u32 = 0;
            var child = p.doc.nodes[node].first_child;
            while (child != none and n < max_stops) : (child = p.doc.nodes[child].next) {
                if (p.doc.nodes[child].tag != .stop) continue;
                var stop = StopState{ .current = around.colour };
                const offset = if (p.doc.get(child, .offset)) |t| values.fraction(t) orelse 0 else 0;
                var c = p.cascade(child);
                while (c.next()) |one| p.stopProperty(one.name, one.value, &stop, &parent);
                var colour = if (stop.use_current) stop.current else stop.colour;
                colour.a *= stop.opacity;
                p.work.stops[n] = .{ .offset = offset, .colour = colour };
                n += 1;
            }
            return n;
        }

        /// A stop's colour as its properties come: `stop-color`, given
        /// or `currentColor`, `stop-opacity` and `color`.
        const StopState = struct {
            colour: Colour = .{},
            opacity: f32 = 1,
            current: Colour,
            use_current: bool = false,
        };

        fn stopProperty(p: *P, name: Name, text_in: []const u8, stop: *StopState, parent: *const StopState) void {
            const text = values.trim(text_in);
            const inherit = std.mem.eql(u8, text, "inherit");
            switch (name) {
                .@"stop-color" => {
                    if (inherit) {
                        stop.colour = if (parent.use_current) parent.current else parent.colour;
                        stop.use_current = false;
                    } else if (values.eqlLower(text, "currentcolor")) {
                        stop.use_current = true;
                    } else if (p.colourOf(text)) |given| {
                        stop.colour = given;
                        stop.use_current = false;
                    }
                },
                .@"stop-opacity" => {
                    if (inherit) {
                        stop.opacity = parent.opacity;
                    } else if (values.fraction(text)) |amount| stop.opacity = amount;
                },
                .color => if (p.colourOf(text)) |given| {
                    stop.current = given;
                },
                else => {},
            }
        }

        // --- styles ---------------------------------------------------------------

        /// An element's style: its parent's, then its properties as they
        /// cascade.
        fn styleOf(p: *P, node: u32, parent: *const Style) Style {
            var s = Style.inherited(parent);
            var c = p.cascade(node);
            while (c.next()) |one| {
                // `marker` is CSS's shorthand of the three; as an
                // attribute it is nothing.
                if (one.name == .marker) {
                    if (one.css) for ([_]Name{ .@"marker-start", .@"marker-mid", .@"marker-end" }) |each| property(&s, parent, each, one.value);
                    continue;
                }
                // `font-kerning`, `mix-blend-mode` and `isolation` are
                // properties of CSS's alone.
                const css_only = one.name == .@"font-kerning" or one.name == .@"mix-blend-mode" or one.name == .isolation;
                if (css_only and !one.css) continue;
                property(&s, parent, one.name, one.value);
                // A colour of an ICC profile, through the profile.
                switch (one.name) {
                    .fill, .stroke, .color => if (values.iccColour(one.value) != null) {
                        if (one.name == .color) {
                            if (p.colourOf(one.value)) |given| s.colour = given;
                        } else if (p.paintIn(one.value)) |paint| {
                            if (one.name == .fill) s.fill = paint else s.stroke = paint;
                        }
                    },
                    else => {},
                }
            }
            // `text-rendering` is a whole text's: a span's own is not.
            switch (p.doc.nodes[node].tag) {
                .tspan, .textPath, .tref => s.text_aliased = parent.text_aliased,
                else => {},
            }
            if (p.dropped_count != 0) p.dropLoops(node, &s, false);
            return s;
        }

        /// An element's style where it is in the tree: its ancestors',
        /// from the root down, and then its own - what a `clipPath` or a
        /// `mask` has, wherever it is drawn from.
        fn styleChain(p: *P, node: u32) Style {
            var chain: [max_depth]u32 = undefined;
            var n: usize = 0;
            var at = node;
            while (at != none and n < max_depth) : (at = p.doc.nodes[at].parent) {
                chain[n] = at;
                n += 1;
            }
            var style = Style{};
            while (n > 0) {
                n -= 1;
                const parent = style;
                style = p.styleOf(chain[n], &parent);
            }
            return style;
        }

        fn cascade(p: *P, node: u32) Cascade {
            return .{ .doc = p.doc, .rules = p.work.rules[0..p.rule_count], .node = node };
        }

        /// The rules of every `style` element into the work, in the order
        /// they apply. One whose `type` is not CSS's is passed over.
        fn readRules(p: *P) void {
            var n: u32 = 0;
            for (p.doc.nodes, 0..) |node, i| {
                if (node.tag != .style) continue;
                if (p.doc.get(@intCast(i), .type)) |kind| {
                    const named = values.trim(kind);
                    if (named.len != 0 and !values.eqlLower(named, "text/css")) continue;
                }
                for (p.doc.attributesOf(@intCast(i))) |a| {
                    if (a.name == .@"#text") css.parse(a.value, &p.work.rules, &n);
                }
            }
            p.rule_count = n;
            css.sort(p.work.rules[0..n]);
        }

        fn transformOf(p: *P, node: u32, name: Name, viewport: [2]f32) Matrix {
            var m = values.transform(p.doc.get(node, name) orelse "") orelse Matrix{};
            // An element's `transform` may be CSS's too: the last that
            // reads is the one.
            if (name == .transform and p.rule_count + @intFromBool(p.doc.get(node, .style) != null) > 0) {
                var cascaded = p.cascade(node);
                while (cascaded.next()) |one| {
                    if (one.css and one.name == .transform) m = values.transform(one.value) orelse m;
                }
            }
            return p.aroundOrigin(node, m, viewport);
        }

        /// A transform of `node`'s about its `transform-origin` (SVG 2;
        /// since 1.7).
        fn aroundOrigin(p: *P, node: u32, m: Matrix, viewport: [2]f32) Matrix {
            const text = p.doc.get(node, .@"transform-origin") orelse return m;
            const origin = originOf(text, viewport) orelse return m;
            return Matrix.translate(origin[0], origin[1]).then(m).then(Matrix.translate(-origin[0], -origin[1]));
        }

        /// A length attribute in units, `default` when it is not there or
        /// not one.
        fn lengthOf(p: *P, node: u32, name: Name, axis: values.Axis, viewport: [2]f32, default: f32) f32 {
            return p.optionalLength(node, name, axis, viewport) orelse default;
        }

        fn optionalLength(p: *P, node: u32, name: Name, axis: values.Axis, viewport: [2]f32) ?f32 {
            const text = p.doc.get(node, name) orelse return null;
            const length = values.length(text) orelse return null;
            const resolved = length.resolveAt(axis, viewport, p.em);
            if (name == .rx or name == .ry) {
                if (!(resolved >= 0)) return null;
            }
            return resolved;
        }

        fn lengthOr(p: *P, node: u32, name: Name, axis: values.Axis, viewport: [2]f32, default: Length) f32 {
            const text = p.doc.get(node, name);
            const l = (if (text) |t| values.length(t) else null) orelse default;
            return l.resolveAt(axis, viewport, p.em);
        }
    };
}

/// An element's properties in the order they cascade: its presentation
/// attributes, the rules for it, its `style` attribute.
/// An element's properties in the order they apply: its attributes, the
/// declarations of the rules for it, its `style` attribute's, and then
/// the rules' and the `style` attribute's marked `!important`, again in
/// that order.
const Cascade = struct {
    doc: *const Document,
    rules: []const css.Rule,
    node: u32,
    phase: enum { attributes, rules, style, done } = .attributes,
    /// The second time through the rules and the style: the important.
    important: bool = false,
    index: usize = 0,
    declarations: values.Declarations = .{ .text = "" },

    /// A property, and whether it came from CSS - a rule or the `style`
    /// attribute - rather than an attribute of its own.
    const One = struct { name: Name, value: []const u8, css: bool = false };

    fn next(c: *Cascade) ?One {
        while (true) switch (c.phase) {
            .attributes => {
                const all = c.doc.attributesOf(c.node);
                if (c.index < all.len) {
                    const a = all[c.index];
                    c.index += 1;
                    if (a.name == .style or a.name == .@"#text") continue;
                    return .{ .name = a.name, .value = a.value };
                }
                c.phase = .rules;
                c.index = 0;
            },
            .rules => {
                while (c.declarations.next()) |declaration| {
                    if (declaration.important == c.important) return .{ .name = document.nameOf(declaration.name), .value = declaration.value, .css = true };
                }
                while (c.index < c.rules.len) {
                    const rule = &c.rules[c.index];
                    c.index += 1;
                    if (rule.matches(c.doc, c.node)) {
                        c.declarations = .{ .text = rule.declarations };
                        break;
                    }
                } else {
                    c.phase = .style;
                    c.declarations = .{ .text = c.doc.get(c.node, .style) orelse "" };
                }
            },
            .style => {
                while (c.declarations.next()) |declaration| {
                    if (declaration.important == c.important) return .{ .name = document.nameOf(declaration.name), .value = declaration.value, .css = true };
                }
                if (c.important) {
                    c.phase = .done;
                } else {
                    c.important = true;
                    c.phase = .rules;
                    c.index = 0;
                    c.declarations = .{ .text = "" };
                }
            },
            .done => return null,
        };
    }
};

/// The order a `paint-order` paints in: what it names first comes
/// first, what it leaves out after in the usual order - fill, stroke,
/// markers. Null for one in error.
const PaintOrder = struct { stroke_first: bool, markers: MarkersAt };

fn paintOrder(text: []const u8) ?PaintOrder {
    if (std.mem.eql(u8, text, "normal")) return .{ .stroke_first = false, .markers = .last };
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    // Each of fill, stroke and markers by its place.
    var order: [3]u8 = undefined;
    var count: u8 = 0;
    var seen = [3]bool{ false, false, false };
    while (words.next()) |word| {
        const kind: u8 = if (std.mem.eql(u8, word, "fill")) 0 else if (std.mem.eql(u8, word, "stroke")) 1 else if (std.mem.eql(u8, word, "markers")) 2 else return null;
        if (seen[kind] or count == 3) return null;
        seen[kind] = true;
        order[count] = kind;
        count += 1;
    }
    if (count == 0) return null;
    for (0..3) |kind| {
        if (!seen[kind]) {
            order[count] = @intCast(kind);
            count += 1;
        }
    }
    const at = struct {
        fn of(list: [3]u8, kind: u8) usize {
            for (list, 0..) |one, index| if (one == kind) return index;
            return 0;
        }
    }.of;
    return .{
        .stroke_first = at(order, 1) < at(order, 0),
        .markers = switch (at(order, 2)) {
            0 => .first,
            1 => .between,
            else => .last,
        },
    };
}

/// What an element's filters come to.
const Filtered = enum {
    /// None, or a list in error: drawn as it is.
    none,
    /// A list none of which is made: not drawn.
    hidden,
    /// Filters to run on the layer it is drawn on.
    run,
};

/// The angle a marker is turned by at a vertex, in degrees: its `orient`
/// - an angle, `auto` the way halfway between the path's way in and its
/// way out, or `auto-start-reverse`, that turned round at the first.
fn markerAngle(orient: ?[]const u8, vertex: *const vector.Vertex, index: usize) f32 {
    const text = values.trim(orient orelse return 0);
    const reverse = std.mem.eql(u8, text, "auto-start-reverse");
    if (reverse or std.mem.eql(u8, text, "auto")) {
        var angle = bisector(vertex);
        if (reverse and index == 0) angle = @mod(angle + 180, 360);
        return angle;
    }
    return angleOf(text) orelse 0;
}

/// The way halfway between a vertex's way in and its way out, the
/// shorter way round; the one it has of them; 0 for neither.
fn bisector(vertex: *const vector.Vertex) f32 {
    const neither = vector.VERTEXF_NO_IN | vector.VERTEXF_NO_OUT;
    if (vertex.flags & neither == neither) return 0;
    const half = (vertex.out_angle - vertex.in_angle) / 2;
    var angle = vertex.in_angle + half;
    if (@abs(half) > 90) angle -= 180;
    return angle;
}

/// An angle in degrees: a number, of degrees unless its unit says
/// `grad`, `rad` or `turn`.
fn angleOf(text: []const u8) ?f32 {
    var scanner = values.Scanner{ .text = text };
    const number = scanner.number() orelse return null;
    const unit = scanner.unit();
    if (!scanner.done()) return null;
    if (unit.len == 0 or values.eqlLower(unit, "deg")) return number;
    if (values.eqlLower(unit, "grad")) return number * 0.9;
    if (values.eqlLower(unit, "rad")) return number * 180 / std.math.pi;
    if (values.eqlLower(unit, "turn")) return number * 360;
    return null;
}

/// A `transform-origin`: across and down, each a length, a percentage of
/// the viewport or a word - `left`, `center`, `right`, `top`, `bottom` -
/// in either order where the words say which is which; one given, the
/// other the middle. A third, a depth, is passed over. Null for one in
/// error.
fn originOf(text: []const u8, viewport: [2]f32) ?[2]f32 {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n,");
    var across: ?f32 = null;
    var down: ?f32 = null;
    // Lengths in the order they came.
    var lengths: [2]f32 = undefined;
    var length_count: usize = 0;
    var count: usize = 0;
    while (words.next()) |word| : (count += 1) {
        if (count == 3) return null;
        if (std.mem.eql(u8, word, "left")) {
            across = 0;
        } else if (std.mem.eql(u8, word, "right")) {
            across = viewport[0];
        } else if (std.mem.eql(u8, word, "top")) {
            down = 0;
        } else if (std.mem.eql(u8, word, "bottom")) {
            down = viewport[1];
        } else if (std.mem.eql(u8, word, "center")) {
            // The middle, as a side not given is.
        } else {
            if (count == 2) continue;
            const l = values.length(word) orelse return null;
            if (length_count == 2) return null;
            lengths[length_count] = l.resolve(if (count == 0) .x else .y, viewport);
            length_count += 1;
            if (count == 0) across = lengths[0] else if (down == null) down = lengths[length_count - 1] else across = lengths[length_count - 1];
        }
    }
    if (count == 0) return null;
    return .{ across orelse viewport[0] / 2, down orelse viewport[1] / 2 };
}

/// Whether a gradient's attribute holds what it can: one that does not
/// is taken from the gradient its `href` names.
fn gradientValue(name: Name, text: []const u8) bool {
    const word = values.trim(text);
    return switch (name) {
        .gradientTransform => values.transform(text) != null,
        .gradientUnits => std.mem.eql(u8, word, "userSpaceOnUse") or std.mem.eql(u8, word, "objectBoundingBox"),
        .spreadMethod => std.mem.eql(u8, word, "pad") or std.mem.eql(u8, word, "reflect") or std.mem.eql(u8, word, "repeat"),
        else => values.length(text) != null,
    };
}

/// The same of a pattern's.
fn patternValue(name: Name, text: []const u8) bool {
    const word = values.trim(text);
    return switch (name) {
        .patternTransform => values.transform(text) != null,
        .patternUnits, .patternContentUnits => std.mem.eql(u8, word, "userSpaceOnUse") or std.mem.eql(u8, word, "objectBoundingBox"),
        .x, .y, .width, .height => values.length(text) != null,
        else => true,
    };
}

/// A paint server's transform: none for none, and one that flattens
/// what it paints - of no inverse - none too.
fn serverTransform(text: ?[]const u8) Matrix {
    const m = values.transform(text orelse return .{}) orelse return .{};
    return if (m.invert() != null) m else .{};
}

/// Whether a `preserveAspectRatio` slices: covers its place and is cut
/// to it, rather than fitting inside.
fn sliced(aspect: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, aspect, " \t\r\n");
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "slice")) return true;
    }
    return false;
}

/// The box round a rectangle through a matrix.
fn boxThrough(m: Matrix, r: vector.Rect) vector.Rect {
    const corners = [_]vector.Point{
        m.apply(.{ .x = r.x, .y = r.y }),
        m.apply(.{ .x = r.x + r.width, .y = r.y }),
        m.apply(.{ .x = r.x, .y = r.y + r.height }),
        m.apply(.{ .x = r.x + r.width, .y = r.y + r.height }),
    };
    var left = corners[0].x;
    var right = left;
    var top = corners[0].y;
    var bottom = top;
    for (corners[1..]) |c| {
        left = @min(left, c.x);
        right = @max(right, c.x);
        top = @min(top, c.y);
        bottom = @max(bottom, c.y);
    }
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

fn isShape(tag: Tag) bool {
    return switch (tag) {
        .path, .rect, .circle, .ellipse, .line, .polyline, .polygon => true,
        else => false,
    };
}

/// A box's units into the user's.
fn boxMatrix(box: vector.Rect) Matrix {
    return .{ .a = box.width, .d = box.height, .e = box.x, .f = box.y };
}

/// A number of the box's units, a percentage of it, or `default`.
fn boxFraction(text: ?[]const u8, default: f32) f32 {
    const l = values.length(text orelse return default) orelse return default;
    return if (l.percent) l.value / 100 else l.value;
}

fn unite(a: ?vector.Rect, b: ?vector.Rect) ?vector.Rect {
    const x = a orelse return b;
    const y = b orelse return a;
    const left = @min(x.x, y.x);
    const top = @min(x.y, y.y);
    const right = @max(x.x + x.width, y.x + y.width);
    const bottom = @max(x.y + x.height, y.y + y.height);
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

/// A point as a box of no size, for `unite`.
fn pointBox(point: vector.Point) vector.Rect {
    return .{ .x = point.x, .y = point.y, .width = 0, .height = 0 };
}

/// Turned by `degrees` about the point `x`, `y`.
fn rotateAt(degrees: f32, x: f32, y: f32) Matrix {
    return Matrix.translate(x, y).then(Matrix.rotate(degrees)).then(Matrix.translate(-x, -y));
}

/// Whether a span puts marks round its characters: one of a
/// `unicode-bidi`, or one set upright in a column.
fn bidiMarked(style: *const Style, vertical: bool) bool {
    return style.bidi != .normal or (vertical and style.orientation == .upright);
}

/// The marks of the embedding, the override or the isolate a span's
/// `unicode-bidi` makes - in a column, the override from left to right
/// of a span set upright - written to `into`, which has room for two:
/// how many bytes.
fn openMarks(style: *const Style, vertical: bool, into: []u8) usize {
    if (vertical and style.orientation == .upright) return utf8.encode(0x202D, into[0..4]);
    const rtl = style.rtl;
    const isolate: u32 = if (rtl) 0x2067 else 0x2066;
    const override: u32 = if (rtl) 0x202E else 0x202D;
    return switch (style.bidi) {
        .normal => 0,
        .embed => utf8.encode(if (rtl) 0x202B else 0x202A, into[0..4]),
        .isolate => utf8.encode(isolate, into[0..4]),
        .override => utf8.encode(override, into[0..4]),
        .isolate_override => utf8.encode(isolate, into[0..4]) + utf8.encode(override, into[3..][0..4]),
        .plaintext => utf8.encode(0x2068, into[0..4]),
    };
}

/// The marks that end what `openMarks` began.
fn closeMarks(style: *const Style, vertical: bool, into: []u8) usize {
    if (vertical and style.orientation == .upright) return utf8.encode(0x202C, into[0..4]);
    return switch (style.bidi) {
        .normal => 0,
        .embed, .override => utf8.encode(0x202C, into[0..4]),
        .isolate, .plaintext => utf8.encode(0x2069, into[0..4]),
        .isolate_override => utf8.encode(0x202C, into[0..4]) + utf8.encode(0x2069, into[3..][0..4]),
    };
}

/// The cluster of a chunk read first or last: of the lowest or the
/// highest character.
fn readEnd(clusters: []const Cluster, which: enum { first, last }) *const Cluster {
    var found = &clusters[0];
    for (clusters) |*cluster| {
        if (if (which == .first) cluster.character < found.character else cluster.character > found.character) found = cluster;
    }
    return found;
}

/// The `text-anchor` of `style` as the side of the line it means: its
/// start the right end of a text read from right to left - in a column,
/// read from the bottom up, its lower end; a column set upright is read
/// from the top down.
fn anchorOf(style: *const Style, vertical: bool) Anchor {
    if (!style.rtl or (vertical and style.orientation == .upright)) return style.anchor;
    return switch (style.anchor) {
        .start => .end,
        .middle => .middle,
        .end => .start,
    };
}

/// How far a chunk `width` long is moved by its `text-anchor`.
fn anchorOffset(how: Anchor, width: f32) f32 {
    return switch (how) {
        .start => 0,
        .middle => -width / 2,
        .end => -width,
    };
}

/// A `dominant-baseline` or an `alignment-baseline` by its name.
fn baselineOf(text: []const u8) ?Baseline {
    const names = [_]struct { name: []const u8, baseline: Baseline }{
        .{ .name = "auto", .baseline = .auto },
        .{ .name = "use-script", .baseline = .auto },
        .{ .name = "reset-size", .baseline = .auto },
        .{ .name = "baseline", .baseline = .baseline },
        .{ .name = "alphabetic", .baseline = .alphabetic },
        .{ .name = "ideographic", .baseline = .ideographic },
        .{ .name = "hanging", .baseline = .hanging },
        .{ .name = "mathematical", .baseline = .mathematical },
        .{ .name = "central", .baseline = .central },
        .{ .name = "center", .baseline = .central },
        .{ .name = "middle", .baseline = .middle },
        .{ .name = "before-edge", .baseline = .before },
        .{ .name = "text-before-edge", .baseline = .before },
        .{ .name = "text-top", .baseline = .before },
        .{ .name = "top", .baseline = .before },
        .{ .name = "after-edge", .baseline = .after },
        .{ .name = "text-after-edge", .baseline = .after },
        .{ .name = "text-bottom", .baseline = .after },
        .{ .name = "bottom", .baseline = .after },
    };
    for (names) |one| if (std.mem.eql(u8, text, one.name)) return one.baseline;
    return null;
}

/// How far down a span's glyphs are drawn to set them on the baseline
/// `which` of its font: the edges of its ascent and descent, its middle,
/// half its x height, or where most fonts have the others.
fn alignmentShift(run: *const Run, which: Baseline) f32 {
    return switch (which) {
        .auto, .baseline, .alphabetic => 0,
        .before => run.ascent,
        .middle => run.x_height / 2,
        .central => (run.ascent + run.descent) / 2,
        .after, .ideographic => run.descent,
        .hanging => run.ascent * 0.8,
        .mathematical => run.ascent / 2,
    };
}

/// What can be drawn: what a `switch` chooses among.
fn drawable(tag: Tag) bool {
    return switch (tag) {
        .g, .a, .@"switch", .svg, .path, .rect, .circle, .ellipse, .line, .polyline, .polygon, .use, .image, .text => true,
        else => false,
    };
}

/// One property set from its text; one that does not read leaves it as
/// it was, and `inherit` takes the parent's.
fn property(s: *Style, parent: *const Style, name: Name, text_in: []const u8) void {
    const text = values.trim(text_in);
    if (std.mem.eql(u8, text, "inherit")) {
        switch (name) {
            .fill => s.fill = parent.fill,
            .@"fill-opacity" => s.fill_opacity = parent.fill_opacity,
            .@"fill-rule" => s.fill_rule = parent.fill_rule,
            .stroke => s.stroke = parent.stroke,
            .@"stroke-opacity" => s.stroke_opacity = parent.stroke_opacity,
            .@"stroke-width" => s.stroke_width = parent.stroke_width,
            .@"stroke-linecap" => s.cap = parent.cap,
            .@"stroke-linejoin" => s.join = parent.join,
            .@"stroke-miterlimit" => s.miter_limit = parent.miter_limit,
            .@"stroke-dasharray" => s.dashes = parent.dashes,
            .@"stroke-dashoffset" => s.dash_offset = parent.dash_offset,
            .color => s.colour = parent.colour,
            .visibility => s.visible = parent.visible,
            .opacity => s.opacity = parent.opacity,
            .@"clip-rule" => s.clip_rule = parent.clip_rule,
            .@"paint-order" => s.stroke_first = parent.stroke_first,
            .@"font-family" => s.font_family = parent.font_family,
            .@"font-size" => s.font_size = parent.font_size,
            .@"font-weight" => s.weight = parent.weight,
            .@"font-style" => {
                s.italic = parent.italic;
                s.oblique = parent.oblique;
            },
            .@"font-stretch" => s.stretch = parent.stretch,
            .@"font-variation-settings" => s.variations = parent.variations,
            .@"font-optical-sizing" => s.optical = parent.optical,
            .@"text-anchor" => s.anchor = parent.anchor,
            .@"letter-spacing" => s.letter_spacing = parent.letter_spacing,
            .@"word-spacing" => s.word_spacing = parent.word_spacing,
            .@"text-decoration" => s.decoration = parent.decoration,
            .@"dominant-baseline" => s.dominant = parent.dominant,
            .@"alignment-baseline" => s.alignment = parent.alignment,
            .@"baseline-shift" => s.shift = parent.shift,
            .@"writing-mode" => s.vertical = parent.vertical,
            .@"text-orientation", .@"glyph-orientation-vertical" => s.orientation = parent.orientation,
            .direction => s.rtl = parent.rtl,
            .@"unicode-bidi" => s.bidi = parent.bidi,
            .@"font-kerning" => s.kerning = parent.kerning,
            .@"font-variant" => s.small_caps = parent.small_caps,
            .@"white-space", .@"xml:space" => s.preserve = parent.preserve,
            .lang => s.language = parent.language,
            .@"marker-start" => s.marker_start = parent.marker_start,
            .@"marker-mid" => s.marker_mid = parent.marker_mid,
            .@"marker-end" => s.marker_end = parent.marker_end,
            .@"shape-rendering" => s.aliased = parent.aliased,
            .@"text-rendering" => s.text_aliased = parent.text_aliased,
            .@"image-rendering" => s.nearest = parent.nearest,
            .@"color-interpolation" => s.linear_gradients = parent.linear_gradients,
            .@"mix-blend-mode" => s.blend = parent.blend,
            .isolation => s.isolate = parent.isolate,
            // What the parent shows, by default all it draws.
            .overflow => s.overflow_visible = parent.overflow_visible orelse true,
            else => {},
        }
        return;
    }
    switch (name) {
        .fill => if (values.paint(text)) |paint| {
            s.fill = paint;
        },
        .stroke => if (values.paint(text)) |paint| {
            s.stroke = paint;
        },
        .@"fill-opacity" => if (values.fraction(text)) |f| {
            s.fill_opacity = f;
        },
        .@"stroke-opacity" => if (values.fraction(text)) |f| {
            s.stroke_opacity = f;
        },
        .opacity => if (values.fraction(text)) |f| {
            s.opacity = f;
        },
        .@"fill-rule" => {
            if (std.mem.eql(u8, text, "evenodd")) s.fill_rule = vector.RULE_EVENODD;
            if (std.mem.eql(u8, text, "nonzero")) s.fill_rule = vector.RULE_NONZERO;
        },
        .@"stroke-width" => if (values.length(text)) |l| {
            if (l.value >= 0) s.stroke_width = l;
        },
        .@"stroke-linecap" => {
            if (std.mem.eql(u8, text, "butt")) s.cap = vector.CAP_BUTT;
            if (std.mem.eql(u8, text, "round")) s.cap = vector.CAP_ROUND;
            if (std.mem.eql(u8, text, "square")) s.cap = vector.CAP_SQUARE;
        },
        .@"stroke-linejoin" => {
            // `arcs` drawn as a miter, as SVG 2 has it where arcs are not.
            if (std.mem.eql(u8, text, "miter") or std.mem.eql(u8, text, "arcs")) s.join = vector.JOIN_MITER;
            if (std.mem.eql(u8, text, "miter-clip")) s.join = vector.JOIN_MITER_CLIP;
            if (std.mem.eql(u8, text, "round")) s.join = vector.JOIN_ROUND;
            if (std.mem.eql(u8, text, "bevel")) s.join = vector.JOIN_BEVEL;
        },
        .@"stroke-miterlimit" => if (values.number(text)) |n| {
            if (n >= 1) s.miter_limit = n;
        },
        .@"stroke-dasharray" => s.dashes = if (std.mem.eql(u8, text, "none")) "" else text,
        .@"stroke-dashoffset" => if (values.length(text)) |l| {
            s.dash_offset = l;
        },
        .color => if (values.colour(text)) |c| {
            s.colour = c;
        },
        .display => s.shown = !std.mem.eql(u8, text, "none"),
        .visibility => s.visible = std.mem.eql(u8, text, "visible"),
        .filter => s.filter = if (std.mem.eql(u8, text, "none")) "" else text,
        .@"clip-path" => s.clip = if (std.mem.eql(u8, text, "none")) "" else text,
        .mask => s.mask = if (std.mem.eql(u8, text, "none")) "" else text,
        .@"clip-rule" => {
            if (std.mem.eql(u8, text, "evenodd")) s.clip_rule = vector.RULE_EVENODD;
            if (std.mem.eql(u8, text, "nonzero")) s.clip_rule = vector.RULE_NONZERO;
        },
        .@"mask-type" => {
            if (std.mem.eql(u8, text, "alpha")) s.mask_alpha = true;
            if (std.mem.eql(u8, text, "luminance")) s.mask_alpha = false;
        },
        .overflow => {
            if (std.mem.eql(u8, text, "visible") or std.mem.eql(u8, text, "auto")) s.overflow_visible = true;
            if (std.mem.eql(u8, text, "hidden") or std.mem.eql(u8, text, "scroll")) s.overflow_visible = false;
        },
        .@"font-family" => if (text.len != 0) {
            s.font_family = text;
        },
        .@"font-size" => if (text_.fontSize(text, parent.font_size)) |size| {
            s.font_size = size;
        },
        .@"font-weight" => if (text_.weightOf(text, parent.weight)) |weight| {
            s.weight = weight;
        },
        .@"font-style" => if (text_.leanOf(text)) |lean| {
            s.italic = lean != .normal;
            s.oblique = lean == .oblique;
        },
        .@"font-stretch" => if (text_.stretchOf(text, parent.stretch)) |stretch| {
            s.stretch = stretch;
        },
        .@"font-variation-settings" => s.variations = text,
        .@"font-optical-sizing" => {
            if (std.mem.eql(u8, text, "none")) s.optical = false;
            if (std.mem.eql(u8, text, "auto")) s.optical = true;
        },
        .font => if (text_.shorthand(text, parent.font_size, parent.weight, parent.stretch)) |shorthand| {
            s.font_family = shorthand.family;
            s.font_size = shorthand.size;
            s.weight = shorthand.weight;
            s.italic = shorthand.lean != .normal;
            s.oblique = shorthand.lean == .oblique;
            s.stretch = shorthand.stretch;
            s.variations = "";
            s.optical = true;
            // What it does not say it sets back.
            s.kerning = true;
            s.small_caps = false;
        },
        .@"paint-order" => if (paintOrder(text)) |order| {
            s.stroke_first = order.stroke_first;
            s.markers_at = order.markers;
        },
        .@"marker-start" => s.marker_start = if (std.mem.eql(u8, text, "none")) "" else text,
        .@"marker-mid" => s.marker_mid = if (std.mem.eql(u8, text, "none")) "" else text,
        .@"marker-end" => s.marker_end = if (std.mem.eql(u8, text, "none")) "" else text,
        .@"shape-rendering" => {
            if (std.mem.eql(u8, text, "crispEdges") or std.mem.eql(u8, text, "optimizeSpeed")) s.aliased = true;
            if (std.mem.eql(u8, text, "auto") or std.mem.eql(u8, text, "geometricPrecision")) s.aliased = false;
        },
        .@"text-rendering" => {
            if (std.mem.eql(u8, text, "optimizeSpeed")) s.text_aliased = true;
            if (std.mem.eql(u8, text, "auto") or std.mem.eql(u8, text, "optimizeLegibility") or std.mem.eql(u8, text, "geometricPrecision")) s.text_aliased = false;
        },
        .@"image-rendering" => {
            if (std.mem.eql(u8, text, "optimizeSpeed") or std.mem.eql(u8, text, "pixelated") or std.mem.eql(u8, text, "crisp-edges")) s.nearest = true;
            if (std.mem.eql(u8, text, "auto") or std.mem.eql(u8, text, "optimizeQuality") or std.mem.eql(u8, text, "smooth") or std.mem.eql(u8, text, "high-quality")) s.nearest = false;
        },
        .@"color-interpolation" => {
            if (std.mem.eql(u8, text, "linearRGB")) s.linear_gradients = true;
            if (std.mem.eql(u8, text, "sRGB") or std.mem.eql(u8, text, "auto")) s.linear_gradients = false;
        },
        .@"mix-blend-mode" => if (filter_.blendMode(text)) |mode| {
            s.blend = mode;
        },
        .isolation => {
            if (std.mem.eql(u8, text, "isolate")) s.isolate = true;
            if (std.mem.eql(u8, text, "auto")) s.isolate = false;
        },
        .@"text-anchor" => {
            if (std.mem.eql(u8, text, "start")) s.anchor = .start;
            if (std.mem.eql(u8, text, "middle")) s.anchor = .middle;
            if (std.mem.eql(u8, text, "end")) s.anchor = .end;
        },
        .@"letter-spacing" => {
            if (std.mem.eql(u8, text, "normal")) s.letter_spacing = .{ .value = 0 } else if (values.length(text)) |l| {
                s.letter_spacing = l;
            }
        },
        .@"word-spacing" => {
            if (std.mem.eql(u8, text, "normal")) s.word_spacing = .{ .value = 0 } else if (values.length(text)) |l| {
                s.word_spacing = l;
            }
        },
        .@"text-decoration" => {
            var bits: u8 = 0;
            var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
            while (words.next()) |word| {
                if (std.mem.eql(u8, word, "underline")) bits |= decoration_under;
                if (std.mem.eql(u8, word, "line-through")) bits |= decoration_through;
                if (std.mem.eql(u8, word, "overline")) bits |= decoration_over;
            }
            // The lines of the spans it is in are drawn with it too.
            s.decoration = parent.decoration | bits;
            s.decoration_own = bits;
        },
        .@"dominant-baseline" => {
            if (std.mem.eql(u8, text, "no-change")) s.dominant = parent.dominant else if (baselineOf(text)) |which| {
                s.dominant = which;
            }
        },
        .@"alignment-baseline" => if (baselineOf(text)) |which| {
            s.alignment = which;
        },
        .@"baseline-shift" => {
            if (std.mem.eql(u8, text, "baseline")) s.shift = .none else if (std.mem.eql(u8, text, "sub")) {
                s.shift = .sub;
            } else if (std.mem.eql(u8, text, "super")) {
                s.shift = .super;
            } else if (values.length(text)) |given| s.shift = .{ .length = given };
        },
        .direction => {
            if (std.mem.eql(u8, text, "rtl")) s.rtl = true;
            if (std.mem.eql(u8, text, "ltr")) s.rtl = false;
        },
        .@"unicode-bidi" => {
            const kinds = [_]struct { name: []const u8, bidi: Bidi }{
                .{ .name = "normal", .bidi = .normal },
                .{ .name = "embed", .bidi = .embed },
                .{ .name = "isolate", .bidi = .isolate },
                .{ .name = "bidi-override", .bidi = .override },
                .{ .name = "isolate-override", .bidi = .isolate_override },
                .{ .name = "plaintext", .bidi = .plaintext },
            };
            for (kinds) |kind| {
                if (std.mem.eql(u8, text, kind.name)) s.bidi = kind.bidi;
            }
        },
        .@"text-orientation" => {
            if (std.mem.eql(u8, text, "mixed")) s.orientation = .mixed;
            if (std.mem.eql(u8, text, "upright")) s.orientation = .upright;
            if (std.mem.eql(u8, text, "sideways") or std.mem.eql(u8, text, "sideways-right")) s.orientation = .sideways;
        },
        // The angle of a glyph to the column: 0 upright, 90 turned.
        .@"glyph-orientation-vertical" => {
            if (std.mem.eql(u8, text, "auto")) s.orientation = .mixed;
            if (std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "0deg")) s.orientation = .upright;
            if (std.mem.eql(u8, text, "90") or std.mem.eql(u8, text, "90deg")) s.orientation = .sideways;
        },
        .@"writing-mode" => {
            if (std.mem.startsWith(u8, text, "tb") or std.mem.startsWith(u8, text, "vertical")) s.vertical = true;
            if (std.mem.startsWith(u8, text, "lr") or std.mem.startsWith(u8, text, "rl") or std.mem.eql(u8, text, "horizontal-tb")) s.vertical = false;
        },
        .@"font-kerning" => {
            if (std.mem.eql(u8, text, "none")) s.kerning = false;
            if (std.mem.eql(u8, text, "normal") or std.mem.eql(u8, text, "auto")) s.kerning = true;
        },
        .kerning => {
            if (std.mem.eql(u8, text, "auto")) s.kerning = true else if (values.length(text)) |given| {
                s.kerning = given.value != 0;
            }
        },
        .@"font-variant" => {
            if (std.mem.eql(u8, text, "small-caps")) s.small_caps = true;
            if (std.mem.eql(u8, text, "normal")) s.small_caps = false;
        },
        .lang => s.language = tts.languageOf(text),
        .@"xml:space" => {
            if (std.mem.eql(u8, text, "preserve")) s.preserve = true;
            if (std.mem.eql(u8, text, "default")) s.preserve = false;
        },
        .@"white-space" => {
            if (std.mem.startsWith(u8, text, "pre") or std.mem.eql(u8, text, "break-spaces")) s.preserve = true;
            if (std.mem.eql(u8, text, "normal") or std.mem.eql(u8, text, "nowrap")) s.preserve = false;
        },
        else => {},
    }
}
