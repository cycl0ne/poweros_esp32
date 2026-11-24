// SPDX-License-Identifier: MIT
//! A device's volume, as this machine - AVRCP's controller - sets it and
//! follows it on AVCTP's channel, and the device's buttons, which this
//! machine - AVRCP's target - takes there. Frames in, frames out: the
//! owner hands `heard` each frame of the channel and sends what comes
//! back. The numbers are sdk/libs/bluetooth/avrcp.zig's.
//!
//! **Asking.** `begin` asks the device for the events it has
//! (GetCapabilities). One that has AVRCP_EVENT_VOLUME_CHANGED takes an
//! absolute volume: `.supported` - the owner sets the volume there from
//! then on - and the change is registered for (RegisterNotification),
//! whose first answer says the device's volume now (`.volume`). One
//! without it, a refusal, or no answer in the owner's time (`timedOut`):
//! `.unsupported`, and the owner keeps the volume in the sound.
//!
//! **Setting.** `set` sends SetAbsoluteVolume; its acceptance says the
//! volume the device took (`.volume`). One waits for its answer at a
//! time: a volume set meanwhile is sent once that one is answered, the
//! last of them alone. A device that refuses the command has no absolute
//! volume after all: `.unsupported`.
//!
//! **Following.** A change the device makes itself - its buttons - comes
//! as a CHANGED answer to the registration: `.changed`, and the event
//! registered again under a new label.
//!
//! **The device's commands.** A headphone is a controller too, of the
//! player it plays for. Its buttons come as PASS THROUGH: those of
//! `buttons` are ACCEPTED and are keyboard.device's media keys (`.keys`),
//! a rawkey down as its button is pressed and up as it is let go of - one
//! pressed while another is held letting go of that one first, one
//! pressed again while held holding on - and the owner lets go of the key
//! held (`letGo`) where its release is late. UNIT INFO and SUBUNIT INFO
//! are answered STABLE, the unit a panel, and GetCapabilities as a
//! target's that has the SIG's company ID and no events; the rest NOT
//! IMPLEMENTED, and a command for a profile other than AVRCP with IPID.
//!
//! **The volume** is a percent as a person sets it, as loud as it sounds
//! (sdk/devices/audiocontrol.zig), and the device's absolute volume is a
//! share of its loudest, which it turns into its own steps of loudness:
//! one is the other in proportion (`volumeOfPercent`, `percentOfVolume`).

const sdk = @import("sdk");
const avrcp = sdk.bluetooth.avrcp;
const kb = sdk.devices.keyboard;

/// Where the controller is with the device.
pub const Phase = enum {
    idle,
    /// GetCapabilities asked.
    asking,
    /// The device takes an absolute volume.
    ready,
    /// It does not.
    unsupported,
};

/// What a frame, or a command given up on, meant for the owner.
pub const Outcome = union(enum) {
    none,
    /// The device takes an absolute volume: set it there.
    supported,
    /// It does not: the volume stays in the sound.
    unsupported,
    /// The device's volume now, as it said: in answer to a registration
    /// or to a volume set.
    volume: u8,
    /// The device changed its volume itself.
    changed: u8,
    /// One of the device's buttons, as keys.
    keys: Keys,
};

/// A button of the device's as keyboard.device's keys: the key let go of
/// and the key pressed - both where one is pressed while another is held
/// - and whether a press came, the button's first or one while it is
/// held, from which its release is waited for anew.
pub const Keys = struct {
    up: ?u8 = null,
    down: ?u8 = null,
    pressed: bool = false,
};

pub const Step = struct { send: []const u8 = &.{}, outcome: Outcome = .none };

/// The longest frame made: the AVCTP header, the AV/C header, the PDU's
/// header and five bytes of parameters.
const frame_most = avrcp.AVCTP_HEADER + avrcp.AVC_HEADER + avrcp.AVRCP_PDU_HEADER + 5;
/// The longest of the device's commands answered whole; a longer one is
/// answered with its headers alone.
const echo_most = 64;

/// The device's buttons taken - PASS THROUGH's - and the keys they are.
const buttons = [_]struct { operation: u8, code: u8 }{
    .{ .operation = avrcp.AVC_PASS_VOLUME_UP, .code = kb.RAWKEY_VOLUMEUP },
    .{ .operation = avrcp.AVC_PASS_VOLUME_DOWN, .code = kb.RAWKEY_VOLUMEDOWN },
    .{ .operation = avrcp.AVC_PASS_MUTE, .code = kb.RAWKEY_MUTE },
    .{ .operation = avrcp.AVC_PASS_PLAY, .code = kb.RAWKEY_MEDIA_PLAY },
    .{ .operation = avrcp.AVC_PASS_STOP, .code = kb.RAWKEY_MEDIA_STOP },
    .{ .operation = avrcp.AVC_PASS_PAUSE, .code = kb.RAWKEY_MEDIA_PAUSE },
    .{ .operation = avrcp.AVC_PASS_REWIND, .code = kb.RAWKEY_MEDIA_REWIND },
    .{ .operation = avrcp.AVC_PASS_FAST_FORWARD, .code = kb.RAWKEY_MEDIA_FASTFORWARD },
    .{ .operation = avrcp.AVC_PASS_FORWARD, .code = kb.RAWKEY_MEDIA_NEXT },
    .{ .operation = avrcp.AVC_PASS_BACKWARD, .code = kb.RAWKEY_MEDIA_PREVIOUS },
};

