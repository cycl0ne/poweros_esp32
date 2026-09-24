# Screenshots

PowerOS 0.1 in Espressif's QEMU (`./zig build qemu-display`, with the QEMU
from `scripts/build-qemu.sh`), on the 1024×600 display the Waveshare 7"
board has. Every program shown is on the flash disk and runs from there.

## Graphics: `C:test/Anim`

![Anim](anim.png)

graphics.library in one moving picture: filled polygons with a hole
(the star), circles and arcs, lines with patterns, a ball blitted through a
mask, gradients, a tiled background, text measured and drawn in bold, and a
scroller in italic and underlined - everything in one RastPort, redrawn
every frame.

## The shell

![Shell](shell.png)

The machine comes up in a shell window. `Info` lists the mounted disks -
the flash disk `DH0:` named `System`, and `RAM:` - and `Avail` the memory:
internal SRAM and the 8 MiB of PSRAM. The blue block is the cursor.

## Fonts: `C:test/Fonts`

![Fonts](fonts.png)

The system's font, `pospaz.font`, at 8 and 16 rows: every character from
32 to 255. The 16-row size is the 8-row one with every row drawn twice,
and it is the screen's default.

## Menus: `C:test/Intuition MENUS`

![Menus](menus.png)

A window's menus, shown in the screen's title bar while the menu button is
held: items with keyboard shortcuts, an item that opens a submenu (»), and
a menu that is disabled.

## A requester: `C:test/Intuition REQUESTER`

![Requester](requester.png)

A requester inside a window: text, a string field being typed into, and
two buttons that end it.

## Gadgets: `C:test/Intuition SLIDERS`

![Sliders](sliders.png)

Sliders in the window's borders, a string field, and two framed buttons in
a group gadget - each an object of one of intuition's gadget classes.
