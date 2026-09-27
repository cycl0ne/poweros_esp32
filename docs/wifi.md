# wifi.device

`DEVS:networks/wifi.device` is the chip's radio as a station. It answers the
network device API with Ethernet framing, and adds the wireless requests to
scan, join and leave.

The radio runs only on Espressif's closed libraries (libcore, libnet80211,
libpp for the MAC, libphy for the radio front end), so the device is two
halves: those libraries, linked in, and our side - the OS adapter they call,
the PHY bring-up, the supplicant, and the unit the requests come through.
The libraries are fetched once by `scripts/fetch-wifi.sh` at pinned commits
and checked against their sha256; nothing of them is committed. A tree
without them builds everything but this device.

## What is where

| file | what it holds |
| --- | --- |
| `wifi.zig` | the device: its ROM tag, its task, the requests, the radio started, the libraries' events acted on |
| `_wifi.zig` | the base, and the one block of internal memory the radio's side lives in |
| `vendor.zig` | every declaration of the libraries' own API, with the layout of each struct checked at compile time |
| `osi/` | the adapter table (`wifi_osi_funcs_t`, 120 words): interrupts, critical sections, semaphores, queues, tasks, timers, memory, time, randomness, the log |
| `phy/` | the radio front end: its power domain, its clocks, the calibration |
| `scan.zig` | S2_GETNETWORKS: what a scan found, as a tag list in the caller's pool |
| `join.zig` | S2_SETOPTIONS and S2_GETNETWORKINFO: joining, leaving, and what the station is joined to; and why it came off a network |
| `link.zig` | frames in and out, and the unit's carrier |
| `rejoin.zig` | joining again, after a pause, when the station comes off a network it was asked to be on |
| `wpa/` | the supplicant: security elements, the keys, the key handshake |

## The adapter

The libraries were built against ESP-IDF's FreeRTOS. `osi/table.zig` is the
table they are given instead, onto exec: a counting semaphore is a signal
and a count, a recursive mutex is an exec semaphore, a queue is a ring with
a signal, a task is an exec task with its FreeRTOS priority shifted down by
five, and an ETSTimer is a node on a list a timer task walks. About
twenty-five of the entries are coexistence and sleep hooks that answer zero.

