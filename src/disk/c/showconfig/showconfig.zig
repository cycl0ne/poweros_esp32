// SPDX-License-Identifier: MIT
//! ShowConfig: the board this machine is, and every part soldered on it,
//! as expansion.library hands them out. Built against the SDK only.
//!
//!   ShowConfig
//!
//! First the board's own facts - its name, its flash and PSRAM, where its
//! console is - then a line per part: which one of its kind, the kind, the
//! chip, the bus it is reached over with the bus's unit and the address on
//! it, and every line the part has, each as the pad or expander pin it is
//! wired to. What is printed is the board's description, read the way any
//! module reads it, so what a driver will find is what is shown here.
//!
//! Last, a table of every pad the chip has and who holds it, as
//! gpio.resource keeps the list - the system's own and each driver's that
//! has come up - with `<not used>` for a free one.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const pins = expansion.boardpin;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "ShowConfig";
const VERSION_STRING = "\x00$VER: ShowConfig 1.3 (24.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "";

const MSG_NOLIBRARY = "%s: no %s\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, sdk.interface.utility.NAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(utility_lib);
    const ub: *UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, expansion.EXPANSIONNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);

    const root = eb.SystemTags();
    const name: [*:0]const u8 = @ptrFromInt(ub.GetTagData(st.SYSTAG_Name, @intFromPtr("(no name)"), root));
    _ = Printf(dl, "board    %s\n", .{name});
    _ = Printf(dl, "flash    %d MiB, the disk from %d KiB\n", .{
        @as(u32, @truncate(ub.GetTagData(st.SYSTAG_FlashSize, 0, root) >> 20)),
        @as(u32, @truncate(ub.GetTagData(st.SYSTAG_DiskOffset, 0, root) >> 10)),
    });
    const psram: u32 = @truncate(ub.GetTagData(st.SYSTAG_PsramSize, 0, root) >> 20);
    if (psram != 0) {
        _ = Printf(dl, "psram    %d MiB, %s\n", .{ psram, psramMode(ub.GetTagData(st.SYSTAG_PsramMode, st.PSRAM_NONE, root)) });
    } else {
        _ = dl.PutStr("psram    none\n");
    }
    _ = Printf(dl, "console  %s\n", .{console(ub.GetTagData(st.SYSTAG_Console, st.CONSOLE_UART0, root))});

    _ = dl.PutStr("\nunit  kind       chip          bus        address     lines\n");
    var part = eb.FindBoardPart(null, st.PARTKIND_ANY, st.CHIP_ANY);
    while (part) |it| : (part = eb.FindBoardPart(it, st.PARTKIND_ANY, st.CHIP_ANY)) {
        const tags = it.tags;
        const bus: u32 = @truncate(ub.GetTagData(st.PART_Bus, st.BUS_NONE, tags));
        _ = Printf(dl, "%-4d  %-9s  %-12s  ", .{ it.unit, kindName(it.kind), it.node.name orelse "-" });
        if (bus == st.BUS_NONE) {
            _ = dl.PutStr("-          ");
        } else {
            _ = Printf(dl, "%-6s %-2d  ", .{ busName(bus), @as(u32, @truncate(ub.GetTagData(st.PART_BusUnit, 0, tags))) });
        }
        if (ub.FindTagItem(st.PART_Address, tags)) |address| {
            _ = Printf(dl, "0x%-8x  ", .{@as(u32, @truncate(address.data))});
        } else {
            _ = dl.PutStr("-           ");
        }
        printLines(dl, ub, tags);
        _ = dl.PutStr("\n");
    }
    printHolders(sys, dl);
    return dos.RETURN_OK;
}

