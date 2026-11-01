// SPDX-License-Identifier: MIT
//! The AV1 decoder as the codec module uses it, without anything of the
//! system: temporal units in, the frames to show out.

const common = @import("common.zig");
const decoder = @import("decoder.zig");
pub const Decoder = decoder.Decoder;
pub const Shown = decoder.Shown;
pub const Error = common.Error;
pub const Env = common.Env;
pub const Frame = common.Frame;
pub const Cores = common.Cores;

test {
    _ = @import("decoder.zig");
}
