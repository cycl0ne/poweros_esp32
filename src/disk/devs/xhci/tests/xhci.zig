// SPDX-License-Identifier: MIT
//! Host tests of xhci.device's parts that need no controller: the rings
//! and their cycle bits (ring.zig), a configuration's endpoints, their
//! intervals and SuperSpeed companions (slots.zig), the root ports the
//! root hub has (controller.zig), a root port's PORTSC as a hub's port
//! status and the root hub's BOS (roothub.zig), the contexts' words
//! (regs.zig), where an isochronous
//! request's packets lie and in which frames they go, and what becomes
//! of each (slots.zig, transfer.zig, _xhci.zig).

const std = @import("std");
const sdk = @import("sdk");
const d = sdk.usb.descriptors;
const regs = @import("../regs.zig");
const ring = @import("../ring.zig");
const slots = @import("../slots.zig");
const roothub = @import("../roothub.zig");
const controller = @import("../controller.zig");
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

test "a SuperSpeed bulk pair: each endpoint's burst from its companion" {
    const config = [_]u8{
        9, d.USB_DT_CONFIG, 44, 0, 1, 1, 0, 0x80, 50,
        9, d.USB_DT_INTERFACE, 0, 0, 2, 8, 6, 0x50, 0,
        7, d.USB_DT_ENDPOINT, 0x81, d.USB_ENDPOINT_XFER_BULK, 0x00, 0x04, 0,
        6, d.USB_DT_SS_ENDPOINT_COMP, 15, 0, 0, 0,
        7, d.USB_DT_ENDPOINT, 0x02, d.USB_ENDPOINT_XFER_BULK, 0x00, 0x04, 0,
        6, d.USB_DT_SS_ENDPOINT_COMP, 3, 0, 0, 0,
    };
    var specs: [32]slots.Spec = @splat(.{});
    try testing.expectEqual(regs.addFlag(3) | regs.addFlag(4), slots.endpointsOf(&config, 1, regs.SPEED_SUPER, &specs));
    try testing.expectEqual(@as(u32, 1024), specs[3].max_packet);
    try testing.expectEqual(@as(u32, 15), specs[3].burst);
    try testing.expectEqual(@as(u32, 3), specs[4].burst);
    // A bulk endpoint has no bytes an interval.
    try testing.expectEqual(@as(u32, 0), specs[3].esit);
    // Word 1 of the IN one's context.
    try testing.expectEqual(@as(u32, 15), (regs.endpointWord1(regs.EP_BULK_IN, specs[3].burst, specs[3].max_packet) >> 8) & 0xFF);
}

test "a SuperSpeed interrupt endpoint's bytes an interval; an isochronous one is not added with the configuration" {
    const config = [_]u8{
        9, d.USB_DT_CONFIG, 50, 0, 1, 1, 0, 0x80, 50,
        9, d.USB_DT_INTERFACE, 0, 0, 1, 3, 0, 0, 0,
        7, d.USB_DT_ENDPOINT, 0x81, d.USB_ENDPOINT_XFER_INT, 0x00, 0x04, 4,
        6, d.USB_DT_SS_ENDPOINT_COMP, 1, 0, 0x00, 0x08,
        9, d.USB_DT_INTERFACE, 1, 1, 1, 1, 2, 0, 0,
        7, d.USB_DT_ENDPOINT, 0x82, d.USB_ENDPOINT_XFER_ISOC, 0x00, 0x04, 1,
        6, d.USB_DT_SS_ENDPOINT_COMP, 2, 1, 0x00, 0x30,
    };
    var specs: [32]slots.Spec = @splat(.{});
    try testing.expectEqual(regs.addFlag(3), slots.endpointsOf(&config, 1, regs.SPEED_SUPER, &specs));
    try testing.expectEqual(@as(u32, 1), specs[3].burst);
    try testing.expectEqual(@as(u32, 2048), specs[3].esit);
}

test "a high-speed interrupt endpoint with three transactions a microframe" {
    const config = [_]u8{
        9, d.USB_DT_CONFIG, 25, 0, 1, 1, 0, 0x80, 50,
        9, d.USB_DT_INTERFACE, 0, 0, 1, 3, 0, 0, 0,
        // 1024 bytes, two more transactions (bits 12:11 = 2).
        7, d.USB_DT_ENDPOINT, 0x81, d.USB_ENDPOINT_XFER_INT, 0x00, 0x14, 1,
    };
    var specs: [32]slots.Spec = @splat(.{});
    try testing.expectEqual(regs.addFlag(3), slots.endpointsOf(&config, 1, regs.SPEED_HIGH, &specs));
    try testing.expectEqual(@as(u32, 1024), specs[3].max_packet);
    try testing.expectEqual(@as(u32, 2), specs[3].burst);
    try testing.expectEqual(@as(u32, 3072), specs[3].esit);
    // At full speed the bits mean nothing.
    try testing.expectEqual(@as(u32, 0), (blk: {
        _ = slots.endpointsOf(&config, 1, regs.SPEED_FULL, &specs);
        break :blk specs[3].burst;
    }));
}