pub const Controller = struct {
    phase: Phase = .idle,
    /// The label the next command takes.
    next_label: u4 = 0,
    /// The commands waiting for their answers, by label: GetCapabilities,
    /// the registration - until its CHANGED - and SetAbsoluteVolume.
    asked: ?u4 = null,
    registered: ?u4 = null,
    setting: ?u4 = null,
    /// Whether the registration has had its first answer.
    interim: bool = false,
    /// A volume to set once the one set is answered.
    pending: ?u8 = null,
    /// The key a button of the device's holds down, its rawkey.
    held: ?u8 = null,
    out: [frame_most]u8 = undefined,
    echo: [echo_most]u8 = undefined,

    /// GetCapabilities asked: the start, once the channel is open.
    pub fn begin(controller: *Controller) []const u8 {
        controller.* = .{};
        controller.phase = .asking;
        const label = controller.newLabel();
        controller.asked = label;
        return controller.command(label, avrcp.AVC_CTYPE_STATUS, avrcp.AVRCP_PDU_GET_CAPABILITIES, &.{avrcp.AVRCP_CAPABILITY_EVENTS});
    }

    /// The device's volume set to `volume` (0 to AVRCP_VOLUME_MAX): the
    /// frame to send, or none while another waits for its answer - this
    /// one is sent after it - or where the device takes no absolute
    /// volume.
    pub fn set(controller: *Controller, volume: u8) []const u8 {
        if (controller.phase != .ready) return &.{};
        const value = @min(volume, avrcp.AVRCP_VOLUME_MAX);
        if (controller.setting != null) {
            controller.pending = value;
            return &.{};
        }
        controller.pending = null;
        const label = controller.newLabel();
        controller.setting = label;
        return controller.command(label, avrcp.AVC_CTYPE_CONTROL, avrcp.AVRCP_PDU_SET_ABSOLUTE_VOLUME, &.{value});
    }

    /// Whether a command waits for an answer due soon: GetCapabilities,
    /// a volume set, a registration not yet answered once.
    pub fn waiting(controller: *const Controller) bool {
        return controller.asked != null or controller.setting != null or (controller.registered != null and !controller.interim);
    }

    /// The commands waited for given up on: a device that has not said
    /// what it has takes no absolute volume; a volume set is forgotten -
    /// the next goes out - and a registration never answered is dropped.
    pub fn timedOut(controller: *Controller) Step {
        if (controller.asked != null) {
            controller.asked = null;
            controller.phase = .unsupported;
            return .{ .outcome = .unsupported };
        }
        if (controller.registered != null and !controller.interim) controller.registered = null;
        if (controller.setting != null) {
            controller.setting = null;
            if (controller.pending) |volume| return .{ .send = controller.set(volume) };
        }
        return .{};
    }

    /// The key a button holds let go of, its release late: its rawkey,
    /// null where none is held.
    pub fn letGo(controller: *Controller) ?u8 {
        const code = controller.held orelse return null;
        controller.held = null;
        return code;
    }

    /// A frame of the channel: an answer to one of this side's commands,
    /// or the device's own command.
    pub fn heard(controller: *Controller, frame: []const u8) Step {
        if (frame.len < avrcp.AVCTP_HEADER) return .{};
        const first = frame[0];
        // Parts of a long message: nothing this side asks for is one.
        if (first & avrcp.AVCTP_PACKET_MASK != avrcp.AVCTP_PACKET_SINGLE) return .{};
        const label: u4 = @intCast(first >> avrcp.AVCTP_LABEL_SHIFT);
        if (first & avrcp.AVCTP_RESPONSE == 0) return controller.answer(frame);
        const pid = @as(u16, frame[1]) << 8 | frame[2];
        if (first & avrcp.AVCTP_IPID != 0 or pid != avrcp.AVRCP_PID) return controller.refused(label);
        const av = frame[avrcp.AVCTP_HEADER..];
        if (av.len < avrcp.AVC_HEADER) return .{};
        const response = av[0] & avrcp.AVC_TYPE_MASK;
        if (av[2] != avrcp.AVC_OP_VENDOR_DEPENDENT) return .{};
        const pdu = av[avrcp.AVC_HEADER..];
        // A refusal may come without the PDU's parameters.
        if (pdu.len < 4 or !sameCompany(pdu[0..3])) {
            return if (response == avrcp.AVC_RESPONSE_NOT_IMPLEMENTED or response == avrcp.AVC_RESPONSE_REJECTED) controller.refused(label) else .{};
        }
        const id = pdu[3];
        var parameters: []const u8 = &.{};
        if (pdu.len >= avrcp.AVRCP_PDU_HEADER) {
            const length = @as(usize, pdu[5]) << 8 | pdu[6];
            parameters = pdu[avrcp.AVRCP_PDU_HEADER..@min(pdu.len, avrcp.AVRCP_PDU_HEADER + length)];
        }
        return switch (id) {
            avrcp.AVRCP_PDU_GET_CAPABILITIES => controller.capabilities(label, response, parameters),
            avrcp.AVRCP_PDU_REGISTER_NOTIFICATION => controller.notified(label, response, parameters),
            avrcp.AVRCP_PDU_SET_ABSOLUTE_VOLUME => controller.volumeSet(label, response, parameters),
            else => .{},
        };
    }

    /// GetCapabilities answered: the events listed, and the volume's
    /// among them or not.
    fn capabilities(controller: *Controller, label: u4, response: u8, parameters: []const u8) Step {
        if (controller.asked != label) return .{};
        controller.asked = null;
        var has_volume = false;
        if (response == avrcp.AVC_RESPONSE_STABLE and parameters.len >= 2 and parameters[0] == avrcp.AVRCP_CAPABILITY_EVENTS) {
            const listed = parameters[2..];
            for (listed[0..@min(listed.len, parameters[1])]) |event| {
                if (event == avrcp.AVRCP_EVENT_VOLUME_CHANGED) has_volume = true;
            }
        }
        if (!has_volume) {
            controller.phase = .unsupported;
            return .{ .outcome = .unsupported };
        }
        controller.phase = .ready;
        return .{ .send = controller.register(), .outcome = .supported };
    }

    /// The registration answered: the volume now, the device's change of
    /// it - registered for again - or a refusal, after which the volume
    /// is set and not followed.
    fn notified(controller: *Controller, label: u4, response: u8, parameters: []const u8) Step {
        if (controller.registered != label) return .{};
        if (parameters.len < 2 or parameters[0] != avrcp.AVRCP_EVENT_VOLUME_CHANGED) {
            controller.registered = null;
            return .{};
        }
        const volume = parameters[1] & avrcp.AVRCP_VOLUME_MAX;
        switch (response) {
            avrcp.AVC_RESPONSE_INTERIM => {
                controller.interim = true;
                return .{ .outcome = .{ .volume = volume } };
            },
            avrcp.AVC_RESPONSE_CHANGED => return .{ .send = controller.register(), .outcome = .{ .changed = volume } },
            else => {
                controller.registered = null;
                return .{};
            },
        }
    }

    /// SetAbsoluteVolume answered: the volume taken, and the next one set
    /// meanwhile sent; refused, the device has no absolute volume.
    fn volumeSet(controller: *Controller, label: u4, response: u8, parameters: []const u8) Step {
        if (controller.setting != label) return .{};
        controller.setting = null;
        if (response != avrcp.AVC_RESPONSE_ACCEPTED) {
            controller.phase = .unsupported;
            controller.pending = null;
            return .{ .outcome = .unsupported };
        }
        const taken: Outcome = if (parameters.len >= 1) .{ .volume = parameters[0] & avrcp.AVRCP_VOLUME_MAX } else .none;
        if (controller.pending) |volume| return .{ .send = controller.set(volume), .outcome = taken };
        return .{ .outcome = taken };
    }

    /// A command of this side's refused as a whole - NOT IMPLEMENTED,
    /// REJECTED without the PDU, IPID: for GetCapabilities and
    /// SetAbsoluteVolume no absolute volume; for the registration no
    /// following.
    fn refused(controller: *Controller, label: u4) Step {
        if (controller.asked == label or controller.setting == label) {
            controller.asked = null;
            controller.setting = null;
            controller.pending = null;
            controller.phase = .unsupported;
            return .{ .outcome = .unsupported };
        }
        if (controller.registered == label) controller.registered = null;
        return .{};
    }

    /// The volume's change registered for, under a label of its own.
    fn register(controller: *Controller) []const u8 {
        const label = controller.newLabel();
        controller.registered = label;
        controller.interim = false;
        return controller.command(label, avrcp.AVC_CTYPE_NOTIFY, avrcp.AVRCP_PDU_REGISTER_NOTIFICATION, &.{ avrcp.AVRCP_EVENT_VOLUME_CHANGED, 0, 0, 0, 0 });
    }

    /// The device's command answered: UNIT INFO and SUBUNIT INFO STABLE,
    /// the unit a panel; GetCapabilities as a target's without events; a
    /// button of `buttons` ACCEPTED and made keys; the rest NOT
    /// IMPLEMENTED with what it said - its headers alone where it is long
    /// - and IPID for another profile.
    fn answer(controller: *Controller, frame: []const u8) Step {
        const head = (frame[0] & 0xF0) | avrcp.AVCTP_PACKET_SINGLE | avrcp.AVCTP_RESPONSE;
        const pid = @as(u16, frame[1]) << 8 | frame[2];
        if (pid != avrcp.AVRCP_PID) {
            controller.echo[0..3].* = .{ head | avrcp.AVCTP_IPID, frame[1], frame[2] };
            return .{ .send = controller.echo[0..3] };
        }
        const av = frame[avrcp.AVCTP_HEADER..];
        if (av.len >= avrcp.AVC_HEADER) {
            const ctype = av[0] & avrcp.AVC_TYPE_MASK;
            const operands = av[avrcp.AVC_HEADER..];
            switch (av[2]) {
                avrcp.AVC_OP_UNIT_INFO => if (ctype == avrcp.AVC_CTYPE_STATUS) {
                    return .{ .send = controller.unitAnswer(head, av[2], [_]u8{ avrcp.AVC_INFO_FIRST, avrcp.AVC_SUBUNIT_PANEL } ++ avrcp.AVRCP_COMPANY_ID) };
                },
                avrcp.AVC_OP_SUBUNIT_INFO => if (ctype == avrcp.AVC_CTYPE_STATUS) {
                    return .{ .send = controller.unitAnswer(head, av[2], .{ avrcp.AVC_INFO_FIRST, avrcp.AVC_SUBUNIT_PANEL, 0xFF, 0xFF, 0xFF }) };
                },
                avrcp.AVC_OP_PASS_THROUGH => if (ctype == avrcp.AVC_CTYPE_CONTROL and av[1] == avrcp.AVC_SUBUNIT_PANEL and operands.len >= 1) {
                    if (keyOf(operands[0] & avrcp.AVC_PASS_OPERATION)) |code| {
                        const keys = controller.button(code, operands[0] & avrcp.AVC_PASS_RELEASED == 0);
                        return .{ .send = controller.echoed(frame, head, avrcp.AVC_RESPONSE_ACCEPTED), .outcome = .{ .keys = keys } };
                    }
                },
                avrcp.AVC_OP_VENDOR_DEPENDENT => if (ctype == avrcp.AVC_CTYPE_STATUS) {
                    if (capabilityAsked(operands)) |id| return .{ .send = controller.offered(head, id) };
                },
                else => {},
            }
        }
        return .{ .send = controller.echoed(frame, head, avrcp.AVC_RESPONSE_NOT_IMPLEMENTED) };
    }

    /// A button pressed or let go of, as keys: one pressed while another
    /// is held lets go of that one first, one pressed again while held
    /// holds on, and the release of a key not held is nothing.
    fn button(controller: *Controller, code: u8, pressed: bool) Keys {
        if (!pressed) {
            if (controller.held != code) return .{};
            controller.held = null;
            return .{ .up = code };
        }
        if (controller.held == code) return .{ .pressed = true };
        const before = controller.held;
        controller.held = code;
        return .{ .up = before, .down = code, .pressed = true };
    }

    /// A STATUS command to the unit answered STABLE, with these operands.
    fn unitAnswer(controller: *Controller, head: u8, opcode: u8, operands: [5]u8) []const u8 {
        const echo = &controller.echo;
        echo[0..3].* = .{ head, @intCast(avrcp.AVRCP_PID >> 8), @intCast(avrcp.AVRCP_PID & 0xFF) };
        echo[3..6].* = .{ avrcp.AVC_RESPONSE_STABLE, avrcp.AVC_SUBUNIT_UNIT, opcode };
        echo[6..11].* = operands;
        return echo[0..11];
    }

    /// GetCapabilities answered as a target's that has no events: the
    /// company IDs - the SIG's alone - or the events, none.
    fn offered(controller: *Controller, head: u8, id: u8) []const u8 {
        var parameters: [5]u8 = .{ id, 0, 0, 0, 0 };
        var length: usize = 2;
        if (id == avrcp.AVRCP_CAPABILITY_COMPANY_ID) {
            parameters[1] = 1;
            parameters[2..5].* = avrcp.AVRCP_COMPANY_ID;
            length = 5;
        }
        return vendorFrame(&controller.echo, head, avrcp.AVC_RESPONSE_STABLE, avrcp.AVRCP_PDU_GET_CAPABILITIES, parameters[0..length]);
    }

    /// The device's command sent back answered `response`: whole, or its
    /// headers alone where it is long.
    fn echoed(controller: *Controller, frame: []const u8, head: u8, response: u8) []const u8 {
        const kept = if (frame.len <= echo_most) frame.len else avrcp.AVCTP_HEADER + avrcp.AVC_HEADER;
        @memcpy(controller.echo[0..kept], frame[0..kept]);
        controller.echo[0] = head;
        if (kept > avrcp.AVCTP_HEADER) controller.echo[avrcp.AVCTP_HEADER] = response;
        return controller.echo[0..kept];
    }

    /// A command of the profile's, in `out`.
    fn command(controller: *Controller, label: u4, ctype: u8, pdu: u8, parameters: []const u8) []const u8 {
        return vendorFrame(&controller.out, @as(u8, label) << avrcp.AVCTP_LABEL_SHIFT | avrcp.AVCTP_PACKET_SINGLE, ctype, pdu, parameters);
    }

    /// The next label, past those waiting.
    fn newLabel(controller: *Controller) u4 {
        while (true) {
            const chosen = controller.next_label;
            controller.next_label +%= 1;
            if (controller.asked == chosen or controller.registered == chosen or controller.setting == chosen) continue;
            return chosen;
        }
    }
};

