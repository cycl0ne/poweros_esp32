// SPDX-License-Identifier: MIT
//! Network devices (devices/sana2.h): the requests every network driver
//! answers, whatever the link - Ethernet, Wi-Fi, SLIP, USB. A driver is a
//! device in DEVS:networks/; the TCP/IP stack and any other opener (a
//! tracer, a test) speak to it in this one form.
//!
//! Every request is an IOSana2Req. A unit is one link; any number of
//! openers may share it, and an opener that sets SANA2OPF_MINE in
//! OpenDevice's flags has it alone.
//!
//!   CMD_READ                a packet of ios2_PacketType (an EtherType on
//!                           Ethernet), queued until one comes: its source
//!                           and destination address, ios2_DataLength, and
//!                           SANA2IOF_BCAST or _MCAST if it was sent to
//!                           many. With SANA2IOF_RAW, the whole frame,
//!                           header included.
//!   CMD_WRITE               ios2_DataLength bytes of ios2_PacketType to
//!                           ios2_DstAddr. With SANA2IOF_RAW, ios2_Data is
//!                           the whole frame.
//!   CMD_FLUSH               aborts every queued request of this opener
//!                           (IOERR_ABORTED).
//!   S2_DEVICEQUERY          fills the Sana2DeviceQuery in ios2_StatData.
//!   S2_GETSTATIONADDRESS    ios2_SrcAddr: the address the unit runs with;
//!                           ios2_DstAddr: the hardware's own.
//!   S2_CONFIGINTERFACE      the unit runs with ios2_SrcAddr and goes
//!                           online. Once per unit: a second one fails
//!                           with S2WERR_IS_CONFIGURED.
//!   S2_ADDMULTICASTADDRESS  the unit also takes packets to ios2_SrcAddr;
//!   S2_DELMULTICASTADDRESS  and stops again. Counted: an address added
//!                           twice needs deleting twice.
//!   S2_MULTICAST            CMD_WRITE to the multicast ios2_DstAddr.
//!   S2_BROADCAST            CMD_WRITE to every station on the link.
//!   S2_TRACKTYPE            counts the packets of ios2_PacketType;
//!   S2_UNTRACKTYPE          and stops counting them.
//!   S2_GETTYPESTATS         fills the Sana2PacketTypeStats in ios2_StatData
//!                           for a tracked ios2_PacketType.
//!   S2_GETSPECIALSTATS      fills the Sana2SpecialStatHeader in
//!                           ios2_StatData and the records after it.
//!   S2_GETGLOBALSTATS       fills the Sana2DeviceStats in ios2_StatData.
//!   S2_ONEVENT              ios2_WireError: a mask of S2EVENT_*; the
//!                           request is answered when one of them happens,
//!                           with that one in ios2_WireError. A state that
//!                           already holds (S2EVENT_ONLINE on a unit that
//!                           is online) answers at once.
//!   S2_READORPHAN           CMD_READ for a packet no opener has a read of
//!                           its type queued for.
//!   S2_ONLINE               puts a configured unit back on the link;
//!   S2_OFFLINE              takes it off, and answers every queued read
//!                           and write with S2ERR_OUTOFSERVICE.
//!
//! A packet that comes in goes to one queued read of its type of each
//! opener, so a tracer beside the stack sees what the stack sees; a
//! packet no read wants goes to one S2_READORPHAN of each opener that has
//! one, and is otherwise dropped and counted.
//!
//! **Buffers stay the opener's.** At OpenDevice, ios2_BufferManagement
//! holds a tag list: S2_CopyToBuff and S2_CopyFromBuff (both required),
//! S2_PacketFilter (optional). The driver copies a received packet straight
//! from its receive ring into the opener's buffer with the first, and a
//! packet to send from the opener's buffer with the second, so ios2_Data
//! is the opener's own handle and never has to be a plain byte array. The
//! driver then replaces the tag list with its own cookie, which every
//! later request of that opener carries (a request made as a copy of the
//! opened one has it). The calls run only on the driver's own task, never
//! in an interrupt, so the opener's buffers may be taken under an ordinary
//! lock.
//!
//! **A driver never polls.** A frame received, a frame sent and a change
//! of the link are its hardware's interrupts, taken with exec's
//! AddIntServer; the interrupt code acknowledges the hardware and signals
//! the driver's task, which does the rest. Hardware that cannot interrupt
//! is polled from a timer.device request, and only while the unit is
//! online.
//!
//! A request that has to wait needs a reply port; without one it fails
//! with IOERR_NOREPLYPORT.

