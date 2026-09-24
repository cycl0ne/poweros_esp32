// SPDX-License-Identifier: MPL-2.0
//! Command buses: making one, and passing transfers to its driver.
//!
//! A transport is made the same way a board is - a driver by name, a tag
//! list, a handle the library allocates and the driver fills in - and a
//! board is given one at create. It is refused deletion while a board
//! still names it, since a board with a bus that has gone would talk into
//! nothing.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const tags = rtg.tags;

const RtgBase = @import("../rtg.zig").RtgBase;
const registry = @import("../driver/_driver.zig");

/// What the library keeps for a transport, beside the handle.
pub const Private = struct {
    io: rtg.RtgTransport = .{},
    name_buf: [32]u8 = .{0} ** 32,
};

/// The library's own record around a transport's handle.
///
/// INPUTS:
/// - `io` - the transport.
pub fn privateOf(io: *rtg.RtgTransport) *Private {
    return @fieldParentPtr("io", io);
}

/// Names a transport: the caller's name, or else the driver's.
///
/// INPUTS:
/// - `rb` - the library. Its `Strlcpy` does the copy.
/// - `private` - the transport's record.
/// - `driver_name` - the driver's name.
/// - `wanted` - the caller's name for it, or null.
pub fn setName(rb: *RtgBase, private: *Private, driver_name: [*:0]const u8, wanted: ?[*:0]const u8) void {
    _ = rb.utility_base.Strlcpy(&private.name_buf, private.name_buf.len, wanted orelse driver_name);
    private.io.node.name = @ptrCast(&private.name_buf);
}