fn sameCompany(bytes: *const [3]u8) bool {
    return bytes[0] == avrcp.AVRCP_COMPANY_ID[0] and bytes[1] == avrcp.AVRCP_COMPANY_ID[1] and bytes[2] == avrcp.AVRCP_COMPANY_ID[2];
}

/// A frame of the profile's own in `into`: AVCTP's first byte, the AV/C
/// type - a command's or a response's - the panel, the PDU and its
/// parameters.
fn vendorFrame(into: []u8, first: u8, ctype: u8, pdu: u8, parameters: []const u8) []const u8 {
    into[0] = first;
    into[1] = @intCast(avrcp.AVRCP_PID >> 8);
    into[2] = @intCast(avrcp.AVRCP_PID & 0xFF);
    into[3] = ctype;
    into[4] = avrcp.AVC_SUBUNIT_PANEL;
    into[5] = avrcp.AVC_OP_VENDOR_DEPENDENT;
    into[6..9].* = avrcp.AVRCP_COMPANY_ID;
    into[9] = pdu;
    into[10] = avrcp.AVRCP_PACKET_SINGLE;
    into[11] = 0;
    into[12] = @intCast(parameters.len);
    @memcpy(into[13..][0..parameters.len], parameters);
    return into[0 .. 13 + parameters.len];
}

