// SPDX-License-Identifier: MIT
//! `Git checkout NAME`: the work tree, the index and HEAD moved to
//! another branch or commit. NAME is a branch; or one of origin's
//! branches not made here yet, which is then made, following it; or any
//! commit - an id, a tag - at which HEAD is then detached. A change made
//! in the work tree or the index is carried over where the new commit
//! does not touch that path, and refused where it would be lost (see
//! worktree.zig); then nothing is changed.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const object = @import("object.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const revision = @import("revision.zig");
const worktree = @import("worktree.zig");
const Repository = @import("repo.zig").Repository;
const Git = @import("context.zig").Git;
const Id = _git.Id;

pub const template = "NAME/A";
const arg_name = 0;
pub const arg_count = 1;

const config_most = 1024 * 1024;

pub fn run(git: *Git, argv: []const usize) i32 {
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    const name_text: [*:0]const u8 = @ptrFromInt(argv[arg_name]);
    const name = files.span(name_text);
    var head: refs.Head = .{};
    if (!refs.head(repo, &head)) {
        git.say("HEAD cannot be read\n", .{});
        return dos.RETURN_ERROR;
    }

    // A branch here, one of origin's, or a commit.
    var branch: [refs.name_most + 1]u8 = undefined;
    var branch_out: _git.Out = .{ .into = &branch };
    branch_out.put("refs/heads/");
    branch_out.put(name);
    var remote: [refs.name_most + 1]u8 = undefined;
    var remote_out: _git.Out = .{ .into = &remote };
    remote_out.put("refs/remotes/origin/");
    remote_out.put(name);
    var target: Id = undefined;
    var new_branch = false;
    var detached = false;
    if (!branch_out.overflow and refs.resolve(repo, branch_out.written()) != null) {
        target = refs.resolve(repo, branch_out.written()).?;
    } else if (!remote_out.overflow and refs.resolve(repo, remote_out.written()) != null) {
        target = refs.resolve(repo, remote_out.written()).?;
        new_branch = true;
    } else {
        target = revision.lookUp(repo, name_text) orelse return dos.RETURN_ERROR;
        detached = true;
    }
    const commit = revision.commitOf(repo, &target) orelse return dos.RETURN_ERROR;
    const new_tree = revision.treeOf(repo, &commit) orelse return dos.RETURN_ERROR;

    if (!detached and !new_branch) {
        if (head.branch) |current| {
            if (_git.same(current, branch_out.written())) {
                git.say("already on %s\n", .{name_text});
                return dos.RETURN_OK;
            }
        }
    }
    var old_tree: ?Id = null;
    if (head.id) |*id| old_tree = revision.treeOf(repo, id) orelse return dos.RETURN_ERROR;
    const unchanged = if (old_tree) |*tree| _git.same(tree, &new_tree) else false;
    if (!unchanged) {
        if (!worktree.switchTrees(repo, if (old_tree) |*tree| tree else null, &new_tree)) return dos.RETURN_ERROR;
    }

    if (detached) {
        if (!refs.write(repo, "HEAD", &commit)) return dos.RETURN_ERROR;
        sayAt(repo, &commit);
        return dos.RETURN_OK;
    }
    if (new_branch) {
        if (!refs.write(repo, branch_out.written(), &commit)) return dos.RETURN_ERROR;
        if (!follow(repo, name)) return dos.RETURN_ERROR;
    }
    if (!refs.writeSymbolic(repo, "HEAD", branch_out.written())) return dos.RETURN_ERROR;
    if (new_branch) {
        git.say("switched to a new branch %s, following origin/%s\n", .{ name_text, name_text });
    } else {
        git.say("switched to branch %s\n", .{name_text});
    }
    return dos.RETURN_OK;
}

/// `HEAD is now at <id> <subject>`.
fn sayAt(repo: *Repository, id: *const Id) void {
    const git = repo.git;
    var hex: [41]u8 = undefined;
    _git.hexOf(id, hex[0..40]);
    hex[7] = 0;
    git.say("HEAD is now at %s ", .{@as([*:0]const u8, @ptrCast(&hex))});
    var found = repo.objects.read(id) orelse return;
    defer found.free(git.sys);
    if (object.parseCommit(found.data)) |commit| git.put(commit.subject());
    git.put("\n");
}

/// `[branch "<name>"]` added to `.git/config`, following origin's
/// branch of the same name.
fn follow(repo: *Repository, name: []const u8) bool {
    const git = repo.git;
    var path: files.Path = undefined;
    const config_name = repo.path(&path, &.{"config"}) orelse return false;
    const old = files.readWhole(git, config_name, config_most) orelse {
        _ = git.dl.PrintFault(git.dl.IoErr(), config_name);
        return false;
    };
    defer git.free(old.ptr);
    const line_end: []const u8 = if (old.len != 0 and old[old.len - 1] != '\n') "\n" else "";
    return refs.writeFile(repo, "config", &.{ old, line_end, "[branch \"", name, "\"]\n\tremote = origin\n\tmerge = refs/heads/", name, "\n" });
}
