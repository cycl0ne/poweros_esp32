// SPDX-License-Identifier: MPL-2.0
//! keymap.library as a library: its base, and the Expunge vector that
//! keeps it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const km = sdk.keymap;
const ExecBase = sdk.interface.exec.ExecBase;

/// The base: the list of keymaps, and which is the default. The ROM's two
/// nodes are in it, since a node is changed by being on a list and a ROM
/// image is read only.
pub const KeymapBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// KeyMapNodes, found by name.
    maps: exec.List,
    /// What every call given no keymap uses.
    default: *km.KeyMap,
    /// "deutsch" and "usa".
    rom: [2]km.KeyMapNode,
};

/// LibExpunge: a module in the ROM stays, and a default keymap may be in
/// use by anything.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