/// What a GetCapabilities of the device's asks for - the company IDs or
/// the events - where the operands are one, in a single packet.
fn capabilityAsked(operands: []const u8) ?u8 {
    if (operands.len < avrcp.AVRCP_PDU_HEADER + 1 or !sameCompany(operands[0..3])) return null;
    if (operands[3] != avrcp.AVRCP_PDU_GET_CAPABILITIES or operands[4] & avrcp.AVRCP_PACKET_MASK != avrcp.AVRCP_PACKET_SINGLE) return null;
    const id = operands[avrcp.AVRCP_PDU_HEADER];
    return if (id == avrcp.AVRCP_CAPABILITY_COMPANY_ID or id == avrcp.AVRCP_CAPABILITY_EVENTS) id else null;
}

/// The key of a button of `buttons`, null for another.
fn keyOf(operation: u8) ?u8 {
    for (buttons) |known| {
        if (known.operation == operation) return known.code;
    }
    return null;
}

/// The device's absolute volume for a percent, 0 to 100: in proportion,
/// rounded.
pub fn volumeOfPercent(percent: u32) u8 {
    const kept: u32 = @min(percent, 100);
    return @intCast((kept * avrcp.AVRCP_VOLUME_MAX + 50) / 100);
}

/// The percent of a device's absolute volume, rounded.
pub fn percentOfVolume(volume: u8) u32 {
    const kept: u32 = @min(volume, avrcp.AVRCP_VOLUME_MAX);
    return (kept * 100 + avrcp.AVRCP_VOLUME_MAX / 2) / avrcp.AVRCP_VOLUME_MAX;
}

