// SPDX-License-Identifier: MIT
//! The files onto the volumes the disk half made, and the list of them
//! left behind.
//!
//! Two sources, one copy. A **package** brings a manifest, so its own
//! list says what to make and what to copy, and every file is held
//! against the sum and the length in it as it goes: an install from a
//! package that arrived damaged stops on the file that is wrong, and the
//! list it leaves is the package's own text. The **running system**
//! brings no list, so the volume is walked and the list is written from
//! what went over - the sum of every file worked out while it is copied,
//! so that nothing is read twice.
//!
//! What the install leaves on the new system volume is that list
//! (`install.installed_manifest`), which is what an update compares
//! against, and `ENVARC:Sys/install.prefs`, which says what was
//! installed where and from where. Neither is in the list: they are the
//! machine's own record, not part of the system, and an update that found
//! them in a list would take them for files a newer package had dropped.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const install = sdk.install;
const manifest = install.manifest;
const prefs = sdk.prefs;
const shared = @import("_install.zig");
const Run = shared.Run;
const Drive = shared.Drive;
const ExecBase = sdk.interface.exec.ExecBase;

/// The volume the running system is on, and what a path on it begins
/// with.
const running_source = "SYS:";

/// Where ENVARC: is on a volume: the drawer S:Startup-Sequence assigns
/// it to. The new volume is not SYS: yet, so the install writes there by
/// the path itself.
const envarc_drawer = "Prefs/Env-Archive/";

/// What a walk of the running system leaves out: the machine's own
/// record of itself, which the install writes afresh.
const machines_own = [_][]const u8{
    install.installed_manifest[running_source.len..],
    envarc_drawer ++ "Sys/install.prefs",
};

/// How much is read and written at a time.
const buffer_bytes: usize = 64 * 1024;

/// The longest path either half can name, with a drive's name before it.
const max_path = manifest.max_path + dos.MAX_DEVICE_NAME + 2;

/// A buffer that grows, in memory of its own.
const Buffer = struct {
    sys: *ExecBase,
    memory: ?*anyopaque = null,
    bytes: []u8 = &.{},
    at: usize = 0,

    fn room(buffer: *Buffer, more: usize) bool {
        if (buffer.at + more <= buffer.bytes.len) return true;
        var want: usize = if (buffer.bytes.len == 0) 16 * 1024 else buffer.bytes.len;
        while (want < buffer.at + more) want *= 2;
        const got = buffer.sys.AllocVec(want, exec.MEMF_ANY) orelse return false;
        const fresh: [*]u8 = @ptrCast(got);
        @memcpy(fresh[0..buffer.at], buffer.bytes[0..buffer.at]);
        if (buffer.memory) |old| buffer.sys.FreeVec(old);
        buffer.memory = got;
        buffer.bytes = fresh[0..want];
        return true;
    }

    fn add(buffer: *Buffer, from: []const u8) bool {
        if (!buffer.room(from.len)) return false;
        @memcpy(buffer.bytes[buffer.at..][0..from.len], from);
        buffer.at += from.len;
        return true;
    }

    fn text(buffer: *const Buffer) []const u8 {
        return buffer.bytes[0..buffer.at];
    }

    fn free(buffer: *Buffer) void {
        if (buffer.memory) |memory| buffer.sys.FreeVec(memory);
        buffer.memory = null;
        buffer.bytes = &.{};
        buffer.at = 0;
    }
};

/// One line of the list being built: where its path is in the paths
/// buffer, and what the file turned out to be.
const Item = struct {
    kind: manifest.Kind,
    at: u32,
    length: u32,
    crc: u32,
    size: u64,
};

