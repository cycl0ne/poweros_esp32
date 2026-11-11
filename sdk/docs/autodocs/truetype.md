# truetype.library

truetype.library's functions: a TrueType file rendered into font
images, one size at a time, since 1.2 its glyphs as outlines, and
since 1.4 a font of a collection, its names and its tables.
Open it with OpenLibrary("truetype.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [CloseOutline](#closeoutline) - What OpenOutline made, given back.
- [FontMetrics](#fontmetrics) - A font's measures.
- [FontName](#fontname) - One of a font's names.
- [FontTable](#fonttable) - One of a font's tables, as the file has it.
- [GlyphIndex](#glyphindex) - The glyph a character is.
- [GlyphMetrics](#glyphmetrics) - A glyph's advance, left side bearing and box.
- [GlyphSegments](#glyphsegments) - A glyph's outline as lines and curves.
- [GlyphVariant](#glyphvariant) - The glyph a character and a variation selector are.
- [Kerning](#kerning) - How much further apart two glyphs are drawn side by side.
- [OpenOutline](#openoutline) - A font of a TrueType file, opened for rendering.
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

## FontMetrics

A font's measures.

**SYNOPSIS**

```zig
fn FontMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, metrics: *truetype.FontMetrics) void
```

**SINCE**

1.2. LVO -44.

**INPUTS**

- `outline` - what `OpenOutline` answered.
- `metrics` - where they go.

**RESULT**

Nothing; `metrics` is filled in, in the font's units, y up.

**BEHAVIOR**

The units per em and the number of glyphs; the ascender, descender
and line gap of the horizontal header (`hhea`), which is what
`RenderFontImage` sets its lines by; the x and capital heights and
the strike-out of `OS/2`, the underline of `post`, each 0 where the
font does not give it; the most verbs and points `GlyphSegments`
gives for a glyph of the font, from what `maxp` says the largest
glyph is (or as for 1024 points and 128 contours, when it does not
say); and the styles the file says it is drawn in.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

`metrics` is the caller's.

**BUGS**

A font whose `maxp` says less than its largest glyph has is not
read so far: that glyph's `GlyphSegments` answers
`TRUETYPEERR_GLYPH`.

**SEE ALSO**

`GlyphMetrics`, `GlyphSegments`, `OpenOutline`

**EXAMPLES**

```zig
var fm: sdk.truetype.FontMetrics = .{};
tb.FontMetrics(outline, &fm);
const scale = size / @as(f32, @floatFromInt(fm.units_per_em));
```

## FontName

One of a font's names.

**SYNOPSIS**

```zig
fn FontName(tb: *TrueTypeBase, outline: *truetype.Outline, name: u32, buffer: [*]u8, room: u32) u32
```

**SINCE**

1.4. LVO -56.

**INPUTS**

- `outline` - what `OpenOutline` answered.
- `name` - which name: `TTNAME_FAMILY`, `TTNAME_STYLE`, `TTNAME_FULL`,
  `TTNAME_VERSION`, `TTNAME_LICENCE`, or any other number of the
  font's `name` table.
- `buffer` - where it goes, in UTF-8, NUL-terminated.
- `room` - the buffer's size in bytes, the NUL counted; 0 to ask only
  how long the name is, and `buffer` is then not written.

**RESULT**

The bytes the whole name takes in UTF-8, the NUL not counted: `room`
or more says the buffer holds only the name's start. 0 when the font
has no such name, and the buffer then holds an empty string.

**BEHAVIOR**

The name is taken in English where the font has it: of the table's
records of that number the one in American English, then one in
another English, then one of no language (the Unicode platform's),
then the first in any other language. A record of no bytes counts as
none.

The name is stored as UTF-16 and written as UTF-8: two surrogates
that are a pair become their one character, one without the other
U+FFFD, and a NUL within the name is left out. A name longer than the
buffer is cut after a whole character.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The buffer is the caller's.

**BUGS**

A name the font has only in a Macintosh encoding is not read, and a
name cannot be asked for in a language of the caller's choice.

**SEE ALSO**

`OpenOutline`, `FontMetrics`

**EXAMPLES**

```zig
var family: [64]u8 = undefined;
if (tb.FontName(outline, sdk.truetype.TTNAME_FAMILY, &family, family.len) == 0) return;
const text: [*:0]const u8 = @ptrCast(&family);
```

## FontTable

One of a font's tables, as the file has it.

**SYNOPSIS**

```zig
fn FontTable(tb: *TrueTypeBase, outline: *truetype.Outline, tag: u32, length: *u32) ?[*]const u8
```

**SINCE**

1.4. LVO -60.

**INPUTS**

- `outline` - what `OpenOutline` answered.
- `tag` - the table's four letters, as `truetype.tableTag` makes
  them: `tableTag("GSUB")`.
- `length` - where the table's size in bytes goes.

**RESULT**

The table's first byte, and its size in `length`. Null, and a size of
0, when the font has no table of that tag or the file ends before the
table does.

**BEHAVIOR**

The font's directory is searched for the tag - in a collection, the
directory of the font `OpenOutline` was asked for - and the table's
place and size are checked against the file. Nothing within the table
is: what it says is its reader's to check against `length`. Its
numbers are stored with the highest byte first.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The bytes are the file's, which is the caller's: they are there as
long as the file is, and are not to be written.

**BUGS**

None known.

**SEE ALSO**

`OpenOutline`, `FontName`

**EXAMPLES**

```zig
var length: u32 = 0;
const start = tb.FontTable(outline, sdk.truetype.tableTag("GSUB"), &length) orelse return;
const substitutions = start[0..length];
```

## GlyphIndex

The glyph a character is.

**SYNOPSIS**

```zig
fn GlyphIndex(tb: *TrueTypeBase, outline: *truetype.Outline, code: u32) u32
```

**SINCE**

1.2, every format of character map since 1.4. LVO -32.

**INPUTS**

- `outline` - what `OpenOutline` answered.
- `code` - the character, a Unicode code point.

**RESULT**

The glyph's number, for `GlyphSegments`, `GlyphMetrics` and
`Kerning`; 0 - the missing glyph, which a font draws as a box or
nothing - when the font has none for it.

**BEHAVIOR**

Looked up in the character map `OpenOutline` chose: the font's
Unicode one that reaches furthest (formats 12, 13, 10, 4, 6 and 0, in
that order; one of the basic plane has no glyph past U+FFFF), or a
symbol font's own, whose characters are where the font puts them. A
glyph the map names and the font does not have answers 0.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

One character is one glyph: a font's substitutions - ligatures, the
forms of a script's letters by where they are in a word - are not
made. A character map of format 2 or 8 is not read.

**SEE ALSO**

`GlyphVariant`, `GlyphSegments`, `GlyphMetrics`, `Kerning`

**EXAMPLES**

```zig
const glyph = tb.GlyphIndex(outline, 'A');
```

## GlyphMetrics

A glyph's advance, left side bearing and box.

**SYNOPSIS**

```zig
fn GlyphMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, metrics: *truetype.GlyphMetrics) bool
```

**SINCE**

1.2. LVO -36.

**INPUTS**

- `outline` - what `OpenOutline` answered.
- `glyph` - the glyph's number, from `GlyphIndex`.
- `metrics` - where they go.

**RESULT**

True, and `metrics` filled in, in the font's units, y up; false - and
`metrics` all 0 - for a number past the font's glyphs.

**BEHAVIOR**

The advance and the left side bearing are the font's horizontal
metrics (`hmtx`); the box is the one the glyph's data gives, which
holds its points on the curve and off it. A glyph of no outline, a
space, has a box of 0s and its advance.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

`metrics` is the caller's.

**BUGS**

No vertical metrics: text set down the page is not read.

**SEE ALSO**

`GlyphIndex`, `FontMetrics`, `GlyphSegments`

**EXAMPLES**

```zig
var m: sdk.truetype.GlyphMetrics = .{};
if (tb.GlyphMetrics(outline, glyph, &m)) x += m.advance;
```

## GlyphSegments

A glyph's outline as lines and curves.

**SYNOPSIS**

```zig
fn GlyphSegments(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, segments: *truetype.Segments) i32
```

**SINCE**

1.2. LVO -40.

**INPUTS**

- `outline` - what `OpenOutline` answered.
- `glyph` - the glyph's number, from `GlyphIndex`.
- `segments` - the caller's arrays of verbs and points, and how many
  each holds; the counts are set.

**RESULT**

- `TRUETYPE_OK` - the outline is in the arrays, `verb_count` verbs
  and `point_count` points; none for a glyph of no outline, a space.
- `TRUETYPEERR_ROOM` - it did not fit: the counts say how many it
  needs, and what is in the arrays is not to be used.
- `TRUETYPEERR_GLYPH` - no glyph of that number, or its data is
  damaged; the counts are 0.
- `TRUETYPEERR_NOMEM` - no memory to read it in.

**BEHAVIOR**

The verbs are vector.library's - `SEG_MOVE`, `SEG_LINE`, `SEG_QUAD`,
`SEG_CLOSE` - and the points `vector.Point`s, so the arrays go to
`AddSegments` as they are. They are in the font's units, y up, from
the glyph's origin on the baseline: a program drawing them scales by
its size over `FontMetrics`' units per em and turns y over. Each
contour is closed, and filled by the non-zero rule its contours are
drawn for. A composite glyph is its parts, each moved and scaled as
the font says, in one outline.

`FontMetrics`' `most_verbs` and `most_points` are long enough for any
glyph of the font.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The arrays are the caller's. The call allocates room to read the
glyph in, and gives it back before it returns.

**BUGS**

No hinting: the outline is as it was drawn, for any size. A part of a
composite placed by matching its points to another's is left where it
was drawn.

**SEE ALSO**

`GlyphIndex`, `GlyphMetrics`, `FontMetrics`,
`vector.library/AddSegments`

**EXAMPLES**

```zig
var s = sdk.truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = verbs.len, .point_room = points.len };
if (tb.GlyphSegments(outline, glyph, &s) == sdk.truetype.TRUETYPE_OK) {
    _ = vb.AddSegments(path, s.verbs, s.verb_count, s.points, s.point_count);
}
```

## GlyphVariant

The glyph a character and a variation selector are.

**SYNOPSIS**

```zig
fn GlyphVariant(tb: *TrueTypeBase, outline: *truetype.Outline, code: u32, selector: u32) u32
```

**SINCE**

1.4. LVO -52.

**INPUTS**

- `outline` - what `OpenOutline` answered.
- `code` - the character, a Unicode code point.
- `selector` - the variation selector that follows it: U+FE00 to
  U+FE0F, U+E0100 to U+E01EF, or U+180B to U+180D.

**RESULT**

The number of the glyph the two are drawn as; 0 when the font has no
such sequence, and the character is then drawn as `GlyphIndex` says,
the selector left out.

**BEHAVIOR**

Looked up in the font's variation sequences (the character map's
format 14). A sequence the font has a glyph of its own for answers
that glyph: U+FE0F after a symbol its picture in colour, U+FE0E its
form as text, a selector after an ideograph one of its registered
shapes. A sequence the font lists as drawn the way the character is
without a selector answers the character's own glyph.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`GlyphIndex`, `GlyphMetrics`

**EXAMPLES**

```zig
// A heart, asked for in colour.
var glyph = tb.GlyphVariant(outline, 0x2764, 0xFE0F);
if (glyph == 0) glyph = tb.GlyphIndex(outline, 0x2764);
```

## Kerning

How much further apart two glyphs are drawn side by side.

**SYNOPSIS**

```zig
fn Kerning(tb: *TrueTypeBase, outline: *truetype.Outline, left: u32, right: u32) i32
```

**SINCE**

1.2. LVO -48.

**INPUTS**

- `outline` - what `OpenOutline` answered.
- `left` - the glyph drawn first, from `GlyphIndex`.
- `right` - the one after it.

**RESULT**

The font's units added to `left`'s advance before `right` is drawn:
negative to draw them closer, as "AV" is. 0 for a pair the font does
not move.

**BEHAVIOR**

The pairs of the font's `kern` table: those of its subtables of
format 0 for horizontal text, summed - one that says it overrides
taking the place of what came before it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

Only the `kern` table is read, not OpenType's `GPOS`: a font that
keeps its kerning only there is drawn without it. Apple's version of
the table is not read either.

**SEE ALSO**

`GlyphIndex`, `GlyphMetrics`

**EXAMPLES**

```zig
x += m.advance + tb.Kerning(outline, glyph, next);
```

## OpenOutline

A font of a TrueType file, opened for rendering.

**SYNOPSIS**

```zig
fn OpenOutline(tb: *TrueTypeBase, file: [*]const u8, size: u32, tags: ?[*]const utility.TagItem) ?*truetype.Outline
```

**SINCE**

1.0, the tags and collections since 1.4. LVO -20.

**INPUTS**

- `file` - the whole file, as read.
- `size` - its size in bytes.
- `tags` - which font of the file is meant, or null for its first:
  - `TTA_FontIndex` (u32) - the font's number in a collection, from 0;
    `truetype.fontCount` says how many the file holds. Default 0.

**RESULT**

The outline, or null if the file has no font of that number, the
bytes are not a TrueType font this library reads - a table it needs
missing or outside the file, no character map it reads - or there is
no memory.

**BEHAVIOR**

The font's tables are found and checked once, and what the other
calls need of them kept: the units per em, the ascender and
descender, where the glyph index, the glyphs, the widths, the
character map and the variation sequences are. The glyphs themselves
are read only when one is asked for.

Of a font's character maps a Unicode one is read, the one that
reaches furthest: formats 12, 13, 10, 4, 6 and 0, in that order. A
symbol font, which has none, is read by its own map, with its
characters where the font puts them (U+F020 to U+F0FF mostly).

A font need not have outlines: one whose glyphs are pictures opens,
maps, measures and names, and every glyph of it is one of no outline.

The outline is not written after this call, and no other call keeps
anything in it: any number of tasks use one outline at once.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The outline is the caller's until `CloseOutline`. The file's bytes stay
the caller's too, and must be there, unchanged, until then: the
outline reads them in place. The tags are read during the call only.

**BUGS**

Hinting instructions are passed over, and fonts of CFF outlines
(OpenType 'OTTO') are not read. A font whose only character map is in
a Macintosh encoding is not opened.

**SEE ALSO**

`RenderFontImage`, `GlyphIndex`, `FontName`, `FontTable`, `CloseOutline`

**EXAMPLES**

```zig
const outline = tb.OpenOutline(file, size, null) orelse return error.NotTrueType;
defer tb.CloseOutline(outline);

// Every font of a collection.
var index: u32 = 0;
while (index < sdk.truetype.fontCount(file[0..size])) : (index += 1) {
    const tags = [_]utility.TagItem{
        .{ .tag = sdk.truetype.TTA_FontIndex, .data = index },
        .{ .tag = utility.TAG_DONE, .data = 0 },
    };
    const font = tb.OpenOutline(file, size, &tags) orelse continue;
    defer tb.CloseOutline(font);
}
```

## RenderFontImage

One size of an outline, as a font image.

**SYNOPSIS**

```zig
fn RenderFontImage(tb: *TrueTypeBase, outline: *truetype.Outline, rows: u32, ranges: [*]const truetype.CodeRange, count: u32) ?*FontImage
```

**SINCE**

1.0, ranges since 1.3, the limits since 1.4. LVO -24.

**INPUTS**

- `outline` - what `OpenOutline` answered.
- `rows` - how tall a line is, 1 to 4096: the font's ascender to its
  descender is scaled to this.
- `ranges` - the characters to render, as code points: `count` ranges,
  sorted, none overlapping another.
- `count` - how many ranges.

**RESULT**

A font image of coverage (`alpha4`), sound and ready for `AddFont`:
every character of the ranges the font has a glyph for, and the
font's missing glyph as the default character, under
`fontimage.MISSING`. Null for a height of 0 or more than 4096, a font
without outlines, ranges out of order or past the last code point, an
image of more than a gigabyte, or no memory.

**BEHAVIOR**

A character the font's character map gives no glyph is left out, so
that graphics draws it as its base letter where the image has that
(`Ā` as `A`) and as the missing glyph otherwise; the image's own
ranges are the runs of characters it has.

Every glyph is its outline scaled so that the line is `rows` tall and
the baseline sits the ascender's share of it down, the curves made
lines within a third of a pixel, and each pixel given how much of it
the outline covers, in fifteenths. The advances are rounded to whole
pixels. The font is `FPF_DESIGNED` - drawn at its size from the
outline, not scaled from another size - and `FPF_PROPORTIONAL` when
its advances differ. Its styles are the ones the font says it is drawn
in (`FontMetrics`): a bold face renders as `FSF_BOLD`, so graphics
draws no bold over it.

A glyph the file is damaged in - its data cut short, its outline
further than sixteen lines from where it is drawn - is rendered as one
of no outline, with its advance; an advance is 32767 pixels at most.

**CONTEXT**

- Waits: no.
- Interrupts: no. The work is a glyph rendered for each character the
  font has in the ranges: hundreds for a European font's scripts.
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
const latin1 = [_]truetype.CodeRange{ .{ .first = 0x20, .last = 0x7E }, .{ .first = 0xA0, .last = 0xFF } };
const image = tb.RenderFontImage(outline, 24, &latin1, latin1.len) orelse return;
defer sys.FreeVec(image);
```
