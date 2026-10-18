// SPDX-License-Identifier: MPL-2.0
//! The power cut at every write: a seeded list of changes run on a fresh
//! volume until the medium dies at write N, then what is left mounted -
//! and cut again while replay runs - and the volume read back. It must be
//! clean, and be what the changes answered before the cut made it, or
//! that and the change the cut fell in: never anything else, never a mix.
//! With snapshots among the changes, what each snapshot holds is part of
//! what the volume must be.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const dos = sdk.dos;
const testmedia = @import("../testmedia.zig");
const TestMedia = testmedia.TestMedia;
const fs_core = @import("../fs.zig");
const util = @import("fs.zig");
const FileSystem = fs_core.FileSystem;
const FileHandle = dos.FileHandle;
const FileInfoBlock = dos.FileInfoBlock;
const layout = dos.posfs.layout;
const packets = dos.posfs.packets;

const names = [_][:0]const u8{ "alpha", "beta", "gamma", "delta", "Drawer/eps", "Drawer/zeta" };
const snapshot_names = [_][:0]const u8{ "s0", "s1", "s2" };

const Op = union(enum) {
    /// MODE_NEWFILE and `len` bytes.
    write: struct { name: u8, len: u32, seed: u8 },
    /// `len` bytes over the file from `at` (its end at most).
    update: struct { name: u8, at: u32, len: u32, seed: u8 },
    cut: struct { name: u8, size: u32 },
    delete: u8,
    rename: struct { from: u8, to: u8 },
    comment: struct { name: u8, seed: u8 },
    /// A snapshot made, deleted, and the volume rolled back to the newest.
    snapshot: u8,
    drop: u8,
    rollback,
};

/// What the volume holds, as the changes answered make it.
const File = struct { data: std.ArrayList(u8) = .empty, comment: u8 = 0 };
const Files = [names.len]?File;

fn cloneFiles(files: *const Files) !Files {
    var copy: Files = @splat(null);
    for (files, 0..) |file, index| {
        if (file) |it| copy[index] = .{ .data = try it.data.clone(testing.allocator), .comment = it.comment };
    }
    return copy;
}

fn freeFiles(files: *Files) void {
    for (files) |*file| {
        if (file.*) |*it| it.data.deinit(testing.allocator);
        file.* = null;
    }
}

/// A snapshot as the model has it: when it was made among the others, and
/// its files.
const Kept = struct { order: u32, files: Files };

const State = struct {
    files: Files = @splat(null),
    kept: [snapshot_names.len]?Kept = @splat(null),
    /// The snapshots made, the deletes and the rollbacks answered.
    made: u32 = 0,
    dropped: u32 = 0,
    rolled: u32 = 0,

    fn clone(state: *const State) !State {
        var copy: State = .{ .made = state.made, .dropped = state.dropped, .rolled = state.rolled };
        copy.files = try cloneFiles(&state.files);
        for (state.kept, 0..) |kept, index| {
            if (kept) |it| copy.kept[index] = .{ .order = it.order, .files = try cloneFiles(&it.files) };
        }
        return copy;
    }

    fn deinit(state: *State) void {
        freeFiles(&state.files);
        for (&state.kept) |*kept| {
            if (kept.*) |*it| freeFiles(&it.files);
        }
    }

    /// The newest snapshot.
    fn newest(state: *const State) ?usize {
        var found: ?usize = null;
        for (state.kept, 0..) |kept, index| {
            const it = kept orelse continue;
            if (found == null or it.order > state.kept[found.?].?.order) found = index;
        }
        return found;
    }
};

fn bytesOf(seed: u8, len: usize, into: []u8) []u8 {
    for (into[0..len], 0..) |*byte, index| byte.* = @truncate(index *% 31 +% seed *% 7 +% (index >> 9));
    return into[0..len];
}

