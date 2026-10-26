// SPDX-License-Identifier: MIT
//! `Git status [SHORT]`: where HEAD is, how its branch stands to the
//! branch it follows (ahead, behind, both), and what has changed - the
//! changes the next commit holds, those not staged for it, and the files
//! the index does not know. SHORT gives a line a path instead, two
//! letters before it: the staged change and the unstaged one (`A`, `M`,
//! `D`, or a space), `??` for an untracked one.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const refs = @import("refs.zig");
const revision = @import("revision.zig");
const history = @import("history.zig");
const changes_module = @import("changes.zig");
const config_module = @import("config.zig");
const log = @import("log.zig");
const context = @import("context.zig");
const Repository = @import("repo.zig").Repository;
const Git = context.Git;
const Id = _git.Id;
const Kind = changes_module.Kind;

pub const template = "SHORT=S/S";
const arg_short = 0;
pub const arg_count = 1;

/// A change noted, its path copied.
const Noted = struct {
    kind: Kind,
    path: []const u8,
};

/// Changes collected in order.
const List = struct {
    arena: *context.Arena,
    items: []Noted = &.{},
    count: usize = 0,
    failed: bool = false,

    fn add(list: *List, kind: Kind, path: []const u8) bool {
        if (list.count == list.items.len) {
            const size = if (list.items.len == 0) 64 else list.items.len * 2;
            const memory = list.arena.take(@sizeOf(Noted) * size, @alignOf(Noted)) orelse return list.fail();
            const grown = @as([*]Noted, @ptrCast(@alignCast(memory)))[0..size];
            @memcpy(grown[0..list.count], list.items[0..list.count]);
            list.items = grown;
        }
        const copied = list.arena.copy(path) orelse return list.fail();
        list.items[list.count] = .{ .kind = kind, .path = copied };
        list.count += 1;
        return true;
    }

    fn fail(list: *List) bool {
        list.failed = true;
        return false;
    }

    fn all(list: *const List) []const Noted {
        return list.items[0..list.count];
    }

    fn note(opaque_list: *anyopaque, kind: Kind, path: []const u8) bool {
        const list: *List = @ptrCast(@alignCast(opaque_list));
        return list.add(kind, path);
    }

    fn noteUntracked(opaque_list: *anyopaque, path: []const u8) bool {
        const list: *List = @ptrCast(@alignCast(opaque_list));
        return list.add(.added, path);
    }
};

pub fn run(git: *Git, argv: []const usize) i32 {
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    const short = argv[arg_short] != 0;
    var arena: context.Arena = .{ .sys = git.sys };
    defer arena.free();
    var head: refs.Head = .{};
    if (!refs.head(repo, &head)) {
        git.say("HEAD cannot be read\n", .{});
        return dos.RETURN_ERROR;
    }
    var head_tree: ?Id = null;
    if (head.id) |*id| head_tree = revision.treeOf(repo, id) orelse return dos.RETURN_ERROR;

    const changes = changes_module.Changes.open(repo) orelse return dos.RETURN_ERROR;
    defer changes.close();
    var staged: List = .{ .arena = &arena };
    var unstaged: List = .{ .arena = &arena };
    var untracked: List = .{ .arena = &arena };
    if (!changes.staged(if (head_tree) |*tree| tree else null, List.note, &staged)) return dos.RETURN_ERROR;
    if (!changes.unstaged(List.note, &unstaged)) return dos.RETURN_ERROR;
    if (!changes.untracked(List.noteUntracked, &untracked)) return dos.RETURN_ERROR;
    if (staged.failed or unstaged.failed or untracked.failed) {
        git.say("no memory\n", .{});
        return dos.RETURN_ERROR;
    }

    if (short) {
        showShort(git, staged.all(), unstaged.all(), untracked.all());
        return dos.RETURN_OK;
    }
    showHead(git, repo, &head);
    var sections: u32 = 0;
    if (staged.count != 0) {
        git.put("\nChanges to be committed:\n");
        for (staged.all()) |*noted| showChange(git, noted, true);
        sections += 1;
    }
    if (unstaged.count != 0) {
        git.put("\nChanges not staged for commit:\n");
        for (unstaged.all()) |*noted| showChange(git, noted, false);
        sections += 1;
    }
    if (untracked.count != 0) {
        git.put("\nUntracked files:\n");
        for (untracked.all()) |*noted| {
            git.put("\t");
            git.put(noted.path);
            git.put("\n");
        }
    }
    git.put("\n");
    if (staged.count == 0) {
        if (unstaged.count != 0) {
            git.put("no changes added to commit\n");
        } else if (untracked.count != 0) {
            git.put("nothing added to commit but untracked files present\n");
        } else {
            git.put("nothing to commit, working tree clean\n");
        }
    }
    return dos.RETURN_OK;
}

