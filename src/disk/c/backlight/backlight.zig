// SPDX-License-Identifier: MIT
//! Backlight: the panel's backlight, and what else the board's IO expander
//! holds. Built against the SDK only.
//!
//!   Backlight [PERCENT/N] [PIN/K/N] [ON/S] [OFF/S] [PINS/S] [ADC/S]
//!
//!   Backlight            the brightness now
//!   Backlight 60         60 per cent
//!   Backlight ON | OFF   full brightness, or dark
//!   Backlight PINS       what each pin reads, and who holds it
//!   Backlight ADC        the expander's analogue input
//!   Backlight PIN 3 ON   drive one pin high (PIN 3 OFF for low)
//!
//! Everything here goes through expander.resource, which owns the part and
//! the shadow of what has been written to it.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const ExpanderBase = sdk.interface.expander.ExpanderBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const expander = sdk.resources.expander;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Backlight";
const VERSION_STRING = "\x00$VER: Backlight 1.0 (17.9.2026)\r\n";

const template = "PERCENT/N,PIN/K/N,ON/S,OFF/S,PINS/S,ADC/S";
const arg_percent = 0;
const arg_pin = 1;
const arg_on = 2;
const arg_off = 3;
const arg_pins = 4;
const arg_adc = 5;

const MSG_NORESOURCE = "No %s - this board has no IO expander\n";
const MSG_BOTH = "only one of ON or OFF allowed\n";
const MSG_RANGE = "a brightness is 0 to 100\n";
const MSG_BADPIN = "a pin is 0 to %d\n";
const MSG_FAILED = "the expander does not answer\n";

/// What a pin is wired to, for the listing: every part of the board with
/// a line on this expander pin, as "gt911 RESET". The board's description
/// says; this program knows no board.
fn printWiring(dl: *DosBase, ub: ?*UtilityBase, eb: ?*ExpansionBase, pin: u32) void {
    const utility = ub orelse return;
    const board = eb orelse return;
    var first = true;
    var part = board.FindBoardPart(null, st.PARTKIND_ANY, st.CHIP_ANY);
    while (part) |it| : (part = board.FindBoardPart(it, st.PARTKIND_ANY, st.CHIP_ANY)) {
        var walk = it.tags;
        while (utility.NextTagItem(&walk)) |item| {
            const role = st.lineName(item.tag) orelse continue;
            const line = expansion.BoardPin.of(item.data);
            if (line.kind != expansion.boardpin.BPIN_EXPANDER or line.number != pin) continue;
            if (!first) _ = dl.PutStr(", ");
            first = false;
            _ = Printf(dl, "%s %s", .{ it.node.name orelse "?", role });
        }
    }
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    if (argv[arg_on] != 0 and argv[arg_off] != 0) {
        _ = dl.PutStr(MSG_BOTH);
        return dos.RETURN_ERROR;
    }

    // A resource is never closed: OpenResource only finds it.
    const base = sys.OpenResource(expander.EXPANDERNAME) orelse {
        _ = Printf(dl, MSG_NORESOURCE, .{expander.EXPANDERNAME});
        return dos.RETURN_FAIL;
    };
    const ex: *ExpanderBase = @ptrCast(@alignCast(base));

    // One pin, rather than the backlight.
    if (argv[arg_pin] != 0) {
        const pin: i32 = numberAt(argv[arg_pin]);
        if (pin < 0 or pin >= expander.PIN_COUNT) {
            _ = Printf(dl, MSG_BADPIN, .{expander.PIN_COUNT - 1});
            return dos.RETURN_ERROR;
        }
        const which: u32 = @intCast(pin);
        if (argv[arg_on] == 0 and argv[arg_off] == 0) {
            const level = ex.GetPin(which);
            if (level < 0) {
                _ = dl.PutStr(MSG_FAILED);
                return dos.RETURN_ERROR;
            }
            _ = Printf(dl, "pin %d is %d\n", .{ which, level });
            return dos.RETURN_OK;
        }
        if (!ex.SetPin(which, argv[arg_on] != 0)) {
            _ = dl.PutStr(MSG_FAILED);
            return dos.RETURN_ERROR;
        }
        return dos.RETURN_OK;
    }

    if (argv[arg_pins] != 0) return showPins(sys, dl, ex);

    if (argv[arg_adc] != 0) {
        const value = ex.ReadADC();
        if (value < 0) {
            _ = dl.PutStr(MSG_FAILED);
            return dos.RETURN_ERROR;
        }
        _ = Printf(dl, "%d\n", .{value});
        return dos.RETURN_OK;
    }

    // The backlight.
    var want: i32 = -1;
    if (argv[arg_on] != 0) want = @intCast(expander.BACKLIGHT_FULL);
    if (argv[arg_off] != 0) want = @intCast(expander.BACKLIGHT_OFF);
    if (argv[arg_percent] != 0) want = numberAt(argv[arg_percent]);
    if (want < 0) {
        if (argv[arg_percent] != 0) {
            _ = dl.PutStr(MSG_RANGE);
            return dos.RETURN_ERROR;
        }
        _ = Printf(dl, "%d\n", .{ex.Backlight()});
        return dos.RETURN_OK;
    }
    if (want > expander.BACKLIGHT_FULL) {
        _ = dl.PutStr(MSG_RANGE);
        return dos.RETURN_ERROR;
    }
    if (!ex.SetBacklight(@intCast(want))) {
        _ = dl.PutStr(MSG_FAILED);
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

fn showPins(sys: *ExecBase, dl: *DosBase, ex: *ExpanderBase) i32 {
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1);
    defer if (utility_lib) |lib| sys.CloseLibrary(lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1);
    defer if (expansion_lib) |lib| sys.CloseLibrary(lib);
    const ub: ?*UtilityBase = if (utility_lib) |lib| @ptrCast(lib) else null;
    const eb: ?*ExpansionBase = if (expansion_lib) |lib| @ptrCast(lib) else null;

    _ = dl.PutStr("Pin  Level  Held by            Wired to\n");
    _ = dl.PutStr("---  -----  -----------------  ----------------------\n");
    var pin: u32 = 0;
    while (pin < expander.PIN_COUNT) : (pin += 1) {
        const level = ex.GetPin(pin);
        const owner = ex.PinOwner(pin) orelse "-";
        if (level < 0) {
            _ = Printf(dl, "%3d      ?  %-17s  ", .{ pin, owner });
        } else {
            _ = Printf(dl, "%3d  %5d  %-17s  ", .{ pin, level, owner });
        }
        printWiring(dl, ub, eb, pin);
        _ = dl.PutStr("\n");
    }
    _ = Printf(dl, "\nbacklight %d per cent\n", .{ex.Backlight()});
    return dos.RETURN_OK;
}

/// A /N slot: ReadArgs leaves a pointer to the number.
fn numberAt(slot: usize) i32 {
    const p: *const i32 = @ptrFromInt(slot);
    return p.*;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
