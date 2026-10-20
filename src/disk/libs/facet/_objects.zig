// SPDX-License-Identifier: MIT
//! What the library's objects are made in, and how a handle becomes the
//! object behind it and back.
//!
//! Every object is a block of the calling task's (AllocVec, cleared): it
//! is the program's, as what it makes with any other library is, and its
//! memory tools show it as the program's. None is private - a queue's
//! task reads them as well. A handle is the object's address, typed as
//! the SDK's opaque handle.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

/// A cleared `T` of the caller's, or null.
pub fn create(sys: *ExecBase, comptime T: type) ?*T {
    // AllocVec's blocks are aligned to its chunks.
    comptime if (@alignOf(T) > exec.MEM_BLOCKSIZE) @compileError("an object is aligned no more than exec's chunks");
    const memory = sys.AllocVec(@sizeOf(T), exec.MEMF_CLEAR) orelse return null;
    return @ptrCast(@alignCast(memory));
}

/// An object `create` made, given back.
pub fn destroy(sys: *ExecBase, object: anytype) void {
    sys.FreeVec(object);
}

/// The object behind a handle.
pub fn of(comptime T: type, object_handle: anytype) *T {
    return @ptrCast(@alignCast(object_handle));
}

/// An object's handle.
pub fn handle(comptime H: type, object: anytype) *H {
    return @ptrCast(object);
}
