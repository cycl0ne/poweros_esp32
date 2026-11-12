// SPDX-License-Identifier: MPL-2.0
//! FindKeyMap: a keymap by name - one on the library's list, or one in a
//! file, which is loaded and put on the list.
//!
//! A keymap's file is `DEVS:Keymaps/<name>`, a load file as a command's
//! is: LoadSeg reads it and applies its relocations, so the tables in it
//! point at each other and can be read. What is looked for in its segments
//! is a ROM tag - the match word and the pointer to itself - that says
//! keymap and has the name asked for; its rt_Init is the `KeyMapFile`. The
//! keymap's node is made from that, with the ROM's tables for the keys the
//! file leaves out, and the file's segments stay loaded for as long as the
//! library is there: a keymap, once found, may be the default, and anyone
//! may hold it.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const keymap = sdk.keymap;
const DosBase = sdk.interface.dos.DosBase;
const usa = @import("usa.zig");
const KeymapBase = @import("keymap_base.zig").KeymapBase;

/// A keymap by name: one on the library's list, or one in a file.
///
/// SYNOPSIS:
/// ```zig
/// fn FindKeyMap(kb: *KeymapBase, name: [*:0]const u8) ?*keymap.KeyMap
/// ```
///
/// SINCE: 0.1. LVO -36.
///
/// INPUTS:
/// - `name` - "deutsch", "usa", or a file's in `DEVS:Keymaps`
///   ("inscript"), at most KEYMAP_NAME_MAX bytes.
///
/// RESULT:
/// The keymap, or null when there is none of that name.
///
/// BEHAVIOR:
/// The names are compared exactly. A name the list has not is looked for
/// as the file `DEVS:Keymaps/<name>` (0.3): a load file
/// with a ROM tag of the type `NodeType.keymap` and that name, whose
/// rt_Init is a `KeyMapFile`. The file is loaded once and its keymap is
/// on the list from then on; the tables of the keys from 0x40 up that the
/// file leaves null are the ROM's keymaps' own. A file with no such tag
/// is unloaded again.
///
/// CONTEXT:
/// - Waits: for the file system, when the name is not on the list.
/// - Interrupts: no. - Locks: the list's, taken and released here; it is
///   not held while the file is read.
/// - Process: a file is read for a process only. A Task finds what is on
///   the list.
///
/// OWNERSHIP:
/// The library's; it stays.
///
/// NOTES:
/// What SetKeyMapDefault is given. dos.library's error of a file not
/// found is left in the caller's IoErr.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetKeyMapDefault`, `KeyMapName`
///
/// EXAMPLES:
/// ```zig
/// const german = kb.FindKeyMap("deutsch");
/// ```
pub fn FindKeyMap(kb: *KeymapBase, name: [*:0]const u8) ?*keymap.KeyMap {
    if (listed(kb, name)) |found| return found;
    return load(kb, name);
}

/// The keymap of that name on the list.
fn listed(kb: *KeymapBase, name: [*:0]const u8) ?*keymap.KeyMap {
    const sys = kb.sys_base;
    sys.AcquireLock(&kb.maps_lock);
    defer sys.ReleaseLock(&kb.maps_lock);
    const node = sys.FindName(&kb.maps, name) orelse return null;
    const kn: *keymap.KeyMapNode = @fieldParentPtr("node", node);
    return &kn.key_map;
}

/// A keymap made from a file: its node, whose name points at `name`, and
/// the file's segments, which its tables are in.
pub const Loaded = extern struct {
    node: keymap.KeyMapNode,
    seg_list: ?*dos.SegList,
    name: [keymap.KEYMAP_NAME_MAX + 1]u8,
};

/// How long `name` is, when it can be a file's in the keymaps' drawer:
/// not empty, not too long, and a name rather than a path.
fn fileNameLength(name: [*:0]const u8) ?usize {
    var length: usize = 0;
    while (name[length] != 0) : (length += 1) {
        if (length == keymap.KEYMAP_NAME_MAX) return null;
        if (name[length] == ':' or name[length] == '/') return null;
    }
    return if (length == 0) null else length;
}

