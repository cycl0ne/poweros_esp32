// SPDX-License-Identifier: MIT
//! bsdsocket.library's structures and constants: socket addresses, the
//! descriptor sets WaitSelect takes, the options, the error numbers, and
//! the tags an opener sets itself up with. The calls are in
//! `sdk.interface.bsdsocket`, on the base OpenLibrary answers, which is
//! the opener's own: its sockets, its error number and its signals.
//!
//! Addresses and ports inside a `sockaddr_in` are in network byte order,
//! most significant byte first, as they travel; `htons`, `htonl` and their
//! reverses turn the chip's own order into it and back. The `INADDR_*`
//! values below are in the chip's order, as numbers to compare with.

const TimeVal = @import("../../devices/timer.zig").TimeVal;
const TAG_USER = @import("../utility/tagitem.zig").TAG_USER;
const TagItem = @import("../utility/tagitem.zig").TagItem;

/// The library's name, for OpenLibrary.
pub const SOCKETNAME = "bsdsocket.library";

// --- byte order -------------------------------------------------------------

/// A 16-bit value between the chip's order and the network's; the same
/// swap goes both ways.
pub inline fn htons(value: u16) u16 {
    return @byteSwap(value);
}
pub inline fn ntohs(value: u16) u16 {
    return @byteSwap(value);
}
/// A 32-bit value between the chip's order and the network's.
pub inline fn htonl(value: u32) u32 {
    return @byteSwap(value);
}
pub inline fn ntohl(value: u32) u32 {
    return @byteSwap(value);
}

// --- addresses --------------------------------------------------------------

/// Address families.
pub const AF_UNSPEC: u8 = 0;
/// PF_UNSPEC: any family, where a call takes it (ObtainSocket).
pub const PF_UNSPEC: i32 = AF_UNSPEC;
pub const AF_INET: u8 = 2;
pub const PF_INET: i32 = AF_INET;
pub const AF_INET6: u8 = 28;
pub const PF_INET6: i32 = AF_INET6;
/// Frames as an interface sends and takes them, for a capture socket
/// (`Socket(PF_PACKET, SOCK_RAW, 0)`): see CaptureHeader.
pub const AF_PACKET: u8 = 17;
pub const PF_PACKET: i32 = AF_PACKET;

/// struct in_addr: an IPv4 address, in network order.
pub const in_addr = extern struct {
    s_addr: u32 = 0,
};

/// struct sockaddr: any family's address. The calls take a pointer to
/// one and its length, and read it as the family says.
pub const sockaddr = extern struct {
    /// sa_len: the bytes of the whole address.
    sa_len: u8 = 0,
    /// sa_family: AF_*.
    sa_family: u8 = 0,
    sa_data: [14]u8 = @splat(0),
};

/// struct sockaddr_in: an IPv4 address and a port.
pub const sockaddr_in = extern struct {
    /// sin_len: @sizeOf(sockaddr_in).
    sin_len: u8 = @sizeOf(sockaddr_in),
    /// sin_family: AF_INET.
    sin_family: u8 = AF_INET,
    /// sin_port: in network order.
    sin_port: u16 = 0,
    sin_addr: in_addr = .{},
    sin_zero: [8]u8 = @splat(0),

    /// As the calls take it.
    pub fn any(address: *sockaddr_in) *sockaddr {
        return @ptrCast(address);
    }
    pub fn anyConst(address: *const sockaddr_in) *const sockaddr {
        return @ptrCast(address);
    }
};

/// struct in6_addr: an IPv6 address, its sixteen bytes in network order.
pub const in6_addr = extern struct {
    s6_addr: [16]u8 = @splat(0),
};

/// struct sockaddr_in6: an IPv6 address, a port, the flow label and, for
/// a link-local address, the interface it is on.
pub const sockaddr_in6 = extern struct {
    /// sin6_len: @sizeOf(sockaddr_in6).
    sin6_len: u8 = @sizeOf(sockaddr_in6),
    /// sin6_family: AF_INET6.
    sin6_family: u8 = AF_INET6,
    /// sin6_port: in network order.
    sin6_port: u16 = 0,
    /// sin6_flowinfo: the flow label, in network order; 0.
    sin6_flowinfo: u32 = 0,
    sin6_addr: in6_addr = .{},
    /// sin6_scope_id: which interface a link-local address is on - its
    /// index, as `If_NameToIndex` answers it; 0 for any other address.
    sin6_scope_id: u32 = 0,

    /// As the calls take it.
    pub fn any(address: *sockaddr_in6) *sockaddr {
        return @ptrCast(address);
    }
    pub fn anyConst(address: *const sockaddr_in6) *const sockaddr {
        return @ptrCast(address);
    }
};

/// struct sockaddr_storage: room for any family's address, for a caller
/// that does not know the family yet (RecvFrom, Accept).
pub const sockaddr_storage = extern struct {
    ss_len: u8 = @sizeOf(sockaddr_storage),
    ss_family: u8 = AF_UNSPEC,
    ss_pad: [126]u8 = @splat(0),

    pub fn any(address: *sockaddr_storage) *sockaddr {
        return @ptrCast(address);
    }
};

comptime {
    if (@sizeOf(sockaddr_in6) != 28) @compileError("sockaddr_in6 is 28 bytes");
    if (@sizeOf(sockaddr_storage) != 128) @compileError("sockaddr_storage is 128 bytes");
}

/// IPv6 addresses with a meaning of their own: none (bind to every
/// address of the machine) and the loopback, ::1.
pub const in6addr_any: in6_addr = .{};
pub const in6addr_loopback: in6_addr = .{ .s6_addr = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };

/// The longest text Inet_NtoP writes for each family, its NUL included.
pub const INET_ADDRSTRLEN: u32 = 16;
pub const INET6_ADDRSTRLEN: u32 = 46;

/// Addresses with a meaning of their own, in the chip's order.
pub const INADDR_ANY: u32 = 0x0000_0000;
pub const INADDR_LOOPBACK: u32 = 0x7F00_0001;
pub const INADDR_BROADCAST: u32 = 0xFFFF_FFFF;
/// What Inet_Addr answers for text that is no address.
pub const INADDR_NONE: u32 = 0xFFFF_FFFF;

// --- sockets ----------------------------------------------------------------

/// Socket types.
pub const SOCK_STREAM: i32 = 1;
pub const SOCK_DGRAM: i32 = 2;
pub const SOCK_RAW: i32 = 3;

/// Protocols.
pub const IPPROTO_IP: i32 = 0;
pub const IPPROTO_ICMP: i32 = 1;
pub const IPPROTO_IGMP: i32 = 2;
pub const IPPROTO_TCP: i32 = 6;
pub const IPPROTO_UDP: i32 = 17;
/// IPv6's own: its options' level, ICMPv6, and "no next header".
pub const IPPROTO_IPV6: i32 = 41;
pub const IPPROTO_ICMPV6: i32 = 58;
pub const IPPROTO_NONE: i32 = 59;

