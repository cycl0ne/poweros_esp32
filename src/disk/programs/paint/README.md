# Paint

`SYS:Programs/Paint/Paint` paints pictures with the pointer: a window
with the tools and the colours down its left, a side panel for the
layers, the brush and the colour, and the picture under a zoom bar. Paint is a drawer of its own, `SYS:Programs/Paint`, so the parts
it loads only when they are needed sit beside it rather than in `LIBS:`:
`Libs/paintio.library` opens and saves files, and is loaded the first
time a file is opened or saved.

Its menus, hints, requesters and messages are in the language chosen on
Prefs' Region page when there is a catalog for it, and in English
otherwise.

```
Paint [FILE] [SCREEN=OWN|DESKTOP]
```

FILE is a picture or a project to open at the start.

## Where it opens

Paint opens on the desktop's screen, in a window that can be moved and
sized, or on a screen of its own: a window without a border over the
whole screen under its bar. `SCREEN=OWN` from the shell, or
`SCREEN=OWN` as a tool type of its icon, asks for its own screen;
`SCREEN=DESKTOP` for the desktop's. Without either it opens where it was
the last time.

View → Own Screen switches while it runs: the window closes and opens
again on the other screen, and the picture, the zoom, the brush, the
colours, the folded sections and everything that can be undone stay as
they were. The
choice is kept in `ENV:Paint.prefs` and `ENVARC:Paint.prefs`, a line
`SCREEN=OWN` or `SCREEN=DESKTOP`.

## The window

- **The menu titles** stay in the screen's bar while Paint's window is
  active, and a click on one opens it.
- **The tools** are down the left, two to a row, then the filled
  shapes' button, Undo and Redo. A tool shows a hint when the pointer
  rests on it.
- **The colours** are under them: the two in use - the foreground in
  front, the background behind it - with the swap beside them, and the
  picture's 32 to pick from.
