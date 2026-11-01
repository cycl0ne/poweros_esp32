// SPDX-License-Identifier: MIT
//! The compare and what comes of it: the list the machine was given and
//! the list the package holds, walked at once - both are sorted the same
//! way, so two lines in hand are enough and nothing is held in memory -
//! and for each path the rule in `sdk.install.update` says what happens
//! to it.
//!
//! The file itself is read only where the two lists differ about it:
//! where they agree it is looked for and not read, so a file edited on
//! the machine is left alone unread while one that went missing is
//! written again.
//!
//! What the build dropped is deleted after everything else and in
//! reverse, so a drawer goes after what was in it.

const sdk = @import("sdk");
const dos = sdk.dos;
const install = sdk.install;
const manifest = install.manifest;
const rule = install.update;
const prefs = sdk.prefs;
const shared = @import("_update.zig");
const source = @import("source.zig");
const Run = shared.Run;
const Name = shared.Name;

/// Where the system half's files are.
const volume = "SYS:";

/// What a path's line says is happening to it.
const row = "  %-7s %s\n";

/// Both lists walked, and the package's left as the machine's own where
/// anything was written. The return code: 0 for nothing to do, 5 where
/// something is to be done and CHECK only said so, 20 for a run that
/// could not finish.
pub fn walk(run: *Run, installed: []const u8, fresh: []const u8) i32 {
    var mine = manifest.Reader.init(installed) catch |err| {
        return shared.fail(run, "%s: %s\n", .{ install.installed_manifest, manifest.why(err) });
    };
    var theirs = manifest.Reader.init(fresh) catch |err| {
        return shared.fail(run, "%s: %s\n", .{ install.package_manifest, manifest.why(err) });
    };

    var gone: shared.Buffer = .{ .sys = run.sys };
    defer gone.free();

    var had = mine.next() catch |err| return badList(run, install.installed_manifest, err);
    var want = theirs.next() catch |err| return badList(run, install.package_manifest, err);
    while (had != null or want != null) {
        if (shared.stopped(run)) return dos.RETURN_WARN;
        const order: manifest.Order = if (had == null)
            .after
        else if (want == null)
            .before
        else
            manifest.orderPaths(had.?.path, want.?.path);

        const path = if (order == .after) want.?.path else had.?.path;
        const this_had: ?manifest.Entry = if (order == .after) null else had;
        const this_want: ?manifest.Entry = if (order == .before) null else want;
        const code = one(run, path, this_had, this_want, &gone);
        if (code != dos.RETURN_OK) return code;

        if (order != .after) had = mine.next() catch |err| return badList(run, install.installed_manifest, err);
        if (order != .before) want = theirs.next() catch |err| return badList(run, install.package_manifest, err);
    }

    const code = remove(run, &gone);
    if (code != dos.RETURN_OK) return code;
    return saveList(run, fresh);
}

/// What is to happen to one path, and the doing of it.
fn one(run: *Run, path: []const u8, had: ?manifest.Entry, want: ?manifest.Entry, gone: *shared.Buffer) i32 {
    const part = install.halfOf(path) orelse {
        return shared.fail(run, "%s is in neither half of a package\n", .{Name.of("", path).cstr()});
    };
    // A half's own drawer stands for the volume it is written to.
    if (part.rest.len == 0) return dos.RETURN_OK;
    // What the firmware reads is written into its partition, which is
    // the kernel's own step: here it is counted and left alone.
    if (part.half == .boot) {
        if (want != null and want.?.kind == .file) run.boot += 1;
        return dos.RETURN_OK;
    }

    const where = Name.of(volume, part.rest);
    const here = if (rule.agree(had, want))
        thereOf(run, where.cstr())
    else
        hereOf(run, where.cstr(), had, want);
    switch (rule.actionFor(had, want, here, run.force)) {
        .keep => {},
        .make => {
            run.made += 1;
            shared.say(run, row, .{ "drawer", where.cstr() });
            if (!run.check and run.dl.CreateDir(where.cstr()) == null) {
                // One that is there already is no fault; anything else is.
                if (run.dl.IoErr() != dos.ERROR_OBJECT_EXISTS) return shared.failed(run, where.cstr(), run.dl.IoErr());
            }
        },
        .write => {
            const entry = want.?;
            const what = if (had == null) "new" else if (here == .gone) "again" else "newer";
            shared.say(run, row, .{ what, where.cstr() });
            run.written += 1;
            run.written_bytes += entry.size;
            if (run.check) return dos.RETURN_OK;
            if (write(run, path, where.cstr(), entry)) |code| return code;
        },
        .kept => {
            run.kept += 1;
            shared.say(run, row, .{ "kept", where.cstr() });
        },
        .delete => {
            run.deleted += 1;
            shared.say(run, row, .{ "gone", where.cstr() });
            if (run.check) return dos.RETURN_OK;
            if (!gone.add(part.rest) or !gone.add("\n")) {
                return shared.fail(run, "no memory for the list of what to delete\n", .{});
            }
        },
    }
    return dos.RETURN_OK;
}

