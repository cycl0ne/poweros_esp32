// SPDX-License-Identifier: MPL-2.0
//! usbport.resource: who holds each of the chip's USB ports, and which
//! controller each is given to.
//!
//! A port is a PHY behind a pair of USB pins. On the ESP32-S3 the one
//! port serves USB-Serial-JTAG - the console and the JTAG, which have it
//! as the chip starts - or the USB OTG controller, and the resource alone
//! sets the switch between them and the OTG side's pad settings
//! (`esp32s3/ports.zig`). On the ESP32-P4 each controller has a port of
//! its own and nothing is switched (`esp32p4/ports.zig`).
//!
//! Each port keeps a list of bidders by priority, the holder among them.
//! A bidder of higher priority than the holder has the holder told, by
//! its signals, that the port is wanted; the holder lets go when what it
//! is doing is done, and the port is switched to the highest bidder,
//! which is told it holds it. usbserial.device bids at the lowest
//! priority, usbotg.device above it when its bus starts.
//!
//! Each call is a file of its own under `port/`. The jump table is
//! usbport_lvo.zig, the ROM tag and init usbport_init.zig, the base
//! usbport_base.zig. This file holds the names the rest of the kernel
//! reaches the resource by, and the tests of it working as a whole.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usbport = sdk.resources.usbport;
const st = sdk.expansion.systemtags;

const usbport_base = @import("usbport_base.zig");
const usbport_init = @import("usbport_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from usbport.resource.
comptime {
    _ = &usbport_init.usbport_resource_tag;
}

/// The resource's base.
pub const UsbPortBase = usbport_base.UsbPortBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = usbport_init.RESOURCE_NAME;
/// The ROM tag, for the host tests that make the resource from it.
pub const usbport_resource_tag = usbport_init.usbport_resource_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");
const _port = @import("port/_port.zig");

test {
    _ = @import("usbport_lvo.zig");
}

fn setUp() !*UsbPortBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &usbport_resource_tag, null) orelse return error.NoResource;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

fn tearDown(pb: *UsbPortBase) !void {
    kexec.RemResource(kexec.SysBase, @ptrCast(&pb.lib));
    kexec.freeLibraryMemory(kexec.SysBase, &pb.lib);
    try kexec.expectNoLeaks();
}

/// The resource as a program calls it, through its jump table.
fn call(pb: *UsbPortBase) *sdk.interface.usbport.UsbPortBase {
    return @ptrCast(pb);
}

/// A bid for the OTG controller's port, on this task, told by `signal`.
fn bid(pb: *UsbPortBase, name: [*:0]const u8, pri: i8, signal: u32) usbport.USBPortHandle {
    return .{
        .node = .{ .pri = pri, .name = name },
        .task = pb.sys_base.FindTask(null),
        .signals = signal,
        .controller = usbport.USBCTL_OTG,
        .unit = 0,
        .role = st.USBROLE_HOST,
    };
}

/// Whether `signal` was sent since the last look; cleared.
fn told(pb: *UsbPortBase, signal: u32) bool {
    return pb.sys_base.SetSignal(0, signal) & signal != 0;
}

const console_signal: u32 = 1 << 20;
const host_signal: u32 = 1 << 21;
const other_signal: u32 = 1 << 22;

test "the first bidder holds the port at once, and leaving gives it up" {
    const pb = try setUp();
    defer kexec.deinit();
    var console = bid(pb, "usbserial.device", usbport.USBPORTPRI_CONSOLE, console_signal);
    const port = _port.portOf(&console).?;

    try testing.expectEqual(@as(?[*:0]const u8, null), call(pb).USBPortOwner(port));
    try testing.expect(call(pb).OwnUSBPort(&console));
    try testing.expectEqual(usbport.USBPORT_HELD, console.state);
    try testing.expectEqualStrings("usbserial.device", std.mem.span(call(pb).USBPortOwner(port).?));
    // A second bid with the same handle changes nothing.
    try testing.expect(call(pb).OwnUSBPort(&console));
    try testing.expect(!told(pb, console_signal));

    call(pb).ReleaseUSBPort(&console, usbport.USBPORTF_REMOVE);
    try testing.expectEqual(usbport.USBPORT_IDLE, console.state);
    try testing.expectEqual(@as(?[*:0]const u8, null), call(pb).USBPortOwner(port));
    try testing.expectEqual(@as(?[*:0]const u8, null), call(pb).USBPortOwner(usbport.USBPORT_PORTS));
    try tearDown(pb);
}