/// The list built while the running system is copied.
const List = struct {
    sys: *ExecBase,
    paths: Buffer,
    items: Buffer,
    count: usize = 0,
    counts: manifest.Counts = .{},

    fn init(sys: *ExecBase) List {
        return .{ .sys = sys, .paths = .{ .sys = sys }, .items = .{ .sys = sys } };
    }

    fn free(list: *List) void {
        list.paths.free();
        list.items.free();
    }

    fn all(list: *const List) []Item {
        if (list.count == 0) return &.{};
        const items: [*]Item = @ptrCast(@alignCast(list.items.bytes.ptr));
        return items[0..list.count];
    }

    fn pathOf(list: *const List, item: Item) []const u8 {
        return list.paths.bytes[item.at..][0..item.length];
    }

    /// One entry kept, by the path a manifest names it with - the half's
    /// own drawer in front of it.
    fn add(list: *List, kind: manifest.Kind, path: []const u8, crc: u32, size: u64) bool {
        if (!list.items.room(@sizeOf(Item))) return false;
        const at = list.paths.at;
        if (!list.paths.add(path)) return false;
        const items: [*]Item = @ptrCast(@alignCast(list.items.bytes.ptr));
        items[list.count] = .{ .kind = kind, .at = @intCast(at), .length = @intCast(path.len), .crc = crc, .size = size };
        list.count += 1;
        list.items.at += @sizeOf(Item);
        list.counts.add(.{ .kind = kind, .path = path, .crc = crc, .size = size });
        return true;
    }

    /// The entries put in the order a manifest's lines are in, which its
    /// reader insists on: a list written from a walk is then the same
    /// list a package would bring. Heapsort - a system volume is
    /// thousands of entries, and this is in memory, not on the disk.
    fn sort(list: *List) void {
        const items = list.all();
        if (items.len < 2) return;
        var start = items.len / 2;
        while (start > 0) {
            start -= 1;
            list.sift(items, start, items.len);
        }
        var end = items.len;
        while (end > 1) {
            end -= 1;
            const first = items[0];
            items[0] = items[end];
            items[end] = first;
            list.sift(items, 0, end);
        }
    }

    fn sift(list: *List, items: []Item, from: usize, end: usize) void {
        var root = from;
        while (root * 2 + 1 < end) {
            var child = root * 2 + 1;
            if (child + 1 < end and list.before(items[child], items[child + 1])) child += 1;
            if (!list.before(items[root], items[child])) return;
            const held = items[root];
            items[root] = items[child];
            items[child] = held;
            root = child;
        }
    }

    fn before(list: *const List, one: Item, other: Item) bool {
        return manifest.orderPaths(list.pathOf(one), list.pathOf(other)) == .before;
    }

    /// The whole list as a manifest's text, into a buffer of its own;
    /// null when there is no memory for it.
    fn written(list: *List, header: manifest.Header) ?Buffer {
        var text: Buffer = .{ .sys = list.sys };
        var settings = header;
        settings.counts = list.counts;
        var line: [manifest.max_header]u8 = undefined;
        if (!text.add(manifest.preamble) or
            !text.add(line[0..manifest.headerLine(settings, &line)]))
        {
            text.free();
            return null;
        }
        for (list.all()) |item| {
            const entry: manifest.Entry = .{
                .kind = item.kind,
                .path = list.pathOf(item),
                .crc = item.crc,
                .size = item.size,
            };
            if (!text.room(manifest.entryLength(entry))) {
                text.free();
                return null;
            }
            text.at += manifest.entryLine(entry, text.bytes[text.at..]);
        }
        return text;
    }
};

/// A path with a drive's name in front of it.
const Path = struct {
    bytes: [max_path:0]u8 = @splat(0),

    fn of(drive: *const Drive, rest: []const u8) Path {
        var path: Path = .{};
        const name = drive.path();
        var at = shared.copy(&path.bytes, name[0..shared.length(name)]);
        at += shared.copy(path.bytes[at..], rest);
        path.bytes[at] = 0;
        return path;
    }

    fn text(path: *const Path) [*:0]const u8 {
        return @ptrCast(&path.bytes);
    }
};

