# Emoji

Emoji is a window to pick an emoji from. The one picked is typed into
the window that was being worked in, as if a key had typed it.

## Starting it

Double-click its icon in SYS:Commodities, or type in a shell:

```
Emoji CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K
```

- `CX_POPKEY` is the hotkey that brings the window up (`ctrl alt e`), in
  the form of commodities.library's descriptions: qualifiers, then a key
  - `lcommand f10`, `shift alt e`.
- `CX_POPUP=NO` starts it without the window: it runs on, and its hotkey
  shows it.
- `CX_PRIORITY` is its place among the commodities (0).

Started from its icon it reads the same three from the icon's tool
types, which the desktop's Information... changes.

It needs the emoji and their names in `LOCALE:Emoji` (`emoji.list` and
a `<language>.names` for each language), and says so and ends when the
list is not there.

## Its window

- **Search**: what is typed here is looked for in the names of the
  emoji and in the words each is found by. Every word typed has to be
  part of one of them - `cat face` finds the cat faces, `herz` the
  hearts in German. Capitals and small letters are the same. Return
  types the first one found.
- **The tabs**: the first holds the emoji used last, the newest first,
  up to 40; each of the others one group, under the first emoji of the
  group. A press on a tab ends a search.
- **The grid**: the emoji of the tab, or the ones found. A press on one
  shows its name in the line below; letting go over it types it. The
  bar at its side and the mouse's wheel move through the rows.
- **The tone**: the skin tone the emoji that have tones are shown and
  typed in - none, or one of five from light to dark.

The names are in the first of the locale's languages that `LOCALE:Emoji`
has a file for, and in English for what that language leaves unnamed.

## Where an emoji goes

Into the window that had the keyboard before Emoji's window took it.
That window gets the keyboard back, and then the emoji arrives as
typing does: in a text or string gadget, in a shell's window, in a
program that reads characters. A line that was being typed into goes on
being typed into, the cursor where it was. An emoji of several characters - a flag,
a family, a hand in a skin tone - arrives as each of them in turn.

When there was no such window, or it has closed since, the screen
flashes and nothing is typed. Emoji's window stays open; a click on it
picks the next one.

## What is kept

The emoji used last and the tone are written to `ENV:Sys/emoji.used`
and `ENVARC:Sys/emoji.used` when the window is put away and when Emoji
ends:

```
emoji-used 1 <tone>
<emoji>
...
```

`<tone>` is 0 for none or 1 to 5; the emoji follow one a line, the
newest first.

The close gadget only hides the window: Emoji runs on, and its hotkey
or starting it again bring the window back. Remove in the controller
(SYS:Commodities/Exchange) or Ctrl-C in its shell end it.

## What it looks like

The emoji are drawn as text in the screen's font, opened larger. What
each one looks like is what the fonts draw for its characters: one the
fonts have no picture for shows as the fonts show any character they
lack.
