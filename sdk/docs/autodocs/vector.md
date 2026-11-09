# vector.library

vector.library's functions: paths of lines and curves in a program's
own units, filled or stroked with smooth edges onto its pens through a
matrix. Open it with OpenLibrary("vector.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [AddEllipse](#addellipse) - A closed ellipse round (cx, cy); SVG's ellipse.
- [AddPathData](#addpathdata) - SVG path data onto the path: VECTORERR_SYNTAX at the first error, the path kept up to it.
- [AddRect](#addrect) - A closed rectangle, its corners rounded rx across and ry down; SVG's rect.
- [ArcTo](#arcto) - SVG's elliptical arc from the current point to (x, y): the radii, the ellipse's angle in degrees, ARC_LARGE and ARC_SWEEP.
- [ClearPath](#clearpath) - The path emptied, its memory kept for the next one built in it.
- [ClosePath](#closepath) - The contour closed back to where it started.
- [CreateCanvasTagList](#createcanvastaglist) - A canvas over the caller's pens (VCA_*); null without a size or the memory.
- [CreatePath](#createpath) - An empty path; null without the memory for one.
- [CubicTo](#cubicto) - A cubic curve from the current point to (x, y), leaving toward (x1, y1) and arriving from (x2, y2).
- [DisposeCanvas](#disposecanvas) - A canvas given back; its pens stay the caller's. Null does nothing.
- [DisposePath](#disposepath) - A path given back. Null does nothing.
- [FillPath](#fillpath) - The path filled through the matrix (null: the identity) in the paint, by the rule (RULE_*).
- [LineTo](#lineto) - A line from the current point to (x, y).
- [MoveTo](#moveto) - A new contour started at (x, y).
- [PathBounds](#pathbounds) - The bounds of the path's curves through the matrix (null: the identity); false for an empty path.
- [PopLayer](#poplayer) - The last layer pushed put down on what is under it.
- [PushLayer](#pushlayer) - What is drawn until PopLayer goes onto a layer of its own, put down at the opacity.
- [QuadTo](#quadto) - A quadratic curve from the current point to (x, y), pulled toward (x1, y1).
- [SetCanvasPens](#setcanvaspens) - The pens the canvas draws on from now on; null draws nothing.
- [StrokePath](#strokepath) - The path stroked in its own units, then through the matrix (null: the identity), in the paint.

## AddEllipse

A closed ellipse round (cx, cy); SVG's ellipse.

**SYNOPSIS**

```zig
fn AddEllipse(vb: *VectorBase, path: *vector.Path, cx: f32, cy: f32, rx: f32, ry: f32) void
```

**SINCE**

1.1. LVO -80.

**INPUTS**

- `path` - the path.
- `cx`, `cy` - its centre, in the path's units.
- `rx`, `ry` - its radii across and down; the same for a circle.

**RESULT**

Nothing.

**BEHAVIOR**

A contour of its own, closed, of four cubic curves, as SVG draws an
`ellipse` or a `circle`: from its rightmost point, clockwise on the
screen. A radius of 0 or less adds nothing. The current point is the
rightmost point afterwards.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, as before.

**BUGS**

None known.

**SEE ALSO**

`AddRect`, `ArcTo`

**EXAMPLES**

```zig
vb.AddEllipse(path, 50, 50, 20, 20); // a circle
```

## AddPathData

SVG path data onto the path: VECTORERR_SYNTAX at the first error, the path kept up to it.

**SYNOPSIS**

```zig
fn AddPathData(vb: *VectorBase, path: *vector.Path, text: [*]const u8, length: u32) i32
```

**SINCE**

1.1. LVO -84.

**INPUTS**

- `path` - the path the contours are added to.
- `text`, `length` - the data: the `d` of an SVG `path`, such as
  `M 10 10 h 20 a 5 5 0 0 1 5 5 z`. It need not end in a 0.

**RESULT**

`VECTOR_OK`; `VECTORERR_SYNTAX` at the first thing that is not SVG's
path data; `VECTORERR_NOMEM` when a segment did not fit.

**BEHAVIOR**

Every command of SVG's path data, in both its forms: absolute, and
relative to the current point. `M`, `L`, `H`, `V`, `C`, `S`, `Q`,
`T`, `A`, `Z`; a command's numbers given again for another of the
same - a move's as lines - and `S` and `T` mirroring the last curve's
control point when the command before was one of their kind. Numbers
may run together where a sign or a second point parts them
(`10-5.5.5`), with an exponent, and an arc's two flags may be single
digits with nothing between them.

At an error the commands before it are kept and the one it is in is
not, which is how SVG draws data that goes wrong. The data is a path
of its own: it must start with a move, and a relative one first is
taken from (0, 0).

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The text is the caller's and only read.

**NOTES**

A program can keep its pictures as path data and build them with
this, as an SVG file does.

**BUGS**

None known.

**SEE ALSO**

`ArcTo`, `MoveTo`, `PathBounds`

**EXAMPLES**

```zig
const d = "M 4 12 l 6 6 l 10 -12";
if (vb.AddPathData(path, d, d.len) != vector.VECTOR_OK) return;
```

## AddRect

A closed rectangle, its corners rounded rx across and ry down; SVG's rect.

**SYNOPSIS**

```zig
fn AddRect(vb: *VectorBase, path: *vector.Path, rect: *const vector.Rect, rx: f32, ry: f32) void
```

**SINCE**

1.1. LVO -76.

**INPUTS**

- `path` - the path.
- `rect` - where it is and how large (`vector.Rect`), in the path's
  units.
- `rx`, `ry` - how far round each corner goes, across and down; 0 for
  square corners.

**RESULT**

Nothing.

**BEHAVIOR**

A contour of its own, closed, as SVG draws a `rect`: from the top
left - after its rounding - going right, so clockwise on the screen.
The corners are quarters of an ellipse, `rx` and `ry` each held to
half the side it is along, and square when either is 0 or less. A
width or a height of 0 or less adds nothing. The current point is the
contour's start afterwards.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The rectangle is the caller's and only read.

**NOTES**

SVG's `rx` given alone stands for `ry` too, and the other way round:
a program reading SVG passes the one for both.

**BUGS**

None known.

**SEE ALSO**

`AddEllipse`, `MoveTo`

**EXAMPLES**

```zig
const box = vector.Rect{ .x = 10, .y = 10, .width = 80, .height = 40 };
vb.AddRect(path, &box, 6, 6);
```

## ArcTo

SVG's elliptical arc from the current point to (x, y): the radii, the ellipse's angle in degrees, ARC_LARGE and ARC_SWEEP.

**SYNOPSIS**

```zig
fn ArcTo(vb: *VectorBase, path: *vector.Path, rx: f32, ry: f32, angle: f32, flags: u32, x: f32, y: f32) void
```

**SINCE**

1.1. LVO -72.

**INPUTS**

- `path` - the path.
- `rx`, `ry` - the ellipse's radii across and down, in the path's
  units; their sign is taken off.
- `angle` - how far the ellipse is turned, in degrees, clockwise on
  the screen.
- `flags` - `ARC_LARGE` for the arc of more than half the ellipse
  rather than less, `ARC_SWEEP` for the one going the way angles rise
  (clockwise on the screen) rather than the other.
- `x`, `y` - where the arc ends.

**RESULT**

Nothing.

**BEHAVIOR**

SVG's `A`: of the two ellipses of these radii and this angle through
the current point and (x, y), and the two arcs of each between them,
the one the flags pick. Radii too small to reach from one end to the
other are made just large enough, so the arc is half an ellipse; a
radius of 0 makes a line, and an arc ending where it starts is
nothing. It is added as a cubic curve for every quarter turn or less
of it, kept as curves until drawn. Without a current point it is
passed over, and after a `ClosePath` it starts a new contour, as
`LineTo` does.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, as before.

**NOTES**

Without the memory for it the arc is added as far as it fitted, a
curve at a time, and the path remembers that something did not fit
(see `MoveTo`).

**BUGS**

None known.

**SEE ALSO**

`CubicTo`, `AddEllipse`, `AddPathData`

**EXAMPLES**

```zig
// A half circle of radius 10 over the top from (0, 10) to (20, 10).
vb.MoveTo(path, 0, 10);
vb.ArcTo(path, 10, 10, 0, vector.ARC_SWEEP, 20, 10);
```

## ClearPath

The path emptied, its memory kept for the next one built in it.

**SYNOPSIS**

```zig
fn ClearPath(vb: *VectorBase, path: *vector.Path) void
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `path` - the path.

**RESULT**

Nothing.

**BEHAVIOR**

Every contour goes, and with it the current point and a want of
memory the path had met: it is as `CreatePath` made it, but it keeps
the memory it had grown to. A program that builds a path anew for
every frame clears one rather than making and giving back another.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, as before.

**BUGS**

None known.

**SEE ALSO**

`CreatePath`, `DisposePath`

**EXAMPLES**

```zig
vb.ClearPath(path);
vb.MoveTo(path, 0, 0);
```

## ClosePath

The contour closed back to where it started.

**SYNOPSIS**

```zig
fn ClosePath(vb: *VectorBase, path: *vector.Path) void
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `path` - the path.

**RESULT**

Nothing.

**BEHAVIOR**

A straight line back to the contour's start closes it: a stroke joins
its ends there instead of giving them caps. The current point is the
start from then on, and the next segment starts a new contour there.
A contour already closed, or no contour at all, is left as it is.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, as before.

**BUGS**

None known.

**SEE ALSO**

`MoveTo`, `StrokePath`

**EXAMPLES**

```zig
vb.MoveTo(path, 0, 0);
vb.LineTo(path, 10, 0);
vb.LineTo(path, 10, 10);
vb.ClosePath(path);
```

## CreateCanvasTagList

A canvas over the caller's pens (VCA_*); null without a size or the memory.

**SYNOPSIS**

```zig
fn CreateCanvasTagList(vb: *VectorBase, tags: ?[*]const utility.TagItem) ?*vector.Canvas
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `tags` - what the canvas is:
  - `VCA_Width`, `VCA_Height` - its size in pixels. Both are needed,
    each from 1 to 1048576.
  - `VCA_Pens` - `[*]graphics.Pen`, what is drawn on: 0xAARRGGBB, not
    premultiplied. Without it nothing is drawn until `SetCanvasPens`.
  - `VCA_BytesPerRow` - from one row of pens to the next; four times
    the width unless given.

**RESULT**

The canvas, or null: no size, or not the memory for its working
memory.

**BEHAVIOR**

The canvas holds the library's working memory for drawing on pens of
that size: the coverage of a band of rows, at most 512 KiB of it,
which a fill or a stroke is summed into a band at a time. A canvas of
360 by 360 pixels is one band; a larger one is drawn in as many as it
takes. The pens themselves are only written, where a shape covers
them.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The canvas is the caller's until `DisposeCanvas`, and one task's at a
time. The pens stay the caller's, and must last while they are drawn
on.

**NOTES**

The tags are read here and not kept. `TAG_IGNORE`, `TAG_MORE` and
`TAG_SKIP` are followed as utility.library follows them.

**BUGS**

None known.

**SEE ALSO**

`DisposeCanvas`, `SetCanvasPens`, `FillPath`, `StrokePath`

**EXAMPLES**

```zig
const tags = [_]utility.TagItem{
    .{ .tag = vector.VCA_Width, .data = 48 },
    .{ .tag = vector.VCA_Height, .data = 48 },
    .{ .tag = vector.VCA_Pens, .data = @intFromPtr(&pens) },
    .{},
};
const canvas = vb.CreateCanvasTagList(&tags) orelse return error.NoMemory;
defer vb.DisposeCanvas(canvas);
```

## CreatePath

An empty path; null without the memory for one.

**SYNOPSIS**

```zig
fn CreatePath(vb: *VectorBase) ?*vector.Path
```

**SINCE**

1.0. LVO -20.

**INPUTS**

None.

**RESULT**

The path, or null when there was not the memory for it.

**BEHAVIOR**

A path holds contours of lines and curves in the caller's own units,
built a segment at a time with `MoveTo`, `LineTo`, `QuadTo`, `CubicTo`
and `ClosePath`. Curves stay curves: the path is broken into lines
only when it is drawn, at the size it is drawn at, so one path is
drawn at any size. Its memory grows as segments are added.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `DisposePath`, and one task's at a time: the
library holds no lock for it.

**BUGS**

None known.

**SEE ALSO**

`DisposePath`, `ClearPath`, `MoveTo`, `FillPath`, `StrokePath`

**EXAMPLES**

```zig
const path = vb.CreatePath() orelse return error.NoMemory;
defer vb.DisposePath(path);
```

## CubicTo

A cubic curve from the current point to (x, y), leaving toward (x1, y1) and arriving from (x2, y2).

**SYNOPSIS**

```zig
fn CubicTo(vb: *VectorBase, path: *vector.Path, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `path` - the path.
- `x1`, `y1` - the first control point, in the path's units.
- `x2`, `y2` - the second.
- `x`, `y` - where the curve ends.

**RESULT**

Nothing.

**BEHAVIOR**

A Bézier curve, as SVG's `C` and Lottie's vertices draw: (x, y) is the
current point from then on. It is kept as a curve and broken into
lines only when drawn, enough of them that none strays from it by
more than a quarter of a pixel at the size it is drawn at. Without a
current point it is passed over, and after a `ClosePath` it starts a
new contour, as `LineTo` does.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, as before.

**NOTES**

Without the memory for it the curve is not added, and the path
remembers that something did not fit (see `MoveTo`).

**BUGS**

None known.

**SEE ALSO**

`QuadTo`, `LineTo`

**EXAMPLES**

```zig
// A quarter of a circle of radius 100 round (0, 0).
vb.MoveTo(path, 100, 0);
vb.CubicTo(path, 100, 55.23, 55.23, 100, 0, 100);
```

## DisposeCanvas

A canvas given back; its pens stay the caller's. Null does nothing.

**SYNOPSIS**

```zig
fn DisposeCanvas(vb: *VectorBase, canvas: ?*vector.Canvas) void
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `canvas` - what `CreateCanvasTagList` answered, or null.

**RESULT**

Nothing.

**BEHAVIOR**

The canvas's working memory goes back, and any layer still pushed with
it, not put down. The pens it drew on are left as they are, with what
was drawn on them.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The canvas is gone: the handle must not be used again. The pens are
the caller's to free.

**BUGS**

None known.

**SEE ALSO**

`CreateCanvasTagList`

**EXAMPLES**

```zig
vb.DisposeCanvas(canvas);
```

## DisposePath

A path given back. Null does nothing.

**SYNOPSIS**

```zig
fn DisposePath(vb: *VectorBase, path: ?*vector.Path) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `path` - what `CreatePath` answered, or null.

**RESULT**

Nothing.

**BEHAVIOR**

The path's memory goes back, its segments with it. What was drawn
with it stays on the pens it was drawn on.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The path is gone: the handle must not be used again.

**BUGS**

None known.

**SEE ALSO**

`CreatePath`, `ClearPath`

**EXAMPLES**

```zig
vb.DisposePath(path);
```

## FillPath

The path filled through the matrix (null: the identity) in the paint, by the rule (RULE_*).

**SYNOPSIS**

```zig
fn FillPath(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, rule: u32) i32
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `canvas` - what it is drawn on.
- `path` - what is filled. Every contour is closed for it, open or
  not, with a straight line back to its start.
- `matrix` - the path's units to pixels, or null when they are pixels.
- `paint` - what it is painted in (`vector.Paint`): one colour, or
  since 1.1 a linear or radial gradient with its stops, spread and
  matrix (1.0 paints a gradient's colour), at the paint's opacity.
  A gradient with no stops paints nothing, one with one paints its
  colour, and one of no length or radius its last stop's colour, as
  SVG has it.
- `rule` - `RULE_NONZERO`: inside wherever the contours wind round a
  point; `RULE_EVENODD`: wherever they wind round it an odd number of
  times, so a contour inside another is a hole.

**RESULT**

`VECTOR_OK`, or `VECTORERR_NOMEM` when the path had run out of memory
as it was built or there was no room to break it into lines: what
there was is drawn.

**BEHAVIOR**

The curves are broken into lines at the size they are drawn at, and
every pixel is painted by how much of it the shape covers, so the
edges are smooth. The paint goes over what each pen held: a pen's
share of the shape times the paint's opacity of it, mixed with the
pen by its own coverage. Pixels off the canvas are passed over; so
is everything with no pens set.

A gradient is laid in its own units, taken into the path's by the
paint's matrix and then to pixels by this one: each pixel's centre
is taken back to see where along it the pixel is. Its colour there
comes from 256 made from the stops for the fill, mixed as they are
and not premultiplied. A radial gradient's focus outside its circle
makes a cone, beside which nothing is painted, as SVG 2 draws it.

With a layer pushed (`PushLayer`) it is drawn on the layer.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The path, the matrix and the paint are the caller's and only read;
the pens are written.

**BUGS**

None known.

**SEE ALSO**

`StrokePath`, `CreateCanvasTagList`, `MoveTo`, `PathBounds`, `PushLayer`

**EXAMPLES**

```zig
const red = vector.Paint{ .colour = .{ .r = 1 } };
const twice = vector.Matrix.scale(2, 2);
_ = vb.FillPath(canvas, path, &twice, &red, vector.RULE_NONZERO);
```

## LineTo

A line from the current point to (x, y).

**SYNOPSIS**

```zig
fn LineTo(vb: *VectorBase, path: *vector.Path, x: f32, y: f32) void
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `path` - the path.
- `x`, `y` - where the line ends, in the path's units.

**RESULT**

Nothing.

**BEHAVIOR**

(x, y) is the current point from then on. Before the path's first
`MoveTo` there is nowhere for a line to start, and it is passed over.
After a `ClosePath` the line starts a new contour where the closed
one began, as SVG's path data does.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, as before.

**NOTES**

Without the memory for it the line is not added, and the path
remembers that something did not fit (see `MoveTo`).

**BUGS**

None known.

**SEE ALSO**

`MoveTo`, `QuadTo`, `CubicTo`, `ClosePath`

**EXAMPLES**

```zig
vb.MoveTo(path, 0, 0);
vb.LineTo(path, 100, 0);
vb.LineTo(path, 50, 80);
vb.ClosePath(path);
```

## MoveTo

A new contour started at (x, y).

**SYNOPSIS**

```zig
fn MoveTo(vb: *VectorBase, path: *vector.Path, x: f32, y: f32) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `path` - the path.
- `x`, `y` - where the contour starts, in the path's units.

**RESULT**

Nothing.

**BEHAVIOR**

A contour still open ends where it is: a fill closes it with a
straight line, a stroke gives it its caps. (x, y) is the current
point, where the next segment starts. A move followed by nothing is a
contour of one point, which a stroke with round caps draws as a dot.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, as before.

**NOTES**

Without the memory for it the move is not added, and the path
remembers that something did not fit: `FillPath` and `StrokePath`
draw what there is and answer `VECTORERR_NOMEM`.

**BUGS**

None known.

**SEE ALSO**

`LineTo`, `CubicTo`, `ClosePath`

**EXAMPLES**

```zig
vb.MoveTo(path, 10, 10);
vb.LineTo(path, 90, 10);
```

## PathBounds

The bounds of the path's curves through the matrix (null: the identity); false for an empty path.

**SYNOPSIS**

```zig
fn PathBounds(vb: *VectorBase, path: *const vector.Path, matrix: ?*const vector.Matrix, bounds: *vector.Rect) bool
```

**SINCE**

1.1. LVO -88.

**INPUTS**

- `path` - the path.
- `matrix` - the path's units to the ones the bounds are wanted in, or
  null for the path's own.
- `bounds` - where they are put.

**RESULT**

True and `bounds` filled in; false for a path with no point, and
`bounds` left as it was.

**BEHAVIOR**

The smallest rectangle round the path's curves as drawn through the
matrix - of the curves themselves, not of their control points -
which is SVG's bounding box, the one `objectBoundingBox` gradients
are laid over. Every point counts, a contour's move with the rest. A
path with nothing but a point has bounds of no size.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The path and the matrix are the caller's and only read.

**BUGS**

None known.

**SEE ALSO**

`FillPath`, `AddPathData`

**EXAMPLES**

```zig
// A gradient laid over the shape's box, as objectBoundingBox has it.
var box: vector.Rect = undefined;
if (vb.PathBounds(path, null, &box)) {
    paint.matrix = vector.Matrix.translate(box.x, box.y).then(vector.Matrix.scale(box.width, box.height));
}
```

## PopLayer

The last layer pushed put down on what is under it.

**SYNOPSIS**

```zig
fn PopLayer(vb: *VectorBase, canvas: *vector.Canvas) void
```

**SINCE**

1.1. LVO -96.

**INPUTS**

- `canvas` - the canvas.

**RESULT**

Nothing.

**BEHAVIOR**

What was drawn on the layer goes down on what is under it - the layer
it is inside, or the pens - at the layer's opacity, each pixel over
what is there as a paint goes; and the layer is given back. A layer
that had no memory, or was past the most, is only ended. With no
layer pushed it does nothing.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The pens under the layer are written.

**NOTES**

Pens set with `SetCanvasPens` while a layer is pushed are the ones
it goes down on.

**BUGS**

None known.

**SEE ALSO**

`PushLayer`

**EXAMPLES**

```zig
vb.PopLayer(canvas);
```

## PushLayer

What is drawn until PopLayer goes onto a layer of its own, put down at the opacity.

**SYNOPSIS**

```zig
fn PushLayer(vb: *VectorBase, canvas: *vector.Canvas, opacity: f32) i32
```

**SINCE**

1.1. LVO -92.

**INPUTS**

- `canvas` - the canvas.
- `opacity` - how much of the layer shows when it is put down, 0 to 1:
  SVG's `opacity` on a group.

**RESULT**

`VECTOR_OK`; `VECTORERR_NOMEM` without the memory for the layer, which
is then drawn without one; `VECTORERR_DEPTH` past `MAX_LAYERS` layers
one inside another, when the layer is nothing. Whatever it answers,
a `PopLayer` goes with it.

**BEHAVIOR**

Every fill and stroke from now until the `PopLayer` that goes with
it is drawn onto pens of the layer's own, clear and the canvas's
size; the pop puts them down on what is under them at `opacity`. So a
group's shapes that overlap are seen as one, at the group's opacity,
not through each other. Layers go inside one another.

Without the memory for the layer, the opacity goes into every paint
drawn until the pop instead, which is the same where the shapes do
not overlap - drawn a little wrong rather than not at all.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The layer is the canvas's, given back by the pop or by
`DisposeCanvas`.

**NOTES**

A layer is four bytes a pixel of the whole canvas, cleared when
pushed: on a small machine, a large canvas's layers are what runs
out first.

**BUGS**

None known.

**SEE ALSO**

`PopLayer`, `FillPath`

**EXAMPLES**

```zig
_ = vb.PushLayer(canvas, 0.5);
_ = vb.FillPath(canvas, body, null, &grey, vector.RULE_NONZERO);
_ = vb.StrokePath(canvas, body, null, &black, &outline);
vb.PopLayer(canvas);
```

## QuadTo

A quadratic curve from the current point to (x, y), pulled toward (x1, y1).

**SYNOPSIS**

```zig
fn QuadTo(vb: *VectorBase, path: *vector.Path, x1: f32, y1: f32, x: f32, y: f32) void
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `path` - the path.
- `x1`, `y1` - the control point, in the path's units.
- `x`, `y` - where the curve ends.

**RESULT**

Nothing.

**BEHAVIOR**

The curve leaves the current point toward (x1, y1) and arrives at
(x, y) from it, as TrueType's and SVG's `Q` curves do; (x, y) is the
current point from then on. It is kept as a curve and broken into
lines only when drawn. Without a current point it is passed over, and
after a `ClosePath` it starts a new contour, as `LineTo` does.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, as before.

**NOTES**

Without the memory for it the curve is not added, and the path
remembers that something did not fit (see `MoveTo`).

**BUGS**

None known.

**SEE ALSO**

`CubicTo`, `LineTo`

**EXAMPLES**

```zig
vb.MoveTo(path, 0, 50);
vb.QuadTo(path, 50, 0, 100, 50);
```

## SetCanvasPens

The pens the canvas draws on from now on; null draws nothing.

**SYNOPSIS**

```zig
fn SetCanvasPens(vb: *VectorBase, canvas: *vector.Canvas, pens: ?[*]graphics.Pen, bytes_per_row: u32) void
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `canvas` - the canvas.
- `pens` - its width by its height of them, 0xAARRGGBB, or null.
- `bytes_per_row` - from one row of them to the next; 0 for four
  times the canvas's width.

**RESULT**

Nothing.

**BEHAVIOR**

The canvas keeps its size and its working memory, and draws on these
pens instead: a program that draws frame after frame into buffers of
one size hands each over in turn. With null, a fill or a stroke
draws nothing.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The pens stay the caller's, and must last while they are drawn on.

**BUGS**

None known.

**SEE ALSO**

`CreateCanvasTagList`, `FillPath`

**EXAMPLES**

```zig
vb.SetCanvasPens(canvas, frame.pens, frame.bytes_per_row);
```

## StrokePath

The path stroked in its own units, then through the matrix (null: the identity), in the paint.

**SYNOPSIS**

```zig
fn StrokePath(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, stroke: *const vector.Stroke) i32
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `canvas` - what it is drawn on.
- `path` - what is stroked: its open contours with caps at their
  ends, its closed ones joined all round.
- `matrix` - the path's units to pixels, or null when they are pixels.
- `paint` - what it is painted in, as `FillPath` paints.
- `stroke` - how (`vector.Stroke`), in the path's own units: the
  width, the joins (`JOIN_MITER`, `JOIN_ROUND`, `JOIN_BEVEL`), the caps
  (`CAP_BUTT`, `CAP_ROUND`, `CAP_SQUARE`), the miter limit, in stroke
  widths, and since 1.1 the dashes (1.0 draws a dashed stroke whole).

**RESULT**

`VECTOR_OK`, or `VECTORERR_NOMEM` as `FillPath` answers it.

**BEHAVIOR**

The stroke is made of pieces in the path's units - a quadrilateral a
line, a piece at each corner, a cap at each open end - and those are
drawn through the matrix, so a stroke drawn through one that stretches
a way is stretched with it, as SVG draws one. A miter longer than the
limit is bevelled. A contour of one point is a dot when the caps are
round, and nothing otherwise; a stroke under a fiftieth of a pixel
wide is not drawn.

Dashes are cut from each contour in the path's units, from
`dash_offset` along it, before it is stroked, so each dash has its
caps; they go on from one segment to the next and round a closed
contour, whose last dash is joined to its first. An odd count of
lengths is gone through twice, and lengths that are negative or come
to nothing draw the stroke whole, as SVG has it. A stroke is cut at
most 65536 times; past that it goes on as the dash or gap it is in.

With a layer pushed (`PushLayer`) it is drawn on the layer.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The path, the matrix, the paint and the stroke are the caller's and
only read; the pens are written.

**BUGS**

None known.

**SEE ALSO**

`FillPath`, `ClosePath`

**EXAMPLES**

```zig
const black = vector.Paint{};
const line = vector.Stroke{ .width = 2, .join = vector.JOIN_ROUND, .cap = vector.CAP_ROUND };
_ = vb.StrokePath(canvas, path, null, &black, &line);
```
