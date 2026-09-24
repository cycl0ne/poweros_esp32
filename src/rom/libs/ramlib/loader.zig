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
//! The name is tried as it was given first, so a program can load a module
//! sitting beside it, and then under `LIBS:` or `DEVS:`.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ramlib = @import("ramlib.zig");
const RamLibBase = ramlib.RamLibBase;

/// The longest name a module may have, with its directory in front.
const max_path = 96;

/// Look for `name`, make what is in it, and keep the segments. True when
/// something was made, and the caller looks on exec's list again.
pub fn load(rlb: *RamLibBase, name: [*:0]const u8, kind: u32, version: u32) bool {
    const sys = rlb.sys_base;
    // One at a time: two tasks asking for the same name at once would both
    // find it missing and both load it.
    sys.ObtainSemaphore(&rlb.lock);
    defer sys.ReleaseSemaphore(&rlb.lock);

    // Somebody may have loaded it while this was waiting for the lock.
    if (alreadyLoaded(rlb, name)) return true;

    const seg_list = find(rlb, name, kind) orelse return false;
    const tag = scan(seg_list, name, version) orelse {
        // A file that is not a module, or not the one that was asked for.
        rlb.dos_base.UnLoadSeg(seg_list);
        return false;
    };
    if (sys.InitResident(tag, @ptrCast(seg_list)) == null) {
        rlb.dos_base.UnLoadSeg(seg_list);
        return false;
    }
    keep(rlb, name, seg_list);
    return true;
}

/// The file, by the name it was asked for and then where its kind lives.
fn find(rlb: *RamLibBase, name: [*:0]const u8, kind: u32) ?*dos.SegList {
    const dl = rlb.dos_base;
    if (dl.LoadSeg(name)) |seg_list| return seg_list;

    var path: [max_path]u8 = undefined;
    const where: []const u8 = if (kind == ramlib.KIND_DEVICE) "DEVS:" else "LIBS:";
    const full = join(&path, where, name) orelse return null;
    return dl.LoadSeg(full);
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
    var node = rlb.loaded.first();
    while (node) |n| : (node = n.next()) {
        const module: *ramlib.Loaded = @fieldParentPtr("node", n);
        if (sameName(@ptrCast(&module.name_buf), name)) return true;
    }
    return false;
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

test "the scan walks every segment of the file" {
    var first: [64]u8 align(@alignOf(exec.Resident)) = @splat(0);
    var second: [128]u8 align(@alignOf(exec.Resident)) = @splat(0);
    const tag: *exec.Resident = @ptrCast(@alignCast(&second[4 * @alignOf(exec.Resident)]));
    tag.* = .{ .match_tag = tag, .version = 1, .type = .device, .name = "test.device" };

    var tail = dos.SegList{ .mem_size = second.len, .data = &second };
    var head = dos.SegList{ .mem_size = first.len, .data = &first, .next = &tail };
    try testing.expectEqual(@as(?*const exec.Resident, tag), scan(&head, "test.device", 0));
}

test "a path is where its kind lives and the name" {
    var buffer: [max_path]u8 = undefined;
    const path = join(&buffer, "LIBS:", "hello.library").?;
    try testing.expectEqualStrings("LIBS:hello.library", std.mem.span(path));

    // A name that does not fit is refused rather than cut: half a name
    // would find the wrong file or none.
    var small: [8]u8 = undefined;
    try testing.expect(join(&small, "LIBS:", "hello.library") == null);
}
