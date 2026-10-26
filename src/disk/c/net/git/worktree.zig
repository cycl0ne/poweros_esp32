// SPDX-License-Identifier: MIT
//! The work tree and the index: a commit's tree written into an empty
//! work tree (a clone), or both moved from one tree to another (a
//! checkout, a pull) without losing a change made in them.
//!
//! **Walking a tree**: `TreeWalk` hands out a tree's entries depth first,
//! each with its whole path, a frame for each directory on the way down -
//! the directory's tree in memory, where its entries have got to - so
//! nothing recurses on the command's stack. Tree order is the index's
//! order, so a walk, the index and another walk go side by side.
//!
//! **What each mode becomes**: 100644 a file whose E bit is set (it may
//! not be run), 100755 a file that may be run, 120000 (a symbolic link)
//! a file holding the link's target, 160000 (a submodule) an empty
//! directory. Names are made Latin-1 where they can be.
//!
//! A path no dos volume holds - an empty name, `.`, `..`, `.git` in any
//! case, a name with a `:` in it, one longer than `name_max` - is not
//! made, nor one that differs only in case from one made before it, nor
//! one whose file cannot be written: each is said, and kept in the index
//! with skip-worktree set, so it is not taken for deleted.
//!
//! **Moving between trees** (`switchTrees`) decides for every path what
//! HEAD's tree, the index and the new tree hold there. Where the index
//! already holds the new tree's entry, or HEAD's and the new tree's
//! agree, the path is left as it is - a change made there is carried
//! over. Where the index holds HEAD's entry, the path takes the new
//! tree's, provided its file is as the index says (or gone); a file
//! there the index does not know must be the new tree's already. Any
//! other path would lose a change: then every such path is named and
//! nothing is changed. Files are deleted first, then written, so a file
//! may become a directory and a directory a file.
//!
//! **Is a file changed?** Its size and date against what the index noted
//! when it was written; a file of the same size dated as the index - or
//! after it, so the change may have come in the second the index was
//! written - is hashed and its id compared.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const _git = @import("_git.zig");
const object = @import("object.zig");
const index = @import("index.zig");
const files = @import("files.zig");
const packread = @import("packread.zig");
const context = @import("context.zig");
const Repository = @import("repo.zig").Repository;
const Git = context.Git;
const Id = _git.Id;

/// How deep the directories of a tree go.
const depth_most = 256;
/// The largest index read.
const index_most = 256 * 1024 * 1024;
const hash_buffer_bytes = 16 * 1024;

/// An entry of a tree, with its whole path.
pub const Item = struct {
    path: []const u8,
    mode: u32,
    id: Id,
};

const Frame = struct {
    tree: packread.Object,
    entries: object.TreeEntries,
    /// How much of the path is this directory's, its `/` included.
    prefix: usize,
};

