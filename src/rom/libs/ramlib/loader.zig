// SPDX-License-Identifier: MPL-2.0
//! Finding a module on the disk and making it.
//!
//! The file is a load file, the same kind a command is: `LoadSeg` reads it,
//! puts each segment where it likes and applies the relocations. A code
//! segment is relocated against its address on the instruction bus and
//! everything else against its own, so what comes out has function
//! pointers that can be called and data that can be read - which is all a
//! ROM tag is.
//!
//! So the rest is what the ROM does at boot with the tags in its own
//! image: find the tag, check what it is, hand it to `InitResident`. The
//! difference is only where the bytes came from.
//!
//! A name may carry a path: `gadgets/checkbox.gadget`,
//! `SYS:classes/gadgets/checkbox.gadget`. What the module is called is the
//! part after the last `/` or `:` - its **tail** - and that is what it is
//! looked for by on exec's lists and among the ROM tags, and what the tag
//! in the file must be named. The file is looked for by the whole name:
//! under `LIBS:` or `DEVS:` when it has no `:`, as it stands when it has
//! one, and last, from a process, as given, from its current directory.
//! `LIBS:` may be a multi-assign - `SYS:libs` and `SYS:classes` - and dos
//! walks its directories until the file is found.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ramlib = @import("ramlib.zig");
const RamLibBase = ramlib.RamLibBase;
const ExecBase = sdk.interface.exec.ExecBase;

/// The longest name a module may have, with its directory in front.
const max_path = 96;

/// A module being loaded: its tail name, the lock its loader holds from
/// the start of the load to its end, and how many tasks still look at
/// this record - the loader and those waiting for it.
const Loading = struct {
    node: exec.Node = .{},
    name_buf: [64]u8 = @splat(0),
    lock: exec.SignalSemaphore = .{},
    users: u32 = 0,
};

/// Look for `name`, make what is in it, and keep the segments. True when
/// something was made, and the caller looks on exec's list again, by the
/// name's tail. `own_process` is true when this runs in the asking
/// process, whose current directory the name as given is tried from.
///
/// **Loads go side by side.** A load reads a file and runs the module's
/// init, which may take seconds and open further modules; a task asking
/// for another module goes on meanwhile. Only the same name waits - two
/// tasks asking for one module at once would otherwise both load it -
/// and the second then answers what the first made of it. Two modules
/// whose inits each open the other, loaded by two tasks at once, would
/// wait for each other for ever; no module does that.
pub fn load(rlb: *RamLibBase, name: [*:0]const u8, kind: u32, version: u32, own_process: bool) bool {
    const sys = rlb.sys_base;
    const tail = tailName(name);
    sys.ObtainSemaphore(&rlb.lock);
    if (isThere(rlb, tail, kind)) {
        sys.ReleaseSemaphore(&rlb.lock);
        return true;
    }
    if (loadingOf(rlb, tail)) |other| {
        other.users += 1;
        sys.ReleaseSemaphore(&rlb.lock);
        // Held by its loader until it is done. When this task is the
        // loader - the module's own init asking for it - it holds it
        // already, and goes straight on to say it is not there yet.
        sys.ObtainSemaphore(&other.lock);
        sys.ReleaseSemaphore(&other.lock);
        sys.ObtainSemaphore(&rlb.lock);
        defer sys.ReleaseSemaphore(&rlb.lock);
        drop(rlb, other);
        return isThere(rlb, tail, kind);
    }
    // Loaded once and expunged since: its segments are free to go.
    if (kind == ramlib.KIND_LIBRARY) forget(rlb, tail);
    const mine = begin(rlb, tail) orelse {
        sys.ReleaseSemaphore(&rlb.lock);
        return false;
    };
    sys.ReleaseSemaphore(&rlb.lock);

    const made = make(rlb, name, tail, kind, version, own_process);

    sys.ReleaseSemaphore(&mine.lock);
    sys.ObtainSemaphore(&rlb.lock);
    drop(rlb, mine);
    sys.ReleaseSemaphore(&rlb.lock);
    return made;
}

/// Whether the module is there: a library on exec's list, a device that
/// was loaded. Under the lists' lock.
fn isThere(rlb: *RamLibBase, tail: [*:0]const u8, kind: u32) bool {
    if (kind == ramlib.KIND_LIBRARY) return libraryListed(rlb, tail);
    return alreadyLoaded(rlb, tail);
}

/// The record of a module of that name being loaded now, if one is.
fn loadingOf(rlb: *RamLibBase, tail: [*:0]const u8) ?*Loading {
    var node = rlb.loading.first();
    while (node) |n| : (node = n.next()) {
        const record: *Loading = @fieldParentPtr("node", n);
        if (sameName(@ptrCast(&record.name_buf), tail)) return record;
    }
    return null;
}

