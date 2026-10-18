// SPDX-License-Identifier: MIT
//! pci.library's structures and constants: a PCI function as the library
//! keeps it, its base address registers, and the registers of its
//! configuration space a driver reads. The calls are in
//! `sdk.interface.pci`.
//!
//! **The machine's PCI is the board's.** Each host bridge is a part
//! (`PARTKIND_PCI`) that names its chip, its configuration space and the
//! windows the processor reaches the buses' memory and I/O space through.
//! The library, as it is first opened, brings every bridge up - their
//! links trained side by side - and walks the buses behind each: every
//! function found, woken from a power-saving state, the buses behind each
//! PCI-to-PCI bridge numbered, every BAR and expansion ROM sized and
//! placed in a window, each bridge's windows made as large as what is
//! behind it, and the functions' decoding switched on. What it found
//! stays as it is until the machine restarts: a `PCIDevice` per function,
//! on the library's chain, in the order of the walk.
//!
//! **A driver** finds its function - FindPCIDevice by vendor and device,
//! FindPCIClass by what it is - claims it (ClaimPCIDevice), switches its
//! bus mastering on if it moves data itself (PCI_COMMAND_MASTER), reaches
//! its registers at its BAR's address, and hooks its interrupt: with
//! AllocPCIVectors and AddPCIVectorServer where the function and the host
//! bridge have message-signalled interrupts, with AddPCIIntServer on its
//! INTx line otherwise. FindPCICapability and FindPCIExtCapability find
//! its capabilities; ResetPCIDevice resets it and puts back what the
//! library set up.
//!
//! **Memory a function reads and writes itself** is RAM at the address
//! the processor has it: the bridges let a function reach all of it. A
//! function that addresses 32 bits needs RAM below 4 GiB (MEMF_DMA).
//! Where a function sees the processors' caches - `dma_coherent`, as it
//! is behind both of the JH7110's bridges and on QEMU - nothing more is
//! needed. Where it does not, what is written for it is pushed out with
//! CachePreDMA, and what it wrote is read after CachePostDMA.

/// The library's name, for OpenLibrary.
pub const PCINAME = "pci.library";

/// FindPCIDevice's vendor or device that matches any.
pub const PCI_ANY: u32 = 0xFFFF_FFFF;

/// One base address register, or the expansion ROM, as the library
/// placed it.
pub const PCIBar = extern struct {
    /// Where the processor reaches it - for an I/O BAR, the port's place
    /// in the host bridge's I/O window; 0 when it is not placed: no
    /// window has room for it, or the host bridge has no window of its
    /// kind.
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
/// The expansion ROM: placed, its decoding off until a driver sets
/// PCI_ROM_ADDRESS_ENABLE in its register (`romRegister`).
pub const PCIBAR_ROM: u32 = 1 << 3;

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
    /// PCI_HEADER_NORMAL, PCI_HEADER_BRIDGE for a PCI-to-PCI bridge, or
    /// PCI_HEADER_CARDBUS.
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

    // --- since 2 -------------------------------------------------------------

    /// The PCI-to-PCI bridge it is behind; null on the host bridge's own
    /// bus.
    parent: ?*PCIDevice = null,
    /// Its expansion ROM (PCIBAR_ROM); size 0 for none.
    rom: PCIBar = .{},
    /// A bridge's buses: the one behind it, and the last one below it.
    /// Both 0 for a function that is no bridge.
    secondary_bus: u8 = 0,
    subordinate_bus: u8 = 0,
    /// Its PCI Express port type (PCI_EXP_TYPE_*); PCI_EXP_TYPE_NONE for
    /// a function without the PCI Express capability: a PCI one.
    express_type: u8 = PCI_EXP_TYPE_NONE,
    /// Where its power was when the library found it, 0 to 3 for D0 to
    /// D3hot. Every function is in D0 once the walk is done.
    found_power: u8 = 0,
    /// Its PCI Express link: the speed it trained to and the most it
    /// goes, in generations (1: 2.5 GT/s, 2: 5 GT/s, 3: 8 GT/s ...), and
    /// the lanes, as it trained and at most. All 0 without one. A port's
    /// is the link below it; an endpoint's the one above.
    link_speed: u8 = 0,
    link_width: u8 = 0,
    link_max_speed: u8 = 0,
    link_max_width: u8 = 0,
    /// The message-signalled interrupts it offers: MSI's vectors (1 to
    /// 32) and the size of its MSI-X table (1 to 2048); 0 for none.
    msi_vectors: u8 = 0,
    /// Which kind AllocPCIVectors gave it (PCI_VECTORS_*), and how many.
    vector_kind: u8 = PCI_VECTORS_NONE,
    msix_vectors: u16 = 0,
    vectors: u16 = 0,
    /// The largest payload its PCI Express transactions carry, as the
    /// library set it for every function behind the host bridge, in
    /// bytes; 0 without PCI Express.
    max_payload: u16 = 0,
    /// The windows a PCI-to-PCI bridge has (PCI_WINDOW_*), besides its
    /// memory window, which every bridge has; 0 for a function that is
    /// no bridge. A window it has not reads as one at 0.
    bridge_windows: u8 = 0,

    // --- since 2.1 -----------------------------------------------------------

    /// Whether what the function reads and writes in RAM sees the
    /// processors' caches, as its host bridge has it: then its driver
    /// needs neither CachePreDMA nor CachePostDMA for it. Read it only
    /// from revision 1 on (`lib_Revision`); before, take it as false.
    dma_coherent: bool = false,
};