/// A tree's entries, depth first - a directory's entry before what is
/// in it.
pub const TreeWalk = struct {
    repo: *Repository,
    depth: usize,
    /// A tree was missing or broken (said).
    failed: bool,
    frames: [depth_most]Frame,
    path: [files.path_most + 1]u8,

    /// The walk through `tree` started; none for no tree (an unborn
    /// branch). False, said, when the tree cannot be read.
    pub fn start(walk: *TreeWalk, repo: *Repository, tree: ?*const Id) bool {
        walk.repo = repo;
        walk.depth = 0;
        walk.failed = false;
        if (tree) |id| return walk.push(id, 0);
        return true;
    }

    pub fn deinit(walk: *TreeWalk) void {
        while (walk.depth > 0) walk.pop();
    }

    /// The next entry, its path valid until the next call; null at the
    /// end, or when the walk failed.
    pub fn next(walk: *TreeWalk) ?Item {
        const git = walk.repo.git;
        while (walk.depth > 0) {
            const frame = &walk.frames[walk.depth - 1];
            const entry = frame.entries.next() orelse {
                if (frame.entries.bad) {
                    git.say("a tree is broken\n", .{});
                    return walk.fail();
                }
                walk.pop();
                continue;
            };
            if (frame.prefix + entry.name.len + 1 > files.path_most) {
                git.say("a path in the tree is longer than %u\n", .{@as(u32, files.path_most)});
                return walk.fail();
            }
            @memcpy(walk.path[frame.prefix..][0..entry.name.len], entry.name);
            const length = frame.prefix + entry.name.len;
            const item: Item = .{ .path = walk.path[0..length], .mode = entry.mode, .id = entry.id };
            if (entry.mode == object.mode_tree) {
                walk.path[length] = '/';
                if (!walk.push(&entry.id, length + 1)) return walk.fail();
            }
            return item;
        }
        return null;
    }

    /// The next entry that is no directory.
    pub fn nextFile(walk: *TreeWalk) ?Item {
        while (walk.next()) |item| {
            if (item.mode != object.mode_tree) return item;
        }
        return null;
    }

    fn fail(walk: *TreeWalk) ?Item {
        walk.failed = true;
        walk.deinit();
        return null;
    }

    fn push(walk: *TreeWalk, id: *const Id, prefix: usize) bool {
        const git = walk.repo.git;
        if (walk.depth == depth_most) {
            git.say("the tree's directories go deeper than %u\n", .{@as(u32, depth_most)});
            return false;
        }
        var tree = walk.repo.objects.read(id) orelse return false;
        if (tree.kind != .tree) {
            tree.free(git.sys);
            git.say("a tree names an object that is no tree\n", .{});
            return false;
        }
        walk.frames[walk.depth] = .{ .tree = tree, .entries = .{ .body = tree.data }, .prefix = prefix };
        walk.depth += 1;
        return true;
    }

    fn pop(walk: *TreeWalk) void {
        walk.depth -= 1;
        walk.frames[walk.depth].tree.free(walk.repo.git.sys);
    }
};

/// The index as `.git/index` holds it, and when it was written.
pub const IndexFile = struct {
    bytes: []u8 = &.{},
    index: ?index.Index = null,
    /// Its date, in seconds since 1970.
    seconds: i64 = 0,

    /// The repository's index; an empty one when there is none. False,
    /// said, when it cannot be read or is none Git reads.
    pub fn read(into: *IndexFile, repo: *Repository) bool {
        const git = repo.git;
        const dl = git.dl;
        into.* = .{};
        var path: files.Path = undefined;
        const name = repo.path(&path, &.{"index"}) orelse return false;
        const lock = dl.Lock(name, dos.SHARED_LOCK) orelse return true;
        const fib = git.create(dos.FileInfoBlock) orelse {
            dl.UnLock(lock);
            return false;
        };
        defer git.free(fib);
        if (dl.Examine(lock, fib)) into.seconds = git.unixTime(fib.date).seconds;
        dl.UnLock(lock);
        into.bytes = files.readWhole(git, name, index_most) orelse {
            _ = dl.PrintFault(dl.IoErr(), name);
            return false;
        };
        into.index = index.Index.open(into.bytes) orelse {
            git.say("%s is no index Git reads\n", .{name});
            into.free(git);
            return false;
        };
        if (!into.index.?.verify(git.cb)) {
            git.say("%s is broken: its checksum is wrong\n", .{name});
            into.free(git);
            return false;
        }
        return true;
    }

    /// The index written back as its bytes now are, with a new
    /// checksum, through `index.lock`.
    pub fn rewrite(file: *IndexFile, repo: *Repository) bool {
        const git = repo.git;
        const dl = git.dl;
        if (file.bytes.len < 20) return true;
        const sum = _git.sha1Of(git.cb, file.bytes[0 .. file.bytes.len - 20]);
        @memcpy(file.bytes[file.bytes.len - 20 ..], &sum);
        var lock_path: files.Path = undefined;
        var path: files.Path = undefined;
        const lock_name = repo.path(&lock_path, &.{"index.lock"}) orelse return false;
        const name = repo.path(&path, &.{"index"}) orelse return false;
        // Another Git writing the index now: it is left to it.
        if (dl.Lock(lock_name, dos.SHARED_LOCK)) |lock| {
            dl.UnLock(lock);
            return false;
        }
        if (!files.writeWhole(git, lock_name, &.{file.bytes})) return false;
        _ = dl.DeleteFile(name);
        return dl.Rename(lock_name, name);
    }

    pub fn free(file: *IndexFile, git: *Git) void {
        if (file.bytes.len != 0) git.free(file.bytes.ptr);
        file.* = .{};
    }

    pub fn entries(file: *const IndexFile) IndexWalk {
        return .{ .inner = if (file.index) |*found| found.entries() else null };
    }
};

