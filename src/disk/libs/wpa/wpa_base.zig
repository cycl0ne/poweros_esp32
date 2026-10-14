// SPDX-License-Identifier: MIT
//! wpa.library's base: exec's Library header, and the libraries it uses -
//! crypto.library for every key, utility.library for the tags and the
//! hook - opened by the first call that needs them and kept until the
//! expunge.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const WPABase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    /// Held while the libraries are opened.
    lock: exec.SignalSemaphore = .{},
    crypto_base: ?*CryptoBase = null,
    utility_base: ?*UtilityBase = null,
};

pub fn wpaBase(lib: *exec.Library) *WPABase {
    return @fieldParentPtr("lib", lib);
}

/// crypto.library and utility.library, opened if they are not yet: false
/// when either can't be.
///
/// base: the library's base.
///
/// CONTEXT: Waits: on the base's lock, and for OpenLibrary - which loads
/// crypto.library from LIBS: the first time, and needs a process for
/// that.
pub fn opened(base: *WPABase) bool {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    if (base.utility_base == null) {
        base.utility_base = @ptrCast(sys.OpenLibrary(sdk.interface.utility.NAME, 0) orelse return false);
    }
    if (base.crypto_base == null) {
        base.crypto_base = @ptrCast(sys.OpenLibrary(sdk.crypto.CRYPTONAME, 1) orelse return false);
    }
    return true;
}
