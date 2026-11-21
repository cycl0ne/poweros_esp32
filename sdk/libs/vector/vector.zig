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
//! Since 1.5 a layer is put down in a blend mode (`PushBlendLayer`):
//! CSS's `mix-blend-mode`, or one of Porter and Duff's operators. A
//! gradient may sweep round a point (`PAINT_SWEEP`). A layer goes through a filter of any of SVG's
//! primitives - offset, colour matrix, transfer, composite, blend,
//! merge, flood, tile, image, morphology, convolution, displacement,
//! turbulence, lighting, drop shadow and blur - one after another, each
//! reading what the ones before made (`FilterLayer`). A path is measured
//! and walked (`PathLength`, `PathPointAt`), and its vertices read with
//! the directions in and out of each (`PathVertices`): SVG's `textPath`,
//! `pathLength` and markers. And a paint may be drawn without smoothed
//! edges, an image read pixel by pixel, a gradient mixed in linear light
//! (`Paint.flags`), a clip cut without smoothing, and a mask's luminance
//! read in linear light.
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
/// Round `cx`, `cy` from `start_angle` to `end_angle`, in degrees from
/// the x axis towards the y axis (since 1.5; 1.4 and before paint its
/// colour). Only the angles of one turn, 0 to 360, are drawn: past the
/// two the spread pads, reflects or repeats.
pub const PAINT_SWEEP: u32 = 4;

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
    /// A sweep's angles, in degrees (since 1.5).
    start_angle: f32 = 0,
    end_angle: f32 = 360,
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
    /// `PAINTF_*` (since 1.5; 1.4 and before read none).
    flags: u32 = 0,
};

/// `Paint.flags`: the edges not smoothed - a pixel is painted whole when
/// the shape covers its middle, and not at all when not: SVG's
/// `shape-rendering: crispEdges`.
pub const PAINTF_ALIASED: u32 = 1;
/// An image read pixel by pixel, each the one nearest, not smoothly
/// between them: SVG's `image-rendering: pixelated`.
pub const PAINTF_NEAREST: u32 = 2;
/// A gradient's colours mixed in linear light rather than as they are
/// written: SVG's `color-interpolation: linearRGB`.
pub const PAINTF_LINEARRGB: u32 = 4;

// --- how a fill covers, and a stroke -------------------------------------

/// Inside where the path winds round a point at all.
pub const RULE_NONZERO: u32 = 0;
/// Inside where it winds round a point an odd number of times: a contour
/// inside another is a hole.
pub const RULE_EVENODD: u32 = 1;
/// With either rule, for `PushClip` (since 1.5): the clip cut without
/// smoothing, as `PAINTF_ALIASED` paints.
pub const RULEF_ALIASED: u32 = 0x100;

pub const JOIN_MITER: u32 = 0;
pub const JOIN_ROUND: u32 = 1;
pub const JOIN_BEVEL: u32 = 2;
/// A miter cut off square where it passes the miter limit, rather than
/// bevelled (since 1.5; 1.4 and before join it as `JOIN_MITER`): SVG 2's
/// `miter-clip`.
pub const JOIN_MITER_CLIP: u32 = 3;

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
/// With `MASK_LUMINANCE` (since 1.5): the luminance of the colours in
/// linear light, SVG's `color-interpolation: linearRGB` on a mask.
pub const MASK_LINEARRGB: u32 = 0x20;

// --- blend modes (since 1.5) ------------------------------------------------

