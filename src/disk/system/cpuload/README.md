# CPULoad

CPULoad shows how busy each of the processor's cores is, now and over the
last minutes.

## Starting it

Double-click its icon, or type in a shell:

```
CPULoad INTERVAL/K/N,HISTORY/K/N
```

- `INTERVAL` is how often it looks, in seconds (1).
- `HISTORY` is how many looks the chart keeps (120: two minutes at one a
  second).

## What the window shows

- A bar for each core the machine runs with how busy it was over the last
  interval, running tasks and serving interrupts together, and a line
  under it saying how much of that was each. They stand in a grid kept
  roughly square, so sixteen cores are four rows of four.
- A chart with a line per core: how busy it was, and - up to eight cores -
  a second, lighter line for how much of that was interrupts. So a load
  that a program makes and one that the hardware makes look different at
  once. Past eight cores each keeps the one line, which is as many as can
  be told apart on one chart.

The figures are the system's own count of each core's time in tasks, idle
and in interrupts. They are exact rather than sampled: a task that runs
for a moment after every tick shows as much as it takes.

## Ending it

The window's close gadget, or Ctrl-C in the shell it was started from.
