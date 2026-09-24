// SPDX-License-Identifier: MIT
//! icclass and modelclass: objects that tell other objects what changed.
//!
//! An **icclass** object is a connection. What arrives at it as
//! `OM_NOTIFY` or `OM_UPDATE` it passes on to its target as `OM_UPDATE`,
//! with the tags first translated through its map: the slider says
//! "position", the thing it moves wants "top", and the map says the one is
//! the other. A connection that is already passing something on passes
//! nothing more, so two objects that are each other's targets stop after
//! one round instead of calling each other for ever.
//!
//! A **modelclass** object is a connection with members: what arrives at
//! it goes to every member (`OM_ADDMEMBER`) and then to its own target. It
//! is where one value that several things show is kept in step. Disposing
//! of a model disposes of its members with it.

const utility = @import("../utility/utility.zig");
const classusr = @import("classusr.zig");
const MethodID = classusr.MethodID;

// --- attributes ---------------------------------------------------------------

pub const ICA_Dummy = utility.TAG_USER + 0x40000;
/// The object updates go to, or `ICTARGET_IDCMP`. None by default, which
/// passes nothing on.
pub const ICA_TARGET = ICA_Dummy + 1;
/// Tag pairs, each translating the tag in `tag` into the one in `data`,
/// ending in TAG_DONE. Not copied, so it must outlive the connection.
/// Tags it does not name pass unchanged.
pub const ICA_MAP = ICA_Dummy + 2;

/// A tag an update aimed at `ICTARGET_IDCMP` may carry - usually made by
/// the connection's ICA_MAP from one of the sender's attributes - whose
/// data becomes the IDCMP_IDCMPUPDATE message's `code`. The whole value is
/// kept, as `code` is 32 bits. The tag stays in the message's list too.
pub const ICSPECIAL_CODE = ICA_Dummy + 3;

/// A target that means "the window's messages" rather than an object: the
/// update arrives as IDCMP_IDCMPUPDATE, for a window that asked for it, on
/// the window the update's GadgetInfo names.
pub const ICTARGET_IDCMP: usize = ~@as(usize, 0);

// --- methods ------------------------------------------------------------------

/// Where icclass's methods begin; used for nothing itself.
pub const ICM_Dummy: MethodID = 0x0401;
/// Count the connection as busy passing something on.
pub const ICM_SETLOOP: MethodID = 0x0402;
/// Count it as done.
pub const ICM_CLEARLOOP: MethodID = 0x0403;
/// How busy it is: 0 when it is free to pass something on.
pub const ICM_CHECKLOOP: MethodID = 0x0404;
