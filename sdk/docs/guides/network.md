# Network

How the machine talks to a network: the TCP/IP stack a program uses, the
interfaces it runs on, the devices that carry its frames, and what it
takes to write one. The calls are in the reference:
[bsdsocket](../autodocs/bsdsocket.md) and [tls](../autodocs/tls.md); the device requests are described
in `sdk/devices/network.zig`, `sdk/devices/wireless.zig` and
`sdk/devices/telnet.zig`.

- [The layers](#the-layers)
- [Using sockets](#using-sockets)
- [Waiting: WaitSelect and signals](#waiting-waitselect-and-signals)
- [Names and addresses](#names-and-addresses)
- [TLS: a secure connection](#tls-a-secure-connection)
- [Interfaces](#interfaces)
- [Configuration files](#configuration-files)
- [The network device API](#the-network-device-api)
- [Wireless devices](#wireless-devices)
- [Writing a network driver](#writing-a-network-driver)
- [A connection as a device: telnet.device](#a-connection-as-a-device-telnetdevice)
- [Commands](#commands)

## The layers

```
 program           Socket, Connect, Send, Recv, WaitSelect, GetAddrInfo ...
    |
 bsdsocket.library the stack: TCP, UDP, IPv4, IPv6, ICMP, ARP, neighbour
    |              discovery, DHCP, routes, names - interfaces eth0, wlan0, lo0
    |  IOSana2Req (CMD_READ, CMD_WRITE, S2_ONEVENT ...)
 network device    DEVS:networks/openeth.device, DEVS:networks/wifi.device
    |
 hardware          a MAC's rings and interrupts, a radio's libraries
```

`LIBS:bsdsocket.library` is the stack. Every network device answers the
same requests (the network device API), so the stack does not know
Ethernet cable from radio, and any other program - a packet tracer, a
test - can open a device beside it.

## Using sockets

The library is opened like any other, and **the base it answers is the
opener's own**: its descriptor table, its error number and its signals.
Two tasks that both use sockets each open the library.

```zig
const bsd = sdk.bsdsocket;
const lib = sys.OpenLibrary(bsd.SOCKETNAME, 0) orelse return;
defer sys.CloseLibrary(lib);
const sb: *sdk.interface.bsdsocket.SocketBase = @ptrCast(lib);

const fd = sb.Socket(bsd.AF_INET, bsd.SOCK_STREAM, 0);
if (fd < 0) return; // sb.Errno() says why
defer _ = sb.CloseSocket(fd);

var to = bsd.sockaddr_in{
    .sin_family = bsd.AF_INET,
    .sin_port = bsd.htons(80),
    .sin_addr = .{ .s_addr = bsd.htonl(0x0A00_0202) }, // 10.0.2.2
};
if (sb.Connect(fd, @ptrCast(&to), @sizeOf(bsd.sockaddr_in)) < 0) return;
_ = sb.Send(fd, "GET / HTTP/1.0\r\n\r\n", 18, 0);
var reply: [512]u8 = undefined;
const got = sb.Recv(fd, &reply, reply.len, 0);
```

- **Families and types:** `AF_INET` and `AF_INET6` with `SOCK_STREAM`
  (TCP), `SOCK_DGRAM` (UDP) or `SOCK_RAW` (ICMP, ICMPv6); `AF_PACKET`
  for whole frames of one interface, which is how `C:net/PacketCapture`
  records what goes by.
- **The calls** are the BSD ones: `Socket`, `Bind`, `Listen`, `Accept`,
  `Connect`, `Send`/`SendTo`, `Recv`/`RecvFrom` (`MSG_PEEK`,
  `MSG_DONTWAIT`, `MSG_OOB`), `Shutdown`, `CloseSocket`, `GetSockName`,
  `GetPeerName`, `SetSockOpt`/`GetSockOpt`, `IoctlSocket` (`FIONBIO`,
  `SIOCATMARK`).
- **Errors:** a call that fails answers -1; `Errno()` gives the reason,
  or `SocketBaseTagList` with `SBTC_ERRNO` puts it where the program
  wants it. `sdk.bsdsocket.errnoText(sb, errno)` gives it in words, as
  the library has them (`SBTC_ERRNOSTRPTR`, and `SBTC_HERRNOSTRPTR` for
  a name lookup's h_errno): the network commands print
  `Connect failed: Network is unreachable - no route to it (errno 51)`.
- **Byte order:** addresses and ports inside a `sockaddr_in` are in
  network order; `htons`, `htonl`, `ntohs`, `ntohl` turn the chip's order
  into it and back. `Inet_PtoN` and `Inet_NtoP` turn text into addresses
  and back, IPv4 and IPv6.
- **Options:** `SO_REUSEADDR`, `SO_KEEPALIVE`, `SO_BROADCAST`,
  `SO_LINGER`, `SO_SNDBUF`, `SO_RCVBUF`, `SO_SNDTIMEO`, `SO_RCVTIMEO`,
  `SO_ERROR`, `SO_TYPE`, `SO_BINDTODEVICE`, `TCP_NODELAY`, and the
  `IPV6_*` ones for hop limits, multicast groups and `IPV6_V6ONLY`.

Every call runs on the caller's own task; a call that waits (a `Recv` with
nothing there, an `Accept` with no connection) waits there too.

## Waiting: WaitSelect and signals

A program that serves several sockets, or sockets and a window, waits
with `WaitSelect`: the descriptor sets to watch, a timeout, and a mask of
exec signals to wait for as well. It answers when a socket is ready, a
signal came (and says which in the mask), or the time passed.

```zig
var reads = bsd.fd_set{};
reads.set(fd);
var signals: u32 = window_signal | exec.SIGBREAKF_CTRL_C;
const ready = sb.WaitSelect(fd + 1, &reads, null, null, null, &signals);
if (signals & exec.SIGBREAKF_CTRL_C != 0) return;
if (ready > 0 and reads.isSet(fd)) handle(fd);
```

For a program built around `Wait`, a socket can raise a signal instead:
`SocketBaseTagList` with `SBTC_SIGEVENTMASK` names the signal, `SetSockOpt`
with `SO_EVENTMASK` says which events (`FD_READ`, `FD_WRITE`,
`FD_ACCEPT`, `FD_CONNECT`, `FD_CLOSE`, `FD_OOB`, `FD_ERROR`), and
`GetSocketEvents` says, when the signal comes, which socket had what.

A socket is handed to another task with `ReleaseSocket(fd, id)` and taken
there with `ObtainSocket(id, ...)`; that is how a server gives each
connection to a task, or to a device (below).

## Names and addresses

`GetAddrInfo(name, service, hints, &result)` answers every address of a
name, IPv6 and IPv4, as a list freed with `FreeAddrInfo`; `GetNameInfo`
goes the other way. A name is looked for in order:

1. `ENVARC:Sys/net/hosts` (copied to `ENV:`): an address, then its names.
2. The name servers: those DHCP gave, those in an interface file, those a
   router's advertisement named, or, with none of those,
   `ENVARC:Sys/net/nameservers`.

`GetHostByName`, `GetHostByAddr`, `Inet_Addr` and `Inet_NtoA` remain for
IPv4-only code. `GetHostName` and `SetHostName` hold the machine's name:
the one in `ENVARC:Sys/net/hostname`, read the first time an interface is
added or the name is asked for, unless `SetHostName` came first. Every
DHCP request carries it (option 12), so a router can show the machine by
name. `C:net/HostName` shows it, sets it, and with `SAVE` writes the
file.

## TLS: a secure connection

`LIBS:tls.library` puts TLS - 1.3, and 1.2 for a server that speaks
nothing newer - over a stream socket a program has connected - the program's own socket, in its own bsdsocket base, which
it keeps: it waits on it, and it closes it after the session.

```zig
const tls = sdk.tls;
const TLSBase = sdk.interface.tls.TLSBase;

const tls_lib = sys.OpenLibrary(tls.TLSNAME, 1) orelse return;
defer sys.CloseLibrary(tls_lib);
const tb: *TLSBase = @ptrCast(tls_lib);

// socket: connected to example.com, port 443.
var err: i32 = 0;
var verdict: u32 = 0;
const session = tb.OpenSession(sb, socket, &[_]utility.TagItem{
    .{ .tag = tls.TLS_Host, .data = @intFromPtr("example.com") },
    .{ .tag = tls.TLS_Protocol, .data = @intFromPtr("http/1.1") },
    .{ .tag = tls.TLS_GetVerdict, .data = @intFromPtr(&verdict) },
    .{},
}, &err) orelse return; // err: TLSERR_*, verdict: TLSV_* when it was the certificate
defer tb.CloseSession(session);

_ = tb.WriteSession(session, request.ptr, @intCast(request.len));
var buffer: [4096]u8 = undefined;
while (true) {
    const got = tb.ReadSession(session, &buffer, buffer.len);
    if (got <= 0) break; // 0: the server closed; below 0: a TLSERR_*
    // ... use buffer[0..got]
}
```

`OpenSession` does the whole handshake before it returns, and one
ClientHello offers both versions:

- **TLS 1.3**: an X25519 key share (P-256 or P-384 when the server asks
  for one), AES-128-GCM or AES-256-GCM, the server's signature by ECDSA,
  RSA-PSS or Ed25519.
- **TLS 1.2**, with a server that answers nothing newer: ECDHE on the
  same curves with AES-GCM, the server signing its key exchange with
  ECDSA or RSA (PKCS #1 or PSS); the extended master secret when the
  server agrees, and no renegotiation. A server that could have spoken
  1.3 and still answers 1.2 is refused - its random gives it away, and
  the newer version was taken off the connection on the way.

TLS 1.1 and older, CBC, RC4 and RSA key exchange are never offered. All
of it runs on crypto.library, the hashes and AES on the chip's engines.
`GetSessionAttr(TLS_Version)` and `TLS_Suite` say what a session came to.

**The server's certificates** are checked as the session opens: a chain
from the server's certificate to a trusted root, each signature, each
certificate's dates, and the host - `TLS_Host` against the names (or
addresses) the certificate lists. The trusted roots are
`SYS:Certificates/Roots`, the build's trust store made from Mozilla's
roots (`scripts/fetch-certs.sh`), and any PEM file in
`ENVARC:Sys/net/certificates/` - the place for a home server's own CA.
Both are read by the first session and kept. `TLS_GetVerdict` says what
was wrong when the check fails; `TLS_Verify` false skips it, for a test
server of one's own and nothing else. Certificates are not checked for
revocation.

**The clock** must be right for any date to be checked, so a session
refuses to open (`TLSERR_CLOCK`) while the clock is still where a cold
boot leaves it: `C:net/TimeSync`, which the boot runs, sets it. The
clock keeps local time; the session works the UTC out by
`ENVARC:Sys/timezone`.

**Waiting.** A record is decrypted whole, and what a read does not take
waits in the session, where `WaitSelect` does not see it: ask
`SessionPending` before waiting on the socket.

A session takes some 75 KiB, from the memory a program's own data goes
to. It belongs to the task that opened it.

**Trying it**: `C:net/HTTPGet https://example.com/` (TLS 1.3),
`https://tls-v1-2.badssl.com:1012/` (TLS 1.2), and badssl.com's broken
ones - `expired.`, `wrong.host.`, `self-signed.`, `untrusted-root.`,
`incomplete-chain.badssl.com` - each refused for its own reason.

## Interfaces

An interface is a network device's unit under a name - `eth0`, `wlan0` -
with its addresses; `lo0` is the loopback, always there. A program rarely
makes one itself: `C:net/AddNetInterface` does it from a file. The calls
behind it are:

| Call | Does |
|---|---|
| `AddInterfaceTagList(name, tags)` | opens the device and brings the interface up: `IFA_Device`, `IFA_Unit`, `IFA_Configure` (`IFCONFIGURE_DHCP` or fixed with `IFA_Address`, `IFA_NetMask`, `IFA_Gateway`), `IFA_NameServer`, `IFA_Domain`, `IFA_MTU`, `IFA_Reads`/`IFA_Writes`, `IFA_TCPSendSpace`/`IFA_TCPRecvSpace`, and for IPv6 `IFA_IPv6`, `IFA_InterfaceID`, `IFA_Address6`, `IFA_Prefix6`, `IFA_Gateway6`, `IFA_NameServer6` |
| `ConfigureInterfaceTagList` | changes what it runs with, or `IFA_State` online and offline |
| `QueryInterfaceTagList` | reads it back: `IFQ_Address`, `IFQ_NetMask`, `IFQ_Gateway`, `IFQ_MTU`, `IFQ_State`, `IFQ_HardwareAddress`, `IFQ_Speed`, the packet counts, the device and unit, and a time server DHCP named |
| `ObtainInterfaceList` / `ReleaseInterfaceList` | the names of all of them |
| `RemoveInterface` | takes one down and closes its device |
| `AddRouteTagList` / `DeleteRouteTagList` | routes: `RTA_Destination`, `RTA_NetMask`, `RTA_Gateway`, `RTA_DefaultGateway` |
| `AddDomainNameServer` / `RemoveDomainNameServer` | name servers, stack-wide |
| `GetNetworkStatistics` | the stack's counts, by protocol |

With DHCP, `AddInterfaceTagList` answers at once and the address comes
when the server answers; `IFQ_State` and `IFQ_Address` show when it has.
IPv6 takes a link-local address at once, and addresses from routers'
prefixes as they are advertised. How many reads and writes the stack
keeps with the device grows with the link's speed unless the file says.

## Configuration files

| File | Holds |
|---|---|
| `DEVS:NetInterfaces/<NAME>` | one interface: `AddNetInterface NAME` brings it up as `<name>` in lower case |
| `ENVARC:Sys/net/hostname` | the machine's name, sent to DHCP servers; "poweros" without it |
| `ENVARC:Sys/net/hosts` | names known without asking: an address, then its names |
| `ENVARC:Sys/net/nameservers` | name servers to ask when the network names none |
| `ENVARC:Sys/net/timeserver` | where `C:net/TimeSync` asks the time, when DHCP names no server |
| `ENVARC:Sys/net/networks/<network>` | a Wi-Fi network's passphrase, its first line |
| `ENVARC:Sys/timezone` | the local time, as a POSIX TZ rule |
| `S:Network-Startup` | run by the Startup-Sequence in a shell of its own: `AddNetInterface ALL QUIET`, then `TimeSync` |

An interface file is keywords, one to a line, and `/* */` comments:

```
Device     = networks/openeth.device
Unit       = 0
Configure  = DHCP
```

| Keyword | Sets |
|---|---|
| `Device`, `Unit` | the network device in `DEVS:` and its unit |
| `Configure` | `DHCP`, or `FIXED` (the default) with `Address`, `NetMask`, `Gateway` |
| `NameServer` | a name server, IPv4 or IPv6; up to four of each, a line each |
| `Domain` | where a name without dots is looked for |
| `MTU` | less than the link takes |
| `ReadRequests`, `WriteRequests` | how many requests the stack keeps with the device |
| `TCPSendSpace`, `TCPRecvSpace` | the ring sizes of every TCP connection |
| `Network` | the Wi-Fi network to join as the interface comes up |
| `IPv6` | `AUTO` (the default), `FIXED` (link-local and `Address6` only) or `OFF` |
| `InterfaceID` | `STABLE` (the default, from `ENVARC:Sys/net/ipv6-secret`) or `EUI64` |
| `Address6`, `Prefix6`, `Gateway6` | a fixed IPv6 address, its prefix length, and an IPv6 router |

A keyword not in the table is an error, reported with its line and
column. A board without the file's device skips the interface and says
nothing, so one set of files serves every board.

## The network device API

A network device is in `DEVS:networks/`. Every request is an
`IOSana2Req` (`sdk/devices/network.zig`): the request, a wire error, a
packet type, source and destination addresses, a length, the opener's
buffer handle, and where statistics go.

**Opening:** `OpenDevice("networks/openeth.device", unit, req, flags)`
with `SANA2OPF_MINE` for the unit alone and `SANA2OPF_PROM` for every
frame on the link. `ios2_BufferManagement` holds a tag list with
`S2_CopyToBuff` and `S2_CopyFromBuff` (both required) and
`S2_PacketFilter` (optional). **Buffers stay the opener's:** the device
copies a received packet straight from its receive ring into the opener's
buffer with the first, and a packet to send out of it with the second, so
`ios2_Data` is the opener's own handle and never has to be a plain byte
array. The copy calls run only on the device's task, never in an
interrupt.

| Request | Does |
|---|---|
| `CMD_READ` | a packet of `ios2_PacketType` (an EtherType), queued until one comes; `SANA2IOF_RAW` for the whole frame |
| `CMD_WRITE` | `ios2_DataLength` bytes of `ios2_PacketType` to `ios2_DstAddr` |
| `S2_MULTICAST`, `S2_BROADCAST` | a write to a group, or to every station |
| `CMD_FLUSH` | aborts every queued request of this opener |
| `S2_DEVICEQUERY` | the address size, MTU, speed and link type |
| `S2_GETSTATIONADDRESS` | the address the unit runs with, and the hardware's own |
| `S2_CONFIGINTERFACE` | runs the unit with an address and takes it online; once |
| `S2_ADDMULTICASTADDRESS` / `S2_DELMULTICASTADDRESS` | joins and leaves a group; counted |
| `S2_ONLINE` / `S2_OFFLINE` | puts a configured unit on and off its link |
| `S2_ONEVENT` | answered when one of the `S2EVENT_*` in `ios2_WireError` happens - at once if it already holds |
| `S2_READORPHAN` | a read for packets no opener has a read of its type for |
| `S2_TRACKTYPE`, `S2_UNTRACKTYPE`, `S2_GETTYPESTATS`, `S2_GETGLOBALSTATS`, `S2_GETSPECIALSTATS` | counts |

**Where a packet goes:** to one queued read of its type of each opener,
so a tracer beside the stack sees what the stack sees; one no read wants
goes to one `S2_READORPHAN` of each opener that has one, and is otherwise
counted and dropped. A request that has to wait needs a reply port.

`C:net/Net` speaks to a device directly - its address, its link, a frame
sent - with no stack in between.

## Wireless devices

A radio's unit takes the network device API with Ethernet framing, and the
wireless requests of `sdk/devices/wireless.zig` beside it. Information
goes both ways as tag lists of `S2INFO_*`; what the device hands back it
builds in an exec memory pool the caller gives in `ios2_Data`, freed all at
once by deleting the pool.

| Request | Does |
|---|---|
| `S2_GETNETWORKS` | scans; answers an array of tag lists, one per network: `S2INFO_SSID`, `S2INFO_BSSID`, `S2INFO_Channel`, `S2INFO_Signal` (dBm), `S2INFO_Encryption`, `S2INFO_AuthMode` |
| `S2_SETOPTIONS` | `S2INFO_SSID` and `S2INFO_Passphrase` join a network (the device does the key handshake), `S2INFO_BSSID` picks one access point, `S2INFO_Disassociate` leaves |
| `S2_GETNETWORKINFO` | the network joined, as a tag list |
| `S2_GETSIGNALQUALITY` | the signal and noise now |
| `S2_GETCRYPTTYPES` | the ciphers the device can use |

`S2_SETOPTIONS` answers at once; whether the join worked comes as
`S2EVENT_ONLINE` on `S2_ONEVENT` - the unit is online only while it has
a carrier, so a program (and the stack) waits for the event rather than
for the request. `C:net/Wireless` scans, joins and leaves by hand; a
network in an interface file's `Network` keyword is joined at every boot,
its passphrase read from `ENVARC:Sys/net/networks/<network>`.

`DEVS:networks/wifi.device` is the chip's radio as such a unit; its build
and inside are described in `docs/wifi.md`.

## Writing a network driver

A driver is a device in `DEVS:networks/`, built like any module on the
disk (`src/disk/devs/networks/<name>/`, one line in `src/disk/build.zig`).
What every driver shares is done for it by `sdk/devices/network/unit.zig`
and `sdk/devices/network/ethernet.zig`; the driver brings the hardware.

**The unit.** `network.unit.Unit(Link)` is a network unit's whole request
logic: the openers and their queues, which read a received frame goes to,
the events, the multicast groups, the tracked types and the counts. It is
made with the driver's `Link`, which it calls to work the hardware:

| The Link provides | For |
|---|---|
| `bps` | the link's speed, answered by `S2_DEVICEQUERY` |
| `setStation(link, address)` | the address the hardware answers to |
| `setRunning(link, on)` | frames in and out, or neither |
| `setFilter(link, groups, all)` | the multicast groups to take, and whether every frame |
| `startWrites(link)` | there are writes: send what `unit.nextWrite` hands out |
| `now(link)` | the system time, for the counts |

and the driver tells the unit what the hardware did:

| The driver calls | When |
|---|---|
| `unit.receive(frame)` | a frame came in; the unit copies it to the reads |
| `unit.nextWrite()`, `unit.buildFrame(req, into)`, `unit.written(req, sent)` | a frame to send taken, framed into the hardware's buffer, and answered once it went |
| `unit.setCarrier(up)` | the link came or went (a radio joining or leaving) |
| `unit.damaged()`, `unit.overrun()` | a bad frame, a frame lost for want of room |

The device's own calls hand over: `BeginIO` gives `open`, `close`,
`abort`, `query` and `stationAddress` to the unit on the caller's task,
and queues everything else to the device's task, where `unit.perform`
does it.

**Rules a driver keeps:**

- **One task does the work.** Every request that copies an opener's
  buffer runs on the device's own task; the openers' copy calls may wait,
  so they never run under a spinlock or in an interrupt.
- **Nothing polls.** A frame received, a frame sent and a change of the
  link are the hardware's interrupts, hooked with exec's `AddIntServer`
  (the numbers from `sdk.hardware.intbits`); the interrupt code only
  acknowledges the hardware and signals the task. Hardware that cannot
  interrupt is polled from a timer.device request, and only while the
  unit is online.
- **The hardware is found, not known.** The driver asks
  expansion.library for its part (`FindBoardPart(null, PARTKIND_NET,
  CHIP_...)`) and reads the
  registers, pins and interrupt from the part's tags; a board without the
  part gets no device, and the interface file for it is skipped.
- **What the hardware reaches is internal memory.** A MAC that reads and
  writes its buffers by DMA gets them in one block the init allocates
  with `MEMF_INTERNAL`, beside the interrupt server; the base, which
  MakeLibrary puts in external memory, holds only the pointer to it.
- **A queued request is a message.** A request queued with `AddTail` has
  its node's type set to `.message`, or `WaitIO` on it returns at once.

`src/disk/devs/networks/openeth/` is the worked example: the emulator's
Ethernet MAC in about three files - the device and its task
(`openeth.zig`), its state and the rings (`_openeth.zig`), the MAC's
registers (`ethmac.zig`). The unit's own tests in
`src/disk/devs/networks/tests/` run it on the host over a link of the
test's own - which read a frame goes to, orphans, filters, going offline,
groups, aborts - so a new driver needs to test only its hardware.

## A connection as a device: telnet.device

`DEVS:telnet.device` turns a TCP connection into a stream a console can
run on. **A unit is a connection:** a server releases an accepted socket
with `ReleaseSocket(fd, UNIQUE_ID)`, and opening the device with that id
as the unit takes the socket over. `CMD_READ` answers as soon as there is
a byte, the Telnet commands taken out; `CMD_WRITE` sends; an interrupt
from the peer comes as Ctrl-C, and a closed connection as
`IOERR_ENDOFSTREAM`. `C:net/ShellServer` is built on it: a shell for each
connection to port 23.

## Commands

| Command | Does |
|---|---|
| `C:net/AddNetInterface NAME/M,ALL/S,QUIET/S,TIMEOUT/K/N,NOWAIT/S` | brings interfaces up from `DEVS:NetInterfaces/` |
| `C:net/RemNetInterface`, `Online`, `Offline` | takes one down, or its device off and on its link |
| `C:net/NetStatus` | interfaces, routes, sockets, the ARP and neighbour tables, the counts |
| `C:net/Wireless` | scans, joins, leaves a Wi-Fi network |
| `C:net/Ping`, `Resolve` | echo requests; the addresses of a name |
| `C:net/HostName` | the machine's name, shown or set; `SAVE` keeps it |
| `C:net/TimeSync` | the clock from a time server |
| `C:net/HTTPGet` | a file over HTTP or HTTPS; `NOVERIFY` leaves a test server's certificate unchecked |
| `C:net/Tcp`, `Udp` | a connection or a datagram by hand |
| `C:net/PacketCapture` | an interface's frames into a pcap file |
| `C:net/ShellServer` | a shell for each connection to a TCP port |
| `C:net/Net` | a network device spoken to directly |
| `C:test/BsdSockTest` | bsdsocket.library against the BSD socket API |
