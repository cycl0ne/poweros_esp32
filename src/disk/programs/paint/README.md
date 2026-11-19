# Paint

`SYS:Programs/Paint/Paint` paints pictures with the pointer: a window
with the picture, the tools down its right and the colours along its
bottom. Paint is a drawer of its own, `SYS:Programs/Paint`, so the parts
it loads only when they are needed sit beside it rather than in `LIBS:`.

Its menus, hints, requesters and messages are in the language chosen on
Prefs' Region page when there is a catalog for it, and in English
otherwise.

```
Paint [SCREEN=OWN|DESKTOP]
```

## Where it opens

Paint opens on the desktop's screen, in a window that can be moved and
sized, or on a screen of its own: a window over the whole screen under
its bar, with the menus in the bar. `SCREEN=OWN` from the shell, or
`SCREEN=OWN` as a tool type of its icon, asks for its own screen;
`SCREEN=DESKTOP` for the desktop's. Without either it opens where it was
the last time.

Settings → Own Screen switches while it runs: the window closes and
opens again on the other screen, and the picture, the zoom, the brush,
the colours and everything that can be undone stay as they were. The
choice is kept in `ENV:Paint.prefs` and `ENVARC:Paint.prefs`, a line
`SCREEN=OWN` or `SCREEN=DESKTOP`.

## The window

- **The picture** fills the window. One smaller than the window sits in
  its middle on a dark ground; one larger is scrolled with the scroll
  bars in the window's border, with the wheel (Shift and the wheel go
  across) or with the cursor keys.
- **The tools** are down the right, two to a row, then the filled
  shapes' button, Undo and Redo, and Zoom In and Zoom Out. A tool shows
  a hint when the pointer rests on it.
- **The colours** are along the bottom: the two in use at the left - the
  foreground in front, the background behind it - and 32 to pick from.
- **The status line** says the picture's size, the zoom and the brush's
  size, and while painting the pixel under the pointer.

## Painting

The select button paints in the foreground colour, the menu button in
the background colour. Over the picture the menu button paints; the
menus open with it anywhere else in the window or the screen's bar.

The brush is round or square, 1, 2, 3, 4, 6, 8, 12, 16, 24 or 32 pixels
across: chosen in the Brush menu, or a size smaller and larger with `[`
and `]` - or `<` and `>`, which are one key on a German keyboard.

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
| Airbrush | `a` | a spray of single pixels round the pointer, for as long as the button is held, moving or not; it reaches four times the brush's size |
| Pick colour | `i` | the colour under the pointer becomes the foreground - with the menu button the background - and the tool before it is chosen again |
| Text | `t` | a click asks for the text and its font, and puts it down with its top left there |

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

## Colours

A press on one of the 32 colours with the select button makes it the
foreground, with the menu button the background. A click on the two
colours in use, or `x`, swaps them.

## The view

The zoom goes from 1:1 to 16:1 - 1, 2, 3, 4, 6, 8, 12 and 16 - with the
View menu, the two tools, or `+` and `-`; it keeps the middle of the
window where it is. From 8:1 a grid marks each pixel, which View → Grid
turns off and on. View → Actual Size goes back to 1:1.

A part of the picture that is see-through shows a light checkerboard
through it.

## The picture

A new picture is as large as the screen and white. Project → New... asks
for another size - the width and the height, typed or stepped with the
arrows, Return taking them and Escape leaving the picture as it is. A
picture that has changed is not let go - by New..., Quit, Control-C or
the window's close gadget - before a requester asks whether to discard
it.

Edit → Clear makes the whole picture the background colour.

## Undo

Every stroke, shape, fill, text and clear can be undone, with Edit →
Undo or its tool, and done again with Redo. Paint keeps as many changes
as fit in a block three pictures' worth large - or half the memory free,
when that is less; the oldest go first. A change larger than the whole
block cannot be undone, which a requester says.

## Menus

The letters are the items' keys, pressed with the right command key.

| Menu | Items |
|---|---|
| Project | New... (N), Quit (Q) |
| Edit | Undo (Z), Redo (Y), Swap Colours, Clear (K) |
| Tools | the tools; Filled Shapes |
| View | Zoom In (+), Zoom Out (-), Actual Size (1), Grid (G) |
| Brush | Round, Square, Size, Smaller ([), Larger (]) |
| Settings | Own Screen |

## Keys

| Key | Does |
|---|---|
| `+`, `-` | zoom in, out |
| `[`, `]` or `<`, `>` | a brush a size smaller, larger |
| `x` | swaps the foreground and background colours |
| a tool's letter | chooses it - see [The tools](#the-tools) |
| `F` | filled shapes on and off |
| Return, Escape | end a curve or polygon as it is, put it away |
| cursor keys | scroll the picture |
