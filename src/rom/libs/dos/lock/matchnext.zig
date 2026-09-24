// SPDX-License-Identifier: MPL-2.0
//! MatchNext: finds the next object of a pattern search.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const entryName = _lock.entryName;
const relLock = _lock.relLock;
const report = _lock.report;
const freeLevels = _lock.freeLevels;
const examineNode = _lock.examineNode;
const any_name = _lock.any_name;
const addAnchor = _lock.addAnchor;
const Step = _lock.Step;
const FileLock = dos.FileLock;
const Search = _lock.Search;
const finish = _lock.finish;

/// Finds the next object a pattern search names.
///
/// SYNOPSIS:
/// ```zig
/// fn MatchNext(db: *DosBase, anchor: *dos.AnchorPath) i32
/// ```
///
/// SINCE: 1.0. LVO -340.
///
/// INPUTS:
/// - `anchor` - the search MatchFirst started. Set APF_DODIR in ap_Flags
///   first to go into the directory just found.
///
/// RESULT:
/// 0 when an object was found, as MatchFirst. Otherwise an error, also in
/// IoErr: ERROR_NO_MORE_ENTRIES when the search is done,
/// ERROR_BUFFER_OVERFLOW when the path was cut to fit, ERROR_BREAK when one
/// of ap_BreakBits came (ap_FoundBreak says which), ERROR_NO_FREE_STORE, or
/// a handler's error.
///
/// BEHAVIOR:
/// With APF_DODIR the directory just found is gone into (a hard link to a
/// directory only with APF_FollowHLinks); once it is read through it comes
/// once more, with APF_DIDDIR set, which stays set until the caller clears
/// it. APF_DirChanged says the entry is in another directory than the one
/// before. The break signals are checked, and cleared, between entries. Any
/// error but ERROR_BUFFER_OVERFLOW frees the chain.
///
/// CONTEXT:
/// - Waits: yes, for the handlers' answers.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do for a pattern with a device; without one the
///   search starts in the current directory, which only a process has.
///
/// OWNERSHIP:
/// As MatchFirst: the anchor holds locks and memory until MatchEnd.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MatchFirst`, `MatchEnd`
///
/// EXAMPLES:
/// ```zig
/// while (dos_lib.MatchNext(&anchor) == 0) {
///     if (anchor.info.dir_entry_type > 0 and anchor.flags & dos.APF_DIDDIR == 0) anchor.flags |= dos.APF_DODIR;
///     anchor.flags &= ~dos.APF_DIDDIR;
/// }
/// ```
pub fn MatchNext(db: *DosBase, anchor: *dos.AnchorPath) i32 {
    const dos_lib = db.iface();
    anchor.flags &= ~dos.APF_DirChanged;
    if (anchor.flags & dos.APF_NOMEMERR != 0) return finish(db, anchor, dos.ERROR_NO_FREE_STORE);
    if (anchor.base == null) return finish(db, anchor, dos.ERROR_NO_MORE_ENTRIES);
    var node = anchor.last orelse return finish(db, anchor, dos.ERROR_NO_MORE_ENTRIES);
    var s: Search = .{ .db = db, .ap = anchor };
    var found: ?*FileLock = null;
    var at: Step = .loop;
    if (anchor.flags & dos.APF_DODIR != 0) {
        anchor.flags &= ~dos.APF_DODIR;
        if (anchor.flags & dos.APF_FollowHLinks == 0 and anchor.info.dir_entry_type == dos.ST_LINKDIR) {
            at = .did_dir;
        } else {
            const all = addAnchor(&s, &any_name, dos.DDF_PatternBit) catch return finish(db, anchor, s.code);
            all.flags |= dos.DDF_AllBit;
            at = .new_node; // `node`, the directory's level, goes into it
        }
    }
    while (true) {
        switch (at) {
            .loop => {
                at = .enter;
                if (node.flags & dos.DDF_Single == 0) {
                    if (node.lock) |l| {
                        if (examineNode(&s, node, l) != .ok) at = .up;
                    }
                }
            },
            .enter => {
                if (node.flags & dos.DDF_PatternBit != 0) {
                    at = .wild;
                } else {
                    node.flags &= ~dos.DDF_ExaminedBit;
                    if (node.flags & dos.DDF_Completed == 0) {
                        at = .locate;
                    } else {
                        node.flags &= ~dos.DDF_Completed;
                        at = .up;
                    }
                }
            },
            .up => {
                if (node.lock) |l| dos_lib.UnLock(l);
                node.lock = null;
                const old = node;
                node = old.parent orelse return finish(db, anchor, dos.ERROR_NO_MORE_ENTRIES);
                anchor.last = node;
                anchor.flags |= dos.APF_DirChanged;
                if (old.flags & dos.DDF_AllBit != 0) {
                    freeLevels(db, old);
                    node.child = null;
                    at = .did_dir;
                } else if (node.flags & dos.DDF_PatternBit != 0) {
                    at = .enter;
                }
            },
            .did_dir => {
                anchor.flags |= dos.APF_DIDDIR;
                return report(db, anchor);
            },
            .wild => {
                at = .up;
                const dir = node.lock orelse continue;
                while (_lock.step(db, dir, &node.info, .examine_next) == null) {
                    const hit = db.sys_base.SetSignal(0, anchor.break_bits) & anchor.break_bits;
                    if (hit != 0) {
                        anchor.found_break = hit;
                        return finish(db, anchor, dos.ERROR_BREAK);
                    }
                    if (!db.utility_base.MatchPatternNoCase(node.string(), @ptrCast(&node.info.file_name))) continue;
                    if (node.child == null) return report(db, anchor);
                    if (node.info.dir_entry_type >= 0) {
                        at = .new_node; // a directory: on into it
                        break;
                    }
                }
            },
            .new_node => {
                node.flags |= dos.DDF_ExaminedBit;
                at = .locate;
            },
            .locate => {
                if (relLock(&s, node, entryName(node))) |l| {
                    switch (examineNode(&s, node, l)) {
                        .ok => {
                            found = l;
                            at = .check;
                            continue;
                        },
                        .not_dir => {
                            dos_lib.UnLock(l);
                            at = .up;
                            continue;
                        },
                        .failed => dos_lib.UnLock(l),
                    }
                } else |_| {}
                // Not found goes on to the next entry for a pattern.
                if (s.code != dos.ERROR_OBJECT_NOT_FOUND or anchor.flags & dos.APF_ITSWILD == 0) return finish(db, anchor, s.code);
                at = .up;
            },
            .check => {
                const l = found.?;
                if (node.flags & dos.DDF_PatternBit == 0) {
                    // The name it was locked by, not Examine's (links, "a/b//").
                    const part = dos_lib.FilePart(node.string());
                    const name = part[0..db.utility_base.Strlen(part)];
                    if (name.len >= node.info.file_name.len) {
                        dos_lib.UnLock(l);
                        return finish(db, anchor, dos.ERROR_LINE_TOO_LONG);
                    }
                    @memcpy(node.info.file_name[0..name.len], name);
                    node.info.file_name[name.len] = 0;
                }
                const child = node.child orelse {
                    node.flags |= dos.DDF_Completed;
                    dos_lib.UnLock(l);
                    return report(db, anchor);
                };
                node = child;
                node.lock = l;
                anchor.last = node;
                node.flags &= ~dos.DDF_ExaminedBit;
                anchor.flags |= dos.APF_DirChanged;
                at = .loop;
            },
        }
    }
}
