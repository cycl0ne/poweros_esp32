// SPDX-License-Identifier: MIT
//! Acpi: the firmware's description tables - every one the root lists,
//! and the two the fixed description points at - listed, saved as the
//! files a disassembler reads as they are, and the fixed description read
//! whole. Built against the SDK only.
//!
//!   Acpi [TO <drawer>] [ROOT <address>] [FIXED]
//!
//!   Acpi                   every table: its signature, its revision, its
//!                          maker and the maker's name for it, its length,
//!                          its address, and whether its checksum holds
//!   Acpi TO RAM:acpi       each table saved into the drawer, which is made
//!                          where it is not there: under its four letters
//!                          and ".aml" (FACP.aml, DSDT.aml), numbered from 1
//!                          in the list's order where the list has more
//!                          than one with those letters (SSDT1.aml,
//!                          SSDT2.aml); the root as RSDP.aml, its list as
//!                          XSDT.aml (RSDT.aml on a root that has only the
//!                          old list), the control structure as FACS.aml
//!   Acpi ROOT 0x7FB7E014   the root at that address rather than where the
//!                          board's firmware part says: the address the
//!                          boot's lines give ("firmware tables at 0x...",
//!                          `C:Log`), for a kernel that writes no such part.
//!                          An address outside the machine's memory faults
//!   Acpi FIXED             the fixed description read whole rather than
//!                          the list: each register block with its space,
//!                          address and width, the line the hardware raises
//!                          and the port it is put into its mode on, the
//!                          clock's alarm registers, the reset register,
//!                          the flags and the boot architecture's by their
//!                          names; then the control structure, the shared
//!                          lock as it stands, and the embedded
//!                          controller's table where there is one - each
//!                          field under the name the tables give it
//!
//! The tables are in the firmware's own memory, which the system keeps
//! and maps where it is, so they are read in place; each is copied out
//! before it goes to its file. A machine without the firmware part has
//! no such tables, and Acpi says so and returns WARN.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const acpi = sdk.hardware.acpi;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const st_expansion = sdk.expansion;
const st = st_expansion.systemtags;
const Printf = dos.stdio.Printf;
const names = @import("names.zig");
const fixed = @import("fixed.zig");

pub const COMMAND_NAME = "Acpi";
const VERSION_STRING = "\x00$VER: Acpi 1.1 (28.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TO/K,ROOT/K,FIXED/S";
const arg_to = 0;
const arg_root = 1;
const arg_fixed = 2;

/// Room for a saved file's path: the drawer as given, then a table's name.
const PATH_ROOM = 512;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var address: usize = 0;
    if (argv[arg_root] != 0) {
        const text: [*:0]const u8 = @ptrFromInt(argv[arg_root]);
        address = numberOf(text) orelse {
            _ = Printf(dl, "%s: \"%s\" is not an address\n", .{ COMMAND_NAME, text });
            return dos.RETURN_FAIL;
        };
    } else {
        address = rootOfBoard(sys) orelse {
            _ = dl.PutStr("no firmware tables: the board has no firmware part for them (ROOT names a root by its address)\n");
            return dos.RETURN_WARN;
        };
    }
    const root = acpi.rootAt(address) orelse {
        _ = Printf(dl, "no firmware tables at 0x%lx: no root there, or its checksums do not hold\n", .{@as(u64, address)});
        return dos.RETURN_FAIL;
    };
    if (argv[arg_fixed] != 0) {
        if (!fixed.show(dl, &root)) return dos.RETURN_WARN;
    } else if (!list(dl, &root)) return dos.RETURN_WARN;
    if (argv[arg_to] != 0) {
        const drawer: [*:0]const u8 = @ptrFromInt(argv[arg_to]);
        return save(sys, dl, &root, drawer);
    }
    return dos.RETURN_OK;
}

/// The root's address, as the board's firmware part names it; null on a
/// board without one.
fn rootOfBoard(sys: *ExecBase) ?usize {
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    defer sys.CloseLibrary(utility_lib);
    const utility: *UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(st_expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_FIRMWARE, st.CHIP_ACPI) orelse return null;
    const address = utility.GetTagData(st.PART_Address, 0, part.tags);
    return if (address != 0) address else null;
}

// --- the listing -----------------------------------------------------------------------

