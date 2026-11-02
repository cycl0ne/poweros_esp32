# Blanker

Blanker darkens the screen when nothing has been typed or moved for a
while, and the first key, move or touch brings it back.

## Starting it

Double-click its icon in SYS:Commodities, or type in a shell:

```
Blanker SECONDS/K/N,CYCLECOLORS/K,ANIMATION/K,CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K
```

- `SECONDS` is the quiet it waits for, 1 to 9999 (60).
- `CYCLECOLORS=YES|NO` walks the colours (YES).
- `ANIMATION=YES|NO` draws a moving figure (YES).
- `CX_POPKEY` is the hotkey that brings the window up (`ctrl alt b`), in
  the form of commodities.library's descriptions: qualifiers, then a key
  - `lcommand f10`, `shift alt e`.
- `CX_POPUP=NO` starts it without the window: it runs on, and its hotkey
  shows it.
- `CX_PRIORITY` is its place among the commodities (0).

Started from its icon it reads all of them from the icon's tool types,
which the desktop's Information... changes. Those are the lasting
settings: what the window changes holds until it ends.

## What it does

After `SECONDS` of quiet - no key, no mouse, no finger, and no mouse
button held - a screen of its own comes to the front with nothing on it,
and the pointer stops being drawn. The first key, move or touch after
that closes it again and goes no further, so the stroke that wakes the
screen does not also land in whatever window was active.

With `ANIMATION` a figure of straight lines moves over the screen and
leaves a trail; with `CYCLECOLORS` it walks through the colours - or,
with no animation, the screen fills with a colour that changes slowly.
With neither, the screen stays black and the panel's backlight goes off
as well, which is what saves a panel that is on all day; with something
moving the backlight has to stay on to be seen.

## Its window

- **Seconds until it blanks**, **Cycle colours**, **Animation** - the
  three settings, each in force as soon as it is changed.
- **Project:** Hide (H), Quit (Q)

The close gadget and Hide only hide the window: Blanker runs on, and its
hotkey or starting it again bring the window back. Quit, Remove in the
controller (SYS:Commodities/Exchange) or Ctrl-C in its shell end it.