/// An index's entries, none for no index.
pub const IndexWalk = struct {
    inner: ?index.Entries,

    pub fn next(walk: *IndexWalk) ?index.Entry {
        if (walk.inner) |*inner| return inner.next();
        return null;
    }

    pub fn bad(walk: *const IndexWalk) bool {
        return if (walk.inner) |inner| inner.bad else false;
    }
};

/// What the work tree holds at an index entry's path.
pub const State = enum { same, changed, missing };

/// What the work tree does: paths made dos paths, files checked against
/// the index and written from blobs.
pub const Work = struct {
    repo: *Repository,
    git: *Git,
    /// The date the index was written, for a file dated as it.
    index_seconds: i64 = 0,
    told_submodules: bool = false,
    files_made: u32 = 0,
    /// The last `stateOf` hashed the file: its date and size, in `fib`,
    /// may be noted in the index.
    hashed: bool = false,
    fib: dos.FileInfoBlock = .{},
    local: [files.path_most + 1]u8 = undefined,
    buffer: ?[*]u8 = null,

    pub fn init(work: *Work, repo: *Repository) void {
        work.* = .{ .repo = repo, .git = repo.git };
    }

    pub fn deinit(work: *Work) void {
        work.git.free(work.buffer);
        work.buffer = null;
    }

    /// The dos path of the tree's `path`, in the work tree: null when it
    /// is too long.
    pub fn localPath(work: *Work, into: *files.Path, path: []const u8) ?[*:0]const u8 {
        const name = files.localName(&work.local, path) orelse return null;
        return work.repo.workPathQuiet(into, name);
    }

    /// What the work tree holds where `entry` is.
    pub fn stateOf(work: *Work, entry: *const index.Entry, local: [*:0]const u8) State {
        work.hashed = false;
        if (entry.skip_worktree) return .same;
        const dl = work.git.dl;
        const lock = dl.Lock(local, dos.SHARED_LOCK) orelse return .missing;
        const examined = dl.Examine(lock, &work.fib);
        dl.UnLock(lock);
        if (!examined) return .changed;
        const directory = dos.isDirectory(work.fib.dir_entry_type);
        if (entry.mode == object.mode_gitlink) return if (directory) .same else .changed;
        if (directory or work.fib.size != entry.size) return .changed;
        const time = work.git.unixTime(work.fib.date);
        const seconds: u32 = @truncate(@as(u64, @bitCast(time.seconds)));
        if (seconds == entry.mtime and time.nanoseconds == entry.mtime_ns and time.seconds < work.index_seconds) return .same;
        const id = work.hashFile(local, work.fib.size) orelse return .changed;
        work.hashed = true;
        return if (_git.same(&id, &entry.id)) .same else .changed;
    }

    /// `entry`'s date and size set from the file `stateOf` examined
    /// last.
    pub fn noteExamined(work: *Work, entry: *index.Entry) void {
        const time = work.git.unixTime(work.fib.date);
        entry.mtime = @truncate(@as(u64, @bitCast(time.seconds)));
        entry.mtime_ns = time.nanoseconds;
        entry.ctime = entry.mtime;
        entry.ctime_ns = entry.mtime_ns;
        entry.size = @truncate(work.fib.size);
    }

    /// The id the file `local` of `size` bytes has as a blob.
    pub fn hashFile(work: *Work, local: [*:0]const u8, size: u64) ?Id {
        const git = work.git;
        const dl = git.dl;
        if (work.buffer == null) work.buffer = git.alloc(hash_buffer_bytes) orelse return null;
        const buffer = work.buffer.?[0..hash_buffer_bytes];
        const file = dl.Open(local, dos.MODE_OLDFILE) orelse return null;
        defer _ = dl.Close(file);
        var sha = _git.Sha1.start(git.cb);
        var head: [32]u8 = undefined;
        sha.update(object.header(.blob, size, &head));
        var total: u64 = 0;
        while (true) {
            const got = dl.Read(file, buffer.ptr, @intCast(buffer.len));
            if (got < 0) return null;
            if (got == 0) break;
            sha.update(buffer[0..@intCast(got)]);
            total += @intCast(got);
        }
        if (total != size) return null;
        return sha.finish();
    }

    /// The blob `entry.id` written as the file `local`, its size and
    /// date noted in `entry`: false, said, when it could not be.
    pub fn writeBlob(work: *Work, path: []const u8, local: [*:0]const u8, entry: *index.Entry) bool {
        const git = work.git;
        const dl = git.dl;
        var blob = work.repo.objects.read(&entry.id) orelse {
            refuse(git, path, "is missing from the store");
            return false;
        };
        defer blob.free(git.sys);
        if (blob.kind != .blob) {
            refuse(git, path, "names an object that is no blob");
            return false;
        }
        const file = dl.Open(local, dos.MODE_NEWFILE) orelse {
            _ = dl.PrintFault(dl.IoErr(), local);
            refuse(git, path, "could not be made");
            return false;
        };
        var written = blob.data.len == 0 or dl.Write(file, blob.data.ptr, @intCast(blob.data.len)) == blob.data.len;
        if (!dl.Close(file)) written = false;
        if (!written) {
            const code = dl.IoErr();
            _ = dl.DeleteFile(local);
            _ = dl.PrintFault(code, local);
            refuse(git, path, "could not be written");
            return false;
        }
        // A file git does not run may not be run here either.
        _ = dl.SetProtection(local, if (entry.mode == object.mode_executable) 0 else dos.FIBF_EXECUTE);
        entry.size = @truncate(blob.data.len);
        work.noteDate(local, entry);
        work.files_made += 1;
        if (work.files_made % 16 == 0) git.progress("Checking out files: %u", .{work.files_made});
        return true;
    }

    /// The directory for a submodule made.
    pub fn makeSubmodule(work: *Work, path: []const u8, local: [*:0]const u8) bool {
        if (!work.told_submodules) {
            work.git.say("a submodule is made an empty directory; its own repository is not cloned\n", .{});
            work.told_submodules = true;
        }
        return makeDir(work.git, path, local);
    }

    /// Whether what is at `local`, which the index does not know, may
    /// make way for `item`: nothing is there, or a file that is it.
    pub fn untrackedFits(work: *Work, local: [*:0]const u8, item: *const Item) bool {
        const dl = work.git.dl;
        const lock = dl.Lock(local, dos.SHARED_LOCK) orelse return true;
        const examined = dl.Examine(lock, &work.fib);
        dl.UnLock(lock);
        if (!examined) return false;
        if (dos.isDirectory(work.fib.dir_entry_type)) return item.mode == object.mode_gitlink;
        const id = work.hashFile(local, work.fib.size) orelse return false;
        return _git.same(&id, &item.id);
    }

    fn noteDate(work: *Work, local: [*:0]const u8, entry: *index.Entry) void {
        const dl = work.git.dl;
        const lock = dl.Lock(local, dos.SHARED_LOCK) orelse return;
        defer dl.UnLock(lock);
        if (!dl.Examine(lock, &work.fib)) return;
        const time = work.git.unixTime(work.fib.date);
        entry.mtime = @truncate(@as(u64, @bitCast(time.seconds)));
        entry.mtime_ns = time.nanoseconds;
        entry.ctime = entry.mtime;
        entry.ctime_ns = entry.mtime_ns;
    }

    /// Whether a dos volume can hold the last name of `path`, and git
    /// allows it.
    pub fn allowed(path: []const u8) bool {
        var start = path.len;
        while (start > 0 and path[start - 1] != '/') start -= 1;
        const name = path[start..];
        if (name.len == 0 or name.len > dos.name_max) return false;
        if (_git.same(name, ".") or _git.same(name, "..")) return false;
        if (name.len == 4 and name[0] == '.' and lower(name[1]) == 'g' and lower(name[2]) == 'i' and lower(name[3]) == 't') return false;
        for (name) |char| {
            if (char == ':' or char == 0) return false;
        }
        return true;
    }
};

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

