// SPDX-License-Identifier: MIT
//! Objects written loose: `objects/xx/<38 hex digits>`, zlib over the
//! object's header (`blob 1234\0`) and its bytes. An object is written
//! to a file of its own in `objects/` while its id is worked out over the
//! same bytes, then named by the id - an object the store has already
//! is left as it is, and the file deleted. A file is taken in pieces, so
//! one of any size goes through the same 32 KiB.

const sdk = @import("sdk");
const dos = sdk.dos;
const compression = sdk.compression;
const _git = @import("_git.zig");
const object = @import("object.zig");
const files = @import("files.zig");
const Repository = @import("repo.zig").Repository;
const Git = @import("context.zig").Git;
const Id = _git.Id;

const piece_bytes = 16 * 1024;

pub const Writer = struct {
    repo: *Repository,
    git: *Git,
    file: ?*dos.FileHandle = null,
    stream: compression.Stream = .{},
    deflating: bool = false,
    sha: _git.Sha1,
    /// The bytes the header promised, and those taken.
    size: u64,
    taken: u64 = 0,
    failed: bool = false,
    temporary: files.Path = undefined,
    out: [piece_bytes]u8 = undefined,
    input: [piece_bytes]u8 = undefined,

    /// An object of `kind` and `size` bytes begun: false, said, when its
    /// file could not be made.
    pub fn start(writer: *Writer, repo: *Repository, kind: object.Type, size: u64) bool {
        const git = repo.git;
        const dl = git.dl;
        writer.repo = repo;
        writer.git = git;
        writer.file = null;
        writer.stream = .{};
        writer.deflating = false;
        writer.sha = _git.Sha1.start(git.cb);
        writer.size = size;
        writer.taken = 0;
        writer.failed = false;
        // A name no other Git's writer has: this one's address.
        var name: [16]u8 = undefined;
        var out: _git.Out = .{ .into = &name };
        out.put("tmp_obj_");
        const address: u32 = @truncate(@intFromPtr(writer));
        for (0..8) |shift| {
            const nibble: u4 = @truncate(address >> @intCast(28 - shift * 4));
            out.byte("0123456789abcdef"[nibble]);
        }
        const path = repo.path(&writer.temporary, &.{ "objects/", out.written() }) orelse return false;
        writer.file = dl.Open(path, dos.MODE_NEWFILE) orelse {
            _ = dl.PrintFault(dl.IoErr(), path);
            return false;
        };
        if (git.zb.InitDeflate(&writer.stream, compression.FORMAT_ZLIB, compression.LEVEL_FAST) != compression.COMPRESS_OK) {
            git.say("no memory\n", .{});
            writer.abandon();
            return false;
        }
        writer.deflating = true;
        var head: [32]u8 = undefined;
        const header = object.header(kind, size, &head);
        writer.sha.update(header);
        return writer.deflate(header, compression.FLUSH_NONE);
    }

    /// The next of the object's bytes.
    pub fn take(writer: *Writer, bytes: []const u8) bool {
        if (writer.failed) return false;
        writer.taken += bytes.len;
        if (writer.taken > writer.size) return writer.fail();
        writer.sha.update(bytes);
        return writer.deflate(bytes, compression.FLUSH_NONE);
    }

    /// The object ended and named: its id, or null, said, when it could
    /// not be written.
    pub fn finish(writer: *Writer) ?Id {
        const git = writer.git;
        const dl = git.dl;
        if (writer.failed or writer.taken != writer.size) {
            writer.abandon();
            return null;
        }
        if (!writer.deflate(&.{}, compression.FLUSH_FINISH)) {
            writer.abandon();
            return null;
        }
        git.zb.EndDeflate(&writer.stream);
        writer.deflating = false;
        const closed = dl.Close(writer.file);
        writer.file = null;
        const temporary: [*:0]const u8 = @ptrCast(&writer.temporary);
        if (!closed) {
            _ = dl.PrintFault(dl.IoErr(), temporary);
            _ = dl.DeleteFile(temporary);
            return null;
        }
        const id = writer.sha.finish();
        var hex: [40]u8 = undefined;
        _git.hexOf(&id, &hex);
        var path: files.Path = undefined;
        const name = writer.repo.path(&path, &.{ "objects/", hex[0..2], "/", hex[2..] }) orelse {
            _ = dl.DeleteFile(temporary);
            return null;
        };
        if (writer.repo.objects.has(&id)) {
            _ = dl.DeleteFile(temporary);
            return id;
        }
        if (!files.makeDirs(git, name) or !dl.Rename(temporary, name)) {
            _ = dl.PrintFault(dl.IoErr(), name);
            _ = dl.DeleteFile(temporary);
            return null;
        }
        return id;
    }

    /// What was begun taken away again.
    pub fn abandon(writer: *Writer) void {
        const dl = writer.git.dl;
        if (writer.deflating) writer.git.zb.EndDeflate(&writer.stream);
        writer.deflating = false;
        if (writer.file) |file| {
            _ = dl.Close(file);
            _ = dl.DeleteFile(@ptrCast(&writer.temporary));
        }
        writer.file = null;
    }

    fn fail(writer: *Writer) bool {
        writer.failed = true;
        return false;
    }

    /// `bytes` deflated, what comes out written to the file.
    fn deflate(writer: *Writer, bytes: []const u8, flush: u32) bool {
        const git = writer.git;
        const dl = git.dl;
        writer.stream.next_in = bytes.ptr;
        writer.stream.avail_in = @intCast(bytes.len);
        while (true) {
            writer.stream.next_out = &writer.out;
            writer.stream.avail_out = writer.out.len;
            const result = git.zb.Deflate(&writer.stream, flush);
            if (result != compression.COMPRESS_OK and result != compression.COMPRESS_END) {
                git.say("the object could not be packed (%d)\n", .{result});
                return writer.fail();
            }
            const produced = writer.out.len - writer.stream.avail_out;
            if (produced != 0 and dl.Write(writer.file, &writer.out, @intCast(produced)) != produced) {
                _ = dl.PrintFault(dl.IoErr(), @ptrCast(&writer.temporary));
                return writer.fail();
            }
            if (result == compression.COMPRESS_END) return true;
            if (flush != compression.FLUSH_FINISH and writer.stream.avail_in == 0 and writer.stream.avail_out != 0) return true;
        }
    }
};

