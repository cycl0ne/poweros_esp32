// SPDX-License-Identifier: MIT
//! One part soldered on the board, as expansion.library hands it out: made
//! at the library's init from one SYSTAG_Part of the system tag list, and
//! kept for as long as the machine runs. A caller reads it and never
//! changes it.

const nodes = @import("../exec/nodes.zig");
const tagitem = @import("../utility/tagitem.zig");

pub const BoardPart = extern struct {
    /// ln_Name is the chip's name ("gt911"), or the kind's for a part that
    /// is no chip of its own ("sdslot").
    node: nodes.Node = .{},
    /// PARTKIND_* and CHIP_* (systemtags.zig).
    kind: u32 = 0,
    chip: u32 = 0,
    /// Which one of its kind: the first I2C bus is unit 0, the second 1.
    unit: u32 = 0,
    /// The part's own tag list, as the board wrote it: every fact about
    /// it is read from here, with utility.library's GetTagData.
    tags: ?[*]const tagitem.TagItem = null,
};
