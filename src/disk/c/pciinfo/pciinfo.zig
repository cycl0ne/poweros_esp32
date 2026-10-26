// SPDX-License-Identifier: MIT
//! PCIInfo: every PCI function the machine has, as pci.library found
//! them, whatever they are - each named by its class code, and by its
//! vendor's and device's names where DEVS:pci.ids (the PCI ID
//! Repository's list) is on the disk; one neither knows is listed by its
//! IDs. Built against the SDK only.
//!
//!   PCIInfo [FULL/S] [TREE/S] [HEX/S]
//!
//!   PCIInfo        every function: where it is, its vendor and device, its
//!                  class code, the interrupt it signals on, the driver
//!                  that has it, and what it is
//!   PCIInfo FULL   with each function's subsystem, BARs and expansion
//!                  ROM, a bridge's buses and windows, its PCI Express link
//!                  and payload, whether it sees the caches, its power, its
//!                  interrupts, what it decodes and its capabilities
//!   PCIInfo TREE   each function below the bridge it is behind
//!   PCIInfo HEX    with each function's configuration space, its
//!                  extended space too on PCI Express (rows of zeros left
//!                  out)
//!
//! Opening the library is what brings the board's host bridges up, the
//! first time: that takes a moment on a PCI Express port.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const pci = sdk.pci;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const PCIBase = sdk.interface.pci.PCIBase;
const Printf = dos.stdio.Printf;
const classes = @import("classes.zig");
const Ids = @import("ids.zig").Ids;

pub const COMMAND_NAME = "PCIInfo";
const VERSION_STRING = "\x00$VER: PCIInfo 2.1 (18.10.2026)\r\n";

const template = "FULL/S,TREE/S,HEX/S";
const arg_full = 0;
const arg_tree = 1;
const arg_hex = 2;

/// Where the PCI ID Repository's list is, and the most of it that is
/// read.
const ids_path = "DEVS:pci.ids";
const ids_most: i64 = 16 << 20;

const Context = struct {
    dl: *DosBase,
    pb: *PCIBase,
    ids: ?Ids,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const full = argv[arg_full] != 0;
    const tree = argv[arg_tree] != 0;
    const hex = argv[arg_hex] != 0;

    const pci_lib = sys.OpenLibrary(pci.PCINAME, 2) orelse {
        _ = Printf(dl, "no %s: the board has no PCI\n", .{pci.PCINAME});
        return dos.RETURN_WARN;
    };
    defer sys.CloseLibrary(pci_lib);
    const pb: *PCIBase = @ptrCast(pci_lib);

    const names = loadIds(sys, dl);
    defer if (names.memory) |memory| sys.FreeVec(memory);
    const context = Context{ .dl = dl, .pb = pb, .ids = names.ids };

    var it = pb.FindPCIDevice(null, pci.PCI_ANY, pci.PCI_ANY);
    if (it == null) {
        _ = dl.PutStr("no PCI function\n");
        return dos.RETURN_OK;
    }
    if (!tree) _ = dl.PutStr("seg bus dev fn  id         class   irq   driver        what\n");
    while (it) |function| : (it = pb.FindPCIDevice(function, pci.PCI_ANY, pci.PCI_ANY)) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return dos.RETURN_WARN;
        }
        if (tree) printBranch(&context, function) else printFunction(&context, function);
        if (full) printFull(&context, function);
        if (hex) printHex(&context, function);
    }
    return dos.RETURN_OK;
}

// --- the listing -----------------------------------------------------------------------

fn printFunction(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    _ = Printf(dl, "%3d %3d %3d %2d  %04x:%04x  %06x  ", .{
        @as(u32, function.segment),   @as(u32, function.bus),       @as(u32, function.device), @as(u32, function.function),
        @as(u32, function.vendor_id), @as(u32, function.device_id), function.class_code,
    });
    switch (function.vector_kind) {
        pci.PCI_VECTORS_MSIX => _ = dl.PutStr("MSI-X "),
        pci.PCI_VECTORS_MSI => _ = dl.PutStr("MSI   "),
        else => if (function.interrupt_pin != 0) {
            _ = Printf(dl, "%4d  ", .{function.interrupt});
        } else {
            _ = dl.PutStr("   -  ");
        },
    }
    _ = Printf(dl, "%-12s  ", .{function.owner orelse "-"});
    printWhat(c, function);
    _ = dl.PutStr("\n");
}

