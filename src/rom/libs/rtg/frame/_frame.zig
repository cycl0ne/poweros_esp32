// SPDX-License-Identifier: MPL-2.0
//! A board's frames: counted as its driver says they end, and waited for.
//!
//! A driver with a frame interrupt calls FrameDone in it. The library
//! counts the frame (`RtgBoardStats.blanks`) and wakes the tasks that
//! wait for one (WaitVBlank): each has a waiter on its own stack, on a
//! list of the board's, with the count of frames it still waits for.
//!
//! The list is what an interrupt reads, so it is changed inside Disable,
//! which holds every core's interrupts off: a spinlock would have to
//! stand after every lock a task may hold when the frame interrupt
//! finds it, exec's own among them. The count and the flag are single
//! words, written inside Disable and read as they are.
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
    /// The frames said so far.
    blanks: u32 = 0,
    /// Whether the driver says its frames: set by each frame, cleared by
    /// a wait they did not come for.
    come: bool = false,
    /// The tasks that wait for a frame. Changed and walked inside
    /// Disable.
    waiters: ?*Waiter = null,
};

/// A frame ended: counted, and every waiter whose count it reaches
/// signalled.
///
/// INPUTS:
/// - `sys` - exec.
/// - `state` - the board's frames.
pub fn done(sys: *ExecBase, state: *State) void {
    sys.Disable();
    @atomicStore(u32, &state.blanks, state.blanks +% 1, .release);
    @atomicStore(bool, &state.come, true, .release);
    var at = state.waiters;
    while (at) |waiter| : (at = waiter.next) {
        if (waiter.left == 0) continue;
        waiter.left -= 1;
        if (waiter.left == 0) sys.Signal(waiter.task, waiter.mask);
    }
    sys.Enable();
}

/// Whether the board's driver says its frames just now.
///
/// INPUTS:
/// - `state` - the board's frames.
pub fn come(state: *const State) bool {
    return @atomicLoad(bool, &state.come, .acquire);
}

/// The frames said so far.
///
/// INPUTS:
/// - `state` - the board's frames.
pub fn count(state: *const State) u32 {
    return @atomicLoad(u32, &state.blanks, .acquire);
}

/// Whether a task waits for a frame of the board.
///
/// INPUTS:
/// - `sys` - exec.
/// - `state` - the board's frames.
pub fn waiting(sys: *ExecBase, state: *State) bool {
    sys.Disable();
    defer sys.Enable();
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
    sys.Disable();
    waiter.next = state.waiters;
    state.waiters = waiter;
    sys.Enable();
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
    sys.Disable();
    defer sys.Enable();
    var link = &state.waiters;
    while (link.*) |at| : (link = &at.next) {
        if (at != waiter) continue;
        link.* = at.next;
        break;
    }
    if (waiter.left != 0) @atomicStore(bool, &state.come, false, .release);
    return waiter.left;
}
