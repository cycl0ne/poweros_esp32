// SPDX-License-Identifier: MIT
//! Host tests of xhci.device's parts that need no controller: the rings
//! and their cycle bits (ring.zig), a configuration's endpoints and their
//! intervals (slots.zig), a root port's PORTSC as a hub's port status
//! (roothub.zig), the contexts' words (regs.zig), and where an
//! isochronous request's packets lie (slots.zig, transfer.zig).

const std = @import("std");
const sdk = @import("sdk");
const d = sdk.usb.descriptors;
const regs = @import("../regs.zig");
const ring = @import("../ring.zig");
const slots = @import("../slots.zig");
const roothub = @import("../roothub.zig");
const transfer = @import("../transfer.zig");
const _xhci = @import("../_xhci.zig");

const testing = std.testing;
const Trb = ring.Trb;

test "a ring the driver fills hands over its Link and flips its cycle at the end" {
    var trbs: [4]Trb align(64) = undefined;
    var r = ring.Ring{};
    r.init(&trbs);
    const start = @intFromPtr(&trbs[0]);
    // The Link at the end points back to the start, not yet handed over.
    try testing.expectEqual(@as(u64, start), trbs[3].param());
    try testing.expectEqual(regs.TRB_LINK, regs.trbType(trbs[3].control));
    try testing.expect(trbs[3].control & regs.TRB_TC != 0);
    try testing.expect(trbs[3].control & regs.TRB_CYCLE == 0);
    try testing.expectEqual(@as(u64, start | 1), r.dequeuePointer());

    const noop = Trb{ .control = regs.typeField(regs.TRB_NOOP) };
    try testing.expectEqual(start, r.push(noop));
    _ = r.push(noop);
    try testing.expect(trbs[0].control & regs.TRB_CYCLE != 0);
    // The third TRB is the last before the Link: the Link is handed
    // over with it, and the ring goes round with its cycle flipped.
    _ = r.push(.{ .control = regs.typeField(regs.TRB_NORMAL) | regs.TRB_CHAIN });
    try testing.expect(trbs[3].control & regs.TRB_CYCLE != 0);
    try testing.expect(trbs[3].control & regs.TRB_CHAIN != 0);
    try testing.expectEqual(@as(u32, 0), r.enqueue);
    try testing.expectEqual(@as(u32, 0), r.cycle);
    try testing.expectEqual(@as(u64, start), r.dequeuePointer());

    // Round again: TRBs go with cycle 0, the Link loses its chain bit.
    try testing.expectEqual(start, r.push(noop));
    try testing.expect(trbs[0].control & regs.TRB_CYCLE == 0);
    _ = r.push(noop);
    _ = r.push(noop);
    try testing.expect(trbs[3].control & regs.TRB_CYCLE == 0);
    try testing.expect(trbs[3].control & regs.TRB_CHAIN == 0);
    try testing.expectEqual(@as(u32, 1), r.cycle);
}

test "a ring emptied again starts afresh at cycle 1" {
    var trbs: [4]Trb align(64) = undefined;
    var r = ring.Ring{};
    r.init(&trbs);
    _ = r.push(.{});
    _ = r.push(.{});
    _ = r.push(.{});
    r.reset();
    try testing.expectEqual(@as(u32, 0), r.enqueue);
    try testing.expectEqual(@as(u32, 1), r.cycle);
    try testing.expect(trbs[0].control == 0);
    try testing.expectEqual(regs.TRB_LINK, regs.trbType(trbs[3].control));
}