/// The function below the bridges it is behind, two columns further in
/// for each.
fn printBranch(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    var parent = function.parent;
    while (parent) |bridge| : (parent = bridge.parent) _ = dl.PutStr("  ");
    _ = Printf(dl, "%04x:%02x:%02x.%d  %04x:%04x  ", .{
        @as(u32, function.segment),   @as(u32, function.bus),       @as(u32, function.device), @as(u32, function.function),
        @as(u32, function.vendor_id), @as(u32, function.device_id),
    });
    printWhat(c, function);
    if (function.owner) |owner| _ = Printf(dl, "  [%s]", .{owner});
    _ = dl.PutStr("\n");
}

/// What the function is: its subclass, and its programming interface,
/// as its class code says; then its vendor's and device's names, where
/// the list has them.
fn printWhat(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    const code = function.class_code;
    const what = classes.describe(code);
    if (what.subclass) |subclass| {
        _ = Printf(dl, "%s", .{subclass});
    } else if (what.class) |class| {
        _ = Printf(dl, "%s, subclass %02x", .{ class, (code >> 8) & 0xFF });
    } else {
        _ = Printf(dl, "class %02x", .{code >> 16});
    }
    if (what.interface) |interface| _ = Printf(dl, " (%s)", .{interface});
    const ids = c.ids orelse return;
    const vendor = ids.vendor(function.vendor_id) orelse return;
    var buffer: [160:0]u8 = undefined;
    _ = Printf(dl, ": %s", .{cString(&buffer, vendor)});
    if (ids.device(function.vendor_id, function.device_id)) |device| {
        _ = Printf(dl, " %s", .{cString(&buffer, device)});
    }
}

// --- FULL ------------------------------------------------------------------------------

fn printFull(c: *const Context, function: *const pci.PCIDevice) void {
    printIdentity(c, function);
    printBars(c, function);
    if (function.header_type == pci.PCI_HEADER_BRIDGE) printBridge(c, function);
    printExpress(c, function);
    printDma(c, function);
    printPower(c, function);
    printInterrupts(c, function);
    printDecoding(c, function);
    printCapabilities(c, function);
}

/// Its vendor, device, revision, its subsystem, and its header.
fn printIdentity(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    var buffer: [160:0]u8 = undefined;
    _ = Printf(dl, "      vendor %04x", .{@as(u32, function.vendor_id)});
    if (c.ids) |ids| if (ids.vendor(function.vendor_id)) |name| {
        _ = Printf(dl, " (%s)", .{cString(&buffer, name)});
    };
    _ = Printf(dl, ", device %04x", .{@as(u32, function.device_id)});
    if (c.ids) |ids| if (ids.device(function.vendor_id, function.device_id)) |name| {
        _ = Printf(dl, " (%s)", .{cString(&buffer, name)});
    };
    _ = Printf(dl, ", revision %02x\n", .{@as(u32, function.revision)});
    if (function.subsystem_vendor != 0 or function.subsystem_id != 0) {
        _ = Printf(dl, "      subsystem %04x:%04x", .{ @as(u32, function.subsystem_vendor), @as(u32, function.subsystem_id) });
        if (c.ids) |ids| {
            if (ids.subsystem(function.vendor_id, function.device_id, function.subsystem_vendor, function.subsystem_id)) |name| {
                _ = Printf(dl, " (%s)", .{cString(&buffer, name)});
            } else if (ids.vendor(function.subsystem_vendor)) |name| {
                _ = Printf(dl, " (%s)", .{cString(&buffer, name)});
            }
        }
        _ = dl.PutStr("\n");
    }
    const header = c.pb.ReadPCIConfig(@constCast(function), pci.PCI_HEADER_TYPE, 1);
    const kind: [*:0]const u8 = switch (function.header_type) {
        pci.PCI_HEADER_NORMAL => "normal",
        pci.PCI_HEADER_BRIDGE => "PCI-to-PCI bridge",
        pci.PCI_HEADER_CARDBUS => "CardBus bridge",
        else => "unknown",
    };
    _ = Printf(dl, "      header %s%s\n", .{ kind, @as([*:0]const u8, if (header & pci.PCI_HEADER_MULTI != 0) ", one of the device's functions" else "") });
}

