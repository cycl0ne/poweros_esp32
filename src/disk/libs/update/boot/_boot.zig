// SPDX-License-Identifier: MIT
//! The package's boot half written into the partition the firmware reads,
//! which is the other half of an update: the files on the system volume
//! are of no use to a machine whose firmware still loads last month's
//! kernel.
//!
//! That partition is not mounted while the machine runs
//! (`gpt.ATTR_NO_AUTOMOUNT`), so it is found the way the install left it
//! to be found: `install.prefs` names the device, the unit and the
//! partition's name in the GPT, and rdb.library walks the table and
//! mounts the entry of that name. One already mounted under that name is
//! used as it is, so nothing mounts a second drive over the first.
//!
//! **Where the firmware starts from either of two partitions** the one
//! not in use is written, `autoboot.txt` in the first of them is pointed
//! at it for a single start, and the machine that comes up on it makes
//! that permanent (`ConfirmUpdate`). A kernel that does not come up costs one
//! start: the flag goes away by itself and the firmware is back on the
//! partition that worked.
//!
//! **Where it reads one** the file being replaced is kept beside the new
//! one as `<name>.old`, since there is no other partition to fall back
//! on. What loads it then is the firmware's own prompt, over the console
//! that machine has attached.
//!
//! Nothing in the partition is deleted: it is the firmware's, and what
//! else somebody put there is their business.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const gpt = dos.gpt;
const rdb = sdk.rdb;
const install = sdk.install;
const manifest = install.manifest;
const autoboot = install.autoboot;
const prefs = sdk.prefs;
const RDBBase = sdk.interface.rdb.RDBBase;
const shared = @import("../run/_run.zig");
const source = @import("../package/_package.zig");
const compare = @import("../system/_system.zig");
const Run = shared.Run;
const Name = shared.Name;

/// The library this wants, the revision in which a GPT's FAT partition
/// can be mounted, and the one that can take a drive off the list again
/// - an older library leaves the partition mounted, which is a drive on
/// the screen until the machine restarts and nothing worse.
pub const rdb_version = 1;
const fat_revision = 7;
const unmount_revision = 8;

/// What the file being replaced is called where there is no second
/// partition to fall back on.
const old_suffix = ".old";

/// What a file is called in the partition while it is fetched.
const part_name = "update.part";

/// One of the firmware's partitions: its entry in the GPT, the number of
/// that entry, and the drive it is mounted as.
pub const Slot = struct {
    part: *rdb.GPTPartition = undefined,
    number: u32 = 0,
    drive: Name = .{},
    /// Whether this run mounted it, and so puts it back as it was.
    ours: bool = false,

    pub fn mounted(slot: *const Slot) bool {
        return slot.drive.text[0] != 0;
    }
};

/// The boot half written. The return code: 0 for a run that wrote what
/// it meant to, 5 for `UPD_Check` with something to do, 20 for one that
/// could not.
pub fn write(run: *Run, fresh: []const u8) i32 {
    const sys = run.sys;
    const settings = &run.settings;
    const device: [*:0]const u8 = @ptrCast(&settings.device);
    const boot: [*:0]const u8 = @ptrCast(&settings.boot);
    if (device[0] == 0 or boot[0] == 0) {
        return shared.fail(run, "%s says nothing about the partition the firmware reads\n", .{prefs.install.ENVARC_FILE});
    }

    const rdb_lib = sys.OpenLibrary(rdb.RDBNAME, rdb_version) orelse {
        return shared.fail(run, "%s 1 or later is not there\n", .{rdb.RDBNAME});
    };
    defer sys.CloseLibrary(rdb_lib);
    if (rdb_lib.version == 1 and rdb_lib.revision < fat_revision) {
        return shared.fail(run, "%s 1.%d or later mounts a GPT's FAT partition; this is 1.%d\n", .{
            rdb.RDBNAME, @as(u32, fat_revision), @as(u32, rdb_lib.revision),
        });
    }
    const rb: *RDBBase = @ptrCast(rdb_lib);

    var err: i32 = rdb.RDBERR_OK;
    const handle = rb.OpenRDB(device, settings.unit, &err) orelse {
        return shared.fail(run, "%s unit %d: the disk's table cannot be read\n", .{ device, settings.unit });
    };
    defer rb.CloseRDB(handle);

    // The pair, in the order their entries are in the table: the first
    // is the one the firmware looks in for `autoboot.txt`.
    var slots: [2]Slot = .{ .{}, .{} };
    var count: usize = 0;
    defer {
        for (slots[0..count]) |*one| unmount(run, rb, handle, one);
    }
    const boot_b: [*:0]const u8 = @ptrCast(&settings.boot_b);
    for ([_][*:0]const u8{ boot, boot_b }) |name| {
        if (name[0] == 0) continue;
        const part = named(run, rb, handle, name) orelse {
            return shared.fail(run, "the GPT on %s unit %d has no partition %s, which %s says the firmware reads\n", .{
                device, settings.unit, name, prefs.install.ENVARC_FILE,
            });
        };
        slots[count] = .{ .part = part, .number = part.number };
        count += 1;
    }
    if (count == 2 and slots[1].number < slots[0].number) {
        const first = slots[0];
        slots[0] = slots[1];
        slots[1] = first;
    }

    // Which one the firmware starts from now, and so which one is
    // written: the file in the first of them says, and where it says
    // nothing the firmware takes the first.
    var settings_file: autoboot.Settings = .{};
    var which: usize = 0;
    if (count == 2) {
        if (mount(run, rb, handle, &slots[0])) |code| return code;
        settings_file = readAutoboot(run, &slots[0]);
        const active = if (settings_file.normal != 0) settings_file.normal else slots[0].number;
        which = if (active == slots[0].number) 1 else 0;
    }
    const slot = &slots[which];
    if (mount(run, rb, handle, slot)) |code| return code;

    shared.row(run, "slot", slot.drive.cstr(), 0);
    const code = files(run, fresh, slot, count == 1);
    if (code != dos.RETURN_OK) return code;

    // The firmware told to read the written partition for one start. The
    // file goes in the first of the pair, which is where it looks.
    if (count == 2 and run.boot_written != 0) {
        const fresh_settings: autoboot.Settings = .{
            .normal = if (settings_file.normal != 0) settings_file.normal else slots[0].number,
            .tried = slot.number,
            .a_b = true,
        };
        if (writeAutoboot(run, &slots[0], fresh_settings)) |failed| return failed;
        run.tried = slot.number;
    }
    return dos.RETURN_OK;
}

