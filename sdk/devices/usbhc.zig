// SPDX-License-Identifier: MIT
//! A USB host controller device's commands (`DEVIF_USBHC`): what
//! usb.library sends the controller of a bus, whichever controller it is.
//! usbotg.device speaks it for the chip's DWC2; another controller - one
//! on SPI, a PCI one - is another device speaking the same.
//!
//! **A request is one transfer** to one endpoint of one device: an
//! `IOUsbHC`, which says everything the controller needs - the device's
//! address and speed, the endpoint and its packet size, the hub a low- or
//! full-speed device hangs off - so the controller keeps no table of
//! devices. A control transfer carries its setup packet; the data is
//! `io_Data` and `io_Length`, and `io_Actual` says what was moved.
//!
//! **The data toggle is the request's**: `toggle` says which DATA0/DATA1
//! the endpoint is at, and the controller leaves it where the endpoint is
//! after the transfer. A pipe that keeps sending the same request keeps
//! the endpoint's toggle without anyone counting.
//!
//! **The root port is a hub.** The controller answers control transfers
//! to its root hub - at address 0 until the root hub has been given one
//! with SET_ADDRESS - with a hub's descriptors and its port's status, and
//! an interrupt transfer to the root hub's endpoint 1 when the port
//! changes; so the bus's software has one hub driver for the root and for
//! every hub plugged in.
//!
//! An interrupt transfer is asked again every `interval` milliseconds
//! until the device answers, and is replied only then: a read of a
//! keyboard waits like any read. A controller may ask one that has had
//! nothing for a while less often, a few milliseconds apart.
//!
//! **An isochronous transfer** is a run of packets at the endpoint's
//! interval, one each interval, at most `UHC_ISO_PACKETS` of them:
//! `io_Length` bytes cut into packets of `iso_packet`, the last taking
//! what is left - or, with `iso_list`, `iso_count` packets each of its
//! own length, lying one after the other in `io_Data`. Nothing is resent
//! and nothing waits for an answer - a packet has its time and is gone -
//! and a request is replied once its last packet's time has passed.
//!
//! **A packet is an interval's bytes**: at most `max_packet`, or where
//! the endpoint moves more in an interval - a high-speed one with more
//! transactions a microframe, a SuperSpeed one with bursts (`burst`,
//! `mult`) - at most its `interval_bytes`, which the controller sends as
//! the wire's packets. A controller that moves one wire packet an
//! interval (usbotg.device) answers a bigger packet IOERR_BADLENGTH.
//!
//! **A SuperSpeed bulk endpoint may have streams**: `streams` says how
//! many - IDs 1 to that - and `stream` which one a transfer goes on. Each
//! stream is a queue of its own on the endpoint, a transfer on one
//! waiting only for those before it on the same, and the device picks
//! the stream it moves data on next. A controller without streams, or
//! whose stream arrays are too small for the one named, answers
//! UHIOERR_HOSTERROR.
//!
//! **A SuperSpeed link may rest** in U1 or U2 while it has nothing to
//! move, as usb.library sets it up. The SET_SEL it sends such a device
//! carries `exit_latency`, the longest the links on the way to it take to
//! come back: a controller that schedules by it takes it first, and one
//! that cannot allow for that much answers the SET_SEL UHIOERR_HOSTERROR
//! without sending it on. A root hub of USB 3 ports answers a BOS with
//! its ports' own exit latencies, and takes PORT_U1_TIMEOUT and
//! PORT_U2_TIMEOUT on them as a SuperSpeed hub does.
//!
//! **A lost packet is a result, not an error.** The request is answered
//! with io_Error 0 whatever became of its packets: `io_Actual` is the
//! bytes that went or came, `iso_lost` the packets that did not, and a
//! list has each packet's own `actual` and `status` (UHIOERR_MISSED for
//! one whose time passed before the controller had it). io_Error is for
//! the request as a whole: the device gone, the request taken back, an
//! endpoint the bus has no time for (UHIOERR_BANDWIDTH).
//!
//! **Each packet has its frame.** Requests sent one after the other
//! follow on with no gap: each starts in the interval after the last
//! packet of the one before, so a controller with the next one before
//! the last has ended plays an unbroken stream. One sent to an idle
//! endpoint starts as soon as the controller can place it, and one with
//! `UHF_ISO_FRAME` in the frame `iso_frame` names. Every request is
//! answered with the frame it started in (`iso_frame`) and the frames the
//! endpoint went without since the request before it ended (`iso_gap`):
//! a stream that ran dry shows there by how much. A controller takes
//! several at once on an endpoint; AbortIO of one on the wire takes back
//! every one on that endpoint, each answered IOERR_ABORTED, and the next
//! request starts a new stream, with no gap counted.
//!
//! **Bus time is the controller's to give.** The bus keeps most of each
//! frame for isochronous and interrupt endpoints, and the controller adds
//! an endpoint only while that has room for it; one it cannot fit is
//! refused with UHIOERR_BANDWIDTH on its first transfer. usb.library
//! keeps no account of its own.