/// PCIDevice.vector_kind: none, MSI or MSI-X.
pub const PCI_VECTORS_NONE: u8 = 0;
pub const PCI_VECTORS_MSI: u8 = 1;
pub const PCI_VECTORS_MSIX: u8 = 2;

/// PCIDevice.bridge_windows: an I/O window, and 32 bits of it rather
/// than 16; a prefetchable memory window, and 64 bits of it rather than
/// 32.
pub const PCI_WINDOW_IO: u8 = 1 << 0;
pub const PCI_WINDOW_IO32: u8 = 1 << 1;
pub const PCI_WINDOW_PREF: u8 = 1 << 2;
pub const PCI_WINDOW_PREF64: u8 = 1 << 3;

/// Where a function's expansion ROM register is.
pub fn romRegister(device: *const PCIDevice) u32 {
    return if (device.header_type == PCI_HEADER_BRIDGE) PCI_ROM_ADDRESS1 else PCI_ROM_ADDRESS;
}

// --- the configuration space ------------------------------------------------------

pub const PCI_VENDOR_ID: u32 = 0x00;
pub const PCI_DEVICE_ID: u32 = 0x02;
pub const PCI_COMMAND: u32 = 0x04;
pub const PCI_STATUS: u32 = 0x06;
pub const PCI_REVISION_ID: u32 = 0x08;
/// The programming interface, then the subclass and the class.
pub const PCI_CLASS_PROG: u32 = 0x09;
pub const PCI_CLASS_DEVICE: u32 = 0x0A;
pub const PCI_CACHE_LINE_SIZE: u32 = 0x0C;
pub const PCI_LATENCY_TIMER: u32 = 0x0D;
pub const PCI_HEADER_TYPE: u32 = 0x0E;
pub const PCI_BIST: u32 = 0x0F;
pub const PCI_BASE_ADDRESS_0: u32 = 0x10;
pub const PCI_CARDBUS_CIS: u32 = 0x28;
pub const PCI_SUBSYSTEM_VENDOR_ID: u32 = 0x2C;
pub const PCI_SUBSYSTEM_ID: u32 = 0x2E;
pub const PCI_ROM_ADDRESS: u32 = 0x30;
pub const PCI_CAPABILITY_LIST: u32 = 0x34;
pub const PCI_INTERRUPT_LINE: u32 = 0x3C;
pub const PCI_INTERRUPT_PIN: u32 = 0x3D;
pub const PCI_MIN_GNT: u32 = 0x3E;
pub const PCI_MAX_LAT: u32 = 0x3F;

