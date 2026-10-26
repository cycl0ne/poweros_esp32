// SPDX-License-Identifier: MIT
//! `Git commit MESSAGE=M/K [ALL]`: what the index holds made a commit on
//! the branch HEAD is on (or on HEAD itself, detached), the commit HEAD
//! was at its parent. ALL first puts every file the index knows in as
//! it is now, and takes out those gone, as `Git add` does - new files
//! are not taken.
//!
//! The index is made trees from its end up: its entries come sorted as
//! a tree sorts its own, so a directory's entries are together, and a
//! directory's tree is written - its id going into its parent's - once
//! the entries leave it. The commit names its author and committer as
//! `[user]` in `.git/config` or ENVARC:Sys/net/gitconfig names them,
//! with the time now and the offset of the zone in
//! ENVARC:Sys/timezone. The message is MESSAGE, its blank lines at
//! either end taken off.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const object = @import("object.zig");
const index = @import("index.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const revision = @import("revision.zig");
const loose = @import("loose.zig");
const add = @import("add.zig");
const changes_module = @import("changes.zig");
const config_module = @import("config.zig");
const log = @import("log.zig");
const context = @import("context.zig");
const Repository = @import("repo.zig").Repository;
const Git = context.Git;
const Id = _git.Id;

pub const template = "MESSAGE=M/A/K,ALL=A/S";
const arg_message = 0;
const arg_all = 1;
pub const arg_count = 2;

/// How deep the trees go.
const depth_most = 64;
const identity_most = 256;

pub fn run(git: *Git, argv: []const usize) i32 {
    const dl = git.dl;
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    const message = trimMessage(files.span(@ptrFromInt(argv[arg_message])));
    if (message.len == 0) {
        git.say("the message is empty - nothing committed\n", .{});
        return dos.RETURN_ERROR;
    }

    // Who commits.
    var name_buffer: [identity_most]u8 = undefined;
    var email_buffer: [identity_most]u8 = undefined;
    var name: []const u8 = undefined;
    var email: []const u8 = undefined;
    {
        var config: config_module.Config = undefined;
        config.read(repo, git);
        defer config.free();
        name = config.get("user", null, "name", &name_buffer) orelse "";
        email = config.get("user", null, "email", &email_buffer) orelse "";
    }
    if (name.len == 0 or email.len == 0) {
        git.say("who commits is not known: give name and email under [user] in ENVARC:Sys/net/gitconfig:\n", .{});
        git.put("  [user]\n  \tname = Your Name\n  \temail = you@example.org\n");
        return dos.RETURN_ERROR;
    }

    // The index, with ALL's changes.
    const adding = add.Adding.open(repo) orelse return dos.RETURN_ERROR;
    defer adding.close();
    if (argv[arg_all] != 0) {
        if (!adding.updateTracked("")) return dos.RETURN_ERROR;
        if (!adding.finish()) return dos.RETURN_ERROR;
        adding.staging.changed = false;
    }
    const entries = adding.staging.all();
    for (entries) |*entry| {
        if (entry.stage != 0) {
            git.say("", .{});
            git.put(entry.path);
            git.put(" is unmerged - nothing committed\n");
            return dos.RETURN_ERROR;
        }
    }

    var head: refs.Head = .{};
    if (!refs.head(repo, &head)) {
        git.say("HEAD cannot be read\n", .{});
        return dos.RETURN_ERROR;
    }
    var head_tree: ?Id = null;
    if (head.id) |*id| head_tree = revision.treeOf(repo, id) orelse return dos.RETURN_ERROR;
    if (entries.len == 0 and head.id == null) {
        git.say("nothing to commit: the index is empty (Git add puts files in)\n", .{});
        return dos.RETURN_WARN;
    }
    const builder = git.create(TreeBuilder) orelse return dos.RETURN_ERROR;
    defer git.free(builder);
    builder.* = .{ .repo = repo, .git = git, .arena = .{ .sys = git.sys } };
    defer builder.arena.free();
    const tree = builder.build(entries) orelse return dos.RETURN_ERROR;
    if (head_tree) |*held| {
        if (_git.same(held, &tree)) {
            git.say("nothing to commit: the index is as HEAD is (Git add puts changes in)\n", .{});
            return dos.RETURN_WARN;
        }
    }
    const changed = countChanges(repo, if (head_tree) |*held| held else null) orelse return dos.RETURN_ERROR;

    // The commit.
    var stamp: dos.DateStamp = undefined;
    _ = dl.DateStamp(&stamp);
    const seconds = git.unixTime(stamp).seconds;
    const offset = if (git.zone) |*zone| zone.offsetAt(seconds) else 0;
    var signature_buffer: [2 * identity_most + 64]u8 = undefined;
    const signature = signatureText(&signature_buffer, name, email, seconds, offset);
    var head_lines: [2 * 48 + 2]u8 = undefined;
    var lines: _git.Out = .{ .into = &head_lines };
    lines.put("tree ");
    lines.hex(&tree);
    lines.byte('\n');
    if (head.id) |*parent| {
        lines.put("parent ");
        lines.hex(parent);
        lines.byte('\n');
    }
    const body_length = lines.at + 2 * (signature.len + 12) + 1 + message.len + 1;
    const body = builder.arena.take(body_length, 1) orelse {
        git.say("no memory\n", .{});
        return dos.RETURN_ERROR;
    };
    var out: _git.Out = .{ .into = body[0..body_length] };
    out.put(lines.written());
    out.put("author ");
    out.put(signature);
    out.put("\ncommitter ");
    out.put(signature);
    out.put("\n\n");
    out.put(message);
    out.byte('\n');
    const id = loose.writeBytes(repo, .commit, out.written()) orelse return dos.RETURN_ERROR;
    if (!refs.write(repo, head.branch orelse "HEAD", &id)) return dos.RETURN_ERROR;

    // `[main 1a2b3c4] subject`, and how many files changed.
    if (!git.quiet) {
        var hex: [40]u8 = undefined;
        _git.hexOf(&id, &hex);
        git.put("[");
        git.put(if (head.branch) |branch| log.shortName(branch) else "detached HEAD");
        if (head.id == null) git.put(" (root-commit)");
        git.put(" ");
        git.put(hex[0..7]);
        git.put("] ");
        var subject_end: usize = 0;
        while (subject_end < message.len and message[subject_end] != '\n') subject_end += 1;
        git.put(message[0..subject_end]);
        var number: [24]u8 = undefined;
        var count: _git.Out = .{ .into = &number };
        count.put("\n ");
        count.decimal(changed);
        git.put(count.written());
        git.put(if (changed == 1) " file changed\n" else " files changed\n");
    }
    return dos.RETURN_OK;
}

/// The message without the blank lines and spaces at its ends.
fn trimMessage(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (end > 0 and isBlank(text[end - 1])) end -= 1;
    while (start < end and isBlank(text[start])) start += 1;
    return text[start..end];
}

fn isBlank(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r';
}

/// `Name <email> 1761403600 +0100`.
fn signatureText(into: []u8, name: []const u8, email: []const u8, seconds: i64, offset: i32) []const u8 {
    var out: _git.Out = .{ .into = into };
    out.put(name);
    out.put(" <");
    out.put(email);
    out.put("> ");
    out.decimal(@intCast(@max(seconds, 0)));
    out.put(if (offset < 0) " -" else " +");
    const minutes: u32 = @intCast(@divTrunc(if (offset < 0) -offset else offset, 60));
    const hours = minutes / 60;
    const rest = minutes % 60;
    out.byte('0' + @as(u8, @intCast(hours / 10)));
    out.byte('0' + @as(u8, @intCast(hours % 10)));
    out.byte('0' + @as(u8, @intCast(rest / 10)));
    out.byte('0' + @as(u8, @intCast(rest % 10)));
    return out.written();
}

/// How many paths the index has changed against HEAD's tree.
fn countChanges(repo: *Repository, head_tree: ?*const Id) ?u32 {
    const changes = changes_module.Changes.open(repo) orelse return null;
    defer changes.close();
    var count: u32 = 0;
    if (!changes.staged(head_tree, countOne, &count)) return null;
    return count;
}

fn countOne(opaque_count: *anyopaque, kind: changes_module.Kind, path: []const u8) bool {
    _ = kind;
    _ = path;
    const count: *u32 = @ptrCast(@alignCast(opaque_count));
    count.* += 1;
    return true;
}

/// A directory being gathered: its entries as its tree holds them.
const Open = struct {
    /// How much of the path is the directory's, its `/` included.
    prefix_length: usize,
    /// Its own name, in its parent.
    name: []const u8,
    bytes: []u8 = &.{},
    length: usize = 0,
};

/// Trees made from the index's entries.
const TreeBuilder = struct {
    repo: *Repository,
    git: *Git,
    arena: context.Arena,
    open: [depth_most + 1]Open = undefined,
    depth: usize = 0,
    /// The path of the innermost open directory.
    prefix: files.Path = undefined,

    /// The root tree's id; null, said, when a tree could not be made.
    fn build(builder: *TreeBuilder, entries: []const index.Entry) ?Id {
        builder.open[0] = .{ .prefix_length = 0, .name = "" };
        builder.depth = 1;
        for (entries) |*entry| {
            // The directories the entry is not in, closed.
            while (builder.depth > 1) {
                const top = &builder.open[builder.depth - 1];
                if (entry.path.len > top.prefix_length and _git.same(entry.path[0..top.prefix_length], builder.prefix[0..top.prefix_length])) break;
                if (!builder.close()) return null;
            }
            // The directories it is in that are not open yet, opened.
            var at = builder.open[builder.depth - 1].prefix_length;
            while (true) {
                var end = at;
                while (end < entry.path.len and entry.path[end] != '/') end += 1;
                if (end == entry.path.len) break;
                if (builder.depth == builder.open.len or end + 1 > files.path_most) {
                    builder.git.say("a path is too deep\n", .{});
                    return null;
                }
                @memcpy(builder.prefix[at .. end + 1], entry.path[at .. end + 1]);
                builder.open[builder.depth] = .{ .prefix_length = end + 1, .name = entry.path[at..end] };
                builder.depth += 1;
                at = end + 1;
            }
            if (!builder.append(entry.mode, entry.path[at..], &entry.id)) return null;
        }
        while (builder.depth > 1) {
            if (!builder.close()) return null;
        }
        const root = &builder.open[0];
        return loose.writeBytes(builder.repo, .tree, root.bytes[0..root.length]);
    }

    /// An entry put at the end of the innermost open directory's.
    fn append(builder: *TreeBuilder, mode: u32, name: []const u8, id: *const Id) bool {
        const top = &builder.open[builder.depth - 1];
        const needed = 7 + 1 + name.len + 1 + 20;
        if (top.length + needed > top.bytes.len) {
            const size = @max(top.bytes.len * 2, top.length + needed + 256);
            const memory = builder.arena.take(size, 1) orelse {
                builder.git.say("no memory\n", .{});
                return false;
            };
            @memcpy(memory[0..top.length], top.bytes[0..top.length]);
            top.bytes = memory[0..size];
        }
        var out: _git.Out = .{ .into = top.bytes[top.length..] };
        object.putTreeEntry(&out, mode, name, id);
        top.length += out.at;
        return true;
    }

    /// The innermost open directory written as a tree, and put into its
    /// parent's.
    fn close(builder: *TreeBuilder) bool {
        const top = builder.open[builder.depth - 1];
        const id = loose.writeBytes(builder.repo, .tree, top.bytes[0..top.length]) orelse return false;
        builder.depth -= 1;
        return builder.append(object.mode_tree, top.name, &id);
    }
};
