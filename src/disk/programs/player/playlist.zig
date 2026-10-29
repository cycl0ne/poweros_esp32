// SPDX-License-Identifier: MIT
//! The playlist: the songs as the rows of a listbrowser.gadget - each
//! one's place, title, artist and length - every row made in one
//! allocation with its song's file name after it (`Entry`).
//!
//! **Shown at once, read later.** A song added stands in the list at
//! once, its file's name for its title; what its tags say is read
//! afterwards, a song at a time (`readNext`), so a long list is there at
//! once and fills in as the window has time. The song the sound opens is
//! filled in from what the sound read (`filled`), and not read again.
//!
//! **A drawer** adds the sound files in it in the order of their names,
//! then those of its drawers, each drawer in turn, `deepest` drawers down
//! at most. A file is sound by its ending (`endings`), the ones the file
//! requester's pattern shows (`pattern`); a file named on its own is
//! added whatever it ends in, and says what it is when it is read.
//!
//! **The places** in the first column follow the list as it stands: once
//! rows are moved or sorted, `renumber` writes them again - those that
//! changed.
//!
//! While the list changes - songs added, songs taken out - the gadget
//! showing it has let go of it (`LISTBROWSER_DETACH`): that is the
//! program's part.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ac = sdk.audiocodec;
const lb = sdk.gadgets.listbrowser;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const TagItem = sdk.utility.TagItem;

/// The endings of the files that are sound, and the file requester's
/// pattern for the same.
pub const endings = [_][]const u8{ "mp3", "wav", "flac", "ogg", "oga" };
pub const pattern = "#?.(mp3|wav|flac|ogg|oga)";

/// How many drawers down a drawer added is looked into.
const deepest = 8;

/// The columns: the place, which a press on its heading does not sort
/// by, the title, the artist, and the length, which sorts by how long.
pub const columns = [_]lb.Column{
    .{ .title = "#", .weight = 1, .flags = lb.COLUMN_RIGHT | lb.COLUMN_NUMBER | lb.COLUMN_NOSORT },
    .{ .title = "Title", .weight = 7 },
    .{ .title = "Artist", .weight = 5 },
    .{ .title = "Time", .weight = 2, .flags = lb.COLUMN_RIGHT | lb.COLUMN_NUMBER },
    .{},
};
const column_count = columns.len - 1;

/// The most of a title and an artist kept: what the tags' first look at
/// a song hands out.
const name_room = 64;

/// One song: its row, the texts of its columns, and its file's name,
/// which follows it in the same allocation.
pub const Entry = extern struct {
    row: lb.Row,
    cells: [column_count]?[*:0]const u8,
    /// Its place in the list from 1, as the first column says it.
    place: u32 = 0,
    /// Its tags have been read.
    read: u8 = 0,
    number: [12]u8 = @splat(0),
    title: [name_room + 1]u8 = @splat(0),
    artist: [name_room + 1]u8 = @splat(0),
    time: [12]u8 = @splat(0),

    /// The song's file name.
    pub fn path(entry: *const Entry) [*:0]const u8 {
        return @ptrCast(@as([*]const u8, @ptrCast(entry)) + @sizeOf(Entry));
    }

    /// The entry a row of the list is.
    pub fn of(row: *lb.Row) *Entry {
        return @fieldParentPtr("row", row);
    }

    fn ofNode(node: *exec.Node) *Entry {
        const row: *lb.Row = @fieldParentPtr("node", node);
        return of(row);
    }

    /// The song after it in the list; null for the last.
    pub fn next(entry: *Entry) ?*Entry {
        return ofNode(entry.row.node.next() orelse return null);
    }

    /// `title` written into its row: a station's name, once it has said
    /// it.
    pub fn retitle(entry: *Entry, title: [*:0]const u8) void {
        copyText(&entry.title, title);
    }

    /// Its place, written into its first column.
    fn setPlace(entry: *Entry, sys: *ExecBase, place: u32) void {
        entry.place = place;
        const stream = exec.fmtStream(.{place});
        comptime exec.checkFormat("%u", @TypeOf(.{@as(u32, 0)}));
        _ = sys.RawDoFmt("%u", &stream, null, &entry.number);
    }
};

