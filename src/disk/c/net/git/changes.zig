// SPDX-License-Identifier: MIT
//! What has changed in a repository, three ways: the index against
//! HEAD's tree (what the next commit holds that HEAD does not: staged),
//! the work tree against the index (what is changed but not staged),
//! and the files of the work tree the index does not know (untracked),
//! less what `.gitignore` leaves out.
//!
//! The index and HEAD's tree are walked side by side, both in path
//! order. The work tree is checked an entry of the index at a time
//! (worktree.zig's `stateOf`); a file it had to hash and found
//! unchanged has its date noted in the index, which is written back, so
//! the next look does not hash it again. The untracked files are found
//! by walking the work tree's directories, an explicit stack of them, a
//! directory the index has nothing in shown as itself, `dir/`; they are
//! handed out sorted by path.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const object = @import("object.zig");
const index = @import("index.zig");
const files = @import("files.zig");
const ignore = @import("ignore.zig");
const worktree = @import("worktree.zig");
const context = @import("context.zig");
const Repository = @import("repo.zig").Repository;
const Git = context.Git;
const Id = _git.Id;

pub const Kind = enum {
    added,
    modified,
    deleted,

    pub fn letter(kind: Kind) u8 {
        return switch (kind) {
            .added => 'A',
            .modified => 'M',
            .deleted => 'D',
        };
    }
};

/// A path that changed; false from it stops the walk.
pub const ChangeFn = *const fn (context: *anyopaque, kind: Kind, path: []const u8) bool;
/// A path the index does not know (`dir/` for a directory).
pub const UntrackedFn = *const fn (context: *anyopaque, path: []const u8) bool;

/// How deep the untracked walk goes.
const walk_depth = ignore.depth_most;

const Level = struct {
    lock: *dos.FileLock,
    fib: dos.FileInfoBlock,
    /// How much of `git_path` and `local_path` is this directory's.
    git_length: usize,
    local_length: usize,
    /// It has a `.gitignore` on the stack.
    ignores: bool,
};