/// Each BAR the function has, and its expansion ROM.
fn printBars(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    for (function.bars, 0..) |bar, n| {
        if (bar.size == 0) continue;
        const kind: [*:0]const u8 = if (bar.flags & pci.PCIBAR_IO != 0)
            "I/O"
        else if (bar.flags & pci.PCIBAR_64 != 0)
            (if (bar.flags & pci.PCIBAR_PREFETCH != 0) "64-bit memory, prefetchable" else "64-bit memory")
        else
            (if (bar.flags & pci.PCIBAR_PREFETCH != 0) "memory, prefetchable" else "memory");
        _ = Printf(dl, "      BAR%d  ", .{@as(u32, @intCast(n))});
        printPiece(dl, bar);
        _ = Printf(dl, "  %s%s\n", .{ kind, @as([*:0]const u8, if (bar.address == 0) ", not placed" else "") });
    }
    const rom = function.rom;
    if (rom.size != 0) {
        _ = dl.PutStr("      ROM   ");
        printPiece(dl, rom);
        const on = c.pb.ReadPCIConfig(@constCast(function), pci.romRegister(function), 4) & pci.PCI_ROM_ADDRESS_ENABLE != 0;
        _ = Printf(dl, "  expansion ROM, %s\n", .{@as([*:0]const u8, if (rom.address == 0) "not placed" else if (on) "decoded" else "not decoded")});
    }
}

/// Where a BAR is and how large.
fn printPiece(dl: *DosBase, bar: pci.PCIBar) void {
    if (bar.address != 0) {
        _ = Printf(dl, "0x%09lx  ", .{bar.address});
    } else {
        _ = dl.PutStr("-            ");
    }
    printSize(dl, bar.size);
}

/// A bridge's buses, and the windows it forwards to them, as on the bus.
fn printBridge(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    const device = @constCast(function);
    _ = Printf(dl, "      buses %d to %d behind it\n", .{ @as(u32, function.secondary_bus), @as(u32, function.subordinate_bus) });
    _ = dl.PutStr("      forwards  I/O ");
    const io_base = c.pb.ReadPCIConfig(device, pci.PCI_IO_BASE, 1);
    const io_limit = c.pb.ReadPCIConfig(device, pci.PCI_IO_LIMIT, 1);
    var io_low: u64 = (io_base & 0xF0) << 8;
    var io_high: u64 = ((io_limit & 0xF0) << 8) | 0xFFF;
    if (io_base & pci.PCI_IO_RANGE_TYPE_MASK == pci.PCI_IO_RANGE_TYPE_32) {
        io_low |= @as(u64, c.pb.ReadPCIConfig(device, pci.PCI_IO_BASE_UPPER16, 2)) << 16;
        io_high |= @as(u64, c.pb.ReadPCIConfig(device, pci.PCI_IO_LIMIT_UPPER16, 2)) << 16;
    }
    printRange(dl, io_low, io_high, function.bridge_windows & pci.PCI_WINDOW_IO != 0);
    _ = dl.PutStr("  memory ");
    const mem_low: u64 = (@as(u64, c.pb.ReadPCIConfig(device, pci.PCI_MEMORY_BASE, 2)) & 0xFFF0) << 16;
    const mem_high: u64 = ((@as(u64, c.pb.ReadPCIConfig(device, pci.PCI_MEMORY_LIMIT, 2)) & 0xFFF0) << 16) | 0xF_FFFF;
    printRange(dl, mem_low, mem_high, true);
    _ = dl.PutStr("  prefetchable ");
    const pref_base = c.pb.ReadPCIConfig(device, pci.PCI_PREF_MEMORY_BASE, 2);
    const pref_limit = c.pb.ReadPCIConfig(device, pci.PCI_PREF_MEMORY_LIMIT, 2);
    var pref_low: u64 = (@as(u64, pref_base) & 0xFFF0) << 16;
    var pref_high: u64 = ((@as(u64, pref_limit) & 0xFFF0) << 16) | 0xF_FFFF;
    if (pref_base & pci.PCI_PREF_RANGE_TYPE_MASK == pci.PCI_PREF_RANGE_TYPE_64) {
        pref_low |= @as(u64, c.pb.ReadPCIConfig(device, pci.PCI_PREF_BASE_UPPER32, 4)) << 32;
        pref_high |= @as(u64, c.pb.ReadPCIConfig(device, pci.PCI_PREF_LIMIT_UPPER32, 4)) << 32;
    }
    printRange(dl, pref_low, pref_high, function.bridge_windows & pci.PCI_WINDOW_PREF != 0);
    _ = dl.PutStr("\n");
}

