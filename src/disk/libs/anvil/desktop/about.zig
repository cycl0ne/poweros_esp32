// SPDX-License-Identifier: MIT
//! About: the desktop's version, and what it runs on - the system's
//! release, the board, the processor, the memory, all of it and how much
//! is free, and the screen. Each is asked of the running system when the
//! requester comes up, so it is the machine's now and not what the
//! desktop was built for; one the system cannot answer is left out.

const sdk = @import("sdk");
const exec = sdk.exec;
const intuition = sdk.intuition;
const utility = sdk.utility;
const platform = sdk.resources.platform;
const sc = intuition.screens;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const PlatformBase = sdk.interface.platform.PlatformBase;
const TagItem = utility.TagItem;
const anvil_init = @import("../anvil_init.zig");
const drawer_path = @import("../drawer/path.zig");
const _desktop = @import("_desktop.zig");
const Desktop = _desktop.Desktop;

/// The most cores counted.
const max_cores = 8;

/// The requester's text as it is put together: NUL after it, since the
/// buffer starts cleared and is never filled to its end.
const Text = struct {
    buffer: [640:0]u8 = @splat(0),
    length: usize = 0,

    fn add(text: *Text, part: []const u8) void {
        const take = @min(part.len, text.buffer.len - text.length);
        @memcpy(text.buffer[text.length..][0..take], part[0..take]);
        text.length += take;
    }

    fn addString(text: *Text, part: [*:0]const u8) void {
        var length: usize = 0;
        while (part[length] != 0) length += 1;
        text.add(part[0..length]);
    }

    /// A count or a size in pixels: its digits alone, no commas.
    fn number(text: *Text, value: u64) void {
        var digits: [20]u8 = undefined;
        var count: usize = 0;
        var left = value;
        while (true) {
            digits[digits.len - 1 - count] = '0' + @as(u8, @intCast(left % 10));
            count += 1;
            left /= 10;
            if (left == 0) break;
        }
        text.add(digits[digits.len - count ..]);
    }

    fn amount(text: *Text, bytes: u64) void {
        var digits: [32]u8 = undefined;
        text.add(digits[0..drawer_path.amount(&digits, bytes)]);
    }
};

/// About's requester, over the desktop's own window.
pub fn show(d: *Desktop) void {
    var text: Text = .{};
    text.add("Anvil ");
    text.add(anvil_init.VERSION_TEXT);
    text.add("\nThe PowerOS desktop\n");
    if (d.sys.FindResident(sdk.release.RELEASE_RESIDENT)) |tag| {
        if (tag.id_string) |id| {
            text.add("\n");
            text.addString(id);
        }
    }
    board(d, &text);
    processor(d, &text);
    memory(d, &text);
    screen(d, &text);
    const easy = intuition.requesters.EasyStruct{
        .title = "About Anvil",
        .text_format = "%s",
        .gadget_format = "OK",
    };
    const args = [_]usize{@intFromPtr(&text.buffer)};
    _ = d.ib.EasyRequestArgs(d.backdrop, &easy, null, &args);
}

/// "Board: <name>", as the board's system tag list names it.
fn board(d: *Desktop, text: *Text) void {
    const library = d.sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return;
    defer d.sys.CloseLibrary(library);
    const eb: *ExpansionBase = @ptrCast(library);
    const name = d.ub.GetTagData(sdk.expansion.systemtags.SYSTAG_Name, 0, eb.SystemTags());
    if (name == 0) return;
    text.add("\nBoard: ");
    text.addString(@ptrFromInt(name));
}

/// "Processor: ESP32-S3, 2 Xtensa LX7 cores at 240 MHz": the chip and its
/// core as platform.resource names them, the cores exec keeps times for,
/// and the clock as measured.
fn processor(d: *Desktop, text: *Text) void {
    const resource = d.sys.OpenResource(platform.PLATFORMNAME) orelse return;
    const pr: *PlatformBase = @ptrCast(@alignCast(resource));
    var info: platform.PlatformInfo = .{};
    _ = pr.GetPlatformInfo(&info, @sizeOf(platform.PlatformInfo));
    var cores: u32 = 0;
    var times: exec.CoreTimes = .{};
    while (cores < max_cores and d.sys.ReadCoreTimes(cores, &times)) cores += 1;
    text.add("\nProcessor: ");
    text.addString(pr.PlatformName());
    if (info.core) |core| {
        text.add(", ");
        if (cores > 0) {
            text.number(cores);
            text.add(" ");
        }
        text.addString(core);
        text.add(if (cores > 1) " cores" else " core");
    }
    text.add(" at ");
    text.number(pr.CpuClock() / 1_000_000);
    text.add(" MHz");
}

/// "Memory: 8,703K, 5,685K free" - all there is, and how much of it is
/// free - then the internal memory and the PSRAM apart, the PSRAM only
/// where the board has some. On a machine whose RAM is one kind
/// (`Desktop.unified`) every region is both, so the line of all of it is
/// the whole story.
fn memory(d: *Desktop, text: *Text) void {
    if (d.unified) {
        text.add("\nMemory: ");
        text.amount(d.sys.AvailMem(exec.MEMF_ANY | exec.MEMF_TOTAL));
        text.add(", ");
        text.amount(d.sys.AvailMem(exec.MEMF_ANY));
        text.add(" free");
        return;
    }
    const internal_total = d.sys.AvailMem(exec.MEMF_INTERNAL | exec.MEMF_TOTAL);
    const internal_free = d.sys.AvailMem(exec.MEMF_INTERNAL);
    const external_total = d.sys.AvailMem(exec.MEMF_EXTERNAL | exec.MEMF_TOTAL);
    const external_free = d.sys.AvailMem(exec.MEMF_EXTERNAL);
    text.add("\nMemory: ");
    text.amount(internal_total + external_total);
    text.add(", ");
    text.amount(internal_free + external_free);
    text.add(" free\nInternal ");
    text.amount(internal_total);
    text.add(", ");
    text.amount(internal_free);
    text.add(" free");
    if (external_total != 0) {
        text.add("; PSRAM ");
        text.amount(external_total);
        text.add(", ");
        text.amount(external_free);
        text.add(" free");
    }
}

/// "Screen: 1024 x 600, 16 bits a pixel": the desktop's screen.
fn screen(d: *Desktop, text: *Text) void {
    const shown = d.screen orelse return;
    var depth: usize = 0;
    d.ib.GetScreenAttrs(shown, &[_]TagItem{ .{ .tag = sc.SA_Depth, .data = @intFromPtr(&depth) }, .{} });
    text.add("\nScreen: ");
    text.number(@intCast(d.screen_width));
    text.add(" x ");
    text.number(@intCast(d.screen_height));
    if (depth != 0) {
        text.add(", ");
        text.number(depth);
        text.add(" bits a pixel");
    }
}