/// IPPROTO_IP's options, on a socket that speaks IPv4. The interface a
/// datagram to a group goes out of (an in_addr, its address;
/// INADDR_ANY for the route's), its time to live (1 unless set), and
/// whether this machine's own members of the group get a copy (1 unless
/// 0) - the last two a u8 or an i32.
pub const IP_MULTICAST_IF: i32 = 9;
pub const IP_MULTICAST_TTL: i32 = 10;
pub const IP_MULTICAST_LOOP: i32 = 11;
/// A group joined, or left, on an interface: an ip_mreq.
pub const IP_ADD_MEMBERSHIP: i32 = 12;
pub const IP_DROP_MEMBERSHIP: i32 = 13;

/// struct ip_mreq: a group, and the interface to be in it on (its
/// address; INADDR_ANY for the one a packet to the group would go out
/// of), both in network order.
pub const ip_mreq = extern struct {
    imr_multiaddr: in_addr = .{},
    imr_interface: in_addr = .{},
};

/// IPPROTO_IPV6's options. Each takes an i32.
/// The hop limit of unicast packets the socket sends; -1: the interface's.
pub const IPV6_UNICAST_HOPS: i32 = 4;
/// The interface a datagram to a group goes out of (a u32 index, 0 for
/// the route's), its hop limit (an i32, -1 for 1), and whether this
/// machine's own members of the group get a copy (an i32, 1 unless 0).
pub const IPV6_MULTICAST_IF: i32 = 9;
pub const IPV6_MULTICAST_HOPS: i32 = 10;
pub const IPV6_MULTICAST_LOOP: i32 = 11;
/// A group joined, or left, on an interface: an ipv6_mreq.
pub const IPV6_JOIN_GROUP: i32 = 12;
pub const IPV6_LEAVE_GROUP: i32 = 13;

/// struct ipv6_mreq: a group, and the interface to be in it on (its
/// index, If_NameToIndex's; 0 for the one a packet to the group would
/// go out of).
pub const ipv6_mreq = extern struct {
    ipv6mr_multiaddr: in6_addr = .{},
    ipv6mr_interface: u32 = 0,
};
/// An AF_INET6 socket that takes IPv6 only; 0 lets it take IPv4 as
/// mapped addresses (::ffff:a.b.c.d) as well, the default.
pub const IPV6_V6ONLY: i32 = 27;
/// An i32, not 0: RecvMsg says the hop limit each IPv6 datagram came
/// with, as an IPV6_HOPLIMIT control message (an i32).
pub const IPV6_RECVHOPLIMIT: i32 = 37;
pub const IPV6_HOPLIMIT: i32 = 47;

/// Flags of the send and receive calls: urgent data on a stream socket
/// (out of band), look at what is there without taking it, and do not
/// wait for this one call.
pub const MSG_OOB: u32 = 0x1;
pub const MSG_PEEK: u32 = 0x2;
pub const MSG_DONTWAIT: u32 = 0x80;
/// RecvMsg's `msg_flags`: the datagram was longer than the buffers, and
/// what was cut off is lost; the control messages did not all fit.
pub const MSG_TRUNC: u32 = 0x10;
pub const MSG_CTRUNC: u32 = 0x20;

/// struct iovec: one buffer of several a datagram is read into.
pub const iovec = extern struct {
    iov_base: ?*anyopaque = null,
    iov_len: u32 = 0,
};

/// struct msghdr: what RecvMsg reads into - where the sender's address
/// goes, the buffers the data is spread over in turn, and the room for
/// control messages - and what it says of the datagram (`msg_flags`).
pub const msghdr = extern struct {
    /// A sockaddr for the sender, or null; in, its room, out, its size.
    msg_name: ?*anyopaque = null,
    msg_namelen: u32 = 0,
    msg_iov: ?[*]iovec = null,
    msg_iovlen: u32 = 0,
    /// Room for control messages (cmsghdr, each followed by its data), or
    /// null; in, its size, out, how much of it was filled.
    msg_control: ?*anyopaque = null,
    msg_controllen: u32 = 0,
    /// MSG_TRUNC, MSG_CTRUNC.
    msg_flags: u32 = 0,
};

/// struct cmsghdr: a control message's header - its length, the header
/// counted, and its level and type (IPPROTO_IPV6, IPV6_HOPLIMIT) - with
/// its data behind it at `cmsgData`.
pub const cmsghdr = extern struct {
    cmsg_len: u32 = 0,
    cmsg_level: i32 = 0,
    cmsg_type: i32 = 0,
};

/// A length rounded up to where the next control message may start.
pub fn cmsgAlign(length: u32) u32 {
    return (length + 3) & ~@as(u32, 3);
}

/// CMSG_LEN: a control message's `cmsg_len` for `data_length` bytes of
/// data; CMSG_SPACE: the room it takes, padding included.
pub fn cmsgLen(data_length: u32) u32 {
    return cmsgAlign(@sizeOf(cmsghdr)) + data_length;
}
pub fn cmsgSpace(data_length: u32) u32 {
    return cmsgAlign(@sizeOf(cmsghdr)) + cmsgAlign(data_length);
}

/// CMSG_FIRSTHDR: the first control message RecvMsg wrote, or null.
pub fn cmsgFirst(message: *const msghdr) ?*cmsghdr {
    if (message.msg_controllen < @sizeOf(cmsghdr)) return null;
    return @ptrCast(@alignCast(message.msg_control orelse return null));
}

/// CMSG_NXTHDR: the control message after `current`, or null.
pub fn cmsgNext(message: *const msghdr, current: *const cmsghdr) ?*cmsghdr {
    const start = @intFromPtr(message.msg_control orelse return null);
    const next = @intFromPtr(current) + cmsgAlign(current.cmsg_len);
    if (next + @sizeOf(cmsghdr) > start + message.msg_controllen) return null;
    return @ptrFromInt(next);
}

/// CMSG_DATA: where a control message's data starts.
pub fn cmsgData(current: *cmsghdr) [*]u8 {
    return @as([*]u8, @ptrCast(current)) + cmsgAlign(@sizeOf(cmsghdr));
}

/// SetSockOpt's and GetSockOpt's level for the socket's own options.
pub const SOL_SOCKET: i32 = 0xFFFF;

