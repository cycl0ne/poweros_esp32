// SPDX-License-Identifier: MIT
//! vector.library's types and constants.
//!
//! vector.library draws shapes with smooth edges onto pens: paths of
//! lines and curves, filled or stroked, in a colour or a gradient. A
//! program builds a path in its own units (`CreatePath`, `MoveTo`,
//! `LineTo`, `CubicTo` ...), and draws it onto a canvas - its own pens,
//! 0xAARRGGBB, which the library only writes - through a matrix that
//! takes the path's units to pixels (`FillPath`, `StrokePath`). Curves
//! stay curves until they are drawn, so one path is drawn at any size,
//! each time broken into lines that keep within a tenth of a pixel of it
//! (a quarter before 1.2).
//!
//! **Coverage, not samples**: every pixel a shape's edge crosses is
//! painted by how much of it the shape covers, so an edge is smooth
//! without a pixel being drawn more than once.
//!
//! Since 1.1 a paint is a gradient as well as a colour, a stroke may be
//! dashed, a path takes SVG's arcs, rectangles, ellipses and path data,
//! and what is drawn may go onto a layer that is put down at an opacity.
//! A program that needs these looks for revision 1 or later in the
//! library it opened.
//!
//! Since 1.2 a path can be handed over whole, its segments' verbs in one
//! array and their points in another (`AddSegments`): one call for a
//! path a program keeps as data, rather than one a segment. 1.2 also
//! draws closer to what SVG's renderers draw: curves are broken finer, a
//! stroke's pieces meet edge to edge rather than lying over each other
//! at its edges, and inside a curve a stroke turns round whatever its
//! join - so a picture drawn by 1.1 and by 1.2 differs at its edges.
//!
//! Since 1.3 what is drawn may be clipped: to a path's inside
//! (`PushClip`), or through a mask drawn first - its coverage or its
//! colours' luminance saying how much shows (`BeginMask`, `EndMask`) -
//! until `PopClip`. SVG's `clipPath` and `mask` and Lottie's mattes are
//! these.
//!
//! Since 1.4 a paint is an image too (`PAINT_IMAGE`): a program's pixels,
//! placed by the paint's matrix and read smoothly between them - SVG's
//! `image`. And a layer can be blurred before it is put down
//! (`BlurLayer`): SVG's `feGaussianBlur`.
//!
//! Open it with OpenLibrary(VECTORNAME, VECTOR_VERSION); its functions
//! are in sdk/interface/vector.zig. A path and a canvas are one task's at
//! a time: the library holds no lock, and two tasks drawing on two
//! canvases never wait for each other.

const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");

/// The name to open it by.
pub const VECTORNAME = "vector.library";
/// The version a caller of this SDK asks for.
pub const VECTOR_VERSION = 1;

/// Lines and curves in a program's own units, built a segment at a
/// time. The library's; made by `CreatePath`, given back with
/// `DisposePath`.
pub const Path = opaque {};

/// What a path is drawn onto: the caller's pens, and the library's
/// working memory for them. Made by `CreateCanvasTagList`, given back
/// with `DisposeCanvas`.
pub const Canvas = opaque {};

/// A point, in a path's units or in pixels.
pub const Point = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// A rectangle from (`x`, `y`), `width` across and `height` down.
pub const Rect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

/// `ArcTo`'s flags, SVG's two: the arc of more than half the ellipse
/// rather than the one of less, and the one going the way angles rise
/// (clockwise on the screen) rather than the other.
pub const ARC_LARGE: u32 = 1;
pub const ARC_SWEEP: u32 = 2;

/// `AddSegments`' verbs, a byte each, and how many of the points each
/// takes: a move to its one, a line to its one, a quadratic curve through
/// its control point to its end, a cubic one through two to its end, and
/// a close, which takes none. Since 1.2.
pub const SEG_MOVE: u8 = 0;
pub const SEG_LINE: u8 = 1;
pub const SEG_QUAD: u8 = 2;
pub const SEG_CUBIC: u8 = 3;
pub const SEG_CLOSE: u8 = 4;

