// SPDX-License-Identifier: MIT
//! H.264's parameter sets read - the units, the bit reader, the sets - as
//! a module of their own, which videoparse.library reads a stream with
//! and chip.vcodec the colours of a stream its chip says nothing about:
//! a file belongs to one module, and both build these in.

pub const nal = @import("nal.zig");
pub const params = @import("params.zig");
pub const bits = @import("bits.zig");

test {
    _ = nal;
    _ = params;
    _ = bits;
}
