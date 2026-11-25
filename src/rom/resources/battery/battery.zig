// SPDX-License-Identifier: MPL-2.0
//! battery.resource: the board's battery - whether a cell is there, its
//! voltage and the charge that leaves, whether the board runs on external
//! power and whether the cell is charging, where the board can tell - and
//! who is told when that changes.
//!
//! What a board has is its PARTKIND_BATTERY part: the line its cell's
//! voltage is read on, behind which divider, and the lines that say
//! external power is there and that the charger charges. A task of the
//! resource's measures every five seconds (`sense/`), so ReadBattery
//! answers at once, and the programs that asked with AddBatteryNotify
//! are signalled when something they would show changes. The charge is
//! read off a one-cell lithium-polymer cell's discharge curve
//! (`sense/curve.zig`).
//!
//! A board's ROM may carry the resource; the flash boards have it on
//! their disks instead, `DEVS:battery.resource`, which ramlib loads the
//! first time something asks for it. So this file is the root of a load
//! file as well, and holds nothing but the SDK: the tests of the resource
//! working as a whole are tests.zig.
//!
//! Each call is a file of its own under `state/` and `notify/`. The jump
//! table is battery_lvo.zig, the ROM tag and init battery_init.zig, the
//! base battery_base.zig. This file holds the names the rest of the
//! kernel reaches the resource by.

const sdk = @import("sdk");
const exec = sdk.exec;

const battery_base = @import("battery_base.zig");
const battery_init = @import("battery_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from battery.resource.
comptime {
    _ = &battery_init.battery_resource_tag;
}

/// A resource is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
fn programEntry(sys: *sdk.interface.exec.ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    exec.kprintf(sys, "%s is a resource, not a command\n", .{battery_init.RESOURCE_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
const version_tag: [battery_init.RESOURCE_VERSION_STRING.len:0]u8 linksection(".version") = battery_init.RESOURCE_VERSION_STRING.*;

/// Whether this is the ROM's copy: the kernel's root lists the ROM's
/// modules, a program's does not.
const in_rom = @hasDecl(@import("root"), "rom_modules");

// The file's entry and its version string, which only the file has: in
// the ROM there is no file, and the host tests build this file beside
// the other modules, whose names are the same.
comptime {
    if (!in_rom and !@import("builtin").is_test) {
        @export(&programEntry, .{ .name = "_program_entry" });
        @export(&version_tag, .{ .name = "version_tag" });
    }
}

/// The resource's base.
pub const BatteryBase = battery_base.BatteryBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = battery_init.RESOURCE_NAME;
/// The ROM tag, for the host tests that make the resource from it.
pub const battery_resource_tag = battery_init.battery_resource_tag;
