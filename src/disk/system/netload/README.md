# NetLoad

NetLoad shows what goes through each network interface, now and over the
last minutes.

## Starting it

Double-click its icon, or type in a shell:

```
NetLoad INTERFACE/K,INTERVAL/K/N,HISTORY/K/N
```

- `INTERFACE` is the interface shown first (the first besides `lo0`).
  One that is not there yet - an adapter still to be plugged in - is
  shown once it comes.
- `INTERVAL` is how often it looks, in seconds (1).
- `HISTORY` is how many looks the chart keeps (120: two minutes at one a
  second).

## What the window shows

- **Interface**: the interfaces there are. The list follows them while
  NetLoad runs: one brought up joins it, one removed leaves it. Pick one
  to show it.
- A line with what the interface is: its address (or `down`, `no address
  yet`), its link's speed, and its device and unit.
- **Received** and **Sent**: a bar each with the rate over the last
  interval written on it, and under it the packets a second and how much
  has gone through since the interface came up. The bar fills to the
  link's speed or to the most the chart holds, whichever is more: a
  device may say no speed (`lo0`, a serial line), or less than it
  carries.
- A chart of both rates over the last minutes, received blue and sent
  orange, in the unit the most of them needs - B/s, kB/s or MB/s, said
  under the chart - and drawn again in another when that changes.

The figures are the network stack's own counts of each interface: the
bytes of the IP and ARP packets, without the link's own header, so they
are counted the same whatever the adapter is - Ethernet, Wi-Fi, a USB
adapter, a line. Every interface is followed, not only the one shown, so
the one picked has its past on the chart at once.

## Ending it

The window's close gadget, or Ctrl-C in the shell it was started from.
