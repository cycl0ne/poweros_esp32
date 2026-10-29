# Notepad

Notepad is a text editor: a text file in a window, to read and to write.

Its menus, ribbon, requesters and messages are in the language chosen on
Prefs' Region page when there is a catalog for it - German is on the
disk, in `LOCALE:Catalogs/deutsch/programs/Notepad.catalog` - and in
English otherwise.

## Starting it

Double-click its icon, or type in a shell:

```
Notepad [FILE]
```

`FILE` is opened at the start. A name that does not exist yet is the file
the text is saved to.

## Using it

Type where the cursor is. Along the top is the ribbon, under it the
text. The scroll bars on the right and at the bottom move the text; the
sizing gadget is in the corner between them. The window's title shows
the file's name, with a `*` before it while the text has changed.

The menus, with their right-Amiga keys:

- **Project:** New (N), Open... (O), Save (S), Save As..., Quit (Q)
- **Edit:** Undo (Z), Redo (Y), Cut (X), Copy (C), Paste (V),
  Select All (A)
- **Search:** Find... (F), Find Next (G), Find Previous (P),
  Replace... (R)
- **View:** Word Wrap (W) and Line Numbers (L), both on to start with;
  Zig Highlighting (H), off to start with; Ribbon

**Zig Highlighting** shows Zig source in colours: keywords, types,
built-in functions (`@import`), strings, numbers and comments each in
their own, on a light field or a dark one. Each line is coloured from
what it says itself, which is all Zig needs: none of its comments or
strings goes on past the end of a line. The colours stop after a line's
first 1024 characters.

Ctrl-X, Ctrl-C and Ctrl-V cut, copy and paste as the menu does. Open and
Save As ask for the file with a file requester. A file dragged from the
desktop and dropped on the window is opened as Open opens one.

**Find...** and **Replace...** open a small window: the text to find,
what to put in its place, whether case matters, and buttons that find the
next one, replace it and find the next, or replace every one. Find Next
and Find Previous go on with the last text looked for.

A text that has changed is not let go - by New, Open, Quit or the close
gadget - before a requester asks whether to save it.

## The ribbon

The ribbon has the menus' commands as buttons with pictures, on two tabs:

- **Home:** Clipboard (Paste, Cut, Copy - Paste grey while the clipboard
  holds no text), Undo (Undo, Redo - grey while there is nothing to undo
  or redo), Editing (Find, Replace, Select All).
  Find's arrow drops down Find Next and Find Previous.
- **View:** Word Wrap and Line Numbers, and Zig for Zig Highlighting -
  each a toggle that is down while it is on, and the menu's check mark
  says the same.

**View → Ribbon** hides the ribbon and shows it again; Notepad remembers
that in `ENV:Notepad.prefs` (`RIBBON=NO` hides it) and in `ENVARC:`. In a
low window, on a small board's screen, the ribbon is only its row of tabs:
a tab drops its page down when it is clicked. Without ribbon.gadget,
toolbutton.gadget or command.image Notepad has no ribbon and works as
before.

## Ending it

Quit in the Project menu, the window's close gadget, or Ctrl-C in the
shell it was started from.