/// The keymap `name` from its file, on the list. Null when the caller is
/// no process, or there is no such file, or it holds no keymap of that
/// name.
fn load(kb: *KeymapBase, name: [*:0]const u8) ?*keymap.KeyMap {
    const sys = kb.sys_base;
    const length = fileNameLength(name) orelse return null;
    const caller = sys.FindTask(null) orelse return null;
    if (caller.node.type != .process) return null;

    var path: [keymap.KEYMAP_DRAWER.len + keymap.KEYMAP_NAME_MAX + 1]u8 = undefined;
    @memcpy(path[0..keymap.KEYMAP_DRAWER.len], keymap.KEYMAP_DRAWER);
    @memcpy(path[keymap.KEYMAP_DRAWER.len..][0..length], name[0..length]);
    path[keymap.KEYMAP_DRAWER.len + length] = 0;

    const dos_library = sys.OpenLibrary(dos.DOSNAME, 0) orelse return null;
    defer sys.CloseLibrary(dos_library);
    const dos_lib: *DosBase = @ptrCast(@alignCast(dos_library));
    const seg_list = dos_lib.LoadSeg(@ptrCast(&path)) orelse return null;
    const file = fileIn(dos_lib, seg_list, name) orelse {
        dos_lib.UnLoadSeg(seg_list);
        return null;
    };
    const made = adopt(kb, name, file, seg_list) orelse {
        dos_lib.UnLoadSeg(seg_list);
        return null;
    };
    // Another process may have loaded it meanwhile: its keymap is the one,
    // and this file goes again.
    if (made.seg_list != seg_list) dos_lib.UnLoadSeg(seg_list);
    return &made.node.key_map;
}

/// The keymap of the tag named `name` in a loaded file.
fn fileIn(dos_lib: *DosBase, seg_list: *dos.SegList, name: [*:0]const u8) ?*const keymap.KeyMapFile {
    var tag = dos_lib.FindSegResident(seg_list, null, .keymap);
    while (tag) |found| : (tag = dos_lib.FindSegResident(seg_list, found, .keymap)) {
        if (!sameName(found.name, name)) continue;
        return @ptrCast(@alignCast(found.init orelse continue));
    }
    return null;
}

fn sameName(one: [*:0]const u8, other: [*:0]const u8) bool {
    var at: usize = 0;
    while (one[at] == other[at]) : (at += 1) {
        if (one[at] == 0) return true;
    }
    return false;
}

/// `file`'s keymap on the list as `name`: the node made here, or the one
/// that was put there meanwhile. Null without memory.
///
/// INPUTS:
/// - `kb` - the library's base.
/// - `name` - the keymap's name, at most KEYMAP_NAME_MAX bytes; copied.
/// - `file` - the file's tables, which stay where they are.
/// - `seg_list` - the file's segments, kept with the node.
///
/// RESULT:
/// The record on the list. Its `seg_list` is the one given when it was
/// made here.
pub fn adopt(kb: *KeymapBase, name: [*:0]const u8, file: *const keymap.KeyMapFile, seg_list: ?*dos.SegList) ?*Loaded {
    const sys = kb.sys_base;
    const made: *Loaded = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(Loaded), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null));
    var length: usize = 0;
    while (name[length] != 0 and length < keymap.KEYMAP_NAME_MAX) : (length += 1) made.name[length] = name[length];
    made.name[length] = 0;
    made.seg_list = seg_list;
    made.node = .{
        .node = .{ .name = @ptrCast(&made.name) },
        .key_map = .{
            .lo_key_map_types = file.lo_key_map_types,
            .lo_key_map = file.lo_key_map,
            .lo_capsable = file.lo_capsable,
            .lo_repeatable = file.lo_repeatable,
            .hi_key_map_types = file.hi_key_map_types orelse &usa.hi_types,
            .hi_key_map = file.hi_key_map orelse &usa.hi_map,
            .hi_capsable = file.hi_capsable orelse &usa.hi_capsable,
            .hi_repeatable = file.hi_repeatable orelse &usa.hi_repeatable,
        },
    };

    sys.AcquireLock(&kb.maps_lock);
    const there = sys.FindName(&kb.maps, name);
    if (there == null) sys.AddTail(&kb.maps, &made.node.node);
    sys.ReleaseLock(&kb.maps_lock);
    const node = there orelse return made;
    sys.FreeVec(made);
    // Only a file's keymap is added while the library runs, and the ROM's
    // are found before a file is looked for.
    const kn: *keymap.KeyMapNode = @fieldParentPtr("node", node);
    return @fieldParentPtr("node", kn);
}