/// The object of `kind` with `body` written: its id, or null, said.
pub fn writeBytes(repo: *Repository, kind: object.Type, body: []const u8) ?Id {
    const git = repo.git;
    const id = object.idOfObject(git.cb, kind, body);
    if (repo.objects.has(&id)) return id;
    const writer = git.create(Writer) orelse return null;
    defer git.free(writer);
    if (!writer.start(repo, kind, body.len)) return null;
    if (!writer.take(body)) {
        writer.abandon();
        return null;
    }
    return writer.finish();
}

/// The file `local`, of `size` bytes, written as a blob: its id, or
/// null, said.
pub fn writeFile(repo: *Repository, local: [*:0]const u8, size: u64) ?Id {
    const git = repo.git;
    const dl = git.dl;
    const writer = git.create(Writer) orelse return null;
    defer git.free(writer);
    const file = dl.Open(local, dos.MODE_OLDFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), local);
        return null;
    };
    defer _ = dl.Close(file);
    if (!writer.start(repo, .blob, size)) return null;
    while (true) {
        const got = dl.Read(file, &writer.input, writer.input.len);
        if (got < 0) {
            _ = dl.PrintFault(dl.IoErr(), local);
            writer.abandon();
            return null;
        }
        if (got == 0) break;
        if (!writer.take(writer.input[0..@intCast(got)])) {
            if (writer.taken > writer.size) git.say("%s changed while it was read\n", .{local});
            writer.abandon();
            return null;
        }
    }
    if (writer.taken != writer.size) {
        git.say("%s changed while it was read\n", .{local});
        writer.abandon();
        return null;
    }
    return writer.finish();
}
