# NumericPad

NumericPad puts a numeric keypad on a keyboard that has none: while Caps
Lock is on, the block of keys on the right of the keyboard is the pad.

## Starting it

Double-click its icon in SYS:Commodities, or type in a shell:

```
NumericPad CX_PRIORITY/K/N
```

- `CX_PRIORITY` is its place among the commodities (0).

Started from its icon it reads the same from the icon's tool types,
which the desktop's Information... changes.

## The keys

```
8 9 0 -     the ( ) / * of the pad
I O P [     7 8 9 -
K L ; '     4 5 6 +
, . /       1 2 3
space       0, and Return the pad's Enter
```

Each arrives as the keypad key it stands for, qualifier and all, so a
program that tells the keypad from the main keys sees the keypad.

The keys of that block that are not part of the pad do nothing while
Caps Lock is on: with it on the keyboard is a keypad, not a keyboard in
capitals. The keys that type nothing - Backspace, Tab, Escape, Delete,
the cursor and function keys, Insert, Page Up, Page Down, Home and End -
are left alone and work as they always do, and so does Caps Lock itself,
which turns the pad off again.

A keyboard that has a keypad of its own is unaffected: its keys are
already the keypad's and pass through as they are.

## Stopping it

It has no window. The controller (SYS:Commodities/Exchange) can make it
inactive and remove it; Ctrl-C from the shell it was started in ends it
too.
