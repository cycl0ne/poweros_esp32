// SPDX-License-Identifier: MIT
//! The H.265 decoder (ITU-T H.265 / ISO 23008-2) as the codec module
//! uses it, without anything of the system: videoparse.library's events
//! in, pictures out.

const common = @import("common.zig");
pub const Decoder = @import("decoder.zig").Decoder;
pub const Error = @import("bits.zig").Error;
pub const Env = common.Env;
pub const Cores = common.Cores;
pub const Store = common.Store;
pub const Format = common.Format;
pub const params = @import("params.zig");
/// The slots the decoder asks the library for beyond the stream's own
/// (VPA_Slots).
pub const own_slots = @import("dpb.zig").own_slots;

test {
    _ = @import("bits.zig");
    _ = @import("cabac.zig");
    _ = @import("tables.zig");
    _ = @import("transform.zig");
    _ = @import("intra.zig");
    _ = @import("inter.zig");
    _ = @import("picture.zig");
    _ = @import("mvpred.zig");
    _ = @import("ctu.zig");
    _ = @import("filter.zig");
    _ = @import("dpb.zig");
    _ = @import("decoder.zig");
}
