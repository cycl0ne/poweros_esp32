// SPDX-License-Identifier: MPL-2.0
//! AddMemHandler: puts a low-memory handler on exec's handler list, by
//! priority. `AllocMem` asks the handlers in that order when no region has
//! room.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Interrupt = sdk.exec.Interrupt;

/// Adds a handler that is asked to free memory when an allocation fails.
///
/// SYNOPSIS:
/// ```zig
/// fn AddMemHandler(base: *ExecBase, handler: *Interrupt) void
/// ```
///
/// SINCE: 1.0. LVO -120.
///
/// INPUTS:
/// - `handler` - an `Interrupt` whose `code` is a `MemHandlerFn` and whose
///   `pri` decides when it is asked. It is called with a `MemHandlerData`
///   saying how much was wanted and with what requirements, and answers
///   `MEM_DID_NOTHING`, `MEM_TRY_AGAIN` or `MEM_ALL_DONE`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Handlers are enqueued by priority and asked highest first, and the
/// allocation is retried after each one that did something.
/// `MEM_TRY_AGAIN` asks the same handler again with `MEMHF_RECYCLE` set, so
/// one that frees a little at a time can be driven until the allocation
/// succeeds - which is how exec's own expunges one library per call rather
/// than emptying the machine on the first failed allocation.
///
/// CONTEXT:
/// - Waits: for the memory handlers' semaphore while another task runs
///   them. **The handler itself must not wait**: it runs inside an
///   `AllocMem`, whose caller may hold anything - a library's lock in its
///   Open vector, say. It tries what it needs and passes over what is
///   busy.
/// - Interrupts: no. It takes a semaphore.
/// - Locks: takes the memory handlers' semaphore; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The `Interrupt` stays the caller's and must
/// outlive its place on the list.
///
/// NOTES:
/// A handler is reached from inside an allocation, so anything it calls
/// must be safe to call there - which rules out allocating, and rules out
/// anything that reaches a handler process.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemMemHandler`, `AllocMem`
///
/// EXAMPLES:
/// ```zig
/// var handler: exec.Interrupt = .{
///     .node = .{ .pri = 0, .name = "my flusher" },
///     .code = @ptrCast(&myFlusher),
/// };
/// sys.AddMemHandler(&handler);
/// ```
pub fn AddMemHandler(base: *ExecBase, handler: *Interrupt) void {
    const sys = base.iface();
    sys.ObtainSemaphore(&base.sem_memhandlers);
    defer sys.ReleaseSemaphore(&base.sem_memhandlers);
    sys.Enqueue(&base.mem_handlers, &handler.node);
}