const exec = @import("../libs/exec/exec.zig");
const TimeVal = @import("timer.zig").TimeVal;
const TAG_USER = @import("../libs/utility/tagitem.zig").TAG_USER;

/// The longest hardware address a link may have, in bits and in bytes.
pub const SANA2_MAX_ADDR_BITS: u32 = 128;
pub const SANA2_MAX_ADDR_BYTES: u32 = (SANA2_MAX_ADDR_BITS + 7) / 8;

/// struct IOSana2Req: every request to a network device. The addresses
/// are left-aligned in their arrays; how many bits count is
/// Sana2DeviceQuery's `addr_field_size`.
pub const IOSana2Req = extern struct {
    /// ios2_Req: the request itself; io_Flags carries SANA2IOF_*.
    req: exec.IORequest = .{},
    /// ios2_WireError: what went wrong on the link (S2WERR_*), when
    /// io_Error says why the request failed; S2_ONEVENT's event mask.
    wire_error: u32 = 0,
    /// ios2_PacketType: the type of the packet read or written, an
    /// EtherType on Ethernet.
    packet_type: u32 = 0,
    /// ios2_SrcAddr
    src_addr: [SANA2_MAX_ADDR_BYTES]u8 = @splat(0),
    /// ios2_DstAddr
    dst_addr: [SANA2_MAX_ADDR_BYTES]u8 = @splat(0),
    /// ios2_DataLength: the bytes of the packet, without the link's header
    /// unless SANA2IOF_RAW is set.
    data_length: u32 = 0,
    /// ios2_Data: the opener's handle for its buffer, given to the copy
    /// calls as it is.
    data: ?*anyopaque = null,
    /// ios2_StatData: where the query and statistics commands write.
    stat_data: ?*anyopaque = null,
    /// ios2_BufferManagement: the tag list at OpenDevice, the driver's
    /// cookie after it.
    buffer_management: ?*anyopaque = null,
};

/// io_Flags of an IOSana2Req.
pub const SANA2IOB_RAW = 7;
pub const SANA2IOF_RAW: u8 = 1 << SANA2IOB_RAW;
pub const SANA2IOB_BCAST = 6;
pub const SANA2IOF_BCAST: u8 = 1 << SANA2IOB_BCAST;
pub const SANA2IOB_MCAST = 5;
pub const SANA2IOF_MCAST: u8 = 1 << SANA2IOB_MCAST;
pub const SANA2IOB_QUICK = 0;
pub const SANA2IOF_QUICK: u8 = exec.IOF_QUICK;

/// OpenDevice's flags: the unit for this opener alone, and every packet
/// on the link rather than only the ones addressed to the unit.
pub const SANA2OPB_MINE = 0;
pub const SANA2OPF_MINE: u32 = 1 << SANA2OPB_MINE;
pub const SANA2OPB_PROM = 1;
pub const SANA2OPF_PROM: u32 = 1 << SANA2OPB_PROM;

/// The tags of ios2_BufferManagement at OpenDevice.
pub const S2_Dummy: u32 = TAG_USER + 0xB0000;
/// ti_Data: a CopyFn that copies a received packet into the opener's
/// buffer (`to` is ios2_Data).
pub const S2_CopyToBuff: u32 = S2_Dummy + 1;
/// ti_Data: a CopyFn that copies a packet to send out of the opener's
/// buffer (`from` is ios2_Data).
pub const S2_CopyFromBuff: u32 = S2_Dummy + 2;
/// ti_Data: a Hook called before a packet is copied to a read, with the
/// request as the object and the packet in the driver's memory as the
/// message; it answers 0 to leave the packet to the next read. It runs on
/// the driver's task while the driver holds its queues, so it only looks
/// and never waits.
pub const S2_PacketFilter: u32 = S2_Dummy + 3;

