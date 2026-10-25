# Volume

Volume shows which output the machine plays through - its speaker,
headphones, a USB speaker - and how loud, and changes both.

## Starting it

Double-click its icon, pick **Volume...** in the desktop's Anvil menu, or
type `Volume` in a shell.

## The window

- **Output** lists the outputs there are and shows the one played
  through. Picking another plays every sound through it from then on,
  the ones already playing included.
- **Volume** is how loud that output plays, from 0 to 100 percent of as
  the sound was recorded, as loud as it sounds: half way is -18 dB, and
  each step of the slider is heard as about as much as the next. It changes while the slider is dragged. Each
  output keeps its own volume: picking another output shows that one's.

The window reads both again every second, so headphones plugged in or a
volume set in a shell (`Audio VOLUME 50`) show at once.

## What is kept

When the window closes and something was changed, every output's volume
and the output preferred go into `ENVARC:Sys/audio.prefs`, and the next
boot starts with them. The output picked here plays until the machine is
switched off or another is picked; which output is preferred - played
through whenever it is there - is set on the Sound page of Prefs or with
`Audio PREFER`.
