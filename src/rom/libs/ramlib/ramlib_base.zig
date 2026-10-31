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
    /// What has been loaded: a `Loaded` per module, by its tail name. Its
    /// segments are unloaded when exec says the module went
    /// (UnLoadModule); a library's too when it is asked for again after it
    /// went with nobody to say so - `RemLibrary` hands them to its caller.
    loaded: exec.List = .{},
    /// What is being loaded now: a `Loading` per module (loader.zig), each
    /// with a lock its loader holds until it is done, which a second task
    /// asking for the same name waits on.
    loading: exec.List = .{},
    /// Over the two lists, held only while one is looked at or changed -
    /// never across a load, so that one module's load does not hold up
    /// another's.
    lock: exec.SignalSemaphore = .{},
    /// Over `loaded` too, a spinlock held for a walk or a link alone:
    /// UnLoadModule takes a note off it from inside AllocMem's low-memory
    /// handler, which waits for no semaphore. Taken after `lock` when both
    /// are, and nothing is allocated or unloaded while it is held.
    notes_lock: exec.Lock = .{},
};

/// LibExpunge: a ROM module stays, and what it has loaded stays with it.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
