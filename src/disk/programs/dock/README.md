# Dock

Dock is a row of icons along an edge of the screen: programs, files,
drawers and disks, each opened with one click. It stays in front of the
windows, so it is always there to reach.

## Starting it

On the 64-bit machines the dock is in `SYS:WBStartup` and starts with the
desktop. On the ESP32 boards, whose screens are small, it is in
`SYS:Programs`: double-click its icon there, or type `SYS:Programs/Dock`
in a shell.

Only one dock runs at a time. Starting it again brings the running one to
the front; `Dock QUIT` ends it, and so does **Quit Dock** in its menu.

## Using it

- **A click** on an entry opens it, as a double click on its icon would:
  a program starts, a file opens in its program, a drawer or a disk opens
  its window.
- **Files let go on an entry** - dragged from the desktop or a drawer -
  are opened with it: let go on Notepad, a text opens in Notepad.
- **Files let go between two entries**, or on a separator, are put in the
  dock there.
- **An entry dragged** along the dock moves there; dragged off the dock
  and let go anywhere else, it is taken off.
- **The menu** of an entry opens when it is held still for a moment, or -
  while the dock is the active window - with the right button. It shows
  the entry's name and offers **Open**, **Information** (the entry's
  icon, its tool types and comment, as the desktop shows them),
  **Remove from Dock**, **Insert Separator** and **Quit Dock**.
- **Add to Dock** in the desktop's Tools menu puts the icons picked there
  at the end of the dock.

How an entry starts - its arguments, its stack, its priority - is in its
own icon's tool types, changed with Information.

## What is kept

The entries are kept in `ENVARC:Sys/dock.items`, written whenever one is
added, moved or taken off, so the dock comes back as it was. How it looks
is in `ENVARC:Sys/dock.prefs`, one line:

    EDGE=BOTTOM ICONSIZE=48 LABELS=POINTER HIDE=NO KEEPCLEAR=YES MAGNIFY=0

- **EDGE** is the edge of the screen it lies along: BOTTOM, LEFT, RIGHT
  or TOP.
- **ICONSIZE** is the most pixels an entry's picture is shown at, 16 to
  128; it is never more than an eighth of the screen's height.
- **LABELS** shows the entries' names NEVER, by the entry under the
  POINTER, or ALWAYS under them.

HIDE, KEEPCLEAR and MAGNIFY are read but not acted on yet. The dock
follows both files while it runs: a change to either - written by hand,
or copied to `ENV:Sys` - shows at once.
