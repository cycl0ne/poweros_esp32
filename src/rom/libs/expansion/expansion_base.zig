// SPDX-License-Identifier: MPL-2.0
//! expansion.library as a library: its base, and the Expunge vector that
//! keeps it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const BoardPart = sdk.expansion.BoardPart;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// The base: the system tag list it was started with, and one BoardPart
/// per part on it, in the board's order.
pub const ExpansionBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    utility_base: *UtilityBase,
    /// The system tag list's root. Never null: a board without one gets
    /// `empty_list`.
    system: [*]const utility.TagItem,
    /// The parts, in one allocation of `part_count`.
    parts: ?[*]BoardPart = null,
    part_count: u32 = 0,
};

/// What SystemTags answers on a machine whose ROM carries no system tag
/// list: a list with nothing in it, so a caller never has to test for
/// null.
pub const empty_list = [_]utility.TagItem{.{ .tag = utility.TAG_DONE, .data = 0 }};

/// LibExpunge: a module in the ROM stays, and what it hands out is kept
/// by everything that asked.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
