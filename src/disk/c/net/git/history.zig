// SPDX-License-Identifier: MIT
//! The history: commits walked newest first, by the committer's time -
//! a queue of the commits reached and not yet shown, each commit's
//! parents put in when it is taken out - and two commits compared: how
//! many commits each has that the other has not.
//!
//! A commit is marked in a table of ids (open addressing, the first four
//! bytes of the id its hash), so each is queued once. The commits listed
//! in `.git/shallow` are where the history is cut: their parents are not
//! there, and are not looked for.
//!
//! **Ahead and behind**: both commits are queued, each marked with its
//! side; a commit taken out hands its marks on to its parents. A side's
//! mark that reaches a commit taken out before - a clock that went back
//! dates a commit before its parent - is handed on down the history
//! already walked. The walk ends when every commit still queued carries
//! both marks - all that is behind them is shared - none of them is
//! dated after the oldest commit taken out without both, and that has
//! held for `slop_most` commits more. The commits seen with one side's
//! mark only are that side's own. A walk for what one side lacks ends
//! on the other side's mark alone (`ends`).

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const _git = @import("_git.zig");
const object = @import("object.zig");
const files = @import("files.zig");
const packread = @import("packread.zig");
const Repository = @import("repo.zig").Repository;
const Id = _git.Id;

const shallow_most = 64 * 1024 * 1024;

pub const mark_seen: u8 = 1;
pub const mark_left: u8 = 2;
pub const mark_right: u8 = 4;
pub const mark_shallow: u8 = 8;
pub const mark_taken: u8 = 16;

/// The commits taken out after the walk could end, for a clock that went
/// back.
const slop_most = 5;

