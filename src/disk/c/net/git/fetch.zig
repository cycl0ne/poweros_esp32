// SPDX-License-Identifier: MIT
//! `Git fetch [REMOTE] [DEPTH=n] [QUIET]`: what a remote - without one,
//! the current branch's, else `origin` - has that the repository has
//! not, fetched, and its refs
//! brought up to date. The remote's URL and refspecs are its
//! `[remote "<name>"]` section of `.git/config`; each refspec
//! (`+refs/heads/*:refs/remotes/origin/*`) maps the remote's refs to the
//! repository's, a `+` letting one move to a commit that does not
//! follow on from the one it held.
//!
//! The commits asked for are those the refs name that the store does
//! not have; the commits it has - the refs' own, and the history behind
//! them, up to 256 - are offered, so only what is new comes. The
//! remote's tags come along with what they name; a tag naming a commit
//! that was here before is asked for after. An existing tag is never
//! moved. A shallow repository says where its history is cut, and keeps
//! `.git/shallow` as the server moves the cut; DEPTH=n cuts it n commits
//! from each ref anew.
//!
//! Each ref that changed is shown in a line - `old..new` moved on,
//! `[new branch]`, `+ old...new (forced update)`, `! [rejected]` - and
//! `.git/FETCH_HEAD` lists the branches fetched, the current branch's
//! upstream first. A URL is shown without its user and token.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const object = @import("object.zig");
const transport = @import("transport.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const history = @import("history.zig");
const incoming = @import("incoming.zig");
const config_module = @import("config.zig");
const log = @import("log.zig");
const context = @import("context.zig");
const Connection = @import("connect.zig").Connection;
const Repository = @import("repo.zig").Repository;
const Git = context.Git;
const Id = _git.Id;

pub const template = "REMOTE,DEPTH/K/N,QUIET/S";
const arg_remote = 0;
const arg_depth = 1;
const arg_quiet = 2;
pub const arg_count = 3;

const specs_most = 16;
const haves_most = 256;
const url_most = 2048;
const shallow_most = 64 * 1024 * 1024;
/// How many tags a tag may name before a commit.
const peel_most = 8;
/// The summary column: `1234567..89abcde`.
pub const summary_width = 17;
/// The remote's names' column, at least.
pub const name_width = 10;

/// A refspec: `[+]source:destination`, each with at most one `*`.
pub const Spec = struct {
    force: bool,
    source: []const u8,
    destination: []const u8,

    pub fn parse(text: []const u8) ?Spec {
        var rest = text;
        var force = false;
        if (rest.len > 0 and rest[0] == '+') {
            force = true;
            rest = rest[1..];
        }
        var colon: usize = 0;
        while (colon < rest.len and rest[colon] != ':') colon += 1;
        if (colon == rest.len or colon == 0 or colon + 1 == rest.len) return null;
        const spec: Spec = .{ .force = force, .source = rest[0..colon], .destination = rest[colon + 1 ..] };
        if ((starOf(spec.source) == null) != (starOf(spec.destination) == null)) return null;
        return spec;
    }

    /// The part of the source before its `*`, for the remote's listing.
    fn prefix(spec: *const Spec) []const u8 {
        return if (starOf(spec.source)) |star| spec.source[0..star] else spec.source;
    }

    /// `name` mapped into `into`; null when the spec does not take it.
    pub fn map(spec: *const Spec, name: []const u8, into: []u8) ?[]const u8 {
        var out: _git.Out = .{ .into = into };
        const star = starOf(spec.source) orelse {
            if (!_git.same(name, spec.source)) return null;
            out.put(spec.destination);
            return if (out.overflow) null else out.written();
        };
        const head = spec.source[0..star];
        const tail = spec.source[star + 1 ..];
        if (name.len < head.len + tail.len or !_git.startsWith(name, head) or !_git.endsWith(name, tail)) return null;
        const destination_star = starOf(spec.destination).?;
        out.put(spec.destination[0..destination_star]);
        out.put(name[head.len .. name.len - tail.len]);
        out.put(spec.destination[destination_star + 1 ..]);
        return if (out.overflow) null else out.written();
    }
};

fn starOf(text: []const u8) ?usize {
    for (text, 0..) |char, at| {
        if (char == '*') return at;
    }
    return null;
}

/// What became of a ref here.
const Outcome = enum {
    none,
    new_branch,
    new_tag,
    new_ref,
    forward,
    forced,
    rejected,
    rejected_tag,
};

/// A ref the remote listed, and where it goes here.
const Listed = struct {
    name: []const u8,
    id: Id,
    peeled: ?Id,
    /// The ref it updates here; null for one no spec takes.
    local: ?[]const u8 = null,
    force: bool = false,
    tag: bool = false,
    outcome: Outcome = .none,
    old: Id = undefined,
    next: ?*Listed = null,
};

/// A commit the history is cut at, as `.git/shallow` lists them.
const Cut = struct {
    id: Id,
    /// The server no longer cuts there.
    gone: bool = false,
    next: ?*Cut = null,
};

/// One fetch's state.
pub const Fetching = struct {
    git: *Git,
    repo: *Repository,
    arena: context.Arena,
    url: [url_most + 1]u8 = undefined,
    /// The URL without its user and token, as it is shown.
    shown_url: []const u8 = "",
    specs: [specs_most]Spec = undefined,
    spec_count: usize = 0,
    listed: ?*Listed = null,
    last: ?*Listed = null,
    depth: u32 = 0,
    shallow: ?*Cut = null,
    shallow_changed: bool = false,
    haves: ?[]const Id = null,
    /// Refs not updated: they would have lost commits.
    rejected: u32 = 0,
    /// The current branch's upstream on the remote (`refs/heads/main`):
    /// FETCH_HEAD's first line.
    upstream: ?[]const u8 = null,

    fn urlText(fetching: *const Fetching) [*:0]const u8 {
        return @ptrCast(&fetching.url);
    }

    /// The id the remote listed for `name`.
    pub fn listedId(fetching: *const Fetching, name: []const u8) ?Id {
        var each = fetching.listed;
        while (each) |ref| : (each = ref.next) {
            if (_git.same(ref.name, name)) return ref.id;
        }
        return null;
    }

    fn noMemory(fetching: *Fetching) bool {
        fetching.git.say("no memory\n", .{});
        return false;
    }

    /// The remote's refs listed, what is new fetched, the refs updated
    /// and shown: false when it failed (said). Refs left as they were
    /// are counted in `rejected`.
    pub fn fetchAll(fetching: *Fetching) bool {
        const git = fetching.git;
        const repo = fetching.repo;
        const connection = Connection.open(git, fetching.urlText(), "git-upload-pack") orelse return false;
        defer connection.close();
        fetching.shown_url = fetching.arena.copy(connection.remote_url.text()) orelse return fetching.noMemory();
        var prefixes: [specs_most + 1][]const u8 = undefined;
        for (fetching.specs[0..fetching.spec_count], 0..) |*spec, number| prefixes[number] = spec.prefix();
        prefixes[fetching.spec_count] = "refs/tags/";
        if (!connection.remote.listRefs(prefixes[0 .. fetching.spec_count + 1], collect, fetching)) {
            connection.sayFailure();
            return false;
        }
        if (!fetching.mapAll()) return false;
        if (!fetching.readShallow()) return false;

        var request: transport.Fetch = .{
            .wants = fetching.collectWants() orelse return false,
            .shallow = fetching.shallowIds() orelse return false,
            .depth = fetching.depth,
            .quiet = git.quiet,
            .boundary = boundary,
            .boundary_context = fetching,
        };
        if (request.wants.len != 0) {
            request.haves = fetching.collectHaves() orelse return false;
            if (incoming.receive(repo, connection, &request, &fetching.arena) == null) return false;
        }
        // Tags naming what was here before: asked for on their own.
        const tags = fetching.missingTags() orelse return false;
        if (tags.len != 0) {
            request.wants = tags;
            request.depth = 0;
            request.haves = fetching.collectHaves() orelse return false;
            const again = Connection.open(git, fetching.urlText(), "git-upload-pack") orelse return false;
            defer again.close();
            if (incoming.receive(repo, again, &request, &fetching.arena) == null) return false;
        }
        if (!fetching.writeShallow()) return false;
        if (!fetching.updateRefs()) return false;
        fetching.showOutcomes();
        return fetching.writeFetchHead();
    }

    /// Each listed ref's local name found through the refspecs; a tag of
    /// the remote's maps to itself.
    fn mapAll(fetching: *Fetching) bool {
        var each = fetching.listed;
        while (each) |ref| : (each = ref.next) {
            var into: [refs.name_most + 1]u8 = undefined;
            for (fetching.specs[0..fetching.spec_count]) |*spec| {
                const local = spec.map(ref.name, &into) orelse continue;
                ref.local = fetching.arena.copy(local) orelse return fetching.noMemory();
                ref.force = spec.force;
                break;
            }
            if (ref.local == null and _git.startsWith(ref.name, "refs/tags/")) {
                ref.local = ref.name;
                ref.tag = true;
            }
        }
        return true;
    }

    /// Room for `count` ids, from the arena.
    fn ids(fetching: *Fetching, count: usize) ?[*]Id {
        const memory = fetching.arena.take(@sizeOf(Id) * (count + 1), @alignOf(Id)) orelse {
            _ = fetching.noMemory();
            return null;
        };
        return @ptrCast(@alignCast(memory));
    }

    /// The ids to ask for: the mapped branches' the store has not - all
    /// of them for a new depth. Tags come with what they name.
    fn collectWants(fetching: *Fetching) ?[]const Id {
        var count: usize = 0;
        var each = fetching.listed;
        while (each) |ref| : (each = ref.next) count += 1;
        const wants = fetching.ids(count) orelse return null;
        var wanted: usize = 0;
        each = fetching.listed;
        while (each) |ref| : (each = ref.next) {
            if (ref.local == null or ref.tag) continue;
            if (fetching.depth == 0 and fetching.repo.objects.has(&ref.id)) continue;
            if (contains(wants[0..wanted], &ref.id)) continue;
            wants[wanted] = ref.id;
            wanted += 1;
        }
        return wants[0..wanted];
    }

    /// The remote's tags not here whose object is not either, but what
    /// they name is.
    fn missingTags(fetching: *Fetching) ?[]const Id {
        const repo = fetching.repo;
        var count: usize = 0;
        var each = fetching.listed;
        while (each) |ref| : (each = ref.next) count += 1;
        const wants = fetching.ids(count) orelse return null;
        var wanted: usize = 0;
        each = fetching.listed;
        while (each) |ref| : (each = ref.next) {
            if (!ref.tag) continue;
            const named = ref.peeled orelse continue;
            if (repo.objects.has(&ref.id) or !repo.objects.has(&named)) continue;
            if (refs.resolve(repo, ref.name) != null) continue;
            if (contains(wants[0..wanted], &ref.id)) continue;
            wants[wanted] = ref.id;
            wanted += 1;
        }
        return wants[0..wanted];
    }

    /// The commits offered as common: the repository's refs' and the
    /// history behind them, newest first, up to `haves_most`.
    fn collectHaves(fetching: *Fetching) ?[]const Id {
        if (fetching.haves) |haves| return haves;
        const repo = fetching.repo;
        const git = fetching.git;
        const haves = fetching.ids(haves_most) orelse return null;
        const walk = git.create(history.Walk) orelse return null;
        defer git.free(walk);
        if (!walk.init(repo)) return null;
        defer walk.deinit();
        const local = refs.list(repo, "refs/", &fetching.arena) orelse return null;
        for (local) |*ref| {
            const named = if (ref.target) |target| refs.resolve(repo, target) else ref.peeled orelse ref.id;
            const commit = commitBehind(repo, &(named orelse continue)) orelse continue;
            if (!walk.add(&commit, 0)) return null;
        }
        var count: usize = 0;
        while (count < haves_most) {
            var taken = walk.next() orelse break;
            taken.commit.free(git.sys);
            haves[count] = taken.id;
            count += 1;
        }
        if (walk.failed) return null;
        fetching.haves = haves[0..count];
        return fetching.haves;
    }

    fn readShallow(fetching: *Fetching) bool {
        const git = fetching.git;
        var path: files.Path = undefined;
        const name = fetching.repo.path(&path, &.{"shallow"}) orelse return false;
        const text = files.readWhole(git, name, shallow_most) orelse return true;
        defer git.free(text.ptr);
        var lines: refs.Lines = .{ .text = text };
        while (lines.next()) |line| {
            const id = _git.idOf(line) orelse continue;
            fetching.shallow = fetching.arena.create(Cut, .{ .id = id, .next = fetching.shallow }) orelse return fetching.noMemory();
        }
        return true;
    }

    fn shallowIds(fetching: *Fetching) ?[]const Id {
        var count: usize = 0;
        var each = fetching.shallow;
        while (each) |cut| : (each = cut.next) count += 1;
        const cuts = fetching.ids(count) orelse return null;
        count = 0;
        each = fetching.shallow;
        while (each) |cut| : (each = cut.next) {
            cuts[count] = cut.id;
            count += 1;
        }
        return cuts[0..count];
    }

    /// `.git/shallow` written anew when the cut moved; taken away when
    /// there is none left.
    fn writeShallow(fetching: *Fetching) bool {
        if (!fetching.shallow_changed) return true;
        const git = fetching.git;
        var count: usize = 0;
        var each = fetching.shallow;
        while (each) |cut| : (each = cut.next) {
            if (!cut.gone) count += 1;
        }
        if (count == 0) {
            var path: files.Path = undefined;
            const name = fetching.repo.path(&path, &.{"shallow"}) orelse return false;
            _ = git.dl.DeleteFile(name);
            return true;
        }
        const text = fetching.arena.take(count * 41, 1) orelse return fetching.noMemory();
        var at: usize = 0;
        each = fetching.shallow;
        while (each) |cut| : (each = cut.next) {
            if (cut.gone) continue;
            _git.hexOf(&cut.id, text[at..][0..40]);
            text[at + 40] = '\n';
            at += 41;
        }
        return refs.writeFile(fetching.repo, "shallow", &.{text[0..at]});
    }

    /// Each mapped ref moved to what the remote has, as its spec allows,
    /// and what became of it noted.
    fn updateRefs(fetching: *Fetching) bool {
        const repo = fetching.repo;
        var each = fetching.listed;
        while (each) |ref| : (each = ref.next) {
            const local = ref.local orelse continue;
            if (!repo.objects.has(&ref.id)) continue;
            const held = refs.resolve(repo, local) orelse {
                if (!refs.write(repo, local, &ref.id)) return false;
                ref.outcome = if (ref.tag or _git.startsWith(ref.name, "refs/tags/"))
                    .new_tag
                else if (_git.startsWith(ref.name, "refs/heads/"))
                    .new_branch
                else
                    .new_ref;
                continue;
            };
            if (_git.same(&held, &ref.id)) continue;
            ref.old = held;
            if (ref.tag) {
                ref.outcome = .rejected_tag;
            } else if (history.isAncestor(repo, &held, &ref.id) orelse return false) {
                ref.outcome = .forward;
            } else if (ref.force) {
                ref.outcome = .forced;
            } else {
                ref.outcome = .rejected;
            }
            switch (ref.outcome) {
                .rejected, .rejected_tag => fetching.rejected += 1,
                else => if (!refs.write(repo, local, &ref.id)) return false,
            }
        }
        return true;
    }

    /// A line for each ref that changed or was refused, after the URL.
    fn showOutcomes(fetching: *Fetching) void {
        const git = fetching.git;
        var width: usize = name_width;
        var shown: u32 = 0;
        var each = fetching.listed;
        while (each) |ref| : (each = ref.next) {
            if (!fetching.showsOutcome(ref)) continue;
            width = @max(width, log.shortName(ref.name).len);
            shown += 1;
        }
        if (shown == 0) return;
        git.endProgress();
        git.put("From ");
        git.put(fetching.shown_url);
        git.put("\n");
        each = fetching.listed;
        while (each) |ref| : (each = ref.next) {
            if (!fetching.showsOutcome(ref)) continue;
            var range: [summary_width + 1]u8 = undefined;
            const flag: []const u8, const summary: []const u8, const note: []const u8 = switch (ref.outcome) {
                .none => unreachable,
                .new_branch => .{ "*", "[new branch]", "" },
                .new_tag => .{ "*", "[new tag]", "" },
                .new_ref => .{ "*", "[new ref]", "" },
                .forward => .{ " ", rangeText(&range, &ref.old, &ref.id, ".."), "" },
                .forced => .{ "+", rangeText(&range, &ref.old, &ref.id, "..."), "forced update" },
                .rejected => .{ "!", "[rejected]", "non-fast-forward" },
                .rejected_tag => .{ "!", "[rejected]", "would clobber existing tag" },
            };
            git.put(" ");
            git.put(flag);
            git.put(" ");
            git.put(summary);
            pad(git, summary.len, summary_width);
            git.put(" ");
            const remote_name = log.shortName(ref.name);
            git.put(remote_name);
            pad(git, remote_name.len, width);
            git.put(" -> ");
            git.put(log.shortName(ref.local.?));
            if (note.len != 0) {
                git.put("  (");
                git.put(note);
                git.put(")");
            }
            git.put("\n");
        }
    }

    /// QUIET leaves out all but what was refused.
    fn showsOutcome(fetching: *const Fetching, ref: *const Listed) bool {
        return switch (ref.outcome) {
            .none => false,
            .rejected, .rejected_tag => true,
            else => !fetching.git.quiet,
        };
    }

    /// `.git/FETCH_HEAD`: a line for each branch fetched, the current
    /// branch's upstream first and the only one not marked
    /// not-for-merge.
    fn writeFetchHead(fetching: *Fetching) bool {
        var size: usize = 0;
        var each = fetching.listed;
        while (each) |ref| : (each = ref.next) {
            if (ref.local == null or ref.tag) continue;
            size += 40 + "\tnot-for-merge\tbranch '' of \n".len + ref.name.len + fetching.shown_url.len;
        }
        if (size == 0) return true;
        const text = fetching.arena.take(size, 1) orelse return fetching.noMemory();
        var out: _git.Out = .{ .into = text[0..size] };
        for ([_]bool{ true, false }) |upstream_pass| {
            each = fetching.listed;
            while (each) |ref| : (each = ref.next) {
                if (ref.local == null or ref.tag) continue;
                const is_upstream = if (fetching.upstream) |upstream| _git.same(upstream, ref.name) else false;
                if (is_upstream != upstream_pass) continue;
                out.hex(&ref.id);
                out.put(if (is_upstream) "\t\t" else "\tnot-for-merge\t");
                if (_git.startsWith(ref.name, "refs/heads/")) {
                    out.put("branch '");
                    out.put(ref.name["refs/heads/".len..]);
                } else {
                    out.put("'");
                    out.put(ref.name);
                }
                out.put("' of ");
                out.put(fetching.shown_url);
                out.byte('\n');
            }
        }
        return refs.writeFile(fetching.repo, "FETCH_HEAD", &.{out.written()});
    }
};

pub fn run(git: *Git, argv: []const usize) i32 {
    git.quiet = argv[arg_quiet] != 0;
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    var remote_buffer: [refs.name_most + 1]u8 = undefined;
    const remote: []const u8 = if (argv[arg_remote] != 0) files.span(@ptrFromInt(argv[arg_remote])) else branchRemote(repo, &remote_buffer);
    var depth: u32 = 0;
    if (argv[arg_depth] != 0) {
        const given = @as(*const i32, @ptrFromInt(argv[arg_depth])).*;
        if (given < 1) {
            git.say("DEPTH must be 1 or more\n", .{});
            return dos.RETURN_ERROR;
        }
        depth = @intCast(given);
    }
    const fetching = start(repo, remote, depth) orelse return dos.RETURN_ERROR;
    defer finish(fetching);
    if (!fetching.fetchAll()) return dos.RETURN_ERROR;
    return if (fetching.rejected != 0) dos.RETURN_ERROR else dos.RETURN_OK;
}

/// A fetch from the remote `remote` set up: its URL and refspecs read
/// from the config; null, said, when it has none.
/// The current branch's remote, as `.git/config` names it; `origin`
/// without one.
fn branchRemote(repo: *Repository, into: *[refs.name_most + 1]u8) []const u8 {
    var head: refs.Head = .{};
    if (!refs.head(repo, &head)) return "origin";
    const branch = head.branch orelse return "origin";
    var config: config_module.Config = undefined;
    config.read(repo, repo.git);
    defer config.free();
    return config.get("branch", log.shortName(branch), "remote", into) orelse "origin";
}

pub fn start(repo: *Repository, remote: []const u8, depth: u32) ?*Fetching {
    const git = repo.git;
    const fetching = git.create(Fetching) orelse return null;
    fetching.* = .{ .git = git, .repo = repo, .arena = .{ .sys = git.sys }, .depth = depth };
    var config: config_module.Config = undefined;
    config.read(repo, git);
    defer config.free();
    const url = config.get("remote", remote, "url", fetching.url[0..url_most]) orelse {
        git.say("there is no remote ", .{});
        git.put(remote);
        git.put(" in .git/config (Git remote add NAME URL makes one)\n");
        finish(fetching);
        return null;
    };
    fetching.url[url.len] = 0;
    var value: [512]u8 = undefined;
    config.each("remote", remote, "fetch", &value, takeSpec, fetching);
    if (fetching.spec_count == 0) {
        git.say("the remote has no fetch refspec in .git/config\n", .{});
        finish(fetching);
        return null;
    }
    // The current branch's upstream, when it is on this remote.
    var head: refs.Head = .{};
    if (refs.head(repo, &head)) {
        if (head.branch) |branch| {
            var remote_value: [refs.name_most + 1]u8 = undefined;
            var merge_value: [refs.name_most + 1]u8 = undefined;
            const short = log.shortName(branch);
            if (config.get("branch", short, "remote", &remote_value)) |name| {
                if (_git.same(name, remote)) {
                    if (config.get("branch", short, "merge", &merge_value)) |merge| {
                        fetching.upstream = fetching.arena.copy(merge);
                    }
                }
            }
        }
    }
    return fetching;
}

fn takeSpec(opaque_fetching: *anyopaque, text: []const u8) bool {
    const fetching: *Fetching = @ptrCast(@alignCast(opaque_fetching));
    if (fetching.spec_count == specs_most) return false;
    const kept = fetching.arena.copy(text) orelse return false;
    const spec = Spec.parse(kept) orelse {
        fetching.git.say("a fetch refspec in .git/config is none Git reads: %s\n", .{kept.ptr});
        return true;
    };
    fetching.specs[fetching.spec_count] = spec;
    fetching.spec_count += 1;
    return true;
}

pub fn finish(fetching: *Fetching) void {
    const git = fetching.git;
    fetching.arena.free();
    git.free(fetching);
}

fn collect(opaque_fetching: *anyopaque, ref: *const transport.Ref) bool {
    const fetching: *Fetching = @ptrCast(@alignCast(opaque_fetching));
    if (ref.unborn or _git.same(ref.name, "HEAD")) return true;
    const name = fetching.arena.copy(ref.name) orelse return false;
    const made = fetching.arena.create(Listed, .{ .name = name, .id = ref.id, .peeled = ref.peeled }) orelse return false;
    if (fetching.last) |last| last.next = made else fetching.listed = made;
    fetching.last = made;
    return !fetching.git.stopped();
}

/// Told by the server where it cuts the history now (`shallow`) and
/// where no longer.
fn boundary(opaque_fetching: *anyopaque, id: *const Id, shallow: bool) bool {
    const fetching: *Fetching = @ptrCast(@alignCast(opaque_fetching));
    var each = fetching.shallow;
    while (each) |cut| : (each = cut.next) {
        if (!_git.same(&cut.id, id)) continue;
        if (cut.gone == shallow) {
            cut.gone = !shallow;
            fetching.shallow_changed = true;
        }
        return true;
    }
    if (!shallow) return true;
    fetching.shallow = fetching.arena.create(Cut, .{ .id = id.*, .next = fetching.shallow }) orelse return false;
    fetching.shallow_changed = true;
    return true;
}

/// The commit `id` names, through its tags; null for anything else, and
/// for an object not here.
fn commitBehind(repo: *Repository, id: *const Id) ?Id {
    const sys = repo.git.sys;
    var current = id.*;
    for (0..peel_most) |_| {
        var found = repo.objects.read(&current) orelse return null;
        defer found.free(sys);
        switch (found.kind) {
            .commit => return current,
            .tag => current = (object.parseTag(found.data) orelse return null).object,
            else => return null,
        }
    }
    return null;
}

fn contains(list: []const Id, id: *const Id) bool {
    for (list) |*each| {
        if (_git.same(each, id)) return true;
    }
    return false;
}

pub fn rangeText(into: *[summary_width + 1]u8, old: *const Id, new: *const Id, dots: []const u8) []const u8 {
    var hex: [40]u8 = undefined;
    var out: _git.Out = .{ .into = into };
    _git.hexOf(old, &hex);
    out.put(hex[0..7]);
    out.put(dots);
    _git.hexOf(new, &hex);
    out.put(hex[0..7]);
    return out.written();
}

pub fn pad(git: *Git, used: usize, width: usize) void {
    var at = used;
    while (at < width) : (at += 1) git.put(" ");
}
