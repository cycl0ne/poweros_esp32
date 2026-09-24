# layers.library

layers.library's functions: windows that share one display buffer.
A layer is a rectangle of a display that something draws into without
having to know what is in front of it. This library works out which
pieces of each layer are visible and hands the answer to
graphics.library as a clip target list on the layer's RastPort, so a
layer draws in its own coordinates and graphics.library never learns
what a window is. Open it with OpenLibrary("layers.library", 0).

Generated from the source by `./zig build autodoc`.

## Index

- [BeginUpdate](#beginupdate) - Narrows a layer to what it owes a redraw.
- [BehindLayer](#behindlayer) - Puts a layer behind every other ordinary one.
- [CreateLayerTagList](#createlayertaglist) - Makes a new layer on a display.
- [DeleteLayer](#deletelayer) - Takes a layer away.
- [DisposeLayerInfo](#disposelayerinfo) - Throws a LayerInfo away, and every layer still in it.
- [DoHookClipRects](#dohookcliprects) - Calls a hook once for each piece of a RastPort that may be drawn on.
- [EndUpdate](#endupdate) - Puts back what `BeginUpdate` narrowed.
- [GetLayerAttrs](#getlayerattrs) - Reads a layer.
- [InstallClipRegion](#installclipregion) - Narrows a layer to a region of the caller's own.
- [InstallLayerHook](#installlayerhook) - Changes what paints a part of a layer that has nothing in it yet.
- [LayersErrorText](#layerserrortext) - Says what an `LERR_` code means, in words.
- [LockLayer](#locklayer) - Holds one layer still.
- [LockLayerInfo](#locklayerinfo) - Holds the list of layers still: which there are, and in what order.
- [LockLayers](#locklayers) - Holds every layer of a display still.
- [MoveLayer](#movelayer) - Moves a layer.
- [MoveLayerInFrontOf](#movelayerinfrontof) - Puts one layer directly in front of another.
- [MoveSizeLayer](#movesizelayer) - Moves a layer and changes its size together.
- [NewLayerInfo](#newlayerinfo) - Makes the LayerInfo of one display, with no layers on it yet.
- [ScrollLayer](#scrolllayer) - Moves the window a `LAYERSUPER` layer shows of its own bitmap.
- [SizeLayer](#sizelayer) - Changes a layer's size, its top-left staying where it is.
- [UnlockLayer](#unlocklayer) - Lets a layer go again.
- [UnlockLayerInfo](#unlocklayerinfo) - Lets the list of layers go again.
- [UnlockLayers](#unlocklayers) - Lets every layer of a display go again.
- [UpfrontLayer](#upfrontlayer) - Puts a layer in front of every other one.
- [WhichLayer](#whichlayer) - Tells which layer a point of the display is in.

## BeginUpdate

Narrows a layer to what it owes a redraw.

**SYNOPSIS**

```zig
fn BeginUpdate(lb: *LayersBase, layer: *Layer) bool
```

**SINCE**

0.1. LVO -60.

**INPUTS**

- `layer` - the layer.

**RESULT**

True if there was damage and the layer is now narrowed to it. False if
there was none, if an update was already on, or with `LERR_NO_MEMORY` in
the layer if there was no memory.

**BEHAVIOR**

Between this and `EndUpdate` a program can draw all of itself and touch
only the parts that were uncovered: the rest of the layer is clipped
away. The whole clip list is put aside rather than freed, since it is
what the layer goes back to and working it out again could fail for want
of memory just when there is none.

**CONTEXT**

- Waits: yes, while another task holds the layer.
- Interrupts: no. It may wait, and it allocates.
- Forbid: must not be held: waiting for the lock would break it.
- Process: a Task will do.

**OWNERSHIP**

Nothing the caller has to free.

**BUGS**

None known.

**SEE ALSO**

`EndUpdate`, `GetLayerAttrs`

**EXAMPLES**

```zig
if (lb.BeginUpdate(layer)) {
    drawWholeWindow(rp); // only the damage lands
    lb.EndUpdate(layer, true);
}
```

## BehindLayer

Puts a layer behind every other ordinary one.

**SYNOPSIS**

```zig
fn BehindLayer(lb: *LayersBase, layer: *Layer) bool
```

**SINCE**

0.1. LVO -40.

**INPUTS**

- `layer` - the layer.

**RESULT**

True, or false with `LERR_NO_MEMORY` in the layer if the tiling could
not be worked out.

**BEHAVIOR**

Behind the ordinary layers, but still in front of the backdrop ones -
which is what makes them backdrops. What it now covers is lost to those layers, and what it uncovers is
given back to them - as damage for a simple layer, out of its keeping
for a smart or super one.

**CONTEXT**

- Waits: yes, while another task holds the display's layers.
- Interrupts: no. It may wait, and it allocates.
- Forbid: must not be held: waiting for the locks would break it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated that outlives the call.

**BUGS**

None known.

**SEE ALSO**

`UpfrontLayer`, `MoveLayerInFrontOf`

**EXAMPLES**

```zig
_ = lb.BehindLayer(layer);
```

## CreateLayerTagList

Makes a new layer on a display.

**SYNOPSIS**

```zig
fn CreateLayerTagList(lb: *LayersBase, info: *LayerInfo, tags: ?[*]const TagItem) ?*Layer
```

**SINCE**

0.1. LVO -28.

**INPUTS**

- `info` - the display it belongs to.
- `tags` - the `LATAG_` options:
  - `LATAG_Bounds` - required: a `*const Rect` in the display's
    coordinates, with something in it.
  - `LATAG_Refresh` - `LAYERSIMPLE` (the default), `LAYERSMART` or
    `LAYERSUPER`.
  - `LATAG_SuperBitMap` - for `LAYERSUPER`: the `*Surface` it draws
    into, at least as big as the layer.
  - `LATAG_Behind` - non-zero puts it behind the ordinary layers instead
    of in front.
  - `LATAG_Backdrop` - non-zero keeps it behind every ordinary layer.
  - `LATAG_BackFill` - what paints its empty parts: 0 for its background
    pen, `LAYERS_NOBACKFILL` for nothing, or a `*Hook`.
  - `LATAG_ErrorPtr` - an `*i32` that gets the reason if it fails.

**RESULT**

The layer, or null. `LATAG_ErrorPtr` then holds why: `LERR_BAD_BOUNDS`
for no rectangle or an empty one, `LERR_NO_SUPERBITMAP` for a
`LAYERSUPER` layer without a bitmap big enough, `LERR_NO_RASTPORT`, or
`LERR_NO_MEMORY`.

**BEHAVIOR**

The layer gets a RastPort of its own whose coordinates start at the
layer's corner, so its program draws at `(0,0)` and means the layer's
top-left. Every layer's visible area is worked out again, and a layer
this one now covers loses those pixels. The new layer is painted with
its backfill before anyone can see it, since what is on the display
there belongs to whoever had it before; coming into view is not damage.

The refresh modes differ in what happens to a covered piece:
`LAYERSIMPLE` loses it and is owed it back as damage, `LAYERSMART`
keeps it in a surface of its own and puts it back, and `LAYERSUPER`
keeps it in the program's own bitmap.

**CONTEXT**

- Waits: yes, while another task holds the display's layers.
- Interrupts: no. It may wait, and it allocates.
- Forbid: must not be held: waiting for the locks would break it.
- Process: a Task will do.

**OWNERSHIP**

The layer and its RastPort are the library's; `DeleteLayer` gives them
back, and the caller must not free the RastPort itself. A `LAYERSUPER`
bitmap stays the caller's, and must outlive the layer.

**NOTES**

A layer made while every layer of the display is held with `LockLayers`
is held as well, so that the release gives back what it took.

**BUGS**

None known.

**SEE ALSO**

`DeleteLayer`, `GetLayerAttrs`, `NewLayerInfo`

**EXAMPLES**

```zig
const where = graphics.Rect{ .min_x = 40, .min_y = 30, .max_x = 240, .max_y = 150 };
var err: i32 = 0;
const tags = [_]TagItem{
    .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&where) },
    .{ .tag = layers.LATAG_ErrorPtr, .data = @intFromPtr(&err) },
    .{},
};
const layer = lb.CreateLayerTagList(info, &tags) orelse return error.NoLayer;
```

## DeleteLayer

Takes a layer away.

**SYNOPSIS**

```zig
fn DeleteLayer(lb: *LayersBase, layer: ?*Layer) void
```

**SINCE**

0.1. LVO -32.

**INPUTS**

- `layer` - the layer. Null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

Its RastPort, its regions and everything it kept go back. What was
behind it is uncovered: a simple layer there is owed the pixels as
damage, a smart or super one gets them back from its keeping.

**CONTEXT**

- Waits: yes, while another task holds the display's layers.
- Interrupts: no. It may wait, and it frees memory.
- Forbid: must not be held: waiting for the locks would break it.
- Process: a Task will do.

**OWNERSHIP**

The layer and its RastPort are gone. A `LAYERSUPER` bitmap stays the
caller's.

**BUGS**

None known.

**SEE ALSO**

`CreateLayerTagList`, `DisposeLayerInfo`

**EXAMPLES**

```zig
lb.DeleteLayer(layer);
```

## DisposeLayerInfo

Throws a LayerInfo away, and every layer still in it.

**SYNOPSIS**

```zig
fn DisposeLayerInfo(lb: *LayersBase, info: ?*LayerInfo) void
```

**SINCE**

0.1. LVO -24.

**INPUTS**

- `info` - the LayerInfo. Null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

Each layer is taken away with `DeleteLayer`, so no RastPort or region
is left behind, and then the pool that held every clip target goes back
in one call. Nothing has to have been taken away first.

**CONTEXT**

- Waits: yes, while another task holds the display's layers.
- Interrupts: no. It may wait, and it frees memory.
- Forbid: must not be held: waiting for the locks would break it.
- Process: a Task will do.

**OWNERSHIP**

The LayerInfo and every layer in it are gone, with their RastPorts.
The display's own RastPort, which `NewLayerInfo` was given, stays the
caller's.

**BUGS**

None known.

**SEE ALSO**

`NewLayerInfo`, `DeleteLayer`

**EXAMPLES**

```zig
lb.DisposeLayerInfo(info);
```

## DoHookClipRects

Calls a hook once for each piece of a RastPort that may be drawn on.

**SYNOPSIS**

```zig
fn DoHookClipRects(lb: *LayersBase, hook: *utility.Hook, rp: *graphics.RastPort, area: *const graphics.Rect) void
```

**SINCE**

0.1. LVO -112.

**INPUTS**

- `hook` - called with the RastPort as the object and a `BackFillMsg` as
  the message, whose `area` is the part of `area` that piece covers, in
  the RastPort's own coordinates.
- `rp` - the RastPort. It need not be a layer's: one rectangle, a clip
  region's several, and a layer's pieces are all walked the same way.
- `area` - what to work over, in the RastPort's coordinates.

**RESULT**

Nothing.

**BEHAVIOR**

What a layer can draw on is several rectangles, and once it is covered
they are not all in the same surface. This hands them over one at a
time, so that something working piece by piece - measuring, counting,
painting a pattern that has to be anchored - does not have to know any
of that. The hook draws through the RastPort, whose clipping confines
it. `BackFillMsg.layer` is null: a RastPort does not say which layer it
belongs to, and a caller that has one already knows.

**CONTEXT**

- Waits: only if the hook does.
- Interrupts: no. It may allocate.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is kept. The hook and the RastPort stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`InstallLayerHook`

**EXAMPLES**

```zig
lb.DoHookClipRects(&count_hook, rp, &whole);
```

## EndUpdate

Puts back what `BeginUpdate` narrowed.

**SYNOPSIS**

```zig
fn EndUpdate(lb: *LayersBase, layer: *Layer, done: bool) void
```

**SINCE**

0.1. LVO -64.

**INPUTS**

- `layer` - the layer.
- `done` - true if all of the damage was drawn, which clears it. False
  keeps it, so the layer still owes a redraw and the next `BeginUpdate`
  offers the same again.

**RESULT**

Nothing. Without an update on, nothing happens.

**BEHAVIOR**

The clip list `BeginUpdate` put aside comes back, and the narrowed one
is freed.

**CONTEXT**

- Waits: yes, while another task holds the layer.
- Interrupts: no. It may wait.
- Forbid: must not be held: waiting for the lock would break it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`BeginUpdate`

**EXAMPLES**

```zig
lb.EndUpdate(layer, true);
```

## GetLayerAttrs

Reads a layer.

**SYNOPSIS**

```zig
fn GetLayerAttrs(lb: *LayersBase, layer: *Layer, tags: ?[*]const TagItem) void
```

**SINCE**

0.1. LVO -52.

**INPUTS**

- `layer` - the layer.
- `tags` - the `LATAG_Get` names, each `ti_Data` a pointer to where the
  value goes: `LATAG_GetBounds` a `*Rect`, `LATAG_GetFlags` a `*u32`,
  `LATAG_GetRastPort`, `LATAG_GetDamage` and `LATAG_GetInFront` a
  `*usize`, `LATAG_GetScroll` a `*Point`, `LATAG_GetLastError` an
  `*i32`.

**RESULT**

Nothing; the values are where the tags point.

**BEHAVIOR**

A tag with a null pointer is passed over, and one the library does not
know is ignored, so a program built against a later SDK still works.
`LATAG_GetInFront` answers 0 for the frontmost layer.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. What comes back is the library's: the RastPort is
the one to draw with, and the damage region is to be read, not kept or
disposed of.

**BUGS**

None known.

**SEE ALSO**

`CreateLayerTagList`, `BeginUpdate`

**EXAMPLES**

```zig
var rp: usize = 0;
const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&rp) }, .{} };
lb.GetLayerAttrs(layer, &ask);
```

## InstallClipRegion

Narrows a layer to a region of the caller's own.

**SYNOPSIS**

```zig
fn InstallClipRegion(lb: *LayersBase, layer: *Layer, region: ?*graphics.Region) ?*graphics.Region
```

**SINCE**

0.1. LVO -56.

**INPUTS**

- `layer` - the layer.
- `region` - the region, in the **layer's** coordinates, or null to take
  one off again.

**RESULT**

What was installed before, for the caller to dispose of, or null.
`LERR_NO_MEMORY` in the layer if the clipping could not be rebuilt.

**BEHAVIOR**

It is folded together with what the layer can actually see, which only
this library knows. While `BeginUpdate` is on, the change takes effect
at `EndUpdate`.

**CONTEXT**

- Waits: yes, while another task holds the layer.
- Interrupts: no. It may wait.
- Forbid: must not be held: waiting for the lock would break it.
- Process: a Task will do.

**OWNERSHIP**

The region stays the caller's and is only read. It must not be disposed
of or changed while it is installed.

**BUGS**

None known.

**SEE ALSO**

`BeginUpdate`, `EndUpdate`

**EXAMPLES**

```zig
const old = lb.InstallClipRegion(layer, inner);
defer _ = lb.InstallClipRegion(layer, old);
```

## InstallLayerHook

Changes what paints a part of a layer that has nothing in it yet.

**SYNOPSIS**

```zig
fn InstallLayerHook(lb: *LayersBase, layer: *Layer, hook: usize) usize
```

**SINCE**

0.1. LVO -108.

**INPUTS**

- `layer` - the layer.
- `hook` - a `*Hook`, or 0 for the layer's own background pen, or
  `LAYERS_NOBACKFILL` for nothing at all: what `LATAG_BackFill` takes.

**RESULT**

What was there before, to be put back or thrown away.

**BEHAVIOR**

It paints nothing by itself; it says what the next painting will use - a
layer made bigger, uncovered, or created after this. The layer's
RastPort carries it too, so anything handed the RastPort alone paints
the ground the same way.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The hook stays the caller's and must outlive its use by the layer.

**BUGS**

None known.

**SEE ALSO**

`DoHookClipRects`, `CreateLayerTagList`

**EXAMPLES**

```zig
const old = lb.InstallLayerHook(layer, @intFromPtr(&pattern_hook));
```

## LayersErrorText

Says what an `LERR_` code means, in words.

**SYNOPSIS**

```zig
fn LayersErrorText(_: *LayersBase, code: i32) [*:0]const u8
```

**SINCE**

0.1. LVO -116.

**INPUTS**

- `code` - an `LERR_` code, as `LATAG_ErrorPtr` or `LATAG_GetLastError`
  gives it.

**RESULT**

The text, which is the library's and not the caller's, so a program
built against an older SDK still prints something true about a code
that arrived after it. A code the library does not know is "unknown
error" rather than null, so the answer can be printed unchecked.

**BEHAVIOR**

A table of the codes the library returns.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The text is read-only and lives as long as the
library.

**BUGS**

None known.

**SEE ALSO**

`CreateLayerTagList`, `GetLayerAttrs`

**EXAMPLES**

```zig
print("layer: %s\n", .{lb.LayersErrorText(err)});
```

## LockLayer

Holds one layer still.

**SYNOPSIS**

```zig
fn LockLayer(lb: *LayersBase, layer: *Layer) void
```

**SINCE**

0.1. LVO -68.

**INPUTS**

- `layer` - the layer.

**RESULT**

Nothing.

**BEHAVIOR**

Its clipping cannot change while it is held, so a drawing call cannot
have the ground move under it. It nests: the same task may take it again
and must let it go as often.

**CONTEXT**

- Waits: yes, while another task holds it.
- Interrupts: no. It waits.
- Forbid: must not be held: waiting would break it.
- Process: a Task will do.

**OWNERSHIP**

The caller holds the layer until `UnlockLayer`.

**NOTES**

**A task drawing into a layer must hold this while it draws.** The calls
that rebuild a layer's clipping take it themselves, but the walking of
that clipping is done inside graphics.library, which has no idea layers
exist - so only the task that decided to draw can take it. Without it, a
retile can free the clip list a drawing call is part way through.

Be brief: anything that would move or resize the layer waits for it.

**BUGS**

None known.

**SEE ALSO**

`UnlockLayer`, `LockLayers`

**EXAMPLES**

```zig
lb.LockLayer(layer);
defer lb.UnlockLayer(layer);
gb.RectFill(rp, &area);
```

## LockLayerInfo

Holds the list of layers still: which there are, and in what order.

**SYNOPSIS**

```zig
fn LockLayerInfo(lb: *LayersBase, info: *LayerInfo) void
```

**SINCE**

0.1. LVO -84.

**INPUTS**

- `info` - the display's layers.

**RESULT**

Nothing.

**BEHAVIOR**

What it protects is the order, not any one layer's pixels. Anything
walking the layers - `WhichLayer` over several points, say - wants it.
It nests.

**CONTEXT**

- Waits: yes, while another task holds it.
- Interrupts: no. It waits.
- Forbid: must not be held: waiting would break it.
- Process: a Task will do.

**OWNERSHIP**

The caller holds the list until `UnlockLayerInfo`.

**BUGS**

None known.

**SEE ALSO**

`UnlockLayerInfo`, `LockLayers`

**EXAMPLES**

```zig
lb.LockLayerInfo(info);
defer lb.UnlockLayerInfo(info);
```

## LockLayers

Holds every layer of a display still.

**SYNOPSIS**

```zig
fn LockLayers(lb: *LayersBase, info: *LayerInfo) void
```

**SINCE**

0.1. LVO -76.

**INPUTS**

- `info` - the display's layers.

**RESULT**

Nothing.

**BEHAVIOR**

The list is taken first, then all of the layers at once. Taking them one
at a time would let two callers going opposite ways each hold what the
other waits for; one call over the whole list cannot. A layer made while
they are held is held as well. It nests.

**CONTEXT**

- Waits: yes, while another task holds the list or a layer.
- Interrupts: no. It waits.
- Forbid: must not be held: waiting would break it.
- Process: a Task will do.

**OWNERSHIP**

The caller holds the list and every layer until `UnlockLayers`.

**BUGS**

None known.

**SEE ALSO**

`UnlockLayers`, `LockLayer`, `LockLayerInfo`

**EXAMPLES**

```zig
lb.LockLayers(info);
defer lb.UnlockLayers(info);
```

## MoveLayer

Moves a layer.

**SYNOPSIS**

```zig
fn MoveLayer(lb: *LayersBase, layer: *Layer, dx: i32, dy: i32) bool
```

**SINCE**

0.1. LVO -92.

**INPUTS**

- `layer` - the layer.
- `dx` - how far across, in the display's coordinates.
- `dy` - how far down.

**RESULT**

True, or false with the reason in the layer: `LERR_BAD_BOUNDS` or
`LERR_NO_MEMORY`, as for `MoveSizeLayer`.

**BEHAVIOR**

`MoveSizeLayer` with no change of size. A simple layer carries the
pixels that stay visible and is owed the rest; a smart layer is owed
nothing.

**CONTEXT**

- Waits: yes, while another task holds the display's layers.
- Interrupts: no. It may wait, it allocates, and it draws.
- Forbid: must not be held: waiting for the locks would break it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated that outlives the call.

**BUGS**

None known.

**SEE ALSO**

`MoveSizeLayer`, `SizeLayer`

**EXAMPLES**

```zig
_ = lb.MoveLayer(layer, 16, -8);
```

## MoveLayerInFrontOf

Puts one layer directly in front of another.

**SYNOPSIS**

```zig
fn MoveLayerInFrontOf(lb: *LayersBase, layer: *Layer, other: *Layer) bool
```

**SINCE**

0.1. LVO -44.

**INPUTS**

- `layer` - the layer to move.
- `other` - the layer it goes in front of. Both are of one LayerInfo.

**RESULT**

True, or false with `LERR_NO_MEMORY` in the layer if the tiling could
not be worked out. A layer put in front of itself stays and answers
true.

**BEHAVIOR**

What it now covers is lost to those layers, and what it uncovers is
given back to them - as damage for a simple layer, out of its keeping
for a smart or super one.

**CONTEXT**

- Waits: yes, while another task holds the display's layers.
- Interrupts: no. It may wait, and it allocates.
- Forbid: must not be held: waiting for the locks would break it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated that outlives the call.

**BUGS**

None known.

**SEE ALSO**

`UpfrontLayer`, `BehindLayer`

**EXAMPLES**

```zig
_ = lb.MoveLayerInFrontOf(dialog, parent);
```

## MoveSizeLayer

Moves a layer and changes its size together.

**SYNOPSIS**

```zig
fn MoveSizeLayer(lb: *LayersBase, layer: *Layer, dx: i32, dy: i32, dw: i32, dh: i32) bool
```

**SINCE**

0.1. LVO -100.

**INPUTS**

- `layer` - the layer.
- `dx` - how far its top-left moves across, in the display's coordinates.
- `dy` - how far it moves down.
- `dw` - how much wider it gets; negative makes it narrower.
- `dh` - how much taller it gets; negative makes it shorter.

**RESULT**

True, or false with the reason in the layer: `LERR_BAD_BOUNDS` if it
would be left with nothing in it, `LERR_NO_MEMORY` if the tiling could
not be worked out. All four 0 does nothing and answers true.

**BEHAVIOR**

One retile and one pass over the pixels, where a move and then a resize
would be two of each and would put the layer somewhere it was never
asked to be in between. A layer draws at its own corner, so nothing it
has drawn moves in its own coordinates. A simple layer keeps the pixels
that are visible before and after - they are copied across the display -
and is owed the rest as damage; a smart layer is owed nothing. What a
growing layer gains has never held anything and is painted with its
backfill.

**CONTEXT**

- Waits: yes, while another task holds the display's layers.
- Interrupts: no. It may wait, it allocates, and it draws.
- Forbid: must not be held: waiting for the locks would break it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated that outlives the call.

**BUGS**

None known.

**SEE ALSO**

`MoveLayer`, `SizeLayer`

**EXAMPLES**

```zig
_ = lb.MoveSizeLayer(layer, 10, 0, 40, 20);
```

## NewLayerInfo

Makes the LayerInfo of one display, with no layers on it yet.

**SYNOPSIS**

```zig
fn NewLayerInfo(lb: *LayersBase, rp: *graphics.RastPort) ?*LayerInfo
```

**SINCE**

0.1. LVO -20.

**INPUTS**

- `rp` - the RastPort the display is drawn on, as `CreateRastPortTagList`
  answers it with no tags. It says how big the display is and where its
  pixels are. It is read, not taken over.

**RESULT**

The LayerInfo, or null: no memory, or nothing behind `rp` to draw on -
which is what a machine with no display gives.

**BEHAVIOR**

Everything about the display comes out of the RastPort, so the library
never reaches past graphics.library to ask what the machine has. The
LayerInfo keeps a RastPort of its own on the same buffer, for putting a
covered piece of a layer back, and a memory pool for the clip targets a
retile makes by the hundred.

**CONTEXT**

- Waits: no.
- Interrupts: no. It allocates.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The caller owns the LayerInfo until `DisposeLayerInfo`, which also takes
away every layer still in it. `rp` stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`DisposeLayerInfo`, `CreateLayerTagList`

**EXAMPLES**

```zig
const info = lb.NewLayerInfo(screen_rp) orelse return error.NoDisplay;
defer lb.DisposeLayerInfo(info);
```

## ScrollLayer

Moves the window a `LAYERSUPER` layer shows of its own bitmap.

**SYNOPSIS**

```zig
fn ScrollLayer(lb: *LayersBase, layer: *Layer, dx: i32, dy: i32) bool
```

**SINCE**

0.1. LVO -104.

**INPUTS**

- `layer` - a layer made with `LAYERSUPER`.
- `dx` - how far across the bitmap; positive shows more of the right.
- `dy` - how far down; positive shows more of the bottom.

**RESULT**

True, or false with the reason in the layer: `LERR_NO_SUPERBITMAP` for a
layer without a bitmap of its own, `LERR_NO_MEMORY` if the clipping
could not be worked out. Scrolling past the bitmap's edge stops at it,
which is not a failure.

**BEHAVIOR**

What is on the display is put back into the bitmap first: while a part
of the layer is visible its pixels are on the display and the bitmap
does not have them, so scrolling without that would lose whatever was
drawn while it showed. Then the window moves, and the part it has moved
on to is copied out of the bitmap.

**CONTEXT**

- Waits: yes, while another task holds the layer.
- Interrupts: no. It may wait, it allocates, and it draws.
- Forbid: must not be held: waiting for the lock would break it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated that outlives the call. The bitmap stays the
caller's.

**BUGS**

None known.

**SEE ALSO**

`CreateLayerTagList`, `GetLayerAttrs`

**EXAMPLES**

```zig
_ = lb.ScrollLayer(layer, 0, 16);
```

## SizeLayer

Changes a layer's size, its top-left staying where it is.

**SYNOPSIS**

```zig
fn SizeLayer(lb: *LayersBase, layer: *Layer, dw: i32, dh: i32) bool
```

**SINCE**

0.1. LVO -96.

**INPUTS**

- `layer` - the layer.
- `dw` - how much wider; negative makes it narrower.
- `dh` - how much taller; negative makes it shorter.

**RESULT**

True, or false with the reason in the layer: `LERR_BAD_BOUNDS` or
`LERR_NO_MEMORY`, as for `MoveSizeLayer`.

**BEHAVIOR**

`MoveSizeLayer` without moving. What is still inside the layer is kept;
what it gains has nothing in it, so a simple layer is owed it as damage
and a smart one has it painted.

**CONTEXT**

- Waits: yes, while another task holds the display's layers.
- Interrupts: no. It may wait, it allocates, and it draws.
- Forbid: must not be held: waiting for the locks would break it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated that outlives the call.

**BUGS**

None known.

**SEE ALSO**

`MoveSizeLayer`, `MoveLayer`

**EXAMPLES**

```zig
_ = lb.SizeLayer(layer, 100, 50);
```

## UnlockLayer

Lets a layer go again.

**SYNOPSIS**

```zig
fn UnlockLayer(lb: *LayersBase, layer: *Layer) void
```

**SINCE**

0.1. LVO -72.

**INPUTS**

- `layer` - a layer the caller holds.

**RESULT**

Nothing.

**BEHAVIOR**

One `LockLayer` given back; the layer is free when every one has been.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: the task that took it.

**OWNERSHIP**

The caller no longer holds it.

**BUGS**

None known.

**SEE ALSO**

`LockLayer`

**EXAMPLES**

```zig
lb.UnlockLayer(layer);
```

## UnlockLayerInfo

Lets the list of layers go again.

**SYNOPSIS**

```zig
fn UnlockLayerInfo(lb: *LayersBase, info: *LayerInfo) void
```

**SINCE**

0.1. LVO -88.

**INPUTS**

- `info` - the display's layers, held with `LockLayerInfo`.

**RESULT**

Nothing.

**BEHAVIOR**

One `LockLayerInfo` given back.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: the task that took it.

**OWNERSHIP**

The caller no longer holds it.

**BUGS**

None known.

**SEE ALSO**

`LockLayerInfo`

**EXAMPLES**

```zig
lb.UnlockLayerInfo(info);
```

## UnlockLayers

Lets every layer of a display go again.

**SYNOPSIS**

```zig
fn UnlockLayers(lb: *LayersBase, info: *LayerInfo) void
```

**SINCE**

0.1. LVO -80.

**INPUTS**

- `info` - the display's layers, held with `LockLayers`.

**RESULT**

Nothing.

**BEHAVIOR**

The layers first, then the list: the reverse of `LockLayers`.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: the task that took them.

**OWNERSHIP**

The caller no longer holds them.

**BUGS**

None known.

**SEE ALSO**

`LockLayers`

**EXAMPLES**

```zig
lb.UnlockLayers(info);
```

## UpfrontLayer

Puts a layer in front of every other one.

**SYNOPSIS**

```zig
fn UpfrontLayer(lb: *LayersBase, layer: *Layer) bool
```

**SINCE**

0.1. LVO -36.

**INPUTS**

- `layer` - the layer.

**RESULT**

True, or false with `LERR_NO_MEMORY` in the layer if the tiling could
not be worked out - the layer has still moved, and what each layer can
see may be out of date.

**BEHAVIOR**

What it now covers is lost to those layers, and what it uncovers is
given back to them - as damage for a simple layer, out of its keeping
for a smart or super one. A backdrop layer stays behind every ordinary one.

**CONTEXT**

- Waits: yes, while another task holds the display's layers.
- Interrupts: no. It may wait, and it allocates.
- Forbid: must not be held: waiting for the locks would break it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated that outlives the call.

**BUGS**

None known.

**SEE ALSO**

`BehindLayer`, `MoveLayerInFrontOf`

**EXAMPLES**

```zig
_ = lb.UpfrontLayer(layer);
```

## WhichLayer

Tells which layer a point of the display is in.

**SYNOPSIS**

```zig
fn WhichLayer(lb: *LayersBase, info: *LayerInfo, x: i32, y: i32) ?*Layer
```

**SINCE**

0.1. LVO -48.

**INPUTS**

- `info` - the display's layers.
- `x` - the point's column, in the display's coordinates.
- `y` - its row.

**RESULT**

The frontmost layer that can be seen at the point, or null if none can.

**BEHAVIOR**

Front to back, by what each layer can **see** rather than by what its
rectangle covers - so the answer is the layer that would be drawn on
there. A point no layer can see is nobody's, which is not the same as
the rectangles' answer for a layer hanging off the display.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed, though the list must not change meanwhile:
  `LockLayerInfo` is how to be sure.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The layer stays the library's.

**BUGS**

None known.

**SEE ALSO**

`LockLayerInfo`

**EXAMPLES**

```zig
lb.LockLayerInfo(info);
defer lb.UnlockLayerInfo(info);
const hit = lb.WhichLayer(info, mouse_x, mouse_y);
```