/// Marks by id.
pub const Marks = struct {
    sys: *ExecBase,
    slots: []Slot = &.{},
    count: usize = 0,

    const Slot = struct {
        id: Id,
        marks: u8,
        used: bool,
    };

    pub fn deinit(table: *Marks) void {
        if (table.slots.len != 0) table.sys.FreeVec(table.slots.ptr);
        table.slots = &.{};
        table.count = 0;
    }

    /// The marks of `id`, null when it has none.
    pub fn get(table: *const Marks, id: *const Id) ?*u8 {
        if (table.slots.len == 0) return null;
        const slot = table.find(id);
        return if (slot.used) &slot.marks else null;
    }

    /// The marks of `id`, none at first; null when there is no memory.
    pub fn put(table: *Marks, id: *const Id) ?*u8 {
        if ((table.count + 1) * 10 > table.slots.len * 7) {
            if (!table.grow()) return null;
        }
        const slot = table.find(id);
        if (!slot.used) {
            slot.* = .{ .id = id.*, .marks = 0, .used = true };
            table.count += 1;
        }
        return &slot.marks;
    }

    fn find(table: *const Marks, id: *const Id) *Slot {
        const mask = table.slots.len - 1;
        var at: usize = _git.get32(id[0..4]) & mask;
        while (true) : (at = (at + 1) & mask) {
            const slot = &table.slots[at];
            if (!slot.used or _git.same(&slot.id, id)) return slot;
        }
    }

    fn grow(table: *Marks) bool {
        const size = if (table.slots.len == 0) 1024 else table.slots.len * 2;
        const memory = table.sys.AllocVec(size * @sizeOf(Slot), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        const old = table.slots;
        table.slots = @as([*]Slot, @ptrCast(@alignCast(memory)))[0..size];
        table.count = 0;
        for (old) |*slot| {
            if (!slot.used) continue;
            const into = table.find(&slot.id);
            into.* = slot.*;
            table.count += 1;
        }
        if (old.len != 0) table.sys.FreeVec(old.ptr);
        return true;
    }
};

const Queued = struct {
    id: Id,
    time: i64,
};

/// Commits newest first.
pub const Walk = struct {
    repo: *Repository,
    marks: Marks,
    queue: []Queued = &.{},
    queued: usize = 0,
    /// The commits a late mark goes on to.
    spreading: []Id = &.{},
    spread_count: usize = 0,
    /// The time of the oldest commit taken out without the left side's
    /// mark, and without the right's; how many more may be taken out once
    /// the walk could end.
    oldest_without: [2]?i64 = .{ null, null },
    slop: u32 = slop_most,
    /// A commit was missing or broken (said).
    failed: bool = false,

    pub fn init(walk: *Walk, repo: *Repository) bool {
        walk.* = .{ .repo = repo, .marks = .{ .sys = repo.git.sys } };
        return walk.readShallow();
    }

    pub fn deinit(walk: *Walk) void {
        walk.marks.deinit();
        if (walk.queue.len != 0) walk.repo.git.sys.FreeVec(walk.queue.ptr);
        if (walk.spreading.len != 0) walk.repo.git.sys.FreeVec(walk.spreading.ptr);
        walk.queue = &.{};
        walk.queued = 0;
        walk.spreading = &.{};
        walk.spread_count = 0;
    }

    /// The commits `.git/shallow` names marked: their parents are not
    /// walked to.
    fn readShallow(walk: *Walk) bool {
        const git = walk.repo.git;
        var path: files.Path = undefined;
        const name = walk.repo.path(&path, &.{"shallow"}) orelse return false;
        const text = files.readWhole(git, name, shallow_most) orelse return true;
        defer git.free(text.ptr);
        var at: usize = 0;
        while (at + 40 <= text.len) {
            if (_git.idOf(text[at..][0..40])) |id| {
                const marks = walk.marks.put(&id) orelse return walk.noMemory();
                marks.* |= mark_shallow;
            }
            while (at < text.len and text[at] != '\n') at += 1;
            at += 1;
        }
        return true;
    }

    fn noMemory(walk: *Walk) bool {
        walk.repo.git.say("no memory\n", .{});
        walk.failed = true;
        return false;
    }

    /// `id` put in the queue with `marks`, unless it was put in before:
    /// then it takes the marks on, and a commit taken out already hands
    /// a side's mark it did not have on to its history.
    pub fn add(walk: *Walk, id: *const Id, marks: u8) bool {
        const held = walk.marks.put(id) orelse return walk.noMemory();
        const before = held.*;
        held.* |= marks | mark_seen;
        if (before & mark_seen != 0) {
            const late = marks & ~before & (mark_left | mark_right);
            if (late != 0 and before & mark_taken != 0) return walk.spread(id, late);
            return true;
        }
        var found = walk.repo.objects.read(id) orelse return walk.missing();
        defer found.free(walk.repo.git.sys);
        if (found.kind != .commit) return walk.missing();
        const commit = object.parseCommit(found.data) orelse return walk.missing();
        return walk.push(.{ .id = id.*, .time = commit.committer.time });
    }

    /// `late` handed on to the parents of `id`, and on from each that
    /// was taken out before; a stack of ids, not recursion.
    fn spread(walk: *Walk, id: *const Id, late: u8) bool {
        const sys = walk.repo.git.sys;
        walk.spread_count = 0;
        if (!walk.pushSpread(id)) return false;
        while (walk.spread_count > 0) {
            walk.spread_count -= 1;
            const at = walk.spreading[walk.spread_count];
            if (walk.marks.get(&at).?.* & mark_shallow != 0) continue;
            var found = walk.repo.objects.read(&at) orelse return walk.missing();
            defer found.free(sys);
            const commit = object.parseCommit(found.data) orelse return walk.missing();
            for (0..commit.parent_count) |number| {
                const parent = commit.parent(number);
                // Every parent of a commit taken out was put in.
                const marks = walk.marks.get(&parent) orelse continue;
                if (marks.* & late == late) continue;
                marks.* |= late;
                if (marks.* & mark_taken != 0 and !walk.pushSpread(&parent)) return false;
            }
        }
        return true;
    }

    fn pushSpread(walk: *Walk, id: *const Id) bool {
        if (walk.spread_count == walk.spreading.len) {
            const size = if (walk.spreading.len == 0) 64 else walk.spreading.len * 2;
            const memory = walk.repo.git.sys.AllocVec(size * @sizeOf(Id), exec.MEMF_ANY) orelse return walk.noMemory();
            const grown = @as([*]Id, @ptrCast(@alignCast(memory)))[0..size];
            @memcpy(grown[0..walk.spread_count], walk.spreading[0..walk.spread_count]);
            if (walk.spreading.len != 0) walk.repo.git.sys.FreeVec(walk.spreading.ptr);
            walk.spreading = grown;
        }
        walk.spreading[walk.spread_count] = id.*;
        walk.spread_count += 1;
        return true;
    }

    fn missing(walk: *Walk) bool {
        walk.repo.git.say("the history names a commit the repository does not have\n", .{});
        walk.failed = true;
        return false;
    }

    /// A commit taken out of the walk: its id, its object as read (the
    /// caller frees it), and its marks then - a side's mark may come
    /// later.
    pub const Taken = struct {
        id: Id,
        commit: packread.Object,
        marks: u8,
    };

    /// The newest commit queued, taken out, its parents queued with its
    /// marks; null at the end and when the walk failed.
    pub fn next(walk: *Walk) ?Taken {
        if (walk.failed or walk.queued == 0) return null;
        const top = walk.pop();
        const git = walk.repo.git;
        var found = walk.repo.objects.read(&top.id) orelse {
            _ = walk.missing();
            return null;
        };
        const commit = object.parseCommit(found.data) orelse {
            found.free(git.sys);
            _ = walk.missing();
            return null;
        };
        const held = walk.marks.get(&top.id).?;
        held.* |= mark_taken;
        const marks = held.*;
        const sides = marks & (mark_left | mark_right);
        if (sides != 0) {
            for (&walk.oldest_without, [_]u8{ mark_left, mark_right }) |*oldest, side| {
                if (sides & side == 0 and (oldest.* == null or top.time < oldest.*.?)) oldest.* = top.time;
            }
        }
        if (marks & mark_shallow == 0) {
            for (0..commit.parent_count) |number| {
                const parent = commit.parent(number);
                if (!walk.add(&parent, marks & (mark_left | mark_right))) {
                    found.free(git.sys);
                    return null;
                }
            }
        }
        return .{ .id = top.id, .commit = found, .marks = marks };
    }

    /// Whether the walk of two sides can end: every commit queued
    /// carries `sides` - both sides' marks, or one side's - none is dated
    /// after the oldest commit taken out without them, and that held for
    /// the last `slop_most` calls.
    pub fn ends(walk: *Walk, sides: u8) bool {
        if (walk.queued == 0) return true;
        var late = false;
        for (walk.oldest_without, [_]u8{ mark_left, mark_right }) |oldest, side| {
            if (sides & side != 0 and oldest != null and walk.queue[0].time >= oldest.?) late = true;
        }
        if (late or !walk.allCarry(sides)) {
            walk.slop = slop_most;
            return false;
        }
        if (walk.slop == 0) return true;
        walk.slop -= 1;
        return false;
    }

    fn allCarry(walk: *const Walk, sides: u8) bool {
        for (walk.queue[0..walk.queued]) |*queued| {
            const marks = walk.marks.get(&queued.id).?.*;
            if (marks & sides != sides) return false;
        }
        return true;
    }

    /// The marks `id` ends the walk with; 0 for a commit not seen.
    pub fn marksOf(walk: *const Walk, id: *const Id) u8 {
        const held = walk.marks.get(id) orelse return 0;
        return held.*;
    }

    fn push(walk: *Walk, item: Queued) bool {
        if (walk.queued == walk.queue.len) {
            const size = if (walk.queue.len == 0) 64 else walk.queue.len * 2;
            const memory = walk.repo.git.sys.AllocVec(size * @sizeOf(Queued), exec.MEMF_ANY) orelse return walk.noMemory();
            const grown = @as([*]Queued, @ptrCast(@alignCast(memory)))[0..size];
            @memcpy(grown[0..walk.queued], walk.queue[0..walk.queued]);
            if (walk.queue.len != 0) walk.repo.git.sys.FreeVec(walk.queue.ptr);
            walk.queue = grown;
        }
        // Up the heap: the newest at the top.
        var at = walk.queued;
        walk.queued += 1;
        while (at > 0) {
            const parent = (at - 1) / 2;
            if (walk.queue[parent].time >= item.time) break;
            walk.queue[at] = walk.queue[parent];
            at = parent;
        }
        walk.queue[at] = item;
        return true;
    }

    fn pop(walk: *Walk) Queued {
        const top = walk.queue[0];
        walk.queued -= 1;
        const last = walk.queue[walk.queued];
        var at: usize = 0;
        while (true) {
            var child = 2 * at + 1;
            if (child >= walk.queued) break;
            if (child + 1 < walk.queued and walk.queue[child + 1].time > walk.queue[child].time) child += 1;
            if (walk.queue[child].time <= last.time) break;
            walk.queue[at] = walk.queue[child];
            at = child;
        }
        if (walk.queued > 0) walk.queue[at] = last;
        return top;
    }
};

/// How many commits `left` has that `right` has not, and the other way.
pub const Counts = struct { ahead: u32, behind: u32 };

/// `left` and `right` compared; null, said, when the history cannot be
/// read.
pub fn compare(repo: *Repository, left: *const Id, right: *const Id) ?Counts {
    var counts: Counts = .{ .ahead = 0, .behind = 0 };
    if (_git.same(left, right)) return counts;
    const walk = repo.git.create(Walk) orelse return null;
    defer repo.git.free(walk);
    if (!walk.init(repo)) return null;
    defer walk.deinit();
    if (!walk.add(left, mark_left) or !walk.add(right, mark_right)) return null;
    while (!walk.ends(mark_left | mark_right)) {
        var taken = walk.next() orelse break;
        taken.commit.free(repo.git.sys);
    }
    if (walk.failed) return null;
    // The commits seen, with the marks they end with: those still queued
    // carry both.
    for (walk.marks.slots) |*slot| {
        if (!slot.used or slot.marks & mark_seen == 0) continue;
        switch (slot.marks & (mark_left | mark_right)) {
            mark_left => counts.ahead += 1,
            mark_right => counts.behind += 1,
            else => {},
        }
    }
    return counts;
}

/// Whether `ancestor` is in the history of `commit`: null, said, when the
/// history cannot be read.
pub fn isAncestor(repo: *Repository, ancestor: *const Id, commit: *const Id) ?bool {
    const counts = compare(repo, ancestor, commit) orelse return null;
    return counts.ahead == 0;
}
