# Prefs

Prefs holds the system's settings in one window: the style that gadgets,
windows and menus are drawn in, the colours of the screens, the fonts,
the desktop, the sound, the dock and a few of the system's own settings.

## Starting it

Double-click its icon, or type `SYS:Programs/Prefs` in a shell.
`SYS:Programs/Prefs PAGE=DOCK` opens it on a page, named as its tab is -
which is what **Dock Settings...** in the dock's menu does.

## The pages

The settings are on eight pages, under tabs:

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
  its own; the field beside it takes a pen's name, a blend of up to three
  pens (`BACKGROUND:8+SHINE:7+FILL`), `#RRGGBB`, `#AARRGGBB` or, for a
  background, two colours `#top..#bottom`.
- **Colours:** the system's twelve pens, which every screen without pens
  of its own is drawn in, each typed as `#RRGGBB` or picked on the colour
  wheel, and a button for the built-in ones.
- **Fonts:** the fonts of the screens, the windows, the consoles and the
  desktop's icons, and under them the two a document is read in - its
  text, and the code in it, which is also what a plain text file is
  shown in. MultiView reads a Markdown file in them.
- **Desktop:** the desktop's ground - one colour, or two shaded from top
  to bottom - a picture over it and how it is placed, how large icons are
  shown, whether an icon that is moved snaps into the nearest free cell
  of the grid (as the desktop's Window menu switches it too), how a
  drawer with no view of its own is shown, and whether each drawer opens
  in a window of its own (A window per drawer) or in the window of the
  drawer it is in - the default; a disk opens a window of its own either
  way.
- **System:** the double-click time, the height of a screen's font when
  it is given none, when the keyboard on the screen comes up, whether a
  window may be moved partly past the screen's edges, and whether the
  close, depth and zoom gadgets in the title bars are wide.
- **Sound:** the outputs and their volumes on the left - which one is
  preferred, played through whenever it is there and taking the sound
  over when it is plugged in, and a slider for each output that is
  there or that the settings name, heard at once while it moves; under
  them the equalizer of the output picked above it, a slider for each
  of ten bands from 31 Hz to 16 kHz, -12 to +12 dB, heard at once, a
  Preset chooser of curves by name (Classical, Rock, Techno, Speech, ...)
  and Flat - and the beep on the right: whether the screen flashes, and the sound
  played with it - none, a tone of a pitch and a length, or a sound
  file - at what volume. Test plays the beep as it is set; a line at
  the bottom says what came of it.
- **Dock:** the edge of the screen the dock lies along, the most pixels
  its pictures are shown at, when the entries' names are shown - never,
  by the one under the pointer, or always - and whether the dock goes
  when the pointer leaves it. On the 64-bit machines also whether the
  entries near the pointer grow, and to how many pixels - more than the
  icon size - and whether the dock starts with the desktop: Save moves
  it and its icon into SYS:WBStartup, or out into SYS:Programs, where
  it is started by hand; Use leaves it where it is. The entries
  themselves are changed on the dock.

The colour wheel opens in a window of its own over the editor: the wheel,
its brightness beside it, the colour shown on a button and typed in a
field, and OK and Cancel. Until it is closed the editor takes no input.

## Keeping the settings

- **Save** keeps the settings for good: they are written to ENV:Sys and
  ENVARC:Sys.
- **Use** keeps them until the machine starts again: they are written to
  ENV:Sys alone.
- **Cancel** leaves everything as it was; the volumes, the equalizers
  and the preferred output, which change while they are set, go back to
  what they were, as they do when the window is closed.

Save and Use hand the settings to the system at once. Every open window
takes the style, the colours and the title bars' gadgets straight away;
new fonts are used by what opens from then on.
