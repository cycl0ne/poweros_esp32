// SPDX-License-Identifier: MIT
//! pci.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base.
//!
//! **The init** is where the machine's PCI is set up: each of the board's
//! PCI parts (PARTKIND_PCI) of a chip the library knows is brought up
//! and walked (scan/scan.zig), and every function found is put on the
//! base's chain. A board without one gets no library: the init answers
//! null before anything is kept. Bringing a PCI Express port up takes its
//! time - PERST# held for 100 ms, as long again before the link is asked,
//! up to a second for the link - which the opener waits out on
//! timer.device.
//!
//! **The library stays** once it is loaded: the buses are numbered and
//! the BARs placed as it found them, and a library loaded again would
//! walk them afresh under drivers that know where their registers are.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const timer = sdk.devices.timer;
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("pci_base.zig");
const PCIBase = _base.PCIBase;
const pci_lvo = @import("pci_lvo.zig");
const _host = @import("host/_host.zig");
const Host = _host.Host;
const Entry = _host.Entry;
const scan = @import("scan/scan.zig");

pub const LIBRARY_NAME = pci.PCINAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "17.10.2026";
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

/// timer.device's micro timer, waited on from the opener's task while
/// the bridges come up.
const Delay = struct {
    sys: *ExecBase,
    port: *exec.MsgPort,
    io: timer.TimeRequest = .{},

    fn open(delay: *Delay) bool {
        delay.io.node.message.reply_port = delay.port;
        delay.io.node.message.length = @sizeOf(timer.TimeRequest);
        return delay.sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &delay.io.node, 0) == 0;
    }

    /// `us` microseconds waited out.
    pub fn wait(delay: *Delay, us: u32) void {
        delay.io.node.command = timer.TR_ADDREQUEST;
        delay.io.time = timer.TimeVal.fromMicros(us);
        _ = delay.sys.DoIO(&delay.io.node);
    }

    fn close(delay: *Delay) void {
        delay.sys.CloseDevice(&delay.io.node);
    }
};

/// Every PCI part of the board's brought up and walked. Whether one was.
fn findHosts(base: *PCIBase) bool {
    const sys = base.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return false;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const port = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(port);
    var delay = Delay{ .sys = sys, .port = port };
    if (!delay.open()) return false;
    defer delay.close();

    var tail: *?*pci.PCIDevice = &base.first;
    var found = false;
    var segment: u8 = 0;
    var part = eb.FindBoardPart(null, st.PARTKIND_PCI, st.CHIP_ANY);
    while (part) |it| : (part = eb.FindBoardPart(it, st.PARTKIND_PCI, st.CHIP_ANY)) {
        if (segment == _host.max_hosts) break;
        defer segment += 1;
        const chip = _host.chipOf(@truncate(ub.GetTagData(st.PART_Chip, st.CHIP_NONE, it.tags))) orelse continue;
        const config = ub.GetTagData(st.PART_PciConfig, 0, it.tags);
        if (config == 0) continue;
        const memory = sys.AllocMem(@sizeOf(Host), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return found;
        const host: *Host = @ptrCast(@alignCast(memory));
        host.* = .{
            .sys = sys,
            .chip = chip,
            .segment = segment,
            .unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, it.tags)),
            .registers = ub.GetTagData(st.PART_Address, 0, it.tags),
            .config = config,
            .windows = .{
                .mem = .of(ub.GetTagData(st.PART_PciMem, 0, it.tags), ub.GetTagData(st.PART_PciMemSize, 0, it.tags)),
                .pref = .of(ub.GetTagData(st.PART_PciPref, 0, it.tags), ub.GetTagData(st.PART_PciPrefSize, 0, it.tags)),
            },
            .irq = @truncate(ub.GetTagData(st.PART_Irq, 0, it.tags)),
            .perst = ub.GetTagData(st.PART_PinReset, 0, it.tags),
        };
        if (!_host.bringUp(host, &delay)) {
            sys.FreeMem(memory, @sizeOf(Host));
            continue;
        }
        var collect = Collect{ .sys = sys, .host = host, .tail = tail };
        _ = scan.walk(_host.Space{ .host = host }, &collect, &host.windows, .{ .root_devices = _host.rootDevices(host) }, 0);
        tail = collect.tail;
        found = true;
    }
    return found;
}

/// What the walk finds behind a host, put on the chain.
const Collect = struct {
    sys: *ExecBase,
    host: *Host,
    tail: *?*pci.PCIDevice,

    pub fn function(collect: *Collect, at: scan.Address, info: *const scan.Function) bool {
        const memory = collect.sys.AllocMem(@sizeOf(Entry), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return false;
        const entry: *Entry = @ptrCast(@alignCast(memory));
        const host = collect.host;
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
            },
            .host = host,
            .root_pin = info.root_pin,
        };
        // The line register says where the line went, as far as a byte
        // does; nothing here reads it back.
        if (info.interrupt_pin != 0) _host.write(host, at, pci.PCI_INTERRUPT_LINE, 1, interrupt & 0xFF);
        collect.tail.* = &entry.device;
        collect.tail = &entry.device.next;
        return true;
    }
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(PCIBase),
    .vectors = &pci_lvo.vectors,
    .vector_count = pci_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it - ramlib loads the file and hands this tag to
/// InitResident. In `.resident`, which program.ld KEEPs.
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