- **The side panel** beside them has a section for the layers, one for
  the brush and one for the colour. A press on a section's name folds it
  away and another unfolds it. Layers: see [Layers](#layers). Brush: Round, Square or Own Brush, and its settings - see
  [The brush's settings](#the-brushs-settings). Colour: the foreground on a colour wheel - its hue
  round the wheel, its saturation out from the middle - and its
  brightness on the slider beside it.
- **The picture** fills the rest. One smaller than the view sits in its
  middle on a dark ground. One larger is moved with the hand tool or
  with Space held - a drag moves it as a hand moves paper - with the
  wheel (Shift and the wheel go across) or with the cursor keys.
- **The zoom bar** above it: smaller, the zoom in per cent, larger, and
  the whole picture as large as it fits; at its right end, Mask shows
  the mask of the layer painted in place of the picture, and Outline
  shows the edge of what is chosen, or hides it.
- **The status line** says the picture's size, the zoom and the brush's
  size, and the pixel under the pointer while it is over the picture.

## Painting

The select button paints in the foreground colour, the menu button in
the background colour. Over the picture the menu button paints; the
menus open with it anywhere else in the window or the screen's bar, or
with a click on a title in the bar.

The brush is round or square, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48 or 64
pixels across in the Brush menu - or any size from 1 to 64 on the side
panel's slider - or a size smaller and larger with `[`
and `]` - or `<` and `>`, which are one key on a German keyboard - or a
brush of your own (see [Brushes](#brushes)). While the pointer is over
the picture, the brush is shown where it would go down, in the
foreground colour.

## The tools

A tool is chosen with its button, in the Tools menu, or with its key.

| Tool | Key | Does |
|---|---|---|
| Freehand | `p` | a line along the way the pointer goes, without gaps however fast it moves |
| Dotted freehand | `.` | the brush wherever the pointer is told to be, so a fast stroke leaves dots spread apart |
| Line | `l` | a straight line from where the button goes down to where it is let go |
| Curve | `c` | a line pulled out as with Line; then a second press bends it, the curve passing through the pointer half way along |
| Rectangle | `r` | from one corner to the other |
| Ellipse | `e` | in the box from one corner to the other |
| Polygon | `n` | a corner at each release - a click, or a drag from the last corner; let go on the first corner, or on the last one again, it closes |
| Fill | `f` | the area of one colour that is pressed on, as far as the same colour reaches side by side and up and down |
| Gradient | `g` | a drag lays the foreground at its start shading into the background at its end, over the whole layer painted - or what is chosen of it; with the menu button the other way round |
| Airbrush | `a` | a spray of single pixels round the pointer, for as long as the button is held, moving or not; it reaches four times the brush's size |
| Pick colour | `i` | the colour shown under the pointer, all the layers together, becomes the foreground - with the menu button the background - and the tool before it is chosen again |
| Text | `t` | a click asks for the text and its font, and puts it down with its top left there |
| Cut brush | `b` | a frame pulled over the picture; what it holds becomes the brush - see [Brushes](#brushes) |
| Rectangle selection | `R` | a rectangle pulled out is chosen - see [Selections](#selections) |
| Lasso | `L` | a shape drawn round with the button held is chosen, closed straight back to where it began |
| Magic wand | `w` | the pixels of the colour clicked on, joined to it, are chosen |
| Eraser | `E` | the picture made see-through where the brush goes, by the brush's settings as paint is |
| Smudge | `s` | the colours under the brush dragged along the stroke, thinning as they go; the flow and the opacity say how strongly |
| Hand | | the picture moved with the pointer; Space held does the same with any tool |
| Zoom | `m` | a click zooms in about the place clicked, the menu button out |

A gradient shades along its drag: before the drag's start it is the
start's colour, past its end the end's, and between them it changes
evenly, the same along every line square to the drag. With **Round
Gradient** (Tools menu) it shades round the drag's start instead, the
drag's length its radius. While dragging, a dashed line shows the way;
the gradient goes down on release, with the brush's opacity and dither,
and is one step to undo.

Lines, curves and the outlines of rectangles, ellipses and polygons are
drawn with the brush. **Filled shapes** - the button under the tools,
Tools → Filled Shapes, or `F` - fills rectangles, ellipses and polygons
instead. While a shape is being drawn it follows the pointer, the brush
and the filling; Return ends a curve or a polygon as it is, and Escape
or Undo puts it away.

The text's window has the text and its font: the screen's font at 24
rows to begin with, and another chosen with the button beside it.
Return takes them, Escape leaves the picture as it is; both are kept for
the next text.

## The brush's settings

The Brush section of the side panel sets how the brush puts its paint
down. They hold for the freehand tools, the airbrush, the eraser, the
lines and the shapes - a filled shape too - and not for the fill tool.

| Setting | Does |
|---|---|
| Size | 1 to 64 pixels across, for the round and square brushes |
| Softness | how far in from its edge a round or square brush fades: 0 % a hard edge, 100 % from its middle |
| Opacity | the most paint a stroke puts on a pixel: however often the brush passes over it in one stroke, it gets no more |
| Flow | how much of that each touch of the brush gives: below 100 % the paint builds up where the brush goes again, up to the opacity |
| Jitter | each touch of the brush moved at random, up to the brush's size |
| Rotation | a square brush or your own turned clockwise, 0 to 359 degrees |
| Dither | paint short of whole made whole or nothing, in a fine even pattern, so a part-way opacity shows as a dot pattern of the colour |

At 100 % opacity and flow without dither the brush goes down as it
always has. While the pointer is over the picture, the brush shown
under it is what a click would put down, softness, opacity and all.

## Brushes

The cut brush tool takes a part of the picture as a brush: pull a frame
over it, and what the frame holds is the brush once the button is let
go, its pixels of the background colour left out, so it has the shape of
what is drawn. With the menu button the part is cut out, the picture
left the background colour there - which Undo puts back. Paint then
goes back to the tool before, or to dotted freehand when that one puts
no brush down.

Brush → Open Brush... takes any picture file as the brush, its
see-through parts as they are; Save Brush... writes the brush as a PNG,
or as an ILBM for a name ending in `.iff`, `.ilbm` or `.lbm`. A brush is
at most 1024 pixels a side.

The brush goes down in its own colours, or with Brush → One Colour as
its shape in the foreground colour. The menu button always puts down
its shape, in the background colour. Where the brush is partly
see-through, it is mixed into what is under it.

| Brush menu | Key | Does |
|---|---|---|
| Flip Horizontally | `h` | left to right |
| Flip Vertically | `v` | top to bottom |
| Turn Right | `z` | a quarter turn clockwise |
| Smaller, Larger | `[`, `]` | halves it, keeping every second pixel; doubles it, each pixel made four |

Round, Square or a size go back to the built-in brushes; Own Brush goes
back to yours, which stays until another is cut or opened.

## Layers

A picture is a stack of layers, each as large as the picture, and what
is shown is each layer laid over the ones below it. Painting, filling,
smudging, cutting and clearing change the layer being painted, which is
marked in the Layers section's list; picking a colour takes what is
shown.

The Layers section shows the layers top first: an eye, open while the
layer is shown - a click on it hides the layer or shows it again - and
the name. A click on a layer paints it, a double-click renames it, and
a drag moves it to another place in the stack. Above the list:

- **Opacity**, 0 to 100 %, how much of the layer painted shows, with the
  buttons that delete it and put a new one in over it;
- **Blend**, how its colours are mixed with those under it:

| Blend | Gives |
|---|---|
| Normal | the layer's colours over those under it |
| Add | the two added, brighter, as light is |
| Multiply | the two multiplied, darker, as inks are |
| Screen | the opposite of Multiply: brighter, never darker |
| Overlay | Multiply where it is dark under it, Screen where it is light |
| Darken, Lighten | the darker, the lighter of the two, colour by colour |
| Colour Dodge, Colour Burn | what is under it brightened, darkened, by the layer |
| Hard Light | Overlay as if the layer were under it |
| Soft Light | a gentle Hard Light |
| Hue, Saturation, Colour, Luminosity | that of the layer, the rest of what is under it |

A new layer is see-through; a new picture has one layer in the
background colour, called Layer 1. Clear and the menu button's cut
leave the bottom layer the background colour and any other see-through.

| Layer menu | Key | Does |
|---|---|---|
| New Layer | `L` | a see-through layer over the one painted |
| Duplicate | `D` | a copy of the one painted over it, named so |
| Delete | | the one painted taken out; the last one stays |
| Rename... | | asks for its name |
| Move Up, Move Down | | the one painted moved one place in the stack |
| Merge Down | `M` | the one painted laid into the one under it as it shows, and taken out |
| Flip Horizontally, Flip Vertically | | the one painted, left to right, top to bottom, with its mask |
| Add Mask → Show All, Hide All, Show the Selection | | a mask on the one painted, white, black, or as much as each pixel is chosen; the mask painted |
| Paint the Mask | `E` | the mask painted, or the layer again |
| Apply the Mask | | the layer left with only what the mask let show, and the mask taken off |
| Delete the Mask | | the mask taken off, the whole layer shown again |

### Masks

A layer may have a mask: a picture of greys as large as the layer,
which says how much of each pixel shows - all of it where the mask is
white, none where it is black or see-through, and as much as a grey is
bright in between. A mask hides without taking anything away: painting
it white again brings back what it hid.

While the mask is painted - Add Mask leaves it so, and Paint the Mask
turns it on and off - every tool works on the mask, in whatever colour
it is given, and the list shows `[Mask]` beside the layer; a layer with
a mask not painted shows `Mask`. Clear makes the mask black. The zoom
bar's Mask shows the mask itself, in place of the picture.

Merge Down lays the layer into the one under it as its mask lets it
show; when the one under has a mask, that is applied first.

## Selections

Part of the picture can be chosen, and then a change touches only
that part: a stroke, a shape, a fill, a text, Clear and the cut all
stop at its edge, which is shown in dashes of black and white. With
nothing chosen everything may change.

The rectangle selection, the lasso and the magic wand choose anew; with
Shift held what they choose is added to what is chosen, with Alt it is
taken away. A click with the rectangle or the lasso chooses nothing,
and so does Escape when no shape is being drawn. The magic wand takes
the colour of the layer being painted, and so do the Select items.

| Selection menu | Key | Does |
|---|---|---|
| Select → All | | every pixel |
| Select → Pixels of the Layer | | the layer painted, as far as each pixel is there |
| Select → Pixels of the Colour | | every pixel in the foreground colour |
| Select → See-through Pixels | | the layer painted, as far as each pixel is see-through |
| Select → Pixels Not in the Palette | | every pixel of a colour none of the 32 is |
| Deselect | Escape | nothing chosen |
| Invert | | what is chosen let go, and the rest chosen |
| Copy to Layer | | what is chosen of the layer painted, in a new layer over it |
| Cut to Layer | | the same, and taken from the layer it was in - one step to undo |
| Copy to Brush | `B` | what is chosen of the layer painted, as the brush |

What is chosen is not saved, and goes with a new or another picture.
Choosing is not a change to undo; the Layer menu's flips turn the whole
layer, whatever is chosen.

## Colours

A picture opened from a file with a palette - an ILBM, a GIF, a PNG
with one - brings its colours: as many of the first 32 as it has take
the places of Paint's. A project keeps its 32.

A press on one of the 32 colours with the select button makes it the
foreground, with the menu button the background. A click on the two
colours in use, on the swap beside them, or `x`, swaps them. The colour
wheel and the brightness slider make the foreground any colour.

### The palette

Palette → Edit... opens the palette in a window of its own. A colour
picked there is changed with its sliders - red, green and blue, or
hue, saturation and value - or by typing its hex value, `#RRGGBB`.
Spread, then a second colour picked, makes the colours between the two
an even run from the one to the other; Copy puts the colour chosen onto
the one picked next, Swap trades the two. OK takes the new colours,
Cancel or Escape leaves the palette as it was. With **Change the
pixels too**, OK first makes every pixel of a colour that changed - in
every layer - the new colour, keeping how see-through it is; that is
one step to undo. The foreground, when it was picked from the palette,
becomes its colour's new one.

The other items of the Palette menu:

| Palette menu | Does |
|---|---|
| From the Picture | the colours the picture shows most, darkest first, in place of the first ones - all of them when it has no more than 32 |
| Presets | Paint's Own, Greys, Spectrum, Pastel, Earth |
| Reduce | the layer painted made of the palette's colours alone: No Dither, Ordered Dither, Error Diffusion - one step to undo |
| Cycle Colours | the palette's ranges turning, and stopped again; also Tab |
| Open Palette... | a palette file, or the palette of a picture or a project |
| Save Palette... | the 32 colours as a palette file |

A palette file is text, a colour a line, six hex digits each
(`E02828`); a `#` before them and a name after are passed over, so the
files of other programs that write their colours so are read too.
Changing the palette is not a change to undo.

### Reducing to the palette

Reduce makes each pixel of the layer painted the palette's nearest
colour, weighing green most and red least, and keeps how see-through
it is. **No Dither** stops there: soft edges and gradients fall into
bands. **Ordered Dither** mixes the two colours either side of a pixel
in a fine, even 4 by 4 pattern - in the proportion the pixel lies
between them, so a colour of the palette stays as it is. **Error
Diffusion** hands what each pixel misses of its colour on to the ones
to its right and below, which gives a grain without a pattern.

### Cycling

Up to four ranges of the palette turn: their colours move along the
range, round and round, and every pixel of one of them takes on the
colour that has come to its place - the way water flows or a fire
flickers in a picture of a few colours. The pixels themselves do not
change; Tab, or Palette → Cycle Colours, starts and stops it.

A range is set in the palette's editor: choose its number under
**Range**, pick one end of it among the colours, press **Set Range**
and pick the other end. A new range turns ten steps a second;
**Speed** sets it from none to 60, and **Backwards** turns it the other
way. The text under the colours says which colours the range chosen
runs over. A project keeps its ranges.

## The view

The zoom goes from 1:1 to 16:1 - 1, 2, 3, 4, 6, 8, 12 and 16 - with the
View menu, the zoom bar, or `+` and `-`; it keeps the middle of the
view where it is. From 8:1 a grid marks each pixel, which View → Grid
turns off and on. View → Actual Size goes back to 1:1; View → Zoom to
Fit, or the zoom bar's last button, shows the whole picture at the
largest zoom it fits at.

A part of the picture that is see-through shows a light checkerboard
through it.

## The picture

A new picture is as large as the screen and white. File → New... asks
for another size - the width and the height, typed or stepped with the
arrows, Return taking them and Escape leaving the picture as it is. A
picture that has changed is not let go - by New..., Open..., Quit,
Control-C or the window's close gadget - before a requester asks whether
to save it first: Save, Don't save, or Cancel.

The window's title names the picture's file - on a screen of its own,
the screen's bar does - with a `*` in front while it has changes.

The Image menu changes the whole picture, every layer and its mask:

| Image menu | Does |
|---|---|
| Rotate | a quarter turn clockwise, anticlockwise, or a half turn |
| Flip Horizontally, Flip Vertically | the picture mirrored left to right, top to bottom |
| Crop to the Selection | the picture cut to the box round what is chosen |
| Trim | the edges cut away where all that shows is the colour of the top left corner |
| Canvas Size... | the picture put on a canvas of another size, asked with where on it the picture goes - one of nine places; what is past the canvas is cut away, and new canvas is the background colour in the bottom layer and see-through above it |
| Flatten | the layers made one as they show - hidden ones left out, masks and blend modes laid in |

Each is one step to undo, the picture's size with it; what is chosen is
let go when the size changes.

## Files

File → Open... opens a project or any picture the system has a
datatype for: PNG, ILBM, JPEG, GIF, BMP and the others. File → Save
As... asks for a name, and what the name ends in says what is written:

| Ending | Written as |
|---|---|
| `.png` | a PNG of what is shown, with the see-through parts when there are any |
| `.iff`, `.ilbm`, `.lbm` | an ILBM of what is shown, 24 planes - 32 with see-through parts |
| anything else | a project: every layer and the 32 colours, packed |

File → Save writes the file again in the same form; a picture that
came from a form Paint does not write - a JPEG, a GIF - is saved with
Save As instead. A file that cannot be read or written says why in a
requester.

A project is an IFF `FORM PNTG`: each layer, packed, with its name,
opacity, blend mode, whether it is shown and its mask, which layer is
painted, and the palette with its ranges. Opened, all of it comes back; a mask comes
back as greys.

Edit → Clear makes the whole layer painted the background colour - or
see-through, when it is not the bottom one.

## Undo

Every stroke, shape, fill, text and clear can be undone, with Edit →
Undo or its tool, and done again with Redo - and every layer put in,
deleted, moved, merged down or flipped, and every mask put on, applied
or deleted; undone, the layer it touched is painted - in its mask, when
that was what changed. Hiding a layer, its opacity, blend mode and name are not
changes to undo. Paint keeps as many changes
as fit in a block three pictures' worth large - or half the memory free,
when that is less; the oldest go first. A change larger than the whole
block cannot be undone, which a requester says.

## Menus

The letters are the items' keys, pressed with the right command key.

| Menu | Items |
|---|---|
| File | New... (N), Open... (O), Save (S), Save As... (A), Quit (Q) |
| Edit | Undo (Z), Redo (Y), Swap Colours, Clear (K) |
| Image | Rotate (90° Clockwise, 90° Anticlockwise, 180°), Flip Horizontally, Flip Vertically, Crop to the Selection, Trim, Canvas Size..., Flatten |
| Tools | the tools; Filled Shapes, Round Gradient |
| Layer | New Layer (L), Duplicate (D), Delete, Rename..., Move Up, Move Down, Merge Down (M), Flip Horizontally, Flip Vertically, Add Mask (Show All, Hide All, Show the Selection), Paint the Mask (E), Apply the Mask, Delete the Mask |
| Selection | Select (All, Pixels of the Layer, Pixels of the Colour, See-through Pixels, Pixels Not in the Palette), Deselect, Invert, Copy to Layer, Cut to Layer, Copy to Brush (B) |
| Brush | Round, Square, Own Brush, Size, Smaller ([), Larger (]), Own Colours, One Colour, Flip Horizontally, Flip Vertically, Turn Right, Open Brush..., Save Brush... |
| Palette | Edit... (P), From the Picture, Presets (Paint's Own, Greys, Spectrum, Pastel, Earth), Reduce (No Dither, Ordered Dither, Error Diffusion), Cycle Colours, Open Palette..., Save Palette... |
| View | Zoom In (+), Zoom Out (-), Actual Size (1), Zoom to Fit, Grid (G), Own Screen |
| Help | About Paint... |

## Keys

| Key | Does |
|---|---|
| `+`, `-` | zoom in, out |
| `[`, `]` or `<`, `>` | a brush a size smaller, larger; your own halved, doubled |
| `h`, `v`, `z` | your own brush flipped across, flipped down, turned right |
| `x` | swaps the foreground and background colours |
| Tab | the palette's ranges cycling on and off |
| a tool's letter | chooses it - see [The tools](#the-tools) |
| `F` | filled shapes on and off |
| Return, Escape | end a curve or polygon as it is, put it away; Escape with none chooses nothing |
| Shift, Alt held | a selection tool adds to what is chosen, takes from it |
| cursor keys | move the picture |
| Space, held | a drag moves the picture, whatever the tool |