fn showChange(git: *Git, noted: *const Noted, staged: bool) void {
    git.put("\t");
    git.put(switch (noted.kind) {
        .added => if (staged) "new file:   " else "modified:   ",
        .modified => "modified:   ",
        .deleted => "deleted:    ",
    });
    git.put(noted.path);
    git.put("\n");
}

/// `XY path` a line, staged and unstaged merged by path; the untracked
/// after them.
fn showShort(git: *Git, staged: []const Noted, unstaged: []const Noted, untracked: []const Noted) void {
    var staged_at: usize = 0;
    var unstaged_at: usize = 0;
    while (staged_at < staged.len or unstaged_at < unstaged.len) {
        const order = if (staged_at == staged.len)
            .greater
        else if (unstaged_at == unstaged.len)
            .less
        else
            _git.order(staged[staged_at].path, unstaged[unstaged_at].path);
        var letters = [2]u8{ ' ', ' ' };
        var path: []const u8 = undefined;
        if (order != .greater) {
            letters[0] = staged[staged_at].kind.letter();
            path = staged[staged_at].path;
            staged_at += 1;
        }
        if (order != .less) {
            letters[1] = unstaged[unstaged_at].kind.letter();
            path = unstaged[unstaged_at].path;
            unstaged_at += 1;
        }
        git.put(&letters);
        git.put(" ");
        git.put(path);
        git.put("\n");
    }
    for (untracked) |*noted| {
        git.put("?? ");
        git.put(noted.path);
        git.put("\n");
    }
}

/// Where HEAD is, and how its branch stands to its upstream.
fn showHead(git: *Git, repo: *Repository, head: *const refs.Head) void {
    const branch = head.branch orelse {
        var hex: [40]u8 = undefined;
        _git.hexOf(&head.id.?, &hex);
        git.put("HEAD detached at ");
        git.put(hex[0..7]);
        git.put("\n");
        return;
    };
    const short = log.shortName(branch);
    git.put("On branch ");
    git.put(short);
    git.put("\n");
    const id = head.id orelse {
        git.put("\nNo commits yet\n");
        return;
    };
    var config: config_module.Config = undefined;
    config.read(repo, git);
    defer config.free();
    var remote_buffer: [refs.name_most + 1]u8 = undefined;
    var merge_buffer: [refs.name_most + 1]u8 = undefined;
    const remote = config.get("branch", short, "remote", &remote_buffer) orelse return;
    const merge = config.get("branch", short, "merge", &merge_buffer) orelse return;
    if (!_git.startsWith(merge, "refs/heads/")) return;
    var upstream: [refs.name_most + 1]u8 = undefined;
    var out: _git.Out = .{ .into = &upstream };
    out.put("refs/remotes/");
    out.put(remote);
    out.byte('/');
    out.put(merge["refs/heads/".len..]);
    if (out.overflow) return;
    const upstream_name = out.written()["refs/remotes/".len..];
    const upstream_id = refs.resolve(repo, out.written()) orelse {
        git.put("Your branch is based on '");
        git.put(upstream_name);
        git.put("', but the upstream is gone.\n");
        return;
    };
    const counts = history.compare(repo, &id, &upstream_id) orelse return;
    var number: [16]u8 = undefined;
    if (counts.ahead == 0 and counts.behind == 0) {
        git.put("Your branch is up to date with '");
        git.put(upstream_name);
        git.put("'.\n");
    } else if (counts.behind == 0) {
        git.put("Your branch is ahead of '");
        git.put(upstream_name);
        git.put("' by ");
        git.put(decimal(&number, counts.ahead));
        git.put(if (counts.ahead == 1) " commit.\n" else " commits.\n");
    } else if (counts.ahead == 0) {
        git.put("Your branch is behind '");
        git.put(upstream_name);
        git.put("' by ");
        git.put(decimal(&number, counts.behind));
        git.put(if (counts.behind == 1) " commit" else " commits");
        git.put(", and can be fast-forwarded.\n");
    } else {
        git.put("Your branch and '");
        git.put(upstream_name);
        git.put("' have diverged,\nand have ");
        git.put(decimal(&number, counts.ahead));
        git.put(" and ");
        var other: [16]u8 = undefined;
        git.put(decimal(&other, counts.behind));
        git.put(" different commits each, respectively.\n");
    }
}

fn decimal(into: *[16]u8, value: u32) []const u8 {
    var out: _git.Out = .{ .into = into };
    out.decimal(value);
    return out.written();
}
