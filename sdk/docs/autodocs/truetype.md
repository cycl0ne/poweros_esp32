# truetype.library

truetype.library's functions: a TrueType file rendered into font
images, one size at a time. Open it with
OpenLibrary("truetype.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [CloseOutline](#closeoutline) - What OpenOutline made, given back.
- [OpenOutline](#openoutline) - A TrueType file, opened for rendering.
- [RenderFontImage](#renderfontimage) - One size of an outline, as a font image.

## CloseOutline

What OpenOutline made, given back.

**SYNOPSIS**

```zig
fn CloseOutline(tb: *TrueTypeBase, outline: ?*truetype.Outline) void
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `outline` - what `OpenOutline` answered, or null.

**RESULT**

Nothing.

**BEHAVIOR**

The outline's memory goes back; null does nothing. The font images
rendered from it stay: each is a whole font of its own.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The file's bytes are the caller's again, free to go.

**BUGS**

None known.

**SEE ALSO**

`OpenOutline`

**EXAMPLES**

```zig
tb.CloseOutline(outline);
```

## OpenOutline

A TrueType file, opened for rendering.

**SYNOPSIS**

```zig
fn OpenOutline(tb: *TrueTypeBase, file: [*]const u8, size: u32) ?*truetype.Outline
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `file` - the whole file, as read.
- `size` - its size in bytes.

**RESULT**

The outline, or null if the bytes are not a TrueType font this library
reads - a table it needs missing or outside the file, no Unicode
character map of format 4 or 12 - or there is no memory.

**BEHAVIOR**

The tables are found and checked once, and what rendering needs of
them kept: the units per em, the ascender and descender, where the
glyph index, the glyphs, the widths and the character map are. The
glyphs themselves are read only when a size is rendered.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The outline is the caller's until `CloseOutline`. The file's bytes stay
the caller's too, and must be there until then: the outline reads them
in place.

**BUGS**

Hinting instructions are passed over, and fonts of CFF outlines
(OpenType 'OTTO') are not read.

**SEE ALSO**

`RenderFontImage`, `CloseOutline`

**EXAMPLES**

```zig
const outline = tb.OpenOutline(file, size) orelse return error.NotTrueType;
defer tb.CloseOutline(outline);
```

## RenderFontImage

One size of an outline, as a font image.

**SYNOPSIS**

```zig
fn RenderFontImage(tb: *TrueTypeBase, outline: *truetype.Outline, rows: u32, first: u32, last: u32) ?*FontImage
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `outline` - what `OpenOutline` answered.
- `rows` - how tall a line is: the font's ascender to its descender
  is scaled to this.
- `first`, `last` - the codes to render: 32 and 255 for the text a
  string of bytes can be.

**RESULT**

A font image of coverage (`alpha4`), sound and ready for `AddFont`:
the codes asked for and the font's missing glyph as the default
character, `last + 1`. Null for a height of 0, `last` below `first`, or
no memory.

**BEHAVIOR**

Every glyph is its outline scaled so that the line is `rows` tall and
the baseline sits the ascender's share of it down, the curves made
lines within a third of a pixel, and each pixel given how much of it
the outline covers, in fifteenths. The advances are rounded to whole
pixels. A code the font has no glyph for is its missing glyph. The
font is `FPF_DESIGNED` - drawn at its size from the outline, not
scaled from another size - and `FPF_PROPORTIONAL` when its advances
differ.

**CONTEXT**

- Waits: no.
- Interrupts: no. The work is a few hundred glyphs.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The image is the caller's, one allocation, freed with `FreeVec`.

**BUGS**

No hinting: stems at small sizes may fall between pixels and show as
two half-covered columns.

**SEE ALSO**

`OpenOutline`, `graphics.library/AddFont`, `diskfont.library/OpenDiskFont`

**EXAMPLES**

```zig
const image = tb.RenderFontImage(outline, 24, 32, 255) orelse return;
defer sys.FreeVec(image);
```