/// The socket's options. Each takes an i32 unless it says otherwise.
pub const SO_REUSEADDR: i32 = 0x0004;
/// A stream socket probes a connection that has been idle for long.
pub const SO_KEEPALIVE: i32 = 0x0008;
pub const SO_BROADCAST: i32 = 0x0020;
/// What CloseSocket does with data not yet sent: a `linger`.
pub const SO_LINGER: i32 = 0x0080;
/// The bytes a socket buffers for sending and receiving: a stream
/// socket's rings, or the memory the frames of a datagram socket's
/// waiting datagrams hold.
pub const SO_SNDBUF: i32 = 0x1001;
pub const SO_RCVBUF: i32 = 0x1002;
/// How long a send or a receive may wait: a TimeVal; zero waits for ever.
pub const SO_SNDTIMEO: i32 = 0x1005;
pub const SO_RCVTIMEO: i32 = 0x1006;
/// The socket's pending error, taken as it is read (get only).
pub const SO_ERROR: i32 = 0x1007;
/// The socket's type, SOCK_* (get only).
pub const SO_TYPE: i32 = 0x1008;
/// The events (FD_*) the socket tells of with the opener's event signal
/// (SBTC_SIGEVENTMASK), for GetSocketEvents.
pub const SO_EVENTMASK: i32 = 0x2001;

/// Socket events: something to read, room to write, an error.
pub const FD_ACCEPT: u32 = 0x01;
pub const FD_CONNECT: u32 = 0x02;
pub const FD_OOB: u32 = 0x04;
pub const FD_READ: u32 = 0x08;
pub const FD_WRITE: u32 = 0x10;
pub const FD_ERROR: u32 = 0x20;
pub const FD_CLOSE: u32 = 0x40;

/// ReleaseSocket's id for "give it one nobody has".
pub const UNIQUE_ID: i32 = -1;

/// struct linger: SO_LINGER's value. With `l_onoff` set, CloseSocket of a
/// stream socket waits up to `l_linger` seconds for what is still to be
/// sent to be acknowledged; with it set and `l_linger` 0, it resets the
/// connection at once.
pub const linger = extern struct {
    l_onoff: i32 = 0,
    l_linger: i32 = 0,
};

/// SetSockOpt's level for TCP's own options, and its one option: send a
/// small segment at once rather than wait for what is in flight.
pub const TCP_NODELAY: i32 = 0x01;

/// Shutdown's `how`: no more receiving, no more sending, neither.
pub const SHUT_RD: i32 = 0;
pub const SHUT_WR: i32 = 1;
pub const SHUT_RDWR: i32 = 2;

/// The longest queue Listen gives a listener.
pub const SOMAXCONN: i32 = 8;

/// IoctlSocket's requests: the bytes the next receive would get (an u32
/// out), whether the socket waits (an i32 in: not 0 for never), and
/// whether a stream socket's next byte is the one after its urgent byte
/// (an i32 out: 1 at the mark).
pub const FIONREAD: u32 = 0x4004_667F;
pub const FIONBIO: u32 = 0x8004_667E;
pub const SIOCATMARK: u32 = 0x4004_7307;

// --- WaitSelect --------------------------------------------------------------

/// The descriptors an fd_set can hold.
pub const FD_SETSIZE = 256;

/// struct fd_set: a bit per descriptor.
pub const fd_set = extern struct {
    fds_bits: [FD_SETSIZE / 32]u32 = @splat(0),

    /// FD_ZERO
    pub fn zero(bits: *fd_set) void {
        bits.fds_bits = @splat(0);
    }
    /// FD_SET
    pub fn set(bits: *fd_set, descriptor: i32) void {
        const n: u32 = @intCast(descriptor);
        bits.fds_bits[n / 32] |= @as(u32, 1) << @intCast(n % 32);
    }
    /// FD_CLR
    pub fn clear(bits: *fd_set, descriptor: i32) void {
        const n: u32 = @intCast(descriptor);
        bits.fds_bits[n / 32] &= ~(@as(u32, 1) << @intCast(n % 32));
    }
    /// FD_ISSET
    pub fn isSet(bits: *const fd_set, descriptor: i32) bool {
        const n: u32 = @intCast(descriptor);
        return bits.fds_bits[n / 32] & (@as(u32, 1) << @intCast(n % 32)) != 0;
    }
};

/// struct timeval, as WaitSelect's timeout and SO_RCVTIMEO take it.
pub const timeval = TimeVal;

// --- SocketBaseTagList --------------------------------------------------------

/// A tag's code (SBTC_*) and what it does with ti_Data: GET writes the
/// value to where ti_Data points, SET takes ti_Data as the value.
pub const SBTB_CODE = 1;
pub const SBTS_CODE: u32 = 0x3FFF;
pub const SBTF_SET: u32 = 0x1;
pub fn SBTM_GETREF(code: u32) u32 {
    return TAG_USER | ((code & SBTS_CODE) << SBTB_CODE);
}
pub fn SBTM_SETVAL(code: u32) u32 {
    return TAG_USER | ((code & SBTS_CODE) << SBTB_CODE) | SBTF_SET;
}

/// The signals that break a wait in a socket call or WaitSelect, which
/// then fails with EINTR; SIGBREAKF_CTRL_C unless set.
pub const SBTC_BREAKMASK: u32 = 1;
/// The signal socket events are told with (see GetSocketEvents).
pub const SBTC_SIGEVENTMASK: u32 = 4;
/// The opener's error number.
pub const SBTC_ERRNO: u32 = 6;
/// The size of the descriptor table: how many sockets the opener may
/// have at once. Set only while it has none.
pub const SBTC_DTABLESIZE: u32 = 8;
/// Every call that fails is logged with its errno, on the serial line.
pub const SBTC_LOGSTAT: u32 = 10;
/// GETREF only: what an error number means. ti_Data points to a usize
/// that holds the number going in and the text's address (`[*:0]const
/// u8`, the library's, never freed) coming out.
pub const SBTC_ERRNOSTRPTR: u32 = 14;
/// The same for an h_errno.
pub const SBTC_HERRNOSTRPTR: u32 = 15;

/// What `errno` means, in words, asked of the library `sb` (any
/// SocketBase): "Network is unreachable - no route to it" for
/// ENETUNREACH.
pub fn errnoText(sb: anytype, errno: i32) [*:0]const u8 {
    var value: usize = @bitCast(@as(isize, errno));
    const tags = [_]TagItem{
        .{ .tag = SBTM_GETREF(SBTC_ERRNOSTRPTR), .data = @intFromPtr(&value) },
        .{},
    };
    if (sb.SocketBaseTagList(&tags) != 0) return "Unknown error";
    return @ptrFromInt(value);
}

// --- errno ------------------------------------------------------------------

