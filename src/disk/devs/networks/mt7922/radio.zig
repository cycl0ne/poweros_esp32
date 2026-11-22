// SPDX-License-Identifier: MIT
//! The radio: what the chip receives besides the answers to commands,
//! the events the firmware sends by itself, and the unit's requests.
//!
//! The station is not on any network yet: frames that come in are
//! dropped, the wireless requests are answered as out of service, and the
//! rest go to the unit.

const sdk = @import("sdk");
const net = sdk.devices.network;
const wireless = sdk.devices.wireless;
const _mt = @import("_mt7922.zig");
const Work = _mt.Work;

/// A buffer the chip filled that is not an event: a frame, a send's
/// status, a note of frames sent.
pub fn received(work: *Work, kind: u32, bytes: []const u8) void {
    _ = work;
    _ = kind;
    _ = bytes;
}

/// An event the firmware sent by itself.
pub fn event(work: *Work, eid: u8, bytes: []const u8) void {
    _ = work;
    _ = eid;
    _ = bytes;
}

/// A request of the unit's openers.
pub fn request(work: *Work, req: *net.IOSana2Req) void {
    const base = work.base;
    switch (req.req.command) {
        wireless.S2_GETNETWORKS, wireless.S2_SETOPTIONS, wireless.S2_GETNETWORKINFO, wireless.S2_GETSIGNALQUALITY => {
            req.req.err = net.S2ERR_OUTOFSERVICE;
            req.wire_error = net.S2WERR_UNIT_OFFLINE;
            base.sys_base.ReplyMsg(&req.req.message);
        },
        else => base.net.perform(req),
    }
}
