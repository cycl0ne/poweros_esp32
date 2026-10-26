// SPDX-License-Identifier: MIT
//! The index as `add`, `rm` and `commit` change it: its entries in an
//! array, sorted as the index sorts them, so a path is found by halving;
//! an entry put in or taken out moves those after it. The paths of the
//! entries read stay in the index's bytes; a new one's is copied into an
//! arena. Written back through `index.lock` as a whole.

const sdk = @import("sdk");
const _git = @import("_git.zig");
const index = @import("index.zig");
const worktree = @import("worktree.zig");
const context = @import("context.zig");
const Repository = @import("repo.zig").Repository;
const Git = context.Git;

pub const Staging = struct {
    repo: *Repository,
    git: *Git,
    file: worktree.IndexFile = .{},
    arena: context.Arena,
    entries: []index.Entry = &.{},
    count: usize = 0,
    /// Something was put in or taken out.
    changed: bool = false,

    /// The repository's index read: false, said, when it cannot be.
    pub fn open(staging: *Staging, repo: *Repository) bool {
        const git = repo.git;
        staging.* = .{ .repo = repo, .git = git, .arena = .{ .sys = git.sys } };
        if (!staging.file.read(repo)) return false;
        const count: usize = if (staging.file.index) |found| found.count else 0;
        if (!staging.grow(count + 16)) return false;
        var walk = staging.file.entries();
        while (walk.next()) |entry| {
            if (staging.count == staging.entries.len) break;
            staging.entries[staging.count] = entry;
            staging.count += 1;
        }
        if (walk.bad()) {
            git.say("the index is broken\n", .{});
            staging.close();
            return false;
        }
        return true;
    }

    pub fn close(staging: *Staging) void {
        staging.file.free(staging.git);
        staging.arena.free();
    }

    pub fn all(staging: *const Staging) []index.Entry {
        return staging.entries[0..staging.count];
    }

    fn grow(staging: *Staging, size: usize) bool {
        const memory = staging.arena.take(@sizeOf(index.Entry) * size, @alignOf(index.Entry)) orelse {
            staging.git.say("no memory\n", .{});
            return false;
        };
        const grown = @as([*]index.Entry, @ptrCast(@alignCast(memory)))[0..size];
        @memcpy(grown[0..staging.count], staging.entries[0..staging.count]);
        staging.entries = grown;
        return true;
    }

    /// Where `path` is, or would go.
    pub fn lowerBound(staging: *const Staging, path: []const u8) usize {
        var low: usize = 0;
        var high = staging.count;
        while (low < high) {
            const middle = (low + high) / 2;
            if (_git.order(staging.entries[middle].path, path) == .less) low = middle + 1 else high = middle;
        }
        return low;
    }

    /// The entry of `path`, stage 0.
    pub fn find(staging: *const Staging, path: []const u8) ?*index.Entry {
        const at = staging.lowerBound(path);
        if (at < staging.count and _git.same(staging.entries[at].path, path)) return &staging.entries[at];
        return null;
    }

    /// The entries in the directory `prefix` (`dir/`; everything for an
    /// empty one), as a range.
    pub fn below(staging: *const Staging, prefix: []const u8) struct { start: usize, end: usize } {
        const start = staging.lowerBound(prefix);
        var end = start;
        while (end < staging.count and _git.startsWith(staging.entries[end].path, prefix)) end += 1;
        return .{ .start = start, .end = end };
    }

    /// `entry` put in at its path, in place of what was there - every
    /// stage of it. False, said, when there is no memory.
    pub fn put(staging: *Staging, entry: *const index.Entry) bool {
        const at = staging.lowerBound(entry.path);
        var end = at;
        while (end < staging.count and _git.same(staging.entries[end].path, entry.path)) end += 1;
        var copy = entry.*;
        copy.stage = 0;
        if (end > at) {
            // The path is the one there already: kept.
            copy.path = staging.entries[at].path;
            staging.removeRange(at + 1, end);
            staging.entries[at] = copy;
            staging.changed = true;
            return true;
        }
        copy.path = staging.arena.copy(entry.path) orelse {
            staging.git.say("no memory\n", .{});
            return false;
        };
        if (staging.count == staging.entries.len and !staging.grow(staging.entries.len * 2)) return false;
        var move = staging.count;
        while (move > at) : (move -= 1) staging.entries[move] = staging.entries[move - 1];
        staging.entries[at] = copy;
        staging.count += 1;
        staging.changed = true;
        return true;
    }

    /// The entries from `start` up to `end` taken out.
    pub fn removeRange(staging: *Staging, start: usize, end: usize) void {
        if (end <= start) return;
        const gone = end - start;
        var at = start;
        while (at + gone < staging.count) : (at += 1) staging.entries[at] = staging.entries[at + gone];
        staging.count -= gone;
        staging.changed = true;
    }

    /// `path`'s entries taken out: whether there were any.
    pub fn remove(staging: *Staging, path: []const u8) bool {
        const start = staging.lowerBound(path);
        var end = start;
        while (end < staging.count and _git.same(staging.entries[end].path, path)) end += 1;
        staging.removeRange(start, end);
        return end > start;
    }

    /// The index written back: false, said, when it could not be.
    pub fn write(staging: *Staging) bool {
        var skipped = false;
        for (staging.all()) |*entry| {
            if (entry.skip_worktree) skipped = true;
        }
        var source: Source = .{ .entries = staging.all() };
        return worktree.writeIndex(staging.repo, @intCast(staging.count), skipped, &source);
    }

    const Source = struct {
        entries: []const index.Entry,
        at: usize = 0,

        pub fn next(source: *Source) ?*const index.Entry {
            if (source.at == source.entries.len) return null;
            source.at += 1;
            return &source.entries[source.at - 1];
        }
    };
};
