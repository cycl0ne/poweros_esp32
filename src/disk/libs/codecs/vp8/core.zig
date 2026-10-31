// SPDX-License-Identifier: MIT
//! The VP8 decoder (RFC 6386) as the codec module uses it, without
//! anything of the system: frames in, the frames to show out.

const common = @import("common.zig");
pub const Decoder = @import("decoder.zig").Decoder;
pub const Error = common.Error;
pub const Env = common.Env;
pub const Frame = common.Frame;

test {
    _ = @import("bool.zig");
    _ = @import("decoder.zig");
}