/// A record made for a load this task begins, its lock held: null
/// without memory. Under the lists' lock.
fn begin(rlb: *RamLibBase, tail: [*:0]const u8) ?*Loading {
    const sys = rlb.sys_base;
    const memory = sys.AllocVec(@sizeOf(Loading), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const record: *Loading = @ptrCast(@alignCast(memory));
    record.* = .{ .users = 1 };
    var i: usize = 0;
    while (tail[i] != 0 and i + 1 < record.name_buf.len) : (i += 1) record.name_buf[i] = tail[i];
    record.name_buf[i] = 0;
    sys.InitSemaphore(&record.lock);
    sys.ObtainSemaphore(&record.lock);
    sys.AddTail(&rlb.loading, &record.node);
    return record;
}

/// One task done with the record; the last frees it. Under the lists'
/// lock.
fn drop(rlb: *RamLibBase, record: *Loading) void {
    record.users -= 1;
    if (record.users != 0) return;
    rlb.sys_base.Remove(&record.node);
    rlb.sys_base.FreeVec(record);
}

/// The module made: from a ROM tag no boot phase started, or from its
/// file, whose segments are kept. With the name's own lock held, and not
/// the lists'.
fn make(rlb: *RamLibBase, name: [*:0]const u8, tail: [*:0]const u8, kind: u32, version: u32, own_process: bool) bool {
    const sys = rlb.sys_base;
    // A ROM tag of that name that no boot phase started: made from the
    // ROM, with no file behind it.
    if (sys.FindResident(tail)) |tag| {
        if (tag.version >= version and wantedKind(tag, kind)) return sys.InitResident(tag, null) != null;
    }

    const seg_list = find(rlb, name, kind, own_process) orelse return false;
    const tag = scan(seg_list, tail, version) orelse {
        // A file that is not a module, or not the one that was asked for.
        rlb.dos_base.UnLoadSeg(seg_list);
        return false;
    };
    if (sys.InitResident(tag, @ptrCast(seg_list)) == null) {
        rlb.dos_base.UnLoadSeg(seg_list);
        return false;
    }
    sys.ObtainSemaphore(&rlb.lock);
    defer sys.ReleaseSemaphore(&rlb.lock);
    keep(rlb, tail, seg_list);
    return true;
}

/// A ROM tag answers only the call that asks for its kind.
fn wantedKind(tag: *const exec.Resident, kind: u32) bool {
    return if (kind == ramlib.KIND_DEVICE) tag.type == .device else tag.type == .library;
}

/// What a module is called: the part of `name` after its last `/` or `:`.
pub fn tailName(name: [*:0]const u8) [*:0]const u8 {
    var tail = name;
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) {
        if (name[i] == '/' or name[i] == ':') tail = name + i + 1;
    }
    return tail;
}

/// The file: where its kind lives, then the name as given from the
/// asking process's current directory. A name with a `:` says where it
/// is, and is tried there alone.
fn find(rlb: *RamLibBase, name: [*:0]const u8, kind: u32, own_process: bool) ?*dos.SegList {
    const dl = rlb.dos_base;
    var path: [max_path]u8 = undefined;
    const load_name = loadName(&path, name, kind) orelse return null;
    if (dl.LoadSeg(load_name)) |seg_list| return seg_list;
    // ramlib's own process has no current directory of the asker's.
    if (load_name == name or !own_process) return null;
    return dl.LoadSeg(name);
}

/// The name the file is loaded by: `name` itself when it has a `:`,
/// otherwise `LIBS:` or `DEVS:` and the whole of it, in `into`.
fn loadName(into: []u8, name: [*:0]const u8, kind: u32) ?[*:0]const u8 {
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) {
        if (name[i] == ':') return name;
    }
    const where: []const u8 = if (kind == ramlib.KIND_DEVICE) "DEVS:" else "LIBS:";
    return join(into, where, name);
}

/// "LIBS:" and a name into one buffer, NUL-terminated. Null if it does not
/// fit, which a name that long deserves.
fn join(into: []u8, where: []const u8, name: [*:0]const u8) ?[*:0]const u8 {
    var at: usize = 0;
    while (at < where.len) : (at += 1) into[at] = where[at];
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) {
        if (at + 1 >= into.len) return null;
        into[at] = name[i];
        at += 1;
    }
    into[at] = 0;
    return @ptrCast(into.ptr);
}