/// S2_CopyToBuff's and S2_CopyFromBuff's call: copies `length` bytes and
/// answers false if it could not (the request then fails with
/// S2ERR_NO_RESOURCES, S2WERR_BUFF_ERROR).
pub const CopyFn = *const fn (to: ?*anyopaque, from: ?*const anyopaque, length: u32) callconv(.c) bool;

/// The commands after the standard ones.
pub const S2_START: u16 = exec.CMD_NONSTD;
pub const S2_DEVICEQUERY: u16 = S2_START + 0;
pub const S2_GETSTATIONADDRESS: u16 = S2_START + 1;
pub const S2_CONFIGINTERFACE: u16 = S2_START + 2;
pub const S2_ADDMULTICASTADDRESS: u16 = S2_START + 5;
pub const S2_DELMULTICASTADDRESS: u16 = S2_START + 6;
pub const S2_MULTICAST: u16 = S2_START + 7;
pub const S2_BROADCAST: u16 = S2_START + 8;
pub const S2_TRACKTYPE: u16 = S2_START + 9;
pub const S2_UNTRACKTYPE: u16 = S2_START + 10;
pub const S2_GETTYPESTATS: u16 = S2_START + 11;
pub const S2_GETSPECIALSTATS: u16 = S2_START + 12;
pub const S2_GETGLOBALSTATS: u16 = S2_START + 13;
pub const S2_ONEVENT: u16 = S2_START + 14;
pub const S2_READORPHAN: u16 = S2_START + 15;
pub const S2_ONLINE: u16 = S2_START + 16;
pub const S2_OFFLINE: u16 = S2_START + 17;

/// struct Sana2DeviceQuery: what S2_DEVICEQUERY tells about a unit. The
/// caller sets `size_available` to the bytes it has room for; the driver
/// fills what fits and says how much in `size_supplied`.
pub const Sana2DeviceQuery = extern struct {
    /// SizeAvailable
    size_available: u32 = 0,
    /// SizeSupplied
    size_supplied: u32 = 0,
    /// DevQueryFormat: 0, this layout.
    dev_query_format: u32 = 0,
    /// DeviceLevel: 0.
    device_level: u32 = 0,
    /// AddrFieldSize: the bits of a hardware address (48 on Ethernet).
    addr_field_size: u32 = 0,
    /// MTU: the most bytes of one packet, without the link's header.
    mtu: u32 = 0,
    /// BPS: the link's speed in bits per second; what the stack sizes its
    /// buffers and outstanding requests from.
    bps: u64 align(4) = 0,
    /// HardwareType: S2WireType_*.
    hardware_type: u32 = 0,
    /// RawMTU: the most bytes of one frame, header included.
    raw_mtu: u32 = 0,
};

/// HardwareType: the kinds of link.
pub const S2WireType_Ethernet: u32 = 1;
pub const S2WireType_PPP: u32 = 253;
pub const S2WireType_SLIP: u32 = 254;
pub const S2WireType_CSLIP: u32 = 255;

/// struct Sana2PacketTypeStats: S2_GETTYPESTATS, for one tracked type.
/// Every count is 64-bit, so none wraps while the system runs.
pub const Sana2PacketTypeStats = extern struct {
    /// PacketsSent
    packets_sent: u64 align(4) = 0,
    /// PacketsReceived
    packets_received: u64 align(4) = 0,
    /// BytesSent
    bytes_sent: u64 align(4) = 0,
    /// BytesReceived
    bytes_received: u64 align(4) = 0,
    /// PacketsDropped: received with no read of the type to take them.
    packets_dropped: u64 align(4) = 0,
};

/// struct Sana2DeviceStats: S2_GETGLOBALSTATS, for the whole unit. The
/// packet counts are 64-bit, so none wraps while the system runs.
pub const Sana2DeviceStats = extern struct {
    /// PacketsReceived
    packets_received: u64 align(4) = 0,
    /// PacketsSent
    packets_sent: u64 align(4) = 0,
    /// BadData: frames received damaged.
    bad_data: u64 align(4) = 0,
    /// Overruns: frames lost because the receive ring was full.
    overruns: u64 align(4) = 0,
    /// UnknownTypesReceived: packets no read and no orphan read took.
    unknown_types_received: u64 align(4) = 0,
    /// Reconfigurations: how often the link changed under the unit.
    reconfigurations: u32 = 0,
    /// LastStart: the system time the unit last went online.
    last_start: TimeVal = .{},
};

