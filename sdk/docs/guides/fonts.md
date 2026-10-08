# Fonts

How text gets onto a surface: what a font is, how one is chosen and opened,
where fonts come from, and what a program has to do to use them. The calls
themselves are in the reference: [graphics](../autodocs/graphics.md),
[diskfont](../autodocs/diskfont.md), [truetype](../autodocs/truetype.md),
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
| `default_char` | the code drawn for any code the font has no glyph for |
| `checksum` | makes the longwords of the whole block add up to zero |

**Characters are found through ranges.** A range says "codes `first` to
`last` are glyphs `glyph` onwards". A font may start and stop anywhere and
leave gaps; a code in no range is drawn as `default_char`, which every
image must have. Codes are 32 bits, so a font can hold any character set;
text passed to `Text` is bytes, each a Latin-1 code (32 to 255).

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
`fontimage.find` and `glyphFor` look a code up; `pixelsOf` finds a glyph's
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
- **Each character has its own width.** `TextLength` adds the advances up;
  `TextExtent` also says where the ink goes (a kern back makes
  `extent.min_x` negative, bold and italic can carry it past `width`);
  `TextFit` says how many characters fit a width, from the start or from
  the end.
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
  font was drawn with (its `style`) is not added again.
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
```

**A size file is a FontImage, byte for byte.** It is read with one `Read`
into one allocation, checked (`check` and `sound`), and drawn from where
it lies; nothing in it is fixed up.

**A contents file** (`sdk/libs/diskfont/fontfile.zig`) is a
`ContentsHeader` - magic `PFCT`, version, count, checksum - and one
80-byte `FontContents` per size: the file's path from `FONTS:`, its
height, drawn styles, flags, kind of pixels, nominal width, and `outline`
set for an entry that is a TrueType file (whose height is then 0). Its
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

**`OpenDiskFont`** answers a perfect match in memory at once. Otherwise it
reads the family's contents file - `FONTS:<name>`, or the name as given
when it holds a `:` - and:

- for a family with an outline, loads a size drawn at exactly that height
  and style if there is one, and otherwise renders the outline at that
  height;
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
FontImage of coverage: `OpenOutline(bytes, size)` checks the file and
keeps what rendering needs, `RenderFontImage(outline, rows, first, last)`
makes a size, `CloseOutline` gives the outline back. The file's bytes stay
the caller's until then. The line is the font's ascender to its
descender, scaled to `rows`; each glyph's curves are flattened and the
area of each pixel inside the outline measured, kept in four bits. There
is no hinting. The image has the codes asked for and the font's missing
glyph as its default character.

diskfont.library does all of this for a family whose contents file lists
an outline: a program only asks `OpenDiskFont` for a height. Rendering a
size of the Go faces takes some tens of milliseconds at text sizes, more
at display sizes, once; the result is kept like a loaded font.

## The system's fonts

intuition.library holds three fonts, by `SYSFONT_*`:

| | Used for |
|---|---|
| `SYSFONT_SCREEN` | screens' title bars and menus |
| `SYSFONT_DEFAULT` | text in windows and gadgets that name no font |
| `SYSFONT_FIXED` | consoles; always a fixed-width font |

Each is pospaz from the ROM until set. `SetSystemFonts(screen, default,
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
the desktop. `SetPrefs SHOW` prints the three in use; a program reads and sets them with `GetPrefs` and
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
| `scripts/fetch-fonts.sh` | fetches the fonts the disk carries - Spleen (BDF) and the Go faces (TrueType), pinned and checked - into `toolchain/fonts/`, which the build converts into `SYS:fonts` |
| `C:ListFonts` | every font by family, size and where it is; `SAMPLE` draws them |
| `C:FixFonts` | writes every family's contents file again |
| `C:SetPrefs` | sets the system's fonts, with the rest of its settings, from `ENV:Sys`; `SHOW` prints them |
| `SYS:Programs/Prefs` | picks the system's fonts and the desktop icons' in a window and writes `font.prefs` |
| `SYS:Programs/FontView` | fonts and sizes in a window, the one chosen drawn |
| `C:test/DiskFont`, `C:test/Fonts` | test programs: open sizes and time them; draw a size file |