/// Every file of the package's boot half written into the slot. `keep`
/// holds the file being replaced beside the new one.
fn files(run: *Run, fresh: []const u8, slot: *const Slot, keep: bool) i32 {
    var reader = manifest.Reader.init(fresh) catch |err| {
        return shared.fail(run, "the package's %s: %s\n", .{ install.package_manifest, manifest.why(err) });
    };
    // A file is fetched to a name on the partition it belongs to, since
    // the step that puts it in place is a rename.
    const partial = Name.of(root(run, slot), part_name);
    while (reader.next() catch |err| {
        return shared.fail(run, "the package's %s: %s\n", .{ install.package_manifest, manifest.why(err) });
    }) |entry| {
        if (shared.stopped(run)) return dos.RETURN_WARN;
        const part = install.halfOf(entry.path) orelse continue;
        if (part.half != .boot or part.rest.len == 0) continue;
        const where = Name.of(root(run, slot), part.rest);
        if (entry.kind == .drawer) {
            run.made += 1;
            shared.row(run, "drawer", where.cstr(), 0);
            if (run.check) continue;
            if (run.dl.CreateDir(where.cstr()) == null and run.dl.IoErr() != dos.ERROR_OBJECT_EXISTS) {
                return shared.failed(run, where.cstr(), run.dl.IoErr());
            }
            continue;
        }
        // A file that is already what the list says is left where it is,
        // so writing the partition again after a reboot costs nothing.
        if (compare.sameFile(run, where.cstr(), entry)) {
            shared.row(run, "same", where.cstr(), 0);
            continue;
        }
        run.written += 1;
        run.written_bytes += entry.size;
        run.boot_written += 1;
        shared.row(run, "boot", where.cstr(), entry.size);
        // The one being replaced is kept beside the new one where there
        // is no other partition to fall back on.
        var kept = where;
        if (keep) {
            const at = run.ub.Strlen(kept.cstr());
            _ = shared.copy(kept.text[at..], old_suffix);
            kept.text[at + old_suffix.len] = 0;
        }
        var there = false;
        if (keep) {
            if (run.dl.Lock(where.cstr(), dos.SHARED_LOCK)) |lock| {
                run.dl.UnLock(lock);
                there = true;
            }
        }
        if (run.check) {
            if (there) shared.row(run, "kept", kept.cstr(), 0);
            continue;
        }
        if (compare.write(run, entry.path, entry, .{
            .where = where.cstr(),
            .part = partial.cstr(),
            .keep = if (there) kept.cstr() else null,
        })) |code| return code;
    }
    return dos.RETURN_OK;
}

/// A drive's name with its colon, as dos takes it.
fn driveOf(run: *Run, name: [*:0]const u8) Name {
    var drive: Name = .{};
    const at = shared.copy(&drive.text, name[0..run.ub.Strlen(name)]);
    drive.text[at] = ':';
    drive.text[at + 1] = 0;
    return drive;
}

/// A slot's drive as a path's root.
fn root(run: *Run, slot: *const Slot) []const u8 {
    return slot.drive.text[0..run.ub.Strlen(slot.drive.cstr())];
}

