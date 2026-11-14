// SPDX-License-Identifier: MPL-2.0
//! ps2.resource: the keyboard and the pointing device plugged into a
//! PC's keyboard controller - a laptop's own keyboard and its TrackPoint
//! or touchpad, a desktop's two round sockets - as keys of
//! keyboard.device and moves of mouse.device.
//!
//! The controller is looked for and set up as the resource starts
//! (`port/_port.zig`): a machine without one reads all ones at its ports
//! and is left alone. Its two lines each get a server that takes the
//! byte waiting and wakes the resource's task (`input/task.zig`), which
//! reads the keyboard's bytes as keys (`key/scancode.zig`) and the
//! pointing device's as moves, buttons and a wheel
//! (`pointer/packet.zig`), and hands them to the two devices as a source
//! of each. So a key from this keyboard and one from a USB keyboard are
//! the same key to everything above, and both may be held at once.
//!
//! It has no calls: the resource is on exec's list to say the controller
//! is driven, and its base holds what the servers and the task share.
//! The ROM tag and init are ps2_init.zig, the base ps2_base.zig.

const std = @import("std");
const ps2_init = @import("ps2_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from ps2.resource.
comptime {
    _ = &ps2_init.ps2_resource_tag;
}

/// What the resource is on exec's list as.
pub const RESOURCE_NAME = ps2_init.RESOURCE_NAME;
/// The ROM tag.
pub const ps2_resource_tag = ps2_init.ps2_resource_tag;

test {
    _ = @import("key/scancode.zig");
    _ = @import("pointer/packet.zig");
}
