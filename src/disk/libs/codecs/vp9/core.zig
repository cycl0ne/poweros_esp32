// SPDX-License-Identifier: MIT
//! The VP9 decoder as the codec module uses it, without anything of the
//! system: packets in, the frames to show out.

const common = @import("common.zig");
const decoder = @import("decoder.zig");
pub const Decoder = decoder.Decoder;
pub const Shown = decoder.Shown;
pub const Error = common.Error;
pub const Env = common.Env;
pub const Frame = common.Frame;

test {
    _ = @import("bool.zig");
    _ = @import("idct.zig");
    _ = @import("decoder.zig");
}