The libraries reach the table through a word in mask ROM, so the adapter
keeps one variable of its own (`osi/_osi.zig`'s `adapter`) - the module's
single exception to having no globals, without which the parts of the MAC
that live in ROM could not call it. Everything else is in the block the
device allocates, reached from that one word.

The libraries start one task of their own. The supplicant's calls, the
receive callback and the transmit-done callback all run on it, so nothing
the device does may make that task wait.

## The radio up

`phy/phy.zig` brings the front end up in the order the hardware wants:

- the Wi-Fi clocks are turned on **before** anything touches the MAC. Without
  them the libraries' `hal_init` hangs with no output.
- `phy_bbpll_en_usb(true)` runs before the calibration. The calibration stops
  the bit of the PLL that clocks the USB serial, and a board being watched
  over its native USB port goes silent at that moment otherwise.
- then the power domain, the modem reset, `phy_module_enable`, and
  `register_chipv7_phy` with the init data and a calibration block carrying
  the eFuse address.

## Joining

A scan is the libraries'; the device turns its records into a tag list.

A join goes through `S2_SETOPTIONS` with the network's name, and a
passphrase for a protected one. Two tasks share the work, because the
libraries ask for the security while they associate and their task cannot
be held up:

- **the device's task** makes the pairwise master key when the request comes
  in - PBKDF2 with HMAC-SHA1 over 4096 rounds, which is 8192 hashes - and
  keeps it with the network and passphrase it was made for, so joining the
  same network again costs nothing;
- **the libraries' task** runs `wpa_sta_connect`, which reads that key, takes
  the beacon's RSN element to hold against what message 3 will repeat,
  builds the station's own element, hands it over for the association
  request, and lets the association go ahead.

The request is answered at once. The join's outcome is the link: the unit's
carrier comes when the station has joined and goes when it leaves or is
thrown off.

A network joined stays wanted until it is left. Coming off it for any
reason but its own leave, the station tries again after a pause - a second,
doubling each time up to a minute, back to a second once it has joined
(`rejoin.zig`). The first join after the board restarts is often refused,
the access point still holding the station from before; the next is let
in. `join.zig`'s `left` says why it came off, in words, because a
wrong passphrase and a network out of reach are otherwise the same silence.

### The element buffer

`esp_wifi_set_appie_internal` takes the buffer it is given as a
`struct wifi_appie`, whose first field is the element's length: it writes
that length over the first two bytes and reads the element from the third.
A buffer holding the element from its first byte comes back with its id and
length overwritten, and the access point refuses the association with
"invalid element" (reason 13). The station's element therefore has two bytes
of room in front of it.

## The key handshake

`wpa/` is the station's side of WPA2-Personal, written here on
crypto.library:

- `keys.zig` - the pairwise master key (PBKDF2-SHA1), the PRF that stretches
  it, the pairwise transient key, the MIC (HMAC-SHA1 cut to 16 bytes), and
  AES key unwrap for the group key;
- `ie.zig` - the RSN and WPA elements: parsed for the libraries on every
  beacon and probe response, and built for the association;
- `eapol.zig` - the 4-way and group key handshakes as a machine with no
  outside, so the host tests drive it without a radio;
- `supplicant.zig` - the libraries' table (`wpa_funcs`), and `Station`, which
  is what the machine reaches outside itself.

Message 4 goes out before the keys are installed, and only its
transmit-done callback lets them in: installed any earlier, the frame would
leave encrypted under a key the access point does not use yet. The
callback's flag says whether sending **failed**, and which frame went out
is read off the frame itself (`eapol.isFinal`: no key data, or the secure
bit), so message 2 going out is never taken for message 4.

The pairwise key goes in at index 0 for both directions
(`PAIRWISE | TX | RX`) with a zero eight-byte counter; the group key for
receiving only (`GROUP | RX`), with the six bytes of counter message 3
carries. A key set without its directions is taken and never used.

Three things the standard leaves to the implementation, each with its
reason:

- **the group key's send bit is dropped.** A station that has a pairwise key
  never sends under the group key, and installing it as one to send has the
  hardware use its index for what the station sends, which stops its
  traffic.
- **a replay counter is taken only once the frame carrying it has been
  believed** - its MIC checked. Taken earlier, one forged frame with a high
  counter leaves every real retransmission looking stale and the handshake
  stuck.
- **the MIC covers what the 802.1X header declares**, not what the radio
  handed over, and it is taken over the frame where it lies rather than a
  copy, so no buffer bounds a frame the station reads.

A message 3 whose RSN element differs from the beacon's is a downgrade, and
the station leaves with reason 17.

### The memory functions

The libraries copy each key into the MAC's key registers with `memcpy`.
Those registers take nothing from a store narrower than a word, and the
compiler's own `memcpy` - which would otherwise have that name in the
device - stores in whatever widths it likes: the handshake finished, the
key entries held the access point's address, and their key bytes were
zero, so nothing encrypted was sent or received. `libc.zig` defines
`memcpy`, `memmove` and `memset` as the ROM's, which store whole words
where both sides are aligned; `romld` gives every ROM address a second name,
`rom.<name>`, so they are reached though the plain names are taken.

### The libraries' log

The libraries log through the adapter, and hand some lines over as a
`va_list` their compiler built. This compiler's reading of such a list goes
wrong where the arguments move from the registers' save area to the stack:
the third argument on came out as other data, and a `%s` among them could
dereference it. `format.zig` reads those lists by the libraries' own
compiler's rule (`LibraryList`), and its own lists as the compiler reads
them (`OwnList`).

### The adapter's timed waits

Every thread the adapter makes waits with a timer.device request of its
own. A wait that is woken early aborts the request, and the abort's reply
sets the port's signal without anyone waiting for it; the port's signal is
cleared before each request, or the next wait returns at once, aborts
again, and the thread spins. Uncleared, the adapter's timer task went round
68,000 times a second, the device's task starved, and seven frames of eight
were lost off its ring.

### The panel beside the radio

On the Waveshare 7B the RGB panel's twenty lines run beside the antenna,
and at the pads' hardest drive their edges drown what the radio hears:
ten times the frames failing their check sum, and pings of half a second
or none. The board's tag list sets the pads to the weakest drive
(`RTGA_RGB_DriveStrength`), which takes the errors down by three quarters
and the pings to milliseconds.

## Tests

`tests/` holds the host tests: the adapter's ring and timer ordering, the
key vectors (IEEE 802.11's PBKDF2 and PRF, RFC 3394's key wrap), the
security elements including every prefix of a good one, and the handshake
driven by a mock access point - the whole 4-way exchange, a downgraded
message 3, key data longer than any frame the station sends, bytes past the
declared length, a forged replay counter, a handshake started over, and a
group rekey. `format.zig` has its own, including a list built by hand the
way the libraries' compiler builds one.

The access point in those tests builds its frames from the frame layout
written out in the test, not from `eapol.zig`'s own constants, so a wrong
offset there fails a test instead of agreeing with itself.

## Proved on the board

On the Waveshare 7B: the radio up and calibrated, a scan listing the
networks in range with their security, an open network joined with DHCP,
ARP and DNS behind it, and a WPA2-Personal network joined - the 4-way
handshake, both keys in the hardware, an address from DHCP, a name resolved,
a page fetched with `HTTPGet` and the clock set with `TimeSync`.

`DEVS:NetInterfaces/WLAN0` is on the disk: the boot brings the interface
up, and it takes its address once the radio has been joined to a network.

## Not done yet

- **The panel still costs the radio something.** With the pads at their
  weakest, a ping takes 4 to 40 ms and now and then a few hundred; with the
  panel stopped, 4 to 20. What is left is the panel's own noise.
- **The group key rekey has not been seen on the board**; it is in the host
  tests.
- **The group key's TKIP form is untested.** A mixed WPA/WPA2 network hands
  out a 32-byte group key, and only CCMP's 16-byte one has been exercised.
- **The reason the station came off a network only reaches the raw port.**
  It belongs in the wireless API as well, so that `C:net/Wireless` can say
  why a join did not take instead of only that it did not.
- **The calibration runs in full on every start.** It belongs in a file in
  `ENVARC:`, with a full run only when the stored one does not fit the
  board.
- **The network is not joined at boot.** WLAN0 has no network to join
  yet: a `Network` keyword and the passphrase in
  `ENVARC:Sys/net/networks/<ssid>` are still to come, so that the boot joins
  without the passphrase on a command line.
- **Nothing is taken back.** The device never expunges: the libraries keep
  tasks, timers and an interrupt that cannot all be given up.
- **WPA3, enterprise, OWE and the access point side are not there**, and the
  libraries' entries for them are left empty, which is how they are told a
  station does not have them.
- **The licence of the converted data tables** (`wifi/regulatory.zig`,
  `phy/init_data.zig`) is an open question: they were converted from
  ESP-IDF's Apache-2.0 sources and carry MIT headers.