pub const EPERM: i32 = 1;
pub const EINTR: i32 = 4;
pub const EIO: i32 = 5;
pub const ENXIO: i32 = 6;
pub const EBADF: i32 = 9;
pub const ENOMEM: i32 = 12;
pub const EACCES: i32 = 13;
pub const EFAULT: i32 = 14;
pub const EINVAL: i32 = 22;
pub const EMFILE: i32 = 24;
/// No room: the buffer given is too small for what goes into it.
pub const ENOSPC: i32 = 28;
pub const EPIPE: i32 = 32;
pub const EWOULDBLOCK: i32 = 35;
pub const EAGAIN: i32 = EWOULDBLOCK;
pub const EINPROGRESS: i32 = 36;
pub const EALREADY: i32 = 37;
pub const ENOTSOCK: i32 = 38;
pub const EDESTADDRREQ: i32 = 39;
pub const EMSGSIZE: i32 = 40;
pub const EPROTOTYPE: i32 = 41;
pub const ENOPROTOOPT: i32 = 42;
pub const EPROTONOSUPPORT: i32 = 43;
pub const ESOCKTNOSUPPORT: i32 = 44;
pub const EOPNOTSUPP: i32 = 45;
pub const EPFNOSUPPORT: i32 = 46;
pub const EAFNOSUPPORT: i32 = 47;
pub const EADDRINUSE: i32 = 48;
pub const EADDRNOTAVAIL: i32 = 49;
pub const ENETDOWN: i32 = 50;
pub const ENETUNREACH: i32 = 51;
pub const ENETRESET: i32 = 52;
pub const ECONNABORTED: i32 = 53;
pub const ECONNRESET: i32 = 54;
pub const ENOBUFS: i32 = 55;
pub const EISCONN: i32 = 56;
pub const ENOTCONN: i32 = 57;
pub const ESHUTDOWN: i32 = 58;
pub const ETOOMANYREFS: i32 = 59;
pub const ETIMEDOUT: i32 = 60;
pub const ECONNREFUSED: i32 = 61;
pub const EHOSTDOWN: i32 = 64;
pub const EHOSTUNREACH: i32 = 65;

// --- interfaces ------------------------------------------------------------------

/// AddInterfaceTagList's tags. Addresses are in network order, as
/// `in_addr.s_addr` and Inet_Addr have them.
pub const IFA_Dummy: u32 = TAG_USER + 0xB2000;
/// ti_Data: the network device's name, "networks/openeth.device".
pub const IFA_Device: u32 = IFA_Dummy + 1;
/// ti_Data: its unit; 0 unless given.
pub const IFA_Unit: u32 = IFA_Dummy + 2;
/// ti_Data: the interface's address.
pub const IFA_Address: u32 = IFA_Dummy + 3;
/// ti_Data: the netmask of its net; 255.255.255.0 unless given.
pub const IFA_NetMask: u32 = IFA_Dummy + 4;
/// ti_Data: a gateway on its net, made the default route.
pub const IFA_Gateway: u32 = IFA_Dummy + 5;
/// ti_Data: the reads kept outstanding and the writes in flight on the
/// device; set from the link's speed unless given.
pub const IFA_Reads: u32 = IFA_Dummy + 6;
pub const IFA_Writes: u32 = IFA_Dummy + 7;

/// ti_Data: how the interface gets its address: IFCONFIGURE_FIXED (the
/// default, IFA_Address) or IFCONFIGURE_DHCP.
pub const IFA_Configure: u32 = IFA_Dummy + 8;
/// ti_Data: the most bytes of IP one packet may carry, below the link's.
pub const IFA_MTU: u32 = IFA_Dummy + 9;
/// ti_Data: a name server to ask, in network order; may be given more
/// than once.
pub const IFA_NameServer: u32 = IFA_Dummy + 10;
/// ti_Data: the domain a name without dots is looked for in, a C string.
pub const IFA_Domain: u32 = IFA_Dummy + 11;
/// ti_Data: the ring sizes of every TCP connection made from now on.
pub const IFA_TCPSendSpace: u32 = IFA_Dummy + 12;
pub const IFA_TCPRecvSpace: u32 = IFA_Dummy + 13;
/// ti_Data: ConfigureInterfaceTagList's IFSTATE_UP set puts the
/// interface's device on line, clear takes it off.
pub const IFA_State: u32 = IFA_Dummy + 14;
/// ti_Data: whether the interface speaks IPv6 - IFIPV6_AUTO (the default:
/// a link-local address, and addresses from the routers' prefixes) or
/// IFIPV6_OFF.
pub const IFA_IPv6: u32 = IFA_Dummy + 15;
/// ti_Data: how the interface's IPv6 addresses end: IFID_STABLE (the
/// default: a hash of the prefix, the link's address and the stable
/// secret) or IFID_EUI64 (the link's address itself).
pub const IFA_InterfaceID: u32 = IFA_Dummy + 16;
/// ti_Data: a pointer to IFSECRET_BYTES bytes, the secret IFID_STABLE
/// hashes with; the same secret gives the same addresses on the same
/// network at every boot. Random unless given.
pub const IFA_StableSecret: u32 = IFA_Dummy + 17;
/// ti_Data: a pointer to an in6_addr, an IPv6 address of the interface's
/// beside the link-local one; with IFA_Prefix6, its prefix length (64
/// unless given), whose prefix is then on the link.
pub const IFA_Address6: u32 = IFA_Dummy + 18;
pub const IFA_Prefix6: u32 = IFA_Dummy + 19;
/// ti_Data: a pointer to an in6_addr, a router on the link made the
/// IPv6 default route - a link-local address, as routers have.
pub const IFA_Gateway6: u32 = IFA_Dummy + 20;
/// ti_Data: a pointer to an in6_addr, an IPv6 name server to ask; may be
/// given more than once. IFA_NameServer's IPv6 twin, stack-wide as it is.
pub const IFA_NameServer6: u32 = IFA_Dummy + 21;
/// ti_Data: not 0 for privacy addresses (RFC 8981): beside each address
/// from a router's prefix, a temporary one ending in random bits, which
/// connections going out are made from, and which a new one replaces
/// each day. Off unless given; ConfigureInterfaceTagList turns it on and
/// off on a running interface.
pub const IFA_PrivacyAddresses: u32 = IFA_Dummy + 22;
/// ti_Data: a tag list handed to the network device with its OpenDevice,
/// beside the stack's own: what that device needs to be told - the serial
/// line of slip.device (sdk/devices/slip.zig).
pub const IFA_DeviceTags: u32 = IFA_Dummy + 23;

pub const IFCONFIGURE_FIXED: u32 = 0;
pub const IFCONFIGURE_DHCP: u32 = 1;

pub const IFIPV6_OFF: u32 = 0;
pub const IFIPV6_AUTO: u32 = 1;
/// IPv6 with the link-local address and IFA_Address6 only: no address is
/// made from a router's prefix, though routers still give routes.
pub const IFIPV6_FIXED: u32 = 2;

pub const IFID_STABLE: u32 = 0;
pub const IFID_EUI64: u32 = 1;
/// The bytes of IFA_StableSecret's secret.
pub const IFSECRET_BYTES: u32 = 16;