/// How a layer's colours go onto what is under them (`PushBlendLayer`),
/// and a filter's `FILTER_BLEND`: CSS's blend modes, by their names.
/// Each mixes the layer's colour with the one under it where both are,
/// and is laid over it at the layer's coverage, as `BLEND_NORMAL` is.
pub const BLEND_NORMAL: u32 = 0;
pub const BLEND_MULTIPLY: u32 = 1;
pub const BLEND_SCREEN: u32 = 2;
pub const BLEND_OVERLAY: u32 = 3;
pub const BLEND_DARKEN: u32 = 4;
pub const BLEND_LIGHTEN: u32 = 5;
pub const BLEND_COLOUR_DODGE: u32 = 6;
pub const BLEND_COLOUR_BURN: u32 = 7;
pub const BLEND_HARD_LIGHT: u32 = 8;
pub const BLEND_SOFT_LIGHT: u32 = 9;
pub const BLEND_DIFFERENCE: u32 = 10;
pub const BLEND_EXCLUSION: u32 = 11;
/// The non-separable four: the layer's hue, saturation, both, or its
/// luminosity, with the rest of the colour under it.
pub const BLEND_HUE: u32 = 12;
pub const BLEND_SATURATION: u32 = 13;
pub const BLEND_COLOUR: u32 = 14;
pub const BLEND_LUMINOSITY: u32 = 15;
/// The two added, each channel and the coverage, and held at full.
pub const BLEND_PLUS_LIGHTER: u32 = 16;
/// Porter and Duff's ways of putting a layer down, the layer being the
/// source and what is under it the destination: nothing; the layer
/// alone; what is under alone; what is under over the layer; the layer
/// where what is under is, or what is under where the layer is; the
/// layer where what is under is not, or the other way round; the layer
/// atop what is under, or the other way round; each where the other is
/// not. Where the layer is not, those that keep only what is of both or
/// of the layer clear what is under it - inside the clips, to the edges
/// of the layer it goes down on.
pub const BLEND_CLEAR: u32 = 17;
pub const BLEND_COPY: u32 = 18;
pub const BLEND_DESTINATION: u32 = 19;
pub const BLEND_DESTINATION_OVER: u32 = 20;
pub const BLEND_SOURCE_IN: u32 = 21;
pub const BLEND_DESTINATION_IN: u32 = 22;
pub const BLEND_SOURCE_OUT: u32 = 23;
pub const BLEND_DESTINATION_OUT: u32 = 24;
pub const BLEND_SOURCE_ATOP: u32 = 25;
pub const BLEND_DESTINATION_ATOP: u32 = 26;
pub const BLEND_XOR: u32 = 27;

// --- filters (since 1.5) ----------------------------------------------------

/// The most primitives one `FilterLayer` runs.
pub const MAX_FILTER_PRIMITIVES = 64;

/// A primitive's input: what was drawn on the layer, its coverage alone
/// (black where it is), or - 0 up - the result of an earlier primitive
/// by its place in the list.
pub const FILTERIN_SOURCE: i32 = -1;
pub const FILTERIN_SOURCEALPHA: i32 = -2;

/// `FilterPrimitive.flags`: the primitive works in linear light, its
/// inputs turned into it first - SVG's `color-interpolation-filters`,
/// whose default this is. Without it, in the colours as written (sRGB).
pub const FILTERF_LINEARRGB: u32 = 1;

/// `FilterPrimitive.kind`, and which of its `as` it reads.
pub const FILTER_BLEND: u32 = 0; // .blend: in over in2 in a blend mode
pub const FILTER_COLOUR_MATRIX: u32 = 1; // .colour_matrix
pub const FILTER_COMPONENT_TRANSFER: u32 = 2; // .transfer
pub const FILTER_COMPOSITE: u32 = 3; // .composite: in with in2
pub const FILTER_CONVOLVE: u32 = 4; // .convolve
pub const FILTER_DIFFUSE_LIGHTING: u32 = 5; // .lighting
pub const FILTER_DISPLACEMENT_MAP: u32 = 6; // .displacement: in moved by in2
pub const FILTER_DROP_SHADOW: u32 = 7; // .drop_shadow
pub const FILTER_FLOOD: u32 = 8; // .flood: no input
pub const FILTER_GAUSSIAN_BLUR: u32 = 9; // .blur
pub const FILTER_IMAGE: u32 = 10; // .image: no input
pub const FILTER_MERGE: u32 = 11; // .merge: its inputs, the first lowest
pub const FILTER_MORPHOLOGY: u32 = 12; // .morphology
pub const FILTER_OFFSET: u32 = 13; // .offset
pub const FILTER_SPECULAR_LIGHTING: u32 = 14; // .lighting
pub const FILTER_TILE: u32 = 15; // none: in's region repeated over this one
pub const FILTER_TURBULENCE: u32 = 16; // .turbulence: no input

/// `FilterComposite.operator`: Porter and Duff's, in over in2 and the
/// rest, a sum of the products (`k1` to `k4`), and the two added.
pub const COMPOSITE_OVER: u32 = 0;
pub const COMPOSITE_IN: u32 = 1;
pub const COMPOSITE_OUT: u32 = 2;
pub const COMPOSITE_ATOP: u32 = 3;
pub const COMPOSITE_XOR: u32 = 4;
pub const COMPOSITE_ARITHMETIC: u32 = 5;
pub const COMPOSITE_LIGHTER: u32 = 6;

/// `FilterTransfer.kind`: a channel as it is, through a table of values
/// it goes between, a table of steps, a line, or a curve.
pub const TRANSFER_IDENTITY: u32 = 0;
pub const TRANSFER_TABLE: u32 = 1;
pub const TRANSFER_DISCRETE: u32 = 2;
pub const TRANSFER_LINEAR: u32 = 3;
pub const TRANSFER_GAMMA: u32 = 4;