test "the event ring takes what matches its cycle, and flips it going round" {
    var trbs: [2]Trb align(64) = undefined;
    var e = ring.EventRing{};
    e.init(&trbs);
    try testing.expect(e.peek() == null);
    trbs[0] = .{ .param_lo = 0x1234, .status = regs.CC_SUCCESS << 24, .control = regs.typeField(regs.TRB_COMMAND_COMPLETION) | 1 };
    const event = e.peek().?;
    try testing.expectEqual(@as(u64, 0x1234), event.param());
    try testing.expectEqual(regs.CC_SUCCESS, regs.completionCode(event.status));
    e.advance();
    try testing.expectEqual(@intFromPtr(&trbs[1]), e.dequeueAddress());
    trbs[1].control = 1;
    try testing.expect(e.peek() != null);
    e.advance();
    // Round: the old events with cycle 1 are not taken again.
    try testing.expectEqual(@as(u32, 0), e.cycle);
    try testing.expect(e.peek() == null);
    trbs[0].control = regs.typeField(regs.TRB_PORT_STATUS_CHANGE);
    try testing.expectEqual(regs.TRB_PORT_STATUS_CHANGE, regs.trbType(e.peek().?.control));
}

test "an endpoint's context index" {
    try testing.expectEqual(@as(u32, 1), regs.dciOf(0x00));
    try testing.expectEqual(@as(u32, 1), regs.dciOf(0x80));
    try testing.expectEqual(@as(u32, 2), regs.dciOf(0x01));
    try testing.expectEqual(@as(u32, 3), regs.dciOf(0x81));
    try testing.expectEqual(@as(u32, 31), regs.dciOf(0x8F));
}

test "an interrupt endpoint's interval as an exponent of 125 us" {
    // Full and low speed: frames, at least 1 ms, at most 128 ms.
    try testing.expectEqual(@as(u32, 3), slots.intervalOf(regs.SPEED_FULL, 1));
    try testing.expectEqual(@as(u32, 6), slots.intervalOf(regs.SPEED_LOW, 10));
    try testing.expectEqual(@as(u32, 10), slots.intervalOf(regs.SPEED_FULL, 255));
    try testing.expectEqual(@as(u32, 3), slots.intervalOf(regs.SPEED_FULL, 0));
    // High speed: 2^(bInterval - 1) microframes.
    try testing.expectEqual(@as(u32, 0), slots.intervalOf(regs.SPEED_HIGH, 1));
    try testing.expectEqual(@as(u32, 11), slots.intervalOf(regs.SPEED_HIGH, 12));
    try testing.expectEqual(@as(u32, 15), slots.intervalOf(regs.SPEED_HIGH, 30));
    // From milliseconds, as a request has it.
    try testing.expectEqual(@as(u32, 3), slots.intervalOfMs(regs.SPEED_FULL, 1));
    try testing.expectEqual(@as(u32, 6), slots.intervalOfMs(regs.SPEED_FULL, 8));
    try testing.expectEqual(@as(u32, 6), slots.intervalOfMs(regs.SPEED_HIGH, 12));
}

/// A keyboard's configuration: a boot keyboard's interface with its
/// interrupt IN, a second setting with an endpoint of its own, and a
/// second interface with an interrupt OUT and an isochronous endpoint.
const keyboard_config = [_]u8{
    9, d.USB_DT_CONFIG, 9 + 9 + 9 + 7 + 9 + 7 + 9 + 7 + 7, 0, 2, 1, 0, 0xA0, 50,
    9, d.USB_DT_INTERFACE, 0, 0, 1, 3, 1, 1, 0,
    9, d.USB_DT_HID, 0x11, 0x01, 0, 1, d.USB_DT_REPORT, 63, 0,
    7, d.USB_DT_ENDPOINT, 0x81, d.USB_ENDPOINT_XFER_INT, 8, 0, 10,
    9, d.USB_DT_INTERFACE, 0, 1, 1, 3, 0, 0, 0,
    7, d.USB_DT_ENDPOINT, 0x83, d.USB_ENDPOINT_XFER_INT, 16, 0, 1,
    9, d.USB_DT_INTERFACE, 1, 0, 2, 3, 0, 0, 0,
    7, d.USB_DT_ENDPOINT, 0x02, d.USB_ENDPOINT_XFER_INT, 0x40, 0, 4,
    7, d.USB_DT_ENDPOINT, 0x84, d.USB_ENDPOINT_XFER_ISOC, 0x00, 0x02, 1,
};