/// A window's first and last address; "-" for one that is shut, "none"
/// for one the bridge has not.
fn printRange(dl: *DosBase, low: u64, high: u64, has: bool) void {
    if (!has) {
        _ = dl.PutStr("none");
        return;
    }
    if (low > high) {
        _ = dl.PutStr("-");
        return;
    }
    _ = Printf(dl, "0x%lx-0x%lx", .{ low, high });
}

/// Its PCI Express port type, its link, and its payload.
fn printExpress(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    if (function.express_type == pci.PCI_EXP_TYPE_NONE) return;
    const kind: [*:0]const u8 = switch (function.express_type) {
        pci.PCI_EXP_TYPE_ENDPOINT => "endpoint",
        pci.PCI_EXP_TYPE_LEG_END => "legacy endpoint",
        pci.PCI_EXP_TYPE_ROOT_PORT => "root port",
        pci.PCI_EXP_TYPE_UPSTREAM => "switch's upstream port",
        pci.PCI_EXP_TYPE_DOWNSTREAM => "switch's downstream port",
        pci.PCI_EXP_TYPE_PCI_BRIDGE => "bridge to PCI",
        pci.PCI_EXP_TYPE_PCIE_BRIDGE => "bridge from PCI",
        pci.PCI_EXP_TYPE_RC_END => "endpoint in the root complex",
        pci.PCI_EXP_TYPE_RC_EC => "event collector in the root complex",
        else => "of an unknown kind",
    };
    _ = Printf(dl, "      PCI Express %s", .{kind});
    if (function.link_max_speed != 0) {
        _ = Printf(dl, ", link %s GT/s x%d (it goes to %s GT/s x%d)", .{
            speedName(function.link_speed),     @as(u32, function.link_width),
            speedName(function.link_max_speed), @as(u32, function.link_max_width),
        });
    }
    if (function.max_payload != 0) _ = Printf(dl, ", payload %d bytes", .{@as(u32, function.max_payload)});
    _ = dl.PutStr("\n");
}

fn speedName(generation: u8) [*:0]const u8 {
    return switch (generation) {
        1 => "2.5",
        2 => "5",
        3 => "8",
        4 => "16",
        5 => "32",
        6 => "64",
        else => "?",
    };
}

/// Whether what it reads and writes in RAM sees the processors' caches;
/// a bridge moves nothing of its own. Unknown before pci.library 2.1.
fn printDma(c: *const Context, function: *const pci.PCIDevice) void {
    if (function.header_type != pci.PCI_HEADER_NORMAL) return;
    const lib: *const exec.Library = @ptrCast(@alignCast(c.pb));
    if (lib.revision < 1) return;
    const how: [*:0]const u8 = if (function.dma_coherent) "sees the caches" else "goes past the caches (CachePreDMA, CachePostDMA)";
    _ = Printf(c.dl, "      memory it reads and writes %s\n", .{how});
}

fn printPower(c: *const Context, function: *const pci.PCIDevice) void {
    const states = [4][*:0]const u8{ "D0", "D1", "D2", "D3hot" };
    const pm = c.pb.FindPCICapability(@constCast(function), pci.PCI_CAP_ID_PM, 0);
    if (pm == 0) return;
    const now = c.pb.ReadPCIConfig(@constCast(function), pm + pci.PCI_PM_CTRL, 2) & pci.PCI_PM_CTRL_STATE_MASK;
    _ = Printf(c.dl, "      power %s", .{states[now]});
    if (function.found_power != 0) _ = Printf(c.dl, ", found in %s", .{states[function.found_power & 3]});
    _ = c.dl.PutStr("\n");
}

