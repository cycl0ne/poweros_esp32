# wpa.library

wpa.library's functions: a Wi-Fi station's WPA2-Personal side for a
driver whose radio leaves it to the host - the network's key from its
passphrase, the station's RSN element, and the 4-way and group key
handshakes. Open it with OpenLibrary("wpa.library", 1); the structures
are in sdk.wpa.

Generated from the source by `./zig build autodoc`.

## Index

- [CreateHandshake](#createhandshake) - Makes the station's key handshake for a join.
- [DeleteHandshake](#deletehandshake) - Frees a key handshake and the keys it held.
- [HandshakeFrame](#handshakeframe) - Hands the handshake an EAPOL frame from the access point.
- [HandshakeSent](#handshakesent) - Tells the handshake that a frame it asked to send has gone over the air.
- [HandshakeStatus](#handshakestatus) - Answers where a key handshake stands.
- [ParseSecurity](#parsesecurity) - Reads what an RSN or WPA element offers.
- [PassphraseKey](#passphrasekey) - Makes a WPA2-Personal network's key from its passphrase and name.
- [StationElement](#stationelement) - Makes the RSN element a station associates with, from the access point's.

## CreateHandshake

Makes the station's key handshake for a join.

**SYNOPSIS**

```zig
fn CreateHandshake(base: *WPABase, tags: ?[*]const utility.TagItem) ?*wpa.Handshake
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `tags`: all of them required -
  - `WPAH_Key`: the network's key (PassphraseKey);
  - `WPAH_Authenticator`: the access point's address;
  - `WPAH_Supplicant`: the station's own address;
  - `WPAH_StationElement`: the element the station associated with
    (StationElement), from its id on;
  - `WPAH_NetworkElement`: the access point's RSN element, from its
    beacon or probe response;
  - `WPAH_Hook`: the hook the handshake asks its driver through.

**RESULT**

The handshake, waiting for message 1; null when a tag is missing, an
element is too long to keep (the station's past `WPA_ELEMENT_MAX`
bytes and a little more, the access point's past 96), there is no
memory, or crypto.library can't be opened.

**BEHAVIOR**

Everything the tags point at is copied: the caller's buffers may go
once this returns. The hook is the one pointer kept, and is called
from HandshakeFrame and HandshakeSent with the handshake as the object
and a `wpa.HandshakeMessage`:

**WPAHM_SEND**: an Ethernet frame to the access point, to send now -
unencrypted, since no key is in before the last one - followed by
HandshakeSent once it has gone over the air.

**WPAHM_PAIRWISEKEY** and **WPAHM_GROUPKEY**: the keys, after message
4 has gone (pairwise first), and the group key again at every rekey.

**WPAHM_AUTHORIZED**: both keys are in; the port may open.

**WPAHM_LEAVE**: the handshake gives up - the access point's element in
message 3 is not its beacon's, or a key could not be made.

A frame the handshake can't believe - a replay counter not newer than
the last, a MIC that doesn't match - is dropped without a word; the
access point sends it again or gives up, and the radio then says the
station is off the network.

**CONTEXT**

- Waits: yes - for memory and, the first time, for crypto.library.
- Interrupts: no.
- Locks: the base's, while the first call opens the libraries; the
  caller holds no spinlock.
- Process: the first call opens crypto.library from LIBS:, which needs
  a process unless crypto.library is already loaded.

**OWNERSHIP**

The handshake is the caller's, freed with DeleteHandshake. The hook
stays the caller's, and must stay until then.

**NOTES**

The handshake holds the network's key; DeleteHandshake wipes it.

**BUGS**

None known.

**SEE ALSO**

`DeleteHandshake`, `HandshakeFrame`, `HandshakeSent`, `StationElement`,
`PassphraseKey`

**EXAMPLES**

```zig
const tags = [_]sdk.utility.TagItem{
    .{ .tag = sdk.wpa.WPAH_Key, .data = @intFromPtr(&key) },
    .{ .tag = sdk.wpa.WPAH_Authenticator, .data = @intFromPtr(&bssid) },
    .{ .tag = sdk.wpa.WPAH_Supplicant, .data = @intFromPtr(&own_address) },
    .{ .tag = sdk.wpa.WPAH_StationElement, .data = @intFromPtr(&own_element) },
    .{ .tag = sdk.wpa.WPAH_NetworkElement, .data = @intFromPtr(&network_rsn) },
    .{ .tag = sdk.wpa.WPAH_Hook, .data = @intFromPtr(&hook) },
    .{},
};
const handshake = wb.CreateHandshake(&tags) orelse return error.NoHandshake;
```

## DeleteHandshake

Frees a key handshake and the keys it held.

**SYNOPSIS**

```zig
fn DeleteHandshake(base: *WPABase, handshake: ?*wpa.Handshake) void
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `handshake`: from CreateHandshake, or null.

**RESULT**

None.

**BEHAVIOR**

The network's key and every key derived from it are wiped before the
memory goes back. Null does nothing. The hook is not called.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a task will do.

**OWNERSHIP**

The handshake is gone; the hook it was given is the caller's again.
The keys the hook installed stay where the driver put them.

**NOTES**

Not from inside the handshake's own hook: the call that called the
hook still uses the handshake.

**BUGS**

None known.

**SEE ALSO**

`CreateHandshake`

**EXAMPLES**

```zig
wb.DeleteHandshake(handshake);
handshake = null;
```

## HandshakeFrame

Hands the handshake an EAPOL frame from the access point.

**SYNOPSIS**

```zig
fn HandshakeFrame(base: *WPABase, handshake: *wpa.Handshake, frame: [*]const u8, length: u32) void
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `handshake`: from CreateHandshake.
- `frame`: the frame from its 802.1X header on - an Ethernet frame of
  type 0x888E without its 14-byte header - `length` bytes. Bytes past
  the length the 802.1X header gives are left out.

**RESULT**

None: what the frame leads to comes through the hook.

**BEHAVIOR**

**Message 1** makes the pairwise key from the access point's nonce and
a fresh one of the station's, and answers with message 2
(WPAHM_SEND). A message 1 later starts the handshake over.

**Message 3** is checked - its MIC, its replay counter, the access
point's element against its beacon's (WPAHM_LEAVE with reason 17 if
they differ) - its group key unwrapped and kept, and message 4 sent
(WPAHM_SEND). The keys wait for HandshakeSent.

**A group message** (a rekey) is checked the same way, its group key
handed over at once (WPAHM_GROUPKEY) and the reply sent.

Anything else, and any frame that does not check, is dropped.

**CONTEXT**

- Waits: no, but the hook runs inside, and may.
- Interrupts: no.
- Locks: none taken; the hook is called with whatever the caller
  holds.
- Process: a task will do.

**OWNERSHIP**

The frame stays the caller's; the handshake keeps nothing of it past
the call.

**NOTES**

One task at a time per handshake: the hook is called before this
returns, and calling HandshakeFrame or HandshakeSent again from inside
it is not allowed.

**BUGS**

None known.

**SEE ALSO**

`HandshakeSent`, `CreateHandshake`

**EXAMPLES**

```zig
if (ethertype == 0x888E) wb.HandshakeFrame(handshake, frame[14..].ptr, @intCast(frame.len - 14));
```

## HandshakeSent

Tells the handshake that a frame it asked to send has gone over the air.

**SYNOPSIS**

```zig
fn HandshakeSent(base: *WPABase, handshake: *wpa.Handshake) void
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `handshake`: from CreateHandshake.

**RESULT**

None.

**BEHAVIOR**

After message 4 the keys message 3 brought go to the hook - the
pairwise key (WPAHM_PAIRWISEKEY), then the group key (WPAHM_GROUPKEY) -
and the port is opened (WPAHM_AUTHORIZED). After any other frame it
does nothing, so a driver calls it after every frame the hook sent.

The keys wait for this rather than going in as message 4 is built:
message 4 has to leave unencrypted, and a radio that had the pairwise
key would encrypt it, which the access point can't read.

**CONTEXT**

- Waits: no, but the hook runs inside, and may.
- Interrupts: no.
- Locks: none taken; the hook is called with whatever the caller
  holds.
- Process: a task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

"Gone over the air" is the radio's transmit status for the frame. A
driver whose radio says nothing calls this when the frame has left
the host, and hopes.

**BUGS**

None known.

**SEE ALSO**

`HandshakeFrame`, `HandshakeStatus`

**EXAMPLES**

```zig
// The radio's status for the EAPOL frame it was handed:
if (handshake) |each| wb.HandshakeSent(each);
```

## HandshakeStatus

Answers where a key handshake stands.

**SYNOPSIS**

```zig
fn HandshakeStatus(base: *WPABase, handshake: *wpa.Handshake) u32
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `handshake`: from CreateHandshake.

**RESULT**

`WPAHS_WAITING` before message 1; `WPAHS_RUNNING` from message 1
until the keys are handed over; `WPAHS_DONE` after.

**BEHAVIOR**

A radio that drops frames of its own while a handshake runs - roaming,
power save - asks this. Once done, a handshake stays done: a message 1
the access point sends later, for a new pairwise key, is answered with
the port left open.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`HandshakeFrame`, `HandshakeSent`

**EXAMPLES**

```zig
const joined = wb.HandshakeStatus(handshake) == sdk.wpa.WPAHS_DONE;
```

## ParseSecurity

Reads what an RSN or WPA element offers.

**SYNOPSIS**

```zig
fn ParseSecurity(base: *WPABase, element: [*]const u8, security: *wpa.Security) bool
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `element`: the element from its id on - an RSN element (48), or a
  vendor element (221) of 00-50-F2 type 1 - as a beacon or probe
  response carries it; its length is its second byte.
- `security`: where the answer goes.

**RESULT**

True with `security` filled in; false for an element of another kind,
or one whose fields run past its length or make no sense.

**BEHAVIOR**

A field the element leaves out has the default IEEE 802.11 gives it:
for RSN, CCMP for both ciphers and 802.1X; for WPA, TKIP and 802.1X.
The pairwise ciphers and key managements are all those offered, as
bits; the group cipher is one bit.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`StationElement`

**EXAMPLES**

```zig
var security: sdk.wpa.Security = .{};
const psk = wb.ParseSecurity(rsn.ptr, &security) and security.managements & sdk.wpa.WPA_AKM_PSK != 0;
```

## PassphraseKey

Makes a WPA2-Personal network's key from its passphrase and name.

**SYNOPSIS**

```zig
fn PassphraseKey(base: *WPABase, passphrase: [*:0]const u8, ssid: [*]const u8, ssid_length: u32, key: *[32]u8) bool
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `passphrase`: 8 to 63 characters, or the key itself as 64 hex
  digits (either case).
- `ssid`: the network's name, `ssid_length` bytes (1 to 32), as its
  beacons carry it.
- `key`: where the key goes: `WPA_KEY_BYTES` bytes.

**RESULT**

True with the key in `key`. False - `key` then undefined - for a
passphrase or name out of bounds, 64 characters that are not all hex
digits, or no crypto.library.

**BEHAVIOR**

The key is PBKDF2 with HMAC-SHA1 over the passphrase, salted with the
network's name, 4096 rounds, 32 bytes (IEEE 802.11-2020, J.4). That is
8192 hashes: a driver makes it once for a network and passphrase and
keeps it, rather than for every join.

**CONTEXT**

- Waits: yes - for crypto.library, and the first call opens it.
- Interrupts: no.
- Locks: the base's, while the first call opens the libraries; the
  caller holds no spinlock.
- Process: the first call opens crypto.library from LIBS:, which needs
  a process unless crypto.library is already loaded.

**OWNERSHIP**

Nothing is allocated. The key is the caller's, and a secret: it wipes
it when it is done.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateHandshake`

**EXAMPLES**

```zig
var key: [sdk.wpa.WPA_KEY_BYTES]u8 = undefined;
if (!wb.PassphraseKey(passphrase, ssid.ptr, @intCast(ssid.len), &key)) return error.BadPassphrase;
defer @memset(&key, 0);
```

## StationElement

Makes the RSN element a station associates with, from the access point's.

**SYNOPSIS**

```zig
fn StationElement(base: *WPABase, element: [*]const u8, into: [*]u8, size: u32) u32
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `element`: the access point's RSN element from its id on, as its
  beacon or probe response carries it.
- `into`: where the station's element goes, `size` bytes;
  `WPA_ELEMENT_MAX` is always enough.

**RESULT**

The length of the element written, id and length byte included; 0
when the network asks for what the library does not do, or `size` is
too small.

**BEHAVIOR**

The station takes CCMP for its own traffic, the access point's cipher
for the group's, and the pre-shared key. A network the library can
join offers RSN, CCMP and PSK; one that offers only TKIP, WPA3's SAE,
802.1X or a WPA element, or requires protected management frames, is
refused here, so a driver knows before it associates. The
capabilities are the station's own, not the access point's: it asks
for no protected management frames.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

The element goes into the association request the radio sends, and
to CreateHandshake (WPAH_StationElement): message 2 repeats it.

**BUGS**

None known.

**SEE ALSO**

`ParseSecurity`, `CreateHandshake`

**EXAMPLES**

```zig
var own: [sdk.wpa.WPA_ELEMENT_MAX]u8 = undefined;
const own_length = wb.StationElement(network_rsn.ptr, &own, own.len);
if (own_length == 0) return error.CannotJoin;
```
