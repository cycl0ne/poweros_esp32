// SPDX-License-Identifier: MIT
//! anvil.library's base, shared by every opener: exec's Library header,
//! what it was loaded from, dos.library, the desktop while it runs, and
//! the windows, icons and menu items programs have added to it.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;

pub const AnvilBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    dos_base: *DosBase,
    /// Whether the desktop runs, and starting it: one at a time.
    start_lock: exec.SignalSemaphore = .{},
    /// The desktop's process's state while it runs (`desktop.Desktop`),
    /// under `start_lock`; null when it does not.
    desktop: ?*anyopaque = null,
    /// What programs added (`app/_app.zig`'s `App`s), and the desktop's
    /// process and the signal it is told of a change with; all under
    /// `app_lock`, the task null while no desktop runs.
    app_lock: exec.SignalSemaphore = .{},
    apps: exec.List = .{},
    app_task: ?*exec.Task = null,
    app_signals: u32 = 0,
};

pub fn anvilBase(lib: *exec.Library) *AnvilBase {
    return @fieldParentPtr("lib", lib);
}

/// The library as its own callers see it: its calls through its jump
/// table.
pub fn interface(base: *AnvilBase) *sdk.interface.anvil.AnvilBase {
    return @ptrCast(base);
}

/// The library's open count changed by `by`, under the library's own
/// lock, which OpenLibrary and CloseLibrary change it under: the count
/// the desktop's process holds while its code runs.
pub fn holdLibrary(base: *AnvilBase, by: i32) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lib.lock);
    defer sys.ReleaseSemaphore(&base.lib.lock);
    if (by > 0) base.lib.open_cnt += 1 else base.lib.open_cnt -= 1;
}
