// SPDX-License-Identifier: MIT
//! `Git add PATHS/M [ALL]`: files put in the index as they are now, for
//! the next commit. A file is written into the store as a blob and its
//! entry set to it; a directory - the work tree for ALL - has every file
//! the index knows in it brought up to date, its gone ones taken out,
//! and every file the index does not know put in, but those `.gitignore`
//! leaves out. A file named that `.gitignore` leaves out is refused; a
//! path that is gone has its entries taken out.
//!
//! The index keeps no executable bit for a file it did not have
//! (`core.filemode` is false on a dos volume): a new file is 100644, and
//! one it had keeps its mode. A file the work tree does not hold
//! (skip-worktree: a name a dos volume cannot have) is left as it is.
//!
//! The work tree is walked as `status` walks it, an explicit stack of
//! directories, each one's `.gitignore` in effect below it.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const object = @import("object.zig");
const index = @import("index.zig");
const files = @import("files.zig");
const ignore = @import("ignore.zig");
const loose = @import("loose.zig");
const worktree = @import("worktree.zig");
const staging_module = @import("staging.zig");
const context = @import("context.zig");
const Repository = @import("repo.zig").Repository;
const Git = context.Git;

pub const template = "PATHS/M,ALL=A/S";
const arg_paths = 0;
const arg_all = 1;
pub const arg_count = 2;

const walk_depth = ignore.depth_most;

pub fn run(git: *Git, argv: []const usize) i32 {
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    const paths = dos.rdargs.multi(argv[arg_paths]);
    const all = argv[arg_all] != 0;
    if (paths.len == 0 and !all) {
        git.say("nothing named, nothing added: name the paths, or ALL\n", .{});
        return dos.RETURN_WARN;
    }
    const adding = Adding.open(repo) orelse return dos.RETURN_ERROR;
    defer adding.close();
    if (all) {
        if (!adding.directory("")) return dos.RETURN_ERROR;
    } else {
        for (paths) |given| {
            var into: files.Path = undefined;
            const path = repo.gitPath(given, &into) orelse return dos.RETURN_ERROR;
            if (!adding.path(path)) return dos.RETURN_ERROR;
        }
    }
    if (!adding.finish()) return dos.RETURN_ERROR;
    return if (adding.refused != 0) dos.RETURN_WARN else dos.RETURN_OK;
}

const Level = struct {
    lock: *dos.FileLock,
    fib: dos.FileInfoBlock,
    /// How much of `git_path` is this directory's (its `/` included).
    git_length: usize,
    /// It has a `.gitignore` on the stack.
    ignores: bool,
};

