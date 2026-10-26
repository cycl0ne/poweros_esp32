// SPDX-License-Identifier: MIT
//! `Git init [DIRECTORY]`: an empty repository made in DIRECTORY - made
//! too when it is not there - or in the current directory. Its `.git`
//! holds the store, the refs, the config of a dos volume's work tree
//! (repo.zig's `core_config`) and HEAD on the branch `init.defaultBranch`
//! of ENVARC:Sys/net/gitconfig names, `main` without it. A repository
//! there already is left as it is.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const config_module = @import("config.zig");
const repo_module = @import("repo.zig");
const Repository = repo_module.Repository;
const Git = @import("context.zig").Git;

pub const template = "DIRECTORY";
const arg_directory = 0;
pub const arg_count = 1;

pub fn run(git: *Git, argv: []const usize) i32 {
    const dl = git.dl;
    const given: [*:0]const u8 = if (argv[arg_directory] != 0) @ptrFromInt(argv[arg_directory]) else "";
    if (given[0] != 0) {
        if (dl.Lock(given, dos.SHARED_LOCK)) |there| {
            dl.UnLock(there);
        } else {
            var with_slash: files.Path = undefined;
            const path = files.join(&with_slash, &.{ files.span(given), "/" }) orelse {
                git.say("the path is too long\n", .{});
                return dos.RETURN_ERROR;
            };
            if (!files.makeDirs(git, path)) {
                _ = dl.PrintFault(dl.IoErr(), given);
                return dos.RETURN_ERROR;
            }
        }
    }
    const lock = dl.Lock(given, dos.SHARED_LOCK) orelse {
        _ = dl.PrintFault(dl.IoErr(), given);
        return dos.RETURN_ERROR;
    };
    var work: files.Path = undefined;
    const named = dl.NameFromLock(lock, &work, files.path_most);
    dl.UnLock(lock);
    if (!named) {
        _ = dl.PrintFault(dl.IoErr(), given);
        return dos.RETURN_ERROR;
    }
    const repo = Repository.open(git, files.span(@ptrCast(&work))) orelse return dos.RETURN_ERROR;
    defer repo.close();

    var head: files.Path = undefined;
    const head_name = repo.path(&head, &.{"HEAD"}) orelse return dos.RETURN_ERROR;
    if (dl.Lock(head_name, dos.SHARED_LOCK)) |held| {
        dl.UnLock(held);
        sayWhere(git, repo, "Reinitialized existing Git repository in ");
        return dos.RETURN_OK;
    }

    var config: config_module.Config = undefined;
    config.read(null, git);
    defer config.free();
    var value: [refs.name_most + 1]u8 = undefined;
    const short = config.get("init", null, "defaultBranch", value[0 .. value.len - 16]) orelse "main";
    var branch: [refs.name_most + 1]u8 = undefined;
    var out: _git.Out = .{ .into = &branch };
    out.put("refs/heads/");
    out.put(short);
    if (!repo.layOut(out.written())) return dos.RETURN_ERROR;
    if (!refs.writeFile(repo, "config", &.{repo_module.core_config})) return dos.RETURN_ERROR;
    sayWhere(git, repo, "Initialized empty Git repository in ");
    return dos.RETURN_OK;
}

fn sayWhere(git: *Git, repo: *const Repository, what: []const u8) void {
    if (git.quiet) return;
    git.put(what);
    git.put(repo.dirText());
    git.put("/\n");
}