/// `path` said as not checked out, and why.
pub fn refuse(git: *Git, path: []const u8, why: []const u8) void {
    git.endProgress();
    git.put("Git: ");
    git.put(path);
    git.put(" ");
    git.put(why);
    git.put(" - not checked out\n");
}

fn makeDir(git: *Git, path: []const u8, local: [*:0]const u8) bool {
    const dl = git.dl;
    if (dl.CreateDir(local)) |lock| {
        dl.UnLock(lock);
        return true;
    }
    if (dl.IoErr() == dos.ERROR_OBJECT_EXISTS) {
        // A directory there already: one of the same name, or of a
        // name that differs only in case.
        if (dl.Lock(local, dos.SHARED_LOCK)) |lock| {
            dl.UnLock(lock);
            return true;
        }
        refuse(git, path, "differs only in case from a path made before it");
    } else {
        _ = dl.PrintFault(dl.IoErr(), local);
        refuse(git, path, "could not be made");
    }
    return false;
}

/// The mode the index keeps for a tree's mode.
pub fn normalMode(mode: u32) u32 {
    return switch (mode) {
        object.mode_executable, object.mode_link, object.mode_gitlink => mode,
        else => if (mode & 0o170000 == 0o100000 and mode & 0o100 != 0) object.mode_executable else object.mode_file,
    };
}

