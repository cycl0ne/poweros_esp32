// SPDX-License-Identifier: MPL-2.0
//! FlushMemory: frees all the memory that can be freed, by asking every
//! low-memory handler for all it can give - with no allocation waiting
//! for it.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Interrupt = sdk.exec.Interrupt;
const FlushHook = sdk.exec.FlushHook;

/// Frees all the memory that can be freed.
///
/// SYNOPSIS:
/// ```zig
/// fn FlushMemory(base: *ExecBase, hook: ?*FlushHook) usize
/// ```
///
/// SINCE: 1.43. LVO -608.
///
/// INPUTS:
/// - `hook` - told of each library and device nobody has open: with
///   `FLUSH_EXPUNGING` and its name before its Expunge runs, then with
///   `FLUSH_GONE` or `FLUSH_KEPT` and no name - the name may have gone
///   with the module. Null for nothing told.
///
/// RESULT:
/// How many more bytes are free than before (`AvailMem(MEMF_ANY)` after
/// less before; 0 when other tasks took more meanwhile).
///
/// BEHAVIOR:
/// Every low-memory handler is asked, highest priority first, with
/// `MEMHF_FLUSH` set: no allocation is waiting, so a handler frees all it
/// can rather than one thing at a time. One that answers `MEM_TRY_AGAIN`
/// is asked again with `MEMHF_RECYCLE` until it answers otherwise. exec's
/// own handler tries each library and device nobody has open, pinned or
/// is expunging once - one that refuses stays, one whose lock is held by
/// someone is passed over - and diskfont.library's lets go of the fonts
/// nobody uses.
///
/// CONTEXT:
/// - Waits: for the memory handlers' semaphore while another task runs
///   them, and for whatever an Expunge waits for - a device's task to
///   end.
/// - Interrupts: no.
/// - Locks: takes the memory handlers' semaphore; the hook runs holding
///   it and the module's own lock. No spinlock may be held.
/// - Process: a Task will do; the hook runs on it.
///
/// OWNERSHIP:
/// Nothing is allocated. The hook is the caller's and is only called
/// during the call.
///
/// NOTES:
/// The hook is told before a module's Expunge runs, so a module whose
/// Expunge never comes back is the last one it was told of. It may print:
/// it holds no lock its output needs, unless what it prints through is
/// the module being expunged. It must not wait for a task that needs
/// memory there is none of: the handlers' semaphore is held.
///
/// BUGS:
/// exec's handler remembers up to 16 modules that refused or were busy
/// in one call; past that, the rest are left where they are.
///
/// SEE ALSO:
/// `AddMemHandler`, `AvailMem`, `AllocMem`, `RemLibrary`
///
/// EXAMPLES:
/// ```zig
/// const freed = sys.FlushMemory(null);
/// ```
pub fn FlushMemory(base: *ExecBase, hook: ?*FlushHook) usize {
    const sys = base.iface();
    const before = sys.AvailMem(sdk.exec.MEMF_ANY);
    {
        sys.ObtainSemaphore(&base.sem_memhandlers);
        defer sys.ReleaseSemaphore(&base.sem_memhandlers);
        var data: sdk.exec.MemHandlerData = .{
            .request_size = ~@as(usize, 0),
            .request_flags = sdk.exec.MEMF_ANY,
            .flags = sdk.exec.MEMHF_FLUSH,
            .hook = hook,
        };
        var node = base.mem_handlers.first();
        while (node) |current| {
            const handler: *Interrupt = @fieldParentPtr("node", current);
            const code: sdk.exec.MemHandlerFn = @ptrCast(@alignCast(handler.code.?));
            if (code(&data, handler.data) == sdk.exec.MEM_TRY_AGAIN) {
                data.flags = sdk.exec.MEMHF_FLUSH | sdk.exec.MEMHF_RECYCLE;
                continue;
            }
            data.flags = sdk.exec.MEMHF_FLUSH;
            node = if (current.succ.?.succ != null) current.succ else null;
        }
    }
    return sys.AvailMem(sdk.exec.MEMF_ANY) -| before;
}