test "an isochronous TD's bursts" {
    // SuperSpeed, bursts of 4 (bMaxBurst 3), 1024-byte packets: 10 packets
    // are three bursts, the last of two.
    const ten = regs.isochBurstFields(10 * 1024, 1024, 3, true);
    try testing.expectEqual(@as(u32, 2), (ten >> 7) & 3);
    try testing.expectEqual(@as(u32, 1), (ten >> 16) & 0xF);
    // A whole number of bursts: the last is a whole burst.
    const eight = regs.isochBurstFields(8 * 1024, 1024, 3, true);
    try testing.expectEqual(@as(u32, 1), (eight >> 7) & 3);
    try testing.expectEqual(@as(u32, 3), (eight >> 16) & 0xF);
    // One short packet, and an empty one: a burst of one.
    try testing.expectEqual(@as(u32, 0), regs.isochBurstFields(100, 1024, 3, true));
    try testing.expectEqual(@as(u32, 0), regs.isochBurstFields(0, 1024, 3, true));
    // High speed: one burst, TLBPC the transactions less one.
    const high = regs.isochBurstFields(2500, 1024, 2, false);
    try testing.expectEqual(@as(u32, 0), (high >> 7) & 3);
    try testing.expectEqual(@as(u32, 2), (high >> 16) & 0xF);
    // Mult in word 0.
    try testing.expectEqual(@as(u32, 1 << 16 | 2 << 8), regs.endpointWord0(1, 2, 0));
}

test "the root hub's ports: the USB 2 ones first, then the USB 3 ones" {
    var map: [_xhci.max_root_ports]u8 = undefined;
    var super: u32 = undefined;
    // QEMU's qemu-xhci: four USB 2 ports, then four USB 3 ones.
    try testing.expectEqual(@as(u32, 8), controller.mapPorts(.{ .usb2_first = 1, .usb2_count = 4, .usb3_first = 5, .usb3_count = 4 }, 8, &map, &super));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, map[0..8]);
    try testing.expectEqual(@as(u32, 0b1_1110_0000), super);
    // The USB 3 ones first in the controller: still last on the hub.
    try testing.expectEqual(@as(u32, 5), controller.mapPorts(.{ .usb2_first = 5, .usb2_count = 1, .usb3_first = 1, .usb3_count = 4 }, 5, &map, &super));
    try testing.expectEqualSlices(u8, &.{ 5, 1, 2, 3, 4 }, map[0..5]);
    try testing.expectEqual(@as(u32, 0b11_1100), super);
    // No capability says: every port, as USB 2.
    try testing.expectEqual(@as(u32, 3), controller.mapPorts(.{}, 3, &map, &super));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, map[0..3]);
    try testing.expectEqual(@as(u32, 0), super);
    // More than a hub's bitmap holds: the first fifteen.
    try testing.expectEqual(@as(u32, 15), controller.mapPorts(.{ .usb2_first = 1, .usb2_count = 10, .usb3_first = 11, .usb3_count = 10 }, 20, &map, &super));
    try testing.expectEqual(@as(u8, 15), map[14]);
    // A capability naming ports the controller does not have: left out.
    try testing.expectEqual(@as(u32, 2), controller.mapPorts(.{ .usb2_first = 1, .usb2_count = 2, .usb3_first = 3, .usb3_count = 2 }, 2, &map, &super));
    try testing.expectEqual(@as(u32, 0), super);
}

