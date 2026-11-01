// SPDX-License-Identifier: MIT
//! What an update does with one path. Three things are compared, not two
//! - the list the machine was given (`install.installed_manifest`), the
//! list the package holds, and the file itself - and this is the rule
//! that says which of them wins, so that the command and its tests
//! answer the same question.
//!
//! **The file is only read where the two lists differ.** Where they agree
//! it is looked for and not read, so a file edited on the machine is left
//! alone unread while one that went missing is written again; where they
//! differ the file decides between "the build changed it" and "it was
//! changed here".
//!
//! What was changed here is kept and named rather than written over, and
//! that includes a file the machine made at a path the build has since
//! begun to ship: a list the machine was never given cannot say the file
//! is the build's. `FORCE` is how the package wins instead.

const manifest = @import("manifest.zig");

pub const Entry = manifest.Entry;

/// What reading the file on the machine said, held against the two
/// lists.
pub const Here = enum {
    /// There, and its length and sum are what the installed list says.
    same,
    /// There, and already what the package's list says: an update that
    /// was cut off after this file was written and before its list was,
    /// so there is nothing left to do with it.
    wanted,
    /// There, and neither list's: changed on this machine - or there
    /// while the installed list does not name it at all, which is the
    /// machine's own file.
    changed,
    /// Not there.
    gone,
    /// There, and not read, because the two lists say the same about it.
    unread,
};

/// What is done with the path.
pub const Action = enum {
    /// Nothing: the lists agree, or the drawer is there already.
    keep,
    /// A drawer to make.
    make,
    /// Fetched to a name of its own, summed, and renamed into place.
    write,
    /// Changed here: kept, and said so by name.
    kept,
    /// The build no longer ships it: deleted.
    delete,
};

/// The rule. `installed` is the entry the machine's own list has for the
/// path and `new` the package's, either of them null where that list does
/// not name it; `here` is what reading the file said. `force` lets the
/// package win over what was changed here.
pub fn actionFor(installed: ?Entry, new: ?Entry, here: Here, force: bool) Action {
    if (new) |want| {
        if (want.kind == .drawer) {
            const had = installed orelse return .make;
            // A path that was a file and is now a drawer: made, and the
            // file in the way is what the command says went wrong.
            return if (had.kind == .drawer and here != .gone) .keep else .make;
        }
        if (installed) |had| {
            // Both lists say the same about it, and it is there: left as
            // it is, whatever is in it. Gone, it is written again.
            if (had.kind == .file and had.crc == want.crc and had.size == want.size and here != .gone) return .keep;
        }
        return switch (here) {
            .wanted => .keep,
            .changed => if (force) .write else .kept,
            else => .write,
        };
    }
    const had = installed orelse return .keep;
    if (had.kind == .drawer) return .delete;
    return switch (here) {
        // Nothing in the package names it, so a file that is neither
        // what was installed nor gone was changed here.
        .changed, .wanted => if (force) .delete else .kept,
        .gone => .keep,
        else => .delete,
    };
}

/// Whether the two lists say the same about a path, which is when the
/// file is looked for and not read.
pub fn agree(installed: ?Entry, new: ?Entry) bool {
    const had = installed orelse return false;
    const want = new orelse return false;
    if (had.kind != want.kind) return false;
    if (had.kind == .drawer) return true;
    return had.crc == want.crc and had.size == want.size;
}
