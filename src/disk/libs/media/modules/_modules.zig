// SPDX-License-Identifier: MIT
//! The container modules there are: `LIBS:codecs/*.container`, each found
//! by the tag in its own file (`mcontainer.ResidentMContainer`), which
//! says which kinds of container it reads. The library holds no list of
//! the kinds there are: what this disk reads is what the modules on it
//! say, so a kind whose module was left off a board's disk is not there,
//! and one dropped in is found.
//!
//! The reading is `dos.modtable`'s, shared with audiocodec.library and the
//! same work videocodec.library does for pictures: a tag is read out of
//! the file and nothing is loaded, and a file whose name, date and size
//! have not changed keeps what its tag said. The table lives in the base,
//! shared by every opener, under `modules_lock`; `scratch` is where the
//! next one is built, so the one in use is never half written.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const media = sdk.media;
const mcontainer = sdk.mcontainer;
const modtable = dos.modtable;
const MediaBase = @import("../media_base.zig").MediaBase;

/// The most modules kept.
pub const max_modules = 8;

/// What is looked for, and how its words are read: the kinds a bit each,
/// then the priority. A container has no chip kind: it is read, never
/// decoded.
pub const looking: modtable.Kind = .{
    .dir = mcontainer.MCONTAINER_DIR,
    .prefix = mcontainer.MCONTAINER_PREFIX,
    .suffix = ".container",
    .magic = mcontainer.MCONTAINER_MAGIC,
    .words = 2,
};

/// The modules there are, in the base's `modules`.
pub const Table = struct {
    count: u32 = 0,
    list: [max_modules]modtable.Found = @splat(.{}),

    pub fn rows(table: *const Table) []const modtable.Found {
        return table.list[0..@min(table.count, max_modules)];
    }
};

/// The host tests' modules: the table as given, `LIBS:codecs/` not read.
pub var test_modules: ?[]const modtable.Found = null;

/// The kinds a module reads, a bit each.
pub fn kindsOf(found: *const modtable.Found) u32 {
    return found.word(0);
}

pub fn priorityOf(found: *const modtable.Found) i32 {
    return @bitCast(found.word(1));
}

/// A row for a module made from its tag, as the host tests hand them in.
pub fn row(name: []const u8, kinds: u32, priority: i32) modtable.Found {
    var found: modtable.Found = .{};
    @memcpy(found.name[0..name.len], name);
    found.words[0] = kinds;
    found.words[1] = @bitCast(priority);
    return found;
}

/// The table brought up to date with `LIBS:codecs/`: the base's own, good
/// while `modules_lock` is held. Null without the memory for it.
///
/// Called with the lock held.
pub fn refresh(base: *MediaBase) ?*const Table {
    const table = tableOf(base, &base.modules) orelse return null;
    if (test_modules) |given| {
        table.count = @intCast(@min(given.len, max_modules));
        for (given[0..table.count], 0..) |found, i| table.list[i] = found;
        return table;
    }
    const scratch = tableOf(base, &base.scratch) orelse return null;
    scratch.count = modtable.scan(base.dos_base, looking, &scratch.list, table.rows());
    table.* = scratch.*;
    return table;
}

fn tableOf(base: *MediaBase, slot: *?*anyopaque) ?*Table {
    if (slot.*) |found| return @ptrCast(@alignCast(found));
    const memory = base.sys_base.AllocMem(@sizeOf(Table), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const table: *Table = @ptrCast(@alignCast(memory));
    table.* = .{};
    slot.* = table;
    return table;
}

/// The `skip`-th module that reads `kind`, in the order they are tried -
/// the higher priority first, then by name - or null when there is no
/// such module.
///
/// Takes `modules_lock` itself, and hands back a copy.
pub fn nth(base: *MediaBase, kind: u32, skip: u32) ?modtable.Found {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.modules_lock);
    defer sys.ReleaseSemaphore(&base.modules_lock);
    const table = refresh(base) orelse return null;
    const bit = mcontainer.kindBit(kind);
    if (bit == 0) return null;
    var taken: ?modtable.Found = null;
    var step: u32 = 0;
    while (step <= skip) : (step += 1) {
        var best: ?modtable.Found = null;
        for (table.rows()) |found| {
            if (kindsOf(&found) & bit == 0) continue;
            if (taken) |last| {
                if (!before(last, found)) continue;
            }
            if (best) |so_far| {
                if (!before(found, so_far)) continue;
            }
            best = found;
        }
        taken = best orelse return null;
    }
    return taken;
}

/// Whether `a` is tried before `b`: the higher priority first, then by
/// name.
fn before(a: modtable.Found, b: modtable.Found) bool {
    if (priorityOf(&a) != priorityOf(&b)) return priorityOf(&a) > priorityOf(&b);
    for (a.name, b.name) |x, y| {
        if (x != y) return x < y;
        if (x == 0) break;
    }
    return false;
}

/// What the base holds given back, at the expunge.
pub fn forget(base: *MediaBase) void {
    for ([_]*?*anyopaque{ &base.modules, &base.scratch }) |slot| {
        if (slot.*) |found| {
            base.sys_base.FreeMem(found, @sizeOf(Table));
            slot.* = null;
        }
    }
}
