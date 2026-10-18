# MemMap

MemMap shows where the memory is and who holds it, as a map that is
drawn again every second.

## Starting it

Double-click its icon, or type in a shell:

```
MemMap INTERVAL/K/N
```

- `INTERVAL` is how often it looks again, in seconds (1).

## What the window shows

- A band for each of the system's memory regions - external memory,
  internal memory - with its name, its size and how many bytes one
  pixel stands for. The band starts at the region's lowest address, top
  left, and goes on to the right and down.
- Each pixel in the colour of whoever holds those bytes:
  - **the system** - libraries, devices, what they keep;
  - **a task** - the ones that hold the most each have a colour of their
    own, the others share grey;
  - **a task that has ended** - red: what it allocated and never gave
    back, or what a library allocated while working for it and keeps;
  - **nobody** - light grey: free.
- A block its owner asked to be private is a darker shade of its colour.
  MemMap's own memory is private, so it shows itself that way.
- Under the bands, a legend: how much the system, the ended tasks and each
  task with a colour hold, how much is free, and how many blocks there
  are.

Every block the system hands out carries a small header with its owner and
size; MemMap reads them all. A damaged header - a program writing past the
end of its block - is named in the legend with its address.

## Ending it

The window's close gadget, or Ctrl-C in the shell it was started from.