pub const Playlist = struct {
    rows: exec.List = .{},
    count: usize = 0,
    /// Songs whose tags are still to be read.
    unread: usize = 0,

    /// Made empty where it is to stay: the list points at itself.
    pub fn init(list: *Playlist) void {
        list.* = .{};
        list.rows.init(.unknown);
    }

    pub fn first(list: *Playlist) ?*Entry {
        return Entry.ofNode(list.rows.first() orelse return null);
    }

    /// The song at `place`, counted from 0; null past the end.
    pub fn at(list: *Playlist, place: usize) ?*Entry {
        var entry = list.first();
        var left = place;
        while (entry) |each| : (entry = each.next()) {
            if (left == 0) return each;
            left -= 1;
        }
        return null;
    }

    /// Where `entry` stands, counted from 0.
    pub fn placeOf(list: *Playlist, entry: *const Entry) usize {
        var place: usize = 0;
        var at_entry = list.first();
        while (at_entry) |each| : (at_entry = each.next()) {
            if (each == entry) return place;
            place += 1;
        }
        return place;
    }

    /// A song added at the end: its row, with the file's name for its
    /// title until its tags are read. Null without the memory.
    pub fn add(list: *Playlist, sys: *ExecBase, name: [*:0]const u8) ?*Entry {
        const entry = make(sys, name) orelse return null;
        list.append(sys, entry);
        return entry;
    }

    fn addFile(list: *Playlist, sys: *ExecBase, name: [*:0]const u8) usize {
        return if (list.add(sys, name) != null) 1 else 0;
    }

    fn append(list: *Playlist, sys: *ExecBase, entry: *Entry) void {
        sys.AddTail(&list.rows, &entry.row.node);
        list.count += 1;
        list.unread += 1;
        entry.setPlace(sys, @intCast(list.count));
    }

    /// What `name` names added: a file - one that is not there too,
    /// which says so when it is read - a station's address, or a drawer's
    /// sound files by name and then its drawers' in turn. How many songs
    /// that was.
    pub fn addPath(list: *Playlist, sys: *ExecBase, dl: *DosBase, name: [*:0]const u8) usize {
        if (isUrl(name)) return list.addFile(sys, name);
        const lock = dl.Lock(name, dos.ACCESS_READ) orelse return list.addFile(sys, name);
        defer dl.UnLock(lock);
        const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return list.addFile(sys, name)));
        defer sys.FreeVec(@ptrCast(fib));
        if (!dl.Examine(lock, fib) or fib.dir_entry_type <= 0) return list.addFile(sys, name);
        var path: [dos.path_max + 1:0]u8 = @splat(0);
        var length: usize = 0;
        while (name[length] != 0 and length < dos.path_max) : (length += 1) path[length] = name[length];
        return list.addDrawer(sys, dl, &path, lock, fib, 0);
    }

    /// The drawer `path` names, locked as `lock` and examined into `fib`:
    /// its sound files by name, then each of its drawers the same way,
    /// `depth` drawers down. `path` grows as the walk goes down and is as
    /// it was at the end; `fib` is taken for the drawers below.
    fn addDrawer(list: *Playlist, sys: *ExecBase, dl: *DosBase, path: *[dos.path_max + 1:0]u8, lock: *dos.FileLock, fib: *dos.FileInfoBlock, depth: u32) usize {
        var files: exec.List = .{};
        files.init(.unknown);
        var drawers: exec.List = .{};
        drawers.init(.unknown);
        defer freeNames(sys, &drawers);
        const length = lengthOf(path);
        while (dl.ExNext(lock, fib)) {
            const name: [*:0]const u8 = @ptrCast(&fib.file_name);
            if (fib.dir_entry_type > 0) {
                if (depth + 1 < deepest) if (makeName(sys, name)) |node| insertByName(sys, &drawers, node);
                continue;
            }
            if (!isSound(name)) continue;
            defer path[length] = 0;
            if (!dl.AddPart(path, name, path.len)) continue;
            const entry = make(sys, path) orelse continue;
            insertByName(sys, &files, &entry.row.node);
        }
        var added: usize = 0;
        while (sys.RemHead(&files)) |node| {
            list.append(sys, Entry.ofNode(node));
            added += 1;
        }
        var drawer = drawers.first();
        while (drawer) |node| : (drawer = node.next()) {
            defer path[length] = 0;
            if (!dl.AddPart(path, node.name.?, path.len)) continue;
            const inner = dl.Lock(path, dos.ACCESS_READ) orelse continue;
            defer dl.UnLock(inner);
            if (!dl.Examine(inner, fib)) continue;
            added += list.addDrawer(sys, dl, path, inner, fib, depth + 1);
        }
        return added;
    }

    /// `entry` taken off the list and given back.
    pub fn remove(list: *Playlist, sys: *ExecBase, entry: *Entry) void {
        sys.Remove(&entry.row.node);
        list.count -= 1;
        if (entry.read == 0) list.unread -= 1;
        sys.FreeVec(@ptrCast(entry));
    }

    /// Every song taken off and given back.
    pub fn clear(list: *Playlist, sys: *ExecBase) void {
        while (list.first()) |entry| list.remove(sys, entry);
    }

    /// Each song's place written into its first column where it changed:
    /// whether any did.
    pub fn renumber(list: *Playlist, sys: *ExecBase) bool {
        var place: u32 = 1;
        var changed = false;
        var entry = list.first();
        while (entry) |each| : (entry = each.next()) {
            if (each.place != place) {
                each.setPlace(sys, place);
                changed = true;
            }
            place += 1;
        }
        return changed;
    }

    /// The tags of the first song not read yet read into its row, and
    /// the song answered; null when every one has been. A file that will
    /// not open keeps its name and says nothing more, and so does a
    /// station, which is not asked.
    pub fn readNext(list: *Playlist, sys: *ExecBase, acb: *AudioCodecBase) ?*Entry {
        if (list.unread == 0) return null;
        var entry = list.first();
        while (entry) |each| : (entry = each.next()) {
            if (each.read != 0) continue;
            var info: ac.AudioStreamInfo = .{};
            var err: i32 = 0;
            // A station says what it is when it is listened to.
            const stream = if (isUrl(each.path())) null else acb.OpenAudioStream(&[_]TagItem{ .{ .tag = ac.ACA_Name, .data = @intFromPtr(each.path()) }, .{} }, &err);
            if (stream) |opened| {
                acb.GetAudioStreamInfo(opened, &info);
                acb.CloseAudioStream(opened);
            }
            list.filled(sys, each, &info);
            return each;
        }
        list.unread = 0;
        return null;
    }

    /// What `info` says of `entry`'s song written into its row - the
    /// title, where it has one, the artist and the length - and the song
    /// counted as read.
    pub fn filled(list: *Playlist, sys: *ExecBase, entry: *Entry, info: *const ac.AudioStreamInfo) void {
        if (info.title[0] != 0) copyText(&entry.title, &info.title);
        copyText(&entry.artist, &info.artist);
        writeTime(sys, &entry.time, info.frames, info.rate);
        if (entry.read != 0) return;
        entry.read = 1;
        list.unread -= 1;
    }
};

