# MouseBlanker

MouseBlanker takes the pointer out of the way while the keyboard is in
use: as soon as a key is typed the pointer stops being drawn, and the
first move of the mouse brings it back.

## Starting it

Double-click its icon in SYS:Commodities, or type in a shell:

```
MouseBlanker CX_PRIORITY/K/N
```

- `CX_PRIORITY` is its place among the commodities (0).

Started from its icon it reads the same from the icon's tool types,
which the desktop's Information... changes.

## What it does

Only the picture of the pointer goes: it is still where it was, and a
press still reaches whatever it stands over. The key that blanks it is
not kept from the windows either - it is typed where it was aimed.

A key held with a command key is a menu shortcut, where the pointer is
wanted: those leave it alone. So does every key once the pointer is
already blanked, so holding a key down does not fight the mouse.

## Stopping it

It has no window. The controller (SYS:Commodities/Exchange) can make it
inactive, which brings the pointer back and leaves it alone, and remove
it; Ctrl-C from the shell it was started in ends it too. The pointer
comes back either way.
