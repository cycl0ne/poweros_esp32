// SPDX-License-Identifier: MIT
//! PCIInfo: the machine's PCI functions, as pci.library found them. Built
//! against the SDK only.
//!
//!   PCIInfo [FULL/S]
//!
//!   PCIInfo        every function: where it is, its vendor and device,
//!                  what it is, the interrupt its line ends up on, and
//!                  the driver that has it
//!   PCIInfo FULL   with each function's BARs: where, how big, what kind
//!
//! Opening the library is what brings the board's host bridges up, the
//! first time: that takes a moment on a PCI Express port.

const sdk = @import("sdk");
const dos = sdk.dos;
const pci = sdk.pci;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const PCIBase = sdk.interface.pci.PCIBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "PCIInfo";
const VERSION_STRING = "\x00$VER: PCIInfo 1.0 (17.10.2026)\r\n";

const template = "FULL/S";
const arg_full = 0;

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
    const full = argv[arg_full] != 0;

    const pci_lib = sys.OpenLibrary(pci.PCINAME, 1) orelse {
        _ = Printf(dl, "no %s: the board has no PCI\n", .{pci.PCINAME});
        return dos.RETURN_WARN;
    };
    defer sys.CloseLibrary(pci_lib);
    const pb: *PCIBase = @ptrCast(pci_lib);

    var it = pb.FindPCIDevice(null, pci.PCI_ANY, pci.PCI_ANY);
    if (it == null) {
        _ = dl.PutStr("no PCI function\n");
        return dos.RETURN_OK;
    }
    _ = dl.PutStr("seg bus dev fn  id         class   irq  driver        what\n");
    while (it) |function| : (it = pb.FindPCIDevice(function, pci.PCI_ANY, pci.PCI_ANY)) {
        printFunction(dl, function);
        if (full) printBars(dl, function);
    }
    return dos.RETURN_OK;
}

fn printFunction(dl: *DosBase, function: *const pci.PCIDevice) void {
    _ = Printf(dl, "%3d %3d %3d %2d  %04x:%04x  %06x  ", .{
        @as(u32, function.segment),   @as(u32, function.bus),       @as(u32, function.device), @as(u32, function.function),
        @as(u32, function.vendor_id), @as(u32, function.device_id), function.class_code,
    });
    if (function.interrupt_pin != 0) {
        _ = Printf(dl, "%3d  ", .{function.interrupt});
    } else {
        _ = dl.PutStr("  -  ");
    }
    _ = Printf(dl, "%-12s  %s\n", .{ function.owner orelse "-", className(function.class_code) });
}

/// Each BAR the function has.
fn printBars(dl: *DosBase, function: *const pci.PCIDevice) void {
    for (function.bars, 0..) |bar, n| {
        if (bar.size == 0) continue;
        const kind: [*:0]const u8 = if (bar.flags & pci.PCIBAR_IO != 0)
            "i/o, not placed"
        else if (bar.flags & pci.PCIBAR_64 != 0)
            (if (bar.flags & pci.PCIBAR_PREFETCH != 0) "64-bit memory, prefetchable" else "64-bit memory")
        else
            (if (bar.flags & pci.PCIBAR_PREFETCH != 0) "memory, prefetchable" else "memory");
        _ = Printf(dl, "      BAR%d  ", .{@as(u32, @intCast(n))});
        if (bar.address != 0) {
            _ = Printf(dl, "0x%09lx  ", .{bar.address});
        } else {
            _ = dl.PutStr("-            ");
        }
        printSize(dl, bar.size);
        _ = Printf(dl, "  %s\n", .{kind});
    }
}

/// A size in bytes, KiB, MiB or GiB, whichever it is a whole number of.
fn printSize(dl: *DosBase, size: u64) void {
    const units = [_]struct { shift: u6, name: [*:0]const u8 }{
        .{ .shift = 30, .name = "G" },
        .{ .shift = 20, .name = "M" },
        .{ .shift = 10, .name = "K" },
    };
    for (units) |unit| {
        if (size >= (@as(u64, 1) << unit.shift) and size & ((@as(u64, 1) << unit.shift) - 1) == 0) {
            _ = Printf(dl, "%5lu%s", .{ size >> unit.shift, unit.name });
            return;
        }
    }
    _ = Printf(dl, "%6lu", .{size});
}

/// What a class code is, as far as this knows.
fn className(class_code: u32) [*:0]const u8 {
    return switch (class_code) {
        pci.PCI_CLASS_SERIAL_USB_XHCI => "USB xHCI controller",
        pci.PCI_CLASS_SERIAL_USB_EHCI => "USB EHCI controller",
        pci.PCI_CLASS_SERIAL_USB_OHCI => "USB OHCI controller",
        pci.PCI_CLASS_SERIAL_USB_UHCI => "USB UHCI controller",
        0x01_08_02 => "NVMe controller",
        else => switch (class_code >> 8) {
            0x0600 => "host bridge",
            0x0604 => "PCI-to-PCI bridge",
            0x0100 => "SCSI controller",
            0x0106 => "SATA controller",
            0x0200 => "Ethernet controller",
            0x0280 => "network controller",
            0x0300 => "VGA display",
            0x0380 => "display",
            0x0403 => "audio",
            0x0C03 => "USB controller",
            else => "?",
        },
    };
}

export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
