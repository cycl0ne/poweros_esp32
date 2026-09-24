// SPDX-License-Identifier: MIT
//! Named objects. All a program sees of one is its no_Object pointer;
//! the rest is utility.library's.

const Tag = @import("tagitem.zig").Tag;

/// struct NamedObject.
pub const NamedObject = extern struct {
    /// no_Object: the user space, or whatever the owner puts here.
    object: ?*anyopaque = null,
};

/// AllocNamedObjectA's tags. ANO_NameSpace: BOOL, give the object a name
/// space. ANO_UserSpace: bytes of user space, cleared and aligned to a
/// pointer; no_Object points to it. ANO_Priority: its ln_Pri in a name
/// space. ANO_Flags: the flags of its name space.
pub const ANO_NameSpace: Tag = 4000;
pub const ANO_UserSpace: Tag = 4001;
pub const ANO_Priority: Tag = 4002;
pub const ANO_Flags: Tag = 4003;

/// ANO_Flags: no two objects with the same name; names compared with case.
pub const NSB_NODUPS = 0;
pub const NSB_CASE = 1;
pub const NSF_NODUPS: u32 = 1 << NSB_NODUPS;
pub const NSF_CASE: u32 = 1 << NSB_CASE;
