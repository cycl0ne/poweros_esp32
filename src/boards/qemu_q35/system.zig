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
//! **What this machine has and this list does not say yet.** The firmware
//! lights a framebuffer and hands over where it is, which wants a kind of
//! its own in the fb display driver before there is anything to declare;
//! and PCI's host bridge is in the firmware's tables rather than here,
//! which is the one part of this machine that cannot be written down in
//! advance. Both are the next items of the list in `todo/port_x86_64/`.

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

/// The root list: the board's own facts. It has no parts yet - everything
/// this machine has beyond its console is in the firmware's tables, and
/// what the kernel makes of those is item 5 of the list.
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
    .done,
};

/// The ROM tag the list is in. No start flags: there is nothing to start,
/// and expansion.library finds it by name.
pub export const system_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &system_tag,
    .version = 1,
    .type = .board,
    .name = sdk.expansion.SYSTEM_RESIDENT,
    .id_string = name,
    .init = &root,
};
