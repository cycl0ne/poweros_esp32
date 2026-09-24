// SPDX-License-Identifier: MPL-2.0
//! ramlib.library's jump table. It has no calls of its own: what it does
//! it does by standing in front of exec's OpenLibrary and OpenDevice.

const sdk = @import("sdk");
const exec = sdk.exec;
const vec = exec.vec;
const ramlib_base = @import("ramlib_base.zig");

/// ramlib.library's jump table: the standard Open, Close and ExtFunc, and
/// its own Expunge, which refuses - it has patched OpenLibrary and
/// OpenDevice, and freeing it would leave those slots pointing at freed
/// code.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(ramlib_base.expunge),
    vec(exec.libExtFunc),
};
