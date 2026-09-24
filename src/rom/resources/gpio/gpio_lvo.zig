// SPDX-License-Identifier: MPL-2.0
//! gpio.resource's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vec = exec.vec;
const GpioBase = @import("gpio_base.zig").GpioBase;
const AllocGPIO = @import("pad/allocgpio.zig").AllocGPIO;
const FreeGPIO = @import("pad/freegpio.zig").FreeGPIO;
const GPIOOwner = @import("pad/gpioowner.zig").GPIOOwner;

/// gpio.resource's interface, as the SDK generates it from
/// sdk/fd/gpio_lib.fd.
const interface = sdk.interface.gpio;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("gpio.resource: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "gpio.resource", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("pad/allocgpio.zig"),
    @embedFile("pad/freegpio.zig"),
    @embedFile("pad/gpioowner.zig"),
};

fn lvoAllocGPIO(gb: *GpioBase, pad: u32, name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return AllocGPIO(gb, pad, name);
}
fn lvoFreeGPIO(gb: *GpioBase, pad: u32) callconv(.c) void {
    FreeGPIO(gb, pad);
}
fn lvoGPIOOwner(gb: *GpioBase, pad: u32) callconv(.c) ?[*:0]const u8 {
    return GPIOOwner(gb, pad);
}

/// The jump table, in slot order: a resource has no standard vectors, so
/// its first function is in the first slot.
pub const vectors = [_]*const anyopaque{
    vec(lvoAllocGPIO),
    vec(lvoFreeGPIO),
    vec(lvoGPIOOwner),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: this resource's own, from the first slot" {
    try testing.expectEqual(@as(usize, @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("gpio_lvo.zig"), LVO, &.{});
}
