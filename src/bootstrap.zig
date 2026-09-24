// SPDX-License-Identifier: MPL-2.0
//! The bootstrap: gets exec.library going, from outside exec.
//!
//! There is no SysBase yet, so no AllocMem. The RAM regions become
//! MemHeaders, and exec's own ROM tag is looked up in the .resident
//! section. exec.library is built from the tag's InitTable with Allocate on
//! the first region that has room (a stripped-down MakeLibrary), and the
//! regions go on MemList. Then exec's init routine (initExec) sets up the
//! rest and starts the system: the ROM scan, the exec task and the
//! RTF_SINGLETASK residents.

const exec = @import("rom/libs/exec/exec.zig");
const layout = @import("arch/esp32s3/layout.zig");

pub const Error = error{ NoExecTag, NoMemory, ExecInitFailed };

pub fn bootStrap(regions: []const exec.MemRegion) Error!*exec.ExecBase {
    const rom_start = layout.residentStart();
    const rom_end = layout.residentEnd();
    const tag = exec.findTag(rom_start, rom_end, exec.LIBRARY_NAME) orelse return error.NoExecTag;
    const table: *const exec.InitTable = @ptrCast(@alignCast(tag.init orelse return error.NoExecTag));
    const init = table.init orelse return error.NoExecTag;
    const vectors = table.vectors[0..table.vector_count];
    const sizes = exec.librarySizes(vectors.len, table.data_size) orelse return error.NoExecTag;

    // The regions as MemHeaders; exec.library from the first one with room.
    // There is no ExecBase yet, so these calls get `undefined` for it: none
    // of them reads the base. That is a stopgap - the bootstrap wants
    // rewriting so that exec's base exists before anything is called.
    const no_base: *exec.ExecBase = undefined;
    var pending: exec.List = .{};
    pending.init(.memory);
    var block: ?*anyopaque = null;
    for (regions) |r| {
        const mh = exec.CreateMemHeader(no_base, r.size, r.attributes, r.pri, r.base, r.name) orelse continue;
        if (block == null) block = exec.Allocate(no_base, mh, sizes.neg + sizes.pos);
        exec.Enqueue(no_base, &pending, &mh.node);
    }
    const lib = exec.buildLibrary(@ptrCast(block orelse return error.NoMemory), vectors, sizes);
    lib.node.name = tag.name;
    lib.node.type = tag.type;
    lib.version = tag.version;
    lib.id_string = tag.id_string;
    const sys: *exec.ExecBase = @fieldParentPtr("lib", lib);
    sys.mem_list.init(.memory);
    while (exec.RemHead(sys, &pending)) |node| exec.Enqueue(sys, &sys.mem_list, node);

    // exec's init routine does the rest. The ROM range tells it where the
    // other residents are.
    const info: exec.BootInfo = .{ .rom_start = rom_start, .rom_end = rom_end };
    _ = init(lib, @constCast(&info), @ptrCast(sys)) orelse return error.ExecInitFailed;
    return sys;
}
