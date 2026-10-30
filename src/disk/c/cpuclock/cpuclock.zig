// SPDX-License-Identifier: MIT
//! CpuClock: the cores' clock on a Compute Module 5, as the VideoCore's
//! firmware has it now - the rate it set them to, the rate it measures,
//! the most it allows - the V3D's the same, the chip's temperature, and what
//! holds the cores back, now and since the machine started. Built against the
//! SDK only.
//!
//!   CpuClock
//!
//! The kernel measures the clock once, as it starts (`Platform CLOCK`).
//! The firmware lowers it while the supply sags or the chip is too hot,
//! and raises it again once that is over - a weak supply swapped for a
//! strong one, say - so this asks it now.
//!
//! The firmware is asked through its mailbox, which the board names as
//! its RTC's address (CHIP_RPI_RTC): the RTC is read through it too. On a
//! board with none - any but a CM5 - it says so, and returns WARN, so a
//! script can ask `If WARN`.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const videocore = sdk.hardware.videocore;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const st_expansion = sdk.expansion;
const st = st_expansion.systemtags;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "CpuClock";
const VERSION_STRING = "\x00$VER: CpuClock 1.1 (30.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "";

const TAG_GET_CLOCK_RATE: u32 = 0x0003_0002;
const TAG_GET_MAX_CLOCK_RATE: u32 = 0x0003_0004;
const TAG_GET_TEMPERATURE: u32 = 0x0003_0006;
const TAG_GET_THROTTLED: u32 = 0x0003_0046;
const TAG_GET_CLOCK_RATE_MEASURED: u32 = 0x0003_0047;
/// The firmware's number for the cores' clock.
const CLOCK_ARM: u32 = 3;
const CLOCK_V3D: u32 = 5;

/// What GET_THROTTLED says holds the cores back, a bit each, in its low
/// 16 bits for now and the same 16 bits up for since the start.
const reasons = [_]struct { bit: u32, name: [*:0]const u8 }{
    .{ .bit = 1 << 0, .name = "the supply is too low (under-voltage)" },
    .{ .bit = 1 << 1, .name = "the clock is capped" },
    .{ .bit = 1 << 2, .name = "the cores are throttled" },
    .{ .bit = 1 << 3, .name = "the chip is at its soft temperature limit" },
};
const SINCE_START = 16;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const mailbox = mailboxOf(sys) orelse {
        _ = Printf(dl, "This is not a Compute Module 5\n", .{});
        return dos.RETURN_WARN;
    };
    const bytes = 2 * videocore.buffer_bytes;
    const memory = sys.AllocMem(bytes, exec.MEMF_DMA) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeMem(memory, bytes);
    const buffer = videocore.bufferIn(memory) orelse return dos.RETURN_FAIL;

    var set = [_]u32{ CLOCK_ARM, 0 };
    var measured = [_]u32{ CLOCK_ARM, 0 };
    var most = [_]u32{ CLOCK_ARM, 0 };
    if (!videocore.call(sys, mailbox, buffer, TAG_GET_CLOCK_RATE, &set) or
        !videocore.call(sys, mailbox, buffer, TAG_GET_CLOCK_RATE_MEASURED, &measured) or
        !videocore.call(sys, mailbox, buffer, TAG_GET_MAX_CLOCK_RATE, &most))
    {
        _ = Printf(dl, "The firmware does not answer\n", .{});
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "clock        %lu MHz (set to %lu, at most %lu)\n", .{
        @as(u64, (measured[1] + 500_000) / 1_000_000), @as(u64, set[1] / 1_000_000), @as(u64, most[1] / 1_000_000),
    });
    var v3d_set = [_]u32{ CLOCK_V3D, 0 };
    var v3d_measured = [_]u32{ CLOCK_V3D, 0 };
    var v3d_most = [_]u32{ CLOCK_V3D, 0 };
    if (videocore.call(sys, mailbox, buffer, TAG_GET_CLOCK_RATE, &v3d_set) and
        videocore.call(sys, mailbox, buffer, TAG_GET_CLOCK_RATE_MEASURED, &v3d_measured) and
        videocore.call(sys, mailbox, buffer, TAG_GET_MAX_CLOCK_RATE, &v3d_most))
    {
        _ = Printf(dl, "V3D          %lu MHz (set to %lu, at most %lu)\n", .{
            @as(u64, (v3d_measured[1] + 500_000) / 1_000_000), @as(u64, v3d_set[1] / 1_000_000), @as(u64, v3d_most[1] / 1_000_000),
        });
    }
    var temperature = [_]u32{ 0, 0 };
    if (videocore.call(sys, mailbox, buffer, TAG_GET_TEMPERATURE, &temperature)) {
        const tenths = (temperature[1] + 50) / 100;
        _ = Printf(dl, "temperature  %lu.%lu \xB0C\n", .{ @as(u64, tenths / 10), @as(u64, tenths % 10) });
    }
    var held = [_]u32{0};
    if (videocore.call(sys, mailbox, buffer, TAG_GET_THROTTLED, &held)) {
        showHeld(dl, "now          ", held[0]);
        showHeld(dl, "since start  ", held[0] >> SINCE_START);
    }
    return dos.RETURN_OK;
}

/// The firmware's mailbox, as the board's RTC part names it; null on a
/// board without one.
fn mailboxOf(sys: *ExecBase) ?usize {
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    defer sys.CloseLibrary(utility_lib);
    const utility: *UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(st_expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_RTC, st.CHIP_RPI_RTC) orelse return null;
    const address = utility.GetTagData(st.PART_Address, 0, part.tags);
    return if (address != 0) address else null;
}

/// A line of what `flags` says holds the cores back - each reason on a
/// line of its own - or that nothing does.
fn showHeld(dl: *DosBase, label: [*:0]const u8, flags: u32) void {
    var any = false;
    for (reasons) |reason| {
        if (flags & reason.bit == 0) continue;
        _ = Printf(dl, "%s%s\n", .{ if (any) @as([*:0]const u8, "             ") else label, reason.name });
        any = true;
    }
    if (!any) _ = Printf(dl, "%snothing holds the cores back\n", .{label});
}
