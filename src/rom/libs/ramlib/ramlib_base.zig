// SPDX-License-Identifier: MPL-2.0
//! ramlib.library as a library: its base, which is its whole state, and
//! the Expunge vector that keeps it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;

/// The base, which is this module's whole state.
pub const RamLibBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// dos.library, opened by the init and kept: everything here is a
    /// file.
    dos_base: *DosBase,
    /// The process that does the loading, and the port it waits on. The
    /// port is null until the process has made it.
    process: ?*anyopaque = null,
    port: ?*exec.MsgPort = null,
    /// The vectors that were replaced, called first on every open.
    old_open_library: ?*const anyopaque = null,
    old_open_device: ?*const anyopaque = null,
    /// What has been loaded: a `Loaded` per module, so a flush later has
    /// something to walk. Nothing is unloaded yet.
    loaded: exec.List = .{},
    /// One load at a time: two tasks asking for the same name at once
    /// would otherwise both load it.
    lock: exec.SignalSemaphore = .{},
};

/// LibExpunge: a ROM module stays, and what it has loaded stays with it.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