// A PCI-to-PCI bridge's (PCI_HEADER_BRIDGE).
pub const PCI_PRIMARY_BUS: u32 = 0x18;
pub const PCI_SECONDARY_BUS: u32 = 0x19;
pub const PCI_SUBORDINATE_BUS: u32 = 0x1A;
pub const PCI_SEC_LATENCY_TIMER: u32 = 0x1B;
pub const PCI_IO_BASE: u32 = 0x1C;
pub const PCI_IO_LIMIT: u32 = 0x1D;
pub const PCI_SEC_STATUS: u32 = 0x1E;
pub const PCI_MEMORY_BASE: u32 = 0x20;
pub const PCI_MEMORY_LIMIT: u32 = 0x22;
pub const PCI_PREF_MEMORY_BASE: u32 = 0x24;
pub const PCI_PREF_MEMORY_LIMIT: u32 = 0x26;
pub const PCI_PREF_BASE_UPPER32: u32 = 0x28;
pub const PCI_PREF_LIMIT_UPPER32: u32 = 0x2C;
pub const PCI_IO_BASE_UPPER16: u32 = 0x30;
pub const PCI_IO_LIMIT_UPPER16: u32 = 0x32;
pub const PCI_ROM_ADDRESS1: u32 = 0x38;
pub const PCI_BRIDGE_CONTROL: u32 = 0x3E;

/// PCI_IO_BASE and PCI_PREF_MEMORY_BASE's low bits: whether the window
/// is 16 or 32 bits (I/O), 32 or 64 bits (prefetchable memory).
pub const PCI_IO_RANGE_TYPE_MASK: u32 = 0x0F;
pub const PCI_IO_RANGE_TYPE_32: u32 = 0x01;
pub const PCI_PREF_RANGE_TYPE_MASK: u32 = 0x0F;
pub const PCI_PREF_RANGE_TYPE_64: u32 = 0x01;

/// PCI_BRIDGE_CONTROL: the bus behind it held in reset.
pub const PCI_BRIDGE_CTL_BUS_RESET: u16 = 1 << 6;

/// PCI_HEADER_TYPE: what the header is, and the bit that says the device
/// has more functions than the first.
pub const PCI_HEADER_NORMAL: u8 = 0;
pub const PCI_HEADER_BRIDGE: u8 = 1;
pub const PCI_HEADER_CARDBUS: u8 = 2;
pub const PCI_HEADER_MULTI: u8 = 0x80;

/// PCI_COMMAND's bits.
pub const PCI_COMMAND_IO: u16 = 1 << 0;
pub const PCI_COMMAND_MEMORY: u16 = 1 << 1;
pub const PCI_COMMAND_MASTER: u16 = 1 << 2;
pub const PCI_COMMAND_PARITY: u16 = 1 << 6;
pub const PCI_COMMAND_SERR: u16 = 1 << 8;
pub const PCI_COMMAND_INTX_DISABLE: u16 = 1 << 10;

/// PCI_STATUS's bits.
pub const PCI_STATUS_INTERRUPT: u16 = 1 << 3;
pub const PCI_STATUS_CAP_LIST: u16 = 1 << 4;
pub const PCI_STATUS_66MHZ: u16 = 1 << 5;

/// A BAR's low bits.
pub const PCI_BASE_ADDRESS_SPACE_IO: u32 = 1 << 0;
pub const PCI_BASE_ADDRESS_MEM_TYPE_MASK: u32 = 3 << 1;
pub const PCI_BASE_ADDRESS_MEM_TYPE_64: u32 = 2 << 1;
pub const PCI_BASE_ADDRESS_MEM_PREFETCH: u32 = 1 << 3;
/// The expansion ROM register's: its decoding on, and the address bits.
pub const PCI_ROM_ADDRESS_ENABLE: u32 = 1 << 0;
pub const PCI_ROM_ADDRESS_MASK: u32 = 0xFFFF_F800;

// --- capabilities -----------------------------------------------------------------

/// Capability IDs, on the list at PCI_CAPABILITY_LIST.
pub const PCI_CAP_ID_PM: u8 = 0x01;
pub const PCI_CAP_ID_AGP: u8 = 0x02;
pub const PCI_CAP_ID_VPD: u8 = 0x03;
pub const PCI_CAP_ID_SLOTID: u8 = 0x04;
pub const PCI_CAP_ID_MSI: u8 = 0x05;
pub const PCI_CAP_ID_CHSWP: u8 = 0x06;
pub const PCI_CAP_ID_PCIX: u8 = 0x07;
pub const PCI_CAP_ID_HT: u8 = 0x08;
pub const PCI_CAP_ID_VNDR: u8 = 0x09;
pub const PCI_CAP_ID_DBG: u8 = 0x0A;
pub const PCI_CAP_ID_CCRC: u8 = 0x0B;
pub const PCI_CAP_ID_SHPC: u8 = 0x0C;
pub const PCI_CAP_ID_SSVID: u8 = 0x0D;
pub const PCI_CAP_ID_AGP3: u8 = 0x0E;
pub const PCI_CAP_ID_SECDEV: u8 = 0x0F;
pub const PCI_CAP_ID_EXP: u8 = 0x10;
pub const PCI_CAP_ID_MSIX: u8 = 0x11;
pub const PCI_CAP_ID_SATA: u8 = 0x12;
pub const PCI_CAP_ID_AF: u8 = 0x13;
pub const PCI_CAP_ID_EA: u8 = 0x14;

