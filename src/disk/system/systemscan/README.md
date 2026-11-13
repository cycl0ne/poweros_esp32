# SystemScan

SystemScan looks at the machine it runs on and writes down what it is
made of, as one text: to read in a window, and to save as a file and
carry to another machine. It is the first thing to run on a machine the
system has not been on before - what it lists with no driver is what
there is to write.

## Starting it

Double-click its icon, or type in a shell:

```
SystemScan TO
```

- `TO` is the drawer the report is saved in. Without it the field at the
  top of the window starts at `POWEROS:Scans` where a volume called
  `POWEROS` is in - the boot partition of the medium a machine is first
  started from, a FAT volume every other system reads - and at
  `SYS:Scans` otherwise.

## What the window shows

- **Save in** - the drawer for the file; its button asks for one.
- **Save** - writes the report there as
  `scan-<year><month><day>-<hour><minute><second>.txt`, by the machine's
  clock, making the drawer where it is not there. The line below says
  what the file is called, or why it could not be written.
- **Scan** - looks at the machine again.
- The report, which can be read, selected and copied but not changed.

## The report

It starts with the PCI functions no driver has claimed, by what their
class code says they are - network, display, sound and video, storage,
USB and other serial buses, wireless, serial ports, input - each with
where it is, its vendor and device IDs, its class code, its revision and
its subsystem. Bridges and the chipset's own parts are not counted. The
functions that have a driver follow, with the driver's name.

Then the listings the system's commands give, each under a heading that
names the command:

| Heading | Command |
|---|---|
| The system | `Version` |
| The machine | `Platform` |
| The board and its parts | `ShowConfig` |
| The devices, by what they speak | `ShowConfig DEVICES` |
| Memory | `Avail` |
| PCI functions | `PCIInfo`, `PCIInfo TREE` |
| USB | `USBInfo`, `USBInfo FULL` |
| Displays | `Rtg FULL` |
| Sound outputs | `Audio LIST` |
| Network | `NetStatus INTERFACES` |
| Drives and volumes | `Info` |
| The system log | `Log LINES 400` |
| PCI functions, in full | `PCIInfo FULL`, `PCIInfo HEX` |

Before it looks, SystemScan starts every drive nothing has used yet, so
that each one's volume is there to be listed - the boot partition of the
stick a machine was started from among them, which is where the report
is then saved.

A command that is not on the disk leaves the shell's own line under its
heading. The report is also left in `T:SystemScan.txt`.
