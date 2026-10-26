// SPDX-License-Identifier: MIT
//! `Git push [REMOTE] [REFS/M] [FORCE] [TAGS] [SETUPSTREAM] [QUIET]`:
//! refs of this
//! repository set on a remote, the objects it lacks sent with them.
//! REMOTE is a remote of `.git/config` or a URL; without it, the current
//! branch's remote, `origin` without one. Each of REFS is
//! `[+]local[:remote]` - a branch or tag here (HEAD for the current
//! branch), and the name it gets there, the same without one; a short
//! name there is a branch, or a tag when the one here is. Without REFS
//! the current branch goes to its upstream when that is on the remote,
//! to its own name otherwise. TAGS sends every tag too.
//!
//! A branch the remote has moves only forward: one at a commit this
//! repository does not have, or one the new commit does not descend
//! from, is refused - unless FORCE, or `+` before it, says to set it
//! anyway. A tag the remote has at another object is refused the same
//! way. What goes is made a pack (outgoing.zig) and sent with the refs,
//! and the server answers for each. The refs of a remote of the config
//! that its fetch refspecs map (`refs/remotes/origin/main`) are set to
//! what the server took; with SETUPSTREAM each branch pushed follows the
//! one it was pushed to, as `pull` and `status` see it.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const object = @import("object.zig");
const transport = @import("transport.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const history = @import("history.zig");
const fetch = @import("fetch.zig");
const outgoing_module = @import("outgoing.zig");
const config_module = @import("config.zig");
const log = @import("log.zig");
const context = @import("context.zig");
const Connection = @import("connect.zig").Connection;
const Repository = @import("repo.zig").Repository;
const Git = context.Git;
const Id = _git.Id;

pub const template = "REMOTE,REFS/M,FORCE/S,TAGS/S,SETUPSTREAM=U/S,QUIET/S";
const arg_remote = 0;
const arg_refs = 1;
const arg_force = 2;
const arg_tags = 3;
const arg_setupstream = 4;
const arg_quiet = 5;
pub const arg_count = 6;

const url_most = 2048;
const specs_most = 16;
/// How many tags a tag may name before what it tags.
const peel_most = 8;

/// What becomes of a ref there.
const Outcome = enum {
    up_to_date,
    new_branch,
    new_tag,
    new_ref,
    forward,
    forced,
    /// The new commit does not descend from the remote's.
    behind,
    /// The remote's commit is not here.
    unknown,
    /// The remote has the tag, at another object.
    exists,

    fn goes(outcome: Outcome) bool {
        return switch (outcome) {
            .new_branch, .new_tag, .new_ref, .forward, .forced => true,
            else => false,
        };
    }
};

/// A ref to set there.
const Going = struct {
    /// Its name here, and there.
    local: []const u8,
    name: []const u8,
    new: Id,
    old: Id = _git.zero_id,
    force: bool,
    outcome: Outcome = .up_to_date,
    /// What was sent of it, with the server's answer.
    sent: ?*transport.Update = null,
};

/// A ref the remote listed.
const Listed = struct {
    name: []const u8,
    id: Id,
    next: ?*Listed,
};

const Pushing = struct {
    git: *Git,
    repo: *Repository,
    arena: context.Arena,
    force: bool,
    quiet: bool,
    /// The remote's name in the config; null for a URL given.
    remote_name: ?[]const u8 = null,
    url: [url_most + 1]u8 = undefined,
    specs: [specs_most]fetch.Spec = undefined,
    spec_count: usize = 0,
    /// The current branch's upstream there, when it has one.
    upstream: ?[]const u8 = null,
    goings: []Going = &.{},
    count: usize = 0,
    listed: ?*Listed = null,
    updates: []transport.Update = &.{},

    fn finish(pushing: *Pushing) void {
        const git = pushing.git;
        pushing.arena.free();
        git.free(pushing);
    }

    fn noMemory(pushing: *Pushing) bool {
        pushing.git.say("no memory\n", .{});
        return false;
    }

    /// The remote: `given`, or the current branch's, or `origin` - a
    /// remote of the config, or a URL.
    fn findRemote(pushing: *Pushing, given: ?[]const u8, head: *const refs.Head) bool {
        const git = pushing.git;
        var config: config_module.Config = undefined;
        config.read(pushing.repo, git);
        defer config.free();
        var remote_value: [refs.name_most + 1]u8 = undefined;
        var short: ?[]const u8 = null;
        if (head.branch) |branch| short = log.shortName(branch);
        const name = given orelse blk: {
            if (short) |branch| {
                if (config.get("branch", branch, "remote", &remote_value)) |remote| break :blk remote;
            }
            break :blk "origin";
        };
        if (config.get("remote", name, "url", pushing.url[0..url_most])) |url_text| {
            pushing.url[url_text.len] = 0;
            pushing.remote_name = pushing.arena.copy(name) orelse return pushing.noMemory();
            var value: [512]u8 = undefined;
            config.each("remote", name, "fetch", &value, takeSpec, pushing);
            if (short) |branch| {
                var branch_remote: [refs.name_most + 1]u8 = undefined;
                var merge_value: [refs.name_most + 1]u8 = undefined;
                if (config.get("branch", branch, "remote", &branch_remote)) |remote| {
                    if (_git.same(remote, name)) {
                        if (config.get("branch", branch, "merge", &merge_value)) |merge| {
                            pushing.upstream = pushing.arena.copy(merge) orelse return pushing.noMemory();
                        }
                    }
                }
            }
            return true;
        }
        // A URL, or a path: anything with a colon or a slash.
        var url_like = false;
        for (name) |char| {
            if (char == ':' or char == '/') url_like = true;
        }
        if (given == null or !url_like or name.len > url_most) {
            git.say("there is no remote ", .{});
            git.put(name);
            git.put(" in .git/config (Git remote add NAME URL makes one)\n");
            return false;
        }
        @memcpy(pushing.url[0..name.len], name);
        pushing.url[name.len] = 0;
        return true;
    }

    /// `name` here set as `there` on the remote; the same name twice
    /// there is one.
    fn add(pushing: *Pushing, name: []const u8, there: []const u8, id: *const Id, force: bool) bool {
        for (pushing.goings[0..pushing.count]) |*going| {
            if (_git.same(going.name, there)) return true;
        }
        if (pushing.count == pushing.goings.len) {
            const size = if (pushing.goings.len == 0) 16 else pushing.goings.len * 2;
            const memory = pushing.arena.take(size * @sizeOf(Going), @alignOf(Going)) orelse return pushing.noMemory();
            const grown = @as([*]Going, @ptrCast(@alignCast(memory)))[0..size];
            @memcpy(grown[0..pushing.count], pushing.goings[0..pushing.count]);
            pushing.goings = grown;
        }
        pushing.goings[pushing.count] = .{
            .local = pushing.arena.copy(name) orelse return pushing.noMemory(),
            .name = pushing.arena.copy(there) orelse return pushing.noMemory(),
            .new = id.*,
            .force = force,
        };
        pushing.count += 1;
        return true;
    }

    /// The current branch, to its upstream or its own name.
    fn addCurrent(pushing: *Pushing, head: *const refs.Head) bool {
        const git = pushing.git;
        const branch = head.branch orelse {
            git.say("HEAD is on no branch: name what to push, and where (HEAD:main)\n", .{});
            return false;
        };
        const id = head.id orelse {
            git.say("", .{});
            git.put(log.shortName(branch));
            git.put(" has no commit yet: nothing to push\n");
            return false;
        };
        return pushing.add(branch, pushing.upstream orelse branch, &id, false);
    }

    /// `[+]local[:remote]`.
    fn addSpec(pushing: *Pushing, text: []const u8, head: *const refs.Head) bool {
        const git = pushing.git;
        var rest = text;
        var force = false;
        if (rest.len > 0 and rest[0] == '+') {
            force = true;
            rest = rest[1..];
        }
        var colon: usize = 0;
        while (colon < rest.len and rest[colon] != ':') colon += 1;
        const source = rest[0..colon];
        const there = if (colon < rest.len) rest[colon + 1 ..] else "";
        var full: [refs.name_most + 1]u8 = undefined;
        full[0] = 0;
        const id = refs.expand(pushing.repo, source, &full) orelse {
            git.say("", .{});
            git.put(source);
            git.put(" names nothing here\n");
            return false;
        };
        var local = files.span(@ptrCast(&full));
        // HEAD is the branch it is on.
        if (_git.same(local, "HEAD")) {
            if (head.branch) |branch| local = branch;
        }
        if (!_git.startsWith(local, "refs/")) {
            if (there.len == 0 or !_git.startsWith(there, "refs/")) {
                git.say("", .{});
                git.put(source);
                git.put(" is no branch or tag: name it there in full (");
                git.put(source);
                git.put(":refs/heads/name)\n");
                return false;
            }
        }
        if (there.len == 0) return pushing.add(local, local, &id, force);
        if (_git.startsWith(there, "refs/")) return pushing.add(local, there, &id, force);
        var name: [refs.name_most + 1]u8 = undefined;
        var out: _git.Out = .{ .into = name[0..refs.name_most] };
        out.put(if (_git.startsWith(local, "refs/tags/")) "refs/tags/" else "refs/heads/");
        out.put(there);
        if (out.overflow) {
            git.say("the name is too long\n", .{});
            return false;
        }
        return pushing.add(local, out.written(), &id, force);
    }

    /// Every tag here.
    fn addTags(pushing: *Pushing) bool {
        const tags = refs.list(pushing.repo, "refs/tags/", &pushing.arena) orelse return false;
        for (tags) |*tag| {
            const id = tag.id orelse continue;
            if (!pushing.add(tag.name, tag.name, &id, false)) return false;
        }
        return true;
    }

    fn listedId(pushing: *const Pushing, name: []const u8) ?Id {
        var each = pushing.listed;
        while (each) |ref| : (each = ref.next) {
            if (_git.same(ref.name, name)) return ref.id;
        }
        return null;
    }

    /// What becomes of each ref: what the remote has against what goes.
    fn decide(pushing: *Pushing) bool {
        const repo = pushing.repo;
        for (pushing.goings[0..pushing.count]) |*going| {
            const old = pushing.listedId(going.name) orelse {
                going.outcome = if (_git.startsWith(going.name, "refs/heads/")) .new_branch else if (_git.startsWith(going.name, "refs/tags/")) .new_tag else .new_ref;
                continue;
            };
            going.old = old;
            const force = pushing.force or going.force;
            if (_git.same(&old, &going.new)) {
                going.outcome = .up_to_date;
            } else if (_git.startsWith(going.name, "refs/tags/")) {
                going.outcome = if (force) .forced else .exists;
            } else if (!repo.objects.has(&old)) {
                going.outcome = if (force) .forced else .unknown;
            } else {
                const forward = pushing.descends(&old, &going.new) orelse return false;
                going.outcome = if (forward) .forward else if (force) .forced else .behind;
            }
        }
        return true;
    }

    /// Whether the commit `new` descends from `old`: false when either
    /// is no commit; null, said, when the history cannot be read.
    fn descends(pushing: *Pushing, old: *const Id, new: *const Id) ?bool {
        const repo = pushing.repo;
        const git = pushing.git;
        for ([_]*const Id{ old, new }) |id| {
            var found = repo.objects.read(id) orelse return false;
            defer found.free(git.sys);
            if (found.kind != .commit) return false;
        }
        return history.isAncestor(repo, old, new);
    }

    /// The objects of what goes: the commits it names, and the tags on
    /// the way to them, which go themselves.
    fn tips(pushing: *Pushing, outgoing: *outgoing_module.Outgoing) ?[]Id {
        const git = pushing.git;
        const memory = pushing.arena.take(pushing.count * @sizeOf(Id) + 1, @alignOf(Id)) orelse {
            _ = pushing.noMemory();
            return null;
        };
        const list = @as([*]Id, @ptrCast(@alignCast(memory)))[0..pushing.count];
        var count: usize = 0;
        for (pushing.goings[0..pushing.count]) |*going| {
            if (!going.outcome.goes()) continue;
            var current = going.new;
            for (0..peel_most) |_| {
                var found = pushing.repo.objects.read(&current) orelse {
                    git.say("the repository does not have the object ", .{});
                    git.put(log.shortName(going.local));
                    git.put(" names\n");
                    return null;
                };
                defer found.free(git.sys);
                switch (found.kind) {
                    .commit => {
                        list[count] = current;
                        count += 1;
                        break;
                    },
                    .tag => {
                        if (!outgoing.include(&current)) return null;
                        const tag = object.parseTag(found.data) orelse {
                            git.say("a tag is broken\n", .{});
                            return null;
                        };
                        current = tag.object;
                    },
                    else => {
                        git.say("", .{});
                        git.put(log.shortName(going.local));
                        git.put(" names no commit: only commits, and tags of them, are pushed\n");
                        return null;
                    },
                }
            }
        }
        return list[0..count];
    }

    /// The commits the remote's refs name that are here: what it has.
    fn known(pushing: *Pushing) ?[]Id {
        const git = pushing.git;
        const repo = pushing.repo;
        var count: usize = 0;
        var each = pushing.listed;
        while (each) |ref| : (each = ref.next) count += 1;
        const memory = pushing.arena.take(count * @sizeOf(Id) + 1, @alignOf(Id)) orelse {
            _ = pushing.noMemory();
            return null;
        };
        const list = @as([*]Id, @ptrCast(@alignCast(memory)))[0..count];
        count = 0;
        each = pushing.listed;
        while (each) |ref| : (each = ref.next) {
            var current = ref.id;
            for (0..peel_most) |_| {
                if (!repo.objects.has(&current)) break;
                var found = repo.objects.read(&current) orelse break;
                defer found.free(git.sys);
                if (found.kind == .commit) {
                    list[count] = current;
                    count += 1;
                    break;
                }
                if (found.kind != .tag) break;
                const tag = object.parseTag(found.data) orelse break;
                current = tag.object;
            }
        }
        return list[0..count];
    }

    /// The updates sent, one for each ref that goes.
    fn makeUpdates(pushing: *Pushing) bool {
        var count: usize = 0;
        for (pushing.goings[0..pushing.count]) |*going| count += @intFromBool(going.outcome.goes());
        const memory = pushing.arena.take(count * @sizeOf(transport.Update) + 1, @alignOf(transport.Update)) orelse return pushing.noMemory();
        pushing.updates = @as([*]transport.Update, @ptrCast(@alignCast(memory)))[0..count];
        count = 0;
        for (pushing.goings[0..pushing.count]) |*going| {
            if (!going.outcome.goes()) continue;
            pushing.updates[count] = .{ .name = going.name, .old = going.old, .new = going.new };
            going.sent = &pushing.updates[count];
            count += 1;
        }
        return true;
    }

    /// `To <url>` and a line for each ref but those up to date.
    fn show(pushing: *Pushing, shown_url: []const u8) void {
        const git = pushing.git;
        var width: usize = fetch.name_width;
        var shown: u32 = 0;
        for (pushing.goings[0..pushing.count]) |*going| {
            if (!pushing.shows(going)) continue;
            width = @max(width, log.shortName(going.local).len);
            shown += 1;
        }
        if (shown == 0) return;
        git.endProgress();
        git.put("To ");
        git.put(shown_url);
        git.put("\n");
        for (pushing.goings[0..pushing.count]) |*going| {
            if (!pushing.shows(going)) continue;
            var range: [fetch.summary_width + 1]u8 = undefined;
            var flag: []const u8, var summary: []const u8, var note: []const u8 = switch (going.outcome) {
                .up_to_date => .{ "=", "[up to date]", "" },
                .new_branch => .{ "*", "[new branch]", "" },
                .new_tag => .{ "*", "[new tag]", "" },
                .new_ref => .{ "*", "[new reference]", "" },
                .forward => .{ " ", fetch.rangeText(&range, &going.old, &going.new, ".."), "" },
                .forced => .{ "+", fetch.rangeText(&range, &going.old, &going.new, "..."), "forced update" },
                .behind => .{ "!", "[rejected]", "non-fast-forward" },
                .unknown => .{ "!", "[rejected]", "fetch first" },
                .exists => .{ "!", "[rejected]", "already exists" },
            };
            if (going.sent) |update| {
                if (update.status == .refused) {
                    flag = "!";
                    summary = "[remote rejected]";
                    note = update.reasonText();
                }
            }
            git.put(" ");
            git.put(flag);
            git.put(" ");
            git.put(summary);
            fetch.pad(git, summary.len, fetch.summary_width);
            git.put(" ");
            const local = log.shortName(going.local);
            git.put(local);
            fetch.pad(git, local.len, width);
            git.put(" -> ");
            git.put(log.shortName(going.name));
            if (note.len != 0) {
                git.put(" (");
                git.put(note);
                git.put(")");
            }
            git.put("\n");
        }
    }

    /// Each branch pushed, or there already, set to follow the branch
    /// it went to: false, said, when the config could not be written.
    fn setUpstream(pushing: *Pushing) bool {
        const git = pushing.git;
        const remote = pushing.remote_name.?;
        for (pushing.goings[0..pushing.count]) |*going| {
            const there = if (going.sent) |update| update.status == .done else going.outcome == .up_to_date;
            if (!there) continue;
            if (!_git.startsWith(going.local, "refs/heads/") or !_git.startsWith(going.name, "refs/heads/")) continue;
            const branch = log.shortName(going.local);
            var lines: [3 * refs.name_most + 64]u8 = undefined;
            var out: _git.Out = .{ .into = &lines };
            out.put("[branch \"");
            out.put(branch);
            out.put("\"]\n\tremote = ");
            out.put(remote);
            out.put("\n\tmerge = ");
            out.put(going.name);
            out.byte('\n');
            if (!config_module.edit(pushing.repo, "branch", branch, &.{ "remote", "merge" }, out.written())) return false;
            if (!git.quiet) {
                git.put("branch '");
                git.put(branch);
                git.put("' set up to track '");
                git.put(remote);
                git.put("/");
                git.put(log.shortName(going.name));
                git.put("'.\n");
            }
        }
        return true;
    }

    /// QUIET shows only what was refused.
    fn shows(pushing: *const Pushing, going: *const Going) bool {
        if (going.outcome == .up_to_date) return false;
        if (!pushing.quiet) return true;
        if (!going.outcome.goes()) return true;
        if (going.sent) |update| return update.status == .refused;
        return false;
    }

    /// The remote's refs here (`refs/remotes/origin/main`) set to what
    /// it took, or had already.
    fn track(pushing: *Pushing) void {
        if (pushing.remote_name == null) return;
        for (pushing.goings[0..pushing.count]) |*going| {
            const there = if (going.sent) |update| update.status == .done else going.outcome == .up_to_date;
            if (!there) continue;
            for (pushing.specs[0..pushing.spec_count]) |*spec| {
                var name: [refs.name_most + 1]u8 = undefined;
                const tracking = spec.map(going.name, name[0..refs.name_most]) orelse continue;
                if (!_git.startsWith(tracking, "refs/remotes/")) continue;
                _ = refs.write(pushing.repo, tracking, &going.new);
                break;
            }
        }
    }
};

fn takeSpec(opaque_pushing: *anyopaque, text: []const u8) bool {
    const pushing: *Pushing = @ptrCast(@alignCast(opaque_pushing));
    if (pushing.spec_count == specs_most) return false;
    const kept = pushing.arena.copy(text) orelse return false;
    const spec = fetch.Spec.parse(kept) orelse return true;
    pushing.specs[pushing.spec_count] = spec;
    pushing.spec_count += 1;
    return true;
}

fn collect(opaque_pushing: *anyopaque, ref: *const transport.Ref) bool {
    const pushing: *Pushing = @ptrCast(@alignCast(opaque_pushing));
    const name = pushing.arena.copy(ref.name) orelse return pushing.noMemory();
    const listed = pushing.arena.create(Listed, .{ .name = name, .id = ref.id, .next = pushing.listed }) orelse return pushing.noMemory();
    pushing.listed = listed;
    return true;
}

/// The pack's file, read in pieces.
const PackFile = struct {
    git: *Git,
    file: *dos.FileHandle,

    fn read(opaque_file: *anyopaque, into: []u8) i32 {
        const pack_file: *PackFile = @ptrCast(@alignCast(opaque_file));
        return @intCast(pack_file.git.dl.Read(pack_file.file, into.ptr, @intCast(into.len)));
    }
};

pub fn run(git: *Git, argv: []const usize) i32 {
    const dl = git.dl;
    git.quiet = argv[arg_quiet] != 0;
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    const pushing = git.create(Pushing) orelse return dos.RETURN_ERROR;
    pushing.* = .{ .git = git, .repo = repo, .arena = .{ .sys = git.sys }, .force = argv[arg_force] != 0, .quiet = git.quiet };
    defer pushing.finish();
    var head: refs.Head = .{};
    if (!refs.head(repo, &head)) {
        git.say("HEAD cannot be read\n", .{});
        return dos.RETURN_ERROR;
    }
    const given_remote: ?[]const u8 = if (argv[arg_remote] != 0) files.span(@ptrFromInt(argv[arg_remote])) else null;
    if (!pushing.findRemote(given_remote, &head)) return dos.RETURN_ERROR;
    const setupstream = argv[arg_setupstream] != 0;
    if (setupstream and pushing.remote_name == null) {
        git.say("SETUPSTREAM needs a remote of .git/config to follow (Git remote add NAME URL)\n", .{});
        return dos.RETURN_ERROR;
    }

    // What goes.
    const given_refs = dos.rdargs.multi(argv[arg_refs]);
    if (given_refs.len == 0 and argv[arg_tags] == 0) {
        if (!pushing.addCurrent(&head)) return dos.RETURN_ERROR;
    }
    for (given_refs) |text| {
        if (!pushing.addSpec(files.span(text), &head)) return dos.RETURN_ERROR;
    }
    if (argv[arg_tags] != 0 and !pushing.addTags()) return dos.RETURN_ERROR;

    const connection = Connection.open(git, @ptrCast(&pushing.url), "git-receive-pack") orelse return dos.RETURN_ERROR;
    defer connection.close();
    const remote = &connection.remote;
    if (!remote.listRefs(&.{}, collect, pushing)) {
        connection.sayFailure();
        return dos.RETURN_ERROR;
    }
    if (!pushing.decide()) return dos.RETURN_ERROR;
    const shown_url = connection.remote_url.text();
    var refused: u32 = 0;
    var going_count: u32 = 0;
    var why: Outcome = .up_to_date;
    for (pushing.goings[0..pushing.count]) |*going| {
        if (going.outcome.goes()) going_count += 1;
        if (going.outcome == .behind or going.outcome == .unknown or going.outcome == .exists) {
            refused += 1;
            why = going.outcome;
        }
    }
    if (going_count == 0) {
        pushing.show(shown_url);
        if (refused == 0) {
            pushing.track();
            if (!git.quiet) git.put("Everything up-to-date\n");
            if (setupstream and !pushing.setUpstream()) return dos.RETURN_ERROR;
            return dos.RETURN_OK;
        }
        return notPushed(git, shown_url, why);
    }

    // The pack, and the refs with it.
    const outgoing = git.create(outgoing_module.Outgoing) orelse return dos.RETURN_ERROR;
    defer git.free(outgoing);
    outgoing.init(repo);
    defer outgoing.deinit();
    const tip_ids = pushing.tips(outgoing) orelse return dos.RETURN_ERROR;
    const known_ids = pushing.known() orelse return dos.RETURN_ERROR;
    if (!outgoing.collect(tip_ids, known_ids)) return dos.RETURN_ERROR;
    if (!outgoing.write()) return dos.RETURN_ERROR;
    if (!pushing.makeUpdates()) return dos.RETURN_ERROR;
    const file = dl.Open(@ptrCast(&outgoing.path), dos.MODE_OLDFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), @ptrCast(&outgoing.path));
        return dos.RETURN_ERROR;
    };
    defer _ = dl.Close(file);
    var pack_file: PackFile = .{ .git = git, .file = file };
    var request: transport.Push = .{
        .updates = pushing.updates,
        .pack = .{ .context = &pack_file, .length = outgoing.size, .read = PackFile.read },
        .quiet = git.quiet,
    };
    if (!remote.push(&request)) {
        // Why a Read of the pack failed, kept from the progress line's end.
        const failure = dl.IoErr();
        git.endProgress();
        _ = dl.SetIoErr(failure);
        connection.sayFailure();
        return dos.RETURN_ERROR;
    }
    pushing.track();
    pushing.show(shown_url);
    if (setupstream and !pushing.setUpstream()) return dos.RETURN_ERROR;
    for (pushing.updates) |*update| {
        if (update.status == .refused) refused += 1;
    }
    if (refused != 0) return notPushed(git, shown_url, why);
    return dos.RETURN_OK;
}

/// Some refs were not pushed: said, with what to do about the reason
/// Git refused one for.
fn notPushed(git: *Git, shown_url: []const u8, why: Outcome) i32 {
    git.say("some refs were not pushed to ", .{});
    git.put(shown_url);
    git.put("\n");
    switch (why) {
        .behind => git.put("  The remote has commits the branch does not: Git pull, then push again - or FORCE to drop them.\n"),
        .unknown => git.put("  The remote has commits this repository does not: Git fetch them first.\n"),
        .exists => git.put("  The remote has the tag already, at another object: FORCE moves it.\n"),
        else => {},
    }
    return dos.RETURN_ERROR;
}