/// Every pad that is held, and by whom. Nothing on a machine without
/// gpio.resource.
fn printHolders(sys: *ExecBase, dl: *DosBase) void {
    const gpio = sdk.resources.gpio;
    const found = sys.OpenResource(gpio.GPIONAME) orelse return;
    const gb: *gpio.GpioBase = @ptrCast(@alignCast(found));

    // The pads the chip has, in order, read down the columns.
    var pads: [gpio.GPIO_PADS]u8 = undefined;
    var count: u32 = 0;
    var pad: u32 = 0;
    while (pad < gpio.GPIO_PADS) : (pad += 1) {
        if (!gpio.padExists(pad)) continue;
        pads[count] = @intCast(pad);
        count += 1;
    }
    const rows = (count + pad_columns - 1) / pad_columns;

    _ = dl.PutStr("\nThe chip's GPIO pins (GPIO0-GPIO48) and which driver has taken\n");
    _ = dl.PutStr("each one.\n\n");
    for (0..pad_columns) |column| {
        if (column != 0) _ = dl.PutStr("  ");
        _ = dl.PutStr("pin held by       ");
    }
    _ = dl.PutStr("\n");
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var column: u32 = 0;
        while (column < pad_columns) : (column += 1) {
            const at = column * rows + row;
            if (at >= count) break;
            if (column != 0) _ = dl.PutStr("  ");
            const holder = gb.GPIOOwner(pads[at]) orelse "<not used>";
            _ = Printf(dl, "%3d %-14s", .{ @as(u32, pads[at]), holder });
        }
        _ = dl.PutStr("\n");
    }
}

/// How many columns the pad table has: three fit a 60-character line.
const pad_columns = 3;

/// Every line a part's tags name, as ROLE=GPIO5, ROLE=EXP1, a trailing
/// "~" for one asserted low.
fn printLines(dl: *DosBase, ub: *UtilityBase, tags: ?[*]const utility.TagItem) void {
    var walk = tags;
    var first = true;
    while (ub.NextTagItem(&walk)) |item| {
        const role = st.lineName(item.tag) orelse continue;
        const pin = expansion.BoardPin.of(item.data);
        if (!pin.wired()) continue;
        if (!first) _ = dl.PutStr(" ");
        first = false;
        const where: [*:0]const u8 = switch (pin.kind) {
            pins.BPIN_GPIO => "GPIO",
            pins.BPIN_EXPANDER => "EXP",
            else => "OWN",
        };
        _ = Printf(dl, "%s=%s%d%s", .{ role, where, @as(u32, pin.number), if (pin.active_low != 0) "~" else "" });
    }
    if (first) _ = dl.PutStr("-");
}

fn kindName(kind: u32) [*:0]const u8 {
    return switch (kind) {
        st.PARTKIND_I2CBUS => "i2c bus",
        st.PARTKIND_SDSLOT => "card slot",
        st.PARTKIND_TOUCH => "touch",
        st.PARTKIND_CODEC => "codec",
        st.PARTKIND_AMPLIFIER => "amplifier",
        st.PARTKIND_EXPANDER => "expander",
        st.PARTKIND_PANEL => "panel",
        st.PARTKIND_LED => "led",
        st.PARTKIND_BATTERY => "battery",
        st.PARTKIND_KEYBOARD => "keyboard",
        st.PARTKIND_MOUSE => "mouse",
        else => "?",
    };
}

fn busName(bus: u32) [*:0]const u8 {
    return switch (bus) {
        st.BUS_I2C => "i2c",
        st.BUS_SPI => "spi",
        st.BUS_I2S => "i2s",
        st.BUS_SDIO => "sdio",
        st.BUS_RMT => "rmt",
        st.BUS_ADC => "adc",
        st.BUS_LCD => "lcd",
        st.BUS_MEMORY => "memory",
        else => "?",
    };
}

fn psramMode(mode: usize) [*:0]const u8 {
    return switch (mode) {
        st.PSRAM_QUAD => "quad",
        st.PSRAM_OCTAL => "octal",
        else => "?",
    };
}

fn console(which: usize) [*:0]const u8 {
    return switch (which) {
        st.CONSOLE_USBJTAG => "the USB port",
        st.CONSOLE_UART0 => "UART0",
        else => "?",
    };
}
