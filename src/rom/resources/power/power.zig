// SPDX-License-Identifier: MPL-2.0
//! power.resource: the machine's own power - what can be done about it,
//! turning it off, and who is told when its power button is pressed.
//!
//! What the machine can do is worked out once as the resource starts and
//! answered by PowerAbilities, so that nothing offers what this machine
//! cannot do. Turning it off is the firmware's to do, and the resource
//! asks it (`machine/_machine.zig`): what a machine is written to in
//! order to be off is described in the firmware's own tables, in a
//! language nothing here reads, and the firmware wrote that description.
//!
//! The button is the board's PARTKIND_POWER part: where the hardware that
//! reports a press is, and which line it raises (`source/acpipm.zig`). A
//! server on that line clears the press and wakes the resource's task
//! (`button/_button.zig`), which tells whoever asked with AddPowerNotify
//! - and where nobody did, stops the drives so that what they hold is
//! written out and turns the machine off (`button/task.zig`), which is
//! what a press means on a machine nobody is watching.
//!
//! Each call is a file of its own under `machine/` and `notify/`. The
//! jump table is power_lvo.zig, the ROM tag and init power_init.zig, the
//! base power_base.zig. This file holds the names the rest of the kernel
//! reaches the resource by, and the tests of it working as a whole.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const power = sdk.resources.power;

const power_base = @import("power_base.zig");
const power_init = @import("power_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from power.resource.
comptime {
    _ = &power_init.power_resource_tag;
}

/// The resource's base.
pub const PowerBase = power_base.PowerBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = power_init.RESOURCE_NAME;
/// The ROM tag, for the host tests that make the resource from it.
pub const power_resource_tag = power_init.power_resource_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");
const acpipm = @import("source/acpipm.zig");
const _notify = @import("notify/_notify.zig");

test {
    _ = @import("power_lvo.zig");
}

test "a machine that can do neither says so, and takes no request" {
    const pb = try setUp();
    defer kexec.deinit();
    // The host's machine has no firmware to ask and no board part.
    try testing.expectEqual(@as(u32, 0), call(pb).PowerAbilities());
    try testing.expect(!pb.started);
    try testing.expect(!pb.hooked);
    try testing.expect(pb.stack == null);
    const sys = pb.sys_base;
    try testing.expect(call(pb).AddPowerNotify(sys.FindTask(null).?, 1 << 20) == null);
    // Asking for what it cannot do leaves the machine running.
    call(pb).PowerOff();
    try tearDown(pb);
}

test "a request is told of a press, and given back" {
    const pb = try setUp();
    defer kexec.deinit();
    const sys = pb.sys_base;
    // As a machine whose button says when it is pressed would have it.
    pb.abilities = power.POWERF_BUTTON;
    const bit: u32 = 1 << 20;
    const notify = call(pb).AddPowerNotify(sys.FindTask(null).?, bit) orelse return error.NoNotify;
    _ = sys.SetSignal(0, bit);

    // The press reaches the task that asked, and says it was taken.
    sys.ObtainSemaphore(&pb.lock);
    try testing.expect(_notify.pressed(pb));
    sys.ReleaseSemaphore(&pb.lock);
    try testing.expect(sys.SetSignal(0, bit) & bit != 0);

    // Given back: nobody is told, and the press is the resource's again.
    call(pb).RemPowerNotify(notify);
    sys.ObtainSemaphore(&pb.lock);
    try testing.expect(!_notify.pressed(pb));
    sys.ReleaseSemaphore(&pb.lock);
    try testing.expect(sys.SetSignal(0, bit) & bit == 0);

    // Null is nothing to give back.
    call(pb).RemPowerNotify(null);
    pb.abilities = 0;
    try tearDown(pb);
}

test "hardware that is not all there is not used" {
    // No blocks at all, a block without its control half, and halves too
    // narrow to hold the bit a press is in: none of them is hardware to
    // read or write.
    try testing.expect(!acpipm.usable(.{}));
    try testing.expect(!acpipm.usable(.{ .event = 0x600, .event_bytes = 4 }));
    try testing.expect(!acpipm.usable(.{ .event = 0x600, .control = 0x604, .event_bytes = 2 }));
    // On this host there is no such hardware whatever the board says, and
    // a reading of it is never taken for a press.
    try testing.expect(!acpipm.pressed(.{ .event = 0x600, .control = 0x604, .event_bytes = 4 }));
}

fn setUp() !*PowerBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &power_resource_tag, null) orelse return error.NoResource;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

fn tearDown(pb: *PowerBase) !void {
    kexec.RemResource(kexec.SysBase, @ptrCast(&pb.lib));
    kexec.freeLibraryMemory(kexec.SysBase, &pb.lib);
    try kexec.expectNoLeaks();
}

/// The resource as a program calls it, through its jump table.
fn call(pb: *PowerBase) *sdk.interface.power.PowerBase {
    return @ptrCast(pb);
}
