// SPDX-License-Identifier: MIT
//! StartAnvil: the desktop started on a process of its own.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const anvil = sdk.anvil;
const utility = sdk.utility;
const _base = @import("../anvil_base.zig");
const AnvilBase = _base.AnvilBase;
const _desktop = @import("../desktop/_desktop.zig");
const Desktop = _desktop.Desktop;

/// The desktop's process: its name, its stack, and its priority - one
/// above the programs it starts, as the original's, so the desktop
/// answers a press while they work.
const process_name = "Anvil";
const stack_bytes = 24576;
const priority = 1;

/// Starts the desktop.
///
/// SYNOPSIS:
/// ```zig
/// fn StartAnvil(base: *AnvilBase, tags: ?[*]const utility.TagItem) bool
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `tags`:
///   - ANVA_CleanUp (bool): the disks' icons placed anew down the
///     desktop's edge, their saved places left aside.
///
/// RESULT:
/// True when the desktop runs - started now, or running already. False
/// with IoErr: ERROR_NO_FREE_STORE, ERROR_INVALID_RESIDENT_LIBRARY (a
/// library it draws with could not be opened), ERROR_OBJECT_NOT_FOUND (no
/// Workbench screen).
///
/// BEHAVIOR:
/// A process named "Anvil" is started with a CLI of its own - the
/// caller's command path, so the programs it starts are found as the
/// caller would find them - and `SYS:` as its current directory. It
/// locks the Workbench screen, lays a backdrop window across it under the
/// screen's bar with the ground `ENV:Sys/anvil.prefs` gives, puts an icon
/// on it for each mounted volume, and says in the screen's title how much
/// memory is free. The call returns once the desktop is up, or has failed
/// to come up.
///
/// While the desktop runs, a second call brings its screen to the front
/// and does nothing else.
///
/// CONTEXT:
/// - Waits: yes, for the desktop to come up.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process; IoErr is set on failure.
///
/// OWNERSHIP:
/// The desktop holds the library open while it runs; the caller may
/// close its own opening at once.
///
/// NOTES:
/// The desktop ends when Quit is picked from its menu, or on CTRL-C.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `C:LoadAnvil`
///
/// EXAMPLES:
/// ```zig
/// const ab: *sdk.interface.anvil.AnvilBase = @ptrCast(sys.OpenLibrary(anvil.ANVILNAME, 1) orelse return);
/// defer sys.CloseLibrary(ab.lib());
/// if (!ab.StartAnvil(null)) return;
/// ```
pub fn StartAnvil(base: *AnvilBase, tags: ?[*]const utility.TagItem) bool {
    const sys = base.sys_base;
    const dl = base.dos_base;
    sys.ObtainSemaphore(&base.start_lock);
    defer sys.ReleaseSemaphore(&base.start_lock);
    if (base.desktop) |running| {
        const desktop: *Desktop = @ptrCast(@alignCast(running));
        desktop.toFront();
        return true;
    }

    const memory = sys.AllocVec(@sizeOf(Desktop), exec.MEMF_CLEAR) orelse return failed(dl, dos.ERROR_NO_FREE_STORE);
    const desktop: *Desktop = @ptrCast(@alignCast(memory));
    const ub_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 0) orelse {
        sys.FreeVec(memory);
        return failed(dl, dos.ERROR_INVALID_RESIDENT_LIBRARY);
    };
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(ub_lib);
    const clean_up = ub.GetTagData(anvil.ANVA_CleanUp, 0, tags) != 0;
    sys.CloseLibrary(ub_lib);

    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        sys.FreeVec(memory);
        return failed(dl, dos.ERROR_NO_FREE_STORE);
    }
    defer sys.FreeSignal(signal);
    desktop.* = .{
        .base = base,
        .sys = sys,
        .dl = dl,
        .clean_up = clean_up,
        .starter = sys.FindTask(null),
        .start_signal = @intCast(signal),
    };

    // SYS: as its current directory; the caller's if SYS: cannot be had.
    const home = dl.Lock("SYS:", dos.SHARED_LOCK);
    // The open count the process holds, taken here and handed to dos.
    _base.holdLibrary(base, 1);
    const process_tags = [_]utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&_desktop.desktopMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
        .{ .tag = dos.NP_StackSize, .data = stack_bytes },
        .{ .tag = dos.NP_Priority, .data = priority },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(desktop) },
        .{ .tag = dos.NP_HoldLibrary, .data = @intFromPtr(&base.lib) },
        .{ .tag = dos.NP_Cli, .data = 1 },
        .{ .tag = dos.NP_CommandName, .data = @intFromPtr(process_name) },
        .{ .tag = if (home != null) dos.NP_CurrentDir else utility.TAG_IGNORE, .data = @intFromPtr(home) },
        // No home directory: none to duplicate, so nothing to fail after
        // the current one was handed over.
        .{ .tag = dos.NP_HomeDir, .data = 0 },
        .{},
    };
    if (dl.CreateNewProc(&process_tags) == null) {
        _base.holdLibrary(base, -1);
        if (home) |lock| dl.UnLock(lock);
        sys.FreeVec(memory);
        return failed(dl, dos.ERROR_NO_FREE_STORE);
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (desktop.start_error != 0) {
        // The process has given back all it took and is ending: its
        // state is the caller's to free.
        const code = desktop.start_error;
        sys.FreeVec(memory);
        return failed(dl, code);
    }
    base.desktop = desktop;
    return true;
}

fn failed(dl: *sdk.interface.dos.DosBase, code: i32) bool {
    _ = dl.SetIoErr(code);
    return false;
}
