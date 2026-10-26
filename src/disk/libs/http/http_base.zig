// SPDX-License-Identifier: MIT
//! http.library's base: exec's Library header, utility.library for the
//! tags, and tls.library and compression.library once a request first
//! needs them. There is one base, shared by every opener: a client and
//! its requests are the caller's.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TLSBase = sdk.interface.tls.TLSBase;
const CompressionBase = sdk.interface.compression.CompressionBase;

pub const HttpBase = extern struct {
    lib: exec.Library,
    /// For the clients, requests and connections, allocated on the
    /// caller's task.
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    utility_base: *UtilityBase,
    /// Held while tls.library or compression.library is opened.
    lock: exec.SignalSemaphore = .{},
    tls_base: ?*TLSBase = null,
    compression_base: ?*CompressionBase = null,
};

pub fn httpBase(lib: *exec.Library) *HttpBase {
    return @fieldParentPtr("lib", lib);
}

/// The library's own jump table, for a call that uses another of its
/// calls: those go through the table like anyone's.
pub fn iface(base: *HttpBase) *sdk.interface.http.HttpBase {
    return @ptrCast(base);
}

/// tls.library, opened by the first request over TLS and kept until the
/// expunge; null when it is not there.
pub fn tlsOf(base: *HttpBase) ?*TLSBase {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    if (base.tls_base == null) {
        if (sys.OpenLibrary(sdk.tls.TLSNAME, 1)) |lib| base.tls_base = @ptrCast(lib);
    }
    return base.tls_base;
}

/// compression.library, opened by the first request that unpacks its
/// answer and kept until the expunge; null when it is not there.
pub fn compressionOf(base: *HttpBase) ?*CompressionBase {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    if (base.compression_base == null) {
        if (sys.OpenLibrary(sdk.compression.COMPRESSIONNAME, 1)) |lib| base.compression_base = @ptrCast(lib);
    }
    return base.compression_base;
}
