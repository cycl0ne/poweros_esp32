// SPDX-License-Identifier: MIT
//! The sound modules there are: `LIBS:codecs/*.acodec`, each found by the
//! tag in its own file (`acodec.ResidentACodec`), which says what it
//! decodes. The library holds no list of the kinds there are: what this
//! disk decodes is what the modules on it say, so a kind whose module was
//! left off a board's disk is simply not there, and one dropped in is
//! found.
//!
//! The reading is `dos.modtable`'s, shared with media.library and the
//! same work videocodec.library does for pictures: a tag is read out of
//! the file and nothing is loaded, and a file whose name, date and size
//! have not changed keeps what its tag said. The table lives in the base,
//! shared by every opener, under `modules_lock`; `scratch` is where the
//! next one is built, so the one in use is never half written.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ac = sdk.audiocodec;
const acodec = sdk.acodec;
const modtable = dos.modtable;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;

/// The most modules kept.
pub const max_modules = 16;

/// What is looked for, and how its words are read: the kinds a bit each,
/// then the chip or software kind, then the priority.
pub const looking: modtable.Kind = .{
    .dir = ac.ACODEC_DIR,
    .prefix = acodec.ACODEC_PREFIX,
    .suffix = ".acodec",
    .magic = acodec.ACODEC_MAGIC,
    .words = 3,
};

/// The modules there are, in the base's `modules`.
pub const Table = struct {
    count: u32 = 0,
    list: [max_modules]modtable.Found = @splat(.{}),

    pub fn rows(table: *const Table) []const modtable.Found {
        return table.list[0..@min(table.count, max_modules)];
    }
};

/// The host tests' modules, made with InitResident: the table as given,
/// `LIBS:codecs/` not read - each name as the host's exec finds it.
pub var test_modules: ?[]const modtable.Found = null;

/// The kinds a module decodes, a bit each.
pub fn codecsOf(found: *const modtable.Found) u32 {
    return found.word(0);
}

/// ACMOD_CHIP or ACMOD_SOFTWARE.
pub fn kindOf(found: *const modtable.Found) u32 {
    return found.word(1);
}

pub fn priorityOf(found: *const modtable.Found) i32 {
    return @bitCast(found.word(2));
}

/// A row for a module made from its tag, as the host tests hand them in.
pub fn row(name: []const u8, codecs: u32, kind: u32, priority: i32) modtable.Found {
    var found: modtable.Found = .{};
    @memcpy(found.name[0..name.len], name);
    found.words[0] = codecs;
    found.words[1] = kind;
    found.words[2] = @bitCast(priority);
    return found;
}

/// The table brought up to date with `LIBS:codecs/`: the base's own, good
/// while `modules_lock` is held. Null without the memory for it.
///
/// Called with the lock held.
pub fn refresh(base: *AudioCodecBase) ?*const Table {
    const table = tableOf(base, &base.modules) orelse return null;
    if (test_modules) |given| {
        table.count = @intCast(@min(given.len, max_modules));
        for (given[0..table.count], 0..) |found, i| table.list[i] = found;
        return table;
    }
    const scratch = tableOf(base, &base.scratch) orelse return null;
    scratch.count = modtable.scan(base.dos_base, looking, &scratch.list, table.rows());
    // The one in use is replaced whole, never written into while it is
    // being read: both are the base's and both are under the lock.
    table.* = scratch.*;
    return table;
}

fn tableOf(base: *AudioCodecBase, slot: *?*anyopaque) ?*Table {
    if (slot.*) |found| return @ptrCast(@alignCast(found));
    // Kept in the library's base: the system's.
    const memory = base.sys_base.AllocMem(@sizeOf(Table), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const table: *Table = @ptrCast(@alignCast(memory));
    table.* = .{};
    slot.* = table;
    return table;
}

/// The `skip`-th module that decodes `codec`, in the order they are tried
/// - a chip's before software, the higher priority first, then by name -
/// or null when there is no such module: `skip` 0 is the first to try,
/// and a caller whose stream the module refused asks for the next.
///
/// Takes `modules_lock` itself, and hands back a copy, so the table may
/// be read again while the module is opened.
pub fn nth(base: *AudioCodecBase, codec: u32, skip: u32) ?modtable.Found {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.modules_lock);
    defer sys.ReleaseSemaphore(&base.modules_lock);
    const table = refresh(base) orelse return null;
    const bit = acodec.codecBit(codec);
    if (bit == 0) return null;
    // Selection: the best, then the best after that, `skip` + 1 times.
    // At most max_modules rows, so counting them again each time costs
    // nothing worth keeping a list for.
    var taken: ?modtable.Found = null;
    var step: u32 = 0;
    while (step <= skip) : (step += 1) {
        var best: ?modtable.Found = null;
        for (table.rows()) |found| {
            if (codecsOf(&found) & bit == 0) continue;
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

/// Whether `a` is tried before `b`: a chip's before software, the higher
/// priority first, then by name. Two modules never share a name - one
/// file, one name - so this orders them outright.
fn before(a: modtable.Found, b: modtable.Found) bool {
    if (rank(kindOf(&a)) != rank(kindOf(&b))) return rank(kindOf(&a)) < rank(kindOf(&b));
    if (priorityOf(&a) != priorityOf(&b)) return priorityOf(&a) > priorityOf(&b);
    for (a.name, b.name) |x, y| {
        if (x != y) return x < y;
        if (x == 0) break;
    }
    return false;
}

fn rank(kind: u32) u32 {
    return switch (kind) {
        acodec.ACMOD_CHIP => 0,
        acodec.ACMOD_SOFTWARE => 1,
        else => 2,
    };
}

/// What the base holds given back, at the expunge.
pub fn forget(base: *AudioCodecBase) void {
    for ([_]*?*anyopaque{ &base.modules, &base.scratch }) |slot| {
        if (slot.*) |found| {
            base.sys_base.FreeMem(found, @sizeOf(Table));
            slot.* = null;
        }
    }
}