const exec = @import("../libs/exec/exec.zig");
const descriptors = @import("../libs/usb/descriptors.zig");

/// A control transfer: the setup packet in `setup`, the data stage's
/// direction its `request_type`'s, `io_Length` its bytes (at most the
/// setup's `length`).
pub const UHCMD_CONTROLXFER: u16 = exec.CMD_NONSTD + 0;
/// A bulk transfer, its direction the endpoint's.
pub const UHCMD_BULKXFER: u16 = exec.CMD_NONSTD + 1;
/// An interrupt transfer: asked every `interval` ms until answered.
pub const UHCMD_INTXFER: u16 = exec.CMD_NONSTD + 2;
/// An isochronous transfer: packets of `iso_packet` bytes, or as
/// `iso_list` says, one each interval, its direction the endpoint's. A
/// controller that has none answers IOERR_NOCMD.
pub const UHCMD_ISOXFER: u16 = exec.CMD_NONSTD + 3;
/// The controller started afresh: every transfer answered
/// UHIOERR_HOSTERROR, the root port powered and empty.
pub const UHCMD_USBRESET: u16 = exec.CMD_NONSTD + 4;
/// The bus suspended and resumed: IOERR_NOCMD until a controller does it.
pub const UHCMD_USBSUSPEND: u16 = exec.CMD_NONSTD + 5;
pub const UHCMD_USBRESUME: u16 = exec.CMD_NONSTD + 6;
/// What the controller is: a `USBHCInfo` into `io_Data`, `io_Length` its
/// size (a shorter one gets as much as fits).
pub const UHCMD_QUERYDEVICE: u16 = exec.CMD_NONSTD + 7;

// io_Error: the IOERR_* of exec, or one of these.
/// The device did not answer within `nak_timeout` ms.
pub const UHIOERR_NAKTIMEOUT: i8 = 1;
/// A transfer kept failing on the wire: a bad CRC, a bit-stuffing error,
/// no answer at all, three times running.
pub const UHIOERR_CRCERROR: i8 = 2;
/// The endpoint stalled: it refused the request, or is halted until its
/// halt is cleared.
pub const UHIOERR_STALL: i8 = 3;
/// The controller gave up on the transfer.
pub const UHIOERR_TIMEOUT: i8 = 4;
/// The device sent more than was asked for.
pub const UHIOERR_OVERFLOW: i8 = 5;
/// The controller could not do it: its DMA could not reach the memory,
/// it has no such stream, it cannot allow for a SET_SEL's exit latency,
/// it was reset under the transfer, or the transfer's endpoint was added
/// afresh or dropped under it.
pub const UHIOERR_HOSTERROR: i8 = 6;
/// The device is gone.
pub const UHIOERR_DETACHED: i8 = 7;
/// A short packet ended the transfer, and `flags` said that is an error.
pub const UHIOERR_RUNTPACKET: i8 = 8;
/// An isochronous packet's time passed before the controller had it: it
/// did not go, or nothing was taken - a packet's `status`. As io_Error:
/// the frame UHF_ISO_FRAME asked for could not be had, and nothing went.
pub const UHIOERR_MISSED: i8 = 9;
/// The bus has no time left for the endpoint in its frames: the
/// isochronous and interrupt endpoints already on it take it.
pub const UHIOERR_BANDWIDTH: i8 = 10;

/// The most packets an isochronous transfer carries.
pub const UHC_ISO_PACKETS: u32 = 32;
/// USB frame numbers run 0 to 2047, a millisecond each, and start again.
pub const UHC_FRAMES: u16 = 2048;

/// `speed`: how fast the device is. At SuperSpeed (5 Gbit/s and above)
/// endpoint 0's packet is 512 bytes, bMaxPacketSize0 its exponent (9).
pub const USB_SPEED_LOW: u8 = 0;
pub const USB_SPEED_FULL: u8 = 1;
pub const USB_SPEED_HIGH: u8 = 2;
pub const USB_SPEED_SUPER: u8 = 3;

/// `flags`: a short packet is an error (UHIOERR_RUNTPACKET).
pub const UHF_SHORT_NOT_OK: u8 = 1 << 0;
/// `flags`: an OUT transfer whose length is a whole number of packets is
/// ended with an empty one.
pub const UHF_ZERO_PACKET: u8 = 1 << 1;
/// `flags`: an isochronous transfer starts in the frame `iso_frame`
/// names, the next time it comes. One the controller can no longer place
/// in time - too soon, or more than `UHC_ISO_AHEAD` frames off - is
/// answered UHIOERR_MISSED, and nothing goes.
pub const UHF_ISO_FRAME: u8 = 1 << 2;
/// The furthest ahead an isochronous transfer can be placed, in frames.
pub const UHC_ISO_AHEAD: u16 = 895;