/// Index entries collected in path order, then written.
const NewIndex = struct {
    arena: context.Arena,
    first: ?*Node = null,
    last: ?*Node = null,
    count: u32 = 0,
    skipped: u32 = 0,

    const Node = struct {
        entry: index.Entry,
        next: ?*Node = null,
    };

    fn add(new_index: *NewIndex, entry: *const index.Entry) ?*index.Entry {
        const path = new_index.arena.copy(entry.path) orelse return null;
        var copy = entry.*;
        copy.path = path;
        const node = new_index.arena.create(Node, .{ .entry = copy }) orelse return null;
        if (new_index.last) |last| last.next = node else new_index.first = node;
        new_index.last = node;
        new_index.count += 1;
        if (copy.skip_worktree) new_index.skipped += 1;
        return &node.entry;
    }

    fn write(new_index: *NewIndex, repo: *Repository) bool {
        return writeIndex(repo, new_index.count, new_index.skipped != 0, new_index);
    }

    /// The entries one at a time, for `writeIndex`.
    pub fn next(new_index: *NewIndex) ?*const index.Entry {
        const node = new_index.first orelse return null;
        new_index.first = node.next;
        return &node.entry;
    }
};

/// `.git/index` written through `index.lock`: `count` entries, in path
/// order, each from `source.next()` - of version 3 when one is to carry
/// skip-worktree (`extended`). False, said, when it could not be, and
/// when another Git is writing it.
pub fn writeIndex(repo: *Repository, count: u32, extended: bool, source: anytype) bool {
    const git = repo.git;
    const dl = git.dl;
    var lock_path: files.Path = undefined;
    var path: files.Path = undefined;
    const lock_name = repo.path(&lock_path, &.{"index.lock"}) orelse return false;
    const name = repo.path(&path, &.{"index"}) orelse return false;
    if (dl.Lock(lock_name, dos.SHARED_LOCK)) |lock| {
        dl.UnLock(lock);
        git.say("%s is there: another Git is writing the index - or one stopped, and then it may be deleted\n", .{lock_name});
        return false;
    }
    const file = dl.Open(lock_name, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), lock_name);
        return false;
    };
    var sink: files.FileSink = .{ .dl = dl, .file = file };
    var writer = index.Writer.start(git.cb, sink.asSink(), count, extended);
    while (source.next()) |entry| writer.entry(entry);
    var written = writer.finish();
    if (!dl.Close(file)) written = false;
    if (!written) {
        _ = dl.PrintFault(dl.IoErr(), lock_name);
        _ = dl.DeleteFile(lock_name);
        return false;
    }
    _ = dl.DeleteFile(name);
    if (!dl.Rename(lock_name, name)) {
        _ = dl.PrintFault(dl.IoErr(), name);
        return false;
    }
    return true;
}