/// Extended capability IDs, on the list from 0x100 of a PCI Express
/// function's 4 KiB.
pub const PCI_EXT_CAP_ID_ERR: u16 = 0x01;
pub const PCI_EXT_CAP_ID_VC: u16 = 0x02;
pub const PCI_EXT_CAP_ID_DSN: u16 = 0x03;
pub const PCI_EXT_CAP_ID_PWR: u16 = 0x04;
pub const PCI_EXT_CAP_ID_RCLD: u16 = 0x05;
pub const PCI_EXT_CAP_ID_RCILC: u16 = 0x06;
pub const PCI_EXT_CAP_ID_RCEC: u16 = 0x07;
pub const PCI_EXT_CAP_ID_MFVC: u16 = 0x08;
pub const PCI_EXT_CAP_ID_VC9: u16 = 0x09;
pub const PCI_EXT_CAP_ID_RCRB: u16 = 0x0A;
pub const PCI_EXT_CAP_ID_VNDR: u16 = 0x0B;
pub const PCI_EXT_CAP_ID_CAC: u16 = 0x0C;
pub const PCI_EXT_CAP_ID_ACS: u16 = 0x0D;
pub const PCI_EXT_CAP_ID_ARI: u16 = 0x0E;
pub const PCI_EXT_CAP_ID_ATS: u16 = 0x0F;
pub const PCI_EXT_CAP_ID_SRIOV: u16 = 0x10;
pub const PCI_EXT_CAP_ID_MRIOV: u16 = 0x11;
pub const PCI_EXT_CAP_ID_MCAST: u16 = 0x12;
pub const PCI_EXT_CAP_ID_PRI: u16 = 0x13;
pub const PCI_EXT_CAP_ID_AMD_XXX: u16 = 0x14;
pub const PCI_EXT_CAP_ID_REBAR: u16 = 0x15;
pub const PCI_EXT_CAP_ID_DPA: u16 = 0x16;
pub const PCI_EXT_CAP_ID_TPH: u16 = 0x17;
pub const PCI_EXT_CAP_ID_LTR: u16 = 0x18;
pub const PCI_EXT_CAP_ID_SECPCI: u16 = 0x19;
pub const PCI_EXT_CAP_ID_PMUX: u16 = 0x1A;
pub const PCI_EXT_CAP_ID_PASID: u16 = 0x1B;
pub const PCI_EXT_CAP_ID_DPC: u16 = 0x1D;
pub const PCI_EXT_CAP_ID_L1SS: u16 = 0x1E;
pub const PCI_EXT_CAP_ID_PTM: u16 = 0x1F;
pub const PCI_EXT_CAP_ID_DVSEC: u16 = 0x23;
pub const PCI_EXT_CAP_ID_DLF: u16 = 0x25;
pub const PCI_EXT_CAP_ID_PL_16GT: u16 = 0x26;
pub const PCI_EXT_CAP_ID_PL_32GT: u16 = 0x2A;
pub const PCI_EXT_CAP_ID_DOE: u16 = 0x2E;

/// Where the extended capabilities start.
pub const PCI_CFG_SPACE_SIZE: u32 = 0x100;
/// A PCI Express function's whole configuration space.
pub const PCI_CFG_SPACE_EXP_SIZE: u32 = 0x1000;

/// Power management (PCI_CAP_ID_PM): its capabilities, and its control
/// and status, whose low two bits are the power state (0 to 3: D0 to
/// D3hot).
pub const PCI_PM_PMC: u32 = 2;
pub const PCI_PM_CTRL: u32 = 4;
pub const PCI_PM_CTRL_STATE_MASK: u16 = 0x3;
/// PCI_PM_CTRL: the function keeps its configuration over D3hot to D0.
pub const PCI_PM_CTRL_NO_SOFT_RESET: u16 = 1 << 3;

