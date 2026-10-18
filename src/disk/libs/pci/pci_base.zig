// SPDX-License-Identifier: MIT
//! pci.library's base: exec's Library header and the functions it found.
//! There is one base, shared by every opener; the host bridges and the
//! functions are made once, as the library starts, and stay.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const ExecBase = sdk.interface.exec.ExecBase;

pub const PCIBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made. The library stays once loaded, so it is never
    /// handed back.
    seg_list: ?*anyopaque = null,
    /// The first function, in the order the walk found them.
    first: ?*pci.PCIDevice = null,
    /// Claims are taken and given back under it.
    claim_lock: exec.SignalSemaphore = .{},
};

pub fn pciBase(lib: *exec.Library) *PCIBase {
    return @fieldParentPtr("lib", lib);
}