/// An affine transform: x' = a x + c y + e, y' = b x + d y + f. The
/// default is the identity.
pub const Matrix = extern struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub fn apply(m: Matrix, p: Point) Point {
        return .{ .x = m.a * p.x + m.c * p.y + m.e, .y = m.b * p.x + m.d * p.y + m.f };
    }

    /// `m` after `n`: n is applied first.
    pub fn then(m: Matrix, n: Matrix) Matrix {
        return .{
            .a = m.a * n.a + m.c * n.b,
            .b = m.b * n.a + m.d * n.b,
            .c = m.a * n.c + m.c * n.d,
            .d = m.b * n.c + m.d * n.d,
            .e = m.a * n.e + m.c * n.f + m.e,
            .f = m.b * n.e + m.d * n.f + m.f,
        };
    }

    pub fn translate(x: f32, y: f32) Matrix {
        return .{ .e = x, .f = y };
    }

    pub fn scale(x: f32, y: f32) Matrix {
        return .{ .a = x, .d = y };
    }

    /// Clockwise on the screen, in degrees.
    pub fn rotate(degrees: f32) Matrix {
        const radians = degrees * (3.14159265 / 180.0);
        const cos = @cos(radians);
        const sin = @sin(radians);
        return .{ .a = cos, .b = sin, .c = -sin, .d = cos };
    }

    /// How much it scales a length, on average.
    pub fn size(m: Matrix) f32 {
        return @sqrt(@abs(m.a * m.d - m.b * m.c));
    }

    pub fn isIdentity(m: Matrix) bool {
        return m.a == 1 and m.b == 0 and m.c == 0 and m.d == 1 and m.e == 0 and m.f == 0;
    }

    /// The transform that undoes it; null for one that flattens the
    /// plane onto a line, which nothing undoes.
    pub fn invert(m: Matrix) ?Matrix {
        const det = m.a * m.d - m.b * m.c;
        if (det == 0 or det != det) return null;
        const k = 1 / det;
        return .{
            .a = m.d * k,
            .b = -m.b * k,
            .c = -m.c * k,
            .d = m.a * k,
            .e = (m.c * m.f - m.d * m.e) * k,
            .f = (m.b * m.e - m.a * m.f) * k,
        };
    }
};

/// A colour, 0 to 1 a channel, not premultiplied: `a` is how much of it
/// covers what is under it.
pub const Colour = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
};

/// A gradient's colour at `offset`, 0 at its start to 1 at its end.
pub const Stop = extern struct {
    offset: f32 = 0,
    colour: Colour = .{},
};

// --- what a shape is painted in -------------------------------------------

/// One colour, `Paint.colour`.
pub const PAINT_SOLID: u32 = 0;
/// From `x1`, `y1` to `x2`, `y2` (since 1.1; 1.0 paints its colour).
pub const PAINT_LINEAR: u32 = 1;
/// Round `cx`, `cy` out to `r`, from the focus `fx`, `fy` (since 1.1;
/// 1.0 paints its colour).
pub const PAINT_RADIAL: u32 = 2;

/// The image `Paint.image` (since 1.4; 1.3 and before paint its colour).
pub const PAINT_IMAGE: u32 = 3;

/// Past a gradient's ends: its end colours go on. Past an image's edges:
/// its edge pixels do.
pub const SPREAD_PAD: u32 = 0;
/// Past a gradient's ends: it comes back the other way, and again; past
/// an image's edges, it is mirrored.
pub const SPREAD_REFLECT: u32 = 1;
/// Past a gradient's ends: it starts again; past an image's edges, it is
/// tiled.
pub const SPREAD_REPEAT: u32 = 2;

/// What a fill or a stroke paints. The caller's, read by the call it is
/// given to; the stops likewise.
pub const Paint = extern struct {
    /// `PAINT_*`.
    kind: u32 = PAINT_SOLID,
    /// A solid paint's colour.
    colour: Colour = .{},
    /// How much of the paint shows, 0 to 1, over its colours' own.
    opacity: f32 = 1,
    /// A gradient's colours, by offset rising.
    stops: ?[*]const Stop = null,
    stop_count: u32 = 0,
    /// `SPREAD_*`.
    spread: u32 = SPREAD_PAD,
    /// A linear gradient's start and end.
    x1: f32 = 0,
    y1: f32 = 0,
    x2: f32 = 1,
    y2: f32 = 0,
    /// A radial gradient's circle, and its focus: where offset 0 is.
    cx: f32 = 0,
    cy: f32 = 0,
    r: f32 = 1,
    fx: f32 = 0,
    fy: f32 = 0,
    /// The focus's own radius (SVG 2's `fr`), 0 for a point.
    fr: f32 = 0,
    /// The gradient's units into the path's: SVG's `gradientTransform`.
    /// An image's units - a pixel each, (0, 0) its top left corner - into
    /// the path's.
    matrix: Matrix = .{},
    /// An image paint's pixels (since 1.4): `image_width` by
    /// `image_height` pens, 0xAARRGGBB and not premultiplied,
    /// `image_bytes_per_row` from one row to the next. Read by the call
    /// the paint is given to, and not kept.
    image: ?[*]const graphics.Pen = null,
    image_width: u32 = 0,
    image_height: u32 = 0,
    image_bytes_per_row: u32 = 0,
};