/// What the source says of itself, before anything is written: that it is
/// there, and that its files are for this machine. The board this
/// machine's own boot files are for is what a package's is held against -
/// a kernel built for the other board of a chip starts with no console -
/// and FORCE is how that is overridden.
pub fn look(run: *Run) i32 {
    var here: [32:0]u8 = @splat(0);
    boardHere(run, &here);
    switch (run.kind) {
        .running => {
            if (here[0] == 0) {
                return shared.fail(run, "%s says nothing about the boot files in %s: there is nothing to install from\n", .{ install.boot_manifest, install.boot_store });
            }
            _ = shared.copy(&run.board, here[0 .. shared.length(@ptrCast(&here)) + 1]);
            return dos.RETURN_OK;
        },
        .directory => {
            var path: [max_path:0]u8 = @splat(0);
            const root = shared.copy(&path, run.from[0..shared.length(run.from)]);
            path[joined(&path, root, install.package_manifest)] = 0;
            const name: [*:0]const u8 = @ptrCast(&path);
            const text = prefs.loadWhole(run.sys, run.dl, name) orelse {
                return shared.fail(run, "%s is not there: FROM names a release package, which holds one\n", .{name});
            };
            defer run.sys.FreeVec(@ptrCast(text.ptr));
            const reader = manifest.Reader.init(text) catch |err| {
                return shared.fail(run, "%s: %s\n", .{ name, manifest.why(err) });
            };
            if (reader.header.chip != sdk.hardware.chip) {
                return shared.fail(run, "%s holds files for %s; this machine is %s\n", .{
                    name,
                    @as([*:0]const u8, @tagName(reader.header.chip)),
                    @as([*:0]const u8, @tagName(sdk.hardware.chip)),
                });
            }
            if (reader.header.board.len != 0) {
                const got = shared.copy(&run.board, reader.header.board);
                run.board[got] = 0;
            }
            const mine = here[0..shared.length(@ptrCast(&here))];
            if (!run.force and mine.len != 0 and reader.header.board.len != 0 and
                !manifest.samePath(mine, reader.header.board))
            {
                return shared.fail(run, "%s holds a kernel for %s, and this machine is %s: a kernel for another board starts with no console. FORCE installs it all the same\n", .{
                    name,
                    @as([*:0]const u8, @ptrCast(&run.board)),
                    @as([*:0]const u8, @ptrCast(&here)),
                });
            }
            run.files = reader.header.counts.files;
            run.bytes = reader.header.counts.bytes;
            return dos.RETURN_OK;
        },
    }
}

/// The board this machine's own boot files are for, as `SYS:Storage`
/// says; empty where it says nothing.
fn boardHere(run: *Run, into: *[32:0]u8) void {
    into[0] = 0;
    const text = prefs.loadWhole(run.sys, run.dl, install.boot_manifest) orelse return;
    defer run.sys.FreeVec(@ptrCast(text.ptr));
    const reader = manifest.Reader.init(text) catch return;
    if (reader.header.chip != sdk.hardware.chip) return;
    if (reader.header.board.len == 0 or reader.header.board.len > 31) return;
    into[shared.copy(into, reader.header.board)] = 0;
}

/// Everything onto the volumes, and the list and the settings left
/// behind.
pub fn copy(run: *Run) i32 {
    const buffer = run.sys.AllocVec(buffer_bytes, exec.MEMF_ANY) orelse return noRoom(run);
    defer run.sys.FreeVec(buffer);
    const bytes: [*]u8 = @ptrCast(buffer);
    const code = switch (run.kind) {
        .running => fromRunning(run, bytes[0..buffer_bytes]),
        .directory => fromPackage(run, bytes[0..buffer_bytes]),
    };
    if (code != dos.RETURN_OK) return code;
    return leavePrefs(run);
}

/// The running system copied: the volume walked, and the boot half taken
/// from what the build left in `SYS:Storage/Boot`. The list is written
/// from what went over.
fn fromRunning(run: *Run, buffer: []u8) i32 {
    var list = List.init(run.sys);
    defer list.free();

    shared.say(run, "  the system's files onto %s\n", .{run.system.path()});
    if (walk(run, &list, buffer, running_source, .system, &run.system, true)) |code| return code;

    for (run.boot[0..run.slots], 0..) |*drive, slot| {
        shared.say(run, "  the boot files onto %s\n", .{drive.path()});
        // Every boot partition holds the same files, so that either one
        // starts the machine: one list covers them, and they are counted
        // once.
        var ignored = List.init(run.sys);
        defer ignored.free();
        const into: *List = if (slot == 0) &list else &ignored;
        if (walk(run, into, buffer, install.boot_store, .boot, drive, slot == 0)) |code| return code;
    }

    list.sort();
    var header: manifest.Header = .{ .chip = sdk.hardware.chip };
    const board = run.board[0..shared.length(@ptrCast(&run.board))];
    if (board.len != 0) header.board = board;
    var text = list.written(header) orelse return noRoom(run);
    defer text.free();
    return saveList(run, text.text());
}

