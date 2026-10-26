// SPDX-License-Identifier: MIT
//! The object store: an object by its id, from `.git/objects/xx/<38 hex
//! digits>` - a loose object, zlib over its header and bytes - or from a
//! pack in `objects/pack/`, found through the pack's idx. A pack is read
//! through a window of 32 KiB on its file, so the entries of a delta
//! chain, near one another, come from few reads.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const compression = sdk.compression;
const _git = @import("_git.zig");
const object = @import("object.zig");
const idx = @import("idx.zig");
const packread = @import("packread.zig");
const files = @import("files.zig");
const Git = @import("context.zig").Git;
const ExecBase = sdk.interface.exec.ExecBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const Id = _git.Id;
const Object = packread.Object;

/// The largest idx read, and the largest loose object.
const idx_most = 256 * 1024 * 1024;
const loose_most = 256 * 1024 * 1024;

const PackFile = struct {
    next: ?*PackFile,
    store: *Store,
    idx_bytes: []u8,
    index: idx.Idx,
    /// The pack's path, and its file - opened the first time it is
    /// read - with a window on it.
    path: files.Path,
    window: files.Window,
    reading: packread.Pack,

    fn read(context: *anyopaque, offset: u64, into: []u8) i32 {
        const pack_file: *PackFile = @ptrCast(@alignCast(context));
        if (pack_file.window.file == null) {
            pack_file.window.file = pack_file.window.dl.Open(@ptrCast(&pack_file.path), dos.MODE_OLDFILE) orelse return -1;
        }
        return pack_file.window.read(offset, into);
    }
};

