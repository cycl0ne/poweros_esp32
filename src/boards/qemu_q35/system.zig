// SPDX-License-Identifier: MPL-2.0
//! QEMU's q35 machine, started by UEFI firmware (`./zig build q35`:
//! `-machine q35 -cpu max -m 512` with the emulator's own UEFI firmware in
//! its flash): 512 MiB of RAM from the bottom of the address space, a
//! 16550 console at I/O port 0x3F8 on the machine's interrupt line 4, and
//! a local interrupt controller per core with the machine's I/O controller
//! in front of it. The firmware's own tables say where those controllers
//! are, how many cores there are, where PCI's configuration space is, and
//! which port the clock whose rate is fixed is on, so none of that is
//! written here.
//!
//! What is true of the board is written down here once, as the system tag
//! list the ROM carries for expansion.library (a part per SYSTAG_Part). The
//! kernel reads the same list at compile time (`boards.fact`).
//!
//! **The parts are the firmware's to say.** Where the framebuffer is and
//! where PCI's configuration space is differ from machine to machine and
//! only the firmware knows them, so they are not written here: the list
//! below carries room for them, and the kernel fills it in from the
//! handover and the firmware's tables before expansion.library starts
//! (`addPart`). From every module's side the machine is still described
//! and not discovered - the description is simply assembled by the one
//! piece of code that is allowed to know the machine.

const sdk = @import("sdk");
const exec = sdk.exec;
const st = sdk.expansion.systemtags;
const Tag = sdk.utility.FixedTagItem;

/// The machine, as QEMU names it.
const name = "QEMU q35";

/// The picture the firmware lights on this machine, for whoever draws on
/// it later. The handover carries the figures the firmware actually chose.
const screen = struct {
    pub const width: u32 = 1280;
    pub const height: u32 = 800;
};

/// The USB bus of an xHCI controller added with `-device qemu-xhci`, and
/// of one on a real machine: the first xHCI function on PCI. Without one,
/// xhci.device finds none and the bus does not start. The machine's own
/// older keyboard and mouse ports are not driven: what is plugged into a
/// machine of this kind today is USB.
const usb = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_USB),
    .value(st.PART_Chip, st.CHIP_XHCI),
    .pointer(st.PART_ChipName, "xhci"),
    .value(st.PART_Bus, st.BUS_PCI),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_UsbRoles, st.USBROLE_HOST),
    .value(st.PART_UsbSpeed, st.USBSPEED_HIGH),
    .value(st.PART_UsbVbus, st.USBVBUS_ALWAYS),
    .pointer(st.PART_Label, "USB"),
    .done,
};

/// The root list: the board's own facts, which the kernel reads at compile
/// time (`boards.fact`). The parts come from the firmware, through
/// `addPart` into `list`.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    // Where the machine's memory starts and how much of it there may be.
    // These stand in only for a handover that listed none: the firmware
    // describes this machine's memory itself, and the stub passes it on.
    .value(st.SYSTAG_RamBase, 0x10_0000),
    .value(st.SYSTAG_RamSize, 512 * 1024 * 1024),
    .value(st.SYSTAG_RamEnd, 0x1_0000_0000),
    .value(st.SYSTAG_UnifiedMemory, 1),
    // The architecture keeps what a device reads and what a core has in
    // its cache the same, on every machine of it.
    .value(st.SYSTAG_DmaCoherent, 1),
    // What the counter's rate is taken to be where it could not be
    // measured: the emulator's counts at a gigahertz.
    .value(st.SYSTAG_Timebase, 1_000_000_000),
    // The console: the machine's first serial port, which the firmware set
    // up and left running and which the stub has already written to. Its
    // divisor's clock has been the same since the part was a chip of its
    // own, and the old line it sits on is 4.
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_ConsoleBase, 0x3F8),
    .value(st.SYSTAG_ConsoleClock, 1_843_200),
    .value(st.SYSTAG_ConsoleIrq, 4),
    // As many as `-smp` gives the machine, up to four. The kernel runs on
    // the boot core alone until it can start the others.
    .value(st.SYSTAG_Cores, 4),
    .value(st.SYSTAG_ScreenWidth, screen.width),
    .value(st.SYSTAG_ScreenHeight, screen.height),
    .pointer(st.SYSTAG_Part, &usb),
    .done,
};

/// How many parts only the firmware can describe: the panel it lit, the
/// battery-backed clock it says the machine has, where PCI's
/// configuration space is, and the machine's power management.
pub const firmware_parts = 4;

/// The list expansion.library reads: the board's own facts, then a slot
/// for each part the firmware described, then the end. Until the kernel
/// fills a slot it is the end of the list, so a kernel that found nothing
/// hands over the board's facts alone.
///
/// A variable, where every other board's list is in the image as it stands:
/// on this machine a part may exist only because the firmware said so, and
/// no static list can say that. What SystemTags promises holds all the
/// same - the list is the board's own, nothing allocated it, and it lives
/// as long as the machine does.
pub var list: [root.len + firmware_parts]Tag = made: {
    var assembled: [root.len + firmware_parts]Tag = @splat(.done);
    for (root[0 .. root.len - 1], 0..) |item, at| assembled[at] = item;
    break :made assembled;
};

/// `part`'s tag list added to the board's, in the first slot left: the
/// kernel's to call, before expansion.library starts. False where the
/// slots are full, which is `firmware_parts` to raise here rather than a
/// part to drop quietly.
pub fn addPart(part: [*]const Tag) bool {
    var at = root.len - 1;
    while (at + 1 < list.len) : (at += 1) {
        if (list[at].tag != sdk.utility.TAG_DONE) continue;
        list[at] = .pointer(st.SYSTAG_Part, part);
        list[at + 1] = .done;
        return true;
    }
    return false;
}

/// The ROM tag the list is in. No start flags: there is nothing to start,
/// and expansion.library finds it by name.
pub export const system_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &system_tag,
    .version = 1,
    .type = .board,
    .name = sdk.expansion.SYSTEM_RESIDENT,
    .id_string = name,
    .init = &list,
};
