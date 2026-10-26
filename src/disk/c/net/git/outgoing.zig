// SPDX-License-Identifier: MIT
//! A pack made for a push: the objects the commits pushed reach that the
//! remote's commits do not, written to `objects/pack/tmp_pack_outgoing`
//! to be sent from there, and taken away after.
//!
//! The commits are walked newest first from both sides at once (the
//! pushed tips and the remote's refs this repository has), until every
//! commit still queued is the remote's (`history.Walk.ends`): those
//! only the pushed side reached go - not one the remote's side reached
//! after it was taken out, a commit dated before its parent.
//! The remote's commits the new ones sit on - their parents that carry
//! the remote's mark when the walk stops, taken out or still queued -
//! are the edge: their trees are marked as the remote's, every tree and
//! blob in them. The new commits' trees are then walked, a tree the
//! remote has passed by whole - an unchanged directory has the same id -
//! and every tree and blob not marked taken. Trees are walked through a
//! queue of ids, not by recursion.
//!
//! A tag object pushed goes too (`include`), whatever the remote has.
//!
//! Each object is written whole, zlib over its bytes, after its type and
//! size; no deltas. The SHA-1 of the pack ends it.

const sdk = @import("sdk");
const dos = sdk.dos;
const compression = sdk.compression;
const _git = @import("_git.zig");
const object = @import("object.zig");
const pack = @import("pack.zig");
const history = @import("history.zig");
const revision = @import("revision.zig");
const context = @import("context.zig");
const files = @import("files.zig");
const Repository = @import("repo.zig").Repository;
const Git = context.Git;
const Id = _git.Id;

const pack_outgoing = "objects/pack/tmp_pack_outgoing";

/// The object marks: the remote has it, or it is taken; and for a
/// commit, that its tree is marked the remote's.
const theirs: u8 = 1;
const taken: u8 = 2;
const edge: u8 = 4;

const piece_bytes = 16 * 1024;