fn plan(seed: u64, count: usize, into: []Op, snapshots: bool) []Op {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (into[0..count]) |*op| {
        const name = random.uintLessThan(u8, names.len);
        op.* = switch (random.uintLessThan(u32, if (snapshots) 14 else 10)) {
            0...3 => .{ .write = .{ .name = name, .len = if (random.boolean()) random.uintLessThan(u32, 600) else random.uintLessThan(u32, 30_000), .seed = random.int(u8) } },
            4, 5 => .{ .update = .{ .name = name, .at = random.uintLessThan(u32, 20_000), .len = random.uintLessThan(u32, 9000), .seed = random.int(u8) } },
            6 => .{ .cut = .{ .name = name, .size = random.uintLessThan(u32, 15_000) } },
            7 => .{ .delete = name },
            8 => .{ .rename = .{ .from = name, .to = random.uintLessThan(u8, names.len) } },
            9 => .{ .comment = .{ .name = name, .seed = random.int(u8) } },
            10, 11 => .{ .snapshot = random.uintLessThan(u8, snapshot_names.len) },
            12 => .{ .drop = random.uintLessThan(u8, snapshot_names.len) },
            else => .rollback,
        };
    }
    return into[0..count];
}

var scratch: [40_000]u8 = undefined;

/// One change made through the packets, and the model moved with it when
/// it was answered yes. False when the volume refused it.
fn apply(fs: *FileSystem, op: Op, state: *State) !bool {
    switch (op) {
        .write => |w| {
            const bytes = bytesOf(w.seed, w.len, &scratch);
            var fh: FileHandle = .{};
            if (util.openFile(fs, &fh, .findoutput, names[w.name]).res1 != dos.DOSTRUE) return false;
            const wrote = util.writeTo(fs, &fh, bytes).res1 == bytes.len;
            if (util.closeFile(fs, &fh).res1 != dos.DOSTRUE or !wrote) return false;
            // A file written over keeps its comment.
            var comment: u8 = 0;
            if (state.files[w.name]) |*file| {
                comment = file.comment;
                file.data.deinit(testing.allocator);
            }
            state.files[w.name] = .{ .comment = comment };
            try state.files[w.name].?.data.appendSlice(testing.allocator, bytes);
        },
        .update => |u| {
            const file = &(state.files[u.name] orelse return false);
            const at = @min(u.at, file.data.items.len);
            const bytes = bytesOf(u.seed, u.len, &scratch);
            var fh: FileHandle = .{};
            if (util.openFile(fs, &fh, .findupdate, names[u.name]).res1 != dos.DOSTRUE) return false;
            const moved = util.sendSeek(fs, .seek, &fh, @intCast(at), dos.OFFSET_BEGINNING).reply.res1 == dos.DOSTRUE;
            const wrote = moved and util.writeTo(fs, &fh, bytes).res1 == bytes.len;
            if (util.closeFile(fs, &fh).res1 != dos.DOSTRUE or !wrote) return false;
            const end = at + bytes.len;
            if (end > file.data.items.len) try file.data.resize(testing.allocator, end);
            @memcpy(file.data.items[at..end], bytes);
        },
        .cut => |c| {
            const file = &(state.files[c.name] orelse return false);
            var fh: FileHandle = .{};
            if (util.openFile(fs, &fh, .findupdate, names[c.name]).res1 != dos.DOSTRUE) return false;
            const done = util.sendSeek(fs, .set_file_size, &fh, c.size, dos.OFFSET_BEGINNING).reply.res1 == dos.DOSTRUE;
            if (util.closeFile(fs, &fh).res1 != dos.DOSTRUE or !done) return false;
            const old = file.data.items.len;
            try file.data.resize(testing.allocator, c.size);
            if (c.size > old) @memset(file.data.items[old..], 0);
        },
        .delete => |name| {
            if (state.files[name] == null) return false;
            if (util.send(fs, .delete_object, .{ 0, util.arg(names[name].ptr), 0, 0 }).res1 != dos.DOSTRUE) return false;
            state.files[name].?.data.deinit(testing.allocator);
            state.files[name] = null;
        },
        .rename => |r| {
            if (state.files[r.from] == null or state.files[r.to] != null) return false;
            if (util.sendArgs(fs, .rename_object, .{ .rename = .{ .from_lock = null, .from_name = names[r.from], .to_lock = null, .to_name = names[r.to] } }).res1 != dos.DOSTRUE) return false;
            state.files[r.to] = state.files[r.from];
            state.files[r.from] = null;
        },
        .comment => |c| {
            if (state.files[c.name] == null) return false;
            var text: [8:0]u8 = @splat(0);
            text[0] = 'c';
            text[1] = 'a' + c.seed % 26;
            if (util.sendArgs(fs, .set_comment, .{ .property = .{ .lock = null, .name = names[c.name], .value = util.arg(&text) } }).res1 != dos.DOSTRUE) return false;
            state.files[c.name].?.comment = text[1];
        },
        .snapshot => |which| {
            if (state.kept[which] != null) return false;
            if (!snapshotAction(fs, packets.ACTION_POSFS_MAKE_SNAPSHOT, which)) return false;
            state.kept[which] = .{ .order = state.made, .files = try cloneFiles(&state.files) };
            state.made += 1;
        },
        .drop => |which| {
            if (state.kept[which] == null) return false;
            if (!snapshotAction(fs, packets.ACTION_POSFS_DELETE_SNAPSHOT, which)) return false;
            freeFiles(&state.kept[which].?.files);
            state.kept[which] = null;
            state.dropped += 1;
        },
        .rollback => {
            const which = state.newest() orelse return false;
            if (!snapshotAction(fs, packets.ACTION_POSFS_ROLLBACK, @intCast(which))) return false;
            freeFiles(&state.files);
            state.files = try cloneFiles(&state.kept[which].?.files);
            state.rolled += 1;
        },
    }
    return true;
}

