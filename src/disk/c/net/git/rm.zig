// SPDX-License-Identifier: MIT
//! `Git rm PATHS/M/A [CACHED] [RECURSIVE] [FORCE]`: files taken out of
//! the index, so the next commit has them no more, and out of the work
//! tree unless CACHED - the directories they leave empty with them. A
//! directory needs RECURSIVE. A file whose change would be lost is
//! refused: one that differs from its entry, or whose entry differs from
//! HEAD's; with CACHED, the file staying, only one that differs both
//! ways. FORCE takes it out all the same.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const object = @import("object.zig");
const index = @import("index.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const revision = @import("revision.zig");
const worktree = @import("worktree.zig");
const staging_module = @import("staging.zig");
const Repository = @import("repo.zig").Repository;
const Git = @import("context.zig").Git;
const Id = _git.Id;

pub const template = "PATHS/M/A,CACHED/S,RECURSIVE=R/S,FORCE/S";
const arg_paths = 0;
const arg_cached = 1;
const arg_recursive = 2;
const arg_force = 3;
pub const arg_count = 4;

const Removing = struct {
    repo: *Repository,
    git: *Git,
    staging: staging_module.Staging,
    work: worktree.Work,
    head_tree: ?Id,
    cached: bool,
    force: bool,
    refused: u32 = 0,
};

pub fn run(git: *Git, argv: []const usize) i32 {
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    var head: refs.Head = .{};
    if (!refs.head(repo, &head)) {
        git.say("HEAD cannot be read\n", .{});
        return dos.RETURN_ERROR;
    }
    const removing = git.create(Removing) orelse return dos.RETURN_ERROR;
    defer git.free(removing);
    removing.* = .{
        .repo = repo,
        .git = git,
        .staging = undefined,
        .work = undefined,
        .head_tree = null,
        .cached = argv[arg_cached] != 0,
        .force = argv[arg_force] != 0,
    };
    if (head.id) |*id| removing.head_tree = revision.treeOf(repo, id) orelse return dos.RETURN_ERROR;
    removing.work.init(repo);
    defer removing.work.deinit();
    if (!removing.staging.open(repo)) return dos.RETURN_ERROR;
    defer removing.staging.close();
    removing.work.index_seconds = removing.staging.file.seconds;

    for (dos.rdargs.multi(argv[arg_paths])) |given| {
        var into: files.Path = undefined;
        const path = repo.gitPath(given, &into) orelse return dos.RETURN_ERROR;
        if (!removePath(removing, path, argv[arg_recursive] != 0)) return dos.RETURN_ERROR;
    }
    if (removing.staging.changed and !removing.staging.write()) return dos.RETURN_ERROR;
    return if (removing.refused != 0) dos.RETURN_WARN else dos.RETURN_OK;
}

/// `path`'s entries taken out, a file or, with `recursive`, a
/// directory's.
fn removePath(removing: *Removing, path: []const u8, recursive: bool) bool {
    const git = removing.git;
    const staging = &removing.staging;
    var start: usize = 0;
    var end: usize = 0;
    if (staging.find(path) != null) {
        start = staging.lowerBound(path);
        end = start + 1;
    } else {
        var prefix: files.Path = undefined;
        var prefix_text: []const u8 = "";
        if (path.len != 0) {
            if (path.len + 1 > files.path_most) return true;
            @memcpy(prefix[0..path.len], path);
            prefix[path.len] = '/';
            prefix_text = prefix[0 .. path.len + 1];
        }
        const range = staging.below(prefix_text);
        start = range.start;
        end = range.end;
        if (end == start) {
            say(git, path, " is in no entry of the index - not removed\n");
            removing.refused += 1;
            return true;
        }
        if (!recursive) {
            say(git, path, " is a directory - RECURSIVE removes it\n");
            removing.refused += 1;
            return true;
        }
    }
    // Every file is checked before any is taken out.
    if (!removing.force) {
        var refused = false;
        for (staging.entries[start..end]) |*entry| {
            if (!safe(removing, entry)) refused = true;
        }
        if (refused) {
            removing.refused += 1;
            return true;
        }
    }
    const dl = git.dl;
    var local_path: files.Path = undefined;
    for (staging.entries[start..end]) |*entry| {
        if (!git.quiet) {
            git.endProgress();
            git.put("rm '");
            git.put(entry.path);
            git.put("'\n");
        }
        if (removing.cached or entry.skip_worktree) continue;
        const local = removing.work.localPath(&local_path, entry.path) orelse continue;
        if (entry.mode == object.mode_gitlink) {
            _ = dl.DeleteFile(local);
            continue;
        }
        if (!dl.DeleteFile(local) and dl.IoErr() != dos.ERROR_OBJECT_NOT_FOUND) {
            _ = dl.PrintFault(dl.IoErr(), local);
        }
    }
    if (!removing.cached) {
        for (staging.entries[start..end]) |*entry| worktree.removeEmptyParents(&removing.work, entry.path);
    }
    staging.removeRange(start, end);
    return true;
}

/// Whether `entry` may go: no change of it is lost.
fn safe(removing: *Removing, entry: *const index.Entry) bool {
    const git = removing.git;
    const staged = if (removing.head_tree) |*tree| blk: {
        const held = revision.heldAt(removing.repo, tree, entry.path) orelse break :blk true;
        break :blk held.mode != worktree.normalMode(entry.mode) or !_git.same(&held.id, &entry.id);
    } else true;
    var local_path: files.Path = undefined;
    const changed = if (entry.skip_worktree) false else if (removing.work.localPath(&local_path, entry.path)) |local|
        removing.work.stateOf(entry, local) == .changed
    else
        false;
    if (removing.cached) {
        if (staged and changed) {
            say(git, entry.path, " differs from both HEAD and its entry - not removed (FORCE removes it)\n");
            return false;
        }
        return true;
    }
    if (staged) {
        say(git, entry.path, " has a change in the index - not removed (CACHED keeps the file, FORCE removes it)\n");
        return false;
    }
    if (changed) {
        say(git, entry.path, " has been changed - not removed (CACHED keeps the file, FORCE removes it)\n");
        return false;
    }
    return true;
}

fn say(git: *Git, path: []const u8, what: []const u8) void {
    git.endProgress();
    git.put("Git: ");
    git.put(path);
    git.put(what);
}
