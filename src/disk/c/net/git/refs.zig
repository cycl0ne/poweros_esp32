// SPDX-License-Identifier: MIT
//! Refs, the names of commits: `HEAD`, `refs/heads/main`, `refs/tags/v1`,
//! `refs/remotes/origin/main`. Each is a file under `.git` holding an id
//! - or `ref: <name>`, a symbolic ref, as HEAD mostly is - or a line of
//! `packed-refs` (`<id> <name>`, a tag's peeled object on a `^<id>` line
//! after it); a file wins over a line.
//!
//! A short name is looked for as git looks for it: as given, then under
//! `refs/`, `refs/tags/`, `refs/heads/`, `refs/remotes/`, and as a
//! remote's HEAD. A ref is written to `<name>.lock` first and renamed
//! over the old file, so it is never seen half written.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const files = @import("files.zig");
const context = @import("context.zig");
const Repository = @import("repo.zig").Repository;
const Git = context.Git;
const Id = _git.Id;

/// The longest ref name.
pub const name_most = 255;
const symbolic_depth = 5;
const packed_most = 64 * 1024 * 1024;

/// What a ref file holds.
pub const Value = struct {
    id: ?Id = null,
    /// A symbolic ref's target.
    target: [name_most + 1]u8 = undefined,
    target_length: usize = 0,

    pub fn targetText(value: *const Value) ?[]const u8 {
        return if (value.id == null and value.target_length != 0) value.target[0..value.target_length] else null;
    }
};

/// The ref `name` as its file or `packed-refs` has it: null when there
/// is none.
pub fn read(repo: *Repository, name: []const u8, into: *Value) bool {
    into.* = .{};
    var path: files.Path = undefined;
    const file_name = files.child(&path, repo.dirText(), &.{name}) orelse return false;
    var text: [name_most + 8]u8 = undefined;
    if (readSmall(repo, file_name, &text)) |content| {
        var line = content;
        while (line.len > 0 and (line[line.len - 1] == '\n' or line[line.len - 1] == '\r' or line[line.len - 1] == ' ')) line = line[0 .. line.len - 1];
        if (_git.startsWith(line, "ref: ")) {
            const target = line[5..];
            if (target.len == 0 or target.len > name_most) return false;
            @memcpy(into.target[0..target.len], target);
            into.target_length = target.len;
            return true;
        }
        into.id = _git.idOf(line) orelse return false;
        return line.len == 40;
    }
    into.id = packedId(repo, name) orelse return false;
    return true;
}

/// The id `name` names, symbolic refs followed: null when it names none
/// (an unborn branch among them).
pub fn resolve(repo: *Repository, name: []const u8) ?Id {
    var value: Value = .{};
    var current: [name_most + 1]u8 = undefined;
    if (name.len > name_most) return null;
    @memcpy(current[0..name.len], name);
    var length = name.len;
    for (0..symbolic_depth) |_| {
        if (!read(repo, current[0..length], &value)) return null;
        if (value.id) |id| return id;
        const target = value.targetText() orelse return null;
        @memcpy(current[0..target.len], target);
        length = target.len;
    }
    return null;
}

/// What a name the user typed stands for: a whole id, or a ref by git's
/// rules - its full name written into `full` when given.
pub fn expand(repo: *Repository, text: []const u8, full: ?*[name_most + 1]u8) ?Id {
    if (text.len == 40) {
        if (_git.idOf(text)) |id| return id;
    }
    const rules = [_][2][]const u8{
        .{ "", "" },
        .{ "refs/", "" },
        .{ "refs/tags/", "" },
        .{ "refs/heads/", "" },
        .{ "refs/remotes/", "" },
        .{ "refs/remotes/", "/HEAD" },
    };
    for (rules) |rule| {
        var name: [name_most + 1]u8 = undefined;
        var out: _git.Out = .{ .into = name[0..name_most] };
        out.put(rule[0]);
        out.put(text);
        out.put(rule[1]);
        if (out.overflow) continue;
        // Only HEAD and the names under refs/ are refs as given.
        if (rule[0].len == 0 and !_git.startsWith(text, "refs/") and !isHeadName(text)) continue;
        if (resolve(repo, out.written())) |id| {
            if (full) |into| {
                @memcpy(into[0..out.at], out.written());
                into[out.at] = 0;
            }
            return id;
        }
    }
    return null;
}

fn isHeadName(text: []const u8) bool {
    for ([_][]const u8{ "HEAD", "FETCH_HEAD", "ORIG_HEAD" }) |name| {
        if (_git.same(text, name)) return true;
    }
    return false;
}

/// The id of `name` in `packed-refs`.
fn packedId(repo: *Repository, name: []const u8) ?Id {
    const git = repo.git;
    var path: files.Path = undefined;
    const file_name = files.child(&path, repo.dirText(), &.{"packed-refs"}) orelse return null;
    const text = files.readWhole(git, file_name, packed_most) orelse return null;
    defer git.free(text.ptr);
    var lines: Lines = .{ .text = text };
    while (lines.next()) |line| {
        if (line.len < 42 or line[40] != ' ') continue;
        if (_git.same(line[41..], name)) return _git.idOf(line);
    }
    return null;
}

