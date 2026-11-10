// SPDX-License-Identifier: MIT
//! `Git diff [CACHED]`: the paths that changed, a line each - `M`, `A`
//! or `D`, a tab, the path. Without CACHED the work tree against the
//! index (what is not staged), with it the index against HEAD's tree
//! (what the next commit holds).

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const refs = @import("refs.zig");
const revision = @import("revision.zig");
const changes_module = @import("changes.zig");
const Repository = @import("repo.zig").Repository;
const Git = @import("context.zig").Git;
const Id = _git.Id;
const Kind = changes_module.Kind;

pub const template = "CACHED=STAGED/S";
const arg_cached = 0;
pub const arg_count = 1;

pub fn run(git: *Git, argv: []const usize) i32 {
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    const changes = changes_module.Changes.open(repo) orelse return dos.RETURN_ERROR;
    defer changes.close();
    if (argv[arg_cached] != 0) {
        var head: refs.Head = .{};
        if (!refs.head(repo, &head)) {
            git.say("HEAD cannot be read\n", .{});
            return dos.RETURN_ERROR;
        }
        var head_tree: ?Id = null;
        if (head.id) |*id| head_tree = revision.treeOf(repo, id) orelse return dos.RETURN_ERROR;
        if (!changes.staged(if (head_tree) |*tree| tree else null, show, git)) return dos.RETURN_ERROR;
    } else {
        if (!changes.unstaged(show, git)) return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

fn show(opaque_git: *anyopaque, kind: Kind, path: []const u8) bool {
    const git: *Git = @ptrCast(@alignCast(opaque_git));
    const line = [2]u8{ kind.letter(), '\t' };
    git.put(&line);
    git.put(path);
    git.put("\n");
    return !git.stopped();
}
