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
- **The tools** are down the right: freehand and dotted freehand, then
  Undo and Redo, then Zoom In and Zoom Out. A tool shows a hint when the
  pointer rests on it.
- **The colours** are along the bottom: the two in use at the left - the
  foreground in front, the background behind it - and 32 to pick from.
- **The status line** says the picture's size, the zoom and the brush's
  size, and while painting the pixel under the pointer.

## Painting

The select button paints in the foreground colour, the menu button in
the background colour. Over the picture the menu button paints; the
menus open with it anywhere else in the window or the screen's bar.

- **Freehand** draws a line along the way the pointer goes, without
  gaps however fast it moves.
- **Dotted freehand** puts the brush down wherever the pointer is told
  to be, so a fast stroke leaves dots spread apart.

The brush is round or square, 1, 2, 3, 4, 6, 8, 12, 16, 24 or 32 pixels
across: chosen in the Brush menu, or a size smaller and larger with `[`
and `]` - or `<` and `>`, which are one key on a German keyboard.

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

Every stroke and every clear can be undone, with Edit →
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
| View | Zoom In (+), Zoom Out (-), Actual Size (1), Grid (G) |
| Brush | Round, Square, Size, Smaller ([), Larger (]) |
| Settings | Own Screen |

## Keys

| Key | Does |
|---|---|
| `+`, `-` | zoom in, out |
| `[`, `]` or `<`, `>` | a brush a size smaller, larger |
| `x` | swaps the foreground and background colours |
| cursor keys | scroll the picture |