// --- tests --------------------------------------------------------------------------

const testing = @import("std").testing;

/// A response of the profile's to the command under `label`.
fn reply(label: u4, rtype: u8, pdu: u8, parameters: []const u8) [32]u8 {
    var frame: [32]u8 = @splat(0);
    frame[0] = @as(u8, label) << avrcp.AVCTP_LABEL_SHIFT | avrcp.AVCTP_RESPONSE;
    frame[1] = 0x11;
    frame[2] = 0x0E;
    frame[3] = rtype;
    frame[4] = avrcp.AVC_SUBUNIT_PANEL;
    frame[5] = avrcp.AVC_OP_VENDOR_DEPENDENT;
    frame[6..9].* = avrcp.AVRCP_COMPANY_ID;
    frame[9] = pdu;
    frame[12] = @intCast(parameters.len);
    @memcpy(frame[13..][0..parameters.len], parameters);
    return frame;
}

fn labelOf(frame: []const u8) u4 {
    return @intCast(frame[0] >> 4);
}

test "a device's events asked for, its volume registered for and set" {
    var controller: Controller = .{};
    const asked = controller.begin();
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x11, 0x0E, 0x01, 0x48, 0x00, 0x00, 0x19, 0x58, 0x10, 0x00, 0x00, 0x01, 0x03 }, asked);
    try testing.expect(controller.waiting());

    // Playback, track and volume: it takes an absolute volume.
    var frame = reply(0, avrcp.AVC_RESPONSE_STABLE, avrcp.AVRCP_PDU_GET_CAPABILITIES, &.{ 0x03, 0x03, 0x01, 0x02, 0x0D });
    var step = controller.heard(frame[0..18]);
    try testing.expectEqual(Outcome.supported, step.outcome);
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x11, 0x0E, 0x03, 0x48, 0x00, 0x00, 0x19, 0x58, 0x31, 0x00, 0x00, 0x05, 0x0D, 0, 0, 0, 0 }, step.send);
    try testing.expect(controller.waiting());

    // Its volume now.
    frame = reply(1, avrcp.AVC_RESPONSE_INTERIM, avrcp.AVRCP_PDU_REGISTER_NOTIFICATION, &.{ 0x0D, 0x40 });
    step = controller.heard(frame[0..15]);
    try testing.expectEqual(Outcome{ .volume = 0x40 }, step.outcome);
    try testing.expect(!controller.waiting());

    // Set; a second set while the first waits goes after it, the last
    // of several alone.
    const sent = controller.set(0x30);
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x11, 0x0E, 0x00, 0x48, 0x00, 0x00, 0x19, 0x58, 0x50, 0x00, 0x00, 0x01, 0x30 }, sent);
    try testing.expectEqual(@as(usize, 0), controller.set(0x20).len);
    try testing.expectEqual(@as(usize, 0), controller.set(0x7F).len);
    frame = reply(2, avrcp.AVC_RESPONSE_ACCEPTED, avrcp.AVRCP_PDU_SET_ABSOLUTE_VOLUME, &.{0x30});
    step = controller.heard(frame[0..14]);
    try testing.expectEqual(Outcome{ .volume = 0x30 }, step.outcome);
    try testing.expectEqualSlices(u8, &.{ 0x30, 0x11, 0x0E, 0x00, 0x48, 0x00, 0x00, 0x19, 0x58, 0x50, 0x00, 0x00, 0x01, 0x7F }, step.send);
    frame = reply(3, avrcp.AVC_RESPONSE_ACCEPTED, avrcp.AVRCP_PDU_SET_ABSOLUTE_VOLUME, &.{0x7F});
    step = controller.heard(frame[0..14]);
    try testing.expectEqual(Outcome{ .volume = 0x7F }, step.outcome);
    try testing.expectEqual(@as(usize, 0), step.send.len);

    // The device's buttons: the change, and the registration made again
    // under a new label; the old label's answers mean nothing now.
    frame = reply(1, avrcp.AVC_RESPONSE_CHANGED, avrcp.AVRCP_PDU_REGISTER_NOTIFICATION, &.{ 0x0D, 0x58 });
    step = controller.heard(frame[0..15]);
    try testing.expectEqual(Outcome{ .changed = 0x58 }, step.outcome);
    try testing.expectEqual(@as(u8, 0x03), step.send[3]);
    try testing.expectEqual(@as(u8, 0x31), step.send[9]);
    const again = labelOf(step.send);
    try testing.expect(again != 1);
    frame = reply(1, avrcp.AVC_RESPONSE_CHANGED, avrcp.AVRCP_PDU_REGISTER_NOTIFICATION, &.{ 0x0D, 0x10 });
    try testing.expectEqual(Outcome.none, controller.heard(frame[0..15]).outcome);
    frame = reply(again, avrcp.AVC_RESPONSE_INTERIM, avrcp.AVRCP_PDU_REGISTER_NOTIFICATION, &.{ 0x0D, 0x58 });
    try testing.expectEqual(Outcome{ .volume = 0x58 }, controller.heard(frame[0..15]).outcome);
}