/// One tree copied onto one drive, every file summed as it goes and kept
/// in the list under its half's drawer.
fn walk(run: *Run, list: *List, buffer: []u8, from: []const u8, half: install.Half, drive: *const Drive, count: bool) ?i32 {
    const dl = run.dl;
    const Anchor = extern struct { ap: dos.AnchorPath, buf: [manifest.max_path + 64]u8 };
    const anchor_memory = run.sys.AllocVec(@sizeOf(Anchor), exec.MEMF_CLEAR) orelse return noRoom(run);
    defer run.sys.FreeVec(anchor_memory);
    const anchor: *Anchor = @ptrCast(@alignCast(anchor_memory));
    anchor.ap.strlen = @intCast(anchor.buf.len);
    anchor.ap.break_bits = exec.SIGBREAKF_CTRL_C;
    anchor.ap.flags = dos.APF_DODIR;

    // The pattern is the tree and everything under it; what follows the
    // base in each full path is the path on the volume.
    var pattern: [max_path:0]u8 = @splat(0);
    var at = shared.copy(&pattern, from);
    if (pattern[at - 1] != ':' and pattern[at - 1] != '/') at += shared.copy(pattern[at..], "/");
    const base = at;
    at += shared.copy(pattern[at..], "#?");
    pattern[at] = 0;
    const named: [*:0]const u8 = @ptrCast(&pattern);

    // The half's own drawer, as a list over a whole package holds it: a
    // list written here is then the same list a package brings.
    if (!list.add(.drawer, install.half_names[@intFromEnum(half)], 0, 0)) return noRoom(run);

    var err = dl.MatchFirst(named, &anchor.ap);
    defer dl.MatchEnd(&anchor.ap);
    if (err == dos.ERROR_NO_MORE_ENTRIES) return null; // an empty tree
    while (err == 0) {
        const ap = &anchor.ap;
        if (ap.flags & dos.APF_DIDDIR != 0) {
            ap.flags &= ~dos.APF_DIDDIR;
            err = dl.MatchNext(ap);
            continue;
        }
        if (shared.stopped(run)) return dos.RETURN_WARN;

        const whole: [*:0]const u8 = @ptrCast(ap.buffer());
        const rest = whole[base..shared.length(whole)];
        if (rest.len == 0 or (half == .system and own(rest))) {
            err = dl.MatchNext(ap);
            continue;
        }
        var text: [manifest.max_path]u8 = undefined;
        if (install.joinLength(half, rest) > text.len or !manifest.pathOk(rest)) {
            _ = shared.fail(run, "%s is not a path a package can hold, and is left out\n", .{whole});
            err = dl.MatchNext(ap);
            continue;
        }
        const path = text[0..install.join(half, rest, &text)];
        const target = Path.of(drive, rest);

        if (dos.isDirectory(ap.info.dir_entry_type)) {
            if (!drawer(run, target.text())) return dos.RETURN_FAIL;
            if (!list.add(.drawer, path, 0, 0)) return noRoom(run);
            ap.flags |= dos.APF_DODIR;
            err = dl.MatchNext(ap);
            continue;
        }

        var sum: u32 = 0;
        var length: u64 = 0;
        if (file(run, whole, target.text(), buffer, &sum, &length)) |code| return code;
        keep(run, &ap.info, target.text());
        if (!list.add(.file, path, sum, length)) return noRoom(run);
        if (count) {
            run.files += 1;
            run.bytes += length;
        }
        err = dl.MatchNext(ap);
    }
    if (err != 0 and err != dos.ERROR_NO_MORE_ENTRIES) return shared.failed(run, named, err);
    return null;
}

