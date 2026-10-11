# FontView

FontView lists every font the system has and draws a line of text in the
one chosen.

## Starting it

Double-click its icon, or type `FontView` in a shell. It takes no
arguments.

## Using it

- The font families are listed on the left: those in the ROM, those in
  memory and those in FONTS: on the disk.
- Beside them are the sizes of the family chosen: the heights it was
  drawn at, or, for a family with an outline, a range of heights it can
  be rendered at.
- Choosing a size opens that font. A line under the lists says what it
  is - how many rows, where it came from, whether it was drawn or made
  from an outline, and its kind of pixels - and a sample line is drawn in
  it below.
- A font's file (`Name.font`) dragged from the desktop and dropped on the
  window chooses that family.

## Ending it

The window's close gadget, or Ctrl-C in the shell it was started from.
