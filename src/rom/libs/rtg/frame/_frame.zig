// SPDX-License-Identifier: MPL-2.0
//! A board's frames: counted as its driver says they end, and waited for.
//!
//! A driver with a frame interrupt calls FrameDone in it. The library
//! counts the frame (`RtgBoardStats.blanks`) and wakes the tasks that
//! wait for one (WaitVBlank): each has a waiter on its own stack, on a
//! list of the board's, with the count of frames it still waits for. The
//! list and the count are under a spinlock of the board's that the
//! interrupt takes too.
//!
//! Whether a board says its frames at all is not asked of the driver: it
//! is seen. The first FrameDone says it does, and a wait whose frames
//! did not come within its limit says it has stopped - from then on a
//! wait is by the clock, until a frame is said again. So a board that
//! has no frame interrupt, one whose stream has not begun, and one whose
//! display went dark are all waited for by the clock, and none of them
//! holds a task for longer than a wait's limit.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

/// Where the frames' lock stands in the lock order: after a driver's own
/// locks, which its frame interrupt may hold when it says a frame.
pub const lock_order = exec.LOCKORDER_DRIVER + 1000;

/// A task waiting for frames, on its own stack.
pub const Waiter = struct {
    next: ?*Waiter = null,
    /// The task, and the signal it waits on.
    task: *exec.Task,
    mask: u32,
    /// The frames it still waits for: counted down by FrameDone, which
    /// signals the task at 0.
    left: u32,
};

/// A board's frames (`Private.frames`).
pub const State = struct {
    /// Holds the waiters' list, `blanks` and `come` still. Taken by the
    /// frame interrupt.
    lock: exec.Lock = .{},
    /// The frames said so far.
    blanks: u32 = 0,
    /// Whether the driver says its frames: set by each frame, cleared by
    /// a wait they did not come for.
    come: bool = false,
    waiters: ?*Waiter = null,
};

/// Makes a board's frame state ready.
///
/// INPUTS:
/// - `sys` - exec.
/// - `state` - the state, cleared.
pub fn init(sys: *ExecBase, state: *State) void {
    sys.InitLock(&state.lock, "rtg frames", lock_order, exec.LOCKF_INTERRUPT);
}

/// A frame ended: counted, and every waiter whose count it reaches
/// signalled.
///
/// INPUTS:
/// - `sys` - exec.
/// - `state` - the board's frames.
pub fn done(sys: *ExecBase, state: *State) void {
    sys.AcquireLock(&state.lock);
    state.blanks +%= 1;
    state.come = true;
    var at = state.waiters;
    while (at) |waiter| : (at = waiter.next) {
        if (waiter.left == 0) continue;
        waiter.left -= 1;
        if (waiter.left == 0) sys.Signal(waiter.task, waiter.mask);
    }
    sys.ReleaseLock(&state.lock);
}

/// Whether the board's driver says its frames just now.
///
/// INPUTS:
/// - `sys` - exec.
/// - `state` - the board's frames.
pub fn come(sys: *ExecBase, state: *State) bool {
    sys.AcquireLock(&state.lock);
    defer sys.ReleaseLock(&state.lock);
    return state.come;
}

/// The frames said so far.
///
/// INPUTS:
/// - `sys` - exec.
/// - `state` - the board's frames.
pub fn count(sys: *ExecBase, state: *State) u32 {
    sys.AcquireLock(&state.lock);
    defer sys.ReleaseLock(&state.lock);
    return state.blanks;
}

/// Whether a task waits for a frame of the board.
///
/// INPUTS:
/// - `sys` - exec.
/// - `state` - the board's frames.
pub fn waiting(sys: *ExecBase, state: *State) bool {
    sys.AcquireLock(&state.lock);
    defer sys.ReleaseLock(&state.lock);
    return state.waiters != null;
}

/// Puts a waiter on the board's list: the frames from now on count it
/// down.
///
/// INPUTS:
/// - `sys` - exec.
/// - `state` - the board's frames.
/// - `waiter` - the waiter, its task, signal and count set.
pub fn add(sys: *ExecBase, state: *State, waiter: *Waiter) void {
    sys.AcquireLock(&state.lock);
    waiter.next = state.waiters;
    state.waiters = waiter;
    sys.ReleaseLock(&state.lock);
}

/// Takes a waiter off the board's list again.
///
/// INPUTS:
/// - `sys` - exec.
/// - `state` - the board's frames.
/// - `waiter` - the waiter `add` put there.
///
/// RESULT:
/// The frames it still waited for: 0 when they all came. Where some did
/// not, the board is held to say no frames until the next is said.
pub fn remove(sys: *ExecBase, state: *State, waiter: *Waiter) u32 {
    sys.AcquireLock(&state.lock);
    defer sys.ReleaseLock(&state.lock);
    var link = &state.waiters;
    while (link.*) |at| : (link = &at.next) {
        if (at != waiter) continue;
        link.* = at.next;
        break;
    }
    if (waiter.left != 0) state.come = false;
    return waiter.left;
}
