# Volume

Volume shows which output the machine plays through - its speaker,
headphones, a USB speaker - how loud, and how its equalizer is set, and
changes all three.

## Starting it

Double-click its icon, pick **Volume...** in the desktop's Anvil menu, or
type `Volume` in a shell.

## The window

- **Output** lists the outputs there are and shows the one played
  through. Picking another plays every sound through it from then on,
  the ones already playing included.
- **Volume** is how loud that output plays, from 0 to 100 percent of as
  the sound was recorded, as loud as it sounds: half way is -18 dB, and
  each step of the slider is heard as about as much as the next. It
  changes while the slider is dragged. Each output keeps its own volume:
  picking another output shows that one's.
- **Equalizer** is a slider for each of ten bands, from 31 Hz to 16 kHz,
  each raising or lowering its band up to 12 dB; the dB is above the
  slider and the frequency below. It is heard while a slider is dragged.
  **Preset** picks a curve by name - Classical, Jazz, Pop, Rock, Dance,
  Techno, Hip-Hop, Speech, More bass, More treble, Loudness, Small
  speaker - and shows the one the bands are, or Custom once a band is
  moved away from it. **Flat** puts every band back at 0. Each output keeps its own: picking
  another output shows that one's, and an output none was set for plays
  flat. While a band is raised the whole is turned down by as much, so
  the loud parts are not clipped. The group is ghosted when the device
  has no equalizer.

The window reads the output and its volume again every second, so
headphones plugged in or a volume set in a shell (`Audio VOLUME 50`)
show at once.

## What is kept

When the window closes and something was changed, every output's volume
and equalizer and the output preferred go into `ENVARC:Sys/audio.prefs`,
and the next boot starts with them. The output picked here plays until the machine is
switched off or another is picked; which output is preferred - played
through whenever it is there - is set on the Sound page of Prefs or with
`Audio PREFER`.