/// The root's line, the list's own, then each table the list names in its
/// order, with the two the fixed description points at below it. False
/// where Ctrl-C broke it off.
fn list(dl: *DosBase, root: *const acpi.Root) bool {
    _ = Printf(dl, "root at 0x%lx, revision %u: %s at 0x%lx, %u tables\n", .{
        @as(u64, root.at),   @as(u32, root.revision), listName(root),
        @as(u64, root.list), root.count,
    });
    _ = dl.PutStr("table  rev  maker   its name     length  address             sum\n");
    printTable(dl, root.list, false);
    var index: u32 = 0;
    while (index < root.count) : (index += 1) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return false;
        }
        const table = root.table(index);
        if (table == 0) {
            _ = Printf(dl, "-      the list's entry %u is empty\n", .{index});
            continue;
        }
        printTable(dl, table, false);
        if (!isFixed(table)) continue;
        const dsdt = acpi.dsdtOf(table);
        if (dsdt != 0) printTable(dl, dsdt, true);
        const facs = acpi.facsOf(table);
        if (facs != 0) printFacs(dl, facs);
    }
    return true;
}

fn listName(root: *const acpi.Root) [*:0]const u8 {
    return if (root.wide) "XSDT" else "RSDT";
}

/// Whether the table at `table` is the fixed description and holds.
fn isFixed(table: usize) bool {
    const header = acpi.headerOf(table);
    return header.sound and sameLetters(header.signature, "FACP");
}

fn sameLetters(letters: [4]u8, other: *const [4]u8) bool {
    for (letters, other) |a, b| {
        if (a != b) return false;
    }
    return true;
}

/// One table's line; `below` for one the fixed description points at,
/// which is set in by a column.
fn printTable(dl: *DosBase, table: usize, below: bool) void {
    const header = acpi.headerOf(table);
    var signature: [8:0]u8 = @splat(0);
    firstColumn(&signature, header.signature, below);
    var maker: [6:0]u8 = @splat(0);
    printable(&maker, &header.oem);
    var its_name: [8:0]u8 = @splat(0);
    printable(&its_name, &header.oem_table);
    _ = Printf(dl, "%s %3u  %-6s  %-8s  %9u  0x%016lx  %s\n", .{
        @as([*:0]const u8, &signature),                        @as(u32, header.revision), @as([*:0]const u8, &maker),
        @as([*:0]const u8, &its_name),                         header.length,             @as(u64, table),
        @as([*:0]const u8, if (header.sound) "ok" else "BAD"),
    });
}

/// The control structure's line: its version and length, for it has no
/// maker, no name and no checksum.
fn printFacs(dl: *DosBase, facs: usize) void {
    const length = acpi.facsLength(facs);
    if (length == 0) {
        _ = Printf(dl, " FACS  the fixed description points at 0x%lx, where there is none\n", .{@as(u64, facs)});
        return;
    }
    _ = Printf(dl, " FACS  %3u" ++ " " ** 20 ++ "%9u  0x%016lx  -\n", .{
        @as(u32, acpi.facsVersion(facs)), length, @as(u64, facs),
    });
}

/// The first column: the four letters, set in by one where `below`, and
/// padded to six.
fn firstColumn(into: *[8:0]u8, letters: [4]u8, below: bool) void {
    var at: usize = 0;
    if (below) {
        into[at] = ' ';
        at += 1;
    }
    for (letters) |char| {
        into[at] = shown(char);
        at += 1;
    }
    while (at < 6) : (at += 1) into[at] = ' ';
    into[at] = 0;
}

/// `bytes` as text into `into`, which is one longer: a byte that is not
/// a printable character shown as "?", a NUL as a space.
fn printable(into: [*:0]u8, bytes: []const u8) void {
    for (bytes, 0..) |char, at| into[at] = if (char == 0) ' ' else shown(char);
    into[bytes.len] = 0;
}

fn shown(char: u8) u8 {
    return if (char >= 0x20 and char < 0x7F) char else '?';
}

// --- the files -------------------------------------------------------------------------

/// What saving needs at hand: the drawer, the path being made, and how
/// many files were written. Allocated, not on the stack: the path is half
/// a kibibyte.
const Saver = struct {
    sys: *ExecBase,
    dl: *DosBase,
    drawer: [*:0]const u8,
    path: [PATH_ROOM:0]u8,
    saved: u32,

    /// `length` bytes at `at` into the file `name` in the drawer: false,
    /// with the fault said, where it could not be written.
    fn put(saver: *Saver, name: [*:0]const u8, at: usize, length: u32) bool {
        const dl = saver.dl;
        if (!pathOf(saver, name)) {
            _ = dl.PrintFault(dos.ERROR_LINE_TOO_LONG, saver.drawer);
            return false;
        }
        const path: [*:0]const u8 = &saver.path;
        const copy: [*]u8 = @ptrCast(saver.sys.AllocVec(length, exec.MEMF_ANY) orelse {
            _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, path);
            return false;
        });
        defer saver.sys.FreeVec(copy);
        const from: [*]const u8 = @ptrFromInt(at);
        @memcpy(copy[0..length], from[0..length]);
        const file = dl.Open(path, dos.MODE_NEWFILE) orelse {
            _ = dl.PrintFault(dl.IoErr(), path);
            return false;
        };
        const written = dl.Write(file, copy, @intCast(length));
        const closed = dl.Close(file);
        if (written != @as(isize, @intCast(length)) or !closed) {
            _ = dl.PrintFault(dl.IoErr(), path);
            return false;
        }
        saver.saved += 1;
        return true;
    }
};

