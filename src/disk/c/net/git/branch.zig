// SPDX-License-Identifier: MIT
//! `Git branch [REMOTES] [ALL]`: the branches, a line each, the one
//! checked out marked with `*` - or, with HEAD detached, a line saying
//! where it is. REMOTES lists origin's branches instead, ALL both (the
//! remote ones as `remotes/origin/...`); a symbolic one shows what it
//! names.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const refs = @import("refs.zig");
const log = @import("log.zig");
const context = @import("context.zig");
const Repository = @import("repo.zig").Repository;
const Git = context.Git;

pub const template = "REMOTES=R/S,ALL=A/S";
const arg_remotes = 0;
const arg_all = 1;
pub const arg_count = 2;

pub fn run(git: *Git, argv: []const usize) i32 {
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    const all = argv[arg_all] != 0;
    const remotes = argv[arg_remotes] != 0 or all;
    const locals = argv[arg_remotes] == 0 or all;
    var arena: context.Arena = .{ .sys = git.sys };
    defer arena.free();
    var head: refs.Head = .{};
    _ = refs.head(repo, &head);

    if (locals) {
        if (head.branch == null) {
            if (head.id) |*id| {
                var hex: [40]u8 = undefined;
                _git.hexOf(id, &hex);
                git.put("* (HEAD detached at ");
                git.put(hex[0..7]);
                git.put(")\n");
            }
        }
        const branches = refs.list(repo, "refs/heads/", &arena) orelse return dos.RETURN_ERROR;
        for (branches) |*ref| {
            const current = if (head.branch) |branch| _git.same(branch, ref.name) else false;
            git.put(if (current) "* " else "  ");
            git.put(log.shortName(ref.name));
            git.put("\n");
        }
    }
    if (remotes) {
        const branches = refs.list(repo, "refs/remotes/", &arena) orelse return dos.RETURN_ERROR;
        for (branches) |*ref| {
            git.put("  ");
            if (all) git.put("remotes/");
            git.put(log.shortName(ref.name));
            if (ref.target) |target| {
                git.put(" -> ");
                git.put(log.shortName(target));
            }
            git.put("\n");
        }
    }
    return dos.RETURN_OK;
}