/// struct Sana2SpecialStatHeader: S2_GETSPECIALSTATS. The caller sets
/// `record_count_max`; the records follow the header.
pub const Sana2SpecialStatHeader = extern struct {
    /// RecordCountMax
    record_count_max: u32 = 0,
    /// RecordCountSupplied
    record_count_supplied: u32 = 0,
};

/// struct Sana2SpecialStatRecord: one count the link's kind keeps.
pub const Sana2SpecialStatRecord = extern struct {
    /// Type: S2SS_*, the wire type in the high half.
    type: u32 = 0,
    /// Count
    count: u32 = 0,
    /// String: the count's name, for a program that lists them.
    string: ?[*:0]const u8 = null,
};

/// The special counts of an Ethernet link.
pub const S2SS_ETHERNET_BADMULTICAST: u32 = (S2WireType_Ethernet << 16) | 1;
pub const S2SS_ETHERNET_RETRIES: u32 = (S2WireType_Ethernet << 16) | 2;
pub const S2SS_ETHERNET_FIFO_UNDERRUNS: u32 = (S2WireType_Ethernet << 16) | 3;

/// io_Error of a network device.
pub const S2ERR_NO_ERROR: i8 = 0;
pub const S2ERR_NO_RESOURCES: i8 = 1;
pub const S2ERR_BAD_ARGUMENT: i8 = 3;
pub const S2ERR_BAD_STATE: i8 = 4;
pub const S2ERR_BAD_ADDRESS: i8 = 5;
pub const S2ERR_MTU_EXCEEDED: i8 = 6;
pub const S2ERR_NOT_SUPPORTED: i8 = 8;
pub const S2ERR_SOFTWARE: i8 = 9;
pub const S2ERR_OUTOFSERVICE: i8 = 10;
pub const S2ERR_TX_FAILURE: i8 = 11;

/// ios2_WireError: the detail behind io_Error.
pub const S2WERR_GENERIC_ERROR: u32 = 0;
pub const S2WERR_NOT_CONFIGURED: u32 = 1;
pub const S2WERR_UNIT_ONLINE: u32 = 2;
pub const S2WERR_UNIT_OFFLINE: u32 = 3;
pub const S2WERR_ALREADY_TRACKED: u32 = 4;
pub const S2WERR_NOT_TRACKED: u32 = 5;
pub const S2WERR_BUFF_ERROR: u32 = 6;
pub const S2WERR_SRC_ADDRESS: u32 = 7;
pub const S2WERR_DST_ADDRESS: u32 = 8;
pub const S2WERR_BAD_BROADCAST: u32 = 9;
pub const S2WERR_BAD_MULTICAST: u32 = 10;
pub const S2WERR_MULTICAST_FULL: u32 = 11;
pub const S2WERR_BAD_EVENT: u32 = 12;
pub const S2WERR_BAD_STATDATA: u32 = 13;
pub const S2WERR_IS_CONFIGURED: u32 = 15;
pub const S2WERR_NULL_POINTER: u32 = 16;
pub const S2WERR_TOO_MANY_RETRIES: u32 = 17;
pub const S2WERR_RCVREL_HDW_ERR: u32 = 18;

/// S2_ONEVENT's mask.
pub const S2EVENT_ERROR: u32 = 1 << 0;
pub const S2EVENT_TX: u32 = 1 << 1;
pub const S2EVENT_RX: u32 = 1 << 2;
pub const S2EVENT_ONLINE: u32 = 1 << 3;
pub const S2EVENT_OFFLINE: u32 = 1 << 4;
pub const S2EVENT_BUFF: u32 = 1 << 5;
pub const S2EVENT_HARDWARE: u32 = 1 << 6;
pub const S2EVENT_SOFTWARE: u32 = 1 << 7;
