// SPDX-License-Identifier: MIT
//! pci.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base.
//!
//! **The init** is where the machine's PCI is set up: each of the board's
//! PCI parts (PARTKIND_PCI) of a chip the library knows is brought up,
//! all of them side by side; then the buses behind each are walked
//! (scan/scan.zig), what was found placed (scan/place.zig), and every
//! function put on the base's chain. A board without one gets no
//! library: the init answers null before anything is kept. Bringing a
//! PCI Express port up takes its time - PERST# held for 100 ms, as long
//! again before the link is asked, up to a second for the link - which
//! the opener waits out on timer.device, once for all the ports.
//!
//! **The library stays** once it is loaded: the buses are numbered and
//! the BARs placed as it found them, and a library loaded again would
//! walk them afresh under drivers that know where their registers are.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("pci_base.zig");
const PCIBase = _base.PCIBase;
const pci_lvo = @import("pci_lvo.zig");
const _host = @import("host/_host.zig");
const Host = _host.Host;
const Entry = _host.Entry;
const scan = @import("scan/scan.zig");
const place = @import("scan/place.zig");
const Delay = @import("delay.zig").Delay;
const _state = @import("host/_state.zig");

pub const LIBRARY_NAME = pci.PCINAME;
pub const LIBRARY_VERSION = 2;
pub const LIBRARY_REVISION = 3;
const BUILD_DATE = "25.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in, and the board's host bridges brought up and
/// walked; null on a board that has none the library knows.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.pciBase(lib);
    const header = lib.*;
    base.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    lib.revision = LIBRARY_REVISION;
    sys_base.InitSemaphore(&base.claim_lock);
    if (!findHosts(base)) {
        sdk.exec.kprintf(sys_base, "%s: no PCI host bridge on this board\n", .{LIBRARY_NAME});
        return null;
    }
    return lib;
}

/// The library stays (see the top of the file).
fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}

pub const expungeVector = expunge;

/// The functions the walk has room for behind one host bridge: more
/// than a machine has, and the rest left out, and said so.
const max_nodes = 256;

/// Every PCI part of the board's brought up and walked. Whether one was.
fn findHosts(base: *PCIBase) bool {
    const sys = base.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return false;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    var delay = Delay.open(sys) orelse return false;
    defer delay.close();
    const nodes_bytes = max_nodes * @sizeOf(scan.Node);
    const nodes_memory = sys.AllocMem(nodes_bytes, exec.MEMF_CLEAR) orelse return false;
    defer sys.FreeMem(nodes_memory, nodes_bytes);
    const nodes = @as([*]scan.Node, @ptrCast(@alignCast(nodes_memory)))[0..max_nodes];

    var hosts: [_host.max_hosts]*Host = undefined;
    var count: usize = 0;
    var segment: u8 = 0;
    var part = eb.FindBoardPart(null, st.PARTKIND_PCI, st.CHIP_ANY);
    while (part) |it| : (part = eb.FindBoardPart(it, st.PARTKIND_PCI, st.CHIP_ANY)) {
        if (segment == _host.max_hosts) break;
        defer segment += 1;
        const chip = _host.chipOf(@truncate(ub.GetTagData(st.PART_Chip, st.CHIP_NONE, it.tags))) orelse continue;
        const config = ub.GetTagData(st.PART_PciConfig, 0, it.tags);
        if (config == 0) continue;
        const memory = sys.AllocMem(@sizeOf(Host), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse break;
        const host: *Host = @ptrCast(@alignCast(memory));
        const mem = ub.GetTagData(st.PART_PciMem, 0, it.tags);
        const pref = ub.GetTagData(st.PART_PciPref, 0, it.tags);
        host.* = .{
            .sys = sys,
            .chip = chip,
            .segment = segment,
            .unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, it.tags)),
            .registers = ub.GetTagData(st.PART_Address, 0, it.tags),
            .config = config,
            .windows = .{
                .io = .ofIo(
                    ub.GetTagData(st.PART_PciIo, 0, it.tags),
                    ub.GetTagData(st.PART_PciIoBus, 0, it.tags),
                    ub.GetTagData(st.PART_PciIoSize, 0, it.tags),
                ),
                .mem = .of(mem, ub.GetTagData(st.PART_PciMemBus, mem, it.tags), ub.GetTagData(st.PART_PciMemSize, 0, it.tags)),
                .pref = .of(pref, ub.GetTagData(st.PART_PciPrefBus, pref, it.tags), ub.GetTagData(st.PART_PciPrefSize, 0, it.tags)),
            },
            .irq = @truncate(ub.GetTagData(st.PART_Irq, 0, it.tags)),
            .perst = ub.GetTagData(st.PART_PinReset, 0, it.tags),
        };
        if (!_host.start(host)) {
            sys.FreeMem(memory, @sizeOf(Host));
            continue;
        }
        hosts[count] = host;
        count += 1;
    }
    if (count == 0) return false;
    _host.bringUp(hosts[0..count], &delay);

    var tail: *?*pci.PCIDevice = &base.first;
    for (hosts[0..count]) |host| walkHost(host, nodes, &tail, &delay);
    return true;
}