test "a configuration's endpoints: every first setting's, no isochronous one" {
    var specs: [32]slots.Spec = @splat(.{});
    const found = slots.endpointsOf(&keyboard_config, 1, regs.SPEED_LOW, &specs);
    try testing.expectEqual(regs.addFlag(3) | regs.addFlag(4), found);
    try testing.expectEqual(regs.EP_INTERRUPT_IN, specs[3].kind);
    try testing.expectEqual(@as(u32, 8), specs[3].max_packet);
    try testing.expectEqual(@as(u32, 6), specs[3].interval);
    try testing.expectEqual(regs.EP_INTERRUPT_OUT, specs[4].kind);
    try testing.expectEqual(@as(u32, 64), specs[4].max_packet);
    try testing.expectEqual(@as(u32, 5), specs[4].interval);
    // Another configuration's value: none of these.
    try testing.expectEqual(@as(u32, 0), slots.endpointsOf(&keyboard_config, 2, regs.SPEED_LOW, &specs));
    // Cut short: what is whole is taken.
    try testing.expectEqual(regs.addFlag(3), slots.endpointsOf(keyboard_config[0 .. 9 + 9 + 9 + 7 + 3], 1, regs.SPEED_LOW, &specs));
}

test "a bulk pair at high speed" {
    const config = [_]u8{
        9, d.USB_DT_CONFIG, 32, 0, 1, 1, 0, 0x80, 50,
        9, d.USB_DT_INTERFACE, 0, 0, 2, 8, 6, 0x50, 0,
        7, d.USB_DT_ENDPOINT, 0x81, d.USB_ENDPOINT_XFER_BULK, 0x00, 0x02, 0,
        7, d.USB_DT_ENDPOINT, 0x02, d.USB_ENDPOINT_XFER_BULK, 0x00, 0x02, 0,
    };
    var specs: [32]slots.Spec = @splat(.{});
    try testing.expectEqual(regs.addFlag(3) | regs.addFlag(4), slots.endpointsOf(&config, 1, regs.SPEED_HIGH, &specs));
    try testing.expectEqual(regs.EP_BULK_IN, specs[3].kind);
    try testing.expectEqual(regs.EP_BULK_OUT, specs[4].kind);
    try testing.expectEqual(@as(u32, 512), specs[4].max_packet);
    try testing.expectEqual(@as(u32, 0), specs[3].interval);
}

test "a root port's PORTSC as a hub's port status" {
    // A low-speed device, connected and enabled after its reset.
    const low = regs.PORT_CCS | regs.PORT_PED | regs.PORT_PP | regs.SPEED_LOW << regs.PORT_SPEED_SHIFT | regs.PORT_CSC | regs.PORT_PRC;
    const status = roothub.statusOf(low);
    try testing.expectEqual(d.USB_PORT_STAT_CONNECTION | d.USB_PORT_STAT_ENABLE | d.USB_PORT_STAT_POWER | d.USB_PORT_STAT_LOW_SPEED, status.status);
    try testing.expectEqual(d.USB_PORT_STAT_C_CONNECTION | d.USB_PORT_STAT_C_RESET, status.change);
    // A high-speed one, in its reset.
    const high = roothub.statusOf(regs.PORT_CCS | regs.PORT_PR | regs.PORT_PP | regs.SPEED_HIGH << regs.PORT_SPEED_SHIFT);
    try testing.expectEqual(d.USB_PORT_STAT_CONNECTION | d.USB_PORT_STAT_RESET | d.USB_PORT_STAT_POWER | d.USB_PORT_STAT_HIGH_SPEED, high.status);
    // Nothing there, powered: no speed said, the disconnect a change.
    const gone = roothub.statusOf(regs.PORT_PP | regs.PORT_CSC | regs.SPEED_HIGH << regs.PORT_SPEED_SHIFT);
    try testing.expectEqual(d.USB_PORT_STAT_POWER, gone.status);
    try testing.expectEqual(d.USB_PORT_STAT_C_CONNECTION, gone.change);
}

