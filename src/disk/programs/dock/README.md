# Dock

Dock is a row of icons along an edge of the screen: programs, files,
drawers and disks, each opened with one click. It stays in front of the
windows, so it is always there to reach.

## Starting it

On the 64-bit machines the dock is in `SYS:WBStartup` and starts with the
desktop. On the ESP32 boards, whose screens are small, it is in
`SYS:Programs`: double-click its icon there, or type `SYS:Programs/Dock`
in a shell.

On the 64-bit machines Prefs can move it out of `SYS:WBStartup` into
`SYS:Programs`, and back: **Start with the desktop** on its Dock page.

Only one dock runs at a time. Starting it again brings the running one to
the front; `Dock QUIT` ends it, and so does **Quit Dock** in its menu. A
dock that is ended while a program started from it still runs goes from
sight at once, and waits unseen for that program to end; a new dock may
start meanwhile.

## Using it

- **A click** on an entry opens it, as a double click on its icon would:
  a program starts, a file opens in its program.
- **A click on a drawer or a disk** lists what is in it by the entry, a
  stack: drawers first, then the rest, each by name, as many as there is
  room for. A click on one opens it; the last row, **Open Drawer** or
  **Open Disk**, opens its window. Escape, or a click anywhere else,
  closes the stack.
- **Files let go on an entry** - dragged from the desktop or a drawer -
  are opened with it: let go on Notepad, a text opens in Notepad.
- **Files let go between two entries** - in the narrow room between
  their pictures - or on a separator, or at an end of the dock, are put
  in the dock there.
- **An entry dragged** along the dock moves there; dragged off the dock
  and let go anywhere else, it is taken off.
- **The menu** of an entry opens when it is held still for a moment, or -
  while the dock is the active window - with the right button. It shows
  the entry's name and offers **Open** (a drawer's or a disk's window,
  too), **Information** (the entry's icon, its tool types and comment,
  as the desktop shows them), **Remove from Dock**, **Insert
  Separator**, **Add Docklet...**, **Dock Settings...** (Prefs, on its
  Dock page) and **Quit Dock**.
- **Add Docklet...** lists the docklets in `SYS:classes/docklets`; the
  one picked is put in after the entry the menu is for, or at the end.
- **Add to Dock** in the desktop's Tools menu puts the icons picked there
  at the end of the dock.

How an entry starts - its arguments, its stack, its priority - is in its
own icon's tool types, changed with Information.

## What it shows

- **Docklets**, small pictures of the machine that keep up to date by
  themselves. Their words - shown by the pointer, or under them - say
  what they show; a click runs the program that shows more, and they
  are moved and taken off as any entry is:
  - **Clock**: the time on a clock face; its words are the time and the
    date.
  - **Battery**: the board's battery, filled as far as it is charged -
    red once it is low - with a bolt while it charges.
  - **Volume**: a speaker with a wave for each third of the volume; a
    click runs Volume.
  - **CPU**: a bar for each core, as busy as it was over the last
    second; a click runs CPULoad.
  - **Network**: an arrow down for what comes in and one up for what
    goes out, lit while something does; its words are the address and
    the rates. A click runs NetLoad.
- **A dot** by an entry whose program, started from the dock, still
  runs.
- **Where dragged files would go**, while they are dragged over the
  dock: the entry that would open them lit, or a bar where they would
  be put in. An entry dragged along the dock shows its new place the
  same way.
- **A dock that hides** (HIDE=AUTO) goes past its edge half a second
  after the pointer has left it, all but a strip four pixels wide. It
  comes back when the pointer touches the strip or the screen's edge
  beside it, when files are dragged there, or when a finger taps it.
- **Magnified entries** (MAGNIFY, on the 64-bit machines): under the
  pointer an entry grows to that many pixels, the ones beside it less,
  and the dock grows with them; the entry under the pointer stays
  under it.

On the 64-bit machines, whose screens are composed, the dock slides as
it goes and comes. On the ESP32 boards it goes at once, and does not
magnify.

## What is kept

The entries are kept in `ENVARC:Sys/dock.items`, written whenever one is
added, moved or taken off, so the dock comes back as it was - a line
each: `ITEM="SYS:Programs/Notepad"`, `SEPARATOR`, or
`DOCKLET="clock.docklet"`. How it looks
is in `ENVARC:Sys/dock.prefs`, one line:

    EDGE=BOTTOM ICONSIZE=48 LABELS=POINTER HIDE=NO KEEPCLEAR=YES MAGNIFY=0

- **EDGE** is the edge of the screen it lies along: BOTTOM, LEFT, RIGHT
  or TOP.
- **ICONSIZE** is the most pixels an entry's picture is shown at, 16 to
  128; it is never more than an eighth of the screen's height.
- **LABELS** shows the entries' names NEVER, by the entry under the
  POINTER, or ALWAYS under them.
- **HIDE** is AUTO for a dock that goes when the pointer leaves it, NO
  for one that stays.
- **MAGNIFY** is 0, or the pixels the entry under the pointer grows to:
  more than ICONSIZE, and no more than a quarter of the screen.

KEEPCLEAR is read but not acted on yet. Prefs changes all of it on its
Dock page. The dock follows both files while it runs: a change to
either - written by Prefs or by hand, or copied to `ENV:Sys` - shows at
once.