/// A package copied: its list says what to make and what to copy, every
/// file is held against the sum and the length in it, and the list it
/// leaves is the package's own text.
fn fromPackage(run: *Run, buffer: []u8) i32 {
    const dl = run.dl;
    var path: [max_path:0]u8 = @splat(0);
    const root = shared.copy(&path, run.from[0..shared.length(run.from)]);
    path[joined(&path, root, install.package_manifest)] = 0;
    const text = prefs.loadWhole(run.sys, dl, @ptrCast(&path)) orelse {
        return shared.fail(run, "%s cannot be read\n", .{@as([*:0]const u8, @ptrCast(&path))});
    };
    defer run.sys.FreeVec(@ptrCast(text.ptr));

    var boot_drives: [shared.max_slots]*Drive = undefined;
    for (0..run.slots) |slot| boot_drives[slot] = &run.boot[slot];

    var reader = manifest.Reader.init(text) catch |err| {
        return shared.fail(run, "%s: %s\n", .{ install.package_manifest, manifest.why(err) });
    };
    var files: u32 = 0;
    var copied: u64 = 0;
    var half: ?install.Half = null;
    while (true) {
        const next = reader.next() catch |err| {
            return shared.fail(run, "%s: %s\n", .{ install.package_manifest, manifest.why(err) });
        };
        const entry = next orelse break;
        if (shared.stopped(run)) return dos.RETURN_WARN;
        const part = install.halfOf(entry.path) orelse {
            return shared.fail(run, "a list that names %d files has one in neither half of a package\n", .{reader.header.counts.files});
        };
        // A half's own drawer stands for the volume its half is written
        // to, which is there already.
        if (part.rest.len == 0) continue;
        if (half == null or half.? != part.half) {
            half = part.half;
            shared.say(run, "  the %s\n", .{if (part.half == .system) "system's files" else "boot files"});
        }
        path[joined(&path, root, entry.path)] = 0;
        const source: [*:0]const u8 = @ptrCast(&path);
        const drives: []const *Drive = switch (part.half) {
            .system => &[_]*Drive{&run.system},
            .boot => boot_drives[0..run.slots],
        };
        for (drives) |drive| {
            const target = Path.of(drive, part.rest);
            switch (entry.kind) {
                .drawer => if (!drawer(run, target.text())) return dos.RETURN_FAIL,
                .file => {
                    var sum: u32 = 0;
                    var length: u64 = 0;
                    if (file(run, source, target.text(), buffer, &sum, &length)) |code| return code;
                    if (sum != entry.crc or length != entry.size) {
                        return shared.fail(run, "%s did not arrive whole: the list says %x of %ld bytes, what was copied is %x of %ld\n", .{
                            source, entry.crc, entry.size, sum, length,
                        });
                    }
                },
            }
        }
        if (entry.kind == .file) {
            files += 1;
            copied += entry.size;
        }
    }
    run.files = files;
    run.bytes = copied;
    return saveList(run, text);
}

/// The list onto the new system volume, where an update reads it.
fn saveList(run: *Run, text: []const u8) i32 {
    const where = Path.of(&run.system, afterColon(install.installed_manifest));
    if (!drawersOf(run, &where)) return dos.RETURN_FAIL;
    if (!prefs.save(run.dl, where.text(), text)) return shared.failed(run, where.text(), run.dl.IoErr());
    shared.say(run, "  %s\n", .{where.text()});
    return dos.RETURN_OK;
}

/// `ENVARC:Sys/install.prefs` on the new volume: what was installed
/// where, and from where, for an update to read.
fn leavePrefs(run: *Run) i32 {
    var settings: prefs.install.Settings = .{};
    _ = set(&settings.device, run.device);
    settings.unit = run.unit;
    _ = set(&settings.system, run.system.name);
    if (run.work.there()) _ = set(&settings.work, run.work.name);
    _ = set(&settings.boot, run.boot[0].name);
    if (run.slots > 1) _ = set(&settings.boot_b, run.boot[1].name);
    _ = set(&settings.board, @ptrCast(&run.board));
    _ = set(&settings.source, if (run.kind == .running) running_source else run.from);
    when(run, &settings.installed);

    var line: [prefs.install.max_line]u8 = undefined;
    var text: Buffer = .{ .sys = run.sys };
    defer text.free();
    if (!text.add(prefs.install.header) or
        !text.add(line[0..prefs.install.write(&settings, &line)]) or
        !text.add("\n")) return noRoom(run);

    const where = Path.of(&run.system, envarc_drawer ++ "Sys/install.prefs");
    if (!drawersOf(run, &where)) return dos.RETURN_FAIL;
    if (!prefs.save(run.dl, where.text(), text.text())) return shared.failed(run, where.text(), run.dl.IoErr());
    shared.say(run, "  %s\n", .{where.text()});
    return dos.RETURN_OK;
}

/// One file copied, its CRC-32 and its length worked out as it goes.
fn file(run: *Run, from: [*:0]const u8, to: [*:0]const u8, buffer: []u8, sum: *u32, length: *u64) ?i32 {
    const dl = run.dl;
    const in = dl.Open(from, dos.MODE_OLDFILE) orelse return shared.failed(run, from, dl.IoErr());
    defer _ = dl.Close(in);
    const out = dl.Open(to, dos.MODE_NEWFILE) orelse return shared.failed(run, to, dl.IoErr());
    var crc = dos.flashfs.crcStart();
    var total: u64 = 0;
    while (true) {
        const got = dl.Read(in, buffer.ptr, @intCast(buffer.len));
        if (got < 0) {
            const code = dl.IoErr();
            _ = dl.Close(out);
            return shared.failed(run, from, code);
        }
        if (got == 0) break;
        const count: usize = @intCast(got);
        if (dl.Write(out, buffer.ptr, @intCast(count)) != got) {
            const code = dl.IoErr();
            _ = dl.Close(out);
            return shared.failed(run, to, code);
        }
        crc = dos.flashfs.crcAdd(crc, buffer[0..count]);
        total += count;
    }
    if (!dl.Close(out)) return shared.failed(run, to, dl.IoErr());
    sum.* = dos.flashfs.crcEnd(crc);
    length.* = total;
    return null;
}