// --- how a fill covers, and a stroke -------------------------------------

/// Inside where the path winds round a point at all.
pub const RULE_NONZERO: u32 = 0;
/// Inside where it winds round a point an odd number of times: a contour
/// inside another is a hole.
pub const RULE_EVENODD: u32 = 1;

pub const JOIN_MITER: u32 = 0;
pub const JOIN_ROUND: u32 = 1;
pub const JOIN_BEVEL: u32 = 2;

pub const CAP_BUTT: u32 = 0;
pub const CAP_ROUND: u32 = 1;
pub const CAP_SQUARE: u32 = 2;

/// How a path is stroked, in its own units. The caller's, read by the
/// call it is given to; the dashes likewise.
pub const Stroke = extern struct {
    width: f32 = 1,
    /// `JOIN_*`: how two segments meet.
    join: u32 = JOIN_MITER,
    /// `CAP_*`: how an open contour ends.
    cap: u32 = CAP_BUTT,
    /// The longest a miter may be, in stroke widths, before the corner
    /// is bevelled instead: SVG's `stroke-miterlimit`.
    miter_limit: f32 = 4,
    /// Dash and gap lengths in turn, from `dash_offset` along the
    /// contour (since 1.1; 1.0 draws a dashed stroke whole). An odd count
    /// is gone through twice.
    dashes: ?[*]const f32 = null,
    dash_count: u32 = 0,
    dash_offset: f32 = 0,
};

// --- a canvas's tags --------------------------------------------------------

pub const VCA_Dummy = utility.TAG_USER + 0x61100;
/// `[*]graphics.Pen`: what is drawn on, `VCA_BytesPerRow` from one row to
/// the next. Without it the canvas draws nothing until `SetCanvasPens`.
pub const VCA_Pens = VCA_Dummy + 1;
/// The canvas's width and height in pixels: both needed, both over 0.
pub const VCA_Width = VCA_Dummy + 2;
pub const VCA_Height = VCA_Dummy + 3;
/// Bytes from one row of pens to the next; four times the width unless
/// given.
pub const VCA_BytesPerRow = VCA_Dummy + 4;

// --- what a call answers ------------------------------------------------------

pub const VECTOR_OK: i32 = 0;
/// There was not the memory for all of it: what there was room for is
/// drawn, or kept.
pub const VECTORERR_NOMEM: i32 = -1;
/// Path data that is not SVG's: the path is kept up to where it went
/// wrong, as SVG draws it.
pub const VECTORERR_SYNTAX: i32 = -2;
/// Layers nested deeper than a canvas holds, or clips; or `EndMask`
/// with no mask begun, or `BlurLayer` with no layer pushed.
pub const VECTORERR_DEPTH: i32 = -3;

/// The most layers a canvas holds one inside another (`PushLayer`,
/// `BeginMask`).
pub const MAX_LAYERS = 16;

// --- clips and masks (since 1.3) ----------------------------------------------

/// The most clips and masks a canvas holds one inside another
/// (`PushClip`, `EndMask`).
pub const MAX_CLIPS = 16;

/// `EndMask`'s kinds: how much of what is drawn shows where the mask was
/// drawn - its coverage alone, SVG's `mask-type: alpha` and Lottie's
/// alpha matte; or its colours' luminance times it, SVG's mask and
/// Lottie's luma matte. `MASK_INVERT` with either shows what the mask
/// does not: Lottie's inverted mattes, and its subtracting masks.
pub const MASK_ALPHA: u32 = 0;
pub const MASK_LUMINANCE: u32 = 1;
pub const MASK_INVERT: u32 = 0x10;
