// SPDX-License-Identifier: MIT
//! `Git remote [VERBOSE]`, `Git remote add NAME URL`, `Git remote remove
//! NAME`: the remotes of `.git/config` listed - with VERBOSE their URLs -
//! one added, or one taken out.
//!
//! A remote added is a `[remote "NAME"]` section at the config's end,
//! its URL and a fetch refspec taking every branch there to
//! `refs/remotes/NAME/`. A remote taken out loses its section, the
//! branches that followed it lose their `remote` and `merge`, and its
//! refs here go: the directory `refs/remotes/NAME` and their lines in
//! `packed-refs`.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const config_module = @import("config.zig");
const Repository = @import("repo.zig").Repository;
const Git = @import("context.zig").Git;

pub const template = "ACTION,NAME,URL,VERBOSE=V/S";
const arg_action = 0;
const arg_name = 1;
const arg_url = 2;
const arg_verbose = 3;
pub const arg_count = 4;

const url_most = 2048;
const names_most = 64;
const packed_most = 64 * 1024 * 1024;

pub fn run(git: *Git, argv: []const usize) i32 {
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    const action: []const u8 = if (argv[arg_action] != 0) files.span(@ptrFromInt(argv[arg_action])) else "";
    const name: ?[]const u8 = if (argv[arg_name] != 0) files.span(@ptrFromInt(argv[arg_name])) else null;
    if (action.len == 0) return list(repo, argv[arg_verbose] != 0);
    if (sameWord(action, "add")) {
        const url: []const u8 = if (argv[arg_url] != 0) files.span(@ptrFromInt(argv[arg_url])) else "";
        if (name == null or url.len == 0) {
            git.say("add takes a name and a URL: Git remote add origin https://host/path\n", .{});
            return dos.RETURN_ERROR;
        }
        return add(repo, name.?, url);
    }
    if (sameWord(action, "remove") or sameWord(action, "rm")) {
        if (name == null) {
            git.say("remove takes the remote's name\n", .{});
            return dos.RETURN_ERROR;
        }
        return remove(repo, name.?);
    }
    git.say("", .{});
    git.put(action);
    git.put(" is no action of remote: add or remove, or none to list them\n");
    return dos.RETURN_ERROR;
}

/// The names, each once, in the order the config has them.
const Names = struct {
    git: *Git,
    names: [names_most][]const u8 = undefined,
    count: usize = 0,

    fn take(context: *anyopaque, name: []const u8) bool {
        const names: *Names = @ptrCast(@alignCast(context));
        for (names.names[0..names.count]) |seen| {
            if (_git.same(seen, name)) return true;
        }
        if (names.count == names.names.len) return false;
        names.names[names.count] = name;
        names.count += 1;
        return true;
    }
};

fn list(repo: *Repository, verbose: bool) i32 {
    const git = repo.git;
    var config: config_module.Config = undefined;
    config.read(repo, git);
    defer config.free();
    var names: Names = .{ .git = git };
    config.subsections("remote", Names.take, &names);
    for (names.names[0..names.count]) |name| {
        if (!verbose) {
            git.put(name);
            git.put("\n");
            continue;
        }
        var url_value: [url_most]u8 = undefined;
        const url = config.get("remote", name, "url", &url_value) orelse "";
        for ([_][]const u8{ " (fetch)\n", " (push)\n" }) |use| {
            git.put(name);
            git.put("\t");
            git.put(url);
            git.put(use);
        }
    }
    return dos.RETURN_OK;
}

fn add(repo: *Repository, name: []const u8, url: []const u8) i32 {
    const git = repo.git;
    if (!validName(name)) {
        git.say("", .{});
        git.put(name);
        git.put(" is no name for a remote: letters, digits, - _ and . only\n");
        return dos.RETURN_ERROR;
    }
    {
        var config: config_module.Config = undefined;
        config.read(repo, git);
        defer config.free();
        var value: [url_most]u8 = undefined;
        if (config.get("remote", name, "url", &value) != null) {
            git.say("there is a remote ", .{});
            git.put(name);
            git.put(" already\n");
            return dos.RETURN_ERROR;
        }
    }
    const size = 3 * name.len + 2 * url.len + 96;
    const memory = git.alloc(size) orelse return dos.RETURN_ERROR;
    defer git.free(memory);
    var out: _git.Out = .{ .into = memory[0..size] };
    out.put("[remote \"");
    out.put(name);
    out.put("\"]\n\turl = ");
    config_module.putValue(&out, url);
    out.put("\n\tfetch = +refs/heads/*:refs/remotes/");
    out.put(name);
    out.put("/*\n");
    if (!config_module.edit(repo, "remote", name, &.{}, out.written())) return dos.RETURN_ERROR;
    return dos.RETURN_OK;
}