test "PORTSC's neutral write keeps no change bit, PED or PR" {
    try testing.expect(regs.PORT_NEUTRAL & regs.PORT_CHANGES == 0);
    try testing.expect(regs.PORT_NEUTRAL & regs.PORT_PED == 0);
    try testing.expect(regs.PORT_NEUTRAL & regs.PORT_PR == 0);
    try testing.expect(regs.PORT_NEUTRAL & regs.PORT_PP != 0);
}

test "a slot context's words" {
    // Behind a hub on root port 3, port 2 of it, a low-speed device
    // through hub slot 5's TT on port 2.
    try testing.expectEqual(@as(u32, 0x2 | 2 << 20 | 1 << 27), regs.slotWord0(2, regs.SPEED_LOW, false, 1));
    try testing.expectEqual(@as(u32, 3 << 16), regs.slotWord1(3, 0));
    try testing.expectEqual(@as(u32, 5 | 2 << 8), regs.slotWord2(5, 2, 0));
    // A high-speed hub with four ports.
    try testing.expectEqual(@as(u32, 3 << 20 | 1 << 26 | 3 << 27), regs.slotWord0(0, regs.SPEED_HIGH, true, 3));
    try testing.expectEqual(@as(u32, 1 << 16 | 4 << 24), regs.slotWord1(1, 4));
    // Endpoint 0 at 64 bytes; an interrupt IN at 8 bytes, every 8 ms.
    try testing.expectEqual(@as(u32, 3 << 1 | 4 << 3 | 64 << 16), regs.endpointWord1(regs.EP_CONTROL, 0, 64));
    try testing.expectEqual(@as(u32, 6 << 16), regs.endpointWord0(6));
    try testing.expectEqual(@as(u32, 8 | 8 << 16), regs.endpointWord4(8, 8));
}

test "scratchpads are counted from both their fields" {
    try testing.expectEqual(@as(u32, 0), regs.scratchpads(0));
    try testing.expectEqual(@as(u32, 4), regs.scratchpads(4 << 27));
    try testing.expectEqual(@as(u32, 33), regs.scratchpads(1 << 21 | 1 << 27));
}

test "an isochronous endpoint's context: no tries, and its interval in frames" {
    const word = regs.endpointWord1(regs.EP_ISOCH_OUT, 0, 192);
    try testing.expectEqual(@as(u32, 0), (word >> 1) & 3);
    try testing.expectEqual(regs.EP_ISOCH_OUT, (word >> 3) & 7);
    try testing.expectEqual(@as(u32, 192), word >> 16);
    try testing.expectEqual(@as(u32, 3), (regs.endpointWord1(regs.EP_BULK_OUT, 0, 512) >> 1) & 3);
    // A packet every millisecond at full speed: 2^3 x 125 us.
    try testing.expectEqual(@as(u32, 3), slots.intervalOfMs(regs.SPEED_FULL, 1));
}

test "isochronous packets lie a power of two apart, at least a cache line" {
    try testing.expectEqual(@as(u32, 64), slots.strideOf(8));
    try testing.expectEqual(@as(u32, 256), slots.strideOf(192));
    try testing.expectEqual(@as(u32, 1024), slots.strideOf(1023));
}

test "an isochronous request's span on the ring, and how far round it lies" {
    const span = _xhci.spanOf(250, 9, 3);
    try testing.expectEqual(@as(u32, 250), _xhci.spanFirst(span));
    try testing.expectEqual(@as(u32, 9), _xhci.spanLast(span));
    // Past the end and round: a TD at 9 is 15 on from one at 250.
    try testing.expectEqual(@as(u32, 15), transfer.ringDistance(250, 9, 256));
    try testing.expectEqual(@as(u32, 0), transfer.ringDistance(250, 250, 256));
    try testing.expect(transfer.ringDistance(250, 5, 256) < transfer.ringDistance(250, 9, 256));
}
