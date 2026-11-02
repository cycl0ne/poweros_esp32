# NoCapsLock

NoCapsLock makes the Caps Lock key ineffective: the key stays where it
is and its light still comes on, but the letters arrive small.

## Starting it

Double-click its icon in SYS:Commodities, or type in a shell:

```
NoCapsLock CX_PRIORITY/K/N
```

- `CX_PRIORITY` is its place among the commodities (0).

Started from its icon it reads the same from the icon's tool types,
which the desktop's Information... changes.

## What it does

Every key that reaches the windows while Caps Lock is on arrives as if
it were off. Nothing else about the key changes - a program that reads
the qualifier itself sees it cleared, and a hotkey that wants Caps Lock
held is never met.

`CX_PRIORITY` decides what the other commodities see: one of lower
priority sees the keys with Caps Lock already cleared, one of higher
priority sees them as they came.

## Stopping it

It has no window. The controller (SYS:Commodities/Exchange) can make it
inactive, which leaves Caps Lock working again, and remove it; Ctrl-C
from the shell it was started in ends it too.
