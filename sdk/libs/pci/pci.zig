// SPDX-License-Identifier: MIT
//! pci.library's structures and constants: a PCI function as the library
//! keeps it, its base address registers, and the registers of its
//! configuration space a driver reads. The calls are in
//! `sdk.interface.pci`.
//!
//! **The machine's PCI is the board's.** Each host bridge is a part
//! (`PARTKIND_PCI`) that names its chip, its configuration space and the
//! windows the processor reaches the buses' memory through. The library,
//! as it is first opened, brings each bridge up, walks the buses behind
//! it, numbers the buses behind each PCI-to-PCI bridge, puts every memory
//! BAR in a window and switches the functions' memory decoding on. What
//! it found stays as it is until the machine restarts: a `PCIDevice` per
//! function, on the library's chain.
//!
//! **A driver** finds its function - FindPCIDevice by vendor and device,
//! FindPCIClass by what it is - claims it (ClaimPCIDevice), switches its
//! bus mastering on if it moves data itself (PCI_COMMAND_MASTER), reaches
//! its registers at its BAR's address, and hooks its interrupt with
//! AddPCIIntServer, which knows whether the function's INTx line is a
//! source of the interrupt controller or one its bridge gathers.
//!
//! **Memory a function reads and writes itself** is RAM below 4 GiB
//! (MEMF_DMA) for one that addresses 32 bits; the bridges let a function
//! reach RAM at the address the processor has it. The JH7110's functions
//! do not see the processors' caches: what is written for one is pushed
//! out with CachePreDMA, and what one wrote is read after CachePostDMA.

/// The library's name, for OpenLibrary.
pub const PCINAME = "pci.library";

/// FindPCIDevice's vendor or device that matches any.
pub const PCI_ANY: u32 = 0xFFFF_FFFF;

/// One base address register, as the library placed it.
pub const PCIBar = extern struct {
    /// Where the processor reaches it; 0 when it is not placed - an I/O
    /// BAR, which the library does not place, or one no window has room
    /// for.
    address: u64 align(4) = 0,
    /// Its size in bytes; 0 where the function has no BAR.
    size: u64 align(4) = 0,
    /// PCIBAR_*.
    flags: u32 = 0,
    pad: u32 = 0,
};

/// An I/O BAR.
pub const PCIBAR_IO: u32 = 1 << 0;
/// A 64-bit memory BAR: the next BAR holds its upper half, and has no
/// size of its own.
pub const PCIBAR_64: u32 = 1 << 1;
/// Memory that may be read ahead.
pub const PCIBAR_PREFETCH: u32 = 1 << 2;

/// A function on a bus, as the library found it. The library's: a driver
/// reads it and changes nothing in it.
pub const PCIDevice = extern struct {
    /// Its BARs. A 64-bit one takes two. First, where their 64-bit fields
    /// are on 8-byte places on every chip.
    bars: [6]PCIBar = @splat(.{}),
    /// The next function on the library's chain, or null.
    next: ?*PCIDevice = null,
    /// Which host bridge it is behind, from 0: the board's PCI parts in
    /// their order. Then its bus, device and function.
    segment: u8 = 0,
    bus: u8 = 0,
    device: u8 = 0,
    function: u8 = 0,
    vendor_id: u16 = 0,
    device_id: u16 = 0,
    /// Class, subclass and programming interface, PCI's 24-bit class code:
    /// PCI_CLASS_* (0x0C0330 an xHCI controller).
    class_code: u32 = 0,
    revision: u8 = 0,
    /// PCI_HEADER_NORMAL, or PCI_HEADER_BRIDGE for a PCI-to-PCI bridge.
    header_type: u8 = 0,
    /// The INTx line it raises, 1 to 4 for INTA to INTD; 0 for none.
    interrupt_pin: u8 = 0,
    pad: u8 = 0,
    subsystem_vendor: u16 = 0,
    subsystem_id: u16 = 0,
    /// The exec interrupt number its INTx line ends up on (an
    /// `sdk.hardware.intbits` source), for a listing: a driver hooks it
    /// with AddPCIIntServer, which may share it with the bridge's other
    /// lines. 0 for none.
    interrupt: u32 = 0,
    /// The driver that has claimed it (ClaimPCIDevice), or null.
    owner: ?[*:0]const u8 = null,
    /// The library's.
    private: ?*anyopaque = null,
};

// --- the configuration space ------------------------------------------------------