fn snapshotAction(fs: *FileSystem, action: i32, which: u8) bool {
    var args: packets.SnapshotArgs = .{ .name = snapshot_names[which] };
    return util.sendOwn(fs, action, &args).res1 == dos.DOSTRUE;
}

/// Whether the volume holds exactly `state`: its files, and its
/// snapshots with theirs.
fn holds(fs: *FileSystem, state: *const State) !bool {
    if (!try filesHeld(fs, "", &state.files)) return false;
    for (snapshot_names, 0..) |snapshot, index| {
        var prefix: [32]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&prefix, ".snapshots/{s}", .{snapshot}) catch unreachable;
        const lock = util.send(fs, .locate_object, .{ 0, util.arg(dir.ptr), dos.SHARED_LOCK, 0 });
        if (lock.res1 != 0) _ = util.send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });
        const kept = state.kept[index] orelse {
            if (lock.res1 != 0) return false;
            continue;
        };
        if (lock.res1 == 0) return false;
        prefix[dir.len] = '/';
        if (!try filesHeld(fs, prefix[0 .. dir.len + 1], &kept.files)) return false;
    }
    return true;
}

/// Whether the files under `prefix` are exactly `files`.
fn filesHeld(fs: *FileSystem, prefix: []const u8, files: *const Files) !bool {
    for (names, 0..) |short, index| {
        var path: [64:0]u8 = @splat(0);
        const name = std.fmt.bufPrintZ(&path, "{s}{s}", .{ prefix, short }) catch unreachable;
        var fh: FileHandle = .{};
        const opened = util.openFile(fs, &fh, .findinput, name);
        const file = files[index] orelse {
            if (opened.res1 == dos.DOSTRUE) {
                _ = util.closeFile(fs, &fh);
                return false;
            }
            continue;
        };
        if (opened.res1 != dos.DOSTRUE) return false;
        const count = util.readFrom(fs, &fh, &scratch);
        _ = util.closeFile(fs, &fh);
        if (count.res1 < 0 or !std.mem.eql(u8, scratch[0..@intCast(count.res1)], file.data.items)) return false;
        const lock = util.send(fs, .locate_object, .{ 0, util.arg(name.ptr), dos.SHARED_LOCK, 0 });
        var fib: FileInfoBlock = undefined;
        _ = util.sendArgs(fs, .examine_object, .{ .examine = .{ .lock = @ptrFromInt(@as(usize, @bitCast(lock.res1))), .fib = &fib } });
        _ = util.send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });
        if (file.comment == 0) {
            if (fib.comment[0] != 0) return false;
        } else if (fib.comment[0] != 'c' or fib.comment[1] != file.comment) return false;
    }
    return true;
}

/// A fresh volume, the directory the names need, and the changes run on
/// it: the states after each one answered, and the change the power went
/// in (the length when it never did).
fn runTo(m: *TestMedia, fs: *FileSystem, ops: []const Op, states: *std.ArrayList(State)) !usize {
    var state: State = .{};
    defer state.deinit();
    try states.append(testing.allocator, try state.clone());
    for (ops, 0..) |op, index| {
        _ = try apply(fs, op, &state);
        // Now and then the handler is idle: a checkpoint.
        if (index % 4 == 3) fs.idle() catch {};
        if (m.dead) return index;
        try states.append(testing.allocator, try state.clone());
    }
    return ops.len;
}