/// QueryInterfaceTagList's tags: ti_Data points at where the answer goes.
pub const IFQ_Dummy: u32 = TAG_USER + 0xB3000;
/// u32s, addresses in network order.
pub const IFQ_Address: u32 = IFQ_Dummy + 1;
pub const IFQ_NetMask: u32 = IFQ_Dummy + 2;
pub const IFQ_Broadcast: u32 = IFQ_Dummy + 3;
/// The default route's gateway if it goes through this interface, else 0.
pub const IFQ_Gateway: u32 = IFQ_Dummy + 4;
pub const IFQ_MTU: u32 = IFQ_Dummy + 5;
/// IFSTATE_* bits.
pub const IFQ_State: u32 = IFQ_Dummy + 6;
/// [6]u8: the link's hardware address; zeros for lo0.
pub const IFQ_HardwareAddress: u32 = IFQ_Dummy + 7;
/// u64s: packets out, packets in; u32: packets that could not go.
pub const IFQ_PacketsSent: u32 = IFQ_Dummy + 8;
pub const IFQ_PacketsReceived: u32 = IFQ_Dummy + 9;
pub const IFQ_PacketsDropped: u32 = IFQ_Dummy + 10;
/// [*:0]const u8, and u32: the network device and unit, or null for lo0.
pub const IFQ_DeviceName: u32 = IFQ_Dummy + 11;
pub const IFQ_DeviceUnit: u32 = IFQ_Dummy + 12;
/// u64: the link's speed in bits per second.
pub const IFQ_Speed: u32 = IFQ_Dummy + 13;
/// u32s: the time servers DHCP named for the interface, in network
/// order, or 0.
pub const IFQ_TimeServer: u32 = IFQ_Dummy + 14;
pub const IFQ_TimeServer2: u32 = IFQ_Dummy + 15;

/// IFQ_State's bits.
pub const IFSTATE_UP: u32 = 1 << 0;
pub const IFSTATE_LOOPBACK: u32 = 1 << 1;
/// The address comes from DHCP; and DHCP has one bound now.
pub const IFSTATE_DHCP: u32 = 1 << 2;
pub const IFSTATE_BOUND: u32 = 1 << 3;
/// The address is a link-local one, taken while DHCP gets no answer.
pub const IFSTATE_LINKLOCAL: u32 = 1 << 4;

/// ConfigureInterfaceTagList takes the IFA_ tags that make sense on a
/// running interface: IFA_Address, IFA_NetMask, IFA_Gateway, IFA_MTU,
/// IFA_State, IFA_Address6 with IFA_Prefix6, IFA_PrivacyAddresses.
/// AddRouteTagList's and DeleteRouteTagList's tags, addresses in network
/// order.
pub const RTA_Dummy: u32 = TAG_USER + 0xB4000;
/// The net or host the route is to, and its netmask (a host unless
/// given).
pub const RTA_Destination: u32 = RTA_Dummy + 1;
pub const RTA_NetMask: u32 = RTA_Dummy + 2;
/// The station on an interface's net the packets go through.
pub const RTA_Gateway: u32 = RTA_Dummy + 3;
/// The default route, through this gateway.
pub const RTA_DefaultGateway: u32 = RTA_Dummy + 4;
/// IPv6 routes, each ti_Data a pointer to an in6_addr: the prefix the
/// route is to, with its length (a u32; 128, one host, unless given),
/// and the router on the link packets go through (none: the prefix is on
/// the link itself).
pub const RTA_Destination6: u32 = RTA_Dummy + 5;
pub const RTA_PrefixLength6: u32 = RTA_Dummy + 6;
pub const RTA_Gateway6: u32 = RTA_Dummy + 7;
/// An IPv6 default route, through this router.
pub const RTA_DefaultGateway6: u32 = RTA_Dummy + 8;
/// ti_Data: the name of the interface an IPv6 route is on, a C string:
/// needed for a prefix on the link; for a router, the interface it is
/// found on unless given.
pub const RTA_Interface: u32 = RTA_Dummy + 9;

/// ObtainInterfaceList's nodes: each interface's name, in a list that is
/// the caller's until ReleaseInterfaceList.
pub const InterfaceNode = extern struct {
    node: @import("../exec/nodes.zig").Node = .{},
    name: [IFNAMSIZ]u8 = @splat(0),
};

/// How many name servers the stack asks, at most.
pub const NAMESERVERS_MAX = 4;

// --- names ----------------------------------------------------------------------

/// struct hostent: what GetHostByName and GetHostByAddr answer, in a
/// buffer of the opener's base that the next such call overwrites.
pub const hostent = extern struct {
    /// h_name: the name, as the answer spelled it.
    h_name: ?[*:0]u8 = null,
    /// h_aliases: other names, a list ended by null.
    h_aliases: ?[*]?[*:0]u8 = null,
    /// h_addrtype: AF_INET.
    h_addrtype: i32 = AF_INET,
    /// h_length: the bytes of one address, 4.
    h_length: i32 = 4,
    /// h_addr_list: the addresses, each `h_length` bytes in network order,
    /// a list ended by null.
    h_addr_list: ?[*]?[*]u8 = null,
};

/// Why a name was not found, as SocketBaseTagList's SBTC_HERRNO reads it.
pub const HOST_NOT_FOUND: i32 = 1;
/// No answer in time: it may be found later.
pub const TRY_AGAIN: i32 = 2;
/// An answer that made no sense, or no name server to ask.
pub const NO_RECOVERY: i32 = 3;
/// The name is known, and has no address.
pub const NO_DATA: i32 = 4;

/// The error of the last name lookup that failed.
pub const SBTC_HERRNO: u32 = 7;

/// struct addrinfo: one address GetAddrInfo found, of a list that
/// FreeAddrInfo gives back whole.
pub const addrinfo = extern struct {
    /// ai_flags: the AI_* the caller gave.
    ai_flags: i32 = 0,
    /// ai_family: AF_INET or AF_INET6; AF_UNSPEC in hints for either.
    ai_family: i32 = AF_UNSPEC,
    /// ai_socktype, ai_protocol: SOCK_STREAM with IPPROTO_TCP, SOCK_DGRAM
    /// with IPPROTO_UDP; 0 in hints for both.
    ai_socktype: i32 = 0,
    ai_protocol: i32 = 0,
    /// ai_addrlen, ai_addr: the address and port, a sockaddr_in or a
    /// sockaddr_in6, ready for Connect, SendTo or Bind.
    ai_addrlen: u32 = 0,
    /// ai_canonname: the name as the answer spelled it, on the first
    /// entry, with AI_CANONNAME.
    ai_canonname: ?[*:0]u8 = null,
    ai_addr: ?*sockaddr = null,
    ai_next: ?*addrinfo = null,
};

/// GetAddrInfo's flags. AI_PASSIVE: with no node, the address that means
/// every one of the machine's (to Bind), not the loopback. AI_CANONNAME:
/// the canonical name on the first entry. AI_NUMERICHOST: the node is an
/// address, never a name to look up; AI_NUMERICSERV: the service is a
/// number. AI_ADDRCONFIG: a family only when an interface other than lo0
/// has an address of it. AI_V4MAPPED: for AF_INET6, IPv4 addresses
/// mapped when there are no IPv6 ones; AI_ALL: and with them too.
pub const AI_PASSIVE: i32 = 0x0001;
pub const AI_CANONNAME: i32 = 0x0002;
pub const AI_NUMERICHOST: i32 = 0x0004;
pub const AI_NUMERICSERV: i32 = 0x0008;
pub const AI_ALL: i32 = 0x0100;
pub const AI_ADDRCONFIG: i32 = 0x0400;
pub const AI_V4MAPPED: i32 = 0x0800;