/// What a mount said went wrong.
fn errorText(err: i32) [*:0]const u8 {
    return switch (err) {
        rdb.RDBERR_NOMEM => "not enough memory",
        rdb.RDBERR_DEVICE => "no such device or unit, or no medium in it",
        rdb.RDBERR_IO => "the device refused a transfer",
        rdb.RDBERR_NAME => "a name that is empty, too long, holds a colon or a slash, or is taken",
        rdb.RDBERR_FILESYSTEM => "no handler serves its DosType here",
        rdb.RDBERR_CHANGED => "the medium in the unit is not the one the table was read from",
        rdb.RDBERR_MOUNTED => "a drive has some of its blocks already",
        rdb.RDBERR_GPT => "the call does not go with the disk's GPT",
        rdb.RDBERR_NOGPT => "the disk has no sound GPT",
        else => "failed",
    };
}

/// The GPT's partition of that name.
pub fn named(run: *Run, rb: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8) ?*rdb.GPTPartition {
    const wanted = name[0..run.ub.Strlen(name)];
    var part = rb.NextGPTPartition(handle, null);
    while (part) |one| : (part = rb.NextGPTPartition(handle, one)) {
        var text: [gpt.name_units:0]u8 = @splat(0);
        _ = gpt.nameText(&one.entry, &text);
        const got: [*:0]const u8 = @ptrCast(&text);
        if (manifest.samePath(got[0..run.ub.Strlen(got)], wanted)) return one;
    }
    return null;
}

/// The slot given a drive, or the one it has already: its name with a
/// colon in `slot.drive`.
pub fn mount(run: *Run, rb: *RDBBase, handle: *rdb.RDBHandle, slot: *Slot) ?i32 {
    if (slot.mounted()) return null;
    var text: [gpt.name_units:0]u8 = @splat(0);
    _ = gpt.nameText(&slot.part.entry, &text);
    const wanted: [*:0]const u8 = @ptrCast(&text);

    // One of that name on this unit is this partition's drive: the
    // install mounted it to write it, or `RDB MOUNTGPT` did.
    if (already(run, wanted)) {
        slot.drive = driveOf(run, wanted);
        return null;
    }

    var got: rdb.MountName = @splat(0);
    const err = rb.MountGPTPartition(handle, slot.part, wanted, &got, rdb.RDBMF_START | rdb.RDBMF_FAT);
    if (err != rdb.RDBERR_OK) {
        return shared.fail(run, "%s cannot be mounted: %s\n", .{ wanted, errorText(err) });
    }
    slot.drive = driveOf(run, @ptrCast(&got));
    slot.ours = true;
    return null;
}

/// A slot this run mounted taken off the device list again: the
/// firmware's partition is not one to leave there, and the install left
/// it marked not to be mounted when the medium comes in. One that was
/// already mounted when this began is left as it was.
pub fn unmount(run: *Run, rb: *RDBBase, handle: *rdb.RDBHandle, slot: *Slot) void {
    if (!slot.ours) return;
    const library = rb.lib();
    if (library.version == rdb_version and library.revision < unmount_revision) return;
    var name: Name = .{};
    const text = slot.drive.text;
    var at: usize = 0;
    while (at < text.len and text[at] != 0 and text[at] != ':') : (at += 1) name.text[at] = text[at];
    name.text[at] = 0;
    if (rb.UnmountPartition(handle, name.cstr()) == rdb.RDBERR_OK) {
        slot.ours = false;
        slot.drive = .{};
        return;
    }
    shared.say(run, "%s is still mounted: something is open on it\n", .{slot.drive.cstr()});
}

/// Whether dos has a drive of that name already.
fn already(run: *Run, name: [*:0]const u8) bool {
    const dl = run.dl;
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const list = dl.LockDosList(flags) orelse return false;
    defer dl.UnLockDosList(flags);
    var entry = dl.NextDosEntry(list, dos.LDF_DEVICES);
    while (entry) |node| : (entry = dl.NextDosEntry(node, dos.LDF_DEVICES)) {
        const text = node.name;
        if (manifest.samePath(text[0..run.ub.Strlen(text)], name[0..run.ub.Strlen(name)])) return true;
    }
    return false;
}

/// What `autoboot.txt` in the slot says; a file that is not there says
/// nothing, which is the firmware's own choice.
pub fn readAutoboot(run: *Run, slot: *const Slot) autoboot.Settings {
    const where = Name.of(root(run, slot), autoboot.file_name);
    const text = prefs.loadWhole(run.sys, run.dl, where.cstr()) orelse return .{};
    defer run.sys.FreeVec(@ptrCast(text.ptr));
    return autoboot.parse(text);
}

/// `autoboot.txt` written into the slot.
pub fn writeAutoboot(run: *Run, slot: *const Slot, settings: autoboot.Settings) ?i32 {
    const where = Name.of(root(run, slot), autoboot.file_name);
    var bytes: [autoboot.max_bytes]u8 = undefined;
    const length = autoboot.write(settings, &bytes);
    shared.row(run, "tried", where.cstr(), 0);
    if (run.check) return null;
    if (!prefs.save(run.dl, where.cstr(), bytes[0..length])) {
        return shared.failed(run, where.cstr(), run.dl.IoErr());
    }
    return null;
}