test "a higher bid has the holder let go, and the holder has the port back after" {
    const pb = try setUp();
    defer kexec.deinit();
    var console = bid(pb, "usbserial.device", usbport.USBPORTPRI_CONSOLE, console_signal);
    var host = bid(pb, "usbotg.device", usbport.USBPORTPRI_HOST, host_signal);
    const port = _port.portOf(&host).?;
    try testing.expect(call(pb).OwnUSBPort(&console));

    // The host waits; the console is told it is wanted, and keeps the
    // port until it lets go.
    try testing.expect(!call(pb).OwnUSBPort(&host));
    try testing.expectEqual(usbport.USBPORT_WAITING, host.state);
    try testing.expectEqual(usbport.USBPORT_WANTED, console.state);
    try testing.expect(told(pb, console_signal));
    try testing.expectEqualStrings("usbserial.device", std.mem.span(call(pb).USBPortOwner(port).?));

    // It lets go and stays a bidder: the host is told it holds it.
    call(pb).ReleaseUSBPort(&console, 0);
    try testing.expectEqual(usbport.USBPORT_WAITING, console.state);
    try testing.expectEqual(usbport.USBPORT_HELD, host.state);
    try testing.expect(told(pb, host_signal));
    try testing.expect(!told(pb, console_signal));
    try testing.expectEqualStrings("usbotg.device", std.mem.span(call(pb).USBPortOwner(port).?));

    // The host done: the console has it again, and is told.
    call(pb).ReleaseUSBPort(&host, usbport.USBPORTF_REMOVE);
    try testing.expectEqual(usbport.USBPORT_IDLE, host.state);
    try testing.expectEqual(usbport.USBPORT_HELD, console.state);
    try testing.expect(told(pb, console_signal));
    try testing.expectEqualStrings("usbserial.device", std.mem.span(call(pb).USBPortOwner(port).?));

    call(pb).ReleaseUSBPort(&console, usbport.USBPORTF_REMOVE);
    try tearDown(pb);
}

test "a lower bid waits without disturbing the holder" {
    const pb = try setUp();
    defer kexec.deinit();
    var host = bid(pb, "usbotg.device", usbport.USBPORTPRI_HOST, host_signal);
    var console = bid(pb, "usbserial.device", usbport.USBPORTPRI_CONSOLE, console_signal);
    try testing.expect(call(pb).OwnUSBPort(&host));
    try testing.expect(!call(pb).OwnUSBPort(&console));
    try testing.expectEqual(usbport.USBPORT_HELD, host.state);
    try testing.expect(!told(pb, host_signal));

    // A holder that lets go with nobody above it keeps the port.
    call(pb).ReleaseUSBPort(&host, 0);
    try testing.expectEqual(usbport.USBPORT_HELD, host.state);
    try testing.expectEqual(usbport.USBPORT_WAITING, console.state);
    try testing.expect(!told(pb, host_signal));

    call(pb).ReleaseUSBPort(&host, usbport.USBPORTF_REMOVE);
    try testing.expectEqual(usbport.USBPORT_HELD, console.state);
    try testing.expect(told(pb, console_signal));
    call(pb).ReleaseUSBPort(&console, usbport.USBPORTF_REMOVE);
    try tearDown(pb);
}

test "a bid withdrawn: the holder is no longer wanted, unless another waits" {
    const pb = try setUp();
    defer kexec.deinit();
    var console = bid(pb, "usbserial.device", usbport.USBPORTPRI_CONSOLE, console_signal);
    var host = bid(pb, "usbotg.device", usbport.USBPORTPRI_HOST, host_signal);
    var other = bid(pb, "other", usbport.USBPORTPRI_HOST - 1, other_signal);
    try testing.expect(call(pb).OwnUSBPort(&console));
    try testing.expect(!call(pb).OwnUSBPort(&host));
    try testing.expect(!call(pb).OwnUSBPort(&other));
    try testing.expectEqual(usbport.USBPORT_WANTED, console.state);

    // The host gives up waiting; the other still outranks the console.
    call(pb).ReleaseUSBPort(&host, usbport.USBPORTF_REMOVE);
    try testing.expectEqual(usbport.USBPORT_WANTED, console.state);
    // The other too: the console holds it in peace again.
    call(pb).ReleaseUSBPort(&other, usbport.USBPORTF_REMOVE);
    try testing.expectEqual(usbport.USBPORT_HELD, console.state);
    try testing.expect(!told(pb, host_signal));
    try testing.expect(!told(pb, other_signal));
    _ = told(pb, console_signal);

    call(pb).ReleaseUSBPort(&console, usbport.USBPORTF_REMOVE);
    try tearDown(pb);
}

test "a controller the chip does not have gets nothing" {
    const pb = try setUp();
    defer kexec.deinit();
    var stray = bid(pb, "stray", usbport.USBPORTPRI_HOST, host_signal);
    stray.unit = 7;
    try testing.expect(!call(pb).OwnUSBPort(&stray));
    try testing.expectEqual(usbport.USBPORT_IDLE, stray.state);
    call(pb).ReleaseUSBPort(&stray, usbport.USBPORTF_REMOVE);
    try testing.expectEqual(usbport.USBPORT_IDLE, stray.state);
    try tearDown(pb);
}