test "a USB 3 root port's PORTSC: SuperSpeed, and a link that failed as C_ENABLE" {
    const super = roothub.statusOf(regs.PORT_CCS | regs.PORT_PED | regs.PORT_PP | regs.SPEED_SUPER << regs.PORT_SPEED_SHIFT | regs.PORT_CSC);
    try testing.expectEqual(d.USB_PORT_STAT_CONNECTION | d.USB_PORT_STAT_ENABLE | d.USB_PORT_STAT_POWER | d.USB_PORT_STAT_SUPER_SPEED, super.status);
    try testing.expectEqual(d.USB_PORT_STAT_C_CONNECTION, super.change);
    // SuperSpeedPlus runs as SuperSpeed.
    try testing.expect(roothub.statusOf(regs.PORT_CCS | 5 << regs.PORT_SPEED_SHIFT).status & d.USB_PORT_STAT_SUPER_SPEED != 0);
    try testing.expectEqual(d.USB_PORT_STAT_C_ENABLE, roothub.statusOf(regs.PORT_PP | regs.PORT_CEC).change);
    try testing.expectEqual(d.USB_PORT_STAT_C_RESET, roothub.statusOf(regs.PORT_PP | regs.PORT_WRC).change);
    try testing.expect(regs.PORT_NEUTRAL & regs.PORT_WPR == 0);
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

test "the root ports' exit latencies, their timeouts' register, and the root hub's BOS" {
    // HCSPARAMS3: U1 in its low byte, U2 in its top half.
    try testing.expectEqual(@as(u8, 4), regs.u1ExitOf(0x0200_0004));
    try testing.expectEqual(@as(u16, 0x200), regs.u2ExitOf(0x0200_0004));
    try testing.expectEqual(@as(usize, 0x424), regs.portpmsc(3));
    var host: _xhci.Host = undefined;
    host.u1_exit = 4;
    host.u2_exit = 0x200;
    const bos = roothub.bosOf(&host);
    const bytes = std.mem.asBytes(&bos);
    try testing.expectEqual(@as(usize, 15), bytes.len);
    const capability = d.superSpeedCapabilityOf(bytes).?;
    try testing.expectEqual(@as(u8, 4), capability.u1_exit);
    try testing.expectEqual(@as(u16, 0x200), capability.u2_exit);
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
    try testing.expectEqual(@as(u32, 3 << 16), regs.slotWord1(0, 3, 0));
    try testing.expectEqual(@as(u32, 5 | 2 << 8), regs.slotWord2(5, 2, 0));
    // A high-speed hub with four ports.
    try testing.expectEqual(@as(u32, 3 << 20 | 1 << 26 | 3 << 27), regs.slotWord0(0, regs.SPEED_HIGH, true, 3));
    try testing.expectEqual(@as(u32, 1 << 16 | 4 << 24), regs.slotWord1(0, 1, 4));
    // A device whose links take 204 us to come back, on root port 2.
    try testing.expectEqual(@as(u32, 204 | 2 << 16), regs.slotWord1(204, 2, 0));
    // Endpoint 0 at 64 bytes; an interrupt IN at 8 bytes, every 8 ms.
    try testing.expectEqual(@as(u32, 3 << 1 | 4 << 3 | 64 << 16), regs.endpointWord1(regs.EP_CONTROL, 0, 64));
    try testing.expectEqual(@as(u32, 6 << 16), regs.endpointWord0(6, 0, 0));
    try testing.expectEqual(@as(u32, 8 | 8 << 16), regs.endpointWord4(8, 8));
}

test "a stream array: a power of two of entries for the streams and stream 0, within the controller's" {
    // QEMU's HCCPARAMS1: 64-bit, MaxPSASize 7 (256 entries).
    try testing.expectEqual(@as(u32, 7), regs.maxPsaSize(0x0008_7001));
    try testing.expectEqual(@as(u32, 0), regs.maxPsaSize(0x0008_0001));
    // Sixteen streams and stream 0: 32 entries, MaxPStreams 4.
    try testing.expectEqual(@as(u32, 32), regs.streamEntries(16, 7));
    try testing.expectEqual(@as(u32, 4), regs.maxPStreams(32));
    // Never fewer than four entries; three streams fill them.
    try testing.expectEqual(@as(u32, 4), regs.streamEntries(1, 7));
    try testing.expectEqual(@as(u32, 4), regs.streamEntries(3, 7));
    try testing.expectEqual(@as(u32, 8), regs.streamEntries(4, 7));
    try testing.expectEqual(@as(u32, 1), regs.maxPStreams(4));
    // A controller whose arrays hold four entries; one with none.
    try testing.expectEqual(@as(u32, 4), regs.streamEntries(16, 1));
    try testing.expectEqual(@as(u32, 0), regs.streamEntries(16, 0));
    try testing.expectEqual(@as(u32, 0), regs.streamEntries(0, 7));
    // The streams an endpoint is given of those asked.
    try testing.expectEqual(@as(u32, 16), slots.streamsOf(7, 16));
    try testing.expectEqual(@as(u32, 16), slots.streamsOf(7, 1 << 15));
    try testing.expectEqual(@as(u32, 3), slots.streamsOf(1, 16));
    try testing.expectEqual(@as(u32, 0), slots.streamsOf(0, 16));
    try testing.expectEqual(@as(u32, 0), slots.streamsOf(7, 0));
}

test "a stream's context and its Set TR Dequeue words, its doorbell, its endpoint's context" {
    // A primary stream's ring at 0x1000, cycle state 1.
    try testing.expectEqual(@as(u64, 0x1000 | 1 | 1 << 1), regs.streamPointer(0x1000 | 1));
    try testing.expectEqual(@as(u32, 5 << 16), regs.streamField(5));
    try testing.expectEqual(@as(u32, 3 | 5 << 16), 3 | regs.streamField(5));
    // MaxPStreams 4 with a linear array.
    try testing.expectEqual(@as(u32, 1 << 15 | 4 << 10), regs.endpointWord0(0, 0, 4));
}

test "an endpoint's lanes: one per stream, each found by its ID and by its ring" {
    var trbs: [3][_xhci.ring_trbs]Trb = undefined;
    var lanes: [3]_xhci.Endpoint = @splat(.{});
    for (&lanes, &trbs, 1..) |*lane, *memory, stream| {
        lane.ring.init(memory);
        lane.stream = @intCast(stream);
    }
    var endpoint: _xhci.Endpoint = .{ .lanes = &lanes };
    // Without streams the endpoint is its own lane.
    try testing.expectEqual(@as(usize, 1), _xhci.ringsOf(&endpoint).len);
    try testing.expectEqual(&endpoint, _xhci.laneOf(&endpoint, 0).?);
    try testing.expectEqual(@as(?*_xhci.Endpoint, null), _xhci.laneOf(&endpoint, 1));
    try testing.expectEqual(&endpoint, _xhci.laneAt(&endpoint, 0x1234).?);
    endpoint.streams = 3;
    try testing.expectEqual(@as(usize, 3), _xhci.ringsOf(&endpoint).len);
    try testing.expectEqual(&lanes[1], _xhci.laneOf(&endpoint, 2).?);
    try testing.expectEqual(@as(?*_xhci.Endpoint, null), _xhci.laneOf(&endpoint, 0));
    try testing.expectEqual(@as(?*_xhci.Endpoint, null), _xhci.laneOf(&endpoint, 4));
    const third: u64 = @intFromPtr(&trbs[2][5]);
    try testing.expectEqual(&lanes[2], _xhci.laneAt(&endpoint, third).?);
    try testing.expectEqual(@as(?*_xhci.Endpoint, null), _xhci.laneAt(&endpoint, 0x10));
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
    try testing.expectEqual(@as(u32, 3), _xhci.spanSlice(span));
    // Past the end and round, the Link at 255 no TD: a TD at 9 is the
    // 14th on from one at 250 - 251 to 254, then 0 to 9.
    try testing.expectEqual(@as(u32, 14), transfer.ringDistance(250, 9, 256));
    try testing.expectEqual(@as(u32, 0), transfer.ringDistance(250, 250, 256));
    try testing.expectEqual(@as(u32, 1), transfer.ringDistance(254, 0, 256));
    try testing.expect(transfer.ringDistance(250, 5, 256) < transfer.ringDistance(250, 9, 256));
}

test "an isochronous TD goes in its frame, and the controller's lead is whole frames" {
    try testing.expectEqual(@as(u32, 0x7FF << 20), regs.frameIdField(2047));
    // Frame numbers go round at 2048.
    try testing.expectEqual(@as(u32, 5 << 20), regs.frameIdField(2048 + 5));
    // IST in microframes (bit 3 clear) rounds up to a frame; in frames,
    // as it says.
    try testing.expectEqual(@as(u32, 0), regs.istFrames(0));
    try testing.expectEqual(@as(u32, 1), regs.istFrames(1));
    try testing.expectEqual(@as(u32, 1), regs.istFrames(7));
    try testing.expectEqual(@as(u32, 2), regs.istFrames(8 | 2));
}

test "the frame count follows MFINDEX round its 2048, and the clock past them" {
    try testing.expectEqual(@as(u32, 10), _xhci.framesSince(100, 110, 10));
    // Round the end of the frame numbers.
    try testing.expectEqual(@as(u32, 6), _xhci.framesSince(2045, 3, 6));
    // The clock a little behind the frames: still their steps.
    try testing.expectEqual(@as(u32, 10), _xhci.framesSince(100, 110, 9));
    // Five seconds unread: two whole rounds besides the steps.
    try testing.expectEqual(@as(u32, 4904 + 96), _xhci.framesSince(0, 904, 5000));
}

test "a stream follows on, its late packets missed, and starts again after a dry ring" {
    // A new stream: as soon as the controller can.
    var plan = transfer.isoPlan(1000, 3, false, 0, 0, null, 10, 1);
    try testing.expectEqual(@as(u32, 1003), plan.start);
    try testing.expectEqual(@as(u32, 0), plan.gap);
    // Running, the next request follows on in the frame after the last.
    plan = transfer.isoPlan(1000, 3, true, 2, 1020, null, 10, 1);
    try testing.expectEqual(@as(u32, 1020), plan.start);
    try testing.expectEqual(@as(u32, 0), plan.late);
    // Running but behind: the packets before frame 1003 are missed, the
    // rest go in their frames.
    plan = transfer.isoPlan(1000, 3, true, 1, 998, null, 10, 1);
    try testing.expectEqual(@as(u32, 998), plan.start);
    try testing.expectEqual(@as(u32, 5), plan.late);
    try testing.expectEqual(@as(u32, 0), plan.gap);
    // Every packet too late: it starts as soon as it can, the frames
    // between its gap.
    plan = transfer.isoPlan(1000, 3, true, 1, 980, null, 10, 1);
    try testing.expectEqual(@as(u32, 1003), plan.start);
    try testing.expectEqual(@as(u32, 23), plan.gap);
    try testing.expectEqual(@as(u32, 0), plan.late);
    // The ring ran dry: nothing missed, the frames gone without its gap.
    plan = transfer.isoPlan(1000, 3, true, 0, 995, null, 10, 1);
    try testing.expectEqual(@as(u32, 1003), plan.start);
    try testing.expectEqual(@as(u32, 8), plan.gap);
    // Dry, but the next frame still ahead: it follows on.
    plan = transfer.isoPlan(1000, 3, true, 0, 1004, null, 10, 1);
    try testing.expectEqual(@as(u32, 1004), plan.start);
    try testing.expectEqual(@as(u32, 0), plan.gap);
    // Packets two frames apart: late is counted in packets.
    plan = transfer.isoPlan(1000, 3, true, 1, 998, null, 10, 2);
    try testing.expectEqual(@as(u32, 3), plan.late);
    // Round the end of the frame count.
    plan = transfer.isoPlan(0xFFFF_FFFE, 3, true, 2, 4, null, 10, 1);
    try testing.expectEqual(@as(u32, 4), plan.start);
}

test "a frame asked for is the next time its number comes, within the controller's reach" {
    // Frame number 1010 is 10 frames on from 3048 (1000 + 2048).
    var plan = transfer.isoPlan(3048, 3, false, 0, 0, 1010, 10, 1);
    try testing.expect(!plan.refused);
    try testing.expectEqual(@as(u32, 3058), plan.start);
    // Too soon for the controller, or further than it places: refused.
    try testing.expect(transfer.isoPlan(1000, 3, false, 0, 0, 1001, 10, 1).refused);
    try testing.expect(transfer.isoPlan(1000, 3, false, 0, 0, 999, 10, 1).refused);
    try testing.expect(transfer.isoPlan(1000, 3, false, 0, 0, 1000 + 896, 10, 1).refused);
    try testing.expect(!transfer.isoPlan(1000, 3, false, 0, 0, 1000 + 895, 10, 1).refused);
    // Asked for past where the stream would go on: the frames between
    // its gap.
    plan = transfer.isoPlan(1000, 3, true, 1, 1010, 1020, 10, 1);
    try testing.expectEqual(@as(u32, 10), plan.gap);
}

test "what an isochronous TD's completion code makes of its packet" {
    try testing.expectEqual(@as(i8, 0), transfer.isoStatus(regs.CC_SUCCESS));
    try testing.expectEqual(@as(i8, 0), transfer.isoStatus(regs.CC_SHORT_PACKET));
    try testing.expectEqual(sdk.devices.usbhc.UHIOERR_MISSED, transfer.isoStatus(regs.CC_MISSED_SERVICE));
    try testing.expectEqual(sdk.devices.usbhc.UHIOERR_CRCERROR, transfer.isoStatus(regs.CC_TRANSACTION));
    try testing.expectEqual(sdk.devices.usbhc.UHIOERR_OVERFLOW, transfer.isoStatus(regs.CC_BABBLE));
}
