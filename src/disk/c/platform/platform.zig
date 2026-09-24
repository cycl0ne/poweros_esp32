// SPDX-License-Identifier: MIT
//! Platform: what machine this is - the chip, its clocks, where the code
//! and the stacks are, and whether there is PSRAM. Built against the SDK
//! only.
//!
//!   Platform CHIP/S,CLOCK/S,TICK/S
//!
//! With no switch it prints the table the `s3>` shell's `info` prints, and
//! from the same place: both ask platform.resource, so there is one source
//! of truth and not two.
//!
//! One of CHIP, CLOCK or TICK prints that one value and nothing else, which
//! is what a script wants - Avail's rule, and for the same reason:
//!
//!   Platform CHIP    ESP32-S3
//!   Platform CLOCK   the CPU clock in Hz, as the system measured it
//!   Platform TICK    the kernel tick in Hz
//!
//! It has no cache or MMU switches: exec has CacheClearU and CacheClearE and
//! no CacheControl, so there is nothing to set. Its facts come from
//! platform.resource because ExecBase is opaque and these are the kernel's
//! facts, not exec's. See
//! docs/platform.md.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const PlatformBase = sdk.interface.platform.PlatformBase;
const platform = sdk.resources.platform;
const PlatformInfo = platform.PlatformInfo;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Platform";
const VERSION_STRING = "\x00$VER: Platform 1.2 (24.09.2026)\r\n";

const template = "CHIP/S,CLOCK/S,TICK/S";
const arg_chip = 0;
const arg_clock = 1;
const arg_tick = 2;

const MSG_NORESOURCE = "No %s - this is not a PowerOS machine\n";
const MSG_NOTBOTH = "only one of CHIP, CLOCK, or TICK allowed\n";

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

    // A resource is never closed: OpenResource only finds it.
    const base = sys.OpenResource(platform.PLATFORMNAME) orelse {
        _ = Printf(dl, MSG_NORESOURCE, .{platform.PLATFORMNAME});
        return dos.RETURN_FAIL;
    };
    const pr: *PlatformBase = @ptrCast(@alignCast(base));

    var asked: u32 = 0;
    if (argv[arg_chip] != 0) asked += 1;
    if (argv[arg_clock] != 0) asked += 1;
    if (argv[arg_tick] != 0) asked += 1;
    if (asked > 1) {
        _ = dl.PutStr(MSG_NOTBOTH);
        return dos.RETURN_ERROR;
    }
    if (asked == 1) {
        // One value and nothing else, which is what a script wants.
        if (argv[arg_chip] != 0) {
            _ = Printf(dl, "%s\n", .{pr.PlatformName()});
        } else if (argv[arg_clock] != 0) {
            _ = Printf(dl, "%d\n", .{pr.CpuClock()});
        } else {
            _ = Printf(dl, "%d\n", .{pr.TickRate()});
        }
        return dos.RETURN_OK;
    }

    // The whole table. A program on the disk may be older or newer than the
    // ROM answering it, so nothing is printed that the answer did not
    // reach.
    var p: PlatformInfo = .{};
    const got = pr.GetPlatformInfo(&p, @sizeOf(PlatformInfo));
    if (got == 0) {
        _ = Printf(dl, MSG_NORESOURCE, .{platform.PLATFORMNAME});
        return dos.RETURN_FAIL;
    }

    // The release is the running system's, asked for rather than built in:
    // this program may be older or newer than the ROM.
    if (sys.FindResident(sdk.release.RELEASE_RESIDENT)) |tag| {
        if (tag.id_string) |id| _ = Printf(dl, "release  %s\n", .{id});
    }
    printBoard(sys, dl);
    if (has(got, "prid")) {
        _ = Printf(dl, "chip     %s, %s, PRID 0x%04x\n", .{ text(p.chip), text(p.core), p.prid & 0xFFFF });
    }
    if (has(got, "tick_irq")) {
        _ = Printf(dl, "clock    %d MHz CPU (configured %d, measured %d), %d Hz tick on CCOMPARE0 (irq %d)\n", .{
            pr.CpuClock() / 1_000_000,
            p.cpu_hz / 1_000_000,
            p.measured_cpu_hz / 1_000_000,
            p.tick_hz,
            p.tick_irq,
        });
        _ = Printf(dl, "crystal  %d MHz, pll calibrated: %s\n", .{
            p.xtal_hz / 1_000_000,
            if (p.pll_calibrated != 0) "yes" else "no",
        });
    }
    if (has(got, "vecbase")) _ = Printf(dl, "vecbase  0x%08x\n", .{p.vecbase});
    if (has(got, "stack_upper")) {
        _ = Printf(dl, "iram     0x%08x-0x%08x  %d bytes code\n", .{ p.iram_lower, p.iram_upper, p.iram_upper - p.iram_lower });
        _ = Printf(dl, "dram     0x%08x-0x%08x  %d bytes data+bss\n", .{ p.dram_lower, p.dram_upper, p.dram_upper - p.dram_lower });
        _ = Printf(dl, "flash    0x%08x-0x%08x  %d KiB code\n", .{
            p.flash_text_lower,
            p.flash_text_upper,
            (p.flash_text_upper - p.flash_text_lower) / 1024,
        });
        _ = Printf(dl, "stack    0x%08x-0x%08x  (the boot task's)\n", .{ p.stack_lower, p.stack_upper });
    }
    _ = Printf(dl, "ram      internal %d KiB free, external %d KiB free (see Avail)\n", .{
        sys.AvailMem(exec.MEMF_INTERNAL) / 1024,
        sys.AvailMem(exec.MEMF_EXTERNAL) / 1024,
    });
    if (has(got, "psram_vendor") and p.psram_size != 0) {
        _ = Printf(dl, "psram    0x%08x-0x%08x  %d MiB octal, vendor 0x%02x\n", .{
            p.psram_base,
            p.psram_base + p.psram_size,
            p.psram_size >> 20,
            p.psram_vendor,
        });
    }
    if (has(got, "built")) _ = Printf(dl, "built    %s\n", .{text(p.built)});
    return dos.RETURN_OK;
}

/// Whether the answer reached far enough to hold a field. The ROM says how
/// many bytes it wrote; a field is there when its last byte is inside them.
fn has(got: u32, comptime field: []const u8) bool {
    const end = @offsetOf(PlatformInfo, field) + @sizeOf(@FieldType(PlatformInfo, field));
    return got >= end;
}

/// The board's name, from its system tag list: the board is
/// expansion.library's to say, the chip is platform.resource's. Nothing is
/// printed on a machine without it.
fn printBoard(sys: *ExecBase, dl: *DosBase) void {
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys.CloseLibrary(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const name = ub.GetTagData(sdk.expansion.systemtags.SYSTAG_Name, 0, eb.SystemTags());
    if (name == 0) return;
    _ = Printf(dl, "board    %s\n", .{@as([*:0]const u8, @ptrFromInt(name))});
}

/// A string the ROM may have left null.
fn text(s: ?[*:0]const u8) [*:0]const u8 {
    return s orelse "?";
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