fn noMemory(git: *Git) bool {
    git.say("no memory\n", .{});
    return false;
}

/// The tree `tree` written into the repository's empty work tree, and
/// the index for it: false, said, when it could not be.
pub fn populate(repo: *Repository, tree: *const Id) bool {
    const git = repo.git;
    const walk = git.create(TreeWalk) orelse return false;
    defer git.free(walk);
    const work = git.create(Work) orelse return false;
    defer git.free(work);
    work.init(repo);
    defer work.deinit();
    var new_index: NewIndex = .{ .arena = .{ .sys = git.sys } };
    defer new_index.arena.free();
    if (!walk.start(repo, tree)) return false;
    defer walk.deinit();
    // A directory not made: what is in it is not either.
    var skip_prefix: files.Path = undefined;
    var skip_length: usize = 0;
    var local_path: files.Path = undefined;
    while (walk.next()) |item| {
        if (git.stopped()) {
            git.say("stopped\n", .{});
            return false;
        }
        if (skip_length != 0 and !_git.startsWith(item.path, skip_prefix[0..skip_length])) skip_length = 0;
        var skip = skip_length != 0;
        var local: ?[*:0]const u8 = null;
        if (!skip and !Work.allowed(item.path)) {
            refuse(git, item.path, "is no name a dos volume holds");
            skip = true;
        }
        if (!skip) {
            local = work.localPath(&local_path, item.path);
            if (local == null) {
                refuse(git, item.path, "is too long a path here");
                skip = true;
            }
        }
        if (item.mode == object.mode_tree) {
            if (!skip and makeDir(git, item.path, local.?)) continue;
            if (skip_length == 0) {
                @memcpy(skip_prefix[0..item.path.len], item.path);
                skip_prefix[item.path.len] = '/';
                skip_length = item.path.len + 1;
            }
            continue;
        }
        var entry: index.Entry = .{ .mode = normalMode(item.mode), .size = 0, .id = item.id, .path = item.path };
        if (!skip) {
            if (item.mode == object.mode_gitlink) {
                skip = !work.makeSubmodule(item.path, local.?);
            } else if (git.dl.Lock(local.?, dos.SHARED_LOCK)) |lock| {
                git.dl.UnLock(lock);
                refuse(git, item.path, "differs only in case from a path made before it");
                skip = true;
            } else {
                skip = !work.writeBlob(item.path, local.?, &entry);
                if (skip and git.stopped()) return false;
            }
        }
        entry.skip_worktree = skip;
        _ = new_index.add(&entry) orelse return noMemory(git);
    }
    if (walk.failed) return false;
    git.endProgress();
    if (work.files_made != 0) git.progress("Checking out files: %u, done.", .{work.files_made});
    git.endProgress();
    if (!new_index.write(repo)) return false;
    if (new_index.skipped != 0) git.say("%u paths were not checked out\n", .{new_index.skipped});
    return true;
}