fn freeStates(states: *std.ArrayList(State)) void {
    for (states.items) |*state| state.deinit();
    states.deinit(testing.allocator);
}

fn formatted(kind: testmedia.Kind, block_size: u32, seed: u64, settings: u32) !struct { m: TestMedia } {
    var m = try TestMedia.init(kind, 512 * 1024, seed);
    errdefer m.deinit();
    var fs = FileSystem.init(m.device());
    try fs.format(.{ .block_size = block_size, .name = "Cut", .settings = settings & ~(small_jobs | with_snapshots) });
    // Recycled keeps one: every delete after the first deletes the one
    // before for good.
    if (settings & layout.VT_RECYCLED != 0) {
        var limit: packets.Settings = .{ .mask = packets.SET_RECYCLED, .settings = packets.SET_RECYCLED, .recycled_max_count = 1 };
        try testing.expectEqual(dos.DOSTRUE, util.sendOwn(&fs, packets.ACTION_POSFS_SETTINGS, &limit).res1);
    }
    const dir = util.send(&fs, .create_dir, .{ 0, util.arg("Drawer"), 0, 0 });
    try testing.expect(dir.res1 != 0);
    _ = util.send(&fs, .free_lock, .{ dir.res1, 0, 0, 0 });
    try fs.unmount();
    fs.deinit();
    return .{ .m = m };
}

/// The harness's own switches beside the volume's: a delete of a file of
/// more than two blocks goes as a job, so cuts fall into the jobs too; and
/// snapshots are made, deleted and rolled back to among the changes.
const small_jobs: u32 = 1 << 31;
const with_snapshots: u32 = 1 << 30;

/// The file system over a medium, as `settings` has it.
fn fileSystem(m: *TestMedia, settings: u32) FileSystem {
    var fs = FileSystem.init(m.device());
    if (settings & small_jobs != 0) fs.job_blocks = 2;
    return fs;
}

/// Mounted after the cut, and the state one of those allowed: before the
/// change the cut fell in, after it - or, for a file written under a new
/// name, between its Open and its Close, the file there and empty.
fn expectRecovered(copy: *TestMedia, states: []State, at: usize, op: ?Op, settings: u32) !void {
    var fs = fileSystem(copy, settings);
    defer fs.deinit();
    try fs.mount();
    try util.expectClean(&fs);
    const before = &states[at];
    if (try holds(&fs, before)) return;
    if (at + 1 < states.len and try holds(&fs, &states[at + 1])) return;
    if (op) |change| switch (change) {
        .write => |w| if (before.files[w.name] == null) {
            var opened = try before.clone();
            defer opened.deinit();
            opened.files[w.name] = .{};
            if (try holds(&fs, &opened)) return;
        },
        else => {},
    };
    std.debug.print("after a cut in change {d}: neither the state before it nor after\n", .{at});
    return error.TestUnexpectedResult;
}

fn run(kind: testmedia.Kind, block_size: u32, seed: u64, op_count: usize, stride: u32) !void {
    try runWith(kind, block_size, seed, op_count, stride, layout.VT_CHECKSUMS);
}

/// `run` on a volume with the switches `settings` (VT_*) on.
fn runWith(kind: testmedia.Kind, block_size: u32, seed: u64, op_count: usize, stride: u32, settings: u32) !void {
    _ = try runCounted(kind, block_size, seed, op_count, stride, settings);
}

/// The snapshot changes a run without a cut had answered.
const Counts = struct { made: u32, dropped: u32, rolled: u32 };