/// A drawer made where it is not there already.
fn drawer(run: *Run, path: [*:0]const u8) bool {
    const dl = run.dl;
    if (dl.CreateDir(path)) |lock| {
        dl.UnLock(lock);
        return true;
    }
    const code = dl.IoErr();
    if (code == dos.ERROR_OBJECT_EXISTS) return true;
    _ = shared.failed(run, path, code);
    return false;
}

/// The drawers above a path, made: a list and a settings file go into
/// drawers the copy may not have made yet.
fn drawersOf(run: *Run, path: *const Path) bool {
    var made: Path = .{};
    const text = path.bytes[0..shared.length(path.text())];
    @memcpy(made.bytes[0..text.len], text);
    var at: usize = 0;
    while (at < text.len and text[at] != ':') at += 1;
    var index = at + 1;
    while (index < text.len) : (index += 1) {
        if (text[index] != '/') continue;
        made.bytes[index] = 0;
        if (!drawer(run, made.text())) return false;
        made.bytes[index] = '/';
    }
    return true;
}

/// A copied file's protection bits, date and comment set from the one it
/// came from: a file that loses its bits is a script that will not run.
/// What cannot be set is passed over - the file itself is there.
fn keep(run: *Run, info: *const dos.FileInfoBlock, target: [*:0]const u8) void {
    const dl = run.dl;
    _ = dl.SetProtection(target, info.protection & ~dos.FIBF_ARCHIVE);
    _ = dl.SetFileDate(target, &info.date);
    if (info.comment[0] != 0) _ = dl.SetComment(target, @ptrCast(&info.comment));
}

/// Now, as the machine says it.
fn when(run: *Run, into: anytype) void {
    var day: [dos.LEN_DATSTRING:0]u8 = @splat(0);
    var clock: [dos.LEN_DATSTRING:0]u8 = @splat(0);
    var stamp: dos.DateStamp = .{};
    _ = run.dl.DateStamp(&stamp);
    var now: dos.DateTime = .{
        .stamp = stamp,
        .format = dos.FORMAT_DOS,
        .str_date = @ptrCast(&day),
        .str_time = @ptrCast(&clock),
    };
    if (!run.dl.DateToStr(&now)) return;
    var at = shared.copy(into, day[0..shared.length(@ptrCast(&day))]);
    at += shared.copy(into[at..], " ");
    at += shared.copy(into[at..], clock[0..shared.length(@ptrCast(&clock))]);
    into[at] = 0;
}

/// Whether a path on the running system is the machine's own record of
/// itself, which the install writes afresh.
fn own(rest: []const u8) bool {
    for (machines_own) |one| {
        if (manifest.samePath(rest, one)) return true;
    }
    return false;
}

/// A text into a settings field; false when it does not fit.
fn set(field: anytype, text: [*:0]const u8) bool {
    const count = shared.length(text);
    if (count > field.len) return false;
    field.* = @splat(0);
    @memcpy(field[0..count], text[0..count]);
    return true;
}

/// A path with its device name taken off: what is left is the path on
/// the volume.
fn afterColon(path: []const u8) []const u8 {
    for (path, 0..) |char, at| {
        if (char == ':') return path[at + 1 ..];
    }
    return path;
}

/// Two paths joined with a `/` between them, into `into` from `at`; how
/// many bytes there are then.
fn joined(into: []u8, at: usize, rest: []const u8) usize {
    var end = at;
    if (end != 0 and into[end - 1] != ':' and into[end - 1] != '/') end += shared.copy(into[end..], "/");
    end += shared.copy(into[end..], rest);
    return end;
}

fn noRoom(run: *Run) i32 {
    return shared.failed(run, shared.COMMAND_NAME, dos.ERROR_NO_FREE_STORE);
}