fn remove(repo: *Repository, name: []const u8) i32 {
    const git = repo.git;
    var config: config_module.Config = undefined;
    config.read(repo, git);
    defer config.free();
    var value: [url_most]u8 = undefined;
    if (config.get("remote", name, "url", &value) == null) {
        git.say("there is no remote ", .{});
        git.put(name);
        git.put(" in .git/config\n");
        return dos.RETURN_ERROR;
    }
    if (!config_module.edit(repo, "remote", name, &.{}, "")) return dos.RETURN_ERROR;
    // The branches that followed it.
    var branches: Names = .{ .git = git };
    config.subsections("branch", Names.take, &branches);
    for (branches.names[0..branches.count]) |branch| {
        var remote_value: [url_most]u8 = undefined;
        const followed = config.get("branch", branch, "remote", &remote_value) orelse continue;
        if (!_git.same(followed, name)) continue;
        if (!config_module.edit(repo, "branch", branch, &.{ "remote", "merge" }, "")) return dos.RETURN_ERROR;
    }
    // Its refs here.
    var path: files.Path = undefined;
    if (repo.path(&path, &.{ "refs/remotes/", name })) |directory| {
        if (git.dl.Lock(directory, dos.SHARED_LOCK)) |lock| {
            git.dl.UnLock(lock);
            if (!files.removeTree(git, directory, false)) {
                _ = git.dl.PrintFault(git.dl.IoErr(), directory);
                return dos.RETURN_ERROR;
            }
        }
    }
    if (!dropPacked(repo, name)) return dos.RETURN_ERROR;
    return dos.RETURN_OK;
}

/// The lines of `packed-refs` naming a ref under `refs/remotes/<name>/`
/// taken out, with the peeled lines after them.
fn dropPacked(repo: *Repository, name: []const u8) bool {
    const git = repo.git;
    var path: files.Path = undefined;
    const file_name = repo.path(&path, &.{"packed-refs"}) orelse return false;
    const text = files.readWhole(git, file_name, packed_most) orelse return true;
    defer git.free(text.ptr);
    const memory = git.alloc(text.len + 1) orelse return false;
    defer git.free(memory);
    var prefix_buffer: [refs.name_most + 1]u8 = undefined;
    var prefix: _git.Out = .{ .into = &prefix_buffer };
    prefix.put("refs/remotes/");
    prefix.put(name);
    prefix.byte('/');
    var length: usize = 0;
    var dropped = false;
    var dropping = false;
    var lines: refs.Lines = .{ .text = text };
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] == '^') {
            if (dropping) continue;
        } else {
            dropping = line.len > 41 and line[40] == ' ' and _git.startsWith(line[41..], prefix.written());
            if (dropping) {
                dropped = true;
                continue;
            }
        }
        @memcpy(memory[length..][0..line.len], line);
        length += line.len;
        memory[length] = '\n';
        length += 1;
    }
    if (!dropped) return true;
    return refs.writeFile(repo, "packed-refs", &.{memory[0..length]});
}

/// A remote's name: what a ref's part may be, and nothing a dos path
/// would read otherwise.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.' or name[0] == '-') return false;
    for (name) |char| {
        const fits = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or (char >= '0' and char <= '9') or char == '-' or char == '_' or char == '.';
        if (!fits) return false;
    }
    return !_git.endsWith(name, ".lock");
}

fn sameWord(given: []const u8, word: []const u8) bool {
    if (given.len != word.len) return false;
    for (given, word) |a, b| {
        const lower = if (a >= 'A' and a <= 'Z') a + 32 else a;
        if (lower != b) return false;
    }
    return true;
}