/// The index being changed, and what it takes to change it.
pub const Adding = struct {
    repo: *Repository,
    git: *Git,
    staging: staging_module.Staging,
    work: worktree.Work,
    ignores: ignore.Ignores = .{},
    /// Paths refused (said).
    refused: u32 = 0,
    depth: usize = 0,
    levels: [walk_depth]Level = undefined,
    git_path: files.Path = undefined,
    name: [dos.name_max * 2 + 1]u8 = undefined,
    /// The directory being gone into.
    local_path: files.Path = undefined,
    /// The file being put in. The paths live here, not on the stack,
    /// which a walk this deep would outgrow.
    file_path: files.Path = undefined,
    prefix: files.Path = undefined,
    ignore_name: files.Path = undefined,
    ignore_path: files.Path = undefined,

    /// The repository's index read: null, said, when it cannot be.
    pub fn open(repo: *Repository) ?*Adding {
        const git = repo.git;
        const adding = git.create(Adding) orelse return null;
        adding.repo = repo;
        adding.git = git;
        adding.ignores = .{};
        adding.refused = 0;
        adding.depth = 0;
        adding.work.init(repo);
        if (!adding.staging.open(repo)) {
            adding.work.deinit();
            git.free(adding);
            return null;
        }
        adding.work.index_seconds = adding.staging.file.seconds;
        return adding;
    }

    pub fn close(adding: *Adding) void {
        const git = adding.git;
        while (adding.depth > 0) adding.leave();
        adding.staging.close();
        adding.work.deinit();
        git.free(adding);
    }

    /// The index written back, when it was changed.
    pub fn finish(adding: *Adding) bool {
        if (!adding.staging.changed) return true;
        return adding.staging.write();
    }

    /// `path` put in as it is: a file, a directory, or a path gone.
    fn path(adding: *Adding, given: []const u8) bool {
        const git = adding.git;
        const dl = git.dl;
        const local = adding.work.localPath(&adding.file_path, given) orelse return tooLong(git);
        const lock = dl.Lock(local, dos.SHARED_LOCK) orelse {
            if (adding.staging.remove(given)) return true;
            const range = adding.staging.below(dirPrefix(&adding.prefix, given) orelse return tooLong(git));
            if (range.end > range.start) {
                adding.staging.removeRange(range.start, range.end);
                return true;
            }
            git.say("%s matches no file\n", .{local});
            adding.refused += 1;
            return true;
        };
        const examined = dl.Examine(lock, &adding.work.fib);
        dl.UnLock(lock);
        if (!examined) {
            _ = dl.PrintFault(dl.IoErr(), local);
            return false;
        }
        if (dos.isDirectory(adding.work.fib.dir_entry_type)) {
            if (adding.staging.find(given)) |entry| {
                if (entry.mode == object.mode_gitlink) return true;
            }
            return adding.directory(given);
        }
        if (adding.staging.find(given) == null) {
            adding.pushParents(given);
            const ignored = adding.ignores.ignored(given, false);
            adding.popAll();
            if (ignored) {
                adding.git.endProgress();
                adding.git.put("Git: ");
                adding.git.put(given);
                adding.git.put(" is left out by .gitignore - not added\n");
                adding.refused += 1;
                return true;
            }
        }
        return adding.file(given, local);
    }

    /// The directory `prefix` (`""` for the work tree): its files the
    /// index knows brought up to date, then those it does not put in.
    pub fn directory(adding: *Adding, given: []const u8) bool {
        if (!adding.updateTracked(given)) return false;
        return adding.addUntracked(given);
    }

    /// Every file the index knows in `given` (all for `""`) put in as
    /// it is now; a file gone taken out.
    pub fn updateTracked(adding: *Adding, given: []const u8) bool {
        const git = adding.git;
        const range = adding.staging.below(dirPrefix(&adding.prefix, given) orelse return tooLong(git));
        var at = range.start;
        var end = range.end;
        while (at < end) {
            if (git.stopped()) {
                git.say("stopped\n", .{});
                return false;
            }
            const entry = &adding.staging.entries[at];
            if (entry.skip_worktree or entry.mode == object.mode_gitlink) {
                at += 1;
                continue;
            }
            const local = adding.work.localPath(&adding.file_path, entry.path) orelse {
                at += 1;
                continue;
            };
            switch (adding.work.stateOf(entry, local)) {
                .same => {
                    if (adding.work.hashed) {
                        adding.work.noteExamined(entry);
                        adding.staging.changed = true;
                    }
                    at += 1;
                },
                .changed => {
                    if (!adding.file(entry.path, local)) return false;
                    at += 1;
                },
                .missing => {
                    adding.staging.removeRange(at, at + 1);
                    end -= 1;
                },
            }
        }
        return true;
    }

    /// The file `given` at `local` written as a blob, its entry set.
    fn file(adding: *Adding, given: []const u8, local: [*:0]const u8) bool {
        const git = adding.git;
        const dl = git.dl;
        const fib = &adding.work.fib;
        const lock = dl.Lock(local, dos.SHARED_LOCK) orelse {
            _ = dl.PrintFault(dl.IoErr(), local);
            return false;
        };
        const examined = dl.Examine(lock, fib);
        dl.UnLock(lock);
        if (!examined) {
            _ = dl.PrintFault(dl.IoErr(), local);
            return false;
        }
        if (fib.size > 0xFFFFFFFF) {
            git.say("%s is larger than 4 GiB\n", .{local});
            return false;
        }
        var mode = object.mode_file;
        if (adding.staging.find(given)) |held| {
            if (held.skip_worktree) return true;
            mode = held.mode;
        }
        const id = loose.writeFile(adding.repo, local, fib.size) orelse return false;
        var entry: index.Entry = .{ .mode = mode, .size = 0, .id = id, .path = given };
        adding.work.noteExamined(&entry);
        return adding.staging.put(&entry);
    }

    /// The files in `given` the index does not know, and `.gitignore`
    /// does not leave out, put in.
    fn addUntracked(adding: *Adding, given: []const u8) bool {
        const git = adding.git;
        const dl = git.dl;
        adding.pushParents(given);
        defer adding.popAll();
        const start = dirPrefix(&adding.prefix, given) orelse return tooLong(git);
        @memcpy(adding.git_path[0..start.len], start);
        // The work tree's own `.gitignore` is on the stack already.
        if (!adding.enter(start.len, start.len != 0)) return false;
        while (adding.depth > 0) {
            if (git.stopped()) {
                git.say("stopped\n", .{});
                return false;
            }
            const level = &adding.levels[adding.depth - 1];
            if (!dl.ExNext(level.lock, &level.fib)) {
                adding.leave();
                continue;
            }
            const local_name = files.span(@ptrCast(&level.fib.file_name));
            const git_name = files.gitName(&adding.name, local_name) orelse continue;
            if (level.git_length == 0 and isDotGit(git_name)) continue;
            if (level.git_length + git_name.len + 2 > files.path_most) continue;
            @memcpy(adding.git_path[level.git_length..][0..git_name.len], git_name);
            const git_length = level.git_length + git_name.len;
            const entry_path = adding.git_path[0..git_length];
            const is_directory = dos.isDirectory(level.fib.dir_entry_type);
            if (adding.ignores.ignored(entry_path, is_directory)) continue;
            if (is_directory) {
                if (adding.staging.find(entry_path) != null) continue;
                if (adding.depth == walk_depth) continue;
                adding.git_path[git_length] = '/';
                if (!adding.enter(git_length + 1, true)) return false;
                continue;
            }
            if (adding.staging.find(entry_path) != null) continue;
            if (!worktree.Work.allowed(entry_path)) continue;
            const local = adding.work.localPath(&adding.file_path, entry_path) orelse continue;
            if (!adding.file(entry_path, local)) return false;
        }
        return true;
    }

    /// The directory `git_path[0..git_length]` gone into; its
    /// `.gitignore` read, unless `pushParents` read it.
    fn enter(adding: *Adding, git_length: usize, read_ignores: bool) bool {
        const git = adding.git;
        const dl = git.dl;
        const dir_path = adding.git_path[0..git_length];
        const without_slash = if (dir_path.len > 0) dir_path[0 .. dir_path.len - 1] else dir_path;
        const local = adding.work.localPath(&adding.local_path, without_slash) orelse return true;
        const lock = dl.Lock(local, dos.SHARED_LOCK) orelse return true;
        const level = &adding.levels[adding.depth];
        level.* = .{ .lock = lock, .fib = .{}, .git_length = git_length, .ignores = false };
        if (!dl.Examine(lock, &level.fib)) {
            dl.UnLock(lock);
            return true;
        }
        adding.depth += 1;
        if (read_ignores) level.ignores = adding.pushIgnore(dir_path);
        return true;
    }

    fn leave(adding: *Adding) void {
        adding.depth -= 1;
        const level = &adding.levels[adding.depth];
        if (level.ignores) adding.ignores.pop();
        adding.git.dl.UnLock(level.lock);
    }

    /// The `.gitignore` of the directory `dir_path` (`a/b/`, `""` for
    /// the work tree) put on the stack: whether it was.
    fn pushIgnore(adding: *Adding, dir_path: []const u8) bool {
        var out: _git.Out = .{ .into = adding.ignore_name[0..files.path_most] };
        out.put(dir_path);
        out.put(".gitignore");
        if (out.overflow) return false;
        const local = adding.work.localPath(&adding.ignore_path, out.written()) orelse return false;
        return adding.ignores.push(adding.git, &adding.staging.arena, local, dir_path);
    }

    /// The rules in effect in `given`'s directory: `info/exclude`, and
    /// the `.gitignore` of each directory from the work tree down to it.
    fn pushParents(adding: *Adding, given: []const u8) void {
        if (adding.repo.path(&adding.ignore_path, &.{"info/exclude"})) |name| _ = adding.ignores.push(adding.git, &adding.staging.arena, name, "");
        // The directories above: every `/`'s prefix.
        _ = adding.pushIgnore("");
        var end: usize = 0;
        while (end < given.len) : (end += 1) {
            if (given[end] != '/') continue;
            _ = adding.pushIgnore(given[0 .. end + 1]);
        }
    }

    fn popAll(adding: *Adding) void {
        while (adding.ignores.count > 0) adding.ignores.pop();
    }
};

/// `given` as a directory's prefix, `a/b/` - `""` for the work tree.
fn dirPrefix(into: *files.Path, given: []const u8) ?[]const u8 {
    if (given.len == 0) return "";
    if (given.len + 1 > files.path_most) return null;
    @memcpy(into[0..given.len], given);
    into[given.len] = '/';
    return into[0 .. given.len + 1];
}

fn isDotGit(name: []const u8) bool {
    return name.len == 4 and name[0] == '.' and (name[1] | 0x20) == 'g' and (name[2] | 0x20) == 'i' and (name[3] | 0x20) == 't';
}

fn tooLong(git: *Git) bool {
    git.say("the path is too long\n", .{});
    return false;
}