fn printInterrupts(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    const pins = [4][*:0]const u8{ "INTA", "INTB", "INTC", "INTD" };
    _ = dl.PutStr("      interrupts: ");
    if (function.interrupt_pin != 0) {
        _ = Printf(dl, "%s, on %d", .{ pins[(function.interrupt_pin - 1) & 3], function.interrupt });
    } else {
        _ = dl.PutStr("no INTx");
    }
    if (function.msi_vectors != 0) _ = Printf(dl, "; MSI, %d %s", .{ @as(u32, function.msi_vectors), vectorWord(function.msi_vectors) });
    if (function.msix_vectors != 0) _ = Printf(dl, "; MSI-X, %d %s", .{ @as(u32, function.msix_vectors), vectorWord(function.msix_vectors) });
    switch (function.vector_kind) {
        pci.PCI_VECTORS_MSI => _ = Printf(dl, "; signals on %d MSI %s", .{ @as(u32, function.vectors), vectorWord(function.vectors) }),
        pci.PCI_VECTORS_MSIX => _ = Printf(dl, "; signals on %d MSI-X %s", .{ @as(u32, function.vectors), vectorWord(function.vectors) }),
        else => {},
    }
    _ = dl.PutStr("\n");
}

fn vectorWord(count: u32) [*:0]const u8 {
    return if (count == 1) "vector" else "vectors";
}

/// What its command register lets it do.
fn printDecoding(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    const command = c.pb.ReadPCIConfig(@constCast(function), pci.PCI_COMMAND, 2);
    _ = dl.PutStr("      decodes");
    if (command & pci.PCI_COMMAND_MEMORY != 0) _ = dl.PutStr(" memory");
    if (command & pci.PCI_COMMAND_IO != 0) _ = dl.PutStr(" I/O");
    if (command & (pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_IO) == 0) _ = dl.PutStr(" nothing");
    if (command & pci.PCI_COMMAND_MASTER != 0) _ = dl.PutStr(", masters the bus");
    if (command & pci.PCI_COMMAND_INTX_DISABLE != 0) _ = dl.PutStr(", INTx off");
    _ = dl.PutStr("\n");
}

/// Every capability on its list, and on a PCI Express function every
/// extended one, each with where it is.
fn printCapabilities(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    const device = @constCast(function);
    if (c.pb.ReadPCIConfig(device, pci.PCI_STATUS, 2) & pci.PCI_STATUS_CAP_LIST != 0) {
        _ = dl.PutStr("      capabilities:");
        var at = c.pb.ReadPCIConfig(device, pci.PCI_CAPABILITY_LIST, 1) & 0xFC;
        var left: u32 = 48;
        while (at >= 0x40 and left > 0) : (left -= 1) {
            const id = c.pb.ReadPCIConfig(device, at, 1);
            const name: [*:0]const u8 = if (id < cap_names.len and cap_names[id][0] != 0) cap_names[id] else "?";
            _ = Printf(dl, " %s(%02x)@%02x", .{ name, id, at });
            at = c.pb.ReadPCIConfig(device, at + 1, 1) & 0xFC;
        }
        _ = dl.PutStr("\n");
    }
    if (function.express_type == pci.PCI_EXP_TYPE_NONE) return;
    var at: u32 = pci.PCI_CFG_SPACE_SIZE;
    var left: u32 = 480;
    var any = false;
    while (at >= pci.PCI_CFG_SPACE_SIZE and at < pci.PCI_CFG_SPACE_EXP_SIZE and left > 0) : (left -= 1) {
        const header = c.pb.ReadPCIConfig(device, at, 4);
        if (header == 0 or header == 0xFFFF_FFFF) break;
        if (!any) _ = dl.PutStr("      extended:");
        any = true;
        const id = header & 0xFFFF;
        const name: [*:0]const u8 = if (id < ext_names.len and ext_names[id][0] != 0) ext_names[id] else "?";
        _ = Printf(dl, " %s(%04x)@%03x", .{ name, id, at });
        at = (header >> 20) & 0xFFC;
    }
    if (any) _ = dl.PutStr("\n");
}

const cap_names = [_][*:0]const u8{
    "",               "PM",     "AGP",   "VPD", "SlotID",  "MSI",         "HotSwap", "PCI-X",
    "HyperTransport", "Vendor", "Debug", "CRC", "HotPlug", "SubsystemID", "AGP8x",   "Secure",
    "Express",        "MSI-X",  "SATA",  "AF",  "EA",      "FPB",
};

