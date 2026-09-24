// SPDX-License-Identifier: MIT
//! Avail: what memory exec has, by kind. Built against the SDK only.
//!
//!   Avail INTERNAL/S,EXTERNAL/S,TOTAL/S,FLUSH/S
//!
//! With one of INTERNAL, EXTERNAL or TOTAL it prints that one number and
//! nothing else, which is what a script wants. FLUSH first asks exec for more
//! memory than there is, which expunges every library, device and font nobody
//! has open.
//!
//! Internal memory is the chip's own SRAM, which a DMA engine addresses
//! and no cache stands in front of; external memory is the PSRAM behind the
//! data cache, which is the bulk of it. The table is exec's own, as the
//! shell used to print it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Avail";
const VERSION_STRING = "\x00$VER: Avail 1.1 (17.9.2026)\r\n";

const template = "INTERNAL/S,EXTERNAL/S,TOTAL/S,FLUSH/S";
const MSG_NOTBOTH = "only one of INTERNAL, EXTERNAL, or TOTAL allowed\n";
const internal = 0;
const external = 1;
const total = 2;
const flush = 3;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    // The largest allocation there could never be: exec frees everything it
    // can while it looks, and then says no.
    if (argv[flush] != 0) _ = sys.AllocMem(0xFFFF_FFFF, exec.MEMF_ANY);

    var asked: u32 = 0;
    var one: u32 = exec.MEMF_ANY;
    if (argv[internal] != 0) {
        asked += 1;
        one = exec.MEMF_INTERNAL;
    }
    if (argv[external] != 0) {
        asked += 1;
        one = exec.MEMF_EXTERNAL;
    }
    if (argv[total] != 0) {
        asked += 1;
        one = exec.MEMF_ANY;
    }
    if (asked > 1) {
        _ = dl.PutStr(MSG_NOTBOTH);
        return dos.RETURN_ERROR;
    }
    if (asked == 1) {
        // One number and nothing else, which is what a script wants.
        _ = Printf(dl, "%d\n", .{sys.AvailMem(one)});
        return dos.RETURN_OK;
    }

    _ = dl.PutStr("Type      Available    In-Use   Maximum   Largest\n");
    // Three lines, the name and the width of the column after it in one
    // literal each (RawDoFmt has no %*d), so all four line up under the
    // heading.
    inline for (.{
        .{ "internal%11d %9d %9d %9d\n", exec.MEMF_INTERNAL },
        .{ "external%11d %9d %9d %9d\n", exec.MEMF_EXTERNAL },
        .{ "total%14d %9d %9d %9d\n", exec.MEMF_ANY },
    }) |row| {
        const available = sys.AvailMem(row[1]);
        const maximum = sys.AvailMem(row[1] | exec.MEMF_TOTAL);
        const largest = sys.AvailMem(row[1] | exec.MEMF_LARGEST);
        _ = Printf(dl, row[0], .{ available, maximum - available, maximum, largest });
    }
    return dos.RETURN_OK;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