/// The drawer, then `name` after it, into the saver's path.
fn pathOf(saver: *Saver, name: [*:0]const u8) bool {
    var at: usize = 0;
    while (saver.drawer[at] != 0) : (at += 1) {
        if (at == PATH_ROOM) return false;
        saver.path[at] = saver.drawer[at];
    }
    saver.path[at] = 0;
    return saver.dl.AddPart(&saver.path, name, PATH_ROOM);
}

/// Each table into a file of its own in `drawer`, which is made where it
/// is not there; a table whose checksum does not hold is listed above and
/// not saved.
fn save(sys: *ExecBase, dl: *DosBase, root: *const acpi.Root, drawer: [*:0]const u8) i32 {
    if (!dl.CreateDirs(drawer, true)) {
        _ = dl.PrintFault(dl.IoErr(), drawer);
        return dos.RETURN_FAIL;
    }
    const saver: *Saver = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(Saver), exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }));
    defer sys.FreeVec(saver);
    saver.* = .{ .sys = sys, .dl = dl, .drawer = drawer, .path = @splat(0), .saved = 0 };

    if (!saver.put("RSDP.aml", root.at, root.length)) return dos.RETURN_FAIL;
    const list_name: [*:0]const u8 = if (root.wide) "XSDT.aml" else "RSDT.aml";
    if (!saver.put(list_name, root.list, acpi.headerOf(root.list).length)) return dos.RETURN_FAIL;
    var skipped: u32 = 0;
    var index: u32 = 0;
    while (index < root.count) : (index += 1) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return dos.RETURN_WARN;
        }
        const table = root.table(index);
        if (table == 0) continue;
        const header = acpi.headerOf(table);
        if (!header.sound) {
            skipped += 1;
            continue;
        }
        var name: [names.NAME_ROOM:0]u8 = @splat(0);
        if (!saver.put(names.nameOf(header.signature, names.placeOf(root, index), &name), table, header.length)) return dos.RETURN_FAIL;
        if (!isFixed(table)) continue;
        const dsdt = acpi.dsdtOf(table);
        if (dsdt != 0) {
            const dsdt_header = acpi.headerOf(dsdt);
            if (dsdt_header.sound) {
                if (!saver.put("DSDT.aml", dsdt, dsdt_header.length)) return dos.RETURN_FAIL;
            } else skipped += 1;
        }
        const facs = acpi.facsOf(table);
        const facs_length = acpi.facsLength(facs);
        if (facs_length != 0 and !saver.put("FACS.aml", facs, facs_length)) return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "%u files saved into %s\n", .{ saver.saved, drawer });
    if (skipped != 0) {
        _ = Printf(dl, "%u tables not saved: their checksums do not hold\n", .{skipped});
        return dos.RETURN_WARN;
    }
    return dos.RETURN_OK;
}

// --- the address ----------------------------------------------------------------------

/// An address as typed: hexadecimal after "0x" or "$", decimal otherwise.
/// Null where it is not a number or does not fit.
fn numberOf(text: [*:0]const u8) ?usize {
    var at: usize = 0;
    var base: usize = 10;
    if (text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        base = 16;
        at = 2;
    } else if (text[0] == '$') {
        base = 16;
        at = 1;
    }
    if (text[at] == 0) return null;
    var value: usize = 0;
    while (text[at] != 0) : (at += 1) {
        const char = text[at];
        const digit: usize = switch (char) {
            '0'...'9' => char - '0',
            'a'...'f' => char - 'a' + 10,
            'A'...'F' => char - 'A' + 10,
            else => return null,
        };
        if (digit >= base) return null;
        const scaled = @mulWithOverflow(value, base);
        if (scaled[1] != 0) return null;
        const sum = @addWithOverflow(scaled[0], digit);
        if (sum[1] != 0) return null;
        value = sum[0];
    }
    return value;
}
