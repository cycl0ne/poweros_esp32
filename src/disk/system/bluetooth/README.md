# Bluetooth

The Bluetooth controllers set - on or off, their name, whether others
find this machine - and the devices around found, in a window.

```
Bluetooth CONTROLLER/K/N
```

`CONTROLLER` is the controller to start on, by its number (as
`C:Bluetooth` lists them); without it the window starts on the first one
there is.

## The window

**Controller.** The controllers are bluetooth.library's: the board's own,
which the library brings up as it is opened - the Raspberry Pi 4's - and
the ones their drivers offer, a USB adapter's once it is plugged in. The
chooser at the top names each by its number, its address, its device and
its unit - `0: 4C:50:DD:3D:AD:8F - usb/bluetooth.device unit 0`. With one
controller it only says which it is; with more, it picks the one the
window works on. Without one, it says so, and the window fills as soon as
one comes.

The line under it says where the controller is: being set up, failed and
why, off, or on - and then whether devices that search find this one, and
for how many seconds more where `C:Bluetooth VISIBLE <seconds>` made it
visible for a while. A message - how many devices a search found, why a
change did not work - stands there for five seconds.

- **On** turns the controller on and off. Off, it answers no device: its
  links end, and nothing finds it.
- **Name** is the name other devices see when they search, set when the
  field is left or Return is pressed. Emptied, it is the machine's name
  again.
- **Visible to others** has devices that search find this one, until it
  is cleared; a device that knows this machine reaches it either way.

The library keeps all three for the controller's next start.

**Devices** are the controller's bonds, its links and what its last
search found, one line each - the bonds first, then the devices linked
without one, then the ones a search found. A device reached over BR/EDR
and over LE with one address is one line.

- **Name** - the one it said last: at the pairing, over its link, or to a
  search; `(no name)` while it has said none.
- **Kind** - what it says it is: its class of device over BR/EDR, its
  appearance over LE, as bluetooth.library reads them (BTDeviceKind).
- **Signal** - for a device the search heard, in dBm, and in a word:
  excellent from -55 up, good from -70, fair from -85, weak below.
- **State** - paired, connected (the line drawn bold as well) or pairing,
  encrypted, and the drivers that drive it - `bthid.device` for a
  keyboard or a mouse.
- **Address** - its Bluetooth address, with `(LE)` for one reached over
  LE and `(LE, random)` for an LE device's random address, which a device
  may change from time to time.

**Search** looks for the devices around for ten seconds: the devices that
advertise over LE, the ones that answer an inquiry over BR/EDR, and the
names of those that sent none. The list grows as they are found; the line
says how many there were once it is over.

The window follows the library: whatever changes - a controller coming or
going, a device found, a link made or ended, a bond made or forgotten -
it reads again, twice a second at the most, so the list stays as it is
while nothing changes.
