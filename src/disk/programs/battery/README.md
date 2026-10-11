# Battery

Battery shows a battery's state in a window: how full it is, how healthy,
the power going in or out, and how that power went over the last four
minutes. It reads the battery from a Victron GX device - a Cerbo GX or
one of its kind - over the network, with Modbus TCP.

## Starting it

Double-click its icon, or type in a shell:

```
Battery HOST/K,ID=UNIT/K/N,PORT/K/N,INTERVAL/K/N
```

- `HOST` is the GX device's address (192.168.1.13 if none is given).
- `UNIT` is the battery's unit ID on the GX device (225). It is the
  number the GX device lists for the battery under Settings, Services,
  Modbus TCP, Available services - not the battery's VRM instance.
- `PORT` is the device's Modbus TCP port (502).
- `INTERVAL` is how often the battery is read, in seconds (2).

Modbus TCP has to be switched on in the GX device's settings, and the
machine has to be on the same network.

## What the window shows

- The state of charge on a ring, and the state of health on a bar under
  it.
- The power on a meter: discharging to the left of 0, charging to the
  right.
- The voltage, the current, the temperature and the charge limits as
  text.
- A chart of the power over the last four minutes.
- A line at the bottom saying when the battery was last read, or why it
  could not be.

A reading the battery does not give leaves only its own field empty. When
the connection is lost, the next round connects again.

## Ending it

The window's close gadget, or Ctrl-C in the shell it was started from.
