// SPDX-License-Identifier: MIT
//! What a name typed for an object stands for: a whole id; a ref by
//! git's rules (`main`, `v1`, `origin/main`, `HEAD`); or the start of an
//! id, four hex digits or more, that one object's id starts with. And
//! the commit a name stands for - a tag's peeled - and its tree.

const _git = @import("_git.zig");
const object = @import("object.zig");
const refs = @import("refs.zig");
const Repository = @import("repo.zig").Repository;
const Id = _git.Id;

/// The object `text` names: null, said, when it names none, or more
/// than one.
pub fn lookUp(repo: *Repository, text: [*:0]const u8) ?Id {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    const name = text[0..length];
    if (refs.expand(repo, name, null)) |id| return id;
    switch (repo.objects.findPrefix(name)) {
        .one => |id| return id,
        .many => repo.git.say("%s is the start of more than one object's id\n", .{text}),
        .none => repo.git.say("%s names no object or ref\n", .{text}),
    }
    return null;
}

/// How many tags a tag may name before a commit.
const peel_most = 8;

/// The commit `id` names: itself, or what its tags name.
pub fn commitOf(repo: *Repository, id: *const Id) ?Id {
    const git = repo.git;
    var current = id.*;
    for (0..peel_most) |_| {
        var found = repo.objects.read(&current) orelse {
            git.say("the repository does not have the object named\n", .{});
            return null;
        };
        defer found.free(git.sys);
        switch (found.kind) {
            .commit => return current,
            .tag => {
                const tag = object.parseTag(found.data) orelse {
                    git.say("a tag is broken\n", .{});
                    return null;
                };
                current = tag.object;
            },
            else => {
                git.say("the name names no commit\n", .{});
                return null;
            },
        }
    }
    git.say("the tags name one another too deep\n", .{});
    return null;
}

/// The tree of the commit `id`.
pub fn treeOf(repo: *Repository, id: *const Id) ?Id {
    const git = repo.git;
    var found = repo.objects.read(id) orelse {
        git.say("the repository does not have a commit it names\n", .{});
        return null;
    };
    defer found.free(git.sys);
    if (found.kind != .commit) {
        git.say("a commit is no commit\n", .{});
        return null;
    }
    const commit = object.parseCommit(found.data) orelse {
        git.say("a commit is broken\n", .{});
        return null;
    };
    return commit.tree;
}

/// What a tree holds at a path.
pub const Held = struct { mode: u32, id: Id };

/// What the tree `tree` holds at `path` (`a/b.txt`): null when it holds
/// nothing there, or a tree on the way cannot be read.
pub fn heldAt(repo: *Repository, tree: *const Id, path: []const u8) ?Held {
    const sys = repo.git.sys;
    var current = tree.*;
    var rest = path;
    while (true) {
        var end: usize = 0;
        while (end < rest.len and rest[end] != '/') end += 1;
        const name = rest[0..end];
        var found = repo.objects.read(&current) orelse return null;
        defer found.free(sys);
        if (found.kind != .tree) return null;
        var entries: object.TreeEntries = .{ .body = found.data };
        const entry = while (entries.next()) |each| {
            if (_git.same(each.name, name)) break each;
        } else return null;
        if (end == rest.len) return .{ .mode = entry.mode, .id = entry.id };
        if (!entry.isTree()) return null;
        current = entry.id;
        rest = rest[end + 1 ..];
    }
}