pub const PCI_VENDOR_ID: u32 = 0x00;
pub const PCI_DEVICE_ID: u32 = 0x02;
pub const PCI_COMMAND: u32 = 0x04;
pub const PCI_STATUS: u32 = 0x06;
pub const PCI_REVISION_ID: u32 = 0x08;
/// The programming interface, then the subclass and the class.
pub const PCI_CLASS_PROG: u32 = 0x09;
pub const PCI_CACHE_LINE_SIZE: u32 = 0x0C;
pub const PCI_LATENCY_TIMER: u32 = 0x0D;
pub const PCI_HEADER_TYPE: u32 = 0x0E;
pub const PCI_BASE_ADDRESS_0: u32 = 0x10;
pub const PCI_SUBSYSTEM_VENDOR_ID: u32 = 0x2C;
pub const PCI_SUBSYSTEM_ID: u32 = 0x2E;
pub const PCI_ROM_ADDRESS: u32 = 0x30;
pub const PCI_CAPABILITY_LIST: u32 = 0x34;
pub const PCI_INTERRUPT_LINE: u32 = 0x3C;
pub const PCI_INTERRUPT_PIN: u32 = 0x3D;

// A PCI-to-PCI bridge's (PCI_HEADER_BRIDGE).
pub const PCI_PRIMARY_BUS: u32 = 0x18;
pub const PCI_SECONDARY_BUS: u32 = 0x19;
pub const PCI_SUBORDINATE_BUS: u32 = 0x1A;
pub const PCI_IO_BASE: u32 = 0x1C;
pub const PCI_IO_LIMIT: u32 = 0x1D;
pub const PCI_MEMORY_BASE: u32 = 0x20;
pub const PCI_MEMORY_LIMIT: u32 = 0x22;
pub const PCI_PREF_MEMORY_BASE: u32 = 0x24;
pub const PCI_PREF_MEMORY_LIMIT: u32 = 0x26;
pub const PCI_PREF_BASE_UPPER32: u32 = 0x28;
pub const PCI_PREF_LIMIT_UPPER32: u32 = 0x2C;
pub const PCI_BRIDGE_CONTROL: u32 = 0x3E;

/// PCI_HEADER_TYPE: what the header is, and the bit that says the device
/// has more functions than the first.
pub const PCI_HEADER_NORMAL: u8 = 0;
pub const PCI_HEADER_BRIDGE: u8 = 1;
pub const PCI_HEADER_MULTI: u8 = 0x80;

/// PCI_COMMAND's bits.
pub const PCI_COMMAND_IO: u16 = 1 << 0;
pub const PCI_COMMAND_MEMORY: u16 = 1 << 1;
pub const PCI_COMMAND_MASTER: u16 = 1 << 2;
pub const PCI_COMMAND_SERR: u16 = 1 << 8;
pub const PCI_COMMAND_INTX_DISABLE: u16 = 1 << 10;

/// PCI_STATUS: the function has a capability list.
pub const PCI_STATUS_CAP_LIST: u16 = 1 << 4;

/// A BAR's low bits.
pub const PCI_BASE_ADDRESS_SPACE_IO: u32 = 1 << 0;
pub const PCI_BASE_ADDRESS_MEM_TYPE_64: u32 = 2 << 1;
pub const PCI_BASE_ADDRESS_MEM_PREFETCH: u32 = 1 << 3;

/// Capability IDs, on the list at PCI_CAPABILITY_LIST.
pub const PCI_CAP_ID_PM: u8 = 0x01;
pub const PCI_CAP_ID_MSI: u8 = 0x05;
pub const PCI_CAP_ID_EXP: u8 = 0x10;
pub const PCI_CAP_ID_MSIX: u8 = 0x11;

/// A PCI Express capability's port type (bits 4 to 7 of its second
/// half-word): a root port and a switch's downstream port each have one
/// device below them.
pub const PCI_EXP_TYPE_ROOT_PORT: u8 = 4;
pub const PCI_EXP_TYPE_DOWNSTREAM: u8 = 6;

/// Class codes (class, subclass, programming interface).
pub const PCI_CLASS_BRIDGE_PCI: u32 = 0x06_04_00;
pub const PCI_CLASS_SERIAL_USB_UHCI: u32 = 0x0C_03_00;
pub const PCI_CLASS_SERIAL_USB_OHCI: u32 = 0x0C_03_10;
pub const PCI_CLASS_SERIAL_USB_EHCI: u32 = 0x0C_03_20;
pub const PCI_CLASS_SERIAL_USB_XHCI: u32 = 0x0C_03_30;
/// The mask that compares a whole class code.
pub const PCI_CLASS_MASK: u32 = 0xFF_FF_FF;
