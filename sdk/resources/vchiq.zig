// SPDX-License-Identifier: MIT
//! vchiq.resource: the message queue the VideoCore's firmware keeps with
//! the ARM on the Raspberry Pi's BCM2711 - the Compute Module 4's
//! CHIP_BCM2711_VCHIQ. The firmware runs what the ARM cannot reach itself
//! behind it, as services: MMAL ("mmal"), whose components decode H.264
//! and JPEG in the chip's hardware, and scale and convert pictures in its
//! ISP. A machine without the part has no vchiq.resource.
//!
//! A service is opened by its four-character name and the version of its
//! protocol the caller speaks (OpenService); the first opening connects
//! with the firmware. Messages of up to VCHIQ_MAX_MESSAGE bytes go to it
//! (SendMessage) and come from it (ReceiveMessage) in order. What is too
//! large for a message goes as a bulk transfer (QueueBulk, WaitBulk): the
//! firmware itself reads the caller's memory, or writes into it, and the
//! bulks of one direction are matched with the firmware's in the order
//! they are queued. A service is used by one task at a time; several may
//! be open at once.
//!
//! Get its base with OpenResource(VCHIQNAME); its functions are in
//! sdk/interface/vchiq.zig.

const exec = @import("../libs/exec/exec.zig");

/// The resource's name, for OpenResource.
pub const VCHIQNAME = "vchiq.resource";

/// A service's name as the firmware has it: its four characters, the
/// first in the top byte ("mmal" is 0x6D6D616C).
pub fn fourcc(name: *const [4]u8) u32 {
    return @as(u32, name[0]) << 24 | @as(u32, name[1]) << 16 | @as(u32, name[2]) << 8 | name[3];
}

/// The most bytes one message holds.
pub const VCHIQ_MAX_MESSAGE: u32 = 4088;

/// What the calls answer: done.
pub const VCHIQERR_OK: u32 = 0;
/// There is no firmware to talk to: the board lists no VCHIQ, the kernel
/// kept it no memory, or the firmware did not take the queue or did not
/// connect.
pub const VCHIQERR_NO_FIRMWARE: u32 = 1;
/// The firmware has no such service, or not in a version the caller
/// speaks.
pub const VCHIQERR_REFUSED: u32 = 2;
/// The firmware closed the service.
pub const VCHIQERR_CLOSED: u32 = 3;
/// The time given ran out first.
pub const VCHIQERR_TIMEOUT: u32 = 4;
/// A message larger than VCHIQ_MAX_MESSAGE or empty, or a bulk with no
/// bytes or more than the resource describes at once.
pub const VCHIQERR_SIZE: u32 = 5;
/// No memory for it.
pub const VCHIQERR_NO_MEMORY: u32 = 6;
/// No room: every service is open, or as many bulks of that direction
/// are out as the queue allows (VCHIQ_MAX_BULKS).
pub const VCHIQERR_BUSY: u32 = 7;
/// The firmware gave up a bulk before it was done: the service was
/// closed.
pub const VCHIQERR_ABORTED: u32 = 8;

/// How many bulks of one direction a service may have out at once.
pub const VCHIQ_MAX_BULKS: u32 = 4;

/// A bulk's direction: the firmware reads the caller's memory.
pub const VCHIQBULK_TRANSMIT: u32 = 0;
/// A bulk's direction: the firmware writes into it.
pub const VCHIQBULK_RECEIVE: u32 = 1;

/// A service, as OpenService gives it: the resource's.
pub const VchiqService = opaque {};

/// A bulk transfer, the caller's own until WaitBulk answered or `done`
/// was signalled. `data` is `size` bytes of memory in one piece, as
/// AllocMem gives it; what the firmware writes is best in memory of its
/// own on 64-byte boundaries, as the ends of anything else in the same
/// 64-byte lines must not be touched while it is out. `actual` is the
/// bytes moved once it is done. The rest is the resource's.
pub const VchiqBulk = extern struct {
    data: ?*anyopaque = null,
    size: u32 = 0,
    direction: u32 = VCHIQBULK_TRANSMIT,
    actual: u32 = 0,
    /// VCHIQERR_OK once done, VCHIQERR_ABORTED when the firmware gave it
    /// up.
    result: u32 = VCHIQERR_OK,
    /// Signalled when it is done or given up: what to wait on beside
    /// others (WaitForAny); WaitBulk waits on it alone.
    done: exec.Waitable = .{},
    private: [4]usize = @splat(0),
};

/// The resource's base, with its functions.
pub const VchiqBase = @import("../interface/vchiq.zig").VchiqBase;
