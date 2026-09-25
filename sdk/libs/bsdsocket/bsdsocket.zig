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
pub const AF_INET: u8 = 2;
pub const PF_INET: i32 = AF_INET;

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
pub const IPPROTO_TCP: i32 = 6;
pub const IPPROTO_UDP: i32 = 17;

/// Flags of the send and receive calls: look at what is there without
/// taking it, and do not wait for this one call.
pub const MSG_PEEK: u32 = 0x2;
pub const MSG_DONTWAIT: u32 = 0x80;

/// SetSockOpt's and GetSockOpt's level for the socket's own options.
pub const SOL_SOCKET: i32 = 0xFFFF;

/// The socket's options. Each takes an i32 unless it says otherwise.
pub const SO_REUSEADDR: i32 = 0x0004;
pub const SO_BROADCAST: i32 = 0x0020;
/// The bytes of data a socket buffers for sending and receiving.
pub const SO_SNDBUF: i32 = 0x1001;
pub const SO_RCVBUF: i32 = 0x1002;
/// How long a send or a receive may wait: a TimeVal; zero waits for ever.
pub const SO_SNDTIMEO: i32 = 0x1005;
pub const SO_RCVTIMEO: i32 = 0x1006;
/// The socket's pending error, taken as it is read (get only).
pub const SO_ERROR: i32 = 0x1007;
/// The socket's type, SOCK_* (get only).
pub const SO_TYPE: i32 = 0x1008;

/// IoctlSocket's requests: the bytes the next receive would get (an u32
/// out), and whether the socket waits (an i32 in: not 0 for never).
pub const FIONREAD: u32 = 0x4004_667F;
pub const FIONBIO: u32 = 0x8004_667E;

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

/// How long an interface's name may be.
pub const IFNAMSIZ = 16;
