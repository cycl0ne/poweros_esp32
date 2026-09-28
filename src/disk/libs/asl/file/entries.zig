// SPDX-License-Identifier: MIT
//! The lines of a file requester's list: what one is, how a drawer is
//! read into them a piece at a time, and how the volumes and assigns are
//! read in their place.
//!
//! An entry is one allocation: the node, what the entry is, and then its
//! name and the text of the right-hand column, one after the other. A
//! name of two characters costs what two characters cost, which a drawer
//! of some thousands of files makes worth doing.
//!
//! The list is kept in order as it grows - drawers first, then by name,
//! without regard to case - rather than sorted at the end, because the
//! requester shows it while it is still being read.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// How many bytes of entries one ExAll call is given. A piece at a time
/// is what lets the requester answer input while a drawer is read; this
/// is how big a piece is.
pub const chunk_bytes = 2048;

/// The most an entry's right-hand column says: a size in bytes, or the
/// word for a drawer.
const right_max = 16;

/// One line of the list.
pub const Entry = extern struct {
    node: exec.Node = .{},
    /// ST_*: above 0 a drawer, below 0 a file.
    kind: i32 = 0,
    size: u64 align(4) = 0,
    /// The name, its NUL, then the right-hand column's text and its NUL.
    /// `node.name` points at the first and `right` finds the second.
    text: [1]u8 = @splat(0),

    pub fn name(e: *const Entry) [*:0]const u8 {
        return @ptrCast(&e.text);
    }

    pub fn right(e: *const Entry) [*:0]const u8 {
        var at: usize = 0;
        const from: [*]const u8 = @ptrCast(&e.text);
        while (from[at] != 0) at += 1;
        return @ptrCast(from + at + 1);
    }

    pub fn isDir(e: *const Entry) bool {
        return e.kind > 0;
    }
};

fn textLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;
}

/// `value` as decimal digits in `into`, and how many there are.
fn decimal(value: u64, into: []u8) usize {
    var digits: [20]u8 = undefined;
    var left = value;
    var count: usize = 0;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    var i: usize = 0;
    while (i < count and i < into.len) : (i += 1) into[i] = digits[count - 1 - i];
    return i;
}

/// Where an entry goes: before the first line it sorts ahead of. Drawers
/// come before files, and within each the names in order without regard
/// to case.
fn before(ub: *UtilityBase, one: *const Entry, other: *const Entry) bool {
    if (one.isDir() != other.isDir()) return one.isDir();
    const a = one.name();
    const b = other.name();
    var i: usize = 0;
    while (a[i] != 0 and b[i] != 0) : (i += 1) {
        const x = ub.ToUpper(a[i]);
        const y = ub.ToUpper(b[i]);
        if (x != y) return x < y;
    }
    return b[i] != 0;
}

/// An entry made and put in its place in `list`. False without memory.
pub fn add(sys: *ExecBase, ub: *UtilityBase, list: *exec.List, name: [*:0]const u8, kind: i32, size: u64) bool {
    var right: [right_max]u8 = @splat(0);
    var right_len: usize = 0;
    if (kind > 0) {
        const word = "Drawer";
        @memcpy(right[0..word.len], word);
        right_len = word.len;
    } else {
        right_len = decimal(size, right[0 .. right.len - 1]);
    }
    const name_len = textLen(name);
    const bytes = @offsetOf(Entry, "text") + name_len + 1 + right_len + 1;
    const block = sys.AllocVec(bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    const entry: *Entry = @ptrCast(@alignCast(block));
    entry.* = .{ .kind = kind, .size = size };
    const text: [*]u8 = @ptrCast(&entry.text);
    @memcpy(text[0..name_len], name[0..name_len]);
    text[name_len] = 0;
    @memcpy(text[name_len + 1 ..][0..right_len], right[0..right_len]);
    text[name_len + 1 + right_len] = 0;
    entry.node.name = entry.name();

    var at = list.first();
    while (at) |node| : (at = node.next()) {
        const other: *Entry = @fieldParentPtr("node", node);
        if (before(ub, entry, other)) {
            sys.Insert(list, &entry.node, node.pred);
            return true;
        }
    }
    sys.AddTail(list, &entry.node);
    return true;
}

/// Every entry freed and the list emptied.
pub fn empty(sys: *ExecBase, list: *exec.List) void {
    while (sys.RemHead(list)) |node| {
        const entry: *Entry = @fieldParentPtr("node", node);
        sys.FreeVec(@ptrCast(entry));
    }
}

/// How far a drawer has been read. `lock` null means there is nothing
/// more to read.
pub const Walk = struct {
    lock: ?*dos.FileLock = null,
    control: ?*dos.ExAllControl = null,
    buffer: ?[*]u8 = null,

    /// The walk over `drawer` begun. False when the drawer cannot be
    /// read, with `IoErr` saying why.
    pub fn start(w: *Walk, sys: *ExecBase, dl: *DosBase, drawer: [*:0]const u8) bool {
        w.stop(sys, dl);
        w.lock = dl.Lock(drawer, dos.SHARED_LOCK) orelse return false;
        w.control = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_EXALLCONTROL, null) orelse {
            w.stop(sys, dl);
            return false;
        }));
        const block = sys.AllocVec(chunk_bytes, exec.MEMF_ANY) orelse {
            w.stop(sys, dl);
            return false;
        };
        w.buffer = @ptrCast(block);
        return true;
    }

    /// The walk given up, whatever it holds.
    pub fn stop(w: *Walk, sys: *ExecBase, dl: *DosBase) void {
        if (w.control) |control| {
            if (w.lock != null and w.buffer != null) {
                dl.ExAllEnd(w.lock, w.buffer.?, chunk_bytes, dos.ED_SIZE, control);
            }
            dl.FreeDosObject(dos.DOS_EXALLCONTROL, @ptrCast(control));
        }
        if (w.buffer) |block| sys.FreeVec(@ptrCast(block));
        if (w.lock) |lock| dl.UnLock(lock);
        w.control = null;
        w.buffer = null;
        w.lock = null;
    }

    pub fn reading(w: *const Walk) bool {
        return w.lock != null;
    }
};