/// PCIDevice.bridge_windows: the windows a bridge has.
fn windowsOf(node: *const scan.Node) u8 {
    var windows: u8 = 0;
    if (node.has_io) windows |= pci.PCI_WINDOW_IO;
    if (node.has_io and node.io32) windows |= pci.PCI_WINDOW_IO32;
    if (node.has_pref) windows |= pci.PCI_WINDOW_PREF;
    if (node.has_pref and node.pref64) windows |= pci.PCI_WINDOW_PREF64;
    return windows;
}

/// The buses behind `host` walked, what is on them placed, and a
/// PCIDevice for each function put on the chain at `tail`.
fn walkHost(host: *Host, nodes: []scan.Node, tail: **?*pci.PCIDevice, delay: *Delay) void {
    const sys = host.sys;
    const space = _host.Space{ .host = host };
    const result = scan.walk(space, delay, nodes, .{ .root_devices = _host.rootDevices(host) }, 0);
    if (result.full) {
        sdk.exec.kprintf(sys, "%s: more than %ld functions behind host bridge %ld, the rest left out\n", .{ LIBRARY_NAME, @as(i64, max_nodes), @as(i64, host.segment) });
    }
    if (result.count == 0) return;
    const found = nodes[0..result.count];
    place.place(space, found, &host.windows);

    const bytes = found.len * @sizeOf(Entry);
    const memory = sys.AllocMem(bytes, exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return;
    const entries = @as([*]Entry, @ptrCast(@alignCast(memory)))[0..found.len];
    for (found, entries) |*node, *entry| {
        const info = &node.info;
        const at = node.at;
        const interrupt = _host.interruptOf(host, info.root_device, info.root_pin);
        entry.* = .{
            .device = .{
                .segment = host.segment,
                .bus = at.bus,
                .device = at.device,
                .function = at.function,
                .vendor_id = info.vendor_id,
                .device_id = info.device_id,
                .class_code = info.class_code,
                .revision = info.revision,
                .header_type = info.header_type,
                .interrupt_pin = info.interrupt_pin,
                .subsystem_vendor = info.subsystem_vendor,
                .subsystem_id = info.subsystem_id,
                .interrupt = interrupt,
                .bars = info.bars,
                .private = host,
                .parent = if (node.parent) |p| &entries[p].device else null,
                .rom = info.rom,
                .secondary_bus = node.secondary,
                .subordinate_bus = node.subordinate,
                .express_type = info.express_type,
                .found_power = info.found_power,
                .link_speed = info.link_speed,
                .link_width = info.link_width,
                .link_max_speed = info.link_max_speed,
                .link_max_width = info.link_max_width,
                .msi_vectors = info.msi_vectors,
                .msix_vectors = info.msix_vectors,
                .max_payload = info.max_payload,
                .bridge_windows = windowsOf(node),
                .dma_coherent = _host.coherent(host.chip),
            },
            .host = host,
            .root_pin = info.root_pin,
            .cap_pm = info.cap_pm,
            .cap_msi = info.cap_msi,
            .cap_msix = info.cap_msix,
            .cap_express = info.cap_express,
        };
        // The line register says where the line went, as far as a byte
        // does; nothing here reads it back.
        if (info.interrupt_pin != 0) _host.write(host, at, pci.PCI_INTERRUPT_LINE, 1, interrupt & 0xFF);
        if (info.header_type == pci.PCI_HEADER_NORMAL) entry.kept = _state.save(entry);
        tail.*.* = &entry.device;
        tail.* = &entry.device.next;
    }
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(PCIBase),
    .vectors = &pci_lvo.vectors,
    .vector_count = pci_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it - ramlib loads the file and hands this tag to
/// InitResident. In the ROM the same: ramlib makes it from the tag when
/// it is first opened, so the ports' links are trained when a driver
/// first asks, not at cold start. In `.resident`, which program.ld KEEPs.
pub export const pci_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &pci_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