/// GetAddrInfo's answers other than 0.
pub const EAI_AGAIN: i32 = 2;
pub const EAI_BADFLAGS: i32 = 3;
pub const EAI_FAIL: i32 = 4;
pub const EAI_FAMILY: i32 = 5;
pub const EAI_MEMORY: i32 = 6;
pub const EAI_NONAME: i32 = 8;
pub const EAI_SERVICE: i32 = 9;
pub const EAI_SOCKTYPE: i32 = 10;
pub const EAI_OVERFLOW: i32 = 14;

/// GetNameInfo's flags. NI_NUMERICHOST: the address as text, never a
/// lookup; NI_NUMERICSERV: the port as a number. NI_NOFQDN: a name in
/// the stack's domain without it. NI_NAMEREQD: EAI_NONAME rather than the
/// address as text when there is no name. NI_DGRAM: the service is UDP's.
pub const NI_NUMERICHOST: i32 = 0x01;
pub const NI_NUMERICSERV: i32 = 0x02;
pub const NI_NOFQDN: i32 = 0x04;
pub const NI_NAMEREQD: i32 = 0x08;
pub const NI_DGRAM: i32 = 0x10;
/// Room enough for any host and service GetNameInfo writes.
pub const NI_MAXHOST = 1025;
pub const NI_MAXSERV = 32;

/// Where names are looked up first, and the name servers kept on the
/// disk: files a program and a user edit.
pub const HOSTS_FILE = "ENVARC:Sys/net/hosts";
pub const NAMESERVERS_FILE = "ENVARC:Sys/net/nameservers";
/// The time server TimeSync asks when neither it nor DHCP names one.
pub const TIMESERVER_FILE = "ENVARC:Sys/net/timeserver";
/// The machine's name: the first line that is not a comment. Read by the
/// stack the first time an interface is added or the name is asked for,
/// unless SetHostName came first; sent to DHCP servers.
pub const HOSTNAME_FILE = "ENVARC:Sys/net/hostname";

/// How long an interface's name may be.
pub const IFNAMSIZ = 16;

// --- statistics -----------------------------------------------------------------

/// GetNetworkStatistics' kinds, and what each fills the buffer with.
/// NETSTATUS_COUNTS: one NetCounts.
pub const NETSTATUS_COUNTS: u32 = 1;
/// NETSTATUS_ROUTES: a RouteInfo per route.
pub const NETSTATUS_ROUTES: u32 = 2;
/// NETSTATUS_SOCKETS: a SocketInfo per socket.
pub const NETSTATUS_SOCKETS: u32 = 3;
/// NETSTATUS_ARP: an ArpInfo per entry of the ARP cache.
pub const NETSTATUS_ARP: u32 = 4;
/// NETSTATUS_ADDRESSES6: an Address6Info per IPv6 address of every
/// interface.
pub const NETSTATUS_ADDRESSES6: u32 = 5;
/// NETSTATUS_ROUTES6: a Route6Info per IPv6 route.
pub const NETSTATUS_ROUTES6: u32 = 6;
/// NETSTATUS_NEIGHBORS: a NeighborInfo per entry of the neighbor cache.
pub const NETSTATUS_NEIGHBORS: u32 = 7;
/// NETSTATUS_NAMESERVERS: a NameServerInfo per name server the stack
/// asks, in the order it asks them.
pub const NETSTATUS_NAMESERVERS: u32 = 8;

/// What the stack counts, since it started.
pub const NetCounts = extern struct {
    ip_received: u64 align(4) = 0,
    ip_sent: u64 align(4) = 0,
    /// Headers that were not IPv4, too short, or longer than the packet.
    ip_bad_header: u32 = 0,
    ip_bad_checksum: u32 = 0,
    /// Fragments received, datagrams put back together from them, and
    /// the ones given up on: too large, overlapping, out of room or out
    /// of time.
    ip_fragments: u32 = 0,
    ip_reassembled: u32 = 0,
    ip_reassembly_dropped: u32 = 0,
    /// Packets for an address that is not this machine's.
    ip_not_ours: u32 = 0,
    /// Packets of a protocol nothing here speaks.
    ip_unknown_protocol: u32 = 0,
    udp_received: u64 align(4) = 0,
    udp_sent: u64 align(4) = 0,
    udp_bad: u32 = 0,
    /// Datagrams to a port nothing is bound to.
    udp_no_port: u32 = 0,
    /// Datagrams dropped because their socket's queue was full.
    udp_full: u32 = 0,
    icmp_received: u32 = 0,
    icmp_bad: u32 = 0,
    /// Echo requests answered, and errors sent for packets that came in.
    icmp_echoes_answered: u32 = 0,
    icmp_errors_sent: u32 = 0,
    tcp_received: u64 align(4) = 0,
    tcp_sent: u64 align(4) = 0,
    /// Segments too short, with a data offset past their end, or a bad
    /// checksum.
    tcp_bad: u32 = 0,
    tcp_resets_sent: u32 = 0,
    /// SYNs a listener's full queue let go unanswered.
    tcp_backlog_full: u32 = 0,
    /// Segments sent again after a timeout, and after three duplicate
    /// acknowledgements; windows probed; connections given up.
    tcp_retransmits: u32 = 0,
    tcp_fast_retransmits: u32 = 0,
    tcp_window_probes: u32 = 0,
    tcp_timeouts: u32 = 0,
    /// Challenge ACKs sent, and the ones the limit held back; segments
    /// the fast path took.
    tcp_challenges: u32 = 0,
    tcp_challenges_dropped: u32 = 0,
    tcp_predicted: u64 align(4) = 0,
    /// ARP: questions sent, answers given, packets that were no ARP, and
    /// packets dropped while their address went unanswered.
    arp_requests_sent: u32 = 0,
    arp_replies_sent: u32 = 0,
    arp_bad: u32 = 0,
    arp_dropped: u32 = 0,
    /// IPv6: packets in and out; headers that were not IPv6 or longer
    /// than the packet, or extension headers that could not be read;
    /// packets for an address that is not this machine's; packets whose
    /// next header nothing here speaks.
    ip6_received: u64 align(4) = 0,
    ip6_sent: u64 align(4) = 0,
    ip6_bad_header: u32 = 0,
    ip6_not_ours: u32 = 0,
    ip6_unknown_protocol: u32 = 0,
    /// Fragments received, datagrams put back together, and the ones
    /// given up on.
    ip6_fragments: u32 = 0,
    ip6_reassembled: u32 = 0,
    ip6_reassembly_dropped: u32 = 0,
    /// Fragments sent, of packets larger than their path.
    ip6_fragments_sent: u32 = 0,
    /// ICMPv6: messages in, the ones too short or with a bad checksum,
    /// echo requests answered, errors sent, and errors the rate limit
    /// held back.
    icmp6_received: u32 = 0,
    icmp6_bad: u32 = 0,
    icmp6_echoes_answered: u32 = 0,
    icmp6_errors_sent: u32 = 0,
    icmp6_errors_limited: u32 = 0,
    /// Neighbor Discovery: solicitations and advertisements sent,
    /// messages that failed its checks, packets dropped while their
    /// neighbor went unanswered, and addresses another station turned out
    /// to have; MLD reports sent.
    nd_solicits_sent: u32 = 0,
    nd_adverts_sent: u32 = 0,
    nd_bad: u32 = 0,
    nd_dropped: u32 = 0,
    nd_duplicates: u32 = 0,
    mld_reports_sent: u32 = 0,
    /// IGMP: messages in, the ones too short or with a bad checksum, and
    /// reports and leaves sent.
    igmp_received: u32 = 0,
    igmp_bad: u32 = 0,
    igmp_reports_sent: u32 = 0,
    /// Packets a packet hook dropped, and refused (AddPacketHook).
    hook_dropped: u32 = 0,
    hook_refused: u32 = 0,
    /// ICMPv4 errors the rate limit held back.
    icmp_errors_limited: u32 = 0,
};