test "a device without an absolute volume" {
    // Its events without the volume's.
    var controller: Controller = .{};
    _ = controller.begin();
    var frame = reply(0, avrcp.AVC_RESPONSE_STABLE, avrcp.AVRCP_PDU_GET_CAPABILITIES, &.{ 0x03, 0x02, 0x01, 0x02 });
    const step = controller.heard(frame[0..17]);
    try testing.expectEqual(Outcome.unsupported, step.outcome);
    try testing.expectEqual(@as(usize, 0), step.send.len);
    try testing.expectEqual(@as(usize, 0), controller.set(0x40).len);

    // GetCapabilities not implemented, its frame echoed without the PDU.
    _ = controller.begin();
    const short = [_]u8{ 0x02, 0x11, 0x0E, avrcp.AVC_RESPONSE_NOT_IMPLEMENTED, 0x48, 0x00 };
    try testing.expectEqual(Outcome.unsupported, controller.heard(&short).outcome);

    // No AVRCP at all.
    _ = controller.begin();
    const ipid = [_]u8{ 0x03, 0x11, 0x0E };
    try testing.expectEqual(Outcome.unsupported, controller.heard(&ipid).outcome);

    // No answer.
    _ = controller.begin();
    try testing.expectEqual(Outcome.unsupported, controller.timedOut().outcome);
    try testing.expect(!controller.waiting());

    // An absolute volume listed, its command refused.
    _ = controller.begin();
    frame = reply(0, avrcp.AVC_RESPONSE_STABLE, avrcp.AVRCP_PDU_GET_CAPABILITIES, &.{ 0x03, 0x01, 0x0D });
    _ = controller.heard(frame[0..16]);
    const sent = controller.set(0x20);
    frame = reply(labelOf(sent), avrcp.AVC_RESPONSE_REJECTED, avrcp.AVRCP_PDU_SET_ABSOLUTE_VOLUME, &.{0x00});
    try testing.expectEqual(Outcome.unsupported, controller.heard(frame[0..14]).outcome);
    try testing.expectEqual(Phase.unsupported, controller.phase);
}

test "a volume set and not answered, the next sent after it" {
    var controller: Controller = .{};
    _ = controller.begin();
    var frame = reply(0, avrcp.AVC_RESPONSE_STABLE, avrcp.AVRCP_PDU_GET_CAPABILITIES, &.{ 0x03, 0x01, 0x0D });
    _ = controller.heard(frame[0..16]);
    frame = reply(1, avrcp.AVC_RESPONSE_INTERIM, avrcp.AVRCP_PDU_REGISTER_NOTIFICATION, &.{ 0x0D, 0x40 });
    _ = controller.heard(frame[0..15]);
    _ = controller.set(0x10);
    try testing.expectEqual(@as(usize, 0), controller.set(0x11).len);
    try testing.expect(controller.waiting());
    const step = controller.timedOut();
    try testing.expectEqual(@as(u8, 0x11), step.send[13]);
    try testing.expect(controller.waiting());
    // The registration stays: it was answered once.
    try testing.expect(controller.registered != null);
}

