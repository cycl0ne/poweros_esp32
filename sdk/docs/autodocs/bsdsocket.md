# bsdsocket.library

bsdsocket.library's functions: the TCP/IP stack's sockets. The base is
the opener's own, from OpenLibrary("bsdsocket.library", 1): its sockets,
its error number and its signals are its own and go with it when it
closes the library. A call that fails answers -1 and sets Errno().

Generated from the source by `./zig build autodoc`.

## Index

- [Bind](#bind) - The local address and port a socket takes datagrams on and sends from.
- [CloseSocket](#closesocket) - The socket closed and its descriptor free for the next Socket.
- [Connect](#connect) - The peer a datagram socket sends to by default, and the only one it takes datagrams from.
- [Errno](#errno) - The error number of the opener's last call that failed.
- [GetDTableSize](#getdtablesize) - How many sockets the opener may have open at once.
- [GetPeerName](#getpeername) - The address and port the socket is connected to.
- [GetSockName](#getsockname) - The address and port the socket is bound to.
- [GetSockOpt](#getsockopt) - One of the socket's options read into `value`.
- [Inet_Addr](#inet_addr) - Dotted text, "10.0.2.2", as an IPv4 address.
- [Inet_NtoA](#inet_ntoa) - An IPv4 address as dotted text, "10.0.2.15".
- [IoctlSocket](#ioctlsocket) - A socket's control requests.
- [Recv](#recv) - The next datagram waiting on the socket, into `buffer`.
- [RecvFrom](#recvfrom) - The next datagram waiting on the socket, into `buffer`, and the address it came from.
- [Send](#send) - A datagram of `length` bytes to the peer the socket is connected to.
- [SendTo](#sendto) - A datagram of `length` bytes sent to `to`, or to the peer the socket is connected to.
- [SetErrnoPtr](#seterrnoptr) - A variable of the program's that gets the error number of every call that fails, besides Errno().
- [SetSockOpt](#setsockopt) - One of the socket's options set.
- [Socket](#socket) - A new socket, and the descriptor the other calls know it by.
- [SocketBaseTagList](#socketbasetaglist) - The opener's settings, read and changed by a tag list.
- [WaitSelect](#waitselect) - Until a socket in the sets is ready, one of the caller's own signals comes, or the timeout passes.

## Bind

The local address and port a socket takes datagrams on and sends from.

**SYNOPSIS**

```zig
fn Bind(base: *SocketBase, socket: i32, address: *const sockaddr, address_length: u32) i32
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `socket` - a descriptor from Socket.
- `address` - a `sockaddr_in`: an address of this machine, or
  `INADDR_ANY` for all of them; a port, or 0 for one nobody has.
- `address_length` - its size, `@sizeOf(sockaddr_in)`.

**RESULT**

0, or -1 with Errno(): `EBADF`, `EINVAL` (already bound, or a short
address), `EAFNOSUPPORT`, `EADDRNOTAVAIL` (not an address of this
machine), `EADDRINUSE` (the port is taken on that address).

**BEHAVIOR**

A port is taken when another socket of the same type is bound to it on
the same address, or either of them is bound to `INADDR_ANY` - unless
both set `SO_REUSEADDR`. Port 0 picks the next free one from 49152 up.
A socket bound to one address takes only datagrams sent to it; one
bound to `INADDR_ANY` takes those to any of the machine's addresses and
its broadcasts.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

`address` is read and not kept.

**NOTES**

GetSockName tells which port 0 picked.

**BUGS**

None known.

**SEE ALSO**

`Socket`, `Connect`, `GetSockName`, `SetSockOpt`

**EXAMPLES**

```zig
var here: bsd.sockaddr_in = .{ .sin_port = bsd.htons(7) };
if (sb.Bind(socket, here.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) return sb.Errno();
```

## CloseSocket

The socket closed and its descriptor free for the next Socket.

**SYNOPSIS**

```zig
fn CloseSocket(base: *SocketBase, socket: i32) i32
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `socket` - a descriptor from Socket.

**RESULT**

0, or -1 with Errno() `EBADF`.

**BEHAVIOR**

The datagrams still waiting on it are dropped, and its port is free
again. A call of another task waiting on the socket finds it gone and
answers `EBADF`.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

The socket is gone; the descriptor may name a new one after the next
Socket.

**NOTES**

Closing the library closes every socket still open.

**BUGS**

None known.

**SEE ALSO**

`Socket`

**EXAMPLES**

```zig
defer _ = sb.CloseSocket(socket);
```

## Connect

The peer a datagram socket sends to by default, and the only one it takes datagrams from.

**SYNOPSIS**

```zig
fn Connect(base: *SocketBase, socket: i32, address: *const sockaddr, address_length: u32) i32
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `socket` - a descriptor from Socket.
- `address` - the peer, a `sockaddr_in`; one whose family is
  `AF_UNSPEC` undoes the connection.
- `address_length` - its size.

**RESULT**

0, or -1 with Errno(): `EBADF`, `EINVAL`, `EAFNOSUPPORT`,
`EADDRNOTAVAIL` (no port of its own could be had).

**BEHAVIOR**

Nothing is sent: a datagram socket only remembers the peer. From then
on Send needs no address, SendTo refuses one (`EISCONN`), and
datagrams from anyone else are left to other sockets or dropped. A
socket not yet bound is bound to a port of its own. Connecting again
replaces the peer.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

`address` is read and not kept.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`Send`, `Recv`, `GetPeerName`, `Bind`

**EXAMPLES**

```zig
var peer: bsd.sockaddr_in = .{ .sin_port = bsd.htons(7), .sin_addr = .{ .s_addr = sb.Inet_Addr("10.0.2.2") } };
if (sb.Connect(socket, peer.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) return sb.Errno();
```

## Errno

The error number of the opener's last call that failed.

**SYNOPSIS**

```zig
fn Errno(base: *SocketBase) i32
```

**SINCE**

1.0. LVO -80.

**INPUTS**

None.

**RESULT**

An `E*` value of sdk.bsdsocket, or 0 if no call has failed yet.

**BEHAVIOR**

A call that succeeds leaves it as it was.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

SetErrnoPtr has it written to a variable of the program's as well.

**BUGS**

None known.

**SEE ALSO**

`SetErrnoPtr`, `SocketBaseTagList`

**EXAMPLES**

```zig
if (sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0) < 0 and sb.Errno() == bsd.EMFILE) return;
```

## GetDTableSize

How many sockets the opener may have open at once.

**SYNOPSIS**

```zig
fn GetDTableSize(base: *SocketBase) i32
```

**SINCE**

1.0. LVO -76.

**INPUTS**

None.

**RESULT**

The size of the descriptor table: 64, unless SocketBaseTagList's
`SBTC_DTABLESIZE` changed it.

**BEHAVIOR**

Descriptors run from 0 to one less than this.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`SocketBaseTagList`, `Socket`

**EXAMPLES**

```zig
const most = sb.GetDTableSize();
```

## GetPeerName

The address and port the socket is connected to.

**SYNOPSIS**

```zig
fn GetPeerName(base: *SocketBase, socket: i32, address: *sockaddr, address_length: *u32) i32
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `socket` - a descriptor from Socket.
- `address` - where the `sockaddr_in` goes.
- `address_length` - in, the room at `address`; out,
  `@sizeOf(sockaddr_in)`.

**RESULT**

0, or -1 with Errno(): `EBADF`, `ENOTCONN` (the socket is not
connected).

**BEHAVIOR**

As much of the address is written as there is room for.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`GetSockName`, `Connect`

**EXAMPLES**

```zig
var peer: bsd.sockaddr_in = .{};
var size: u32 = @sizeOf(bsd.sockaddr_in);
if (sb.GetPeerName(socket, peer.any(), &size) < 0) return sb.Errno();
```

## GetSockName

The address and port the socket is bound to.

**SYNOPSIS**

```zig
fn GetSockName(base: *SocketBase, socket: i32, address: *sockaddr, address_length: *u32) i32
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `socket` - a descriptor from Socket.
- `address` - where the `sockaddr_in` goes.
- `address_length` - in, the room at `address`; out,
  `@sizeOf(sockaddr_in)`.

**RESULT**

0, or -1 with Errno() `EBADF`.

**BEHAVIOR**

A socket not bound yet answers `INADDR_ANY` and port 0. As much of the
address is written as there is room for.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

How to learn the port Bind picked for port 0.

**BUGS**

None known.

**SEE ALSO**

`GetPeerName`, `Bind`

**EXAMPLES**

```zig
var here: bsd.sockaddr_in = .{};
var size: u32 = @sizeOf(bsd.sockaddr_in);
_ = sb.GetSockName(socket, here.any(), &size);
const port = bsd.ntohs(here.sin_port);
```

## GetSockOpt

One of the socket's options read into `value`.

**SYNOPSIS**

```zig
fn GetSockOpt(base: *SocketBase, socket: i32, level: i32, option: i32, value: *anyopaque, value_length: *u32) i32
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `socket` - a descriptor from Socket.
- `level` - `SOL_SOCKET`.
- `option` - any SetSockOpt takes, and `SO_ERROR` (the socket's
  pending error, which reading clears) and `SO_TYPE` (its SOCK_*), each
  an i32.
- `value` - where the value goes.
- `value_length` - in, the room at `value`; out, the value's size.

**RESULT**

0, or -1 with Errno(): `EBADF`, `ENOPROTOOPT`, `EINVAL` (too little
room).

**BEHAVIOR**

The flags answer 1 or 0.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`SetSockOpt`

**EXAMPLES**

```zig
var pending: i32 = 0;
var size: u32 = @sizeOf(i32);
_ = sb.GetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_ERROR, &pending, &size);
```

## Inet_Addr

Dotted text, "10.0.2.2", as an IPv4 address.

**SYNOPSIS**

```zig
fn Inet_Addr(base: *SocketBase, text: [*:0]const u8) u32
```

**SINCE**

1.0. LVO -92.

**INPUTS**

- `text` - four numbers from 0 to 255 with dots between.

**RESULT**

The address in network order, as `in_addr.s_addr` holds it, or
`INADDR_NONE` when the text is no address.

**BEHAVIOR**

Only the four-part decimal form is taken.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

"255.255.255.255" is a real address and answers the same as text that
is none.

**BUGS**

None known.

**SEE ALSO**

`Inet_NtoA`

**EXAMPLES**

```zig
var to: bsd.sockaddr_in = .{ .sin_port = bsd.htons(7), .sin_addr = .{ .s_addr = sb.Inet_Addr("10.0.2.2") } };
```

## Inet_NtoA

An IPv4 address as dotted text, "10.0.2.15".

**SYNOPSIS**

```zig
fn Inet_NtoA(base: *SocketBase, address: u32) [*:0]const u8
```

**SINCE**

1.0. LVO -88.

**INPUTS**

- `address` - in network order, as `in_addr.s_addr` holds it.

**RESULT**

The text, in a buffer of the opener's base.

**BEHAVIOR**

Four numbers from 0 to 255, with dots between.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The buffer is the base's: the next Inet_NtoA overwrites it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`Inet_Addr`

**EXAMPLES**

```zig
_ = Printf(dl, "from %s\n", .{sb.Inet_NtoA(from.sin_addr.s_addr)});
```

## IoctlSocket

A socket's control requests.

**SYNOPSIS**

```zig
fn IoctlSocket(base: *SocketBase, socket: i32, request: u32, argument: *anyopaque) i32
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `socket` - a descriptor from Socket.
- `request` - `FIONBIO`: `argument` is an i32, not 0 for a socket
  whose calls never wait, 0 for one that does; `FIONREAD`: `argument`
  is an u32 that gets the bytes of the next datagram, 0 if none.
- `argument` - as the request says.

**RESULT**

0, or -1 with Errno(): `EBADF`, `EINVAL` (a request there is not).

**BEHAVIOR**

A socket that does not wait answers `EWOULDBLOCK` where it would have
waited.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

FIONREAD counts the next datagram, which is what one RecvFrom takes.

**BUGS**

None known.

**SEE ALSO**

`SetSockOpt`, `RecvFrom`, `WaitSelect`

**EXAMPLES**

```zig
var never: i32 = 1;
_ = sb.IoctlSocket(socket, bsd.FIONBIO, &never);
```

## Recv

The next datagram waiting on the socket, into `buffer`.

**SYNOPSIS**

```zig
fn Recv(base: *SocketBase, socket: i32, buffer: *anyopaque, length: u32, flags: u32) i32
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `socket` - a datagram socket.
- `buffer` - where the data goes.
- `length` - its size.
- `flags` - as RecvFrom takes them.

**RESULT**

The bytes put in `buffer`, or -1 with Errno(), as RecvFrom.

**BEHAVIOR**

RecvFrom without the sender's address.

**CONTEXT**

- Waits: yes, unless the socket does not wait.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; the one that opened the base.

**OWNERSHIP**

As RecvFrom.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`RecvFrom`, `Send`, `Connect`

**EXAMPLES**

```zig
var buffer: [512]u8 = undefined;
const got = sb.Recv(socket, &buffer, buffer.len, 0);
```

## RecvFrom

The next datagram waiting on the socket, into `buffer`, and the address it came from.

**SYNOPSIS**

```zig
fn RecvFrom(base: *SocketBase, socket: i32, buffer: *anyopaque, length: u32, flags: u32,
    from: ?*sockaddr, from_length: ?*u32) i32
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `socket` - a datagram socket.
- `buffer` - where the data goes.
- `length` - its size.
- `flags` - `MSG_PEEK` leaves the datagram to be read again;
  `MSG_DONTWAIT` does not wait for this one call.
- `from` - where the sender's `sockaddr_in` goes, or null.
- `from_length` - in, the room at `from`; out, the address's size. Null
  when `from` is.

**RESULT**

The bytes put in `buffer`, or -1 with Errno(): `EBADF`, `EWOULDBLOCK`
(nothing waiting and the socket does not wait, or `SO_RCVTIMEO`
passed), `EINTR` (a break signal came), or an error the network
reported for the socket.

**BEHAVIOR**

A datagram is read whole or not at all: what does not fit in `buffer`
is lost. With nothing waiting, the call waits - without holding the
stack - until a datagram comes, one of the opener's break signals
(SIGBREAKF_CTRL_C unless SocketBaseTagList changed them) comes, or
`SO_RCVTIMEO` passes. A break signal is taken.

**CONTEXT**

- Waits: yes, unless the socket does not wait.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; it must be the one that opened the base,
  whose signals the wait is on.

**OWNERSHIP**

The datagram is copied into `buffer` and its frame given back.

**NOTES**

FIONREAD tells the size of the next datagram before it is read.

**BUGS**

None known.

**SEE ALSO**

`Recv`, `SendTo`, `WaitSelect`, `IoctlSocket`

**EXAMPLES**

```zig
var buffer: [512]u8 = undefined;
var from: bsd.sockaddr_in = .{};
var from_length: u32 = @sizeOf(bsd.sockaddr_in);
const got = sb.RecvFrom(socket, &buffer, buffer.len, 0, from.any(), &from_length);
```

## Send

A datagram of `length` bytes to the peer the socket is connected to.

**SYNOPSIS**

```zig
fn Send(base: *SocketBase, socket: i32, message: *const anyopaque, length: u32, flags: u32) i32
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `socket` - a connected datagram socket.
- `message` - the data.
- `length` - its bytes.
- `flags` - as SendTo takes them.

**RESULT**

`length`, or -1 with Errno(): as SendTo, and `EDESTADDRREQ` when the
socket is not connected.

**BEHAVIOR**

SendTo without an address.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

`message` is copied.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`SendTo`, `Connect`, `Recv`

**EXAMPLES**

```zig
_ = sb.Send(socket, "ping", 4, 0);
```

## SendTo

A datagram of `length` bytes sent to `to`, or to the peer the socket is connected to.

**SYNOPSIS**

```zig
fn SendTo(base: *SocketBase, socket: i32, message: *const anyopaque, length: u32, flags: u32,
    to: ?*const sockaddr, to_length: u32) i32
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `socket` - a datagram socket.
- `message` - the data.
- `length` - its bytes; 0 sends an empty datagram.
- `flags` - 0; `MSG_DONTWAIT` is taken and changes nothing, since a
  datagram is sent or refused at once.
- `to` - a `sockaddr_in`, or null on a connected socket.
- `to_length` - its size.

**RESULT**

`length`, or -1 with Errno(): `EBADF`, `EDESTADDRREQ` (no address and
not connected), `EISCONN` (an address on a connected socket),
`EAFNOSUPPORT`, `EINVAL`, `EMSGSIZE` (more than the interface takes),
`ENETUNREACH` (no route), `EACCES` (a broadcast without
`SO_BROADCAST`), `ENOBUFS` (no frame free), or an error the network
reported for an earlier datagram of this socket.

**BEHAVIOR**

The datagram is copied into a frame, given its UDP and IPv4 headers,
and handed to the interface the route for its address picks, all
before the call returns: a datagram to the machine itself is already
in its receiver's queue by then. A socket that is not bound is bound
to a port of its own first. Nothing is fragmented: a datagram larger
than the interface's MTU less 28 bytes of headers is refused.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

`message` is copied; it is the caller's again when this returns.

**NOTES**

"Sent" means handed to the interface. UDP has no acknowledgement, and
a datagram may still be lost on the way.

**BUGS**

None known.

**SEE ALSO**

`Send`, `RecvFrom`, `Connect`, `SetSockOpt`

**EXAMPLES**

```zig
var to: bsd.sockaddr_in = .{ .sin_port = bsd.htons(7), .sin_addr = .{ .s_addr = sb.Inet_Addr("127.0.0.1") } };
const text = "hello";
_ = sb.SendTo(socket, text, text.len, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in));
```

## SetErrnoPtr

A variable of the program's that gets the error number of every call that fails, besides Errno().

**SYNOPSIS**

```zig
fn SetErrnoPtr(base: *SocketBase, errno_pointer: ?*anyopaque, size: u32) void
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `errno_pointer` - the variable, or null for none.
- `size` - its bytes: 1, 2 or 4.

**RESULT**

Nothing.

**BEHAVIOR**

Another size, or null, stops the writing.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The variable must stay while the base is open, or until it is changed.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`Errno`, `SocketBaseTagList`

**EXAMPLES**

```zig
var errno: i32 = 0;
sb.SetErrnoPtr(&errno, @sizeOf(i32));
```

## SetSockOpt

One of the socket's options set.

**SYNOPSIS**

```zig
fn SetSockOpt(base: *SocketBase, socket: i32, level: i32, option: i32, value: *const anyopaque, value_length: u32) i32
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `socket` - a descriptor from Socket.
- `level` - `SOL_SOCKET`.
- `option` - `SO_REUSEADDR`, `SO_BROADCAST` (an i32, not 0 for on),
  `SO_RCVBUF`, `SO_SNDBUF` (an i32 of bytes), `SO_RCVTIMEO`,
  `SO_SNDTIMEO` (a timeval; zero waits for ever).
- `value` - the option's value.
- `value_length` - its size.

**RESULT**

0, or -1 with Errno(): `EBADF`, `ENOPROTOOPT` (another level or an
option there is not, or one that can only be read), `EINVAL` (a value
of the wrong size).

**BEHAVIOR**

`SO_RCVBUF` is how many bytes of datagrams wait on the socket before
the next is dropped; it is held to between 1 byte and 256 KiB.
`SO_REUSEADDR` must be set before Bind to count. `SO_SNDTIMEO` is kept
and changes nothing for a datagram socket, which never waits to send.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

`value` is read and not kept.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`GetSockOpt`, `IoctlSocket`

**EXAMPLES**

```zig
const on: i32 = 1;
_ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_BROADCAST, &on, @sizeOf(i32));
```

## Socket

A new socket, and the descriptor the other calls know it by.

**SYNOPSIS**

```zig
fn Socket(base: *SocketBase, domain: i32, socket_type: i32, protocol: i32) i32
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `domain` - `PF_INET`, the only family there is.
- `socket_type` - `SOCK_DGRAM`: datagrams, UDP.
- `protocol` - 0 or `IPPROTO_UDP`.

**RESULT**

The descriptor, from 0 up, or -1 with Errno(): `EAFNOSUPPORT` for
another domain, `ESOCKTNOSUPPORT` for another type, `EPROTONOSUPPORT`
for another protocol, `EMFILE` when the descriptor table is full,
`ENOMEM`.

**BEHAVIOR**

The socket takes the lowest free descriptor. It is bound to nothing
and connected to nothing; the first datagram it sends binds it to a
port of its own, or Bind chooses one first. It waits in its calls
unless FIONBIO says otherwise.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do; it must be the one that opened the base.

**OWNERSHIP**

The socket is the opener's until CloseSocket, or until it closes the
library, which closes every socket still open.

**NOTES**

Stream sockets (TCP) and raw sockets come with the protocols that
serve them.

**BUGS**

None known.

**SEE ALSO**

`CloseSocket`, `Bind`, `SendTo`, `RecvFrom`

**EXAMPLES**

```zig
const sb: *SocketBase = @ptrCast(sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return);
defer sys.CloseLibrary(sb.lib());
const socket = sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
if (socket < 0) return sb.Errno();
```

## SocketBaseTagList

The opener's settings, read and changed by a tag list.

**SYNOPSIS**

```zig
fn SocketBaseTagList(base: *SocketBase, tags: ?[*]const TagItem) i32
```

**SINCE**

1.0. LVO -96.

**INPUTS**

- `tags` - each tag `SBTM_SETVAL(code)` with the value in ti_Data, or
  `SBTM_GETREF(code)` with a pointer to an u32 in ti_Data that gets the
  value. The codes:
  - `SBTC_BREAKMASK` - the signals that break a wait with `EINTR`;
  - `SBTC_SIGEVENTMASK` - the signal socket events are told with;
  - `SBTC_ERRNO` - the error number;
  - `SBTC_DTABLESIZE` - the size of the descriptor table, from 1 to
    `FD_SETSIZE`; set only while no socket is open;
  - `SBTC_LOGSTAT` - not 0 to have every call that fails logged, with
    its errno, on the serial line.

**RESULT**

0 when every tag was taken, else the position of the first that was
not, from 1; the tags before it were taken.

**BEHAVIOR**

The tags are taken in order, through utility.library, so TAG_MORE and
the other system tags work as anywhere.

**CONTEXT**

- Waits: only for the stack's lock.
- Interrupts: no.
- Forbid: not held.
- Process: a Task will do.

**OWNERSHIP**

The tag list is read and not kept.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`Errno`, `WaitSelect`, `GetDTableSize`

**EXAMPLES**

```zig
const tags = [_]TagItem{
    .{ .tag = bsd.SBTM_SETVAL(bsd.SBTC_BREAKMASK), .data = exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_D },
    .{},
};
_ = sb.SocketBaseTagList(&tags);
```

## WaitSelect

Until a socket in the sets is ready, one of the caller's own signals comes, or the timeout passes.

**SYNOPSIS**

```zig
fn WaitSelect(base: *SocketBase, count: i32, read: ?*fd_set, write: ?*fd_set, except: ?*fd_set,
    timeout: ?*TimeVal, signals: ?*u32) i32
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `count` - one more than the highest descriptor in any set.
- `read` - the sockets to wait for until a receive would not wait, or
  null.
- `write` - until a send would not wait, or null.
- `except` - until something exceptional comes, or null.
- `timeout` - how long to wait at most; zero only looks; null waits
  for ever.
- `signals` - in, the caller's own signals that end the wait too; out,
  the ones of them that came. Null for none.

**RESULT**

How many sockets are ready - the sets then hold only those - or 0
when the timeout passed or one of `signals` came - the sets are then
empty - or -1 with Errno(): `EBADF` (a descriptor in a set that is no
socket), `EINVAL` (`count` below 0 or past the table), `EINTR` (a break
signal came, and was taken).

**BEHAVIOR**

A datagram socket is always ready to send, and ready to receive once a
datagram or an error waits on it. Nothing is exceptional for a
datagram socket, so `except` only ever comes back empty. The wait is on
the opener's readiness signal, the break signals, the timer and
`*signals` together, and the sets are looked at afresh after each: the
program waits on its sockets and on its windows' ports in one call.

**CONTEXT**

- Waits: yes, unless something is ready or the timeout is zero.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; the one that opened the base.

**OWNERSHIP**

The sets are the caller's; they are overwritten with the answer.

**NOTES**

The signals in `*signals` that came are taken, as Wait takes them.

**BUGS**

None known.

**SEE ALSO**

`RecvFrom`, `IoctlSocket`, exec's `Wait`

**EXAMPLES**

```zig
var read: bsd.fd_set = .{};
read.set(socket);
var signals: u32 = window_port.sigMask();
var patience: bsd.timeval = .{ .secs = 2 };
const ready = sb.WaitSelect(socket + 1, &read, null, null, &patience, &signals);
```
