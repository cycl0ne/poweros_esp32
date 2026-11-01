// SPDX-License-Identifier: MIT
//! The H.264 decoder (ITU-T H.264 / ISO 14496-10) as the codec module
//! uses it, without anything of the system: NAL units in, pictures out.

const common = @import("common.zig");
pub const Decoder = @import("decoder.zig").Decoder;
pub const Error = @import("bits.zig").Error;
pub const Env = common.Env;
pub const Cores = common.Cores;
pub const Store = common.Store;
pub const nal = @import("nal.zig");
pub const params = @import("params.zig");

test {
    _ = @import("bits.zig");
    _ = @import("nal.zig");
    _ = @import("params.zig");
    _ = @import("cavlc.zig");
    _ = @import("cabac.zig");
    _ = @import("transform.zig");
    _ = @import("intra.zig");
    _ = @import("inter.zig");
    _ = @import("mb.zig");
    _ = @import("mvpred.zig");
    _ = @import("recon.zig");
    _ = @import("deblock.zig");
    _ = @import("decoder.zig");
}