pub const Outgoing = struct {
    repo: *Repository,
    git: *Git,
    arena: context.Arena,
    marks: history.Marks,
    /// What goes, commits first.
    ids: []Id = &.{},
    count: usize = 0,
    /// Trees still to be walked.
    queue: []Id = &.{},
    queued: usize = 0,
    /// The pack's file, and its length once written.
    path: files.Path = undefined,
    size: u64 = 0,
    written: bool = false,

    pub fn init(outgoing: *Outgoing, repo: *Repository) void {
        outgoing.* = .{ .repo = repo, .git = repo.git, .arena = .{ .sys = repo.git.sys }, .marks = .{ .sys = repo.git.sys } };
    }

    /// The pack's file taken away, the memory given back.
    pub fn deinit(outgoing: *Outgoing) void {
        if (outgoing.written) _ = outgoing.git.dl.DeleteFile(@ptrCast(&outgoing.path));
        outgoing.marks.deinit();
        outgoing.arena.free();
    }

    fn noMemory(outgoing: *Outgoing) bool {
        outgoing.git.say("no memory\n", .{});
        return false;
    }

    /// `id` put on `list`, grown as needed.
    fn append(outgoing: *Outgoing, list: *[]Id, length: *usize, id: *const Id) bool {
        if (length.* == list.len) {
            const size = if (list.len == 0) 256 else list.len * 2;
            const memory = outgoing.arena.take(size * @sizeOf(Id), @alignOf(Id)) orelse return outgoing.noMemory();
            const grown = @as([*]Id, @ptrCast(@alignCast(memory)))[0..size];
            @memcpy(grown[0..length.*], list.*[0..length.*]);
            list.* = grown;
        }
        list.*[length.*] = id.*;
        length.* += 1;
        return true;
    }

    /// What goes found: the objects `tips` reach that `known` - the
    /// remote's commits this repository has - do not. False, said, when
    /// the history or a tree cannot be read.
    pub fn collect(outgoing: *Outgoing, tips: []const Id, known: []const Id) bool {
        const repo = outgoing.repo;
        const git = outgoing.git;
        const walk = git.create(history.Walk) orelse return false;
        defer git.free(walk);
        if (!walk.init(repo)) return false;
        defer walk.deinit();
        for (tips) |*tip| {
            if (!walk.add(tip, history.mark_left)) return false;
        }
        for (known) |*commit| {
            if (!walk.add(commit, history.mark_right)) return false;
        }
        // The new commits' trees and the parents they sit on, and the
        // remote's trees, to be walked after.
        var new_trees: []Id = &.{};
        var new_count: usize = 0;
        var parents: []Id = &.{};
        var parent_count: usize = 0;
        var their_trees: []Id = &.{};
        var their_count: usize = 0;
        // Tags included come before the commits.
        const first = outgoing.count;
        while (!walk.ends(history.mark_right)) {
            var commit_taken = walk.next() orelse break;
            defer commit_taken.commit.free(git.sys);
            if (commit_taken.marks & history.mark_right != 0) continue;
            const commit = object.parseCommit(commit_taken.commit.data) orelse continue;
            const marks = outgoing.marks.put(&commit_taken.id) orelse return outgoing.noMemory();
            marks.* |= taken;
            if (!outgoing.append(&outgoing.ids, &outgoing.count, &commit_taken.id)) return false;
            if (!outgoing.append(&new_trees, &new_count, &commit.tree)) return false;
            for (0..commit.parent_count) |number| {
                const parent = commit.parent(number);
                if (!outgoing.append(&parents, &parent_count, &parent)) return false;
            }
        }
        if (walk.failed) return false;
        // The remote's after all, with their trees: a tree kept is the
        // same one at the same place in each list.
        var kept: usize = 0;
        for (0..new_count) |at| {
            if (walk.marksOf(&outgoing.ids[first + at]) & history.mark_right != 0) continue;
            outgoing.ids[first + kept] = outgoing.ids[first + at];
            new_trees[kept] = new_trees[at];
            kept += 1;
        }
        outgoing.count = first + kept;
        new_count = kept;
        // The edge, each commit once.
        for (parents[0..parent_count]) |*parent| {
            if (walk.marksOf(parent) & history.mark_right == 0) continue;
            const marks = outgoing.marks.put(parent) orelse return outgoing.noMemory();
            if (marks.* & edge != 0) continue;
            marks.* |= edge;
            const tree = revision.treeOf(repo, parent) orelse return false;
            if (!outgoing.append(&their_trees, &their_count, &tree)) return false;
        }
        for (their_trees[0..their_count]) |*tree| {
            if (!outgoing.walkTrees(tree, theirs)) return false;
        }
        for (new_trees[0..new_count]) |*tree| {
            if (!outgoing.walkTrees(tree, taken)) return false;
        }
        return true;
    }

    /// The object `id` - a tag a push names - put on the list.
    pub fn include(outgoing: *Outgoing, id: *const Id) bool {
        _ = outgoing.take(id, taken) orelse return false;
        return true;
    }

    /// The tree `root` and everything in it marked `mark`; each one
    /// marked `taken` put on the list. A tree marked before is passed by
    /// whole.
    fn walkTrees(outgoing: *Outgoing, root: *const Id, mark: u8) bool {
        const repo = outgoing.repo;
        const git = outgoing.git;
        if (!(outgoing.take(root, mark) orelse return false)) return true;
        outgoing.queued = 0;
        if (!outgoing.append(&outgoing.queue, &outgoing.queued, root)) return false;
        while (outgoing.queued > 0) {
            if (git.stopped()) {
                git.say("stopped\n", .{});
                return false;
            }
            outgoing.queued -= 1;
            const tree = outgoing.queue[outgoing.queued];
            var found = repo.objects.read(&tree) orelse {
                git.say("the repository does not have a tree it names\n", .{});
                return false;
            };
            defer found.free(git.sys);
            if (found.kind != .tree) {
                git.say("a tree is no tree\n", .{});
                return false;
            }
            var entries: object.TreeEntries = .{ .body = found.data };
            while (entries.next()) |entry| {
                if (entry.mode == object.mode_gitlink) continue;
                if (!(outgoing.take(&entry.id, mark) orelse return false)) continue;
                if (entry.isTree() and !outgoing.append(&outgoing.queue, &outgoing.queued, &entry.id)) return false;
            }
            if (entries.bad) {
                git.say("a tree is broken\n", .{});
                return false;
            }
        }
        return true;
    }

    /// `id` marked `mark`, and put on the list when that is `taken`:
    /// false when it was marked before, null when there is no memory
    /// (said).
    fn take(outgoing: *Outgoing, id: *const Id, mark: u8) ?bool {
        const marks = outgoing.marks.put(id) orelse {
            _ = outgoing.noMemory();
            return null;
        };
        if (marks.* != 0) return false;
        marks.* = mark;
        if (mark == taken and !outgoing.append(&outgoing.ids, &outgoing.count, id)) return null;
        return true;
    }

    /// The pack written to its file: false, said, when it could not be.
    pub fn write(outgoing: *Outgoing) bool {
        const repo = outgoing.repo;
        const git = outgoing.git;
        const dl = git.dl;
        const name = repo.path(&outgoing.path, &.{pack_outgoing}) orelse return false;
        const writer = git.create(Writer) orelse return false;
        defer git.free(writer);
        writer.* = .{ .git = git, .file = dl.Open(name, dos.MODE_NEWFILE), .sha = _git.Sha1.start(git.cb) };
        if (writer.file == null) {
            _ = dl.PrintFault(dl.IoErr(), name);
            return false;
        }
        outgoing.written = true;
        var head: [pack.header_bytes]u8 = undefined;
        pack.putHeader(&head, @intCast(outgoing.count));
        writer.put(&head);
        for (outgoing.ids[0..outgoing.count], 0..) |*id, number| {
            if (number % 64 == 0 or number + 1 == outgoing.count) git.progress("Writing objects: %u/%u", .{ @as(u32, @intCast(number + 1)), @as(u32, @intCast(outgoing.count)) });
            if (!writer.entry(repo, id)) {
                _ = dl.Close(writer.file);
                return false;
            }
        }
        git.endProgress();
        const sum = writer.sha.finish();
        writer.put(&sum);
        writer.flush();
        const closed = dl.Close(writer.file);
        if (writer.failed or !closed) {
            _ = dl.PrintFault(dl.IoErr(), name);
            return false;
        }
        outgoing.size = writer.total;
        return true;
    }
};

