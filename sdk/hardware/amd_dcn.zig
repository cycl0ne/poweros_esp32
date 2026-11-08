// SPDX-License-Identifier: MIT
//! The registers of an AMD graphics device's display engine (DCN 3.1.4)
//! that are shared between its driver and the tests that try it: a
//! pipe's timing generator (OTG), a fetcher's surface and flip (HUBP), by
//! the kernel's dcn_3_1_4_offset.h names. Counted in 32-bit words from
//! the engine's third segment - FindGPUBlock(GPUBLOCK_DISPLAY)'s
//! `addresses[2]` - a pipe's and a fetcher's set each its stride apart; a
//! register is at `registers + (segment + offset + stride * n) * 4`.
//!
//! Only names and numbers: nothing here touches the hardware.

// --- a pipe's timing generator -------------------------------------------------------

pub const OTG_STRIDE: u32 = 0x80;
/// The frames the pipe has scanned, counting.
pub const OTG_STATUS_FRAME_COUNT: u32 = 0x1b4c;
/// The points in a frame that can raise an interrupt, each with its
/// switch, its note that it came, and the bit that clears the note.
pub const OTG_GLOBAL_SYNC_STATUS: u32 = 0x1b89;
/// The point at which the pipe takes up what its double-buffered
/// registers were told - a flip's address among them - whatever their
/// lock says: once a frame, and never masked.
pub const VUPDATE_NO_LOCK_INT_EN: u32 = 1 << 12;
pub const VUPDATE_NO_LOCK_EVENT_OCCURRED: u32 = 1 << 14;
pub const VUPDATE_NO_LOCK_EVENT_CLEAR: u32 = 1 << 16;

// --- a fetcher ---------------------------------------------------------------------------

pub const HUBP_STRIDE: u32 = 0xdc;
/// How far apart the rows of the surface read are, in pixels less one.
pub const DCSURF_SURFACE_PITCH: u32 = 0x0607;
pub const PITCH_MASK: u32 = 0x3fff;
/// The device's address of the surface read: written high word first,
/// the low word's write arming the flip.
pub const DCSURF_PRIMARY_SURFACE_ADDRESS: u32 = 0x060a;
pub const DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH: u32 = 0x060b;
pub const ADDRESS_HIGH_MASK: u32 = 0xffff;
/// How a new address is taken up, and whether one is still waiting to
/// be.
pub const DCSURF_FLIP_CONTROL: u32 = 0x061b;
pub const SURFACE_UPDATE_LOCK: u32 = 1 << 0;
/// Set: at once, wherever the scan is. Clear: at the pipe's next update
/// point, between frames.
pub const SURFACE_FLIP_TYPE: u32 = 1 << 1;
pub const SURFACE_FLIP_PENDING: u32 = 1 << 8;
/// The address the fetcher reads now.
pub const DCSURF_SURFACE_EARLIEST_INUSE: u32 = 0x0625;
pub const DCSURF_SURFACE_EARLIEST_INUSE_HIGH: u32 = 0x0626;