pub const Store = struct {
    git: *Git,
    dir: files.Path,
    dir_length: usize,
    packs: ?*PackFile = null,
    scanned: bool = false,

    pub fn init(store: *Store, git: *Git, dir: []const u8) void {
        store.git = git;
        @memcpy(store.dir[0..dir.len], dir);
        store.dir[dir.len] = 0;
        store.dir_length = dir.len;
        store.packs = null;
        store.scanned = false;
    }

    pub fn deinit(store: *Store) void {
        const git = store.git;
        var pack_file = store.packs;
        while (pack_file) |each| {
            pack_file = each.next;
            if (each.window.file) |file| _ = git.dl.Close(file);
            each.reading.deinit();
            git.free(each.idx_bytes.ptr);
            git.free(each);
        }
        store.packs = null;
        store.scanned = false;
    }

    fn dirText(store: *const Store) []const u8 {
        return store.dir[0..store.dir_length];
    }

    /// The object `id`: null when the store does not have it, or it
    /// cannot be read (said).
    pub fn read(store: *Store, id: *const Id) ?Object {
        if (store.readLoose(id)) |found| return found;
        store.scan();
        var pack_file = store.packs;
        while (pack_file) |each| : (pack_file = each.next) {
            const position = each.index.find(id) orelse continue;
            const offset = each.index.offsetAt(position) orelse continue;
            each.reading.failure = .none;
            return each.reading.readObject(offset) orelse {
                store.saidBroken(id, each.reading.failure);
                return null;
            };
        }
        return null;
    }

    /// Whether the store has the object `id`.
    pub fn has(store: *Store, id: *const Id) bool {
        var path: files.Path = undefined;
        if (store.loosePath(&path, id)) |name| {
            if (store.git.dl.Lock(name, dos.ACCESS_READ)) |lock| {
                store.git.dl.UnLock(lock);
                return true;
            }
        }
        store.scan();
        var pack_file = store.packs;
        while (pack_file) |each| : (pack_file = each.next) {
            if (each.index.find(id) != null) return true;
        }
        return false;
    }

    pub const Found = union(enum) { none, one: Id, many };

    /// The object whose id starts with the hex digits `text` (four at
    /// least): one, none, or more than one.
    pub fn findPrefix(store: *Store, text: []const u8) Found {
        if (text.len < 4 or text.len > 40) return .none;
        var low_id: Id = _git.zero_id;
        for (text, 0..) |char, at| {
            const value: u8 = switch (char) {
                '0'...'9' => char - '0',
                'a'...'f' => char - 'a' + 10,
                'A'...'F' => char - 'A' + 10,
                else => return .none,
            };
            low_id[at / 2] |= if (at % 2 == 0) value << 4 else value;
        }
        var found: Found = .none;
        store.scan();
        var pack_file = store.packs;
        while (pack_file) |each| : (pack_file = each.next) {
            const index = &each.index;
            var low: u32 = if (low_id[0] == 0) 0 else index.fanout(low_id[0] - 1);
            var high: u32 = index.fanout(low_id[0]);
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (_git.order(index.idAt(middle), &low_id) == .less) low = middle + 1 else high = middle;
            }
            var at = low;
            while (at < index.count and startsWithHex(index.idAt(at), text)) : (at += 1) {
                if (!note(&found, index.idAt(at))) return .many;
            }
        }
        // Loose objects: the names in objects/xx that go on as the text
        // does.
        const git = store.git;
        var path: files.Path = undefined;
        const name = files.child(&path, store.dirText(), &.{ "objects/", text[0..2] }) orelse return found;
        const lock = git.dl.Lock(name, dos.ACCESS_READ) orelse return found;
        defer git.dl.UnLock(lock);
        const info = git.create(dos.FileInfoBlock) orelse return found;
        defer git.free(info);
        if (!git.dl.Examine(lock, info)) return found;
        while (git.dl.ExNext(lock, info)) {
            const file_name = files.span(@ptrCast(&info.file_name));
            if (file_name.len != 38 or !sameHex(file_name[0 .. text.len - 2], text[2..])) continue;
            var whole: [40]u8 = undefined;
            @memcpy(whole[0..2], text[0..2]);
            @memcpy(whole[2..], file_name);
            const id = _git.idOf(&whole) orelse continue;
            if (!note(&found, &id)) return .many;
        }
        return found;
    }

    fn lookup(context: *anyopaque, id: *const Id) ?Object {
        const store: *Store = @ptrCast(@alignCast(context));
        return store.read(id);
    }

    fn saidBroken(store: *Store, id: *const Id, failure: packread.Failure) void {
        var hex: [41]u8 = undefined;
        _git.hexOf(id, hex[0..40]);
        hex[40] = 0;
        const what: [*:0]const u8 = switch (failure) {
            .memory => "there is no memory for it",
            .base => "the base of a delta in it is missing",
            .read => "its pack cannot be read",
            else => "its pack is broken",
        };
        store.git.say("can't read object %s: %s\n", .{ @as([*:0]const u8, @ptrCast(&hex)), what });
    }

    /// `objects/xx/<rest>`.
    fn loosePath(store: *const Store, into: *files.Path, id: *const Id) ?[*:0]const u8 {
        var hex: [40]u8 = undefined;
        _git.hexOf(id, &hex);
        return files.child(into, store.dirText(), &.{ "objects/", hex[0..2], "/", hex[2..] });
    }

    fn readLoose(store: *Store, id: *const Id) ?Object {
        const git = store.git;
        var path: files.Path = undefined;
        const name = store.loosePath(&path, id) orelse return null;
        const packed_bytes = files.readWhole(git, name, loose_most) orelse return null;
        defer git.free(packed_bytes.ptr);
        return inflateLoose(git.sys, git.zb, packed_bytes) orelse {
            store.saidBroken(id, .entry);
            return null;
        };
    }

    /// Every pack in `objects/pack`, found the first time one is needed.
    fn scan(store: *Store) void {
        if (store.scanned) return;
        store.scanned = true;
        const git = store.git;
        const dl = git.dl;
        var path: files.Path = undefined;
        const name = files.child(&path, store.dirText(), &.{"objects/pack"}) orelse return;
        const lock = dl.Lock(name, dos.ACCESS_READ) orelse return;
        defer dl.UnLock(lock);
        const info = git.create(dos.FileInfoBlock) orelse return;
        defer git.free(info);
        if (!dl.Examine(lock, info)) return;
        while (dl.ExNext(lock, info)) {
            const file_name = files.span(@ptrCast(&info.file_name));
            if (file_name.len > 4 and _git.same(file_name[file_name.len - 4 ..], ".idx")) {
                _ = store.addPack(file_name[0 .. file_name.len - 4]);
            }
        }
    }

    /// The pack `objects/pack/<base>.pack` and its idx taken into the
    /// store: false, said, when the idx cannot be read.
    pub fn addPack(store: *Store, base: []const u8) bool {
        const git = store.git;
        var path: files.Path = undefined;
        const idx_name = files.child(&path, store.dirText(), &.{ "objects/pack/", base, ".idx" }) orelse return false;
        const idx_bytes = files.readWhole(git, idx_name, idx_most) orelse {
            _ = git.dl.PrintFault(git.dl.IoErr(), idx_name);
            return false;
        };
        const index = idx.Idx.open(idx_bytes) orelse {
            git.say("%s is no pack index\n", .{idx_name});
            git.free(idx_bytes.ptr);
            return false;
        };
        const pack_file = git.create(PackFile) orelse {
            git.free(idx_bytes.ptr);
            return false;
        };
        pack_file.store = store;
        pack_file.idx_bytes = idx_bytes;
        pack_file.index = index;
        pack_file.window.dl = git.dl;
        pack_file.window.file = null;
        pack_file.window.at = 0;
        pack_file.window.length = 0;
        if (files.child(&pack_file.path, store.dirText(), &.{ "objects/pack/", base, ".pack" }) == null) {
            git.free(idx_bytes.ptr);
            git.free(pack_file);
            return false;
        }
        pack_file.reading.init(git.sys, git.zb, .{ .context = pack_file, .read = PackFile.read });
        pack_file.reading.lookup = lookup;
        pack_file.reading.lookup_context = store;
        pack_file.next = store.packs;
        store.packs = pack_file;
        return true;
    }
};

