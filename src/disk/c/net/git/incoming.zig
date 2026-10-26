// SPDX-License-Identifier: MIT
//! A pack fetched into a repository: written to
//! `objects/pack/tmp_pack_incoming` as it arrives (its SHA-1 checked on
//! the way), indexed from there into `tmp_idx_incoming`, then both named
//! by the pack's checksum - the idx last, so a pack is never seen
//! without it - and the store told of it. What fails takes the files
//! away again.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const transport = @import("transport.zig");
const indexpack = @import("indexpack.zig");
const files = @import("files.zig");
const context = @import("context.zig");
const Connection = @import("connect.zig").Connection;
const Repository = @import("repo.zig").Repository;
const Received = @import("receive.zig").Received;
const Git = context.Git;

const pack_incoming = "objects/pack/tmp_pack_incoming";
const idx_incoming = "objects/pack/tmp_idx_incoming";

/// `request` fetched over `connection` into the repository: the pack's
/// name (`pack-<checksum>`, in `arena`), or null, said, when it failed.
pub fn receive(repo: *Repository, connection: *Connection, request: *const transport.Fetch, arena: *context.Arena) ?[]const u8 {
    const git = repo.git;
    const dl = git.dl;
    var pack_path: files.Path = undefined;
    var idx_path: files.Path = undefined;
    const pack_name = repo.path(&pack_path, &.{pack_incoming}) orelse return null;
    const idx_name = repo.path(&idx_path, &.{idx_incoming}) orelse return null;
    const pack_file = dl.Open(pack_name, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), pack_name);
        return null;
    };
    var sink: files.FileSink = .{ .dl = dl, .file = pack_file };
    const received = connection.remote.fetch(request, sink.asSink());
    const closed = dl.Close(pack_file);
    git.endProgress();
    const got = received orelse {
        connection.sayFailure();
        _ = dl.DeleteFile(pack_name);
        return null;
    };
    if (!closed) {
        _ = dl.PrintFault(dl.IoErr(), pack_name);
        _ = dl.DeleteFile(pack_name);
        return null;
    }
    const name = index(repo, &got, pack_name, idx_name, arena);
    if (name == null) {
        _ = dl.DeleteFile(pack_name);
        _ = dl.DeleteFile(idx_name);
        return null;
    }
    if (!repo.objects.addPack(name.?)) return null;
    return name;
}

/// The pack received indexed, both named by its checksum.
fn index(repo: *Repository, got: *const Received, pack_name: [*:0]const u8, idx_name: [*:0]const u8, arena: *context.Arena) ?[]const u8 {
    const git = repo.git;
    const dl = git.dl;
    const window = git.create(files.Window) orelse return null;
    defer git.free(window);
    window.* = .{ .dl = dl, .file = dl.Open(pack_name, dos.MODE_OLDFILE) };
    if (window.file == null) {
        _ = dl.PrintFault(dl.IoErr(), pack_name);
        return null;
    }
    const idx_file = dl.Open(idx_name, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), idx_name);
        _ = dl.Close(window.file);
        return null;
    };
    const indexer = git.create(indexpack.Indexer) orelse {
        _ = dl.Close(idx_file);
        _ = dl.Close(window.file);
        return null;
    };
    indexer.init(git.sys, git.zb, git.cb, window.source());
    indexer.progress = .{ .context = git, .step = step };
    var sink: files.FileSink = .{ .dl = dl, .file = idx_file };
    var indexed = indexer.run(got.bytes, got.count, &got.checksum, sink.asSink());
    const failure = indexer.failure;
    indexer.deinit();
    git.free(indexer);
    if (!dl.Close(idx_file)) indexed = false;
    _ = dl.Close(window.file);
    git.endProgress();
    if (!indexed) {
        switch (failure) {
            .none, .sink, .read => if (dl.IoErr() != 0) {
                _ = dl.PrintFault(dl.IoErr(), idx_name);
            } else {
                git.say("the pack could not be indexed\n", .{});
            },
            .entry, .delta => git.say("the pack is broken\n", .{}),
            .base => git.say("the pack holds a delta whose base it does not have\n", .{}),
            .memory => git.say("no memory to index the pack\n", .{}),
            .stopped => git.say("stopped\n", .{}),
        }
        return null;
    }

    var name: [45]u8 = undefined;
    @memcpy(name[0..5], "pack-");
    _git.hexOf(&got.checksum, name[5..45]);
    const pack_base = arena.copy(&name) orelse {
        git.say("no memory\n", .{});
        return null;
    };
    var final_pack: files.Path = undefined;
    var final_idx: files.Path = undefined;
    const pack_final = repo.path(&final_pack, &.{ "objects/pack/", pack_base, ".pack" }) orelse return null;
    const idx_final = repo.path(&final_idx, &.{ "objects/pack/", pack_base, ".idx" }) orelse return null;
    if (dl.Lock(idx_final, dos.SHARED_LOCK)) |lock| {
        // The same pack is there already.
        dl.UnLock(lock);
        _ = dl.DeleteFile(pack_name);
        _ = dl.DeleteFile(idx_name);
        return pack_base;
    }
    if (!dl.Rename(pack_name, pack_final)) {
        _ = dl.PrintFault(dl.IoErr(), pack_final);
        return null;
    }
    if (!dl.Rename(idx_name, idx_final)) {
        _ = dl.PrintFault(dl.IoErr(), idx_final);
        return null;
    }
    return pack_base;
}

fn step(opaque_git: *anyopaque, phase: indexpack.Phase, done: u32, total: u32) bool {
    const git: *Git = @ptrCast(@alignCast(opaque_git));
    if (done % 256 == 0 or done == total) {
        switch (phase) {
            .indexing => git.progress("Indexing objects: %u/%u", .{ done, total }),
            .resolving => git.progress("Resolving deltas: %u/%u", .{ done, total }),
        }
    }
    return !git.stopped();
}