pub const Changes = struct {
    repo: *Repository,
    git: *Git,
    file: worktree.IndexFile,
    work: *worktree.Work,
    arena: context.Arena,
    /// The index's paths, sorted, for the untracked walk.
    paths: [][]const u8 = &.{},

    /// The repository's index read: null, said, when it cannot be.
    pub fn open(repo: *Repository) ?*Changes {
        const git = repo.git;
        const changes = git.create(Changes) orelse return null;
        changes.* = .{
            .repo = repo,
            .git = git,
            .file = .{},
            .work = undefined,
            .arena = .{ .sys = git.sys },
        };
        changes.work = git.create(worktree.Work) orelse {
            git.free(changes);
            return null;
        };
        changes.work.init(repo);
        if (!changes.file.read(repo)) {
            changes.close();
            return null;
        }
        changes.work.index_seconds = changes.file.seconds;
        return changes;
    }

    pub fn close(changes: *Changes) void {
        const git = changes.git;
        changes.file.free(git);
        changes.work.deinit();
        git.free(changes.work);
        changes.arena.free();
        git.free(changes);
    }

    /// Each path whose index entry differs from HEAD's tree (`head_tree`,
    /// none on an unborn branch).
    pub fn staged(changes: *Changes, head_tree: ?*const Id, each: ChangeFn, each_context: *anyopaque) bool {
        const git = changes.git;
        const walk = git.create(worktree.TreeWalk) orelse return false;
        defer git.free(walk);
        if (!walk.start(changes.repo, head_tree)) return false;
        defer walk.deinit();
        var entries = changes.file.entries();
        var item = walk.nextFile();
        var entry = entries.next();
        while (item != null or entry != null) {
            const order = if (item == null) .greater else if (entry == null) .less else _git.order(item.?.path, entry.?.path);
            switch (order) {
                .less => {
                    if (!each(each_context, .deleted, item.?.path)) return true;
                    item = walk.nextFile();
                },
                .greater => {
                    if (!each(each_context, .added, entry.?.path)) return true;
                    entry = entries.next();
                },
                .equal => {
                    const held = entry.?;
                    const given = item.?;
                    if (held.mode != worktree.normalMode(given.mode) or !_git.same(&held.id, &given.id)) {
                        if (!each(each_context, .modified, held.path)) return true;
                    }
                    item = walk.nextFile();
                    entry = entries.next();
                },
            }
        }
        if (walk.failed) return false;
        if (entries.bad()) {
            git.say("the index is broken\n", .{});
            return false;
        }
        return true;
    }

    /// Each path whose file differs from its index entry, or is gone.
    pub fn unstaged(changes: *Changes, each: ChangeFn, each_context: *anyopaque) bool {
        const git = changes.git;
        const work = changes.work;
        var entries = changes.file.entries();
        var local_path: files.Path = undefined;
        var refreshed: u32 = 0;
        while (entries.next()) |held| {
            if (git.stopped()) {
                git.say("stopped\n", .{});
                return false;
            }
            if (held.skip_worktree or held.stage != 0) continue;
            const local = work.localPath(&local_path, held.path) orelse continue;
            switch (work.stateOf(&held, local)) {
                .same => if (work.hashed and held.mode != object.mode_gitlink) {
                    var noted = held;
                    work.noteExamined(&noted);
                    index.patchStat(changes.file.bytes, entries.inner.?.last_at, &noted);
                    refreshed += 1;
                },
                .changed => if (!each(each_context, .modified, held.path)) return true,
                .missing => if (!each(each_context, .deleted, held.path)) return true,
            }
        }
        if (entries.bad()) {
            git.say("the index is broken\n", .{});
            return false;
        }
        // The dates noted, so these files are not hashed again; an index
        // that cannot be written now is no failure.
        if (refreshed != 0) _ = changes.file.rewrite(changes.repo);
        return true;
    }

    /// Each file and directory of the work tree the index does not know
    /// and `.gitignore` does not leave out, sorted.
    pub fn untracked(changes: *Changes, each: UntrackedFn, each_context: *anyopaque) bool {
        if (!changes.sortPaths()) return false;
        const found = changes.findUntracked() orelse return false;
        _git.heapSort([]const u8, found, {}, pathBefore);
        for (found) |path| {
            if (!each(each_context, path)) return true;
        }
        return true;
    }

    /// The index's paths in an array, sorted as the index is.
    fn sortPaths(changes: *Changes) bool {
        const count = if (changes.file.index) |found| found.count else 0;
        const memory = changes.arena.take(@sizeOf([]const u8) * (count + 1), @alignOf([]const u8)) orelse return noMemory(changes.git);
        const paths = @as([*][]const u8, @ptrCast(@alignCast(memory)))[0..count];
        var entries = changes.file.entries();
        var taken: usize = 0;
        while (entries.next()) |held| {
            if (taken == count) break;
            paths[taken] = held.path;
            taken += 1;
        }
        changes.paths = paths[0..taken];
        return true;
    }

    /// Whether the index has `path`.
    fn tracked(changes: *const Changes, path: []const u8) bool {
        const at = changes.lowerBound(path);
        return at < changes.paths.len and _git.same(changes.paths[at], path);
    }

    /// Whether the index has a path in the directory `prefix` (`dir/`).
    fn trackedBelow(changes: *const Changes, prefix: []const u8) bool {
        const at = changes.lowerBound(prefix);
        return at < changes.paths.len and _git.startsWith(changes.paths[at], prefix);
    }

    fn lowerBound(changes: *const Changes, path: []const u8) usize {
        var low: usize = 0;
        var high = changes.paths.len;
        while (low < high) {
            const middle = (low + high) / 2;
            if (_git.order(changes.paths[middle], path) == .less) low = middle + 1 else high = middle;
        }
        return low;
    }

    /// The work tree walked, what is untracked collected.
    fn findUntracked(changes: *Changes) ?[][]const u8 {
        const git = changes.git;
        const dl = git.dl;
        const repo = changes.repo;
        const state = git.create(UntrackedWalk) orelse return null;
        defer git.free(state);
        state.* = .{ .dl = dl, .depth = 0, .levels = undefined, .git_path = undefined, .local_path = undefined, .name = undefined };
        var found: Found = .{ .arena = &changes.arena };

        var path: files.Path = undefined;
        if (repo.path(&path, &.{"info/exclude"})) |name| _ = state.ignores.push(git, &changes.arena, name, "");
        const work_root = repo.workText();
        @memcpy(state.local_path[0..work_root.len], work_root);
        var local_length = work_root.len;
        if (local_length != 0 and work_root[local_length - 1] != ':' and work_root[local_length - 1] != '/') {
            state.local_path[local_length] = '/';
            local_length += 1;
        }
        if (!state.enter(changes, local_length, 0, "")) return null;
        var failed = false;
        while (state.depth > 0) {
            if (git.stopped()) {
                git.say("stopped\n", .{});
                failed = true;
                break;
            }
            const level = &state.levels[state.depth - 1];
            if (!dl.ExNext(level.lock, &level.fib)) {
                state.leave();
                continue;
            }
            const local_name = files.span(@ptrCast(&level.fib.file_name));
            const git_name = files.gitName(&state.name, local_name) orelse continue;
            if (level.git_length == 0 and git_name.len == 4 and isDotGit(git_name)) continue;
            if (level.git_length + git_name.len + 2 > files.path_most or level.local_length + local_name.len + 2 > files.path_most) continue;
            @memcpy(state.git_path[level.git_length..][0..git_name.len], git_name);
            const git_length = level.git_length + git_name.len;
            const entry_path = state.git_path[0..git_length];
            const directory = dos.isDirectory(level.fib.dir_entry_type);
            if (!directory) {
                if (changes.tracked(entry_path) or state.ignores.ignored(entry_path, false)) continue;
                if (!found.add(entry_path)) {
                    failed = true;
                    break;
                }
                continue;
            }
            if (changes.tracked(entry_path) or state.ignores.ignored(entry_path, true)) continue;
            state.git_path[git_length] = '/';
            @memcpy(state.local_path[level.local_length..][0..local_name.len], local_name);
            const local_end = level.local_length + local_name.len;
            state.local_path[local_end] = '/';
            if (changes.trackedBelow(state.git_path[0 .. git_length + 1])) {
                if (state.depth == walk_depth) continue;
                if (!state.enter(changes, local_end + 1, git_length + 1, state.git_path[0 .. git_length + 1])) {
                    failed = true;
                    break;
                }
                continue;
            }
            // A directory the index has nothing in: itself, if not empty.
            state.local_path[local_end] = 0;
            if (!isEmpty(git, @ptrCast(&state.local_path))) {
                if (!found.add(state.git_path[0 .. git_length + 1])) {
                    failed = true;
                    break;
                }
            }
        }
        while (state.depth > 0) state.leave();
        if (failed) return null;
        return found.slice() orelse noMemoryList(git);
    }
};

