# MediaKeys

MediaKeys makes the media keys work for the whole system - play/pause,
play, pause, stop, previous, next, rewind, fast forward, mute and the
volume down and up - from every keyboard that has them and from the
buttons of Bluetooth headphones, wherever the active window is.
S:Startup-Sequence starts it.

## Starting it

Double-click its icon in SYS:Commodities, or type in a shell:

```
MediaKeys STEP/K/N,CX_PRIORITY/K/N
```

- `STEP` is how far a volume key turns the volume, in percent (5), 1
  to 50.
- `CX_PRIORITY` is its place among the commodities (0).

Started from its icon it reads the same from the icon's tool types,
which the desktop's Information... changes.

## What it does

The volume keys turn the output the machine plays through up and down
by `STEP` percent, onto the steps - from 52% up to 55 and down to 50 -
between 0 and 100. A percent is as loud as it sounds, as on the Volume
window's slider and in `Audio VOLUME`. Held, they repeat. Mute switches
the output's sound off and on again, its volume kept; a volume key
while it is off switches it on. The Volume window and the volume in
the dock show both.

The other keys go to the Player (SYS:Programs/Player) when it runs, as
if they were pressed in its window: play/pause pauses and goes on, play
and pause do only that, stop stops, previous and next go to the song
before and after, rewind and fast forward jump ten seconds. With no
Player running they do nothing.

While it runs, no window sees these keys.

## Stopping it

It has no window. The controller (SYS:Commodities/Exchange) can make it
inactive - the keys then reach the active window, and the Player's
window takes them as its own, the volume keys there its own volume -
and remove it; Ctrl-C from the shell it was started in ends it too.
