// SPDX-License-Identifier: MIT
//! `Git clone URL [DIR] [DEPTH=n] [BRANCH=name] [QUIET]`: a remote
//! repository copied into a new one and its branch checked out.
//!
//! DIR is made, or must be empty; without it the URL's last part names
//! it, a `.git` at its end left off. The remote's branches become
//! `refs/remotes/origin/*` and its tags `refs/tags/*` (both in
//! `packed-refs`), the branch its HEAD names - or BRANCH, a branch or a
//! tag - is made and checked out, and `.git/config` names the remote as
//! `origin`. DEPTH=n fetches only the last n commits of that one branch
//! (`.git/shallow` lists where the history is cut).
//!
//! The pack comes in as incoming.zig takes it. What fails on the way
//! takes the new repository away again.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const object = @import("object.zig");
const transport = @import("transport.zig");
const incoming = @import("incoming.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const worktree = @import("worktree.zig");
const context = @import("context.zig");
const Connection = @import("connect.zig").Connection;
const repo_module = @import("repo.zig");
const Repository = repo_module.Repository;
const Git = context.Git;
const Id = _git.Id;

pub const template = "URL/A,DIR,DEPTH/K/N,BRANCH/K,QUIET/S";
const arg_url = 0;
const arg_dir = 1;
const arg_depth = 2;
const arg_branch = 3;
const arg_quiet = 4;
pub const arg_count = 5;

/// A ref the remote listed, copied.
const Advertised = struct {
    name: [:0]u8,
    id: Id,
    peeled: ?Id,
    target: ?[:0]u8,
    unborn: bool,
    next: ?*Advertised = null,
};

/// A commit the history is cut at.
const Cut = struct {
    id: Id,
    next: ?*Cut = null,
};

const Clone = struct {
    git: *Git,
    arena: context.Arena,
    url: [*:0]const u8,
    depth: u32,
    branch: ?[*:0]const u8,
    /// The work tree, as typed or taken from the URL.
    dir: files.Path,
    /// The directory was made here, not found empty.
    made_dir: bool = false,
    repo: ?*Repository = null,
    connection: ?*Connection = null,
    advertised: ?*Advertised = null,
    last_advertised: ?*Advertised = null,
    head: ?*Advertised = null,
    cuts: ?*Cut = null,
    cut_count: usize = 0,
    /// What is checked out: a branch's ref, or a tag's, or none (HEAD
    /// detached at `checkout_id`).
    checkout_ref: ?*Advertised = null,
    checkout_id: Id = _git.zero_id,
    detached: bool = false,
    /// Only the branch checked out is fetched and tracked.
    single: bool = false,

    /// The work tree named and made, or found empty.
    fn prepare(clone: *Clone, given: ?[*:0]const u8) bool {
        const git = clone.git;
        const dl = git.dl;
        const name = if (given) |text| files.span(text) else directoryOf(files.span(clone.url));
        if (name.len == 0) {
            git.say("no directory can be told from %s - name one\n", .{clone.url});
            return false;
        }
        _ = files.join(&clone.dir, &.{name}) orelse {
            git.say("the path is too long\n", .{});
            return false;
        };
        const dir: [*:0]const u8 = @ptrCast(&clone.dir);
        if (dl.Lock(dir, dos.SHARED_LOCK)) |lock| {
            defer dl.UnLock(lock);
            const fib = git.create(dos.FileInfoBlock) orelse return false;
            defer git.free(fib);
            if (!dl.Examine(lock, fib) or !dos.isDirectory(fib.dir_entry_type)) {
                git.say("%s exists and is no directory\n", .{dir});
                return false;
            }
            if (dl.ExNext(lock, fib)) {
                git.say("%s exists and is not empty\n", .{dir});
                return false;
            }
            return true;
        }
        var with_slash: files.Path = undefined;
        const path = files.join(&with_slash, &.{ name, "/" }) orelse return false;
        if (!files.makeDirs(git, path)) {
            _ = dl.PrintFault(dl.IoErr(), dir);
            return false;
        }
        clone.made_dir = true;
        return true;
    }

    fn close(clone: *Clone) void {
        if (clone.repo) |repo| repo.close();
        if (clone.connection) |connection| connection.close();
        clone.repo = null;
        clone.connection = null;
    }

    /// The clone, start to end: false, said, when it failed.
    fn work(clone: *Clone) bool {
        const git = clone.git;
        if (!git.quiet) {
            git.put("Cloning into ");
            git.put(files.span(@ptrCast(&clone.dir)));
            git.put("...\n");
        }
        const repo = Repository.open(git, files.span(@ptrCast(&clone.dir))) orelse return false;
        clone.repo = repo;
        if (!clone.repo.?.layOut("refs/heads/main")) return false;
        const connection = Connection.open(git, clone.url, "git-upload-pack") orelse return false;
        clone.connection = connection;
        if (!connection.remote.listRefs(&.{ "HEAD", "refs/heads/", "refs/tags/" }, collect, clone)) {
            connection.sayFailure();
            return false;
        }
        if (!clone.choose()) return false;
        if (clone.advertised == null) {
            // Nothing to fetch.
            git.say("the repository is empty\n", .{});
            return clone.writeRefs(null) and clone.writeConfig();
        }
        if (clone.checkout_ref == null and !clone.detached) {
            if (clone.single) {
                git.say("the remote's HEAD names no branch - name one with BRANCH\n", .{});
                return false;
            }
            git.say("the remote's HEAD names no branch: nothing is checked out\n", .{});
        }
        const pack_name = clone.fetch() orelse return false;
        connection.close();
        clone.connection = null;
        if (!clone.writeShallow()) return false;
        if (!clone.writeRefs(pack_name)) return false;
        if (!clone.writeConfig()) return false;
        if (clone.checkout_ref == null and !clone.detached) return true;
        return clone.checkOut();
    }

    fn find(clone: *Clone, name: []const u8) ?*Advertised {
        var each = clone.advertised;
        while (each) |ref| : (each = ref.next) {
            if (_git.same(ref.name, name)) return ref;
        }
        return null;
    }

    /// What is checked out: BRANCH, else the branch the remote's HEAD names.
    fn choose(clone: *Clone) bool {
        const git = clone.git;
        if (clone.branch) |branch| {
            var name: [refs.name_most + 1]u8 = undefined;
            for ([_][]const u8{ "refs/heads/", "refs/tags/" }) |prefix| {
                var out: _git.Out = .{ .into = &name };
                out.put(prefix);
                out.put(files.span(branch));
                if (out.overflow) continue;
                if (clone.find(out.written())) |ref| {
                    clone.checkout_ref = ref;
                    clone.checkout_id = ref.peeled orelse ref.id;
                    clone.detached = _git.startsWith(ref.name, "refs/tags/");
                    return true;
                }
            }
            git.say("the remote has no branch or tag %s\n", .{branch});
            return false;
        }
        const head = clone.head orelse return true;
        if (head.unborn) return true;
        if (head.target) |target| {
            if (clone.find(target)) |ref| {
                clone.checkout_ref = ref;
                clone.checkout_id = ref.id;
                return true;
            }
        }
        // HEAD without its target (an old server): the branch at its commit,
        // master or main first; else HEAD's commit itself.
        for ([_][]const u8{ "refs/heads/master", "refs/heads/main" }) |name| {
            if (clone.find(name)) |ref| {
                if (_git.same(&ref.id, &head.id)) {
                    clone.checkout_ref = ref;
                    clone.checkout_id = ref.id;
                    return true;
                }
            }
        }
        var each = clone.advertised;
        while (each) |ref| : (each = ref.next) {
            if (_git.startsWith(ref.name, "refs/heads/") and _git.same(&ref.id, &head.id)) {
                clone.checkout_ref = ref;
                clone.checkout_id = ref.id;
                return true;
            }
        }
        clone.checkout_id = head.id;
        clone.detached = true;
        return true;
    }

    /// Whether the ref is tracked: every branch and tag, or only the one
    /// checked out.
    fn tracked(clone: *const Clone, ref: *const Advertised) bool {
        if (clone.single) return clone.checkout_ref == ref;
        return _git.startsWith(ref.name, "refs/heads/") or _git.startsWith(ref.name, "refs/tags/");
    }

    /// The pack fetched and indexed: its name (`pack-<checksum>`).
    fn fetch(clone: *Clone) ?[]const u8 {
        const git = clone.git;
        const repo = clone.repo.?;
        // The wants: each tracked ref's commit once.
        var count: usize = 0;
        var each = clone.advertised;
        while (each) |ref| : (each = ref.next) {
            if (clone.tracked(ref)) count += 1;
        }
        const wants_memory = clone.arena.take(@sizeOf(Id) * (count + 1), @alignOf(Id)) orelse {
            git.say("no memory\n", .{});
            return null;
        };
        const wants: [*]Id = @ptrCast(@alignCast(wants_memory));
        var wanted: usize = 0;
        if (clone.detached and clone.checkout_ref == null) {
            wants[0] = clone.checkout_id;
            wanted = 1;
        }
        each = clone.advertised;
        while (each) |ref| : (each = ref.next) {
            if (!clone.tracked(ref)) continue;
            const seen = for (wants[0..wanted]) |*id| {
                if (_git.same(id, &ref.id)) break true;
            } else false;
            if (seen) continue;
            wants[wanted] = ref.id;
            wanted += 1;
        }

        const request: transport.Fetch = .{
            .wants = wants[0..wanted],
            .depth = clone.depth,
            .quiet = git.quiet,
            .boundary = cut,
            .boundary_context = clone,
        };
        return incoming.receive(repo, clone.connection.?, &request, &clone.arena);
    }

    /// `.git/shallow`: the commits the history is cut at, a line each.
    fn writeShallow(clone: *Clone) bool {
        if (clone.cut_count == 0) return true;
        const git = clone.git;
        const memory = clone.arena.take(clone.cut_count * 41, 1) orelse {
            git.say("no memory\n", .{});
            return false;
        };
        var at: usize = 0;
        var each = clone.cuts;
        while (each) |made| : (each = made.next) {
            _git.hexOf(&made.id, memory[at..][0..40]);
            memory[at + 40] = '\n';
            at += 41;
        }
        return refs.writeFile(clone.repo.?, "shallow", &.{memory[0..at]});
    }

    /// `packed-refs` - the remote's branches as `refs/remotes/origin/*`, its
    /// tags the store has - and the branch checked out, HEAD and
    /// `origin/HEAD` as loose refs.
    fn writeRefs(clone: *Clone, pack_name: ?[]const u8) bool {
        const repo = clone.repo.?;
        if (pack_name != null) {
            var count: usize = 0;
            var bytes: usize = 0;
            var each = clone.advertised;
            while (each) |ref| : (each = ref.next) {
                if (!clone.inPackedRefs(ref)) continue;
                count += 1;
                bytes += 41 + "refs/remotes/origin/".len + ref.name.len + 1 + 42;
            }
            const list_memory = clone.arena.take(@sizeOf(*Advertised) * (count + 1), @alignOf(*Advertised)) orelse return clone.noMemory();
            const list: [*]*Advertised = @ptrCast(@alignCast(list_memory));
            count = 0;
            each = clone.advertised;
            while (each) |ref| : (each = ref.next) {
                if (!clone.inPackedRefs(ref)) continue;
                list[count] = ref;
                count += 1;
            }
            _git.heapSort(*Advertised, list[0..count], {}, nameBefore);
            const head_line = "# pack-refs with: peeled fully-peeled sorted \n";
            const text = clone.arena.take(head_line.len + bytes, 1) orelse return clone.noMemory();
            var out: _git.Out = .{ .into = text[0 .. head_line.len + bytes] };
            out.put(head_line);
            // The branches first: refs/remotes/ sorts before refs/tags/.
            for ([_]bool{ true, false }) |branches| {
                for (list[0..count]) |ref| {
                    const branch = _git.startsWith(ref.name, "refs/heads/");
                    if (branch != branches) continue;
                    out.hex(&ref.id);
                    out.byte(' ');
                    if (branch) {
                        out.put("refs/remotes/origin/");
                        out.put(ref.name["refs/heads/".len..]);
                    } else {
                        out.put(ref.name);
                    }
                    out.byte('\n');
                    if (ref.peeled) |*peeled| {
                        out.byte('^');
                        out.hex(peeled);
                        out.byte('\n');
                    }
                }
            }
            if (!refs.writeFile(repo, "packed-refs", &.{out.written()})) return false;
        }

        if (clone.detached) {
            return refs.write(repo, "HEAD", &clone.checkout_id);
        }
        const branch_name = if (clone.checkout_ref) |ref|
            ref.name
        else if (clone.head) |head|
            head.target orelse "refs/heads/main"
        else
            "refs/heads/main";
        if (clone.checkout_ref) |ref| {
            if (!refs.write(repo, ref.name, &ref.id)) return false;
            // origin/HEAD names the remote's own HEAD branch, when that is
            // tracked.
            if (clone.head) |head| {
                if (head.target) |target| {
                    if (_git.startsWith(target, "refs/heads/") and (!clone.single or _git.same(target, ref.name))) {
                        var name: [refs.name_most + 1]u8 = undefined;
                        var out: _git.Out = .{ .into = &name };
                        out.put("refs/remotes/origin/");
                        out.put(target["refs/heads/".len..]);
                        if (!out.overflow and !refs.writeSymbolic(repo, "refs/remotes/origin/HEAD", out.written())) return false;
                    }
                }
            }
        }
        return refs.writeSymbolic(repo, "HEAD", branch_name);
    }

    /// Whether a ref goes into `packed-refs`: tracked, and - a tag - its
    /// object fetched.
    fn inPackedRefs(clone: *Clone, ref: *const Advertised) bool {
        if (_git.startsWith(ref.name, "refs/heads/")) return clone.tracked(ref);
        if (!_git.startsWith(ref.name, "refs/tags/")) return false;
        return clone.repo.?.objects.has(&ref.id);
    }

    fn noMemory(clone: *Clone) bool {
        clone.git.say("no memory\n", .{});
        return false;
    }

    /// `.git/config`: the core settings for a dos volume, the remote, the
    /// branch's upstream.
    fn writeConfig(clone: *Clone) bool {
        const repo = clone.repo.?;
        var tail: [2 * refs.name_most + 256]u8 = undefined;
        var out: _git.Out = .{ .into = &tail };
        if (clone.single and clone.checkout_ref != null) {
            const name = clone.checkout_ref.?.name;
            if (_git.startsWith(name, "refs/heads/")) {
                const short = name["refs/heads/".len..];
                out.put("\tfetch = +refs/heads/");
                out.put(short);
                out.put(":refs/remotes/origin/");
                out.put(short);
                out.byte('\n');
            } else {
                out.put("\tfetch = +");
                out.put(name);
                out.byte(':');
                out.put(name);
                out.byte('\n');
            }
        } else {
            out.put("\tfetch = +refs/heads/*:refs/remotes/origin/*\n");
        }
        if (!clone.detached) {
            if (clone.checkout_ref) |ref| {
                out.put("[branch \"");
                out.put(ref.name["refs/heads/".len..]);
                out.put("\"]\n\tremote = origin\n\tmerge = ");
                out.put(ref.name);
                out.byte('\n');
            }
        }
        if (out.overflow) {
            clone.git.say("a branch's name is too long\n", .{});
            return false;
        }
        return refs.writeFile(repo, "config", &.{ repo_module.core_config, "[remote \"origin\"]\n\turl = ", files.span(clone.url), "\n", out.written() });
    }

    /// The commit checked out into the work tree.
    fn checkOut(clone: *Clone) bool {
        const git = clone.git;
        const repo = clone.repo.?;
        var commit = repo.objects.read(&clone.checkout_id) orelse return false;
        defer commit.free(git.sys);
        if (commit.kind != .commit) {
            git.say("the ref checked out names no commit\n", .{});
            return false;
        }
        const parsed = object.parseCommit(commit.data) orelse {
            git.say("the commit checked out is broken\n", .{});
            return false;
        };
        return worktree.populate(repo, &parsed.tree);
    }
};

pub fn run(git: *Git, argv: []const usize) i32 {
    git.quiet = argv[arg_quiet] != 0;
    const clone = git.create(Clone) orelse return dos.RETURN_FAIL;
    defer git.free(clone);
    clone.* = .{
        .git = git,
        .arena = .{ .sys = git.sys },
        .url = @ptrFromInt(argv[arg_url]),
        .depth = 0,
        .branch = if (argv[arg_branch] != 0) @ptrFromInt(argv[arg_branch]) else null,
        .dir = undefined,
    };
    defer clone.arena.free();
    if (argv[arg_depth] != 0) {
        const depth = @as(*const i32, @ptrFromInt(argv[arg_depth])).*;
        if (depth < 1) {
            git.say("DEPTH must be 1 or more\n", .{});
            return dos.RETURN_ERROR;
        }
        clone.depth = @intCast(depth);
        clone.single = true;
    }
    const given: ?[*:0]const u8 = if (argv[arg_dir] != 0) @ptrFromInt(argv[arg_dir]) else null;
    if (!clone.prepare(given)) return dos.RETURN_ERROR;
    if (clone.work()) {
        clone.close();
        return dos.RETURN_OK;
    }
    clone.close();
    // What was made, taken away again; a directory found empty is left.
    if (!files.removeTree(git, @ptrCast(&clone.dir), !clone.made_dir)) {
        _ = git.dl.PrintFault(git.dl.IoErr(), @ptrCast(&clone.dir));
    }
    return dos.RETURN_ERROR;
}

/// The directory a URL's repository is cloned into: its last part, a
/// `.git` at the end left off.
fn directoryOf(url_text: []const u8) []const u8 {
    var text = url_text;
    while (text.len > 0 and (text[text.len - 1] == '/' or text[text.len - 1] == ' ')) text = text[0 .. text.len - 1];
    if (text.len >= 5 and _git.same(text[text.len - 5 ..], "/.git")) text = text[0 .. text.len - 5];
    var start = text.len;
    while (start > 0 and text[start - 1] != '/' and text[start - 1] != ':') start -= 1;
    var name = text[start..];
    if (name.len > 4 and _git.same(name[name.len - 4 ..], ".git")) name = name[0 .. name.len - 4];
    return name;
}

fn collect(opaque_clone: *anyopaque, ref: *const transport.Ref) bool {
    const clone: *Clone = @ptrCast(@alignCast(opaque_clone));
    const arena = &clone.arena;
    const name = arena.copy(ref.name) orelse return false;
    const target = if (ref.target) |text| (arena.copy(text) orelse return false) else null;
    const made = arena.create(Advertised, .{
        .name = name,
        .id = ref.id,
        .peeled = ref.peeled,
        .target = target,
        .unborn = ref.unborn,
    }) orelse return false;
    if (_git.same(name, "HEAD")) {
        clone.head = made;
    } else {
        if (clone.last_advertised) |last| last.next = made else clone.advertised = made;
        clone.last_advertised = made;
    }
    return !clone.git.stopped();
}

fn cut(opaque_clone: *anyopaque, id: *const Id, shallow: bool) bool {
    const clone: *Clone = @ptrCast(@alignCast(opaque_clone));
    if (!shallow) return true;
    const made = clone.arena.create(Cut, .{ .id = id.*, .next = clone.cuts }) orelse return false;
    clone.cuts = made;
    clone.cut_count += 1;
    return true;
}

fn nameBefore(_: void, a: *const *Advertised, b: *const *Advertised) bool {
    return _git.order(a.*.name, b.*.name) == .less;
}
