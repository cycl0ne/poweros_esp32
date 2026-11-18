// SPDX-License-Identifier: MIT
//! VIA Labs' VL805 (PCI 1106:3483), an xHCI on PCI Express, given its
//! code where it has none. The VL805 runs code of its own, which it reads
//! from an EEPROM beside it where the board has one; on the Raspberry Pi
//! 4 Model B the VideoCore's firmware has the code and loads it over the
//! bus once it is told the function's address - its property tag
//! NOTIFY_XHCI_RESET with bus << 20 | device << 15 | function << 12, as
//! Linux's firmware driver sends it. PERST# takes the code away again,
//! and the firmware resets the port before it starts the ARM, so this is
//! asked at every start of the unit, UHCMD_USBRESET's too.
//!
//! The version of the code it runs is in the function's configuration
//! space at 0x50, 0 while it runs none: a VL805 that has its code - from
//! its EEPROM, or from an earlier start - is left alone, and one given it
//! is waited for until it says so. Nothing is done for any other
//! function, or on a board without the firmware (CHIP_RPI_FIRMWARE).

const sdk = @import("sdk");
const exec = sdk.exec;
const videocore = sdk.hardware.videocore;
const _xhci = @import("_xhci.zig");
const Host = _xhci.Host;

const VENDOR_VIA: u16 = 0x1106;
const DEVICE_VL805: u16 = 0x3483;
/// Where the function says which code it runs: 0 for none.
const VL805_CODE_VERSION: u32 = 0x50;
/// The firmware's tag that loads it.
const TAG_NOTIFY_XHCI_RESET: u32 = 0x0003_0058;
/// How long the function is given to run the code once the firmware was
/// told, asked every `step_ms`.
const load_ms: u32 = 1000;
const step_ms: u32 = 10;

/// The unit's function given its code where it is a VL805 that runs none
/// and the board's firmware has it (see the top), and waited for until it
/// runs it. On the unit's task, with its timers open.
pub fn load(host: *Host) void {
    const function = host.function orelse return;
    const mailbox = host.dev_base.firmware;
    if (mailbox == 0 or function.vendor_id != VENDOR_VIA or function.device_id != DEVICE_VL805) return;
    const pb = host.dev_base.pci_base.?;
    if (pb.ReadPCIConfig(function, VL805_CODE_VERSION, 4) != 0) return;
    const sys = host.sys;
    const bytes = 2 * videocore.buffer_bytes;
    const memory = sys.AllocMem(bytes, exec.MEMF_DMA) orelse return;
    defer sys.FreeMem(memory, bytes);
    const buffer = videocore.bufferIn(memory) orelse return;
    var address = [_]u32{@as(u32, function.bus) << 20 | @as(u32, function.device) << 15 | @as(u32, function.function) << 12};
    // The answer may come late, while the code is still loading; the
    // version says when it runs, either way.
    const answered = videocore.call(sys, mailbox, buffer, TAG_NOTIFY_XHCI_RESET, &address);
    var waited: u32 = 0;
    while (true) : (waited += step_ms) {
        const version = pb.ReadPCIConfig(function, VL805_CODE_VERSION, 4);
        if (version != 0) {
            sdk.exec.klog(sys, exec.LOG_DEBUG, "%s: unit %d: the VL805 runs the firmware's code, version %08x\n", .{ _xhci.DEVICE_NAME, host.number, version });
            return;
        }
        if (waited >= load_ms) break;
        _xhci.delay(host, step_ms);
    }
    sdk.exec.kprintf(sys, "%s: unit %d: the VL805 runs no code: %s\n", .{
        _xhci.DEVICE_NAME,
        host.number,
        @as([*:0]const u8, if (answered) "the firmware loaded none" else "the firmware did not answer"),
    });
}
