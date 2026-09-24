// SPDX-License-Identifier: MIT
//! Variables (dos/var.h): a process's local variables and aliases, and
//! the flags of SetVar, GetVar, DeleteVar and FindVar. Global variables
//! are files in ENV:.

const MinNode = @import("../exec/nodes.zig").MinNode;

/// struct LocalVar: one local variable or alias on a process's
/// pr_LocalVars, sorted by name. dos allocates it (with its name and
/// value) and frees it; FindVar hands it out.
pub const LocalVar = extern struct {
    /// lv_Node's links.
    node: MinNode = .{},
    /// lv_Node.ln_Type: LV_VAR or LV_ALIAS; with LVF_IGNORE set, SetVar,
    /// GetVar and FindVar don't see it (the shell hides an alias so while
    /// it expands it).
    var_type: u8 = LV_VAR,
    /// lv_Flags: GVF_BINARY_VAR when it was set as binary.
    flags: u16 = 0,
    /// lv_Node.ln_Name
    name: [*:0]u8,
    /// lv_Value: `len` bytes (and a NUL after them).
    value: [*]u8,
    /// lv_Len
    len: u32 = 0,
};

// The types (a SetVar/GetVar flag's low byte).
pub const LV_VAR: u8 = 0;
pub const LV_ALIAS: u8 = 1;
pub const LVB_IGNORE = 7;
pub const LVF_IGNORE: u8 = 1 << LVB_IGNORE;

// SetVar, GetVar and DeleteVar's flags.
/// ENV: only, not the local variables.
pub const GVF_GLOBAL_ONLY: u32 = 0x100;
/// The local variables only.
pub const GVF_LOCAL_ONLY: u32 = 0x200;
/// The value as it is: not cut at a newline.
pub const GVF_BINARY_VAR: u32 = 0x400;
/// With GVF_BINARY_VAR: no NUL after the value.
pub const GVF_DONT_NULL_TERM: u32 = 0x800;
/// With a global SetVar: ENVARC:name too.
pub const GVF_SAVE_VAR: u32 = 0x1000;
