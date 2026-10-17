// SPDX-License-Identifier: MPL-2.0
//! QEMU's RISC-V 64 `virt` machine under the OpenSBI QEMU brings
//! (`./zig build virt`): 512 MiB of RAM at 0x80000000, a 16550 console
//! at 0x10000000 with byte-wide registers one after the other (QEMU
//! gives its divisor a 3.6864 MHz clock) on PLIC source 10, a 10 MHz
//! timebase, and the PLIC's contexts two per hart, machine mode first.
//!
//! What is true of the board is written down here once, as the system tag
//! list the ROM carries for expansion.library (a part per SYSTAG_Part). The
//! kernel reads the same list at compile time (`boards.fact`).

const sdk = @import("sdk");
const exec = sdk.exec;
const Tag = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;

/// The machine, as QEMU names it.
const name = "QEMU RISC-V virt";

/// The root list: the board's own facts and a SYSTAG_Part per part.
/// `boards.fact` reads it at compile time for the kernel.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    .value(st.SYSTAG_RamBase, 0x8000_0000),
    .value(st.SYSTAG_RamSize, 512 * 1024 * 1024),
    .value(st.SYSTAG_Timebase, 10_000_000),
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_ConsoleBase, 0x1000_0000),
    .value(st.SYSTAG_ConsoleShift, 0),
    .value(st.SYSTAG_ConsoleWide, 0),
    .value(st.SYSTAG_ConsoleClock, 3_686_400),
    .value(st.SYSTAG_ConsoleIrq, 10),
    .value(st.SYSTAG_PlicFirst, 1),
    .value(st.SYSTAG_PlicStride, 2),
    .value(st.SYSTAG_Cores, 1),
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