test "the device's commands answered: the unit, its panel, what it has; the rest not implemented" {
    var controller: Controller = .{};
    _ = controller.begin();
    // UNIT INFO, as a controller asks first: a panel, of the SIG.
    const unit = [_]u8{ 0x50, 0x11, 0x0E, 0x01, 0xFF, 0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var step = controller.heard(&unit);
    try testing.expectEqualSlices(u8, &.{ 0x52, 0x11, 0x0E, 0x0C, 0xFF, 0x30, 0x07, 0x48, 0x00, 0x19, 0x58 }, step.send);
    try testing.expectEqual(Outcome.none, step.outcome);
    // SUBUNIT INFO's first page: the panel alone.
    const subunit = [_]u8{ 0x60, 0x11, 0x0E, 0x01, 0xFF, 0x31, 0x07, 0xFF, 0xFF, 0xFF, 0xFF };
    step = controller.heard(&subunit);
    try testing.expectEqualSlices(u8, &.{ 0x62, 0x11, 0x0E, 0x0C, 0xFF, 0x31, 0x07, 0x48, 0xFF, 0xFF, 0xFF }, step.send);
    // UNIT INFO as a CONTROL is none this side has.
    const control_unit = [_]u8{ 0x50, 0x11, 0x0E, 0x00, 0xFF, 0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    try testing.expectEqual(@as(u8, 0x08), controller.heard(&control_unit).send[3]);
    // GetCapabilities: the SIG's company ID, and no events.
    const companies = [_]u8{ 0x10, 0x11, 0x0E, 0x01, 0x48, 0x00, 0x00, 0x19, 0x58, 0x10, 0x00, 0x00, 0x01, 0x02 };
    step = controller.heard(&companies);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x11, 0x0E, 0x0C, 0x48, 0x00, 0x00, 0x19, 0x58, 0x10, 0x00, 0x00, 0x05, 0x02, 0x01, 0x00, 0x19, 0x58 }, step.send);
    const events = [_]u8{ 0x20, 0x11, 0x0E, 0x01, 0x48, 0x00, 0x00, 0x19, 0x58, 0x10, 0x00, 0x00, 0x01, 0x03 };
    step = controller.heard(&events);
    try testing.expectEqualSlices(u8, &.{ 0x22, 0x11, 0x0E, 0x0C, 0x48, 0x00, 0x00, 0x19, 0x58, 0x10, 0x00, 0x00, 0x02, 0x03, 0x00 }, step.send);
    // The track's attributes: not implemented.
    const attributes = [_]u8{ 0x30, 0x11, 0x0E, 0x01, 0x48, 0x00, 0x00, 0x19, 0x58, 0x20, 0x00, 0x00, 0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    step = controller.heard(&attributes);
    try testing.expectEqual(@as(u8, 0x32), step.send[0]);
    try testing.expectEqual(@as(u8, 0x08), step.send[3]);
    try testing.expectEqual(@as(usize, attributes.len), step.send.len);
    // A profile of another identifier.
    const other = [_]u8{ 0x70, 0x11, 0x0C, 0x01, 0x48, 0x00 };
    step = controller.heard(&other);
    try testing.expectEqualSlices(u8, &.{ 0x73, 0x11, 0x0C }, step.send);
    // A long command: its headers alone.
    var long: [100]u8 = @splat(0);
    long[0..6].* = .{ 0x80, 0x11, 0x0E, 0x01, 0x48, 0x00 };
    step = controller.heard(&long);
    try testing.expectEqualSlices(u8, &.{ 0x82, 0x11, 0x0E, 0x08, 0x48, 0x00 }, step.send);
    // Parts of a long message pass.
    const part = [_]u8{ 0x94, 0x02, 0x11, 0x0E };
    try testing.expectEqual(@as(usize, 0), controller.heard(&part).send.len);
}

test "the device's buttons: pressed, held, let go of, never let go of, and one not taken" {
    var controller: Controller = .{};
    _ = controller.begin();
    // Play pressed: accepted, its key down.
    const play = [_]u8{ 0x60, 0x11, 0x0E, 0x00, 0x48, 0x7C, 0x44, 0x00 };
    var step = controller.heard(&play);
    try testing.expectEqualSlices(u8, &.{ 0x62, 0x11, 0x0E, 0x09, 0x48, 0x7C, 0x44, 0x00 }, step.send);
    try testing.expectEqual(Outcome{ .keys = .{ .down = 0x78, .pressed = true } }, step.outcome);
    // Pressed again as it is held: held on, no key again.
    step = controller.heard(&play);
    try testing.expectEqual(@as(u8, 0x09), step.send[3]);
    try testing.expectEqual(Outcome{ .keys = .{ .pressed = true } }, step.outcome);
    // Let go of: its key up; let go of again, nothing.
    const released = [_]u8{ 0x70, 0x11, 0x0E, 0x00, 0x48, 0x7C, 0xC4, 0x00 };
    step = controller.heard(&released);
    try testing.expectEqualSlices(u8, &.{ 0x72, 0x11, 0x0E, 0x09, 0x48, 0x7C, 0xC4, 0x00 }, step.send);
    try testing.expectEqual(Outcome{ .keys = .{ .up = 0x78 } }, step.outcome);
    try testing.expectEqual(Outcome{ .keys = .{} }, controller.heard(&released).outcome);
    try testing.expectEqual(@as(?u8, null), controller.letGo());

    // The volume up held, the next pressed without its release: the
    // first let go of as the second goes down.
    const up = [_]u8{ 0x80, 0x11, 0x0E, 0x00, 0x48, 0x7C, 0x41, 0x00 };
    try testing.expectEqual(Outcome{ .keys = .{ .down = 0x7C, .pressed = true } }, controller.heard(&up).outcome);
    const next = [_]u8{ 0x90, 0x11, 0x0E, 0x00, 0x48, 0x7C, 0x4B, 0x00 };
    try testing.expectEqual(Outcome{ .keys = .{ .up = 0x7C, .down = 0x75, .pressed = true } }, controller.heard(&next).outcome);
    // A release of the one let go of is nothing.
    const up_released = [_]u8{ 0xA0, 0x11, 0x0E, 0x00, 0x48, 0x7C, 0xC1, 0x00 };
    try testing.expectEqual(Outcome{ .keys = .{} }, controller.heard(&up_released).outcome);
    // Never let go of: the owner lets go of it once its release is late.
    try testing.expectEqual(@as(?u8, 0x75), controller.letGo());
    try testing.expectEqual(@as(?u8, null), controller.letGo());

    // Every button, and its key.
    const keys = [_][2]u8{ .{ 0x41, 0x7C }, .{ 0x42, 0x7B }, .{ 0x43, 0x7A }, .{ 0x44, 0x78 }, .{ 0x45, 0x72 }, .{ 0x46, 0x79 }, .{ 0x48, 0x76 }, .{ 0x49, 0x77 }, .{ 0x4B, 0x75 }, .{ 0x4C, 0x74 } };
    for (keys) |pair| {
        var frame = [_]u8{ 0xB0, 0x11, 0x0E, 0x00, 0x48, 0x7C, pair[0], 0x00 };
        try testing.expectEqual(Outcome{ .keys = .{ .down = pair[1], .pressed = true } }, controller.heard(&frame).outcome);
        frame[6] = pair[0] | 0x80;
        try testing.expectEqual(Outcome{ .keys = .{ .up = pair[1] } }, controller.heard(&frame).outcome);
    }

    // Select, a menu's, and the vendor's own: not implemented, no key.
    const select = [_]u8{ 0xC0, 0x11, 0x0E, 0x00, 0x48, 0x7C, 0x00, 0x00 };
    step = controller.heard(&select);
    try testing.expectEqualSlices(u8, &.{ 0xC2, 0x11, 0x0E, 0x08, 0x48, 0x7C, 0x00, 0x00 }, step.send);
    try testing.expectEqual(Outcome.none, step.outcome);
    const vendor_unique = [_]u8{ 0xD0, 0x11, 0x0E, 0x00, 0x48, 0x7C, 0x7E, 0x05, 0x00, 0x19, 0x58, 0x00, 0x00 };
    step = controller.heard(&vendor_unique);
    try testing.expectEqual(@as(u8, 0x08), step.send[3]);
    try testing.expectEqual(Outcome.none, step.outcome);
    // Play as a STATUS, and one to another subunit: not implemented.
    const status_play = [_]u8{ 0xE0, 0x11, 0x0E, 0x01, 0x48, 0x7C, 0x44, 0x00 };
    try testing.expectEqual(Outcome.none, controller.heard(&status_play).outcome);
    const elsewhere = [_]u8{ 0xF0, 0x11, 0x0E, 0x00, 0x20, 0x7C, 0x44, 0x00 };
    try testing.expectEqual(@as(u8, 0x08), controller.heard(&elsewhere).send[3]);
    try testing.expectEqual(@as(?u8, null), controller.held);

    // The channel opened again starts with nothing held.
    _ = controller.heard(&play);
    _ = controller.begin();
    try testing.expectEqual(@as(?u8, null), controller.letGo());
}

test "a percent and the device's volume, one in proportion to the other" {
    try testing.expectEqual(@as(u8, 0), volumeOfPercent(0));
    try testing.expectEqual(@as(u8, 127), volumeOfPercent(100));
    try testing.expectEqual(@as(u8, 127), volumeOfPercent(150));
    try testing.expectEqual(@as(u8, 64), volumeOfPercent(50));
    try testing.expectEqual(@as(u32, 0), percentOfVolume(0));
    try testing.expectEqual(@as(u32, 100), percentOfVolume(127));
    try testing.expectEqual(@as(u32, 50), percentOfVolume(64));
    // Every percent comes back as it was.
    var percent: u32 = 0;
    while (percent <= 100) : (percent += 1) try testing.expectEqual(percent, percentOfVolume(volumeOfPercent(percent)));
}
