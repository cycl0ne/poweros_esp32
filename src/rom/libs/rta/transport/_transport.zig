// SPDX-License-Identifier: MPL-2.0
//! Lines: making one, and passing its stream to its driver.
//!
//! A line is made the way a sink is - a driver by name, a tag list, a
//! handle the library allocates and the driver fills in - and a sink is
//! given one at create. It is refused deletion while a sink still names
//! it, since a sink whose line has gone would play into nothing. Its
//! stream calls are the sink driver's: the sink starts its line from its
//! own start, at the point its part wants the clocks.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;

/// What the library keeps for a line, beside the handle.
pub const Private = struct {
    io: rta.AudioTransport = .{},
    name_buf: [32]u8 = .{0} ** 32,
};

/// The library's own record around a line's handle.
///
/// INPUTS:
/// - `io` - the line.
pub fn privateOf(io: *rta.AudioTransport) *Private {
    return @fieldParentPtr("io", io);
}

/// Whether the line has been started and not stopped.
///
/// INPUTS:
/// - `io` - the line.
pub fn running(io: *const rta.AudioTransport) bool {
    return io.flags & rta.transport.AUDIOTF_RUNNING != 0;
}