/// A song's entry, on no list yet; null without the memory.
fn make(sys: *ExecBase, name: [*:0]const u8) ?*Entry {
    const length = lengthOf(name);
    const memory: [*]u8 = @ptrCast(sys.AllocVec(@intCast(@sizeOf(Entry) + length + 1), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null);
    const entry: *Entry = @ptrCast(@alignCast(memory));
    entry.* = .{ .row = .{ .cells = &entry.cells }, .cells = .{ @ptrCast(&entry.number), @ptrCast(&entry.title), @ptrCast(&entry.artist), @ptrCast(&entry.time) } };
    const kept = memory + @sizeOf(Entry);
    for (0..length) |i| kept[i] = name[i];
    kept[length] = 0;
    copyText(&entry.title, fileName(name));
    entry.row.node.name = @ptrCast(&entry.title);
    return entry;
}

/// A node holding a copy of `name`, on no list; null without the memory.
fn makeName(sys: *ExecBase, name: [*:0]const u8) ?*exec.Node {
    const length = lengthOf(name);
    const memory: [*]u8 = @ptrCast(sys.AllocVec(@intCast(@sizeOf(exec.Node) + length + 1), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null);
    const kept = memory + @sizeOf(exec.Node);
    for (0..length) |i| kept[i] = name[i];
    kept[length] = 0;
    const node: *exec.Node = @ptrCast(@alignCast(memory));
    node.* = .{ .name = @ptrCast(kept) };
    return node;
}

fn freeNames(sys: *ExecBase, list: *exec.List) void {
    while (sys.RemHead(list)) |node| sys.FreeVec(@ptrCast(node));
}

/// `node` put into `list` before the first whose name comes after its
/// own, in any case.
fn insertByName(sys: *ExecBase, list: *exec.List, node: *exec.Node) void {
    var at_node = list.first();
    while (at_node) |each| : (at_node = each.next()) {
        if (compareNames(node.name.?, each.name.?) >= 0) continue;
        // Behind the node in front of it, or at the head when that is the
        // list's own.
        const in_front = each.pred.?;
        sys.Insert(list, node, if (in_front.pred == null) null else in_front);
        return;
    }
    sys.AddTail(list, node);
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

/// Two names in any case: below 0, 0 or above.
pub fn compareNames(a: [*:0]const u8, b: [*:0]const u8) i32 {
    var i: usize = 0;
    while (true) : (i += 1) {
        const x = lower(a[i]);
        const y = lower(b[i]);
        if (x != y) return @as(i32, x) - @as(i32, y);
        if (x == 0) return 0;
    }
}

/// Whether `name` ends in one of the endings of sound.
pub fn isSound(name: [*:0]const u8) bool {
    const length = lengthOf(name);
    var dot = length;
    while (dot > 0) {
        dot -= 1;
        if (name[dot] == '.') break;
        if (name[dot] == '/' or name[dot] == ':') return false;
    } else return false;
    const ending = name[dot + 1 .. length];
    for (endings) |known| {
        if (known.len != ending.len) continue;
        for (known, ending) |want, have| {
            if (lower(have) != want) break;
        } else return true;
    }
    return false;
}

/// Whether `name` is a station's address - `http://` or `https://`, in
/// any case - rather than a file's: never locked, nor looked beside.
pub fn isUrl(name: [*:0]const u8) bool {
    return startsWith(name, "http://") or startsWith(name, "https://");
}

fn startsWith(name: [*:0]const u8, prefix: []const u8) bool {
    for (prefix, 0..) |want, at| {
        if (name[at] == 0 or lower(name[at]) != want) return false;
    }
    return true;
}

/// The last part of a file's name: after its drawers and its volume.
/// A name that ends in a drawer or a volume - nothing after its last `/`
/// or `:` - is the whole of it.
pub fn fileName(name: [*:0]const u8) [*:0]const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) {
        if (name[i] == '/' or name[i] == ':') start = i + 1;
    }
    return if (name[start] != 0) name + start else name;
}

/// A song's length, `frames` at `rate` a second, as minutes and seconds,
/// hours before them from an hour on; empty when it is not known.
fn writeTime(sys: *ExecBase, into: *[12]u8, frames: u32, rate: u32) void {
    into[0] = 0;
    if (frames == 0 or rate == 0) return;
    const seconds = frames / rate;
    if (seconds >= 3600) {
        const stream = exec.fmtStream(.{ seconds / 3600, seconds / 60 % 60, seconds % 60 });
        comptime exec.checkFormat("%u:%02u:%02u", @TypeOf(.{ @as(u32, 0), @as(u32, 0), @as(u32, 0) }));
        _ = sys.RawDoFmt("%u:%02u:%02u", &stream, null, into);
    } else {
        const stream = exec.fmtStream(.{ seconds / 60, seconds % 60 });
        comptime exec.checkFormat("%u:%02u", @TypeOf(.{ @as(u32, 0), @as(u32, 0) }));
        _ = sys.RawDoFmt("%u:%02u", &stream, null, into);
    }
}

/// `from`, up to its end or `into`'s room less one, into `into`, ended.
fn copyText(into: []u8, from: [*]const u8) void {
    var i: usize = 0;
    while (i + 1 < into.len and from[i] != 0) : (i += 1) into[i] = from[i];
    into[i] = 0;
}

fn lengthOf(text: [*:0]const u8) usize {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return n;
}
