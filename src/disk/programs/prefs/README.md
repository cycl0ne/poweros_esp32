# Prefs

Prefs holds the system's settings in one window: the style that gadgets,
windows and menus are drawn in, the colours of the screens, the fonts,
the desktop and a few of the system's own settings.

## Starting it

Double-click its icon, or type `SYS:Programs/Prefs` in a shell.

## The pages

The settings are on six pages, under tabs:

- **Style:** the looks there are to choose from - one style file each in
  SYS:Prefs/Presets/Styles - and a few gadgets drawn in the one chosen.
  Choosing one makes it the style being edited, which the other pages
  can then change.
- **Advanced:** a part and a state chosen at the top, and that part's
  look in that state below: its border and the way a bevel's corners
  meet, its colours, its border's thickness, its corners' radius, its
  padding, its opacity and how long a change into the state takes. A
  field left empty is the system's default; a value that means nothing
  is refused, and the line at the bottom says why. Beside each colour a
  chooser picks the default, one of the screen's pens, or a colour of
  its own; the field beside it takes a pen's name, `#RRGGBB`, `#AARRGGBB`
  or, for a background, two colours `#top..#bottom`.
- **Colours:** the system's twelve pens, which every screen without pens
  of its own is drawn in, each typed as `#RRGGBB` or picked on the colour
  wheel, and a button for the built-in ones.
- **Fonts:** the fonts of the screens, the windows, the consoles and the
  desktop's icons.
- **Desktop:** the desktop's ground - one colour, or two shaded from top
  to bottom - a picture over it and how it is placed, how large icons are
  shown, and how a drawer with no view of its own is shown.
- **System:** the double-click time, the height of a screen's font when
  it is given none, when the keyboard on the screen comes up, and whether
  a window may be moved partly past the screen's edges.

The colour wheel opens in a window of its own over the editor: the wheel,
its brightness beside it, the colour shown on a button and typed in a
field, and OK and Cancel. Until it is closed the editor takes no input.

## Keeping the settings

- **Save** keeps the settings for good: they are written to ENV:Sys and
  ENVARC:Sys.
- **Use** keeps them until the machine starts again: they are written to
  ENV:Sys alone.
- **Cancel** leaves everything as it was.

Save and Use hand the settings to the system at once. Every open window
takes the style and the colours straight away; new fonts are used by what
opens from then on.