/// `id` noted as found: false when another was found before.
fn note(found: *Store.Found, id: *const Id) bool {
    switch (found.*) {
        .none => found.* = .{ .one = id.* },
        .one => |other| if (!_git.same(&other, id)) return false,
        .many => return false,
    }
    return true;
}

fn startsWithHex(id: *const Id, text: []const u8) bool {
    var hex: [40]u8 = undefined;
    _git.hexOf(id, &hex);
    return sameHex(hex[0..text.len], text);
}

/// Whether two runs of hex digits are alike, their case aside.
fn sameHex(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lower_x = if (x >= 'A' and x <= 'F') x + 32 else x;
        const lower_y = if (y >= 'A' and y <= 'F') y + 32 else y;
        if (lower_x != lower_y) return false;
    }
    return true;
}

/// A loose object's zlib stream inflated: its header read, its bytes in
/// memory of their own; null when it is none.
pub fn inflateLoose(sys: *ExecBase, zb: *CompressionBase, packed_bytes: []const u8) ?Object {
    var stream: compression.Stream = .{};
    if (zb.InitInflate(&stream, compression.FORMAT_ZLIB) != compression.COMPRESS_OK) return null;
    defer zb.EndInflate(&stream);
    stream.next_in = packed_bytes.ptr;
    stream.avail_in = @intCast(packed_bytes.len);
    var head: [64]u8 = undefined;
    stream.next_out = &head;
    stream.avail_out = head.len;
    var result = zb.Inflate(&stream, compression.FLUSH_FINISH);
    if (result != compression.COMPRESS_OK and result != compression.COMPRESS_END) return null;
    const produced = head.len - stream.avail_out;
    const parsed = object.parseHeader(head[0..produced]) orelse return null;
    if (parsed.size > loose_most) return null;
    const size: usize = @intCast(parsed.size);
    const already = produced - parsed.body_at;
    if (already > size) return null;
    var data: []u8 = &.{};
    if (size != 0) {
        const block = sys.AllocVec(size, exec.MEMF_ANY) orelse return null;
        data = @as([*]u8, @ptrCast(block))[0..size];
    }
    @memcpy(data[0..already], head[parsed.body_at..produced]);
    // A small object came whole with its header; the rest of a larger
    // one goes straight to its place.
    var complete = already == size;
    if (result != compression.COMPRESS_END) {
        stream.next_out = data.ptr + already;
        stream.avail_out = @intCast(size - already);
        result = zb.Inflate(&stream, compression.FLUSH_FINISH);
        complete = stream.avail_out == 0;
    }
    if (result != compression.COMPRESS_END or !complete) {
        if (size != 0) sys.FreeVec(data.ptr);
        return null;
    }
    return .{ .kind = parsed.kind, .data = data };
}
