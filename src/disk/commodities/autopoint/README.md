# AutoPoint

AutoPoint makes the window under the pointer the active one, without a
click: the pointer carries the keyboard with it, so moving to a window
is enough to type into it.

## Starting it

Double-click its icon in SYS:Commodities, or type in a shell:

```
AutoPoint CX_PRIORITY/K/N
```

- `CX_PRIORITY` is its place among the commodities (0).

Started from its icon it reads the same from the icon's tool types,
which the desktop's Information... changes.

## What it does

Nothing is clicked and nothing comes to the front: the window stays
where it is in the depth order, and a window covered at the point the
pointer stands over is not the one activated.

It waits for the pointer to stand still, so a sweep across the screen
does not activate every window on the way, and it does nothing at all
while a mouse button is held, so a drag that passes over another window
does not take the keyboard away from the window being dragged in.

## Stopping it

It has no window. The controller (SYS:Commodities/Exchange) can make it
inactive and remove it; Ctrl-C from the shell it was started in ends it
too. The window last activated stays active.