/// A text's lines, without their line ends.
pub const Lines = struct {
    text: []const u8,
    at: usize = 0,

    pub fn next(lines: *Lines) ?[]const u8 {
        if (lines.at >= lines.text.len) return null;
        var end = lines.at;
        while (end < lines.text.len and lines.text[end] != '\n') end += 1;
        var line = lines.text[lines.at..end];
        lines.at = end + 1;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

/// A small file's bytes, at most `into.len`; null when there is none.
fn readSmall(repo: *Repository, name: [*:0]const u8, into: []u8) ?[]u8 {
    const dl = repo.git.dl;
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(file);
    const got = dl.Read(file, into.ptr, @intCast(into.len));
    if (got < 0) return null;
    return into[0..@intCast(got)];
}

/// The ref `name` set to `id`: false, said, when it cannot be written.
pub fn write(repo: *Repository, name: []const u8, id: *const Id) bool {
    var text: [41]u8 = undefined;
    _git.hexOf(id, text[0..40]);
    text[40] = '\n';
    return writeFile(repo, name, &.{&text});
}

/// The ref `name` made symbolic, naming `target`.
pub fn writeSymbolic(repo: *Repository, name: []const u8, target: []const u8) bool {
    return writeFile(repo, name, &.{ "ref: ", target, "\n" });
}

/// `.git/<name>` written through `<name>.lock`.
pub fn writeFile(repo: *Repository, name: []const u8, parts: []const []const u8) bool {
    const git = repo.git;
    const dl = git.dl;
    var path: files.Path = undefined;
    var lock_path: files.Path = undefined;
    const file_name = repo.path(&path, &.{name}) orelse return false;
    const lock_name = repo.path(&lock_path, &.{ name, ".lock" }) orelse return false;
    if (!files.writeWhole(git, lock_name, parts)) {
        _ = dl.PrintFault(dl.IoErr(), lock_name);
        return false;
    }
    _ = dl.DeleteFile(file_name);
    if (!dl.Rename(lock_name, file_name)) {
        _ = dl.PrintFault(dl.IoErr(), file_name);
        _ = dl.DeleteFile(lock_name);
        return false;
    }
    return true;
}

/// A ref as `list` hands it out.
pub const Listed = struct {
    name: [:0]const u8,
    /// Null for a symbolic ref.
    id: ?Id,
    /// A symbolic ref's target.
    target: ?[:0]const u8 = null,
    /// What a tag object names, as `packed-refs` has it.
    peeled: ?Id = null,
    /// From `packed-refs`, which notes every tag object's peeled id: a
    /// tag there without one names no tag object.
    from_packed: bool = false,
};

/// Every ref under `prefix` (`refs/heads/`), sorted by name, a loose
/// file winning over a line of `packed-refs`: copied into `arena`, null
/// when there is no memory (said).
pub fn list(repo: *Repository, prefix: []const u8, arena: *context.Arena) ?[]Listed {
    const git = repo.git;
    var collected: Collected = .{ .arena = arena };
    // packed-refs first; a loose file of the same name replaces its line.
    var path: files.Path = undefined;
    if (files.child(&path, repo.dirText(), &.{"packed-refs"})) |name| {
        if (files.readWhole(git, name, packed_most)) |text| {
            defer git.free(text.ptr);
            var lines: Lines = .{ .text = text };
            while (lines.next()) |line| {
                if (line.len > 1 and line[0] == '^') {
                    if (collected.last) |last| last.ref.peeled = _git.idOf(line[1..]);
                    continue;
                }
                if (line.len < 42 or line[40] != ' ' or !_git.startsWith(line[41..], prefix)) {
                    collected.last = null;
                    continue;
                }
                const id = _git.idOf(line) orelse continue;
                if (!collected.add(line[41..], id, null)) return null;
                collected.last.?.ref.from_packed = true;
            }
        }
    }
    if (!listLoose(repo, prefix, &collected)) return null;
    const memory = arena.take(@sizeOf(Listed) * (collected.count + 1), @alignOf(Listed)) orelse return noMemory(git);
    const out = @as([*]Listed, @ptrCast(@alignCast(memory)))[0..collected.count];
    var count: usize = 0;
    var node = collected.first;
    while (node) |each| : (node = each.next) {
        if (each.gone) continue;
        out[count] = each.ref;
        count += 1;
    }
    _git.heapSort(Listed, out[0..count], {}, listedBefore);
    return out[0..count];
}

fn listedBefore(_: void, a: *const Listed, b: *const Listed) bool {
    return _git.order(a.name, b.name) == .less;
}

fn noMemory(git: *Git) ?[]Listed {
    git.say("no memory\n", .{});
    return null;
}

const Collected = struct {
    arena: *context.Arena,
    first: ?*Node = null,
    last: ?*Node = null,
    tail: ?*Node = null,
    count: usize = 0,

    const Node = struct {
        ref: Listed,
        gone: bool = false,
        next: ?*Node = null,
    };

    fn add(collected: *Collected, name: []const u8, id: ?Id, target: ?[]const u8) bool {
        // A loose ref replaces the packed line of its name.
        var node = collected.first;
        while (node) |each| : (node = each.next) {
            if (!each.gone and _git.same(each.ref.name, name)) {
                collected.count -= 1;
                each.gone = true;
            }
        }
        const copied = collected.arena.copy(name) orelse return false;
        const copied_target = if (target) |text| (collected.arena.copy(text) orelse return false) else null;
        const made = collected.arena.create(Node, .{ .ref = .{ .name = copied, .id = id, .target = copied_target } }) orelse return false;
        if (collected.tail) |tail| tail.next = made else collected.first = made;
        collected.tail = made;
        collected.last = made;
        collected.count += 1;
        return true;
    }
};

/// The loose refs under `prefix`: the directory `.git/<prefix>` walked,
/// each file read.
fn listLoose(repo: *Repository, prefix: []const u8, collected: *Collected) bool {
    const git = repo.git;
    const dl = git.dl;
    const walk = git.create(LooseWalk) orelse return false;
    defer git.free(walk);
    // The prefix up to its last '/' is the directory.
    var dir_length = prefix.len;
    while (dir_length > 0 and prefix[dir_length - 1] != '/') dir_length -= 1;
    if (dir_length == 0 or dir_length > name_most) return true;
    @memcpy(walk.name[0..dir_length], prefix[0..dir_length]);
    walk.lengths[0] = dir_length;
    walk.depth = 0;
    {
        var path: files.Path = undefined;
        const dir = files.child(&path, repo.dirText(), &.{prefix[0 .. dir_length - 1]}) orelse return true;
        walk.locks[0] = dl.Lock(dir, dos.SHARED_LOCK) orelse return true;
        if (!dl.Examine(walk.locks[0].?, &walk.fibs[0])) {
            dl.UnLock(walk.locks[0].?);
            return true;
        }
    }
    var ok = true;
    while (true) {
        const depth = walk.depth;
        const lock = walk.locks[depth].?;
        if (!dl.ExNext(lock, &walk.fibs[depth])) {
            dl.UnLock(lock);
            walk.locks[depth] = null;
            if (depth == 0) break;
            walk.depth -= 1;
            continue;
        }
        const fib = &walk.fibs[depth];
        const entry = files.span(@ptrCast(&fib.file_name));
        const length = walk.lengths[depth];
        if (length + entry.len + 1 > name_most) continue;
        @memcpy(walk.name[length..][0..entry.len], entry);
        const name = walk.name[0 .. length + entry.len];
        if (dos.isDirectory(fib.dir_entry_type)) {
            if (depth + 1 == walk.locks.len) continue;
            walk.name[name.len] = '/';
            var path: files.Path = undefined;
            const dir = files.child(&path, repo.dirText(), &.{name}) orelse continue;
            const inner = dl.Lock(dir, dos.SHARED_LOCK) orelse continue;
            if (!dl.Examine(inner, &walk.fibs[depth + 1])) {
                dl.UnLock(inner);
                continue;
            }
            walk.depth += 1;
            walk.locks[walk.depth] = inner;
            walk.lengths[walk.depth] = name.len + 1;
            continue;
        }
        if (!_git.startsWith(name, prefix) or _git.endsWith(name, ".lock")) continue;
        var value: Value = .{};
        if (!read(repo, name, &value)) continue;
        if (!collected.add(name, value.id, value.targetText())) {
            ok = false;
            break;
        }
    }
    while (true) {
        if (walk.locks[walk.depth]) |lock| dl.UnLock(lock);
        if (walk.depth == 0) break;
        walk.depth -= 1;
    }
    if (!ok) git.say("no memory\n", .{});
    return ok;
}

const loose_depth = 16;

const LooseWalk = struct {
    depth: usize,
    locks: [loose_depth]?*dos.FileLock,
    lengths: [loose_depth]usize,
    fibs: [loose_depth]dos.FileInfoBlock,
    name: [name_most + 1]u8,
};

/// Where HEAD is: on a branch (born or not), or detached at a commit.
pub const Head = struct {
    /// The branch HEAD names, `refs/heads/main`; null when detached.
    branch: ?[]const u8 = null,
    /// The commit it is at; null on an unborn branch.
    id: ?Id = null,
    value: Value = .{},
};

pub fn head(repo: *Repository, into: *Head) bool {
    into.* = .{};
    if (!read(repo, "HEAD", &into.value)) return false;
    if (into.value.targetText()) |target| {
        into.branch = target;
        into.id = resolve(repo, target);
    } else {
        into.id = into.value.id;
    }
    return true;
}
