// SPDX-License-Identifier: MPL-2.0
//! The device: its function on PCI found and claimed, its two windows,
//! and its table of blocks read.
//!
//! The function is the vendor's display function. Its registers are in
//! the sixth window, its memory in the first; a function whose windows are
//! not those two, or whose table is in none of the places a table is
//! looked for, is given back and said so of - it is a device this does
//! not know, and is left alone rather than read at addresses that would
//! mean something else.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const PCIDevice = pci.PCIDevice;
const PCIBase = sdk.interface.pci.PCIBase;
const AMDGPUBase = @import("../amdgpu_base.zig").AMDGPUBase;
const _table = @import("../table/_table.zig");
const Window = _table.Window;

/// The resource's name, as a listing of claimed functions shows it.
pub const owner = sdk.resources.amdgpu.AMDGPUNAME;

/// The vendor, and the class every display function carries in its upper
/// sixteen bits.
const VENDOR: u32 = 0x1002;
const CLASS_DISPLAY: u32 = 0x0300;

/// The window the memory is in, and the one the registers are in.
const bar_memory = 0;
const bar_registers = 5;
/// The least either window can be and still be the one: a chip's
/// registers fill a quarter of a mebibyte, and its memory is never a
/// handful of pages.
const registers_least = 256 * 1024;
const memory_least = 16 * 1024 * 1024;

/// The device found, claimed and read into the base: true where it is
/// there. Every function of the vendor's that is a display function is
/// looked at, and the first whose windows and table are what they should
/// be is kept; each one passed over is said so of.
pub fn take(ab: *AMDGPUBase) bool {
    const sys = ab.sys_base;
    const lib = sys.OpenLibrary(pci.PCINAME, 1) orelse return false;
    const base: *PCIBase = @ptrCast(lib);
    var found: ?*PCIDevice = null;
    while (base.FindPCIDevice(found, VENDOR, pci.PCI_ANY)) |device| {
        found = device;
        if (device.class_code >> 8 != CLASS_DISPLAY) continue;
        if (base.ClaimPCIDevice(device, owner)) |holder| {
            exec.kprintf(sys, "%s: %x:%x is %s's\n", .{ owner, @as(u32, device.vendor_id), @as(u32, device.device_id), holder });
            continue;
        }
        if (read(ab, device)) {
            ab.device = device;
            ab.pci_lib = lib;
            ab.pci = base;
            return true;
        }
        base.ReleasePCIDevice(device);
    }
    sys.CloseLibrary(lib);
    return false;
}

/// One function read into the base: its windows and its table. False,
/// with nothing kept, where either is not what it should be.
fn read(ab: *AMDGPUBase, device: *PCIDevice) bool {
    const sys = ab.sys_base;
    const memory = window(device, bar_memory, memory_least) orelse return say(ab, device, "its memory window is not one this reads");
    const registers = window(device, bar_registers, registers_least) orelse return say(ab, device, "its register window is not one this reads");
    const table = _table.find(sys, memory, registers) orelse return say(ab, device, "it leaves no table of blocks where one is looked for");
    ab.table = table.at;
    ab.table_room = table.room;
    ab.info = .{
        .vendor = device.vendor_id,
        .device = device.device_id,
        .registers = registers.at,
        .registers_bytes = registers.bytes,
        .window = memory.at,
        .window_bytes = memory.bytes,
        .memory_bytes = _table.memoryBytes(registers),
    };
    exec.kprintf(sys, "%s: %x:%x, the table of blocks is in %s\n", .{
        owner, @as(u32, device.vendor_id), @as(u32, device.device_id), table.where,
    });
    return true;
}

/// A line about a function that was looked at and left alone, and false.
fn say(ab: *AMDGPUBase, device: *PCIDevice, why: [*:0]const u8) bool {
    exec.kprintf(ab.sys_base, "%s: %x:%x is a display function and %s\n", .{
        owner, @as(u32, device.vendor_id), @as(u32, device.device_id), why,
    });
    return false;
}

/// A window of the function, when it is memory the firmware or the
/// library placed, it is at least `least` bytes, and it is within what
/// this machine can address.
fn window(device: *PCIDevice, which: usize, least: usize) ?Window {
    const bar = device.bars[which];
    if (bar.address == 0 or bar.size < least) return null;
    if (bar.flags & pci.PCIBAR_IO != 0) return null;
    if (bar.address > std.math.maxInt(usize) or bar.address + bar.size > std.math.maxInt(usize)) return null;
    return .{ .at = @intCast(bar.address), .bytes = @intCast(bar.size) };
}
