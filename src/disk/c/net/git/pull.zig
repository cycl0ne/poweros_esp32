// SPDX-License-Identifier: MIT
//! `Git pull [REMOTE] [QUIET]`: the branch HEAD is on brought up to the
//! branch it follows. Its upstream - `[branch "<name>"]` in
//! `.git/config`, `remote` and `merge` - is fetched as `Git fetch`
//! fetches; when the upstream's commit follows on from the branch's, the
//! branch is moved to it (a fast-forward), and the work tree and the
//! index with it as `Git checkout` moves them: a change made here is
//! kept where the upstream does not touch its path, and refused where it
//! would be lost, and then nothing is changed. A branch with commits of
//! its own that the upstream has not is left as it is: pull only moves a
//! branch forward.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const revision = @import("revision.zig");
const history = @import("history.zig");
const worktree = @import("worktree.zig");
const fetch = @import("fetch.zig");
const config_module = @import("config.zig");
const log = @import("log.zig");
const Repository = @import("repo.zig").Repository;
const Git = @import("context.zig").Git;
const Id = _git.Id;

pub const template = "REMOTE,QUIET/S";
const arg_remote = 0;
const arg_quiet = 1;
pub const arg_count = 2;

pub fn run(git: *Git, argv: []const usize) i32 {
    git.quiet = argv[arg_quiet] != 0;
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    var head: refs.Head = .{};
    if (!refs.head(repo, &head)) {
        git.say("HEAD cannot be read\n", .{});
        return dos.RETURN_ERROR;
    }
    const branch = head.branch orelse {
        git.say("HEAD is on no branch: pull brings a branch up to date\n", .{});
        return dos.RETURN_ERROR;
    };
    const short = log.shortName(branch);

    // The upstream: the remote, and its branch.
    var remote_buffer: [refs.name_most + 1]u8 = undefined;
    var merge_buffer: [refs.name_most + 1]u8 = undefined;
    var remote: []const u8 = "origin";
    var merge: []const u8 = undefined;
    {
        var config: config_module.Config = undefined;
        config.read(repo, git);
        defer config.free();
        merge = config.get("branch", short, "merge", &merge_buffer) orelse {
            git.say("the branch ", .{});
            git.put(short);
            git.put(" follows no branch: .git/config has no merge for it\n");
            return dos.RETURN_ERROR;
        };
        if (config.get("branch", short, "remote", &remote_buffer)) |name| remote = name;
    }
    if (argv[arg_remote] != 0) remote = files.span(@ptrFromInt(argv[arg_remote]));

    const fetching = fetch.start(repo, remote, 0) orelse return dos.RETURN_ERROR;
    defer fetch.finish(fetching);
    fetching.upstream = merge;
    if (!fetching.fetchAll()) return dos.RETURN_ERROR;
    const listed = fetching.listedId(merge) orelse {
        git.say("the remote has no branch ", .{});
        git.put(merge);
        git.put("\n");
        return dos.RETURN_ERROR;
    };
    const upstream = revision.commitOf(repo, &listed) orelse return dos.RETURN_ERROR;
    const new_tree = revision.treeOf(repo, &upstream) orelse return dos.RETURN_ERROR;

    const current = head.id orelse {
        // A branch without a commit yet: the upstream checked out.
        if (!worktree.switchTrees(repo, null, &new_tree)) return dos.RETURN_ERROR;
        return if (refs.write(repo, branch, &upstream)) dos.RETURN_OK else dos.RETURN_ERROR;
    };
    if (_git.same(&current, &upstream) or (history.isAncestor(repo, &upstream, &current) orelse return dos.RETURN_ERROR)) {
        if (!git.quiet) git.put("Already up to date.\n");
        return dos.RETURN_OK;
    }
    if (!(history.isAncestor(repo, &current, &upstream) orelse return dos.RETURN_ERROR)) {
        git.say("the branch and its upstream have diverged: pull only moves a branch forward, so nothing was changed\n", .{});
        return dos.RETURN_ERROR;
    }
    const old_tree = revision.treeOf(repo, &current) orelse return dos.RETURN_ERROR;
    if (!git.quiet) {
        var range: [7 + 2 + 7]u8 = undefined;
        var hex: [40]u8 = undefined;
        _git.hexOf(&current, &hex);
        @memcpy(range[0..7], hex[0..7]);
        @memcpy(range[7..9], "..");
        _git.hexOf(&upstream, &hex);
        @memcpy(range[9..16], hex[0..7]);
        git.put("Updating ");
        git.put(&range);
        git.put("\n");
    }
    if (!_git.same(&old_tree, &new_tree)) {
        if (!worktree.switchTrees(repo, &old_tree, &new_tree)) return dos.RETURN_ERROR;
    }
    if (!refs.write(repo, branch, &upstream)) return dos.RETURN_ERROR;
    if (!git.quiet) git.put("Fast-forward\n");
    return dos.RETURN_OK;
}
