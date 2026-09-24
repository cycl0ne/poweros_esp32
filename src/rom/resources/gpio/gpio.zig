// SPDX-License-Identifier: MPL-2.0
//! gpio.resource: who holds which of the chip's pads.
//!
//! A driver takes each pad it routes with AllocGPIO, under a name that
//! says who it is, and gives it back with FreeGPIO; a second driver asking
//! for the same pad is told whose it is instead of getting it. The
//! resource only keeps that list - routing and setting a pad is
//! `sdk.hardware.gpio`'s - and starts with the pads the machine runs on
//! already taken: the flash's, the PSRAM's, the USB port's and UART0's.
//!
//! Each call is a file of its own under `pad/`. The jump table is
//! gpio_lvo.zig, the ROM tag and init gpio_init.zig, the base
//! gpio_base.zig. This file holds the names the rest of the kernel reaches
//! the resource by, and the tests of it working as a whole.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.gpio;

const gpio_base = @import("gpio_base.zig");
const gpio_init = @import("gpio_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from gpio.resource.
comptime {
    _ = &gpio_init.gpio_resource_tag;
}

/// The resource's base.
pub const GpioBase = gpio_base.GpioBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = gpio_init.RESOURCE_NAME;
/// The ROM tag, for the host tests that make the resource from it.
pub const gpio_resource_tag = gpio_init.gpio_resource_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");
const AllocGPIO = @import("pad/allocgpio.zig").AllocGPIO;
const FreeGPIO = @import("pad/freegpio.zig").FreeGPIO;
const GPIOOwner = @import("pad/gpioowner.zig").GPIOOwner;

test {
    _ = gpio_base;
    _ = gpio_init;
    _ = @import("gpio_lvo.zig");
    _ = @import("pad/allocgpio.zig");
    _ = @import("pad/freegpio.zig");
    _ = @import("pad/gpioowner.zig");
}

/// exec and the resource made from its ROM tag. No expansion.library, so
/// the board's PSRAM is unknown and its pads are left free.
fn setUp() !*GpioBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &gpio_resource_tag, null) orelse return error.NoResource;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

fn tearDown(gb: *GpioBase) !void {
    kexec.RemResource(kexec.SysBase, @ptrCast(&gb.lib));
    kexec.freeLibraryMemory(kexec.SysBase, &gb.lib);
    try kexec.expectNoLeaks();
}

test "a free pad is taken, refused to the next, and given back" {
    const gb = try setUp();
    defer kexec.deinit();

    try testing.expectEqual(@as(?[*:0]const u8, null), GPIOOwner(gb, 9));
    try testing.expectEqual(@as(?[*:0]const u8, null), AllocGPIO(gb, 9, "i2c.device"));
    try testing.expectEqualStrings("i2c.device", std.mem.span(GPIOOwner(gb, 9).?));
    // Taken: the second asker is told whose it is, and nothing changes.
    try testing.expectEqualStrings("i2c.device", std.mem.span(AllocGPIO(gb, 9, "sd.device").?));
    try testing.expectEqualStrings("i2c.device", std.mem.span(GPIOOwner(gb, 9).?));
    FreeGPIO(gb, 9);
    try testing.expectEqual(@as(?[*:0]const u8, null), GPIOOwner(gb, 9));
    try testing.expectEqual(@as(?[*:0]const u8, null), AllocGPIO(gb, 9, "sd.device"));
    FreeGPIO(gb, 9);
    try tearDown(gb);
}

test "the system's own pads are taken from the start" {
    const gb = try setUp();
    defer kexec.deinit();

    try testing.expectEqualStrings("flash", std.mem.span(GPIOOwner(gb, 30).?));
    try testing.expectEqualStrings("usb", std.mem.span(GPIOOwner(gb, 19).?));
    try testing.expectEqualStrings("uart0", std.mem.span(GPIOOwner(gb, 43).?));
    try testing.expectEqualStrings("flash", std.mem.span(AllocGPIO(gb, 27, "sd.device").?));
    // No board to say there is PSRAM: its pads stay free.
    try testing.expectEqual(@as(?[*:0]const u8, null), GPIOOwner(gb, 33));
    try tearDown(gb);
}

test "a pad the chip does not have is never handed out" {
    const gb = try setUp();
    defer kexec.deinit();

    for ([_]u32{ 22, 25, types.GPIO_PADS, 1000 }) |pad| {
        try testing.expectEqualStrings(types.NO_SUCH_PAD, std.mem.span(AllocGPIO(gb, pad, "x").?));
        try testing.expectEqual(@as(?[*:0]const u8, null), GPIOOwner(gb, pad));
        FreeGPIO(gb, pad);
    }
    try tearDown(gb);
}