/// The pack's bytes buffered into its file, the SHA-1 running over them.
const Writer = struct {
    git: *Git,
    file: ?*dos.FileHandle,
    sha: _git.Sha1,
    total: u64 = 0,
    at: usize = 0,
    failed: bool = false,
    stream: compression.Stream = .{},
    buffer: [piece_bytes]u8 = undefined,
    out: [piece_bytes]u8 = undefined,

    fn put(writer: *Writer, bytes: []const u8) void {
        writer.sha.update(bytes);
        writer.total += bytes.len;
        var rest = bytes;
        while (rest.len > 0) {
            if (writer.at == writer.buffer.len) writer.flush();
            const count = @min(rest.len, writer.buffer.len - writer.at);
            @memcpy(writer.buffer[writer.at..][0..count], rest[0..count]);
            writer.at += count;
            rest = rest[count..];
        }
    }

    fn flush(writer: *Writer) void {
        if (writer.at != 0 and !writer.failed) {
            if (writer.git.dl.Write(writer.file, &writer.buffer, @intCast(writer.at)) != writer.at) writer.failed = true;
        }
        writer.at = 0;
    }

    /// The object `id`: its type and size, then zlib over its bytes.
    fn entry(writer: *Writer, repo: *Repository, id: *const Id) bool {
        const git = writer.git;
        var found = repo.objects.read(id) orelse {
            git.say("the repository does not have an object it names\n", .{});
            return false;
        };
        defer found.free(git.sys);
        var head: [10]u8 = undefined;
        writer.put(pack.putEntryHead(&head, found.kind, found.data.len));
        if (git.zb.InitDeflate(&writer.stream, compression.FORMAT_ZLIB, compression.LEVEL_DEFAULT) != compression.COMPRESS_OK) {
            git.say("no memory\n", .{});
            return false;
        }
        defer git.zb.EndDeflate(&writer.stream);
        writer.stream.next_in = found.data.ptr;
        writer.stream.avail_in = @intCast(found.data.len);
        while (true) {
            writer.stream.next_out = &writer.out;
            writer.stream.avail_out = writer.out.len;
            const result = git.zb.Deflate(&writer.stream, compression.FLUSH_FINISH);
            if (result != compression.COMPRESS_OK and result != compression.COMPRESS_END) {
                git.say("an object could not be packed (%d)\n", .{result});
                return false;
            }
            writer.put(writer.out[0 .. writer.out.len - writer.stream.avail_out]);
            if (result == compression.COMPRESS_END) break;
        }
        return !writer.failed;
    }
};
