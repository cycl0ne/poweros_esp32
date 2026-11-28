// SPDX-License-Identifier: MPL-2.0
//! acpi.resource's ROM tag, and the init routine it names: the namespace
//! made and the firmware's tables of bytecode loaded into it, once, at
//! cold start.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const acpi = sdk.resources.acpi;
const hardware_acpi = sdk.hardware.acpi;
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const acpi_lvo = @import("acpi_lvo.zig");
const AcpiBase = @import("acpi_base.zig").AcpiBase;
const machine = @import("machine/_machine.zig");
const namespace = @import("namespace/_namespace.zig");
const tables = @import("tables/_tables.zig");

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = acpi.ACPINAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "28.11.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The pool's puddles, and the size above which a block is a puddle of
/// its own: the namespace is a few thousand blocks of tens of bytes, and
/// a buffer or a package now and then of a few hundred.
const PUDDLE_SIZE = 16 * 1024;
const THRESHOLD = 4 * 1024;

fn acpiBase(lib: *exec.Library) *AcpiBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// The firmware's root, as the board's firmware part names it: null on a
/// board without one, or where it does not hold.
fn firmwareRoot(sys: *ExecBase) ?hardware_acpi.Root {
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    defer sys.CloseLibrary(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const ub: *UtilityBase = @ptrCast(utility_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_FIRMWARE, st.CHIP_ACPI) orelse return null;
    return hardware_acpi.rootAt(ub.GetTagData(st.PART_Address, 0, part.tags));
}

/// ResInit: the namespace with the names it starts with, and the
/// firmware's tables loaded into it - the DSDT, then each SSDT and PSDT
/// in the root's order. A board without the firmware's tables has the
/// starting names alone; a machine without memory for even those has no
/// namespace, and every call answers null. What loading found is said in
/// the log: a line for the whole, and one for each name defined again,
/// each scope that is not there, and each term the interpreter cannot
/// read.
///
/// CONTEXT:
/// - Waits: for memory. - Interrupts: no; it runs on the exec task at
///   cold start.
/// - Locks: none needed: nothing has the resource yet. - Process: a Task
///   will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const ab = acpiBase(lib);
    lib.revision = RESOURCE_REVISION;
    ab.sys_base = sys_base;
    ab.machine = &machine.rom;
    ab.pool = null;
    ab.root = null;
    ab.integer_bits = 64;
    ab.tables = 0;
    ab.loaded = .{};
    sys_base.InitSemaphore(&ab.lock);
    ab.pool = sys_base.CreatePool(exec.MEMF_ANY, PUDDLE_SIZE, THRESHOLD) orelse return lib;
    if (!namespace.make(ab)) return lib;
    const root = firmwareRoot(sys_base) orelse return lib;
    tables.loadFirmware(ab, &root);
    const loaded = ab.loaded;
    machine.log(ab, exec.LOG_INFO, "%u tables, %u names; %u terms outside a method; %u defined again, %u not there, %u not known, %u broken\n", .{
        @as(u32, ab.tables), loaded.names, loaded.code, loaded.again, loaded.missing, loaded.unknown, loaded.broken,
    });
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(AcpiBase),
    .vectors = &acpi_lvo.vectors,
    .vector_count = acpi_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 27: after expansion.library, which the firmware's root is
/// found through, and after power.resource and thermal.resource, which
/// come up from the board's parts alone.
pub export const acpi_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &acpi_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 27,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
