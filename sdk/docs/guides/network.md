# Network

How the machine talks to a network: the TCP/IP stack a program uses, the
interfaces it runs on, the devices that carry its frames, and what it takes
to write one. The calls are in the reference:
[bsdsocket](../autodocs/bsdsocket.md), [tls](../autodocs/tls.md) and
[filter](../autodocs/filter.md); the
device requests are described in `sdk/devices/network.zig`,
`sdk/devices/wireless.zig`, `sdk/devices/slip.zig`,
`sdk/devices/telnet.zig` and `sdk/devices/ssh.zig`.

- [The layers](#the-layers)
- [Using sockets](#using-sockets)
- [Groups: multicast](#groups-multicast)
- [Waiting: WaitSelect and signals](#waiting-waitselect-and-signals)
- [Names and addresses](#names-and-addresses)
- [TLS: a secure connection](#tls-a-secure-connection)
- [Interfaces](#interfaces)
- [Configuration files](#configuration-files)
- [The network device API](#the-network-device-api)
- [Wireless devices](#wireless-devices)
- [A serial line: slip.device](#a-serial-line-slipdevice)
- [Writing a network driver](#writing-a-network-driver)
- [A connection as a device: telnet.device](#a-connection-as-a-device-telnetdevice)
- [SSH: ssh.device](#ssh-sshdevice) - the server, its files over sftp
  and scp, the client (`C:net/SSH`), copying (`C:net/SCP`), the device
- [A packet filter](#a-packet-filter) - its rules, `C:net/Filter`, and
  the packet hooks it is built on
- [Commands](#commands)

## The layers

```
 program           Socket, Connect, Send, Recv, WaitSelect, GetAddrInfo ...
    |
 bsdsocket.library the stack: TCP, UDP, IPv4, IPv6, ICMP, ARP, neighbour
    |              discovery, IGMP, MLD, DHCP, DHCPv6, routes, names - interfaces
    |              eth0, wlan0, lo0
    |  IOSana2Req (CMD_READ, CMD_WRITE, S2_ONEVENT ...)
 network device    DEVS:networks/openeth.device, DEVS:networks/wifi.device,
    |              DEVS:networks/slip.device
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
const lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return;
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
  `MSG_DONTWAIT`, `MSG_OOB`), `RecvMsg` (several buffers, and control
  messages: `IPV6_RECVHOPLIMIT` gives each IPv6 datagram's hop limit,
  walked with `cmsgFirst`/`cmsgNext`/`cmsgData`), `Shutdown`, `CloseSocket`, `GetSockName`,
  `GetPeerName`, `SetSockOpt`/`GetSockOpt`, `IoctlSocket` (`FIONBIO`,
  `SIOCATMARK`).
- **Errors:** a call that fails answers -1; `Errno()` gives the reason, and
  `SetErrnoPtr` has the library keep it in a variable of the program's as
  well. `sdk.bsdsocket.errnoText(sb, errno)` gives it in words, as the
  library has them (`SBTC_ERRNOSTRPTR`, and `SBTC_HERRNOSTRPTR` for a name
  lookup's h_errno): the network commands print
  `Connect failed: Network is unreachable - no route to it (errno 51)`.
- **Byte order:** addresses and ports inside a `sockaddr_in` are in
  network order; `htons`, `htonl`, `ntohs`, `ntohl` turn the chip's order
  into it and back. `Inet_PtoN` and `Inet_NtoP` turn text into addresses
  and back, IPv4 and IPv6.
- **Options:** `SO_REUSEADDR`, `SO_KEEPALIVE`, `SO_BROADCAST`,
  `SO_LINGER`, `SO_SNDBUF`, `SO_RCVBUF`, `SO_SNDTIMEO`, `SO_RCVTIMEO`,
  `SO_ERROR`, `SO_TYPE`, `SO_BINDTODEVICE`, `TCP_NODELAY`, the `IP_*`
  ones for multicast groups, and the `IPV6_*` ones for hop limits,
  multicast groups and `IPV6_V6ONLY`.

Every call runs on the caller's own task; a call that waits (a `Recv` with
nothing there, an `Accept` with no connection) waits there too.

## Groups: multicast

A datagram socket joins a group to get what is sent to it - mDNS's
`224.0.0.251` and `ff02::fb`, SSDP's `239.255.255.250`:

```zig
var here: bsd.sockaddr_in = .{ .sin_port = bsd.htons(5353) };
_ = sb.Bind(fd, @ptrCast(&here), @sizeOf(bsd.sockaddr_in));
const request: bsd.ip_mreq = .{
    .imr_multiaddr = .{ .s_addr = sb.Inet_Addr("224.0.0.251") },
    .imr_interface = .{ .s_addr = bsd.INADDR_ANY }, // the route's interface
};
_ = sb.SetSockOpt(fd, bsd.IPPROTO_IP, bsd.IP_ADD_MEMBERSHIP, &request, @sizeOf(bsd.ip_mreq));
```

`IPV6_JOIN_GROUP` with an `ipv6_mreq` does the same for an IPv6 group, on
an interface named by its index (`If_NameToIndex`). The first socket in a
group joins it on the interface's device and tells the link's routers -
and the switches that listen - with IGMP (IPv4) or MLD (IPv6), and answers
their queries for as long as it stays; the last one out says it left.
`IP_DROP_MEMBERSHIP` and `IPV6_LEAVE_GROUP` leave, and so does
`CloseSocket`. A socket is in up to 4 groups, an interface in up to 8 of
each family that sockets joined.

What comes to a group goes to every socket in it that is bound to its
port, each a copy of its own. Sent to a group, a datagram stays on the
link (a time to live, or hop limit, of 1) unless `IP_MULTICAST_TTL` or
`IPV6_MULTICAST_HOPS` says otherwise; goes out of the interface
`IP_MULTICAST_IF` or `IPV6_MULTICAST_IF` names, or the route's; and
reaches this machine's own members too, unless `IP_MULTICAST_LOOP` or
`IPV6_MULTICAST_LOOP` is 0. A `PF_INET6` socket that speaks IPv4 takes
both families' options, and the two of each pair are one setting.
`C:net/NetStatus COUNTS` shows the IGMP and MLD reports sent.

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

1. `ENVARC:Sys/net/hosts`: an address, then its names.
2. The name servers: those DHCP gave, those in an interface file, those a
   router's advertisement or DHCPv6 named, or, with none of those,
   `ENVARC:Sys/net/nameservers`.

`GetHostByName`, `GetHostByAddr`, `Inet_Addr` and `Inet_NtoA` remain for
IPv4-only code. `GetHostName` and `SetHostName` hold the machine's name:
the one in `ENVARC:Sys/net/hostname`, read the first time an interface is
added or the name is asked for, unless `SetHostName` came first. Every
DHCP request carries it (option 12), so a router can show the machine by
name. `C:net/HostName` shows it, sets it, and with `SAVE` writes the
file.

## TLS: a secure connection

`LIBS:tls.library` puts TLS - 1.3, and 1.2 for a server that speaks nothing
newer - over a stream socket a program has connected - the program's own
socket, in its own bsdsocket base, which it keeps: it waits on it, and it
closes it after the session.

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
| `AddInterfaceTagList(name, tags)` | opens the device and brings the interface up: `IFA_Device`, `IFA_Unit`, `IFA_Configure` (`IFCONFIGURE_DHCP` or fixed with `IFA_Address`, `IFA_NetMask`, `IFA_Gateway`), `IFA_NameServer`, `IFA_Domain`, `IFA_MTU`, `IFA_Reads`/`IFA_Writes`, `IFA_TCPSendSpace`/`IFA_TCPRecvSpace`, and for IPv6 `IFA_IPv6`, `IFA_InterfaceID`, `IFA_PrivacyAddresses`, `IFA_Address6`, `IFA_Prefix6`, `IFA_Gateway6`, `IFA_NameServer6` |
| `ConfigureInterfaceTagList` | changes what it runs with - its IPv6 address too (`IFA_Address6`) - `IFA_PrivacyAddresses` on or off, or `IFA_State` online and offline |
| `QueryInterfaceTagList` | reads it back: `IFQ_Address`, `IFQ_NetMask`, `IFQ_Gateway`, `IFQ_MTU`, `IFQ_State`, `IFQ_HardwareAddress`, `IFQ_Speed`, the packet counts, the device and unit, and a time server DHCP named |
| `ObtainInterfaceList` / `ReleaseInterfaceList` | the names of all of them |
| `RemoveInterface` | takes one down and closes its device |
| `AddRouteTagList` / `DeleteRouteTagList` | routes: `RTA_Destination`, `RTA_NetMask`, `RTA_Gateway`, `RTA_DefaultGateway`; IPv6 ones with `RTA_Destination6`, `RTA_PrefixLength6`, `RTA_Gateway6`, `RTA_DefaultGateway6`, `RTA_Interface` |
| `AddDomainNameServer` / `RemoveDomainNameServer` | name servers, stack-wide |
| `GetNetworkStatistics` | what the stack holds, by kind: `NETSTATUS_COUNTS` (its packet counts), `ROUTES`, `SOCKETS`, `ARP`, `ADDRESSES6`, `ROUTES6`, `NEIGHBORS`, `NAMESERVERS` |

With DHCP, `AddInterfaceTagList` answers at once and the address comes
when the server answers; `IFQ_State` and `IFQ_Address` show when it has.
IPv6 takes a link-local address at once, and addresses from routers'
prefixes as they are advertised. A router whose advertisement sets the M
flag hands out addresses by DHCPv6: the stack asks for them, renews and
gives them back, each one alone (`/128`, NetStatus marks it `dhcp`); one
that sets only the O flag has its name servers and search domain there,
which the stack asks for and asks again after the server's refresh time.
How many reads and writes the stack keeps with the device grows with the
link's speed unless the file says.

## Configuration files

| File | Holds |
|---|---|
| `DEVS:NetInterfaces/<NAME>` | one interface: `AddNetInterface NAME` brings it up as `<name>` in lower case |
| `ENVARC:Sys/net/hostname` | the machine's name, sent to DHCP servers; "poweros" without it; a new name in it is in force at once while the network runs |
| `ENVARC:Sys/net/hosts` | names known without asking: an address, then its names |
| `ENVARC:Sys/net/nameservers` | name servers to ask when the network names none |
| `ENVARC:Sys/net/timeserver` | where `C:net/TimeSync` asks the time, when DHCP names no server |
| `ENVARC:Sys/net/networks/<network>` | a Wi-Fi network's passphrase, its first line |
| `ENVARC:Sys/net/syslog` | a syslog server: `S:Network-Startup` starts `C:Log SYSLOG` to it |
| `ENVARC:Sys/net/shellserver` | `C:net/ShellServer`'s password, its first line (Telnet and SSH) |
| `ENVARC:Sys/net/authorized_keys` | the ssh-ed25519 keys that may log in over SSH, OpenSSH's lines |
| `ENVARC:Sys/net/ssh_host_key` | the SSH host key, made at the first start; `.pub` beside it |
| `ENVARC:Sys/net/id_ed25519` | the key `C:net/SSH` and `C:net/SCP` log in with, made by `SSH KEYGEN`; `.pub` beside it |
| `ENVARC:Sys/net/known_hosts` | the host keys `C:net/SSH` and `C:net/SCP` have seen, OpenSSH's lines |
| `ENVARC:Sys/net/filter` | the packet filter's rules: `S:Network-Startup` loads them before any interface comes up |
| `ENVARC:Sys/timezone` | the local time, as a POSIX TZ rule |
| `S:Network-Startup` | run by the Startup-Sequence in a shell of its own: `AddNetInterface ALL QUIET`, then `TimeSync`, then `Log SYSLOG` when `Sys/net/syslog` names a server |

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
| `PrivacyAddresses` | `YES`: temporary addresses (below); `NO`, the default |
| `SerialDevice`, `SerialUnit`, `Baud` | the serial line under `slip.device` (below) |

**Privacy addresses** (RFC 8981): an address made from a router's prefix
ends the same on that network at every boot, so whatever the machine
connects to can tell it is the same machine. With `PrivacyAddresses = YES`
the interface has, beside each such address, a temporary one in the same
prefix whose last 64 bits are random. Connections going out are made from
it; what comes in is answered from the address it came to. A temporary
address stays preferred for about a day - each for a random part less, so
the machines on a link do not all change at once - and is valid for two;
a few seconds before it stops being preferred a new one is made, and the
old one lasts for the connections it still has. `C:net/NetStatus` marks
them `temporary`.

A keyword not in the table is an error, reported with its line and
column. A board without the file's device skips the interface; with
`QUIET`, as `S:Network-Startup` runs it, it says nothing, so one set of
files serves every board (without, it names the interface it could not
add and ends with `WARN`).

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

## A serial line: slip.device

`DEVS:networks/slip.device` carries IP over a serial line (SLIP, RFC
1055) to whatever is at the other end - a PC with `slattach`, another
board. A frame is the packet itself, so the link has no addresses and no
ARP: whatever the routes send out of it goes to the other end. It has no
DHCP either; the address is given:

```
/* DEVS:NetInterfaces/SL0 */
Device       = networks/slip.device
Address      = 192.168.7.2
SerialDevice = serial.device
SerialUnit   = 1
Baud         = 115200
IPv6         = OFF
```

The serial line is any device with serial.device's API - a UART of
serial.device, or usbserial.device's unit 0 - opened when the interface
comes up and given back when it goes; without the three keywords it is
serial.device's unit 1 at 115200 baud. Each of the device's two units is a
line of its own. The MTU is 1006 bytes, RFC 1055's; the other end should
say the same (`slattach -p slip -s 115200 /dev/ttyUSB0`, then
`ip addr add 192.168.7.1 peer 192.168.7.2 dev sl0` and `ip link set sl0
up mtu 1006` on Linux). A program opening the device itself names the
line with the tags of `sdk/devices/slip.zig` in its open's tag list;
AddInterfaceTagList hands them on from `IFA_DeviceTags`.

In QEMU, `-Dslip=tcp::5021,server,nowait` puts the emulator's UART1 -
serial.device's unit 1 - on a TCP port for a program on the host to be the
other end.

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

The device's own calls hand over: `Open`, `Close` and `AbortIO` go to
the unit's `open`, `close` and `abort`; `BeginIO` does `S2_DEVICEQUERY`
and `S2_GETSTATIONADDRESS` with `query` and `stationAddress` on the
caller's task, and queues everything else to the device's task, where
`unit.perform` does it.

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
`IOERR_ENDOFSTREAM`. The client's window size, when it tells it (NAWS,
RFC 1073) - again each time the window changes - is what
serial.device's `SDCMD_TERMSIZE` answers, so the console lists Tab's
names as wide as the window. `C:net/ShellServer` is built on it: a shell
for each connection to port 23.

## SSH: ssh.device

SSH both ways: `C:net/ShellServer SSH` lets others in to a shell and to
the files on this machine, and `C:net/SSH` takes this machine's console
to a shell on another, `C:net/SCP` copies files to and from it. They are
`DEVS:ssh.device`, one end of it each.

### The server: ShellServer SSH

`C:net/ShellServer SSH` serves SSH on port 22 instead of Telnet on 23:
the connection is encrypted, and nobody gets in without logging in.

- **Logins**: the password in `ENVARC:Sys/net/shellserver`, and the keys in
  `ENVARC:Sys/net/authorized_keys` - OpenSSH's lines, ssh-ed25519 keys (a
  PC's `~/.ssh/id_ed25519.pub` copied in as it is) - read again for each
  connection, so a key added counts for the next login. With neither at
  its start, ShellServer will not start. Six failed tries end a connection, and a
  client has two minutes to log in.
- **The host key** is made at the first start, in
  `ENVARC:Sys/net/ssh_host_key`, with its public half beside it in
  `ssh_host_key.pub`; ShellServer prints its fingerprint, which the client
  shows on its first connection - the two should be the same.
- **What a client may ask for**: a shell (`ssh machine`), with a
  terminal, or one command (`ssh machine list SYS:`), which runs with its
  input and output as they are - piped input reaches it, and the client
  ends with the command's return code - or the files, with `sftp` and
  `scp` (below). No port forwarding.
- **What it speaks**: key exchange mlkem768x25519-sha256 - ML-KEM-768
  and X25519 together, which a quantum computer cannot undo, what OpenSSH
  10 asks for - or curve25519-sha256 for a client without it, each with
  OpenSSH's strict exchange; the host key ssh-ed25519, aes256-gcm or
  aes128-gcm, no compression.
- **The terminal's size**: what the client's window is, it tells, and
  tells again when the window changes; the console lists Tab's names as
  wide as it is.

### Files: sftp and scp

A client that asks for the `sftp` subsystem - `sftp`, and `scp`, which
speaks SFTP too - gets the files of every mounted volume, in one tree:

```
sftp -P 2222 claus@localhost       ; in QEMU, -Dssh=2222
sftp> ls /                          ; C  DEVS  DH0  ENV  LIBS  RAM  S  SYS ...
sftp> get /SYS/C/List
scp -P 2222 notes.txt claus@localhost:/RAM/
scp -r -P 2222 claus@localhost:/SYS/S saved-s
```

- **Names**: `/` holds the mounted file systems' devices and the
  assigns, each a directory; `/SYS/C/List` is `SYS:C/List`. A session
  starts in `/SYS`, so a name without a leading `/` is from there.
- **What it does**: read and write files anywhere in them, make and
  remove directories, rename, list with `ls -l`'s lines, and set a
  file's time and its read, write and execute bits (`chmod`). A new file
  gets the protection any new file gets, whatever the client's copy
  had, so a program brought from a PC stays runnable.
- **Times** are the clock's local time turned into UTC by the zone in
  `ENVARC:Sys/timezone`, and back.
- SFTP version 3, as OpenSSH speaks it; up to 16 files and directories
  open at once in a session. No links. A file past 2 GiB (exFAT) is read
  and written front to back, as `get` and `put` do; a jump within it
  past 2 GiB, or cutting it there, fails: dos.library's `Seek` and
  `SetFileSize` take 32-bit positions.

### The client: C:net/SSH

`C:net/SSH` is the other end: a shell, or one command, on another
machine - another PowerOS one, a PC, a server.

```
SSH KEYGEN                         ; once: the key for logins
SSH claus@server.example           ; a shell
SSH claus@10.0.0.5 PORT 2222 list SYS:   ; one command
```

- **The host key**: the first connection to a host shows its key's
  fingerprint and asks; `yes` keeps the key in
  `ENVARC:Sys/net/known_hosts`. From then on a host must show the same
  key, or the connection is refused - someone may be in between. When a
  host has been given a new key, take its line out of the file.
- **The login**: the key `ENVARC:Sys/net/id_ed25519` first, when there
  is one, then a password, asked for without its echo. `SSH KEYGEN` makes
  the key and prints its public line, also in `id_ed25519.pub`: the line
  goes into the other machine's `~/.ssh/authorized_keys` (or
  `ENVARC:Sys/net/authorized_keys` on a PowerOS one). The user is
  `user@host`, or `USER`, or the variable `USER`. A banner the server
  shows at the login comes first, as Latin-1 and without its control
  characters; the password is asked for only when the server takes one.
- **A shell** runs on a terminal of type xterm-256color the size of the
  console, which the console says when asked and keeps saying as its
  window changes; every key goes to the shell, Ctrl-C too. `~.` at the
  start of a line ends the connection.
- **A command** runs without a terminal: lines typed go to it, Ctrl-\
  ends its input, Ctrl-C the connection; input from a file goes to it as
  it is. The return code is the command's exit status.
- It speaks what ShellServer speaks: mlkem768x25519-sha256, or
  curve25519-sha256 with a server without it; ssh-ed25519 host keys;
  AES-GCM.

### Copying: C:net/SCP

`C:net/SCP FROM TO` copies a file, or with `ALL` a directory and all in
it, between this machine and another, over SFTP as `scp` does - to any
SSH server with the `sftp` subsystem, ShellServer SSH among them.

```
SCP claus@server.example:notes.txt RAM:      ; there to here
SCP SYS:S/Startup-Sequence claus@10.0.0.5:/tmp/
SCP RAM:photos claus@10.0.0.5:backup ALL PORT 2222
```

- **Which side is which**: `user@host:path` is the other machine's, and
  so is `host:path` when no device, volume or assign here is called
  `host`; an IPv6 address goes in brackets (`[fe80::1]:path`). The path
  there is from the home directory unless it starts at `/`; empty, it is
  the home directory. The other name is one here.
- **Where it goes**: to TO, or into TO under its own name when TO is a
  directory. A file there is replaced; each file copied is listed with
  its size, unless `QUIET`.
- **The connection** is as for `C:net/SSH`: the same host keys in
  `known_hosts`, the same key and password for the login, `PORT` and
  `USER` alike.
- Four reads or writes of 32 KiB are in flight at once, so the round
  trips overlap. Ctrl-C stops it; the return code is 10 when something
  could not be copied, 20 when there was no connection.

### The device

`DEVS:ssh.device` is the protocol (`sdk/devices/ssh.zig`), either end of
it. As with telnet.device, a unit is a connection, its number the id the
socket was released under, and the first command decides which end it
is. On the server's end, the first opener's `SSHCMD_ACCEPT` hands it the
host key and the logins and is answered once the client has logged in
and asked for its session - shell, command or subsystem, the user, the
terminal. Then a console opens the same unit and reads and writes the
session, and asks the terminal's size with serial.device's
`SDCMD_TERMSIZE` - or, for a subsystem, the opener speaks it on its own
request; `SSHCMD_EXIT` tells the client the exit status and closes the
channel.

On the client's end the steps are commands, each answered once the
server has answered it: `SSHCMD_CONNECT` (the key exchange; the host key
comes back, for the caller to judge before anything secret is sent),
`SSHCMD_LOGIN` (a key, a password, both, or neither to ask; `SSHERR_LOGIN`
with the ways the server still takes; the server's banner, if it sent
one), `SSHCMD_SESSION` (a shell, a command or a subsystem, with a
terminal or without). Then `CMD_READ` and `CMD_WRITE` carry the session,
`SSHCMD_WINDOW` tells a new size, `SSHCMD_EOF` ends the session's input,
and `SSHCMD_STATUS` is answered with the exit status once it is over.
When the connection goes first, a step's answer is `IOERR_ENDOFSTREAM`
with the reason in `io_Actual`.

A program on the client's end starts with `sdk/devices/ssh/connect.zig`,
as `C:net/SSH` and `C:net/SCP` do: its `Client` makes the connection,
checks the host key against `known_hosts`, asking the first time, and
logs in with the key or a password; the program then asks for its
session. `sdk/devices/ssh/sftp.zig` is SFTP's packets and attributes,
for either end.

In QEMU, `-Dssh=2222` forwards a host port to port 22 (qemu-display does
unless told otherwise): `ssh -p 2222 localhost`. The host is `10.0.2.2`
from inside: `SSH user@10.0.2.2` reaches the PC's own sshd.

## A packet filter

Every program that binds a socket listens on every interface: a shell
on port 23, Modbus on 502. A packet filter lets a port be open on one
interface and shut on another, or open to one subnet only, without a
program learning to check who it talks to. It is a library of its own,
`LIBS:filter.library`, loaded only when there are rules; the stack names
no filter and keeps no rules.

**Rules** are a file, `ENVARC:Sys/net/filter`, a line each, read top
down - the first rule that matches decides:

```
# '#' to the line's end is a comment
default in on wlan0 block
pass   in on wlan0 proto tcp from 192.168.1.0/24 to port 23
pass   in on wlan0 proto tcp from 192.168.1.50 to port 502
pass   in proto icmp type echo
refuse in on eth0 proto udp to port 161
```

- **The action**: `pass`; `block`, dropped and nothing said, so the
  sender waits and gives up; `refuse`, answered at once - a TCP reset,
  or a port unreachable for UDP (anything else is dropped). Then `in`:
  the rules are about what comes in.
- **The matches**, each at most once, in any order: `on <interface>`;
  `inet` or `inet6`; `proto tcp|udp|icmp|icmp6`; `from` and `to`, each
  an address with a prefix length (`10.0.0.0/8`, `fd00::/8`), a single
  address, `any`, or nothing, and maybe `port <n>` or `port <n>-<m>`;
  `type echo`, `type echo-reply` or `type <number>` for ICMP; `flags S`
  for a TCP segment that opens a connection. An IPv4 address matches
  IPv4 packets and an IPv6 one IPv6.
- **`default in on <interface> pass|block|refuse`** is what a packet on
  that interface gets when no rule matched; without `on`, every
  interface no other default names. An interface no default names is
  open, so a filter written for Wi-Fi leaves the cable alone.

**What passes before any rule**: a segment of a TCP connection the
stack has - one this machine opened, or one a rule let in - and an
answer to a UDP datagram or an echo this machine sent: its DNS, its
time server, its ping. A UDP exchange is kept 60 seconds after its last
packet, an echo 10. So `default in on wlan0 block` with a `pass` for
each port that should be reachable is a whole configuration: everything
this machine starts still works. **What always passes**, whatever the
rules say, so that no rule can cut an interface off: lo0, ARP, IGMP,
ICMP's errors (unreachable, time exceeded, parameter problem) and
ICMPv6's, Neighbor Discovery, MLD, and this machine's own DHCP and
DHCPv6.

**C:net/Filter** puts them in force: `Filter LOAD` reads the file (or
`FROM` another) and takes the old rules' place at once; a line it does
not understand loads nothing and is said with its line, column and word.
`Filter SHOW` lists the rules with how many packets each decided,
`Filter FLOWS` the exchanges whose answers pass, `Filter OFF` takes the
rules out. `S:Network-Startup` runs `Filter LOAD QUIET` before it brings
up an interface, when the file is there.

**Seeing it work**: the counts in `Filter SHOW`; `NetStatus COUNTS`, whose
`Hooks` line counts what was dropped and refused; and
`PacketCapture eth0 TO RAM:f.pcap FILTERED`, which keeps only what came
in and was stopped - which shows the rule that bites.

### Packet hooks

The filter is built on two calls of bsdsocket.library a program may use
for a filter or a logger of its own. `AddPacketHook(hook, tags)` puts a
utility.library Hook in a chain - `PH_Direction` `PH_IN` or `PH_OUT`,
`PH_Priority`, `PH_Interface` - and the hook is called with a
`PacketView` for every TCP segment, UDP datagram and ICMP message: the
interface, the family, the addresses (IPv4's mapped), the protocol, the
ports or the ICMP type, the TCP flags, the transport's bytes, and coming
in, what the stack found it is for (`PACKET_BELONGS_CONNECTION`,
`_LISTENER`, `_BOUND`, `_NONE`). It answers `PACKET_PASS`, `PACKET_DROP`
or `PACKET_REFUSE`; the first answer that is not a pass decides.

```zig
fn noTelnetFromWiFi(_: *utility.Hook, object: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
    const view: *const bsd.PacketView = @ptrCast(@alignCast(object.?));
    if (view.protocol == bsd.IPPROTO_TCP and view.destination_port == 23) return bsd.PACKET_REFUSE;
    return bsd.PACKET_PASS;
}

var hook: utility.Hook = .{ .entry = &noTelnetFromWiFi };
_ = sb.AddPacketHook(&hook, &[_]utility.TagItem{ .{ .tag = bsd.PH_Interface, .data = @intFromPtr("wlan0") }, .{} });
// ... and before the code goes:
sb.RemPacketHook(&hook);
```

A hook runs under the stack's lock, on whichever task holds it - the
stack's for what comes in, the sender's for what goes out - so it may
not wait, call bsdsocket.library or touch a file, and every packet
waits for it. RemPacketHook returns once it is not running. A hook goes
with the base that added it, unless `PH_Keep` keeps it until a
RemPacketHook from any base: how filter.library, which opens
bsdsocket.library only for the length of a call, keeps its hooks in.

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
| `C:net/Tcp`, `Udp` | a connection or a datagram by hand; `Udp JOIN` joins a group and prints what it hears |
| `C:net/PacketCapture` | an interface's frames into a pcap file; `FILTERED` only what the filter stopped |
| `C:net/Filter` | the packet filter's rules loaded (`LOAD`), shown with their counts (`SHOW`), its exchanges (`FLOWS`), taken out (`OFF`) |
| `C:net/ShellServer` | a shell for each connection to a TCP port: Telnet, or with `SSH` an SSH server, with sftp and scp for the files |
| `C:net/SSH` | a shell or a command on another machine over SSH; `KEYGEN` makes the key for logins |
| `C:net/SCP` | files to and from another machine over SSH (SFTP); `ALL` for a directory |
| `C:net/Net` | a network device spoken to directly |
| `C:test/BsdSockTest` | bsdsocket.library against the BSD socket API |