fn runCounted(kind: testmedia.Kind, block_size: u32, seed: u64, op_count: usize, stride: u32, settings: u32) !Counts {
    var buffer: [64]Op = undefined;
    const ops = plan(seed, op_count, &buffer, settings & with_snapshots != 0);
    var base = try formatted(kind, block_size, seed, settings);
    defer base.m.deinit();
    // The whole list without a cut: the states it goes through, and the
    // writes it takes.
    var states: std.ArrayList(State) = .empty;
    defer freeStates(&states);
    var counts: Counts = undefined;
    const total = blk: {
        var m = try base.m.image(seed);
        defer m.deinit();
        var fs = fileSystem(&m, settings);
        defer fs.deinit();
        try fs.mount();
        _ = try runTo(&m, &fs, ops, &states);
        try util.expectClean(&fs);
        const last = &states.items[states.items.len - 1];
        try testing.expect(try holds(&fs, last));
        counts = .{ .made = last.made, .dropped = last.dropped, .rolled = last.rolled };
        break :blk m.writes;
    };
    var cut: u32 = 0;
    while (cut < total) : (cut += stride) {
        var m = try base.m.image(seed + cut);
        defer m.deinit();
        m.cut_at = cut;
        m.cut_bytes = (cut * 97) % 512;
        var seen: std.ArrayList(State) = .empty;
        defer freeStates(&seen);
        const at = blk: {
            var fs = fileSystem(&m, settings);
            defer fs.deinit();
            try fs.mount();
            break :blk try runTo(&m, &fs, ops, &seen);
        };
        m.cut();
        var copy = try m.image(seed * 31 + cut);
        defer copy.deinit();
        // Cut again while replay writes, then mounted once more.
        {
            var again = try copy.image(seed + 7);
            defer again.deinit();
            again.cut_at = cut % 5;
            var fs = fileSystem(&again, settings);
            fs.mount() catch {};
            fs.deinit();
            again.cut();
            var after = try again.image(seed + 9);
            defer after.deinit();
            try expectRecovered(&after, states.items, at, if (at < ops.len) ops[at] else null, settings);
        }
        try expectRecovered(&copy, states.items, at, if (at < ops.len) ops[at] else null, settings);
    }
    return counts;
}

test "the power cut at every write: on flash" {
    try run(.flash, 4096, 11, 40, 1);
}

test "the power cut at every write: on a card" {
    try run(.sd, 4096, 12, 40, 1);
    try run(.sd, 1024, 13, 16, 3);
}

test "the power cut at every write: on a stick" {
    try run(.usb, 4096, 14, 40, 1);
}

test "the power cut at every write: compressed, and without checksums" {
    try runWith(.flash, 4096, 15, 40, 1, layout.VT_CHECKSUMS | layout.VT_COMPRESS);
    try runWith(.sd, 4096, 16, 40, 2, layout.VT_COMPRESS);
    try runWith(.sd, 4096, 17, 24, 3, 0);
}

test "the power cut at every write: with Recycled, and deletes as jobs" {
    try runWith(.flash, 4096, 18, 40, 1, layout.VT_CHECKSUMS | layout.VT_RECYCLED | small_jobs);
    try runWith(.sd, 4096, 19, 40, 1, layout.VT_CHECKSUMS | small_jobs);
    try runWith(.usb, 4096, 20, 40, 2, layout.VT_RECYCLED);
}

test "the power cut at every write: with snapshots, deleted and rolled back to" {
    const runs = [_]Counts{
        try runCounted(.flash, 4096, 21, 40, 1, layout.VT_CHECKSUMS | with_snapshots),
        try runCounted(.sd, 4096, 22, 40, 1, layout.VT_CHECKSUMS | layout.VT_RECYCLED | with_snapshots),
        try runCounted(.usb, 4096, 23, 40, 2, layout.VT_COMPRESS | small_jobs | with_snapshots),
    };
    // Each made, deleted and rolled back to snapshots.
    for (runs) |counts| try testing.expect(counts.made > 1 and counts.dropped > 0 and counts.rolled > 0);
}

test "the power cut at every write: more seeds, with -Dposfs-soak" {
    const seeds = @import("test_options").posfs_soak;
    var seed: u64 = 100;
    while (seed < 100 + seeds) : (seed += 1) {
        try run(.flash, 4096, seed, 40, 1);
        try run(.sd, if (seed % 2 == 0) 4096 else 1024, seed, 40, 1);
        try run(.usb, 4096, seed, 40, 1);
        try runWith(.sd, 4096, seed, 40, 1, layout.VT_CHECKSUMS | layout.VT_COMPRESS);
        try runWith(.flash, 4096, seed, 40, 1, layout.VT_CHECKSUMS | layout.VT_RECYCLED | small_jobs);
        try runWith(.usb, 4096, seed, 40, 1, layout.VT_CHECKSUMS | small_jobs);
        try runWith(if (seed % 2 == 0) .flash else .sd, 4096, seed, 40, 1, layout.VT_CHECKSUMS | with_snapshots);
    }
}
