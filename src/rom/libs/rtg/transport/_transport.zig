// SPDX-License-Identifier: MPL-2.0
//! Command buses: the record of one, and passing transfers to its driver.
//!
//! A bus is made for the driver of the device that sits on it
//! (`OpenTransport`): the transport driver whose table names the device's
//! bus makes it, from the device's tags, in a handle the library
//! allocates. The panel's driver keeps it, talks over it (`TxParam`,
//! `TxColor`, `RxParam`) and gives it back (`CloseTransport`).

const sdk = @import("sdk");
const rtg = sdk.rtg;

/// What the library keeps for a transport: the handle.
pub const Private = struct {
    io: rtg.RtgTransport = .{},
};

/// The library's own record around a transport's handle.
///
/// INPUTS:
/// - `io` - the transport.
pub fn privateOf(io: *rtg.RtgTransport) *Private {
    return @fieldParentPtr("io", io);
}