/// MSI (PCI_CAP_ID_MSI): its control word, the address the messages go
/// to, and the data they carry - the data and the mask after the upper
/// address where the address is 64 bits.
pub const PCI_MSI_FLAGS: u32 = 2;
pub const PCI_MSI_ADDRESS_LO: u32 = 4;
pub const PCI_MSI_ADDRESS_HI: u32 = 8;
pub const PCI_MSI_DATA_32: u32 = 8;
pub const PCI_MSI_DATA_64: u32 = 12;
pub const PCI_MSI_MASK_32: u32 = 12;
pub const PCI_MSI_MASK_64: u32 = 16;
pub const PCI_MSI_FLAGS_ENABLE: u16 = 1 << 0;
/// How many vectors it may have, 2^n (bits 1 to 3), and how many it has
/// been given (4 to 6).
pub const PCI_MSI_FLAGS_QMASK: u16 = 0x7 << 1;
pub const PCI_MSI_FLAGS_QSIZE: u16 = 0x7 << 4;
pub const PCI_MSI_FLAGS_64BIT: u16 = 1 << 7;
pub const PCI_MSI_FLAGS_MASKBIT: u16 = 1 << 8;

/// MSI-X (PCI_CAP_ID_MSIX): its control word, and where its table and
/// its pending bits are - a BAR's number in the low three bits, the
/// offset into it above.
pub const PCI_MSIX_FLAGS: u32 = 2;
pub const PCI_MSIX_TABLE: u32 = 4;
pub const PCI_MSIX_PBA: u32 = 8;
pub const PCI_MSIX_FLAGS_QSIZE: u16 = 0x7FF;
pub const PCI_MSIX_FLAGS_MASKALL: u16 = 1 << 14;
pub const PCI_MSIX_FLAGS_ENABLE: u16 = 1 << 15;
pub const PCI_MSIX_TABLE_BIR: u32 = 0x7;
pub const PCI_MSIX_TABLE_OFFSET: u32 = 0xFFFF_FFF8;
/// A table entry: 16 bytes, the address, the data, the vector's mask.
pub const PCI_MSIX_ENTRY_SIZE: u32 = 16;
pub const PCI_MSIX_ENTRY_LOWER_ADDR: u32 = 0;
pub const PCI_MSIX_ENTRY_UPPER_ADDR: u32 = 4;
pub const PCI_MSIX_ENTRY_DATA: u32 = 8;
pub const PCI_MSIX_ENTRY_VECTOR_CTRL: u32 = 12;
pub const PCI_MSIX_ENTRY_CTRL_MASKBIT: u32 = 1 << 0;

/// The PCI Express capability (PCI_CAP_ID_EXP): its registers, from the
/// capability's start.
pub const PCI_EXP_FLAGS: u32 = 0x02;
pub const PCI_EXP_DEVCAP: u32 = 0x04;
pub const PCI_EXP_DEVCTL: u32 = 0x08;
pub const PCI_EXP_DEVSTA: u32 = 0x0A;
pub const PCI_EXP_LNKCAP: u32 = 0x0C;
pub const PCI_EXP_LNKCTL: u32 = 0x10;
pub const PCI_EXP_LNKSTA: u32 = 0x12;
pub const PCI_EXP_SLTCAP: u32 = 0x14;
pub const PCI_EXP_SLTCTL: u32 = 0x18;
pub const PCI_EXP_SLTSTA: u32 = 0x1A;
pub const PCI_EXP_RTCTL: u32 = 0x1C;
pub const PCI_EXP_RTCAP: u32 = 0x1E;
pub const PCI_EXP_RTSTA: u32 = 0x20;
pub const PCI_EXP_DEVCAP2: u32 = 0x24;
pub const PCI_EXP_DEVCTL2: u32 = 0x28;
pub const PCI_EXP_LNKCAP2: u32 = 0x2C;
pub const PCI_EXP_LNKCTL2: u32 = 0x30;
/// PCI_EXP_FLAGS: the port type, bits 4 to 7.
pub const PCI_EXP_FLAGS_TYPE: u16 = 0xF << 4;
/// PCI_EXP_DEVCAP: the largest payload it takes, 128 << n (bits 0 to 2),
/// and whether it resets on its own (function level reset).
pub const PCI_EXP_DEVCAP_PAYLOAD: u32 = 0x7;
pub const PCI_EXP_DEVCAP_FLR: u32 = 1 << 28;
/// PCI_EXP_DEVCTL: the payload it is set to (bits 5 to 7), and the bit
/// that starts its function level reset.
pub const PCI_EXP_DEVCTL_PAYLOAD: u16 = 0x7 << 5;
pub const PCI_EXP_DEVCTL_BCR_FLR: u16 = 1 << 15;
/// PCI_EXP_DEVSTA: transactions it still has outstanding.
pub const PCI_EXP_DEVSTA_TRPND: u16 = 1 << 5;
/// PCI_EXP_LNKCAP and PCI_EXP_LNKSTA: the speed (bits 0 to 3) and the
/// width (4 to 9); whether the port reports its data link layer's state,
/// and that state.
pub const PCI_EXP_LNKCAP_SLS: u32 = 0xF;
pub const PCI_EXP_LNKCAP_MLW: u32 = 0x3F << 4;
pub const PCI_EXP_LNKCAP_DLLLARC: u32 = 1 << 20;
pub const PCI_EXP_LNKSTA_CLS: u16 = 0xF;
pub const PCI_EXP_LNKSTA_NLW: u16 = 0x3F << 4;
pub const PCI_EXP_LNKSTA_DLLLA: u16 = 1 << 13;
/// PCI_EXP_RTCAP and PCI_EXP_RTCTL: a root port that tells a function
/// asking to be asked again (configuration request retry) from one that
/// is not there, and the switch for it.
pub const PCI_EXP_RTCAP_CRSVIS: u16 = 1 << 0;
pub const PCI_EXP_RTCTL_CRSSVE: u16 = 1 << 4;