/// What a convolution reads past the input's edge: its nearest pixel,
/// the other side's, or clear.
pub const EDGE_DUPLICATE: u32 = 0;
pub const EDGE_WRAP: u32 = 1;
pub const EDGE_NONE: u32 = 2;

/// A displacement map's channels.
pub const CHANNEL_R: u32 = 0;
pub const CHANNEL_G: u32 = 1;
pub const CHANNEL_B: u32 = 2;
pub const CHANNEL_A: u32 = 3;

/// `FilterMorphology.operator`: thinner or fatter.
pub const MORPHOLOGY_ERODE: u32 = 0;
pub const MORPHOLOGY_DILATE: u32 = 1;

/// `FilterLight.kind`: a light from far off in one direction, from a
/// point, or a spot from a point toward another.
pub const LIGHT_DISTANT: u32 = 0;
pub const LIGHT_POINT: u32 = 1;
pub const LIGHT_SPOT: u32 = 2;

/// In over in2 in `mode` (`BLEND_*`).
pub const FilterBlend = extern struct { mode: u32 = BLEND_NORMAL };

/// Each pixel's red, green, blue and alpha, not premultiplied and 0 to
/// 1, times the matrix's four rows of five: SVG's `feColorMatrix`, whose
/// other types are matrices too.
pub const FilterColourMatrix = extern struct { values: [20]f32 = .{ 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 } };

/// One channel's function, SVG's `feFuncR` and the rest. `table` is read
/// by the call and not kept.
pub const FilterTransfer = extern struct {
    kind: u32 = TRANSFER_IDENTITY,
    table: ?[*]const f32 = null,
    table_count: u32 = 0,
    slope: f32 = 1,
    intercept: f32 = 0,
    amplitude: f32 = 1,
    exponent: f32 = 1,
    offset: f32 = 0,
};

/// Red, green, blue and alpha, each through its own function, not
/// premultiplied.
pub const FilterComponentTransfer = extern struct { functions: [4]FilterTransfer = @splat(.{}) };

