// SPDX-License-Identifier: MIT
//! tls.library's base: exec's Library header, the libraries it uses, and
//! what every session shares - the trust stores and the time zone, read
//! once by the first session and kept until the expunge.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const TLSBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    /// Held while the libraries are opened and the stores read.
    lock: exec.SignalSemaphore = .{},
    crypto_base: ?*CryptoBase = null,
    dos_base: ?*DosBase = null,
    utility_base: ?*UtilityBase = null,
    /// Whether the stores and the zone have been read.
    loaded: bool = false,
    /// `SYS:Certificates/Roots`, as read.
    roots: ?[*]u8 = null,
    roots_length: u32 = 0,
    /// The program's own roots, turned into a store.
    own: ?[*]u8 = null,
    own_length: u32 = 0,
    /// The clock's time zone rule, as `ENVARC:Sys/timezone` gives it.
    zone: [96]u8 = @splat(0),
    zone_length: u32 = 0,
};

pub fn tlsBase(lib: *exec.Library) *TLSBase {
    return @fieldParentPtr("lib", lib);
}
