# Fonts

How text gets onto a surface: what a font is, how one is chosen and opened,
where fonts come from, and what a program has to do to use them. The calls
themselves are in the reference: [graphics](../autodocs/graphics.md),
[diskfont](../autodocs/diskfont.md), [truetype](../autodocs/truetype.md),
[truetypeshaping](../autodocs/truetypeshaping.md),
[intuition](../autodocs/intuition.md).

- [The font image](#the-font-image)
- [Drawing text](#drawing-text)
- [Text from a description](#text-from-a-description)
- [Choosing and opening a font](#choosing-and-opening-a-font)
- [Sizes in points](#sizes-in-points)
- [Fonts on the disk](#fonts-on-the-disk)
- [diskfont.library](#diskfontlibrary)
- [Outline fonts](#outline-fonts)
- [The system's fonts](#the-systems-fonts)
- [Making a font yourself](#making-a-font-yourself)
- [Tools](#tools)

## The font image

Every font is one block of memory, a `FontImage`
(`sdk/libs/graphics/fontimage.zig`). The two fonts in the ROM, a size read
from a file, a size scaled from another and one rendered from an outline
are all the same kind of block. Nothing in it is a pointer: every table is
an offset from the block's own start, so the block means the same wherever
it lies - in the ROM, in a file, or read from one into memory.

```
+------------------+  offset 0
| FontImage header |  height, baseline, x_size, kind, default_char, ...
+------------------+  .ranges
| Range[]          |  first code, last code, first glyph - sorted
+------------------+  .glyphs
| Glyph[]          |  data offset, box, top, left, advance, pitch
+------------------+  .palette (colour fonts only)
| u32[] ARGB       |
+------------------+  .data
| pixels           |  each glyph's rows, one after another
+------------------+  .size
```

The header's measures:

| Field | Meaning |
|---|---|
| `height` | rows in a line of text |
| `baseline` | rows from the top of the line down to the baseline |
| `x_size` | the nominal width: every advance of a fixed-width font, a typical one of a proportional font |
| `max_width` | the widest glyph box |
| `style` | the `FSF_` styles the font was drawn with, which are not added again |
| `flags` | `FPF_PROPORTIONAL` when advances differ, `FPF_DESIGNED` when the size was drawn rather than scaled |
| `kind` | what a pixel is (below) |
| `bold_smear` | how far right bold draws a glyph again |
| `default_char` | the code drawn for a code the font has no glyph for, nor a base letter of |
| `checksum` | makes the longwords of the whole block add up to zero |

**Characters are found through ranges.** A range says "codes `first` to
`last` are glyphs `glyph` onwards". Codes are Unicode code points, and a
font may start and stop anywhere and leave gaps. A code in no range that
is a Latin, Greek or Cyrillic letter with marks is drawn as its base
letter when the font has that - `Ā` as `A`, `Ǻ` as `Å` or else `A`, `ἀ`
as `α` (`utility.unicode.base`) - and anything else as `default_char`,
which every image must have. A font whose stand-in is no character of
its own, a box or the outline's missing glyph, gives it the code
`fontimage.MISSING`, one past the last code point, so no text names it.

**A glyph is a box of ink.** Its box holds only the pixels it draws: a
space has none, an `x` only the rows the x fills. `top` is how far down
the line the box starts, `left` how far right of the point (less than
zero reaches back under the character before), `advance` how far the
point moves after it.

**A pixel is one of three kinds**, the same for the whole font:

| `kind` | A pixel | 0 means |
|---|---|---|
| `mono1` | one bit, the leftmost in a byte's highest | no ink |
| `alpha4` | four bits, two to a byte, the left one high; 15 is full ink | no ink |
| `indexed8` | one byte, an entry of the palette | transparent |

A colour font may name one palette entry `pen_index`: that entry is drawn
in the RastPort's foreground pen with the entry's own alpha, so a font
with a coloured shadow still takes the caller's text colour for its body.

`fontimage.check(block, size)` says whether a block holds together (every
table inside it, ranges sorted, the default character there);
`fontimage.sound(block, size)` whether its checksum is right.
`fontimage.find` looks a code up, `glyphFor` the glyph it is drawn with
(its own, a base letter's, or the default); `pixelsOf` finds a glyph's
rows.

## Drawing text

Text is drawn through a RastPort. Put a font on it, set the pens, move to
where the text starts, and draw:

```zig
const font = gb.OpenFont(&.{ .name = sdk.graphics.POSPAZNAME, .y_size = 16 }) orelse return;
defer gb.CloseFont(font);
sdk.graphics.SetFont(gb, rp, font);
gb.Move(rp, 20, 40);            // the left end of the baseline
gb.Text(rp, "Hello", 5);
```

- **The point is the left end of the baseline.** Letters sit above it,
  tails hang below. After `Text` the point is just past the last letter,
  so one `Text` follows another.
- **Text is UTF-8, and its counts are bytes.** `Text(rp, "Grüße", 7)`
  draws five characters. A byte that is no UTF-8 is drawn as the
  character it reads as (`utility.utf8.read`).
- **Each character has its own width.** `TextLength` adds the advances up;
  `TextExtent` also says where the ink goes (a kern back makes
  `extent.min_x` negative, bold and italic can carry it past `width`);
  `TextFit` says how many bytes fit a width, from the start or from the
  end - whole characters, never part of one.
- **The draw mode is the draw mode.** `DRMD_JAM1` puts ink down,
  `DRMD_JAM2` lays the background pen behind each character's cell first,
  `DRMD_COMPLEMENT` inverts. A font of coverage lays the pen over what is
  there by how much of each pixel the letter covers, so its edges are
  smooth on any ground; under `DRMD_COMPLEMENT` a pixel half covered or
  more is inverted.
- **Styles are drawn, not stored.** `FSF_BOLD` draws each glyph again
  `bold_smear` to the right, `FSF_ITALIC` leans the rows, `FSF_UNDERLINED`
  draws a line under the run, `FSF_EXTENDED` sets the letters a pixel
  further apart. Bold widens every advance by one as well, for the glyph
  drawn again, so a run in either is longer than the plain one. A style the
  font was drawn with (its `style`) is not added again - a family's own
  bold face, which diskfont.library answers for `FSF_BOLD` where one is
  installed, is drawn as it is.
- `GetRPAttrs` with `RPTAG_FontHeight`, `RPTAG_FontBaseline`,
  `RPTAG_FontWidth` (the nominal width) and `RPTAG_FontProportional`
  answers what a layout needs without touching the font.

## Text from a description

Where a program hands words to something else to draw - a gadget's label,
a menu item, a requester's message, an image - it hands an **IntuiText**:
a tag list that says what the words are and how they look, so whoever
draws them needs nothing else. intuition.library's `PrintIText` draws
one, and `IntuiTextLength` measures it.

```zig
const intuition = sdk.intuition;
const TagItem = sdk.utility.TagItem;

const advice = [_]TagItem{
    .{ .tag = intuition.IT_Text, .data = @intFromPtr("Check that it is on and has paper.") },
    .{ .tag = intuition.IT_Top, .data = 20 },
    .{},
};
const heading = [_]TagItem{
    .{ .tag = intuition.IT_Text, .data = @intFromPtr("The printer is not answering.") },
    .{ .tag = intuition.IT_Style, .data = sdk.graphics.FSF_BOLD },
    .{ .tag = intuition.IT_Next, .data = @intFromPtr(&advice) },
    .{},
};
ib.PrintIText(rp, &heading, 10, 20);
```

| Tag | Data |
|---|---|
| `IT_Text` | the words, `[*:0]const u8` |
| `IT_FrontPen`, `IT_BackPen` | the pens, 0xAARRGGBB |
| `IT_DrawMode` | `DRMD_JAM1` or `DRMD_JAM2` |
| `IT_Left`, `IT_Top` | where the run goes, from the corner it is drawn at |
| `IT_Font` | an open `TextFont`; null names none |
| `IT_Style` | `FSF_BOLD`, `FSF_ITALIC`, `FSF_UNDERLINED` |
| `IT_Next` | the next run, another IntuiText |

- **A run is placed by its top left corner,** not by its baseline: (`left`
  + `IT_Left`, `top` + `IT_Top`) is the top of the letters whatever the
  font, so runs in two fonts line up by their tops.
- **What a run does not name is the RastPort's own.** A run without
  `IT_FrontPen` is drawn in the pen the caller set, one without `IT_Font`
  in the RastPort's font. Each run starts from the RastPort as the caller
  gave it - nothing one run names carries over to the next - and the
  RastPort gets its pens, mode, font and style back when the call ends.
- **Runs chain with `IT_Next`.** Several lines, or a word in another
  colour or style, are one IntuiText drawn by one call. A run with no
  words is passed over and the runs after it are still drawn.
- **`IntuiTextLength` measures one run,** in its `IT_Font` and `IT_Style`,
  or in the system's default font (`SYSFONT_DEFAULT`) when it names
  none. The runs after
  it are not added: each goes where it says. `intuition.text.plainRun(words,
  font)` makes the run to measure a word with.
- **The font stays the caller's,** and open, for as long as the run is
  used.

Where intuition takes an IntuiText:

- **A gadget's label**, `GA_IntuiText` in place of `GA_Text`: centred in
  the gadget, in what its runs name.
- **itexticlass**, `IA_Data`: an image whose shape is the words, all its
  runs drawn in the image's `IA_FGPen` in JAM1, so a label takes its
  colour from where it is shown.
- **A menu item's words**, its `item_fill` with `ITEMTEXT`. `CreateMenusA`
  makes them, and `LayoutMenusA` writes each run's place, pen and font
  into its `IT_Left`, `IT_FrontPen` and `IT_Font` - a strip built by hand
  and laid out that way needs writable runs with those tags.
- **A requester's message and buttons**, `SYSREQ_Body`, `SYSREQ_Positive`
  and `SYSREQ_Negative` for `AutoRequestTagList` and
  `BuildSysRequestTagList`: each body run is a line, and only the words
  are taken - the requester has its own look.

## Choosing and opening a font

A font is asked for by a `TextAttr`: a name, a height, the styles it
should look like, flags.

```zig
const want = sdk.graphics.TextAttr{ .name = "spleen.font", .y_size = 16 };
```

`graphics.library/OpenFont` opens the font on graphics' list that matches
it best, weighed by `WeighTAMatch`. A perfect match weighs
`MAXFONTMATCHWEIGHT`; the weight falls:

- by 32 for each row the font is shorter than asked, and by 128 for each
  row it is taller - text short of its box reads better than text
  spilling out of it;
- a little for a style asked for that the font lacks (italic 16, bold 8,
  underlined 4), since the soft styles can draw it; a lot for a style the
  font has and was not asked for (italic 1024, bold 512, underlined
  2048), since nothing can take it away;
- to nothing when `FPF_DESIGNED` is asked and the font was scaled.

`OpenFont` only finds what is already in memory - the ROM's fonts and
whatever has been loaded. To have a font read from the disk, scaled or
rendered, ask `diskfont.library/OpenDiskFont` instead: it answers from
memory too when the match there is perfect, so a program can ask it for
every font.

Every open is matched by one `graphics.library/CloseFont`, whichever call
opened it. `AskFont` describes a RastPort's font as a TextAttr, which opens
the same font again.

## Sizes in points

A height in rows means something different on every panel. With
`FPF_POINTS` in its flags, a TextAttr's `y_size` is in points, 72 to the
inch, and the screen's DPI makes it rows:

```zig
const want = sdk.graphics.TextAttr{ .name = "go.font", .y_size = 10, .flags = sdk.graphics.FPF_POINTS };
```

The DPI is the board's (`SYSTAG_ScreenDPI` in its system tags): 170 on the
7-inch 1024x600 board, 165 on the 3.5-inch 480x320 board, 170 in QEMU,
which stands in for the 7-inch board. Ten points is then 24 rows on one
and 23 on the other - the same height on the glass. `FontRows(textAttr)`
answers the rows a TextAttr asks for; `OpenFont`, `WeighTAMatch` and
`OpenDiskFont` all go through it. Without a DPI a point is a row.

## Fonts on the disk

`FONTS:` is `SYS:fonts`. A font family there is a contents file and a
directory of its sizes:

```
FONTS:spleen.font        the contents file: which sizes there are
FONTS:spleen/8           a size file, 8 rows
FONTS:spleen/16          a size file, 16 rows
FONTS:go.font            a contents file listing an outline
FONTS:go/Go-Regular.ttf  the outline, rendered at any height
FONTS:go-bold.font       the same family's bold face, a family of its own
FONTS:go-bold/Go-Bold.ttf
FONTS:sans.font          Liberation Sans, and its faces sans-bold, -italic
FONTS:sans/LiberationSans-Regular.ttf   and -bolditalic; serif and mono the same
```

The 64-bit machines' disks also carry the Liberation families - `sans`,
`serif` and `mono`, drawn to the widths of Arial, Times New Roman and
Courier New, under the SIL Open Font License (`FONTS:liberation.licence`)
- for the text of SVG pictures, which names those fonts more than any.

**What a font holds is what its source has**, under each character's
code point: Spleen's sizes from 16 rows up have Latin with its
extensions, Greek, Cyrillic, box drawing, blocks and Braille, close to
a thousand characters, its 8 and 12 rows a few hundred; the Go faces
Latin-1 and Latin Extended-A, Greek and Cyrillic, about 600 in what
diskfont renders; Liberation's nearly three times that. A letter with marks a
font lacks is drawn as its base letter, anything else as its stand-in.

**A size file is a FontImage, byte for byte.** It is read with one `Read`
into one allocation, checked (`check` and `sound`), and drawn from where
it lies; nothing in it is fixed up.

**A contents file** (`sdk/libs/diskfont/fontfile.zig`) is a
`ContentsHeader` - magic `PFCT`, version, count, checksum - and one
80-byte `FontContents` per size: the file's path from `FONTS:`, its
height, drawn styles, flags, kind of pixels, nominal width, and `outline`
set for an entry that is a TrueType file (whose height is then 0, and its
styles the ones the file says it is drawn in). Its
longwords add up to zero too. `fontfile.sound` checks one, `seal` sets
its checksum, `entryFor` and `outlineEntry` make entries.

A size dropped into a family's directory is found only through the
contents file: `C:FixFonts` writes every family's contents file again
from what is in its directory.

## diskfont.library

```zig
const df_lib = sys.OpenLibrary(sdk.diskfont.DISKFONTNAME, sdk.diskfont.DISKFONT_VERSION) orelse return;
defer sys.CloseLibrary(df_lib);
const dfb: *sdk.interface.diskfont.DiskfontBase = @ptrCast(df_lib);
const font = dfb.OpenDiskFont(&.{ .name = "spleen.font", .y_size = 20 }) orelse return;
defer gb.CloseFont(font);
```

**`OpenDiskFont`** answers a perfect match in memory at once.

**Bold and italic are a family's own faces where it has them**: asked for
`FSF_BOLD` or `FSF_ITALIC`, it tries the faces installed beside the family
first - `go-bolditalic.font`, `go-bold.font`, `go-italic.font` beside
`go.font`, each only for styles asked, the one drawing the most of them
first. A face is drawn in its styles, so the soft styles draw only what it
lacks: bold italic asked of a family with only a bold face is that face,
leaned. A family is installed as its own faces by naming them so.

Otherwise it reads the family's contents file - `FONTS:<name>`, or the
name as given when it holds a `:` - and:

- for a family with an outline, loads a size drawn at exactly that height
  and style if there is one, then takes a size of the outline already in
  memory at that height, and otherwise renders the outline at that
  height - in the styles the TrueType file says it is drawn in, so a bold
  face renders as bold;
- without `FPF_DESIGNED`, looks for a source at the height asked, then at
  twice it, then at half it, in memory first and then on the disk,
  letting go of underline, then bold, then italic if none is found, and
  failing all of that takes the nearest size by `WeighTAMatch`; a source
  of another height is scaled to the height asked;
- with `FPF_DESIGNED`, takes the nearest size drawn, never a scaled one.

A size that fails its checks is passed over for the next best. Fonts are
loaded one at a time, whoever asks.

**A font it made is kept.** Once nobody holds it, it stays in memory for
the next caller, until memory runs short; then diskfont.library's own
low-memory handler frees such fonts one at a time.

**`AvailFonts(buffer, size, flags)`** lists what there is: fonts in memory
(`AFF_MEMORY`, with `AFF_SCALED` to count scaled ones too) and every entry
of every contents file in every directory of `FONTS:` (`AFF_DISK`). The
buffer holds an `AvailFontsHeader`, its entries from `avail_entries_at`
(`diskfont.availEntries` finds them), and the names they point at. It
answers 0, or how many bytes more it needed:

```zig
var size: u32 = 2048;
while (true) {
    const buffer = sys.AllocVec(size, exec.MEMF_ANY) orelse return;
    defer sys.FreeVec(buffer);
    const more = dfb.AvailFonts(buffer, size, diskfont.AFF_MEMORY | diskfont.AFF_DISK);
    if (more != 0) { size += more; continue; }
    const header: *const diskfont.AvailFontsHeader = @ptrCast(@alignCast(buffer));
    for (diskfont.availEntries(header)) |entry| use(entry.type, entry.attr);
    break;
}
```

Each entry is the TextAttr that opens the font and where it is:
`AFF_MEMORY`, `AFF_MEMORY | AFF_SCALED`, `AFF_DISK`, or
`AFF_DISK | AFF_SCALABLE` with a height of 0 for an outline.

**`NewScaledDiskFont(font, textAttr)`** makes a new size from any font:
every glyph scaled by the ratio of the heights, across and down alike,
each pixel the value of the old pixel under its middle - so ink stays ink,
coverage keeps its steps, colour keeps its entries. The result is the
caller's, one allocation freed with `FreeVec(font)` (after `RemFont` if
it was added).

**`NewFontContents(lock, "name.font")`** makes a contents file's image from
the family's directory; `DisposeFontContents` frees it.

## Outline fonts

`truetype.library` reads a TrueType file and renders a size of it into a
FontImage of coverage: `OpenOutline(bytes, size, tags)` checks the file
and keeps what rendering needs, `RenderFontImage(outline, rows, ranges,
count)` makes a size of the characters it has in the ranges asked for,
`CloseOutline` gives the outline back. The file's bytes stay
the caller's until then. The line is the font's ascender to its
descender, scaled to `rows`; each glyph's curves are flattened and the
area of each pixel inside the outline measured, kept in four bits. There
is no hinting. The image has the characters of the ranges the font has a
glyph for - one it lacks is left out, so that graphics draws its base
letter - and the font's missing glyph as its default character, under
`fontimage.MISSING`, and the styles the file says it is drawn
in - `truetype.styleOf` reads them, bold and italic, from its `head`
table.

diskfont.library does all of this for a family whose contents file lists
an outline: a program only asks `OpenDiskFont` for a height. It renders
what the font has of Latin (with IPA and the spacing modifiers), Greek,
Cyrillic, general punctuation, currency, the letterlike symbols, box
drawing and blocks, and U+FFFD. A size costs a glyph rendered for each of
those the font has, once; the result is kept like a loaded font.

**Glyphs as outlines** (truetype.library 1.2): a program that draws text
itself - at any size, turned, filled with a gradient - takes the glyphs
as shapes. `GlyphIndex(outline, code)` is a character's glyph, 0 for the
font's missing one; `GlyphMetrics` its advance, left side bearing and
box; `GlyphSegments` its outline as vector.library's verbs and points, in
the font's units with y up, ready for `AddSegments` through a matrix that
scales them and turns them over; `FontMetrics` the font's units per em,
ascender, descender, line gap, x and cap height, underline and strikeout
lines, and the most verbs and points one glyph takes; `Kerning(outline,
left, right)` what the `kern` table says of a pair.

**The file** (truetype.library 1.4). A file is one font or a collection
of several (`ttcf`): `truetype.fontCount(bytes)` says how many, and
`OpenOutline`'s tag `TTA_FontIndex` which of them is opened - the first
without it. An outline is not written once it is opened, and each call
keeps what it works with to itself, so any number of tasks use one
outline at once.

Of a font's character maps a Unicode one is read, the one that reaches
furthest: formats 12, 13, 10, 4, 6 and 0. A symbol font is read by its
own map, with its characters where the font puts them (U+F020 to U+F0FF
mostly). `GlyphVariant(outline, code, selector)` is the glyph a character
is drawn with when a variation selector follows it (the map's format
14): the sequence's own glyph, the character's where the font says the
two look the same, 0 where it has no such sequence - U+FE0F after a
symbol asks for its picture in colour, U+FE0E for its form as text.

`FontName(outline, name, buffer, room)` writes one of the font's names -
`TTNAME_FAMILY`, `TTNAME_STYLE`, `TTNAME_FULL`, `TTNAME_VERSION` and the
others of the `name` table, by number - in UTF-8, in English where the
font has it, and answers the bytes the whole name takes: `room` or more
says the buffer holds only its start. `FontTable(outline, tag, &length)`
hands out a table of the font as it lies in the file, for a reader of
what the library does not read itself:
`truetype.tableTag("GSUB")` names it, and the table's place and size are
checked against the file, nothing within it. A font whose glyphs are
pictures and not outlines opens too: it maps, measures and names, and
each of its glyphs is one of no outline.

```zig
const tags = [_]sdk.utility.TagItem{
    .{ .tag = sdk.truetype.TTA_FontIndex, .data = 1 },
    .{ .tag = sdk.utility.TAG_DONE, .data = 0 },
};
const outline = tb.OpenOutline(bytes.ptr, size, &tags) orelse return;
defer tb.CloseOutline(outline);
var family: [64]u8 = undefined;
_ = tb.FontName(outline, sdk.truetype.TTNAME_FAMILY, &family, family.len);
const heart = tb.GlyphVariant(outline, 0x2764, 0xFE0F);
var length: u32 = 0;
const gsub = tb.FontTable(outline, sdk.truetype.tableTag("GSUB"), &length);
```

```zig
const of = dfb.OpenOutlineFont("sans.font", sdk.graphics.FSF_BOLD) orelse return;
defer dfb.CloseOutlineFont(of);
var fm: sdk.truetype.FontMetrics = .{};
tb.FontMetrics(of.outline, &fm);
const glyph = tb.GlyphIndex(of.outline, 'A');
var segments = sdk.truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = verbs.len, .point_room = points.len };
if (tb.GlyphSegments(of.outline, glyph, &segments) == sdk.truetype.TRUETYPE_OK) {
    _ = vb.AddSegments(path, &verbs, segments.verb_count, &points, segments.point_count);
}
```

**`OpenOutlineFont(name, style)`** (diskfont.library 1.4) finds the
outline as `OpenDiskFont` finds a size: the family's faces for the styles
asked, then the family. Its `style` says which of them the face draws -
what it does not, the program draws itself. The outline is read once and
shared by everyone who opens it; `CloseOutlineFont` gives it back, and
it is freed when memory runs low and nobody holds it.

**Shaping** (truetypeshaping.library 1.0). A font says more than which
glyph a character has: its `GSUB` table replaces glyphs - two letters by
their ligature, a letter by the form it has beside its neighbours - and
its `GPOS` table sets them: a pair closer or apart, a mark onto the
glyph it belongs to, the letters of a joined script so that they meet.
`ShapeGlyphs(outline, script, direction, language, features, run)`
applies both to a run of glyphs. The run is an array of `ShapedGlyph`,
each with its `glyph` and its `cluster` - the place in the text it
stands for - and comes back with the glyphs it is drawn with, each with
its `advance` and its `x_offset` and `y_offset` in the font's units, in
the order they are drawn from left to right. A ligature has the lowest
cluster of its parts, so a caret or a selection still finds the text a
glyph stands for.

The script and the language are the font's four-letter names
(`scriptTag("latn")`, `languageTag("TRK ")`), or the defaults. The
features are a list ended by a tag of 0: each with its tag, a `value` -
0 switches it off, a number from 1 picks one of the forms a feature
offers - and the clusters `first` to `last` it holds for, the whole run
when they are left alone. The call applies what it is given and nothing
else: `liga` and `kern` are features like any other. A font without the
tables, or without the feature, gives the run back with the advances the
font has for its glyphs.

```zig
const tts = sdk.truetypeshaping;
var glyphs: [16]tts.ShapedGlyph = undefined;
for ("office", 0..) |letter, place| {
    glyphs[place] = .{ .glyph = tb.GlyphIndex(outline, letter), .cluster = @intCast(place) };
}
var run: tts.ShapedRun = .{ .glyphs = &glyphs, .room = glyphs.len, .count = 6 };
const features = [_]tts.Feature{
    .{ .tag = tts.featureTag("liga") },
    .{ .tag = tts.featureTag("kern") },
    .{},
};
if (sb.ShapeGlyphs(outline, tts.scriptTag("latn"), tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &features, &run) == tts.TTS_OK) {
    var x: i32 = 0;
    for (glyphs[0..run.count]) |shaped| {
        // Draw shaped.glyph at x + shaped.x_offset, shaped.y_offset.
        x += shaped.advance;
    }
}
```

`TTSERR_ROOM` says the shaped run has more glyphs than the array holds,
and `count` how many. What a font can ask for is bounded - a sequence of
64 glyphs, lookups calling each other 8 deep, a run growing to 64 times
its length, and each table's work on a run: 65536 pieces a glyph, a
million for a short run, where a piece is a subtable looked at for a
glyph, a rule tried, a glyph compared - so that a call's time follows
the run's length and not what a table's numbers say. Tables that are
not sound shape to something or to nothing, and are never read past
their end.

**A text** (since 1.1). `ShapeText(outline, text, length, direction,
language, features, run)` takes the text itself, in UTF-8, and does what
a caller of `ShapeGlyphs` would do by hand. It cuts the text into
stretches of one script - a space, a digit, a comma and a mark belong to
the stretch before them - and shapes each by what the font lists for
that script. A stretch is first made the characters the font draws it
with: a letter and a mark behind it become the one character there is
for the two where the font has its glyph, a character the font lacks
becomes its parts where it has those, and the marks on a letter are put
in the order of their combining classes - so a text draws the same
however it spells a letter, and a font's lookups find the marks in one
order. A space of a set width the font lacks (U+2000 to U+200A, U+202F,
U+205F, U+3000) is its space with the width the character says, and the
non-breaking hyphen its hyphen (since 1.2). Each character becomes its
glyph, and a character with a variation selector the glyph the font has
for the two. The features a
text is set with are applied without being asked for: `rvrn`, `ccmp`,
`locl`, `rlig`, `liga`, `clig`, `calt` and `rclt` replace; `kern`,
`mark`, `mkmk`, `curs`, `dist`, `abvm` and `blwm` place; and where
`GPOS` has no kerning the font's `kern` table is asked. The characters
a text does not show - the soft hyphen, the joiners, the marks of
direction - are taken out once the glyphs are replaced, and a mark's
advance becomes 0.

A cluster is the byte of the text a glyph's character starts at, and a
feature's `first` and `last` count bytes too. `features` lists what is
wanted besides: a tag with the value 0 leaves one of the usual features
out - for the whole text, or for the bytes named - and any other tag
adds its feature. `run` needs its array and `room` only.

```zig
const text = "Waffle, 1/2";
var glyphs: [32]tts.ShapedGlyph = undefined;
var run: tts.ShapedRun = .{ .glyphs = &glyphs, .room = glyphs.len };
// Without the usual ligatures, with old-style figures for the "1/2".
const features = [_]tts.Feature{
    .{ .tag = tts.featureTag("liga"), .value = 0 },
    .{ .tag = tts.featureTag("onum"), .first = 8, .last = 10 },
    .{},
};
if (sb.ShapeText(outline, text.ptr, text.len, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &features, &run) == tts.TTS_OK) {
    var x: i32 = 0;
    for (glyphs[0..run.count]) |shaped| {
        // Draw shaped.glyph at x + shaped.x_offset, shaped.y_offset;
        // it stands for the text from byte shaped.cluster on.
        x += shaped.advance;
    }
}
```

The whole text is read in the one `direction`, and one read from right
to left comes back turned around, its last stretch first: a text of both
directions is the caller's to cut and to order, and no bracket is
mirrored. Every script is shaped by the features above: the joined forms
of Arabic and the syllables of the scripts of India are not made. A
character the font has no form of is the missing glyph. Where a font
has no `GPOS`, a mark left on its letter moves back onto it by its
advance and is not set by its outline's box. svg.datatype lays its text
out with this call.

**A glyph by its number** (truetype.library 1.5). A shaped run names
glyphs, and many of them - a ligature, the form a letter has at the end
of a word - have no character a font image could list them under.
`RenderGlyph(outline, glyph, rows, image)` renders one glyph for a line
`rows` tall into the caller's bytes, the way a font image has a glyph:
`image.glyph` is its box and advance (a `fontimage.Glyph`: `left` from
the point, `top` down from the top of the line, `pitch` bytes from one
row to the next), `image.kind` says what the bytes are (`alpha4`), and
`image.size` how many of them were written. The glyph comes out byte for
byte as `RenderFontImage` renders it at that height, so text drawn from
an image and glyphs drawn by number are one font. `TRUETYPEERR_ROOM`
says the bytes were too few: `size` and the box are set and nothing is
written. A glyph with no ink is `TRUETYPE_OK` with no bytes and its
advance; a font whose glyphs are pictures has none to render
(`TRUETYPEERR_GLYPH`). A shaped run's advances and offsets are in the
font's units, and `rows` over the font's ascender less its descender
makes them pixels of this line.

```zig
var fm: sdk.truetype.FontMetrics = .{};
tb.FontMetrics(outline, &fm);
const line = fm.ascender - fm.descender;
var bytes: [4096]u8 = undefined;
var image = sdk.truetype.GlyphImage{ .pixels = &bytes, .room = bytes.len };
var x: i32 = 0;
for (glyphs[0..run.count]) |shaped| {
    if (tb.RenderGlyph(outline, shaped.glyph, 24, &image) == sdk.truetype.TRUETYPE_OK) {
        const left = @divFloor((x + shaped.x_offset) * 24, line) + image.glyph.left;
        const top = image.glyph.top - @divFloor(shaped.y_offset * 24, line);
        // image.glyph.width by image.glyph.rows pixels of coverage in
        // bytes[0..image.size], drawn at left, top of the line.
    }
    x += shaped.advance;
}
```

## The system's fonts

intuition.library holds three fonts, by `SYSFONT_*`:

| | Used for |
|---|---|
| `SYSFONT_SCREEN` | screens' title bars and menus |
| `SYSFONT_DEFAULT` | text in windows and gadgets that name no font |
| `SYSFONT_FIXED` | consoles; always a fixed-width font |

Each is pospaz from the ROM until set. Pospaz has ASCII, Latin-1 and
what code page 1252 adds to it - `€`, the curly quotes, dashes, `…`,
`™`, `Œ œ Š š Ž ž Ÿ` and a few more; another letter with marks is drawn as
its base letter, and anything else as a box. `SetSystemFonts(screen, default,
fixed)` sets them for everything opened from then on (a proportional fixed
font is refused); `OpenSystemFont(which)` opens one for a program that
wants to match them. A screen takes the screen font unless given
`SA_Font` or `SA_SysFont`; a window's text takes the default font unless
`WA_SysFont` names another - a console asks for `SYSFONT_FIXED`. A title
bar is always in its screen's font. Screens and windows already open keep
the fonts they were made with.

`C:SetPrefs` sets them at boot from `ENV:Sys/font.prefs`, one line - on
the disk the Go faces at the height of the ROM's pospaz, so a window laid
out for one fits in the other:

```
SCREEN=go.font/16 DEFAULT=go.font/16 FIXED=go-mono.font/16
```

A size is in rows, or in points with `P` after it. A fourth,
`ICON=family/size`, is the font of the names under the desktop's icons;
left out, the desktop takes `DEFAULT`'s, and `C:SetPrefs` leaves it to
the desktop. Two more are a document's: `DOCUMENT=family/size` is what
text.datatype sets a document's text in - a Markdown file in MultiView -
and `CODE=family/size` the code in it and a plain text file; left out,
they are `DEFAULT`'s and `FIXED`'s. text.datatype reads them itself as
it opens a document, sizes its headings from `DOCUMENT`'s size, and
finds a family's bold and italic by name - `go-bold.font`,
`go-italic.font`, `go-bolditalic.font` beside `go.font` - drawing the
style over the nearest face it has where there is none. The disk's line:

```
SCREEN=go.font/16 DEFAULT=go.font/16 FIXED=go-mono.font/16 DOCUMENT=go.font/18 CODE=go-mono.font/15
```

Prefs' Fonts page sets all six. `SetPrefs SHOW` prints the three in use; a program reads and sets them with `GetPrefs` and
`SetPrefs` (`IPREFS_ScreenFont`, `IPREFS_DefaultFont`,
`IPREFS_FixedFont`). The boot shell's window opens after `C:SetPrefs`,
so it is in the fonts the file names.

## Making a font yourself

A program or library can put a font of its own on graphics' list. Build a
FontImage (at compile time with `fontimage.build`, or by hand at run time
with its checksum from `fontimage.checksumOf`), put a `TextFont` in front
of it in the same allocation, name it, and add it:

```zig
/// The font first, the image right after it: one allocation.
const MyFont = extern struct { font: sdk.graphics.TextFont };

const memory = sys.AllocVec(@sizeOf(MyFont) + image_size, exec.MEMF_ANY) orelse return;
const mine: *MyFont = @ptrCast(@alignCast(memory));
const image: [*]align(4) u8 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(memory)) + @sizeOf(MyFont)));
// ... fill image[0..image_size] ...
mine.* = .{ .font = .{ .node = .{ .name = "my.font" }, .image = @ptrCast(image) } };
if (!gb.AddFont(&mine.font)) return;          // the image did not hold together
// ... later, when done:
if (gb.RemFont(&mine.font)) sys.FreeVec(mine); // true once nobody holds it
```

- The `TextFont`, its name and its image stay yours; graphics only holds
  the font on its list and counts who has it open.
- `AddFont` refuses an image that does not hold together.
- `RemFont` answers false while anything has the font open, and true once
  it is off the list - also when it was not on it - so true means it is
  safe to free.
- Where waiting is not allowed (a low-memory handler),
  `AttemptRemFont` does the same without waiting, and answers false when
  the list is busy.
- `LockFonts`, `NextFont` and `UnlockFonts` walk the list to read what is
  on it.

## Tools

| | |
|---|---|
| `tools/fontconv` | on the host: BDF, Amiga font files (colour too) and TrueType files into size files and a contents file; `--alpha N` for coverage from a larger drawing, `--shadow` for a shadowed colour font |
| `scripts/fetch-fonts.sh` | fetches the fonts the disk carries - Spleen (BDF), the Go faces and Liberation's (TrueType), pinned and checked - into `toolchain/fonts/`, which the build converts into `SYS:fonts`; Liberation only onto the 64-bit machines' disks. With them two fonts only the host tests read, which go on no disk: Noto Sans Devanagari and Noto Color Emoji |
| `scripts/font-reference.py` | on the host: writes what fontTools reads from the fetched fonts - tables, measures, character maps, variation sequences, names, each glyph's measures - as the Zig files `truetype.library`'s host tests compare its answers with (`src/disk/libs/truetype/tests/reference/`), each headed by its font's file name and SHA-256. Run again when a font's pin changes; the tests need neither Python nor fontTools, and one that needs a font not fetched is skipped |
| `scripts/shape-reference.py` | on the host: applies the fetched fonts' `GSUB` and `GPOS` lookups to runs of glyphs - every glyph of a font, and sequences its lookups have rules for - with an applier of its own on fontTools' reading of the tables, and writes what comes out, a digest for each script, language and feature list, as the Zig files `truetypeshaping.library`'s host tests compare its shaping with (`src/disk/libs/truetypeshaping/tests/reference/`). `--check` says whether the files are the ones it would write, `--show <font> <case>` prints a case's runs |
| `scripts/shape-text-reference.py` | on the host: shapes texts with libharfbuzz - in the fetched fonts Latin with its kerning and marks, letters and marks spelled apart and together, Greek, Cyrillic, Hebrew read from right to left, Devanagari by its plain features, emoji, features switched for a part of a text; and in a font made of a rule, which is told the characters it lacks, texts whose characters are taken apart, sorted and put together - and writes the glyphs, clusters, advances and offsets as the Zig files `truetypeshaping.library`'s host tests compare `ShapeText`'s answers with (`src/disk/libs/truetypeshaping/tests/text_reference/`); `--check` says whether they are up to date |
| `C:ListFonts` | every font by family, size and where it is; `SAMPLE` draws them |
| `C:FixFonts` | writes every family's contents file again |
| `C:SetPrefs` | sets the system's fonts, with the rest of its settings, from `ENV:Sys`; `SHOW` prints them |
| `SYS:Programs/Prefs` | picks the system's fonts and the desktop icons' in a window and writes `font.prefs` |
| `SYS:Programs/FontView` | fonts and sizes in a window, the one chosen drawn |
| `C:test/DiskFont`, `C:test/Fonts` | test programs: open sizes and time them, or with `GLYPHS` render every glyph of an outline by its number and compare with a font image; draw a size file |
