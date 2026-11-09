# Clock

Clock shows the time in a window, on a dial with hands or in figures, with
the date under it.

## Starting it

Double-click its icon, click the clock in the dock, or type in a shell:

```
Clock MODE/K,SECONDS/K,DATE/K,HOURS/K/N,LEFT/K/N,TOP/K/N,ANALOGSIZE/K,DIGITALSIZE/K,PUBSCREEN/K
```

- `MODE` is `ANALOG`, the dial, or `DIGITAL`, the figures (`ANALOG`).
- `SECONDS` is `YES` or `NO`: the second hand, or the seconds beside the
  figures (`YES`).
- `DATE` is `YES` or `NO`: the date in the locale's words (`YES`).
- `HOURS` is `12` or `24`. Without it the locale's way of writing the time
  decides.
- `LEFT` and `TOP` are where the window opens; without them it opens in
  the middle of the screen.
- `ANALOGSIZE` and `DIGITALSIZE` are the size of the window's inside in
  each mode, as `WIDTHxHEIGHT` (`200x224` and `300x116`).
- `PUBSCREEN` is the public screen it opens on.

Started from its icon it reads the same as tool types: `MODE=DIGITAL`,
`SECONDS=NO`, and so on.

Only one Clock runs. Starting it again - or clicking the dock's clock while
one is open - brings its window to the front.

## What the window shows

- **The dial**: a metal bezel round a paper face, a mark for every minute
  and a wider one for every hour, the quarters longest. The hour and
  minute hands are dark iron, the second hand red with a weight at its
  tail; each throws a shadow down and to the right. The minute hand moves
  on at each minute.
- **The figures**: the hours and minutes in large blue figures on a dark
  panel, the colon blinking each half second, the seconds smaller beside
  them, and AM or PM above the seconds on a twelve-hour clock.

The date stands under the dial, or along the foot of the panel: in full
when it fits, short when only that fits, and left out when neither does.

The dial and the figures are drawn to fit the window, whatever its size.

## The menus

- **Project**: Analog, Digital, About, Quit.
- **Settings**: Seconds, Date and 24 Hours, each on or off; Save Settings.

A double click in the window changes between the dial and the figures as
well. The window keeps a size for each: changing over gives it the size it
last had in the other.

Save Settings writes what it shows, where the window is and its size in
both modes into the program's icon as tool types, so it opens that way the
next time; the icon's other tool types are kept. The 24 Hours setting is
written only once it has been changed, so until then it goes on following
the locale.

## Ending it

The window's close gadget, Quit, or Ctrl-C in the shell it was started from.