/// What happens to a path when the work tree moves to another tree.
const Action = struct {
    kind: enum { keep, write, delete },
    entry: index.Entry,
    next: ?*Action = null,
};

/// The work tree and the index moved from the tree `from` - HEAD's, or
/// none - to `to`, keeping what was changed in them: false, said, when a
/// change would be lost (then nothing is changed) or the move failed.
pub fn switchTrees(repo: *Repository, from: ?*const Id, to: *const Id) bool {
    const git = repo.git;
    const old_walk = git.create(TreeWalk) orelse return false;
    defer git.free(old_walk);
    const new_walk = git.create(TreeWalk) orelse return false;
    defer git.free(new_walk);
    const work = git.create(Work) orelse return false;
    defer git.free(work);
    work.init(repo);
    defer work.deinit();
    var arena: context.Arena = .{ .sys = git.sys };
    defer arena.free();
    var current: IndexFile = .{};
    if (!current.read(repo)) return false;
    defer current.free(git);
    work.index_seconds = current.seconds;
    if (!old_walk.start(repo, from)) return false;
    defer old_walk.deinit();
    if (!new_walk.start(repo, to)) return false;
    defer new_walk.deinit();

    // Pass 1: what each path does, every change that would be lost said.
    var first: ?*Action = null;
    var last: ?*Action = null;
    var lost: u32 = 0;
    var entries = current.entries();
    var old_item = old_walk.nextFile();
    var new_item = new_walk.nextFile();
    var entry = entries.next();
    var local_path: files.Path = undefined;
    while (old_item != null or new_item != null or entry != null) {
        if (git.stopped()) {
            git.say("stopped\n", .{});
            return false;
        }
        if (entry) |held| {
            if (held.stage != 0) {
                git.endProgress();
                git.put("Git: ");
                git.put(held.path);
                git.put(" is not merged - nothing was changed\n");
                return false;
            }
        }
        var path: []const u8 = undefined;
        var have_path = false;
        for ([_]?[]const u8{
            if (old_item) |item| item.path else null,
            if (new_item) |item| item.path else null,
            if (entry) |held| held.path else null,
        }) |candidate| {
            const each = candidate orelse continue;
            if (!have_path or _git.order(each, path) == .less) {
                path = each;
                have_path = true;
            }
        }
        const old_here = if (old_item) |item| (if (_git.same(item.path, path)) item else null) else null;
        const new_here = if (new_item) |item| (if (_git.same(item.path, path)) item else null) else null;
        const entry_here = if (entry) |held| (if (_git.same(held.path, path)) held else null) else null;

        var action: Action = .{ .kind = .keep, .entry = undefined };
        var decided = true;
        if (sameEntry(entry_here, new_here) or sameItems(old_here, new_here)) {
            // The index has the new tree's already, or the new tree
            // changes nothing here: what is here stays.
            if (entry_here) |held| action.entry = held else decided = false;
        } else if (sameEntry(entry_here, old_here)) {
            const local = work.localPath(&local_path, path);
            if (entry_here) |held| {
                if (local != null and work.stateOf(&held, local.?) == .changed) {
                    sayLost(git, path, "is changed here");
                    lost += 1;
                }
            } else if (local) |name| {
                if (!work.untrackedFits(name, &new_here.?)) {
                    sayLost(git, path, "is here, and not in the index");
                    lost += 1;
                }
            }
            if (new_here) |item| {
                action.kind = .write;
                action.entry = .{ .mode = normalMode(item.mode), .size = 0, .id = item.id, .path = path };
            } else {
                action.kind = .delete;
                action.entry = entry_here.?;
            }
        } else {
            sayLost(git, path, "has a change in the index");
            lost += 1;
            decided = false;
        }
        if (decided and lost == 0) {
            const copied = arena.copy(path) orelse return noMemory(git);
            action.entry.path = copied;
            const made = arena.create(Action, action) orelse return noMemory(git);
            if (last) |previous| previous.next = made else first = made;
            last = made;
        }
        if (old_here != null) old_item = old_walk.nextFile();
        if (new_here != null) new_item = new_walk.nextFile();
        if (entry_here != null) entry = entries.next();
    }
    if (old_walk.failed or new_walk.failed) return false;
    if (entries.bad()) {
        git.say("the index is broken\n", .{});
        return false;
    }
    if (lost != 0) {
        git.say("nothing was changed: commit those changes, or undo them, first\n", .{});
        return false;
    }

    // Pass 2: the files deleted, then written; the index made.
    var each = first;
    while (each) |action| : (each = action.next) {
        if (action.kind != .delete or action.entry.skip_worktree) continue;
        const local = work.localPath(&local_path, action.entry.path) orelse continue;
        _ = git.dl.DeleteFile(local);
        removeEmptyParents(work, action.entry.path);
    }
    var new_index: NewIndex = .{ .arena = .{ .sys = git.sys } };
    defer new_index.arena.free();
    each = first;
    while (each) |action| : (each = action.next) {
        switch (action.kind) {
            .delete => continue,
            .keep => {},
            .write => {
                var skip = !Work.allowed(action.entry.path);
                if (skip) refuse(git, action.entry.path, "is no name a dos volume holds");
                const local = if (skip) null else work.localPath(&local_path, action.entry.path);
                if (!skip and local == null) {
                    refuse(git, action.entry.path, "is too long a path here");
                    skip = true;
                }
                if (!skip and !files.makeDirs(git, local.?)) {
                    _ = git.dl.PrintFault(git.dl.IoErr(), local.?);
                    refuse(git, action.entry.path, "could not be made");
                    skip = true;
                }
                if (!skip) {
                    skip = if (action.entry.mode == object.mode_gitlink)
                        !work.makeSubmodule(action.entry.path, local.?)
                    else
                        !work.writeBlob(action.entry.path, local.?, &action.entry);
                }
                action.entry.skip_worktree = skip;
            },
        }
        _ = new_index.add(&action.entry) orelse return noMemory(git);
    }
    git.endProgress();
    return new_index.write(repo);
}