/// A route: addresses in network order.
pub const RouteInfo = extern struct {
    destination: u32 = 0,
    netmask: u32 = 0,
    /// The station packets go through, or 0 for a net the interface is on.
    gateway: u32 = 0,
    interface: [IFNAMSIZ]u8 = @splat(0),
};

/// A TCP connection's state, SocketInfo's `tcp_state`.
pub const TCPS_CLOSED: u8 = 0;
pub const TCPS_LISTEN: u8 = 1;
pub const TCPS_SYN_SENT: u8 = 2;
pub const TCPS_SYN_RECEIVED: u8 = 3;
pub const TCPS_ESTABLISHED: u8 = 4;
pub const TCPS_FIN_WAIT_1: u8 = 5;
pub const TCPS_FIN_WAIT_2: u8 = 6;
pub const TCPS_CLOSE_WAIT: u8 = 7;
pub const TCPS_CLOSING: u8 = 8;
pub const TCPS_LAST_ACK: u8 = 9;
pub const TCPS_TIME_WAIT: u8 = 10;

/// SocketInfo's flags: handed over and waiting for ObtainSocket; closed
/// by its program and still finishing its connection; a connection a
/// listener took that Accept has not yet.
pub const SOCKINFO_RELEASED: u8 = 1 << 0;
pub const SOCKINFO_CLOSING: u8 = 1 << 1;
pub const SOCKINFO_UNACCEPTED: u8 = 1 << 2;

/// A socket: its addresses as IPv6 has them (an IPv4 one mapped,
/// `::ffff:a.b.c.d`), ports in the chip's order.
pub const SocketInfo = extern struct {
    /// Its descriptor in its owner's table, or -1.
    descriptor: i32 = -1,
    socket_type: i32 = 0,
    protocol: i32 = 0,
    /// AF_INET or AF_INET6, as it was made.
    family: i32 = AF_INET,
    local_address: in6_addr = .{},
    remote_address: in6_addr = .{},
    local_port: u16 = 0,
    remote_port: u16 = 0,
    /// TCPS_* for a stream socket, else 0.
    tcp_state: u8 = 0,
    /// SOCKINFO_*.
    flags: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    /// The bytes waiting to be read, and the bytes sent and not yet
    /// acknowledged or not yet sent.
    receive_queued: u32 = 0,
    send_queued: u32 = 0,
    /// The name of the task whose socket it is; empty when it has none.
    owner: [32]u8 = @splat(0),
};

/// An ArpInfo's state: a question out, an answer known, the answer being
/// checked again, an address that went unanswered and is left alone for
/// a while.
pub const ARPSTATE_PENDING: u8 = 1;
pub const ARPSTATE_RESOLVED: u8 = 2;
pub const ARPSTATE_CHECKING: u8 = 3;
pub const ARPSTATE_HELD: u8 = 4;

/// An entry of the ARP cache: its address in network order.
pub const ArpInfo = extern struct {
    address: u32 = 0,
    hardware: [6]u8 = @splat(0),
    /// ARPSTATE_*.
    state: u8 = 0,
    pad: u8 = 0,
    interface: [IFNAMSIZ]u8 = @splat(0),
};

/// An Address6Info's state.
pub const ADDR6_TENTATIVE: u8 = 1;
pub const ADDR6_PREFERRED: u8 = 2;
pub const ADDR6_DEPRECATED: u8 = 3;
pub const ADDR6_DUPLICATE: u8 = 4;

/// Lifetimes that never end, in the infos' seconds.
pub const LIFETIME_INFINITE: u32 = 0xFFFF_FFFF;

/// One IPv6 address of an interface.
pub const Address6Info = extern struct {
    address: in6_addr = .{},
    prefix_length: u8 = 0,
    /// ADDR6_*.
    state: u8 = 0,
    /// Made from a router's prefix; and a temporary address, its ending
    /// random (IFA_PrivacyAddresses).
    autoconf: u8 = 0,
    temporary: u8 = 0,
    /// The seconds it stays preferred and valid, or LIFETIME_INFINITE.
    preferred_s: u32 = LIFETIME_INFINITE,
    valid_s: u32 = LIFETIME_INFINITE,
    interface: [IFNAMSIZ]u8 = @splat(0),
    /// The interface's last router advertisement's M and O flags
    /// (RA_MANAGED, RA_OTHER), on every entry of it.
    router_flags: u8 = 0,
    /// Given by DHCPv6.
    dhcp: u8 = 0,
    pad2: [2]u8 = .{ 0, 0 },
};

/// A router advertisement's flags: addresses (M) or other settings (O)
/// are to be had from DHCPv6.
pub const RA_MANAGED: u8 = 0x80;
pub const RA_OTHER: u8 = 0x40;

/// A Route6Info's origin.
pub const ROUTE6_MANUAL: u8 = 1;
pub const ROUTE6_ROUTER: u8 = 2;
pub const ROUTE6_REDIRECT: u8 = 3;

/// An IPv6 route.
pub const Route6Info = extern struct {
    destination: in6_addr = .{},
    /// The router it goes through; `::` for a prefix on the link.
    gateway: in6_addr = .{},
    prefix_length: u8 = 0,
    /// ROUTE6_*.
    origin: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    /// The seconds it is still used, or LIFETIME_INFINITE.
    lifetime_s: u32 = LIFETIME_INFINITE,
    interface: [IFNAMSIZ]u8 = @splat(0),
};

