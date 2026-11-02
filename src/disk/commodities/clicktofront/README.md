# ClickToFront

ClickToFront brings a window to the front with a double click in it: the
window it is covered by does not have to be moved out of the way first.

## Starting it

Double-click its icon in SYS:Commodities, or type in a shell:

```
ClickToFront CX_PRIORITY/K/N,QUALIFIER/K
```

- `QUALIFIER` makes it need a key held: a qualifier word a filter
  description takes - `SHIFT`, `LSHIFT`, `RSHIFT`, `CTRL`, `ALT`,
  `LALT`, `RALT`, `LCOMMAND`, `RCOMMAND` - where `SHIFT` and `ALT` are
  either of their pair. With none given, a plain double click with
  nothing held does it.
- `CX_PRIORITY` is its place among the commodities (0).

Started from its icon it reads the same two from the icon's tool types,
which the desktop's Information... changes.

## What it does

Two clicks of the left button in a window, within the double-click time
the Input settings set, bring that window in front of the others. The
clicks themselves still reach the window, so a double click that means
something there means it as well.

The window is the one the pointer stands over as the second click
lands, so a double click whose two halves are in different windows
brings the second one forward. Caps Lock never counts either way.

## Stopping it

It has no window. The controller (SYS:Commodities/Exchange) can make it
inactive and remove it; Ctrl-C from the shell it was started in ends it
too.
