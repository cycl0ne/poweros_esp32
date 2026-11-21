# WiFi

The networks a radio hears, joined and left in a window, and the one it
joins at every start.

```
WiFi INTERFACE/K
```

`INTERFACE` is the radio to start on, by its interface's name (`wlan0`);
without it the window starts on the first radio there is.

## The window

**Radio.** The chooser at the top names each radio as its interface, its
device and its unit: `wlan0 - networks/cyw43455.device unit 0`. A radio is
a network interface whose device answers the wireless requests, so it is
found once its interface is up - `C:net/AddNetInterface` brings one up from
its file in `DEVS:NetInterfaces/`, and the startup brings up every file
there. With one radio the chooser only says which it is; with more, it
picks the one the window works on.

The line under it says where the station is: the network it is on, the
channel, the band and the signal, and the address the interface has - or
that it is on no network, or the join under way. It is asked again every
three seconds. An address that starts with `169.254` is one the interface
gave itself because no DHCP server answered yet.

**Networks in range** is what the last scan heard. Every network name is
one line, however many access points send it - the strongest one's signal,
channel and way in, and every band any of them is on - the strongest first.
A network that sends no name is left out, since a station joins by name.

- **Signal** - in dBm, and in a word: excellent from -55 up, good from
  -67, fair from -75, weak below.
- **Band** - 2.4 GHz for channels 1 to 14, 5 GHz above.
- **Security** - open, WEP, WPA, WPA2, WPA3, the mixed modes as WPA/WPA2
  and WPA2/WPA3, or enterprise.
- **State** - on it (the line is drawn bold as well), joining, known when
  a passphrase is kept for it, and at start for the one the radio joins as
  the machine starts.

The window scans as it opens and when another radio is picked; **Scan**
asks again. A scan takes a few seconds and the window goes on working
while it runs.

**Join**, or a double-click on a line, joins the network picked. An open
network is joined at once, a protected one with the passphrase kept for
it; without one, a window asks for it. The passphrase is 8 to 63
characters, or the key itself as 64 hex digits. **Keep the passphrase**
keeps it for the next time - it is written only once the station is on
the network with it, so a wrong one is never kept. The line under the
chooser follows the join; one that has not come off after twenty seconds
is given up and the network left, so that the radio does not go on trying
a wrong passphrase. An enterprise network, which asks for an account, is
not joined.

**Leave** leaves the network the station is on, or gives up the join under
way. **Forget...** deletes the passphrase kept for the network picked and,
if it is the one joined at start, stops that too, once it has asked.

**Settings...** opens `SYS:System/Network` on the radio's interface: how
it gets its address - DHCP or a fixed one - its name servers and IPv6.

**Join at start** is checked when the network picked is the one the radio
joins as the machine starts. Checking it makes the network picked that
one; clearing it makes the radio join none. A protected network is joined
at start only once its passphrase is kept.

## The files

What is joined at start is the `Network` of the radio's interface file,
`DEVS:NetInterfaces/WLAN0` for `wlan0`:

```
Device    = networks/cyw43455.device
Unit      = 0
Configure = DHCP
Network   = "Home"
```

The window changes that line only - written over, added at the end, or
taken out - and leaves the rest of the file as it is, comments and all.
A radio without an interface file has the box dimmed.

A passphrase is kept as the first line of `ENVARC:Sys/net/networks/<name>`,
the file named after the network. A network whose name holds a `:` or a
`/` names no file, and its passphrase cannot be kept.

## What it is built on

The radio does the work - its device scans, joins and agrees on the keys
with the access point - and `bsdsocket.library` gives the interface its
address once the station is on a network. The files are the
ones the startup reads, so a network joined at start here is the one
`AddNetInterface` joins, and `C:net/wireless` shows and joins the same
networks from a shell.