/// Where a name server came from: an interface file, DHCP or a program
/// (AddDomainNameServer); a router's advertisement (RDNSS).
pub const NAMESERVER_GIVEN: u8 = 1;
pub const NAMESERVER_ROUTER: u8 = 2;

/// A name server: its address as IPv6 has it (an IPv4 one mapped).
pub const NameServerInfo = extern struct {
    address: in6_addr = .{},
    /// NAMESERVER_*.
    origin: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The interface whose router named it; empty for one given.
    interface: [IFNAMSIZ]u8 = @splat(0),
};

/// A NeighborInfo's state (RFC 4861, 7.3.2).
pub const NDSTATE_INCOMPLETE: u8 = 1;
pub const NDSTATE_REACHABLE: u8 = 2;
pub const NDSTATE_STALE: u8 = 3;
pub const NDSTATE_DELAY: u8 = 4;
pub const NDSTATE_PROBE: u8 = 5;

/// An entry of the neighbor cache.
pub const NeighborInfo = extern struct {
    address: in6_addr = .{},
    hardware: [6]u8 = @splat(0),
    /// NDSTATE_*.
    state: u8 = 0,
    /// It said it is a router.
    router: u8 = 0,
    interface: [IFNAMSIZ]u8 = @splat(0),
};

// --- capture ----------------------------------------------------------------------

/// SetSockOpt(SOL_SOCKET, SO_BINDTODEVICE): a capture socket held to the
/// interface named in the value ("eth0"); an empty name is every one.
pub const SO_BINDTODEVICE: i32 = 0x2002;

/// CaptureHeader's `direction`.
pub const CAPTURE_IN: u8 = 0;
pub const CAPTURE_OUT: u8 = 1;

/// CaptureHeader's `link`: what the frame behind it starts with. The
/// values are pcap's LINKTYPE_ numbers. NULL is a 4-byte address family
/// in the chip's order (AF_INET or AF_INET6), then the IP packet: what lo0
/// carries, and what a packet hook stopped is shown as.
pub const CAPTURE_LINK_NULL: u8 = 0;
/// A 14-byte Ethernet header: destination, source, type.
pub const CAPTURE_LINK_ETHERNET: u8 = 1;

/// What each datagram a capture socket receives starts with; the frame
/// follows it, as much of it as the datagram holds.
pub const CaptureHeader = extern struct {
    /// When the frame was seen: the system time.
    secs: u32 = 0,
    micro: u32 = 0,
    /// The frame's whole length on the link.
    length: u32 = 0,
    /// Frames the socket had no room for since the one before this.
    dropped: u32 = 0,
    /// CAPTURE_IN or CAPTURE_OUT.
    direction: u8 = CAPTURE_IN,
    /// CAPTURE_LINK_*.
    link: u8 = CAPTURE_LINK_ETHERNET,
    /// CAPTURE_FILTERED, or 0.
    flags: u8 = 0,
    pad: u8 = 0,
    /// The interface it went through.
    interface: [IFNAMSIZ]u8 = @splat(0),
};

/// CaptureHeader's `flags`: a packet that came in and a packet hook
/// dropped or refused - a second copy, the IP packet behind a NULL link
/// header, beside the frame as it came off the link.
pub const CAPTURE_FILTERED: u8 = 1 << 0;

// --- packet hooks ------------------------------------------------------------------

/// AddPacketHook's tags.
pub const PH_Dummy: u32 = TAG_USER + 0xB6000;
/// Which way the hook looks: PH_IN (the default) or PH_OUT.
pub const PH_Direction: u32 = PH_Dummy + 1;
/// Its place in the chain, -128..127, the highest called first; 0 when
/// not given. Hooks of one priority are called in the order they came.
pub const PH_Priority: u32 = PH_Dummy + 2;
/// The interface it looks at, its name ("wlan0"), even one not there yet;
/// every interface when not given.
pub const PH_Interface: u32 = PH_Dummy + 3;
/// TRUE: the hook stays when the base that added it is closed, until a
/// RemPacketHook from any base. For a library that adds its hook during
/// one call on its caller's task and takes it out during another, and
/// whose code stays while the hook is in.
pub const PH_Keep: u32 = PH_Dummy + 4;

pub const PH_IN: u32 = 0;
pub const PH_OUT: u32 = 1;

/// What a packet hook answers, as its `h_Entry`'s result: the packet goes
/// on; it is dropped and nothing said; it is refused - a TCP segment
/// answered with a reset, a UDP datagram with a port unreachable, anything
/// else dropped. A packet going out is only passed or dropped.
pub const PACKET_PASS: u32 = 0;
pub const PACKET_DROP: u32 = 1;
pub const PACKET_REFUSE: u32 = 2;

/// PacketView's `belongs`: what the stack found the packet is for when it
/// came in - nothing, a TCP connection's segment, a SYN or anything else
/// for a listening socket, a datagram for a socket bound to its port or a
/// member of its group. Going out, it is always NONE.
pub const PACKET_BELONGS_NONE: u8 = 0;
pub const PACKET_BELONGS_CONNECTION: u8 = 1;
pub const PACKET_BELONGS_LISTENER: u8 = 2;
pub const PACKET_BELONGS_BOUND: u8 = 3;

/// TCP's flags, as PacketView's `tcp_flags` has them.
pub const TH_FIN: u8 = 0x01;
pub const TH_SYN: u8 = 0x02;
pub const TH_RST: u8 = 0x04;
pub const TH_PUSH: u8 = 0x08;
pub const TH_ACK: u8 = 0x10;
pub const TH_URG: u8 = 0x20;

/// What a packet hook is shown: a packet's parts, read from its headers,
/// and its transport's bytes. Valid only during the call, and read-only.
pub const PacketView = extern struct {
    /// PH_IN or PH_OUT.
    direction: u8 = 0,
    /// AF_INET or AF_INET6.
    family: u8 = 0,
    /// IPPROTO_TCP, IPPROTO_UDP, IPPROTO_ICMP or IPPROTO_ICMPV6.
    protocol: u8 = 0,
    /// PACKET_BELONGS_*.
    belongs: u8 = 0,
    /// TCP: the segment's TH_* flags.
    tcp_flags: u8 = 0,
    /// ICMP and ICMPv6: the message's type and code.
    icmp_type: u8 = 0,
    icmp_code: u8 = 0,
    pad: u8 = 0,
    /// TCP and UDP: the ports, in the chip's order; 0 otherwise.
    source_port: u16 = 0,
    destination_port: u16 = 0,
    /// The interface, by If_NameToIndex's number and by name.
    interface_index: u32 = 0,
    interface: [IFNAMSIZ]u8 = @splat(0),
    /// The addresses; IPv4's as IPv4-mapped IPv6 (::ffff:a.b.c.d).
    source: in6_addr = .{},
    destination: in6_addr = .{},
    /// The transport's header and what it carries, `length` bytes.
    data: ?[*]const u8 = null,
    length: u32 = 0,
};