/// Whether an index entry and a tree's entry are alike, both absent too.
fn sameEntry(entry: ?index.Entry, item: ?Item) bool {
    if (entry == null and item == null) return true;
    const held = entry orelse return false;
    const given = item orelse return false;
    return held.mode == normalMode(given.mode) and _git.same(&held.id, &given.id);
}

fn sameItems(a: ?Item, b: ?Item) bool {
    if (a == null and b == null) return true;
    const first = a orelse return false;
    const second = b orelse return false;
    return normalMode(first.mode) == normalMode(second.mode) and _git.same(&first.id, &second.id);
}

fn sayLost(git: *Git, path: []const u8, why: []const u8) void {
    git.endProgress();
    git.put("Git: ");
    git.put(path);
    git.put(" ");
    git.put(why);
    git.put(": the change would be lost\n");
}

/// The directories `path` was in, removed where they became empty -
/// the work tree itself never.
pub fn removeEmptyParents(work: *Work, path: []const u8) void {
    var end = path.len;
    var local_path: files.Path = undefined;
    while (end > 0) {
        while (end > 0 and path[end - 1] != '/') end -= 1;
        if (end == 0) return;
        end -= 1;
        const local = work.localPath(&local_path, path[0..end]) orelse return;
        if (!work.git.dl.DeleteFile(local)) return;
    }
}