/// The Advanced Features capability (PCI_CAP_ID_AF), for a PCI function
/// that resets itself: its capabilities, and its control word.
pub const PCI_AF_CAP: u32 = 3;
pub const PCI_AF_CTRL: u32 = 4;
pub const PCI_AF_STATUS: u32 = 5;
pub const PCI_AF_CAP_TP: u8 = 1 << 0;
pub const PCI_AF_CAP_FLR: u8 = 1 << 1;
pub const PCI_AF_CTRL_FLR: u8 = 1 << 0;
pub const PCI_AF_STATUS_TP: u8 = 1 << 0;

/// A PCI Express capability's port types (PCI_EXP_FLAGS_TYPE): a root
/// port and a switch's downstream port each have one device below them.
pub const PCI_EXP_TYPE_ENDPOINT: u8 = 0;
pub const PCI_EXP_TYPE_LEG_END: u8 = 1;
pub const PCI_EXP_TYPE_ROOT_PORT: u8 = 4;
pub const PCI_EXP_TYPE_UPSTREAM: u8 = 5;
pub const PCI_EXP_TYPE_DOWNSTREAM: u8 = 6;
pub const PCI_EXP_TYPE_PCI_BRIDGE: u8 = 7;
pub const PCI_EXP_TYPE_PCIE_BRIDGE: u8 = 8;
pub const PCI_EXP_TYPE_RC_END: u8 = 9;
pub const PCI_EXP_TYPE_RC_EC: u8 = 10;
/// PCIDevice.express_type of a function without the capability.
pub const PCI_EXP_TYPE_NONE: u8 = 0xFF;

// --- class codes ------------------------------------------------------------------

/// Class codes (class, subclass, programming interface).
pub const PCI_CLASS_STORAGE_SATA_AHCI: u32 = 0x01_06_01;
pub const PCI_CLASS_STORAGE_NVME: u32 = 0x01_08_02;
pub const PCI_CLASS_BRIDGE_HOST: u32 = 0x06_00_00;
pub const PCI_CLASS_BRIDGE_PCI: u32 = 0x06_04_00;
pub const PCI_CLASS_SERIAL_USB_UHCI: u32 = 0x0C_03_00;
pub const PCI_CLASS_SERIAL_USB_OHCI: u32 = 0x0C_03_10;
pub const PCI_CLASS_SERIAL_USB_EHCI: u32 = 0x0C_03_20;
pub const PCI_CLASS_SERIAL_USB_XHCI: u32 = 0x0C_03_30;
/// The mask that compares a whole class code, and the one that compares
/// the class and subclass alone.
pub const PCI_CLASS_MASK: u32 = 0xFF_FF_FF;
pub const PCI_CLASS_SUB_MASK: u32 = 0xFF_FF_00;
