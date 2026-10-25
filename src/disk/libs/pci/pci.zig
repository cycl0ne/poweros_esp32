// SPDX-License-Identifier: MIT
//! pci.library: the machine's PCI and PCI Express functions, on the disk
//! in LIBS:, and in the ROM of a board that carries it (the VisionFive
//! 2's, for its SSD: `src/boards/visionfive2/romtags.zig`).
//! As it is first opened it brings up the board's host bridges
//! (PARTKIND_PCI), walks the buses behind them, numbers them, places the
//! functions' memory and I/O and keeps a PCIDevice for each function; a
//! driver finds its function, claims it, reads and writes its
//! configuration space, finds its capabilities, hooks its INTx line or
//! its message-signalled interrupts, and resets it through the library.
//!
//! The jump table is pci_lvo.zig, the ROM tag, the init and the expunge
//! pci_init.zig, the base pci_base.zig, the timer waits delay.zig. The
//! walk is scan/ - `scan.zig` what is there, `place.zig` where it goes -
//! the host bridges host/ - `_host.zig` what both have, `ecam.zig`
//! QEMU's, and `jh7110.zig` the JH7110's PCI Express ports. Each call is
//! a file under its area: `find/`, `config/`, `claim/`, `interrupt/`
//! (`_vectors.zig` MSI and MSI-X), `reset/`.

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
fn programEntry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{pci_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
const version_tag: [pci_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = pci_init.LIBRARY_VERSION_STRING.*;

/// Whether this is the ROM's copy: the kernel's root lists the ROM's
/// modules, a program's does not.
const in_rom = @hasDecl(@import("root"), "rom_modules");

// The file's entry and its version string, which only the file has: in
// the ROM there is no file, and every module the ROM takes from the disk
// would bring its own by the same names.
comptime {
    if (!in_rom) {
        @export(&programEntry, .{ .name = "_program_entry" });
        @export(&version_tag, .{ .name = "version_tag" });
    }
}
