# MultiView

MultiView shows a file in a window: a picture, an animation, a sound, a
text, a Markdown document like this one - whatever kind of file the
system knows.

## Starting it

Double-click a file whose icon opens MultiView, double-click MultiView's
own icon to be asked for a file, or type in a shell:

```
MultiView [FILE] [CLIP/K/N] [SCALE/S] [PUBSCREEN/K]
```

- `FILE` is the file to show. Without one, a file requester asks for it.
- `CLIP` shows the contents of that clipboard unit instead of a file.
- `SCALE` shows a picture at the size of the window rather than its own.
- `PUBSCREEN` opens the window on that public screen rather than the
  default one.

## Using it

- The scroll bars on the right and at the bottom move the view over what
  does not fit.
- A file dragged from the desktop and dropped on the window is shown in
  place of the one there.
- A picture too large to be held whole is kept smaller, and the window's
  title says so.

MultiView knows no formats itself. The datatypes classes in
SYS:classes/datatypes read the files, and the descriptors in
DEVS:DataTypes say which class reads which kind of file - so a new kind
of file needs a new class and a new descriptor, not a new MultiView.

## Ending it

The window's close gadget, or Ctrl-C in the shell it was started from.