/// One file fetched to a name of its own, held against the list, and
/// renamed into place. Null when it is there; a return code when it is
/// not.
fn write(run: *Run, path: []const u8, where: [*:0]const u8, entry: manifest.Entry) ?i32 {
    const dl = run.dl;
    var sum: u32 = 0;
    var length: u64 = 0;
    if (source.fetch(run, path, shared.part_file, &sum, &length)) |code| return code;
    if (sum != entry.crc or length != entry.size) {
        _ = dl.DeleteFile(shared.part_file);
        return shared.fail(run, "%s did not arrive whole: the list says %x of %ld bytes, what came is %x of %ld\n", .{
            where, entry.crc, entry.size, sum, length,
        });
    }
    // The old file goes only once the new one is whole on the volume.
    _ = dl.DeleteFile(where);
    if (!dl.Rename(shared.part_file, where)) {
        const code = dl.IoErr();
        _ = dl.DeleteFile(shared.part_file);
        return shared.failed(run, where, code);
    }
    return null;
}

/// What the build dropped, deleted in reverse: a drawer after what was
/// in it.
fn remove(run: *Run, gone: *shared.Buffer) i32 {
    if (run.check or gone.at == 0) return dos.RETURN_OK;
    var end = gone.at;
    while (end != 0) {
        var start = end - 1; // the line's own newline
        while (start != 0 and gone.bytes[start - 1] != '\n') start -= 1;
        const rest = gone.bytes[start .. end - 1];
        const where = Name.of(volume, rest);
        if (!run.dl.DeleteFile(where.cstr())) {
            const code = run.dl.IoErr();
            // Gone already, or a drawer something was put in since: said
            // and the rest goes on.
            if (code != dos.ERROR_OBJECT_NOT_FOUND) _ = run.dl.PrintFault(code, where.cstr());
        }
        end = start;
    }
    return dos.RETURN_OK;
}

/// The package's list left as the machine's own, which the next update
/// compares against. It is written last: a run that ends before this
/// looks like one that never happened, and every file it did write is
/// already what the package says, so the next run passes over it.
fn saveList(run: *Run, fresh: []const u8) i32 {
    if (run.check) return if (changed(run)) dos.RETURN_WARN else dos.RETURN_OK;
    if (!changed(run)) return dos.RETURN_OK;
    if (!prefs.save(run.dl, install.installed_manifest, fresh)) {
        return shared.failed(run, install.installed_manifest, run.dl.IoErr());
    }
    shared.say(run, row, .{ "list", install.installed_manifest });
    return dos.RETURN_OK;
}

/// Whether this run has anything to show.
pub fn changed(run: *Run) bool {
    return run.written != 0 or run.deleted != 0 or run.made != 0;
}

/// What the file on the machine is, held against the two lists: read
/// once, and only where the lists differ.
fn hereOf(run: *Run, where: [*:0]const u8, had: ?manifest.Entry, want: ?manifest.Entry) rule.Here {
    var sum: u32 = 0;
    var length: u64 = 0;
    if (!sumOf(run, where, &sum, &length)) return .gone;
    if (had) |entry| {
        if (entry.kind == .file and entry.crc == sum and entry.size == length) return .same;
    }
    if (want) |entry| {
        if (entry.kind == .file and entry.crc == sum and entry.size == length) return .wanted;
    }
    return .changed;
}

/// Whether the path is there at all, which is all that is asked where
/// the two lists say the same about it: what is in it is then its own
/// business, and one that went missing is written again.
fn thereOf(run: *Run, where: [*:0]const u8) rule.Here {
    const lock = run.dl.Lock(where, dos.SHARED_LOCK) orelse return .gone;
    run.dl.UnLock(lock);
    return .unread;
}

/// A file's CRC-32 and its length; false when it is not there.
fn sumOf(run: *Run, where: [*:0]const u8, sum: *u32, length: *u64) bool {
    const dl = run.dl;
    const file = dl.Open(where, dos.MODE_OLDFILE) orelse return false;
    defer _ = dl.Close(file);
    var crc = dos.flashfs.crcStart();
    var total: u64 = 0;
    while (true) {
        const got = dl.Read(file, run.buffer.ptr, @intCast(run.buffer.len));
        if (got <= 0) break;
        const count: usize = @intCast(got);
        crc = dos.flashfs.crcAdd(crc, run.buffer[0..count]);
        total += count;
    }
    sum.* = dos.flashfs.crcEnd(crc);
    length.* = total;
    return true;
}

fn badList(run: *Run, which: []const u8, err: manifest.Error) i32 {
    return shared.fail(run, "%s: %s\n", .{ Name.of("", which).cstr(), manifest.why(err) });
}