fn pathBefore(_: void, a: *const []const u8, b: *const []const u8) bool {
    return _git.order(a.*, b.*) == .less;
}

fn isDotGit(name: []const u8) bool {
    return name[0] == '.' and (name[1] | 0x20) == 'g' and (name[2] | 0x20) == 'i' and (name[3] | 0x20) == 't';
}

fn noMemory(git: *Git) bool {
    git.say("no memory\n", .{});
    return false;
}

fn noMemoryList(git: *Git) ?[][]const u8 {
    git.say("no memory\n", .{});
    return null;
}

/// Whether the directory at `local` holds nothing.
fn isEmpty(git: *Git, local: [*:0]const u8) bool {
    const dl = git.dl;
    const fib = git.create(dos.FileInfoBlock) orelse return true;
    defer git.free(fib);
    const lock = dl.Lock(local, dos.SHARED_LOCK) orelse return true;
    defer dl.UnLock(lock);
    if (!dl.Examine(lock, fib)) return true;
    return !dl.ExNext(lock, fib);
}

/// The untracked paths found, copied.
const Found = struct {
    arena: *context.Arena,
    first: ?*Node = null,
    count: usize = 0,

    const Node = struct { path: []const u8, next: ?*Node };

    fn add(found: *Found, path: []const u8) bool {
        const copied = found.arena.copy(path) orelse return false;
        const node = found.arena.create(Node, .{ .path = copied, .next = found.first }) orelse return false;
        found.first = node;
        found.count += 1;
        return true;
    }

    fn slice(found: *Found) ?[][]const u8 {
        const memory = found.arena.take(@sizeOf([]const u8) * (found.count + 1), @alignOf([]const u8)) orelse return null;
        const paths = @as([*][]const u8, @ptrCast(@alignCast(memory)))[0..found.count];
        var node = found.first;
        var at: usize = 0;
        while (node) |each| : (node = each.next) {
            paths[at] = each.path;
            at += 1;
        }
        return paths;
    }
};

const UntrackedWalk = struct {
    dl: *sdk.interface.dos.DosBase,
    depth: usize,
    levels: [walk_depth]Level,
    ignores: ignore.Ignores = .{},
    git_path: files.Path,
    local_path: files.Path,
    name: [dos.name_max * 2 + 1]u8,

    /// The directory at `local_path[0..local_length]` (its `/` included)
    /// gone into, its `.gitignore` read.
    fn enter(state: *UntrackedWalk, changes: *Changes, local_length: usize, git_length: usize, base: []const u8) bool {
        const git = changes.git;
        const dl = git.dl;
        // The directory's own path, without its `/` - unless it is a
        // volume's root.
        var lock_length = local_length;
        if (lock_length > 0 and state.local_path[lock_length - 1] == '/') lock_length -= 1;
        const saved = state.local_path[lock_length];
        state.local_path[lock_length] = 0;
        const lock = dl.Lock(@ptrCast(&state.local_path), dos.SHARED_LOCK);
        state.local_path[lock_length] = saved;
        const held = lock orelse return true;
        const level = &state.levels[state.depth];
        level.* = .{ .lock = held, .fib = .{}, .git_length = git_length, .local_length = local_length, .ignores = false };
        if (!dl.Examine(held, &level.fib)) {
            dl.UnLock(held);
            return true;
        }
        state.depth += 1;
        var ignore_path: files.Path = undefined;
        @memcpy(ignore_path[0..local_length], state.local_path[0..local_length]);
        const ignore_name = ".gitignore";
        if (local_length + ignore_name.len < files.path_most) {
            @memcpy(ignore_path[local_length..][0..ignore_name.len], ignore_name);
            ignore_path[local_length + ignore_name.len] = 0;
            level.ignores = state.ignores.push(git, &changes.arena, @ptrCast(&ignore_path), base);
        }
        return true;
    }

    fn leave(state: *UntrackedWalk) void {
        state.depth -= 1;
        const level = &state.levels[state.depth];
        if (level.ignores) state.ignores.pop();
        state.dl.UnLock(level.lock);
    }
};