pub const FilterComposite = extern struct {
    operator: u32 = COMPOSITE_OVER,
    /// `COMPOSITE_ARITHMETIC`'s k1 * in * in2 + k2 * in + k3 * in2 + k4.
    k: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Each pixel the sum of those round it times the kernel, `order_x` by
/// `order_y` numbers read by the call and not kept, over `divisor`, and
/// `bias` added; the kernel's `target_x`, `target_y` is the pixel's own
/// place in it. `preserve_alpha` leaves the coverage as it is and
/// convolves the colours alone.
pub const FilterConvolve = extern struct {
    order_x: u32 = 3,
    order_y: u32 = 3,
    kernel: ?[*]const f32 = null,
    divisor: f32 = 1,
    bias: f32 = 0,
    target_x: i32 = 1,
    target_y: i32 = 1,
    edge: u32 = EDGE_DUPLICATE,
    preserve_alpha: u32 = 0,
};

/// A light, in pixels: a distant one by its direction in degrees, a
/// point and a spot by where they are - z up from the canvas - and a
/// spot by where it points, how its light falls off round that
/// (`spot_exponent`) and the cone it is held to (`cone`, in degrees; 0
/// for none).
pub const FilterLight = extern struct {
    kind: u32 = LIGHT_DISTANT,
    azimuth: f32 = 0,
    elevation: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    at_x: f32 = 0,
    at_y: f32 = 0,
    at_z: f32 = 0,
    spot_exponent: f32 = 1,
    cone: f32 = 0,
};

/// The input's coverage taken as a surface, `surface_scale` high where
/// it is whole, lit by `light` in `colour` (in sRGB): diffusely by
/// `constant`, or as a shine, by `constant` to the power of `exponent`.
pub const FilterLighting = extern struct {
    surface_scale: f32 = 1,
    constant: f32 = 1,
    exponent: f32 = 1,
    colour: Colour = .{ .r = 1, .g = 1, .b = 1 },
    light: FilterLight = .{},
};

/// Each pixel of in taken from as far off as in2's channels say -
/// `x_channel` across, `y_channel` down, each times `scale_x` or
/// `scale_y` pixels round its middle.
pub const FilterDisplacement = extern struct {
    scale_x: f32 = 0,
    scale_y: f32 = 0,
    x_channel: u32 = CHANNEL_A,
    y_channel: u32 = CHANNEL_A,
};

/// In's coverage blurred, moved, in `colour`, and in over it.
pub const FilterDropShadow = extern struct {
    dx: f32 = 2,
    dy: f32 = 2,
    deviation_x: f32 = 2,
    deviation_y: f32 = 2,
    colour: Colour = .{},
};

/// The region in one colour, in sRGB.
pub const FilterFlood = extern struct { colour: Colour = .{ .a = 0 } };

/// In blurred, a deviation in pixels each way.
pub const FilterBlur = extern struct { deviation_x: f32 = 0, deviation_y: f32 = 0 };

/// A program's pixels - 0xAARRGGBB, not premultiplied, in sRGB -
/// `width` by `height`, their top left corner at `x`, `y` on the canvas.
/// Read by the call and not kept.
pub const FilterImage = extern struct {
    pens: ?[*]const graphics.Pen = null,
    width: u32 = 0,
    height: u32 = 0,
    bytes_per_row: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
};

/// The inputs, by their numbers as `in` has them, put down one over the
/// other, the first lowest. Read by the call and not kept.
pub const FilterMerge = extern struct { inputs: ?[*]const i32 = null, count: u32 = 0 };

/// Each pixel the least, or the most, of those within a box this many
/// pixels round it, each channel on its own.
pub const FilterMorphology = extern struct {
    operator: u32 = MORPHOLOGY_ERODE,
    radius_x: f32 = 0,
    radius_y: f32 = 0,
};

/// In moved, in pixels.
pub const FilterOffset = extern struct { dx: f32 = 0, dy: f32 = 0 };

/// Perlin's noise, as SVG's `feTurbulence` makes it: in the units
/// `matrix` takes to pixels, at `base_x`, `base_y` waves a unit, `octaves`
/// of it, from `seed`; its sum (`fractal`) or the sum of its sizes. With
/// `stitch`, made to repeat over the tile `tile_*`, in the same units.
pub const FilterTurbulence = extern struct {
    base_x: f32 = 0,
    base_y: f32 = 0,
    octaves: u32 = 1,
    seed: f32 = 0,
    fractal: u32 = 0,
    stitch: u32 = 0,
    matrix: Matrix = .{},
    tile_x: f32 = 0,
    tile_y: f32 = 0,
    tile_width: f32 = 0,
    tile_height: f32 = 0,
};

/// What one kind of primitive reads.
pub const FilterParameters = extern union {
    blend: FilterBlend,
    colour_matrix: FilterColourMatrix,
    transfer: FilterComponentTransfer,
    composite: FilterComposite,
    convolve: FilterConvolve,
    lighting: FilterLighting,
    displacement: FilterDisplacement,
    drop_shadow: FilterDropShadow,
    flood: FilterFlood,
    blur: FilterBlur,
    image: FilterImage,
    merge: FilterMerge,
    morphology: FilterMorphology,
    offset: FilterOffset,
    turbulence: FilterTurbulence,
};

/// One step of a filter (`FilterLayer`): what it does (`FILTER_*`) and
/// with what. Its result is clear outside `region` - pixels of the
/// canvas, SVG's primitive subregion - and the next steps read it by its
/// place in the list.
pub const FilterPrimitive = extern struct {
    kind: u32 = FILTER_FLOOD,
    /// `FILTERIN_*`, or an earlier step's place.
    in: i32 = FILTERIN_SOURCE,
    in2: i32 = FILTERIN_SOURCE,
    region: Rect = .{},
    /// `FILTERF_*`.
    flags: u32 = FILTERF_LINEARRGB,
    as: FilterParameters = .{ .flood = .{} },
};

// --- a path's vertices (since 1.5) ------------------------------------------

/// A vertex of a path (`PathVertices`): where a segment ends or a
/// contour starts, and the directions the path comes in and goes out
/// there, in degrees clockwise from across.
pub const Vertex = extern struct {
    point: Point = .{},
    in_angle: f32 = 0,
    out_angle: f32 = 0,
    /// `VERTEXF_*`.
    flags: u32 = 0,
};

/// A contour's first vertex, and its last.
pub const VERTEXF_START: u32 = 1;
pub const VERTEXF_END: u32 = 2;
/// The contour is closed: its first vertex is come into by the close,
/// and its last is where the close begins.
pub const VERTEXF_CLOSED: u32 = 4;
/// Nothing comes in, or nothing goes out: the angle is the other one.
pub const VERTEXF_NO_IN: u32 = 8;
pub const VERTEXF_NO_OUT: u32 = 16;
