# fontconv

Converts fonts into the system's own files: a size file that is a font
image byte for byte (`sdk/libs/graphics/fontimage.zig`) and a family's
contents file listing its sizes (`sdk/libs/diskfont/fontfile.zig`).

```
fontconv <out dir> <family> [--alpha N] [--shadow] <source>...
```

Writes `<out dir>/<family>/<rows>` for each source and
`<out dir>/<family>.font`. A source is:

- a **BDF** file - one size, the characters 32 to 255 and the default
  character;
- an **Amiga size file** - the hunk load file of one size, colour fonts
  included, which become palette fonts with the pen's colour marked;
- an **Amiga contents file** (`<family>.font`) - every size it lists,
  read from beside it.

`--alpha N` reads sources drawn 2 or 4 times too large and writes fonts
of coverage (four bits a pixel) at their size divided by N. `--shadow`
writes a colour font: each letter in the pen, a translucent black
shadow one pixel down and right.

The build runs it on what `scripts/fetch-fonts.sh` fetched and puts
the result in `SYS:fonts` (`FONTS:`). Its tests run with
`./zig build test`.
