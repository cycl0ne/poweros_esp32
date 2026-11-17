// SPDX-License-Identifier: MPL-2.0
//! vchiq.resource: the message queue the VideoCore's firmware keeps with
//! the ARM on the BCM2711 (the Compute Module 4), through which its
//! services are reached - MMAL, whose components decode H.264 and JPEG in
//! the chip's hardware (videodec.resource and jpeg.resource use it).
//!
//! The queue lives in a block of memory the kernel keeps in the first
//! GiB and maps without caches (PART_SharedMemory): both sides write
//! their messages into slots of their own there, and ring each other's
//! doorbell. `link/_layout.zig` is that memory's layout, `link/_queue.zig`
//! the queue at work - started, written, read by the resource's task, and
//! the bulk transfers the firmware does itself.
//!
//! Each call is a file of its own under `service/`. The jump table is
//! vchiq_lvo.zig, the ROM tag and init vchiq_init.zig, the base
//! vchiq_base.zig. This file holds the names the rest of the kernel
//! reaches the resource by.

const vchiq_init = @import("vchiq_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from vchiq.resource.
comptime {
    _ = &vchiq_init.vchiq_resource_tag;
}

/// The resource's base.
pub const VchiqBase = @import("vchiq_base.zig").VchiqBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = vchiq_init.RESOURCE_NAME;

test {
    _ = @import("vchiq_lvo.zig");
    _ = @import("link/_queue.zig");
}