const ext_names = [_][*:0]const u8{
    "",            "AER",           "VC",          "SerialNumber",    "PowerBudget",        "RCLink",          "RCInternalLink", "RCEC",
    "MFVC",        "VC9",           "RCRB",        "Vendor",          "CAC",                "ACS",             "ARI",            "ATS",
    "SR-IOV",      "MR-IOV",        "Multicast",   "PRI",             "AMD",                "ResizableBAR",    "DPA",            "TPH",
    "LTR",         "SecondaryPCIe", "PMUX",        "PASID",           "LNR",                "DPC",             "L1PMSubstates",  "PTM",
    "M-PCIe",      "FRS",           "RTR",         "DVSEC",           "VFResizableBAR",     "DLF",             "PL16GT",         "LaneMargining",
    "HierarchyID", "NPEM",          "PL32GT",      "AltProtocol",     "SFI",                "ShadowFunctions", "DOE",            "Device3",
    "IDE",         "PL64GT",        "FlitLogging", "FlitPerformance", "FlitErrorInjection",
};

// --- HEX -------------------------------------------------------------------------------

/// The function's configuration space, 16 bytes a row; on PCI Express its
/// extended space too, a run of rows of zeros there one '*'.
fn printHex(c: *const Context, function: *const pci.PCIDevice) void {
    const dl = c.dl;
    const device = @constCast(function);
    const size: u32 = if (function.express_type != pci.PCI_EXP_TYPE_NONE) pci.PCI_CFG_SPACE_EXP_SIZE else pci.PCI_CFG_SPACE_SIZE;
    var skipping = false;
    var row: u32 = 0;
    while (row < size) : (row += 16) {
        var words: [4]u32 = undefined;
        for (&words, 0..) |*word, i| word.* = c.pb.ReadPCIConfig(device, row + @as(u32, @intCast(i)) * 4, 4);
        if (row >= pci.PCI_CFG_SPACE_SIZE and words[0] | words[1] | words[2] | words[3] == 0) {
            if (!skipping) _ = dl.PutStr("      *\n");
            skipping = true;
            continue;
        }
        skipping = false;
        var line: [80:0]u8 = undefined;
        var n: usize = 0;
        for ("      ") |ch| put(&line, &n, ch);
        hexDigits(&line, &n, row, 3);
        put(&line, &n, ':');
        for (words) |word| {
            for (0..4) |b| {
                put(&line, &n, ' ');
                hexDigits(&line, &n, (word >> @intCast(8 * b)) & 0xFF, 2);
            }
        }
        put(&line, &n, '\n');
        line[n] = 0;
        _ = dl.PutStr(&line);
    }
}

fn put(line: *[80:0]u8, n: *usize, ch: u8) void {
    line[n.*] = ch;
    n.* += 1;
}

fn hexDigits(line: *[80:0]u8, n: *usize, value: u32, digits: u5) void {
    var d = digits;
    while (d > 0) {
        d -= 1;
        put(line, n, "0123456789abcdef"[(value >> (d * 4)) & 0xF]);
    }
}

// --- what is shared --------------------------------------------------------------------

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

/// `text` as a C string, cut to what `buffer` holds.
fn cString(buffer: *[160:0]u8, text: []const u8) [*:0]const u8 {
    const n = @min(text.len, buffer.len);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
    return buffer;
}

/// DEVS:pci.ids read whole, where it is; nothing without it.
const Loaded = struct {
    memory: ?*anyopaque = null,
    ids: ?Ids = null,
};

fn loadIds(sys: *ExecBase, dl: *DosBase) Loaded {
    const file = dl.Open(ids_path, dos.MODE_OLDFILE) orelse return .{};
    defer _ = dl.Close(file);
    _ = dl.Seek(file, 0, dos.OFFSET_END);
    const size = dl.Seek(file, 0, dos.OFFSET_BEGINNING);
    if (size <= 0 or size > ids_most) return .{};
    const bytes: usize = @intCast(size);
    const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return .{};
    const text: [*]u8 = @ptrCast(memory);
    var got: usize = 0;
    while (got < bytes) {
        const n = dl.Read(file, text + got, @intCast(bytes - got));
        if (n <= 0) break;
        got += @intCast(n);
    }
    return .{ .memory = memory, .ids = .{ .text = text[0..got] } };
}

export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
