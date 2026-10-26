// SPDX-License-Identifier: MIT
//! `Git log [REVISION] [COUNT=n] [ONELINE]`: the history from REVISION
//! (HEAD without one), newest first. Each commit as git shows it: its
//! id and the refs that name it, the parents of a merge, the author, the
//! date in the author's own zone, the message indented; ONELINE puts a
//! commit on one line, the start of its id and its subject. COUNT=n
//! stops after n commits.

const sdk = @import("sdk");
const dos = sdk.dos;
const timezone = dos.timezone;
const _git = @import("_git.zig");
const object = @import("object.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const revision = @import("revision.zig");
const history = @import("history.zig");
const context = @import("context.zig");
const Repository = @import("repo.zig").Repository;
const Git = context.Git;
const Id = _git.Id;

pub const template = "REVISION,COUNT=N/K/N,ONELINE/S";
const arg_revision = 0;
const arg_most = 1;
const arg_oneline = 2;
pub const arg_count = 3;

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// The refs that name commits, for the line of each.
const Decorations = struct {
    /// Each ref's name and the commit it names, newest name first.
    items: []Item = &.{},
    /// HEAD's branch, or null when detached.
    head_branch: ?[]const u8 = null,
    head_id: ?Id = null,

    const Item = struct { name: []const u8, id: Id };

    /// Every ref's commit found once: a symbolic ref's target's, a tag
    /// object's peeled.
    fn collect(decorations: *Decorations, repo: *Repository, arena: *context.Arena) bool {
        const listed = refs.list(repo, "refs/", arena) orelse return false;
        const memory = arena.take(@sizeOf(Item) * (listed.len + 1), @alignOf(Item)) orelse {
            repo.git.say("no memory\n", .{});
            return false;
        };
        const items = @as([*]Item, @ptrCast(@alignCast(memory)));
        var count: usize = 0;
        var number = listed.len;
        while (number > 0) {
            number -= 1;
            const ref = &listed[number];
            const id = if (ref.target) |target|
                refs.resolve(repo, target)
            else if (ref.peeled) |peeled|
                peeled
            else if (_git.startsWith(ref.name, "refs/tags/") and !ref.from_packed)
                revision.commitOf(repo, &ref.id.?)
            else
                ref.id;
            items[count] = .{ .name = ref.name, .id = id orelse continue };
            count += 1;
        }
        decorations.items = items[0..count];
        return true;
    }
};

pub fn run(git: *Git, argv: []const usize) i32 {
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    const name: [*:0]const u8 = if (argv[arg_revision] != 0) @ptrFromInt(argv[arg_revision]) else "HEAD";
    var most: u32 = 0xFFFF_FFFF;
    if (argv[arg_most] != 0) {
        const given = @as(*const i32, @ptrFromInt(argv[arg_most])).*;
        if (given < 0) {
            git.say("COUNT must be 0 or more\n", .{});
            return dos.RETURN_ERROR;
        }
        most = @intCast(given);
    }
    const oneline = argv[arg_oneline] != 0;
    const start = revision.lookUp(repo, name) orelse return dos.RETURN_ERROR;
    const commit_id = revision.commitOf(repo, &start) orelse return dos.RETURN_ERROR;

    var arena: context.Arena = .{ .sys = git.sys };
    defer arena.free();
    var decorations: Decorations = .{};
    if (!decorations.collect(repo, &arena)) return dos.RETURN_ERROR;
    var head: refs.Head = .{};
    if (refs.head(repo, &head)) {
        decorations.head_branch = head.branch;
        decorations.head_id = head.id;
    }

    const walk = git.create(history.Walk) orelse return dos.RETURN_FAIL;
    defer git.free(walk);
    if (!walk.init(repo)) return dos.RETURN_ERROR;
    defer walk.deinit();
    if (!walk.add(&commit_id, 0)) return dos.RETURN_ERROR;
    var shown: u32 = 0;
    while (shown < most) {
        if (git.stopped()) {
            git.say("stopped\n", .{});
            return dos.RETURN_WARN;
        }
        var taken = walk.next() orelse break;
        defer taken.commit.free(git.sys);
        const commit = object.parseCommit(taken.commit.data) orelse break;
        if (oneline) {
            showShort(git, &decorations, &taken.id, &commit);
        } else {
            if (shown != 0) git.put("\n");
            showMedium(git, &decorations, &taken.id, &commit);
        }
        shown += 1;
    }
    return if (walk.failed) dos.RETURN_ERROR else dos.RETURN_OK;
}

fn showShort(git: *Git, decorations: *const Decorations, id: *const Id, commit: *const object.Commit) void {
    var hex: [40]u8 = undefined;
    _git.hexOf(id, &hex);
    git.put(hex[0..7]);
    git.put(" ");
    if (decorate(git, decorations, id, "")) git.put(" ");
    git.put(commit.subject());
    git.put("\n");
}

fn showMedium(git: *Git, decorations: *const Decorations, id: *const Id, commit: *const object.Commit) void {
    var hex: [40]u8 = undefined;
    _git.hexOf(id, &hex);
    git.put("commit ");
    git.put(&hex);
    _ = decorate(git, decorations, id, " ");
    git.put("\n");
    if (commit.parent_count > 1) {
        git.put("Merge:");
        for (0..commit.parent_count) |number| {
            const parent = commit.parent(number);
            _git.hexOf(&parent, &hex);
            git.put(" ");
            git.put(hex[0..7]);
        }
        git.put("\n");
    }
    git.put("Author: ");
    git.put(commit.author.name);
    git.put(" <");
    git.put(commit.author.email);
    git.put(">\nDate:   ");
    var date: [64]u8 = undefined;
    git.put(formatDate(&date, &commit.author));
    git.put("\n\n");
    // The message, each line indented; an empty line left empty.
    var message = commit.message;
    while (message.len > 0 and message[message.len - 1] == '\n') message = message[0 .. message.len - 1];
    var at: usize = 0;
    while (at < message.len) {
        var end = at;
        while (end < message.len and message[end] != '\n') end += 1;
        if (end > at) git.put("    ");
        git.put(message[at..end]);
        git.put("\n");
        at = end + 1;
    }
}

/// The refs naming `id` in brackets, HEAD first, `lead` before them:
/// false, and nothing written, when there are none.
fn decorate(git: *Git, decorations: *const Decorations, id: *const Id, lead: []const u8) bool {
    var any = false;
    if (decorations.head_id) |*head_id| {
        if (_git.same(head_id, id)) {
            git.put(lead);
            git.put("(HEAD");
            if (decorations.head_branch) |branch| {
                git.put(" -> ");
                git.put(shortName(branch));
            }
            any = true;
        }
    }
    for (decorations.items) |*item| {
        if (!_git.same(&item.id, id)) continue;
        if (decorations.head_branch) |branch| {
            if (_git.same(item.name, branch) and any) continue;
        }
        if (!any) git.put(lead);
        git.put(if (any) ", " else "(");
        if (_git.startsWith(item.name, "refs/tags/")) git.put("tag: ");
        git.put(shortName(item.name));
        any = true;
    }
    if (any) git.put(")");
    return any;
}

/// `main` for refs/heads/main, `origin/main` for
/// refs/remotes/origin/main, `v1` for refs/tags/v1.
pub fn shortName(name: []const u8) []const u8 {
    for ([_][]const u8{ "refs/heads/", "refs/remotes/", "refs/tags/" }) |prefix| {
        if (_git.startsWith(name, prefix)) return name[prefix.len..];
    }
    return name;
}

/// `Thu Oct 1 10:00:00 2026 +0200`: the signature's time in its own
/// zone.
fn formatDate(into: *[64]u8, signature: *const object.Signature) []const u8 {
    const local = signature.time + @as(i64, signature.offset) * 60;
    const days = @divFloor(local, 86400);
    const seconds: u32 = @intCast(local - days * 86400);
    const civil = timezone.civilFromDays(days);
    const weekday: usize = @intCast(@mod(days + 4, 7));
    var out: _git.Out = .{ .into = into };
    out.put(day_names[weekday]);
    out.byte(' ');
    out.put(month_names[civil.month - 1]);
    out.byte(' ');
    out.decimal(civil.day);
    out.byte(' ');
    twoDigits(&out, seconds / 3600);
    out.byte(':');
    twoDigits(&out, seconds / 60 % 60);
    out.byte(':');
    twoDigits(&out, seconds % 60);
    out.byte(' ');
    out.decimal(@intCast(civil.year));
    out.byte(' ');
    const offset = if (signature.offset < 0) -signature.offset else signature.offset;
    out.byte(if (signature.offset < 0) '-' else '+');
    twoDigits(&out, @intCast(@divFloor(offset, 60)));
    twoDigits(&out, @intCast(@mod(offset, 60)));
    return out.written();
}

fn twoDigits(out: *_git.Out, value: u32) void {
    out.byte('0' + @as(u8, @intCast(value / 10 % 10)));
    out.byte('0' + @as(u8, @intCast(value % 10)));
}
