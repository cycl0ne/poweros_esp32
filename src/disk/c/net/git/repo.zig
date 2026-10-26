// SPDX-License-Identifier: MIT
//! A repository: its work tree and the `.git` directory in it, found from
//! the current directory up as git finds it, or named (a clone, an init),
//! and the paths inside both put together - a dos path joined to git's
//! `/`-separated one.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const files = @import("files.zig");
const store = @import("store.zig");
const refs = @import("refs.zig");
const Git = @import("context.zig").Git;

/// `.git/config`'s core settings, for a dos volume: no executable bit
/// kept, no links, names alike in any case.
pub const core_config =
    "[core]\n" ++
    "\trepositoryformatversion = 0\n" ++
    "\tfilemode = false\n" ++
    "\tbare = false\n" ++
    "\tlogallrefupdates = true\n" ++
    "\tsymlinks = false\n" ++
    "\tignorecase = true\n";

/// Whether two dos names are alike, their case aside.
fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lower_x = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const lower_y = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (lower_x != lower_y) return false;
    }
    return true;
}

pub const Repository = struct {
    git: *Git,
    /// The work tree, `Work:poweros`, NUL-terminated.
    work: files.Path,
    work_length: usize,
    /// Its `.git`.
    dir: files.Path,
    dir_length: usize,
    objects: store.Store,

    /// The repository the current directory is in, or one above it:
    /// null, said, when there is none.
    pub fn find(git: *Git) ?*Repository {
        const dl = git.dl;
        var lock = dl.Lock("", dos.ACCESS_READ) orelse {
            _ = dl.PrintFault(dl.IoErr(), "Git");
            return null;
        };
        var name: files.Path = undefined;
        while (true) {
            if (!dl.NameFromLock(lock, &name, files.path_most)) {
                dl.UnLock(lock);
                _ = dl.PrintFault(dl.IoErr(), "Git");
                return null;
            }
            var candidate: files.Path = undefined;
            if (files.child(&candidate, files.span(@ptrCast(&name)), &.{".git"})) |git_dir| {
                if (dl.Lock(git_dir, dos.ACCESS_READ)) |found| {
                    dl.UnLock(found);
                    dl.UnLock(lock);
                    return open(git, files.span(@ptrCast(&name)));
                }
            }
            const parent = dl.ParentDir(lock);
            dl.UnLock(lock);
            lock = parent orelse {
                git.say("not in a repository (no .git here or above)\n", .{});
                return null;
            };
        }
    }

    /// The repository whose work tree is `work`, its `.git` there or
    /// not yet.
    pub fn open(git: *Git, work: []const u8) ?*Repository {
        const repo = git.create(Repository) orelse return null;
        repo.git = git;
        const work_path = files.join(&repo.work, &.{work}) orelse {
            git.say("the path is too long\n", .{});
            git.free(repo);
            return null;
        };
        repo.work_length = files.span(work_path).len;
        const dir_path = files.child(&repo.dir, repo.workText(), &.{".git"}) orelse {
            git.say("the path is too long\n", .{});
            git.free(repo);
            return null;
        };
        repo.dir_length = files.span(dir_path).len;
        repo.objects.init(git, repo.dirText());
        return repo;
    }

    pub fn close(repo: *Repository) void {
        repo.objects.deinit();
        repo.git.free(repo);
    }

    pub fn workText(repo: *const Repository) []const u8 {
        return repo.work[0..repo.work_length];
    }

    pub fn dirText(repo: *const Repository) []const u8 {
        return repo.dir[0..repo.dir_length];
    }

    /// `.git/<parts>`; null, said, when it is too long.
    pub fn path(repo: *const Repository, into: *files.Path, parts: []const []const u8) ?[*:0]const u8 {
        return files.child(into, repo.dirText(), parts) orelse {
            repo.git.say("the path is too long\n", .{});
            return null;
        };
    }

    /// `<work tree>/<name>`; null when it is too long.
    pub fn workPathQuiet(repo: *const Repository, into: *files.Path, name: []const u8) ?[*:0]const u8 {
        return files.child(into, repo.workText(), &.{name});
    }

    /// `.git` and the directories in it made, HEAD naming `branch`
    /// (`refs/heads/main`): false, said, when they could not be.
    pub fn layOut(repo: *Repository, branch: []const u8) bool {
        const git = repo.git;
        for ([_][]const u8{ "objects/pack/", "objects/info/", "refs/heads/", "refs/tags/" }) |dir| {
            var into: files.Path = undefined;
            const name = repo.path(&into, &.{dir}) orelse return false;
            if (!files.makeDirs(git, name)) {
                _ = git.dl.PrintFault(git.dl.IoErr(), name);
                return false;
            }
        }
        return refs.writeSymbolic(repo, "HEAD", branch);
    }

    /// The path in the work tree, as git writes it, of the dos path
    /// `given` - whole, or from the current directory - whether it is
    /// there or not: empty for the work tree itself. Null, said, when it
    /// is outside the work tree, or too long.
    pub fn gitPath(repo: *const Repository, given: [*:0]const u8, into: *files.Path) ?[]const u8 {
        const git = repo.git;
        const dl = git.dl;
        var full: files.Path = undefined;
        var length: usize = 0;
        if (dl.Lock(given, dos.SHARED_LOCK)) |lock| {
            defer dl.UnLock(lock);
            if (!dl.NameFromLock(lock, &full, files.path_most)) return repo.outside(given);
            length = files.span(@ptrCast(&full)).len;
        } else {
            // Not there: its directory, and its name after it.
            const text = files.span(given);
            var cut = text.len;
            while (cut > 0 and text[cut - 1] != '/' and text[cut - 1] != ':') cut -= 1;
            // `dir/name`'s directory is `dir`, `Work:name`'s `Work:`.
            var parent: files.Path = undefined;
            var parent_length = cut;
            if (parent_length > 0 and text[parent_length - 1] == '/') parent_length -= 1;
            if (parent_length >= files.path_most) return repo.outside(given);
            @memcpy(parent[0..parent_length], text[0..parent_length]);
            parent[parent_length] = 0;
            const lock = dl.Lock(@ptrCast(&parent), dos.SHARED_LOCK) orelse return repo.outside(given);
            defer dl.UnLock(lock);
            if (!dl.NameFromLock(lock, &full, files.path_most)) return repo.outside(given);
            length = files.span(@ptrCast(&full)).len;
            const name = text[cut..];
            if (length > 0 and full[length - 1] != ':' and full[length - 1] != '/') {
                if (length + 1 >= files.path_most) return repo.outside(given);
                full[length] = '/';
                length += 1;
            }
            if (length + name.len >= files.path_most) return repo.outside(given);
            @memcpy(full[length..][0..name.len], name);
            length += name.len;
        }
        const work = repo.workText();
        if (length < work.len or !sameName(full[0..work.len], work)) return repo.outside(given);
        var rest = full[work.len..length];
        if (rest.len > 0) {
            if (work[work.len - 1] != ':' and work[work.len - 1] != '/') {
                if (rest[0] != '/') return repo.outside(given);
                rest = rest[1..];
            }
        }
        while (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];
        return files.gitName(into, rest) orelse repo.outside(given);
    }

    fn outside(repo: *const Repository, given: [*:0]const u8) ?[]const u8 {
        repo.git.say("%s is outside the repository\n", .{given});
        return null;
    }

    /// `<work tree>/<parts>`; null, said, when it is too long.
    pub fn workPath(repo: *const Repository, into: *files.Path, parts: []const []const u8) ?[*:0]const u8 {
        return files.child(into, repo.workText(), parts) orelse {
            repo.git.say("the path is too long\n", .{});
            return null;
        };
    }
};