/// The ROM tag in what was loaded: the same match word and self-pointer the
/// boot scan looks for, over every segment of the file. A tag is data, so
/// it is read where the data is; the vectors it points at were relocated
/// against the instruction bus and are ready to call.
fn scan(seg_list: *dos.SegList, name: [*:0]const u8, version: u32) ?*const exec.Resident {
    var seg: ?*dos.SegList = seg_list;
    while (seg) |s| : (seg = s.next) {
        const bytes = s.data orelse continue;
        var at: usize = 0;
        // A tag is laid out by a compiler, so it sits on its own type's
        // alignment; the scan steps by that rather than by a byte, which
        // is both faster and the only way the pointer below is allowed to
        // be made at all.
        const step = @alignOf(exec.Resident);
        while (at + @sizeOf(exec.Resident) <= s.mem_size) : (at += step) {
            const tag: *const exec.Resident = @ptrCast(@alignCast(bytes + at));
            if (tag.match_word != exec.RTC_MATCHWORD) continue;
            if (tag.match_tag != tag) continue;
            if (tag.version < version) continue;
            if (!sameName(tag.name, name)) continue;
            return tag;
        }
    }
    return null;
}

/// A file may hold a module of another name - it is only a file - and
/// making that one would answer a question nobody asked. The tag's name is
/// what the caller gets, so it has to be the name it asked for.
fn sameName(tag_name: [*:0]const u8, wanted: [*:0]const u8) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        const a = lower(tag_name[i]);
        const b = lower(wanted[i]);
        if (a != b) return false;
        if (a == 0) return true;
    }
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn alreadyLoaded(rlb: *RamLibBase, name: [*:0]const u8) bool {
    return noteOf(rlb, name) != null;
}

fn noteOf(rlb: *RamLibBase, name: [*:0]const u8) ?*ramlib.Loaded {
    var node = rlb.loaded.first();
    while (node) |n| : (node = n.next()) {
        const module: *ramlib.Loaded = @fieldParentPtr("node", n);
        if (sameName(@ptrCast(&module.name_buf), name)) return module;
    }
    return null;
}

/// Whether exec has a library of that name: exec's own open, and a close
/// straight after. A library leaves the list when it expunges, which a
/// note of ramlib's cannot see.
fn libraryListed(rlb: *RamLibBase, name: [*:0]const u8) bool {
    const sys = rlb.sys_base;
    const open: *const fn (*ExecBase, [*:0]const u8, u32) callconv(.c) ?*exec.Library =
        @ptrCast(@alignCast(rlb.old_open_library.?));
    const lib = open(sys, name, 0) orelse return false;
    sys.CloseLibrary(lib);
    return true;
}

/// A library that was loaded and has expunged itself since: its base is
/// gone and its code is used by nothing, so the segments go with the note.
fn forget(rlb: *RamLibBase, name: [*:0]const u8) void {
    const module = noteOf(rlb, name) orelse return;
    const sys = rlb.sys_base;
    sys.Remove(&module.node);
    if (module.seg_list) |seg_list| rlb.dos_base.UnLoadSeg(seg_list);
    sys.FreeVec(module);
}