/// One packet of an isochronous transfer, in its `iso_list`.
pub const UsbIsoPacket = extern struct {
    /// Its bytes: those sent (OUT), the room for those that come (IN); at
    /// most the endpoint's bytes an interval (`interval_bytes`, else its
    /// max packet size).
    length: u16 = 0,
    /// Written by the controller: the bytes that went or came.
    actual: u16 = 0,
    /// Written by the controller: 0, or how the packet was lost -
    /// UHIOERR_MISSED, UHIOERR_CRCERROR (it came damaged or not at all),
    /// UHIOERR_OVERFLOW (the device sent more), UHIOERR_HOSTERROR.
    status: i8 = 0,
    pad: [3]u8 = @splat(0),
};

/// A transfer for a host controller device.
pub const IOUsbHC = extern struct {
    /// The request with the standard fields: io_Data and io_Length the
    /// data, io_Actual what was moved. io_Offset is not used.
    std: exec.IOStdReq = .{},
    /// The setup packet of a control transfer.
    setup: descriptors.SetupPacket = .{ .request_type = 0, .request = 0, .value = 0, .index = 0, .length = 0 },
    /// The device's address, 0 to 127.
    address: u8 = 0,
    /// bEndpointAddress: the number, with USB_DIR_IN for one that sends.
    /// A control transfer's is 0; its direction is the setup packet's.
    endpoint: u8 = 0,
    /// USB_SPEED_*.
    speed: u8 = USB_SPEED_FULL,
    /// UHF_*.
    flags: u8 = 0,
    /// The endpoint's max packet size.
    max_packet: u16 = 8,
    /// An interrupt or isochronous endpoint's interval, in milliseconds.
    interval: u16 = 10,
    /// The transaction translator a low- or full-speed device is reached
    /// through: the high-speed hub it hangs off - straight, or behind
    /// full-speed hubs - and that hub's port it is on, toward which the
    /// controller sends split transactions. 0, 0 for a device reached at
    /// its own speed: a high-speed one, or any on a root port that runs
    /// at full speed, where a low-speed device behind a full-speed hub
    /// is reached with a preamble.
    hub_address: u8 = 0,
    hub_port: u8 = 0,
    /// The data toggle the endpoint is at, 0 or 1: the next packet's.
    /// The controller leaves it where the endpoint is after the transfer.
    toggle: u8 = 0,
    pad: u8 = 0,
    /// Milliseconds a device may keep answering NAK before the transfer
    /// ends with UHIOERR_NAKTIMEOUT; 0: no limit.
    nak_timeout: u32 = 0,
    /// An isochronous transfer's packets: the bytes of each but the
    /// last, at most the endpoint's bytes an interval; 0 is `max_packet`.
    iso_packet: u32 = 0,
    /// The controller's, while it has the request.
    hc_private: [4]usize = @splat(0),
    /// An isochronous transfer's packets one by one: `iso_count` of them,
    /// each of its own length, and written back with what became of it.
    /// Null: `io_Length` cut into `iso_packet`s.
    iso_list: ?[*]UsbIsoPacket = null,
    iso_count: u16 = 0,
    /// The USB frame number the transfer's first packet goes in: with
    /// UHF_ISO_FRAME the one asked for; written back with the one it
    /// started in.
    iso_frame: u16 = 0,
    /// Written back: the packets that did not go or did not come, and the
    /// frames the endpoint went without between the request before this
    /// one and this one - 0 when it followed on, or starts a stream.
    iso_lost: u16 = 0,
    iso_gap: u16 = 0,
    /// The wire packets of a burst less one: at SuperSpeed the endpoint
    /// companion's bMaxBurst, at high speed an interrupt or isochronous
    /// endpoint's more transactions a microframe (wMaxPacketSize bits
    /// 12:11); 0 elsewhere.
    burst: u8 = 0,
    /// A SuperSpeed isochronous endpoint's bursts an interval less one
    /// (its companion's Mult); 0 elsewhere.
    mult: u8 = 0,
    /// An interrupt or isochronous endpoint's bytes an interval: its
    /// companion's wBytesPerInterval at SuperSpeed, (burst + 1) packets
    /// at high speed; 0 for one packet's.
    interval_bytes: u16 = 0,
    /// A SuperSpeed bulk endpoint's streams, IDs 1 to `streams` (0: it
    /// has none, or the transfer does not use them), and the one the
    /// transfer goes on.
    streams: u16 = 0,
    stream: u16 = 0,
    /// On a SET_SEL: the longest the links from the controller to the
    /// device take to come back from U1 or U2, in µs (its MEL); 0
    /// elsewhere.
    exit_latency: u16 = 0,
};

/// What `UHCMD_QUERYDEVICE` answers.
pub const USBHCInfo = extern struct {
    /// The controller's name ("dwc2"), a C string the device keeps.
    name: ?[*:0]const u8 = null,
    /// USB_SPEED_*: the fastest it runs its root port at now.
    speed: u32 = 0,
    /// Transfers it can have on the wire at once.
    channels: u32 = 0,
    /// Its root hub's ports.
    ports: u32 = 0,
    /// The USB frame number as it answered, for a transfer placed in a
    /// frame of its own (UHF_ISO_FRAME); 0 from a controller without
    /// isochronous transfers.
    frame: u32 = 0,
};
