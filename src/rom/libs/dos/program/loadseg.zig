// SPDX-License-Identifier: MPL-2.0
//! LoadSeg: loads a program or module file into memory, ready to run.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _program = @import("_program.zig");
const relocate = _program.relocate;
const readSegment = _program.readSegment;
const SegList = dos.SegList;
const Loaded = _program.Loaded;
const max_segments = _program.max_segments;
const fail = _program.fail;
const loadfile = dos.loadfile;
const readAll = _program.readAll;

/// Loads a program or module file into memory, ready to run.
///
/// SYNOPSIS:
/// ```zig
/// fn LoadSeg(db: *DosBase, name: [*:0]const u8) ?*dos.SegList
/// ```
///
/// SINCE: 1.0. LVO -544.
///
/// INPUTS:
/// - `name` - the load file's name, as for Open.
///
/// RESULT:
/// The chain of segments, the first one with the entry point in its
/// `entry` - which a `SegCode` wraps for RunCommand or CreateNewProc -
/// and later UnLoadSeg; IoErr is 0. Null on failure, with IoErr set: ERROR_OBJECT_WRONG_TYPE for a file
/// that isn't a load file, or is one for another CPU or word size,
/// ERROR_BAD_HUNK for one that is
/// damaged (too many or too large segments, relocations outside them, an
/// entry point outside the code), ERROR_NO_FREE_STORE, or Open's error.
///
/// BEHAVIOR:
/// The file's header names the CPU and the width of an address word it
/// was built for; both must be this machine's. A version-1 file names
/// neither and is taken as an Xtensa one.
///
/// Each segment gets one block of memory the CPU can run code from, its
/// bytes read in and the rest cleared. Once all are in, the relocations are
/// applied: each word named gets the base of its target segment added, the
/// instruction-bus address for a code segment. The caches are cleared
/// before the chain is answered, so the new code is what runs. On failure
/// everything loaded so far is freed.
///
/// CONTEXT:
/// - Waits: yes, for the file system.
/// - Interrupts: not callable.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; only a process gets IoErr.
///
/// OWNERSHIP:
/// The chain is the caller's until UnLoadSeg, which frees it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnLoadSeg`, `RunCommand`, `CreateNewProc`
///
/// EXAMPLES:
/// ```zig
/// const seg = dos_lib.LoadSeg("C:dir") orelse return dos_lib.IoErr();
/// defer dos_lib.UnLoadSeg(seg);
/// const entry = seg.entry orelse return dos.ERROR_FILE_NOT_OBJECT; // a program's CommandFn
/// ```
pub fn LoadSeg(db: *DosBase, name: [*:0]const u8) ?*dos.SegList {
    const dos_lib = db.iface();
    const fh = dos_lib.Open(name, dos.MODE_OLDFILE) orelse return null;
    defer _ = dos_lib.Close(fh);

    // A version-1 header is the first part of a version-2 one.
    var header: loadfile.Header = undefined;
    const header_bytes: [*]u8 = @ptrCast(&header);
    if (!readAll(db, fh, header_bytes[0..loadfile.HEADER_V1_SIZE])) return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
    if (@as(u32, @bitCast(header.magic)) != @as(u32, @bitCast(loadfile.MAGIC))) return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
    switch (header.version) {
        // Before files said which CPU they were for, they were Xtensa's.
        1 => if (loadfile.native_machine != loadfile.MACHINE_XTENSA) return fail(db, dos.ERROR_OBJECT_WRONG_TYPE),
        loadfile.VERSION => {
            if (!readAll(db, fh, header_bytes[loadfile.HEADER_V1_SIZE..@sizeOf(loadfile.Header)]))
                return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
            if (header.machine != loadfile.native_machine or header.word_size != loadfile.native_word_size)
                return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
        },
        else => return fail(db, dos.ERROR_OBJECT_WRONG_TYPE),
    }
    if (header.segments == 0 or header.segments > max_segments) return fail(db, dos.ERROR_BAD_HUNK);

    var loaded: [max_segments]Loaded = @splat(.{});
    var segments: [max_segments]?*SegList = @splat(null);
    var first: ?*SegList = null;
    var last: ?*SegList = null;
    var i: u16 = 0;
    while (i < header.segments) : (i += 1) {
        const seg = readSegment(db, fh, &loaded[i], if (i == 0) dos_lib.FilePart(name) else null) orelse {
            dos_lib.UnLoadSeg(first);
            return null;
        };
        segments[i] = seg;
        if (last) |l| l.next = seg else first = seg;
        last = seg;
    }
    if (!relocate(db, fh, first, &loaded)) {
        dos_lib.UnLoadSeg(first);
        return null;
    }
    // Where it starts, for the caller: RunCommand and CreateNewProc take it
    // as a SegCode.
    const entry_seg = segments[if (header.entry_segment < header.segments) header.entry_segment else 0] orelse unreachable;
    if (header.entry_segment >= header.segments or entry_seg.kind != .code or
        header.entry_offset >= entry_seg.mem_size)
    {
        dos_lib.UnLoadSeg(first);
        return fail(db, dos.ERROR_BAD_HUNK);
    }
    first.?.entry = @ptrCast(entry_seg.run_address.? + header.entry_offset);
    db.sys_base.CacheClearU(); // the code was written through the data bus
    // On the list of loaded files, for a Guru to name.
    db.sys_base.AcquireLock(&db.code_lock);
    db.sys_base.AddTail(&db.loaded, &first.?.file);
    db.sys_base.ReleaseLock(&db.code_lock);
    _ = dos_lib.SetIoErr(0);
    return first;
}