/// Note what was loaded, so that a flush has something to walk and a
/// second ask does not load it twice. Without the memory for the note the
/// module still works; it just cannot be found again.
fn keep(rlb: *RamLibBase, name: [*:0]const u8, seg_list: *dos.SegList) void {
    const sys = rlb.sys_base;
    const memory = sys.AllocVec(@sizeOf(ramlib.Loaded), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
    const module: *ramlib.Loaded = @ptrCast(@alignCast(memory));
    module.* = .{ .seg_list = seg_list };
    var i: usize = 0;
    while (name[i] != 0 and i + 1 < module.name_buf.len) : (i += 1) module.name_buf[i] = name[i];
    module.name_buf[i] = 0;
    module.node.name = @ptrCast(&module.name_buf);
    sys.AddTail(&rlb.loaded, &module.node);
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// What can be checked without a machine: the scan that finds a module in
// what was loaded, and the path it looks under. Everything else here is
// LoadSeg and InitResident, which have to be asked of a real disk.

const std = @import("std");
const testing = std.testing;

test "the scan finds a module, and refuses one that was not asked for" {
    var buffer: [256]u8 align(@alignOf(exec.Resident)) = @splat(0);
    // Somewhere in the middle, as a linker would put it.
    const tag: *exec.Resident = @ptrCast(@alignCast(&buffer[8 * @alignOf(exec.Resident)]));
    tag.* = .{
        .match_tag = tag,
        .version = 2,
        .type = .library,
        .name = "hello.library",
    };
    var seg = dos.SegList{ .mem_size = buffer.len, .data = &buffer };

    try testing.expectEqual(@as(?*const exec.Resident, tag), scan(&seg, "hello.library", 0));
    // The name is a name, whatever case it is asked in.
    try testing.expectEqual(@as(?*const exec.Resident, tag), scan(&seg, "HELLO.library", 2));
    // Older than what was asked for is not what was asked for.
    try testing.expect(scan(&seg, "hello.library", 3) == null);
    // A file may hold another module; that is not this one.
    try testing.expect(scan(&seg, "other.library", 0) == null);

    // A tag that does not point at itself is a coincidence in the bytes.
    tag.match_tag = @ptrCast(@alignCast(&buffer[0]));
    try testing.expect(scan(&seg, "hello.library", 0) == null);
    tag.match_tag = tag;
    tag.match_word = 0;
    try testing.expect(scan(&seg, "hello.library", 0) == null);
}

test "a module is called by the tail of its name" {
    try testing.expectEqualStrings("x.gadget", std.mem.span(tailName("gadgets/x.gadget")));
    try testing.expectEqualStrings("x.gadget", std.mem.span(tailName("SYS:classes/gadgets/x.gadget")));
    try testing.expectEqualStrings("x.gadget", std.mem.span(tailName("RAM:x.gadget")));
    try testing.expectEqualStrings("hello.library", std.mem.span(tailName("hello.library")));
    try testing.expectEqualStrings("", std.mem.span(tailName("LIBS:")));
}

test "the scan walks every segment of the file" {
    var first: [64]u8 align(@alignOf(exec.Resident)) = @splat(0);
    var second: [128]u8 align(@alignOf(exec.Resident)) = @splat(0);
    const tag: *exec.Resident = @ptrCast(@alignCast(&second[4 * @alignOf(exec.Resident)]));
    tag.* = .{ .match_tag = tag, .version = 1, .type = .device, .name = "test.device" };

    var tail = dos.SegList{ .mem_size = second.len, .data = &second };
    var head = dos.SegList{ .mem_size = first.len, .data = &first, .next = &tail };
    try testing.expectEqual(@as(?*const exec.Resident, tag), scan(&head, "test.device", 0));
}

test "a name being loaded is not waited for by its own loader, and its record goes with the last" {
    const kexec = @import("../exec/exec.zig");
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    // Only what the bookkeeping needs: exec's own OpenLibrary to look on
    // its list, and the lists. No dos: nothing here reaches a file.
    var rlb: RamLibBase = .{ .lib = .{}, .sys_base = sys, .dos_base = undefined };
    sys.NewList(&rlb.loaded);
    sys.NewList(&rlb.loading);
    sys.InitSemaphore(&rlb.lock);
    const exec_lib: *exec.Library = @ptrCast(@alignCast(sys));
    rlb.old_open_library = exec_lib.vector(*const anyopaque, sdk.interface.exec.LVO.OpenLibrary);

    // This task begins loading a module...
    sys.ObtainSemaphore(&rlb.lock);
    const mine = begin(&rlb, "busy.library") orelse return error.NoMemory;
    sys.ReleaseSemaphore(&rlb.lock);
    try testing.expect(loadingOf(&rlb, "BUSY.library") == mine);
    // ...whose init asks for it again: no wait on itself, and it is not
    // there yet.
    try testing.expect(!load(&rlb, "busy.library", ramlib.KIND_LIBRARY, 0, true));
    try testing.expectEqual(@as(u32, 1), mine.users);

    // The load done, the record goes, and the lists' lock is free.
    sys.ReleaseSemaphore(&mine.lock);
    sys.ObtainSemaphore(&rlb.lock);
    drop(&rlb, mine);
    sys.ReleaseSemaphore(&rlb.lock);
    try testing.expect(rlb.loading.isEmpty());
    try testing.expectEqual(@as(i16, 0), rlb.lock.nest_count);
    try kexec.expectNoLeaks();
}

test "a path is where its kind lives and the name" {
    var buffer: [max_path]u8 = undefined;
    const path = join(&buffer, "LIBS:", "hello.library").?;
    try testing.expectEqualStrings("LIBS:hello.library", std.mem.span(path));

    // A directory in the name stays in the path; a device goes where
    // devices are; a name with a colon is loaded as it stands.
    try testing.expectEqualStrings("LIBS:gadgets/x.gadget", std.mem.span(loadName(&buffer, "gadgets/x.gadget", ramlib.KIND_LIBRARY).?));
    try testing.expectEqualStrings("DEVS:sdcard.device", std.mem.span(loadName(&buffer, "sdcard.device", ramlib.KIND_DEVICE).?));
    const given: [*:0]const u8 = "SYS:classes/gadgets/x.gadget";
    try testing.expectEqual(given, loadName(&buffer, given, ramlib.KIND_LIBRARY).?);

    // A name that does not fit is refused rather than cut: half a name
    // would find the wrong file or none.
    var small: [8]u8 = undefined;
    try testing.expect(join(&small, "LIBS:", "hello.library") == null);
}
