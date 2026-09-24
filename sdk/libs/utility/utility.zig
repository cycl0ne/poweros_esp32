// SPDX-License-Identifier: MIT
//! utility.library's structures and constants, a file per area, and
//! everything also here by name.

pub const tagitem = @import("tagitem.zig");
pub const hooks = @import("hooks.zig");
pub const date = @import("date.zig");
pub const name = @import("name.zig");
pub const pack = @import("pack.zig");
pub const pattern = @import("pattern.zig");

/// utility.library's base, with its functions.
pub const UtilityBase = @import("../../interface/utility.zig").UtilityBase;

pub const Tag = tagitem.Tag;
pub const TagItem = tagitem.TagItem;
pub const FixedTagItem = tagitem.FixedTagItem;
pub const fixedList = tagitem.fixedList;
pub const TAG_DONE = tagitem.TAG_DONE;
pub const TAG_END = tagitem.TAG_END;
pub const TAG_IGNORE = tagitem.TAG_IGNORE;
pub const TAG_MORE = tagitem.TAG_MORE;
pub const TAG_SKIP = tagitem.TAG_SKIP;
pub const TAG_USER = tagitem.TAG_USER;
pub const TAGFILTER_AND = tagitem.TAGFILTER_AND;
pub const TAGFILTER_NOT = tagitem.TAGFILTER_NOT;
pub const MAP_REMOVE_NOT_FOUND = tagitem.MAP_REMOVE_NOT_FOUND;
pub const MAP_KEEP_NOT_FOUND = tagitem.MAP_KEEP_NOT_FOUND;

pub const Hook = hooks.Hook;
pub const HookFn = hooks.HookFn;

pub const ClockData = date.ClockData;

pub const P_ANY = pattern.P_ANY;
pub const P_SINGLE = pattern.P_SINGLE;
pub const P_ORSTART = pattern.P_ORSTART;
pub const P_ORNEXT = pattern.P_ORNEXT;
pub const P_OREND = pattern.P_OREND;
pub const P_NOT = pattern.P_NOT;
pub const P_NOTEND = pattern.P_NOTEND;
pub const P_NOTCLASS = pattern.P_NOTCLASS;
pub const P_CLASS = pattern.P_CLASS;
pub const P_REPBEG = pattern.P_REPBEG;
pub const P_REPEND = pattern.P_REPEND;
pub const P_STOP = pattern.P_STOP;
pub const parsedSize = pattern.parsedSize;

pub const NamedObject = name.NamedObject;
pub const ANO_NameSpace = name.ANO_NameSpace;
pub const ANO_UserSpace = name.ANO_UserSpace;
pub const ANO_Priority = name.ANO_Priority;
pub const ANO_Flags = name.ANO_Flags;
pub const NSB_NODUPS = name.NSB_NODUPS;
pub const NSB_CASE = name.NSB_CASE;
pub const NSF_NODUPS = name.NSF_NODUPS;
pub const NSF_CASE = name.NSF_CASE;

/// SDivMod32's result: the quotient, and the remainder with the sign of
/// the dividend.
pub const SDivMod32Result = extern struct {
    quotient: i32,
    remainder: i32,
};

/// UDivMod32's result: the quotient and the remainder.
pub const UDivMod32Result = extern struct {
    quotient: u32,
    remainder: u32,
};
