// SPDX-License-Identifier: MIT
//! DeviceUnits: the units of the devices that speak a command set, as
//! expansion.library's ObtainDeviceUnits lists them. Built against the
//! SDK only.
//!
//!   DeviceUnits SPEAKS/N
//!
//! SPEAKS is a command set's number, DEVIF_* (sdk/libs/expansion/devices.zig:
//! 1 a stream, 2 a serial line, 4 SANA-II, 5 blocks, 12 a USB host
//! controller, 13 a USB class driver); without it, every device that says
//! what it speaks. A line per unit: the name to open, the unit, the
//! version, ROM or DEVS:, the command sets, and the unit's label.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const expansion = sdk.expansion;
const devices = expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "DeviceUnits";
const VERSION_STRING = "\x00$VER: DeviceUnits 1.0 (12.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "SPEAKS/N";
const arg_speaks = 0;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const speaks: u32 = if (argv[arg_speaks] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_speaks])).*) else 0;

    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse {
        _ = Printf(dl, "%s: no %s\n", .{ COMMAND_NAME, expansion.EXPANSIONNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    const list = eb.ObtainDeviceUnits(speaks, null) orelse {
        _ = Printf(dl, "%s: no memory\n", .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer eb.ReleaseDeviceUnits(list);

    if (list.isEmpty()) {
        _ = Printf(dl, "no device speaks %lu\n", .{@as(u64, speaks)});
        return dos.RETURN_WARN;
    }
    var it = list.iterator();
    while (it.next()) |node| {
        const unit: *const devices.DeviceUnit = @ptrCast(@alignCast(node));
        const where: [*:0]const u8 = if (unit.flags & devices.DUF_ROM != 0) "ROM" else "DEVS:";
        _ = Printf(dl, "%-22s %2u  %u.%-3u %-5s speaks", .{ unit.node.name.?, unit.unit, @as(u32, unit.version), @as(u32, unit.revision), where });
        var index: usize = 0;
        while (unit.speaks[index] != 0) : (index += 1) _ = Printf(dl, " %u", .{unit.speaks[index]});
        if (unit.label) |label| _ = Printf(dl, "  \"%s\"", .{label});
        _ = Printf(dl, "\n", .{});
    }
    return dos.RETURN_OK;
}
