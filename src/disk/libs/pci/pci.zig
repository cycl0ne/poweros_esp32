// SPDX-License-Identifier: MIT
//! pci.library: the machine's PCI and PCI Express functions, on the disk
//! in LIBS:. As it is first opened it brings up the board's host bridges
//! (PARTKIND_PCI), walks the buses behind them, numbers them, places the
//! functions' memory and keeps a PCIDevice for each function; a driver
//! finds its function, claims it, reads and writes its configuration
//! space and hooks its INTx line through the library.
//!
//! The jump table is pci_lvo.zig, the ROM tag, the init and the expunge
//! pci_init.zig, the base pci_base.zig. The walk is scan/, the host
//! bridges host/ - `_host.zig` what both have, `ecam.zig` QEMU's, and
//! `jh7110.zig` the JH7110's PCI Express ports. Each call is a file
//! under its area: `find/`, `config/`, `claim/`, `interrupt/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const pci_init = @import("pci_init.zig");

comptime {
    _ = &pci_init.pci_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const pci_library_tag = pci_init.pci_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{pci_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [pci_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = pci_init.LIBRARY_VERSION_STRING.*;
