// SPDX-License-Identifier: MIT
//! Rtg: what displays this machine has, and what drives them. Built
//! against the SDK only.
//!
//!   Rtg BOARD,DRIVERS/S,DEVICES/S,BOARDS/S,MODES/S,MEMORY/S,STATS/S,FULL/S,
//!       SET/S,CLEAR/S,MODE/K,MIRROR/K,BRIGHTNESS/K/N,RANGE/K,FIRST/K,
//!       DEVICE/K,DRIVER/K,SAVE/S,RETRY/S,TRIED/S
//!
//! With nothing asked for it prints the three lists: the display drivers
//! on rtg.library's list, the devices the machine has for them - a panel
//! of the board, a display function on PCI - each with the driver that
//! took it, and the boards the drivers made. Name a board and it prints
//! that board in full - what it is, what is on its connector and the
//! sound it plays, what it can be asked to do, the modes it has, what its display memory has been cut
//! into and, for a display that refreshes itself, how the stream is
//! doing.
//!
//! A board is named after the driver that made it and a number, in the
//! order that driver made its boards: `rgb.0` an RGB panel the chip
//! scans itself, `dcs.0` a panel that keeps its own picture and takes it
//! over a command bus, `dsi.0` a panel on a MIPI-DSI link, `qemu.0`
//! Espressif QEMU's display, `fw.0` the picture a PC's UEFI firmware lit
//! or QEMU's ramfb, `virtio.0` QEMU's virtio GPU, `bcm2711.0` and
//! `bcm2712.0` the first HDMI port of a Raspberry Pi 4 or Compute Module
//! 4 and of a Compute Module 5, `jh7110.0` the VisionFive 2's HDMI port,
//! and `amd.0` the connector an AMD display's firmware lit. A device is
//! named by where it is: a panel of the board by its number among the
//! panels (`panel.0`), a display function on PCI by its bus, device and
//! function (`pci.65:00.0`).
//!
//! The switches pick sections rather than repeat the name: MODES, MEMORY
//! and STATS each print that one section, for the board named or for every
//! board; DRIVERS, DEVICES and BOARDS print one list alone, which is what
//! a script wants; FULL prints every section of every board.
//!
//! SET changes the settings (`display.prefs`) as rtg.library holds them.
//! With a board it changes that board's line for the monitor on it now:
//! CLEAR takes the line away first, and each of MODE (WIDTHxHEIGHT or
//! WIDTHxHEIGHT@HZ, the mode the board comes up in), MIRROR (X, Y, XY or
//! NONE), BRIGHTNESS (0 to 100), RANGE (FULL or LIMITED) and FIRST (YES
//! or NO) changes that one key and leaves the others. Mirror, brightness,
//! range and which board is first are in force at once; the mode with the
//! display's next first screen. With DEVICE and DRIVER (ON or OFF) it
//! says whether a driver from the disk is bound to that device from the
//! next start on. SAVE writes the settings to ENV:Sys/display.prefs and
//! ENVARC:Sys/display.prefs, after a SET on the same line; without it a
//! change lasts until the machine restarts.
//!
//!   Rtg amd.0 SET MODE=1920x1080@60 FIRST=YES SAVE
//!   Rtg SET DEVICE=pci.01:00.0 DRIVER=OFF SAVE
//!
//! ENVARC:Sys/display.trying names the display drivers that are being
//! loaded from DEVS:gfxdrv: rtg.library writes a driver's name there
//! before it loads it, and passes over a driver it finds named. TRIED
//! says the drivers came back: once every board says what it began in
//! the background as it was made has ended (RTGCTRL_SETTLED), the name of
//! every driver that is on the list leaves the file, and a name that
//! stays is a driver that hung the machine. The startup-sequence runs it
//! once the desktop is up. RETRY deletes the file, loads the drivers
//! again and then does what TRIED does.
//!
//! Everything it prints comes from GetBoardInfo and GetBoardStats, which
//! answer with the bytes they wrote, so a command older or newer than the
//! ROM prints what the answer reached and no more. See sdk/docs/guides/rtg.md.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const rtg = sdk.rtg;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Rtg";
const VERSION_STRING = "\x00$VER: Rtg 1.15 (26.11.2026)\r\n";

const template = "BOARD,DRIVERS/S,DEVICES/S,BOARDS/S,MODES/S,MEMORY/S,STATS/S,FULL/S," ++
    "SET/S,CLEAR/S,MODE/K,MIRROR/K,BRIGHTNESS/K/N,RANGE/K,FIRST/K,DEVICE/K,DRIVER/K,SAVE/S,RETRY/S,TRIED/S";
const arg_board = 0;
const arg_drivers = 1;
const arg_devices = 2;
const arg_boards = 3;
const arg_modes = 4;
const arg_memory = 5;
const arg_stats = 6;
const arg_full = 7;
const arg_set = 8;
const arg_clear = 9;
const arg_mode = 10;
const arg_mirror = 11;
const arg_brightness = 12;
const arg_range = 13;
const arg_first = 14;
const arg_device = 15;
const arg_driver = 16;
const arg_save = 17;
const arg_retry = 18;
const arg_tried = 19;
const arg_count = 20;

const MSG_NOLIBRARY = "No %s - this machine has no display layer\n";
const MSG_NOBOARD = "No board \"%s\"\n";
const MSG_NOBOARDS = "No boards: no display driver found anything to drive\n";
const MSG_NODRIVERS = "No display drivers\n";
const MSG_NODEVICES = "No devices: the machine has no display rtg.library knows of\n";
const MSG_SET_WHAT = "SET needs a board, or DEVICE and DRIVER\n";
const MSG_BAD_MODE = "MODE is WIDTHxHEIGHT or WIDTHxHEIGHT@HZ\n";
const MSG_BAD_MIRROR = "MIRROR is X, Y, XY or NONE\n";
const MSG_BAD_BRIGHTNESS = "BRIGHTNESS is 0 to 100\n";
const MSG_BAD_RANGE = "RANGE is FULL or LIMITED\n";
const MSG_BAD_FIRST = "FIRST is YES or NO\n";
const MSG_BAD_DRIVER = "DRIVER is ON or OFF\n";
const MSG_NOT_SET = "The settings were not changed: %s\n";
const MSG_NOT_SAVED = "%s was not written: %s\n";
const MSG_RETRIED = "%ld board(s) made\n";

/// The file that names the display drivers being tried.
const trying_file = "ENVARC:Sys/display.trying";

/// The most drivers and devices one list prints.
const max_listed = 16;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);

    // The drivers that did not come back tried again; those that came
    // back, here or at the start, no longer named as being tried.
    if (argv[arg_retry] != 0) {
        _ = dl.DeleteFile(trying_file);
        _ = Printf(dl, MSG_RETRIED, .{@as(u64, rb.LoadRtgDrivers())});
        cameBack(dl, rb);
        return dos.RETURN_OK;
    }
    if (argv[arg_tried] != 0) {
        cameBack(dl, rb);
        return dos.RETURN_OK;
    }

    // The settings changed, and written: nothing is printed but what went
    // wrong.
    if (argv[arg_set] != 0 or argv[arg_save] != 0) {
        if (argv[arg_set] != 0) {
            const code = set(dl, rb, &argv);
            if (code != dos.RETURN_OK) return code;
        }
        if (argv[arg_save] != 0) return save(dl, rb);
        return dos.RETURN_OK;
    }

    // FULL is not "all three sections": it is the whole of every board,
    // which is what printBoard prints. A section switch asks for that
    // section and nothing else.
    const full = argv[arg_full] != 0;
    const want_modes = argv[arg_modes] != 0;
    const want_memory = argv[arg_memory] != 0;
    const want_stats = argv[arg_stats] != 0;
    const one_section = !full and (want_modes or want_memory or want_stats);

    // DRIVERS, DEVICES or BOARDS on its own is one list and nothing else.
    const lists = @as(u32, @intFromBool(argv[arg_drivers] != 0)) + @intFromBool(argv[arg_devices] != 0) + @intFromBool(argv[arg_boards] != 0);
    if (lists == 1 and !one_section) {
        if (argv[arg_drivers] != 0) return printDrivers(dl, rb);
        if (argv[arg_devices] != 0) return printDevices(dl, rb);
        return printBoards(dl, rb);
    }

    // A board by name: that one, in as much detail as was asked for.
    if (argv[arg_board] != 0) {
        const wanted: [*:0]const u8 = @ptrFromInt(argv[arg_board]);
        const board = rb.FindBoard(wanted) orelse {
            _ = Printf(dl, MSG_NOBOARD, .{wanted});
            return dos.RETURN_ERROR;
        };
        if (one_section) {
            if (want_modes) printModes(dl, rb, board);
            if (want_memory) printMemory(dl, rb, board);
            if (want_stats) printStats(dl, rb, board);
            return dos.RETURN_OK;
        }
        printBoard(dl, rb, board);
        return dos.RETURN_OK;
    }

    // A section without a board: that section for every board there is,
    // each under the same heading a board's own report starts with.
    if (one_section) {
        var board = rb.NextBoard(null);
        if (board == null) {
            _ = dl.PutStr(MSG_NOBOARDS);
            return dos.RETURN_WARN;
        }
        while (board) |b| : (board = rb.NextBoard(b)) {
            var info: rtg.RtgBoardInfo = .{};
            _ = rb.GetBoardInfo(b, &info, @sizeOf(rtg.RtgBoardInfo));
            _ = Printf(dl, "%-12s %s\n", .{ "Board", name(info.name) });
            if (want_modes) printModes(dl, rb, b);
            if (want_memory) printMemory(dl, rb, b);
            if (want_stats) printStats(dl, rb, b);
        }
        return dos.RETURN_OK;
    }

    // FULL: every board, whole, with a blank line between them.
    if (full) {
        var board = rb.NextBoard(null);
        if (board == null) {
            _ = dl.PutStr(MSG_NOBOARDS);
            return dos.RETURN_WARN;
        }
        var first = true;
        while (board) |b| : (board = rb.NextBoard(b)) {
            if (!first) _ = dl.PutStr("\n");
            first = false;
            printBoard(dl, rb, b);
        }
        return dos.RETURN_OK;
    }

    // Nothing asked for: the three lists.
    _ = printDrivers(dl, rb);
    _ = dl.PutStr("\n");
    _ = printDevices(dl, rb);
    _ = dl.PutStr("\n");
    return printBoards(dl, rb);
}

// --- the lists --------------------------------------------------------------

fn printDrivers(dl: *DosBase, rb: *RtgBase) i32 {
    var found: [max_listed]rtg.RtgDriverInfo = undefined;
    const there = rb.GetRtgDrivers(&found, found.len);
    if (there == 0) {
        _ = dl.PutStr(MSG_NODRIVERS);
        return dos.RETURN_WARN;
    }
    _ = dl.PutStr("Driver          Ver  Kind       Devices  Boards  Buses  Module\n");
    var id: [48]u8 = undefined;
    for (found[0..@min(there, found.len)]) |*driver| {
        _ = Printf(dl, "%-14s  %d.%-2d %-9s  %7d  %6d  %5d  %s\n", .{
            stringOf(&driver.name),
            driver.version,
            driver.revision,
            kindOf(driver.kind),
            driver.devices,
            driver.boards,
            driver.buses,
            idText(&id, stringOf(&driver.id_string)),
        });
    }
    return dos.RETURN_OK;
}

fn printDevices(dl: *DosBase, rb: *RtgBase) i32 {
    var found: [max_listed]rtg.RtgDeviceInfo = undefined;
    const there = rb.GetRtgDevices(&found, found.len);
    if (there == 0) {
        _ = dl.PutStr(MSG_NODEVICES);
        return dos.RETURN_WARN;
    }
    _ = dl.PutStr("Device        What                  Driver    Boards  Notes\n");
    for (found[0..@min(there, found.len)]) |*device| {
        var what: [24]u8 = undefined;
        _ = Printf(dl, "%-12s  %-20s  %-8s  %6d  ", .{
            stringOf(&device.name),
            whatOf(&what, device),
            if (device.driver[0] != 0) stringOf(&device.driver) else "-",
            device.boards,
        });
        var noted = false;
        if (device.flags & rtg.drivers.RTGDVF_FIRMWARE != 0) noted = note(dl, noted, "lit by the firmware");
        if (device.behind[0] != 0) {
            noted = note(dl, noted, "behind ");
            _ = dl.PutStr(stringOf(&device.behind));
        }
        if (device.flags & rtg.drivers.RTGDVF_DRIVER_OFF != 0) _ = note(dl, noted, "drivers from the disk off");
        _ = dl.PutStr("\n");
    }
    return dos.RETURN_OK;
}

/// One of a device's notes, after a comma where one came before. Answers
/// that one has been printed.
fn note(dl: *DosBase, noted: bool, words: [*:0]const u8) bool {
    if (noted) _ = dl.PutStr(", ");
    _ = dl.PutStr(words);
    return true;
}

/// A name `GetRtgDrivers` or `GetRtgDevices` copied out, as a string.
fn stringOf(buffer: []const u8) [*:0]const u8 {
    return @ptrCast(buffer.ptr);
}

/// What a device is, for people: a part's chip name, or a function's
/// vendor and device as PCI writes them ("1af4:1050").
fn whatOf(buffer: *[24]u8, device: *const rtg.RtgDeviceInfo) [*:0]const u8 {
    if (device.kind != rtg.drivers.RTGDEV_PCI) {
        return if (device.chip_name[0] != 0) stringOf(&device.chip_name) else "-";
    }
    const digits = "0123456789abcdef";
    var at: usize = 0;
    for ([_]u32{ device.vendor, device.device }, 0..) |value, which| {
        if (which == 1) {
            buffer[at] = ':';
            at += 1;
        }
        var shift: u5 = 12;
        while (true) : (shift -= 4) {
            buffer[at] = digits[(value >> shift) & 0xF];
            at += 1;
            if (shift == 0) break;
        }
    }
    buffer[at] = 0;
    return @ptrCast(buffer);
}

fn printBoards(dl: *DosBase, rb: *RtgBase) i32 {
    var board = rb.NextBoard(null);
    if (board == null) {
        _ = dl.PutStr(MSG_NOBOARDS);
        return dos.RETURN_WARN;
    }
    _ = dl.PutStr("Board        Driver    Mode               Memory free  Showing\n");
    while (board) |b| : (board = rb.NextBoard(b)) {
        var info: rtg.RtgBoardInfo = .{};
        const got = rb.GetBoardInfo(b, &info, @sizeOf(rtg.RtgBoardInfo));
        if (got == 0) continue;
        const shown = rb.BoardDisplayBitMap(b);
        _ = Printf(dl, "%-11s  %-8s  %4dx%-4d %-8s  %10zd  %s\n", .{
            name(info.name),
            name(info.driver),
            info.width,
            info.height,
            formatName(info.format),
            info.memory_free,
            if (shown != null) "yes" else "no",
        });
    }
    return dos.RETURN_OK;
}

// --- one board --------------------------------------------------------------

fn printBoard(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var info: rtg.RtgBoardInfo = .{};
    const got = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    if (got == 0) {
        _ = Printf(dl, MSG_NOBOARD, .{name(info.name)});
        return;
    }
    _ = Printf(dl, "%-12s %s\n", .{ "Board", name(info.name) });
    var id: [48]u8 = undefined;
    _ = Printf(dl, "%-12s %s (%s)\n", .{ "Driver", name(info.driver), idText(&id, info.id_string) });
    // Its device and what the output is called, where the answer reached
    // that far.
    if (got >= @offsetOf(rtg.RtgBoardInfo, "device") + @sizeOf(?[*:0]const u8)) {
        if (info.device) |device| _ = Printf(dl, "%-12s %s\n", .{ "Device", device });
        if (info.label) |label| _ = Printf(dl, "%-12s %s\n", .{ "Output", label });
    }
    _ = Printf(dl, "%-12s %dx%d %s, %d bytes a row\n", .{
        "Mode",
        info.width,
        info.height,
        formatName(info.format),
        info.pitch,
    });
    if (info.refresh_mhz != 0) {
        _ = Printf(dl, "%-12s %d.%03d Hz, pixel clock %d.%03d MHz\n", .{
            "Refresh",
            info.refresh_mhz / 1000,
            info.refresh_mhz % 1000,
            info.pixel_clock_hz / 1_000_000,
            (info.pixel_clock_hz / 1000) % 1000,
        });
    }
    printMonitor(dl, rb, board);
    printSettings(dl, rb, board);
    _ = Printf(dl, "%-12s %d at once\n", .{ "Buffers", info.buffers });
    _ = Printf(dl, "%-12s ", .{"State"});
    printFlags(dl, info.flags);
    _ = Printf(dl, "%-12s ", .{"Can"});
    printCaps(dl, info.caps);
    printTurn(dl, &info);
    printPower(dl, &info);

    printModes(dl, rb, board);
    printMemory(dl, rb, board);
    if (info.flags & rtg.boards.RTGBF_STREAMING != 0) printStats(dl, rb, board);
}

/// Two words alike, whatever the case of their letters.
fn sameWord(word: [*:0]const u8, other: []const u8) bool {
    for (other, 0..) |char, at| {
        const given = word[at];
        if (given == 0) return false;
        const upper = if (given >= 'a' and given <= 'z') given - ('a' - 'A') else given;
        if (upper != char) return false;
    }
    return word[other.len] == 0;
}

/// A decimal number at `text[at.*]`, `at` moved past it; null where none
/// starts there or it does not fit.
fn numberAt(text: [*:0]const u8, at: *usize) ?u32 {
    var value: u64 = 0;
    const start = at.*;
    while (text[at.*] >= '0' and text[at.*] <= '9') : (at.* += 1) {
        value = value * 10 + (text[at.*] - '0');
        if (value > 0xFFFF_FFFF) return null;
    }
    if (at.* == start) return null;
    return @intCast(value);
}

/// "1920x1080" or "1920x1080@60" into a line's mode; false for anything
/// else.
fn readMode(text: [*:0]const u8, line: *rtg.RtgSettings) bool {
    var at: usize = 0;
    const width = numberAt(text, &at) orelse return false;
    if (text[at] != 'x' and text[at] != 'X') return false;
    at += 1;
    const height = numberAt(text, &at) orelse return false;
    var refresh: u32 = 0;
    if (text[at] == '@') {
        at += 1;
        const hertz = numberAt(text, &at) orelse return false;
        if (hertz == 0 or hertz > 1000) return false;
        refresh = hertz * 1000;
    }
    if (text[at] != 0 or width == 0 or height == 0) return false;
    line.flags |= rtg.RTGSET_MODE;
    line.mode_width = width;
    line.mode_height = height;
    line.mode_refresh_mhz = refresh;
    return true;
}

/// SET: a board's line changed key by key, or a device's driver switched.
fn set(dl: *DosBase, rb: *RtgBase, argv: *const [arg_count]usize) i32 {
    if (argv[arg_device] != 0 and argv[arg_driver] != 0) {
        const device: [*:0]const u8 = @ptrFromInt(argv[arg_device]);
        const word: [*:0]const u8 = @ptrFromInt(argv[arg_driver]);
        const on = sameWord(word, "ON");
        if (!on and !sameWord(word, "OFF")) {
            _ = dl.PutStr(MSG_BAD_DRIVER);
            return dos.RETURN_ERROR;
        }
        const code = rb.SetRtgDeviceDriver(device, on);
        if (code != rtg.errors.RTGERR_OK) {
            _ = Printf(dl, MSG_NOT_SET, .{rb.RtgErrorText(code)});
            return dos.RETURN_ERROR;
        }
        if (argv[arg_board] == 0) return dos.RETURN_OK;
    }
    if (argv[arg_board] == 0) {
        _ = dl.PutStr(MSG_SET_WHAT);
        return dos.RETURN_ERROR;
    }
    const wanted: [*:0]const u8 = @ptrFromInt(argv[arg_board]);
    const board = rb.FindBoard(wanted) orelse {
        _ = Printf(dl, MSG_NOBOARD, .{wanted});
        return dos.RETURN_ERROR;
    };
    var line: rtg.RtgSettings = .{};
    if (argv[arg_clear] == 0) _ = rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));

    if (argv[arg_mode] != 0 and !readMode(@ptrFromInt(argv[arg_mode]), &line)) {
        _ = dl.PutStr(MSG_BAD_MODE);
        return dos.RETURN_ERROR;
    }
    if (argv[arg_mirror] != 0) {
        const word: [*:0]const u8 = @ptrFromInt(argv[arg_mirror]);
        const axes: u32 = if (sameWord(word, "X"))
            rtg.RTGSET_MIRROR_X
        else if (sameWord(word, "Y"))
            rtg.RTGSET_MIRROR_Y
        else if (sameWord(word, "XY"))
            rtg.RTGSET_MIRROR_X | rtg.RTGSET_MIRROR_Y
        else if (sameWord(word, "NONE"))
            0
        else {
            _ = dl.PutStr(MSG_BAD_MIRROR);
            return dos.RETURN_ERROR;
        };
        line.flags &= ~@as(u32, rtg.RTGSET_MIRROR_X | rtg.RTGSET_MIRROR_Y);
        line.flags |= rtg.RTGSET_MIRROR | axes;
    }
    if (argv[arg_brightness] != 0) {
        const percent: *const i32 = @ptrFromInt(argv[arg_brightness]);
        if (percent.* < 0 or percent.* > 100) {
            _ = dl.PutStr(MSG_BAD_BRIGHTNESS);
            return dos.RETURN_ERROR;
        }
        line.flags |= rtg.RTGSET_BRIGHTNESS;
        line.brightness = @intCast(percent.*);
    }
    if (argv[arg_range] != 0) {
        const word: [*:0]const u8 = @ptrFromInt(argv[arg_range]);
        line.flags &= ~@as(u32, rtg.RTGSET_LIMITED_RANGE);
        if (sameWord(word, "LIMITED")) {
            line.flags |= rtg.RTGSET_RANGE | rtg.RTGSET_LIMITED_RANGE;
        } else if (sameWord(word, "FULL")) {
            line.flags |= rtg.RTGSET_RANGE;
        } else {
            _ = dl.PutStr(MSG_BAD_RANGE);
            return dos.RETURN_ERROR;
        }
    }
    if (argv[arg_first] != 0) {
        const word: [*:0]const u8 = @ptrFromInt(argv[arg_first]);
        if (sameWord(word, "YES")) {
            line.flags |= rtg.RTGSET_FIRST;
        } else if (sameWord(word, "NO")) {
            line.flags &= ~@as(u32, rtg.RTGSET_FIRST);
        } else {
            _ = dl.PutStr(MSG_BAD_FIRST);
            return dos.RETURN_ERROR;
        }
    }
    const code = rb.SetBoardSettings(board, &line);
    if (code != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, MSG_NOT_SET, .{rb.RtgErrorText(code)});
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

/// Whether a line of the file of drivers being tried names a driver on
/// rtg.library's list.
fn onList(listed: []const rtg.RtgDriverInfo, line: []const u8) bool {
    for (listed) |*driver| {
        var length: usize = 0;
        while (length < driver.name.len and driver.name[length] != 0) length += 1;
        if (length != line.len) continue;
        var same = true;
        for (driver.name[0..length], line) |one, other| {
            if (one != other) same = false;
        }
        if (same) return true;
    }
    return false;
}

/// TRIED: once every board has settled - what it began in the background
/// as it was made has ended - the name of every driver on the list taken
/// out of the file of drivers being tried; the file deleted when none is
/// left.
fn cameBack(dl: *DosBase, rb: *RtgBase) void {
    var board = rb.NextBoard(null);
    while (board) |one| : (board = rb.NextBoard(one)) _ = rb.BoardControl(one, rtg.boards.RTGCTRL_SETTLED, 0);
    var before: [1024]u8 = undefined;
    const file = dl.Open(trying_file, dos.MODE_OLDFILE) orelse return;
    const got = dl.Read(file, &before, before.len);
    _ = dl.Close(file);
    const names = before[0..if (got > 0) @intCast(got) else 0];
    var drivers: [max_listed]rtg.RtgDriverInfo = undefined;
    const listed = drivers[0..@min(rb.GetRtgDrivers(&drivers, max_listed), max_listed)];

    var kept: [1024]u8 = undefined;
    var length: usize = 0;
    var at: usize = 0;
    while (at < names.len) {
        var end = at;
        while (end < names.len and names[end] != '\n') end += 1;
        var line = names[at..end];
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        at = end + 1;
        if (line.len == 0 or onList(listed, line)) continue;
        @memcpy(kept[length..][0..line.len], line);
        kept[length + line.len] = '\n';
        length += line.len + 1;
    }
    if (length == 0) {
        _ = dl.DeleteFile(trying_file);
        return;
    }
    const out = dl.Open(trying_file, dos.MODE_NEWFILE) orelse return;
    _ = dl.Write(out, &kept, @intCast(length));
    _ = dl.Close(out);
}

/// SAVE: the settings written for the running system and for the next
/// start.
fn save(dl: *DosBase, rb: *RtgBase) i32 {
    var result: i32 = dos.RETURN_OK;
    for ([_][*:0]const u8{ rtg.RTG_SETTINGS_ENV, rtg.RTG_SETTINGS_ENVARC }) |path| {
        const code = rb.SaveBoardSettings(path);
        if (code == rtg.errors.RTGERR_OK) continue;
        _ = Printf(dl, MSG_NOT_SAVED, .{ path, rb.RtgErrorText(code) });
        result = dos.RETURN_ERROR;
    }
    return result;
}

/// The board's settings line in force, as the file has its keys; nothing
/// for a board with none.
fn printSettings(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var line: rtg.RtgSettings = .{};
    if (rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings)) != @sizeOf(rtg.RtgSettings)) return;
    if (line.flags & ~@as(u32, rtg.RTGSET_MONITOR) == 0) return;
    _ = Printf(dl, "%-12s", .{"Settings"});
    if (line.flags & rtg.RTGSET_MODE != 0) {
        _ = Printf(dl, " MODE=%dx%d", .{ line.mode_width, line.mode_height });
        if (line.mode_refresh_mhz != 0) _ = Printf(dl, "@%d", .{(line.mode_refresh_mhz + 500) / 1000});
    }
    if (line.flags & rtg.RTGSET_FIRST != 0) _ = dl.PutStr(" FIRST=YES");
    if (line.flags & rtg.RTGSET_MIRROR != 0) {
        const both = rtg.RTGSET_MIRROR_X | rtg.RTGSET_MIRROR_Y;
        const how: [*:0]const u8 = switch (line.flags & both) {
            rtg.RTGSET_MIRROR_X => "X",
            rtg.RTGSET_MIRROR_Y => "Y",
            both => "XY",
            else => "NONE",
        };
        _ = Printf(dl, " MIRROR=%s", .{how});
    }
    if (line.flags & rtg.RTGSET_BRIGHTNESS != 0) _ = Printf(dl, " BRIGHTNESS=%d", .{line.brightness});
    if (line.flags & rtg.RTGSET_RANGE != 0) {
        _ = dl.PutStr(if (line.flags & rtg.RTGSET_LIMITED_RANGE != 0) " RANGE=LIMITED" else " RANGE=FULL");
    }
    if (line.flags & rtg.RTGSET_TIMINGS != 0) {
        _ = Printf(dl, " TIMINGS=%dx%d at %d Hz", .{ line.timings.h_active, line.timings.v_active, line.timings.pixel_clock_hz });
    }
    if (line.flags & rtg.RTGSET_MONITOR != 0) {
        _ = Printf(dl, ", for %s:%04x:%08x", .{ @as([*:0]const u8, @ptrCast(&line.maker)), line.product, line.serial });
    }
    _ = dl.PutStr("\n");
}

/// Whether the picture is shown, black or the display asleep, and the
/// backlight where the board has one: its level, and how many it has.
fn printPower(dl: *DosBase, info: *const rtg.RtgBoardInfo) void {
    const state: [*:0]const u8 = switch (info.power) {
        rtg.boards.RTGPWR_ON => "on",
        rtg.boards.RTGPWR_BLANK => "blank",
        rtg.boards.RTGPWR_ASLEEP => "asleep",
        else => "?",
    };
    if (info.brightness_steps == 0) {
        _ = Printf(dl, "%-12s %s\n", .{ "Power", state });
    } else {
        _ = Printf(dl, "%-12s %s, backlight %u%% of %u levels\n", .{ "Power", state, info.brightness, info.brightness_steps });
    }
}

/// How the picture is turned, for a board that can mirror it or one that
/// has. A board that answers RTGERR_NOT_SUPPORTED says nothing here:
/// turning its picture is the business of whoever draws it.
fn printTurn(dl: *DosBase, info: *const rtg.RtgBoardInfo) void {
    const can = info.caps & (rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y);
    const turned = info.mirror_x != 0 or info.mirror_y != 0;
    if (can == 0 and !turned) return;
    const how: [*:0]const u8 = if (info.mirror_x != 0 and info.mirror_y != 0)
        "mirrored about x and y"
    else if (info.mirror_x != 0)
        "mirrored about x"
    else if (info.mirror_y != 0)
        "mirrored about y"
    else
        "upright";
    _ = Printf(dl, "%-12s %s\n", .{ "Turned", how });
}

/// The most modes of a board that are listed.
const modes_listed = 32;

/// What is on the board's connector: a panel, or a monitor by its maker
/// and name, with what its EDID says of it; nothing in particular for a
/// connector with nothing on it.
fn printMonitor(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var monitor: rtg.RtgMonitorInfo = .{};
    const written = rb.GetBoardMonitor(board, &monitor, @sizeOf(rtg.RtgMonitorInfo));
    if (written == 0) return;
    const m = rtg.modes;
    const called: [*:0]const u8 = @ptrCast(&monitor.name);
    if (monitor.flags & m.RTGMON_PANEL != 0) {
        _ = Printf(dl, "%-12s the panel %s\n", .{ "Monitor", called });
        return;
    }
    if (monitor.flags & m.RTGMON_PRESENT == 0) {
        _ = Printf(dl, "%-12s none on the connector\n", .{"Monitor"});
        return;
    }
    if (monitor.flags & m.RTGMON_EDID == 0) {
        _ = Printf(dl, "%-12s one that does not say what it is\n", .{"Monitor"});
        return;
    }
    _ = Printf(dl, "%-12s %s %s, product %04x, made %d, %d x %d mm, ", .{
        "Monitor",
        @as([*:0]const u8, @ptrCast(&monitor.maker)),
        called,
        monitor.product,
        @as(u32, monitor.year),
        monitor.width_mm,
        monitor.height_mm,
    });
    printWords(dl, monitor.flags, &monitor_words, "DVI");
    // A library older than the description of the sound leaves it out.
    if (written >= @offsetOf(rtg.RtgMonitorInfo, "speakers") + @sizeOf(u32) and monitor.audio_channels != 0) {
        printSound(dl, &monitor);
    }
}

/// The monitor's sound: how many channels at which rates and in which
/// sizes of a sample, the rates two channels take where there are more
/// of them, and the speakers.
fn printSound(dl: *DosBase, monitor: *const rtg.RtgMonitorInfo) void {
    _ = Printf(dl, "%-12s %d channel(s) at ", .{ "Sound", @as(u32, monitor.audio_channels) });
    printList(dl, monitor.audio_rates, &rate_words);
    _ = dl.PutStr(" kHz in ");
    printList(dl, monitor.audio_sizes, &size_words);
    _ = dl.PutStr(" bits");
    if (monitor.audio_channels > 2 and monitor.audio_stereo_rates & ~monitor.audio_rates != 0) {
        _ = dl.PutStr(", two at ");
        printList(dl, monitor.audio_stereo_rates, &rate_words);
        _ = dl.PutStr(" kHz");
    }
    _ = dl.PutStr(", to ");
    printWords(dl, monitor.speakers, &speaker_words, "speakers it does not name");
}

/// The words of `bits` one after the other, without a line's end.
fn printList(dl: *DosBase, bits: u32, words: []const Named) void {
    var printed = false;
    for (words) |w| {
        if (bits & w.bit == 0) continue;
        _ = Printf(dl, "%s%s", .{ if (printed) " " else "", w.word });
        printed = true;
    }
    if (!printed) _ = dl.PutStr("-");
}

fn printModes(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var found: [modes_listed]rtg.RtgMode = undefined;
    const there = rb.GetBoardModes(board, &found, found.len);
    if (there == 0) {
        _ = Printf(dl, "%-12s none\n", .{"Modes"});
        return;
    }
    _ = dl.PutStr("Modes         id  name            format     row    clock    refresh  how it is\n");
    for (found[0..@min(there, found.len)]) |*m| {
        _ = Printf(dl, "             %3d  %-14s  %-6s  %6d  %4d MHz  %2d.%03d Hz  ", .{
            m.id,
            @as([*:0]const u8, @ptrCast(&m.name)),
            formatName(m.format),
            m.pitch,
            m.pixel_clock_hz / 1_000_000,
            m.refresh_mhz / 1000,
            m.refresh_mhz % 1000,
        });
        // What this mode is to the board, in words: no legend to look up.
        printWords(dl, m.flags, &mode_words, "-");
    }
}

fn printMemory(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var info: rtg.RtgBoardInfo = .{};
    if (rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo)) == 0) return;
    _ = Printf(dl, "%-12s %zd bytes, %zd free, largest piece %zd\n", .{
        "Memory",
        info.memory_total,
        info.memory_free,
        info.memory_largest,
    });
    if (rb.BoardDisplayBitMap(board)) |shown| {
        _ = Printf(dl, "%-12s 0x%08zx, %dx%d %s, %d bytes a row, %zd bytes\n", .{
            "Showing",
            @intFromPtr(shown.pixels),
            shown.width,
            shown.height,
            formatName(shown.format),
            shown.pitch,
            shown.size_bytes,
        });
    } else {
        _ = Printf(dl, "%-12s nothing\n", .{"Showing"});
    }
}

fn printStats(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var s: rtg.RtgBoardStats = .{};
    const got = rb.GetBoardStats(board, &s, @sizeOf(rtg.RtgBoardStats));
    if (got == 0) return;
    if (s.frames == 0 and s.refills == 0 and s.buffer_swaps == 0) {
        _ = dl.PutStr("Stream       nothing counted\n");
        return;
    }
    _ = Printf(dl, "%-12s %d frames, %d late (worst %d us past the frame), %d starved\n", .{
        "Stream",
        s.frames,
        s.late_frames,
        s.worst_late_us,
        s.starved_frames,
    });
    if (has(got, "late_refills")) {
        _ = Printf(dl, "%-12s %d copied, %d of them late\n", .{ "Refills", s.refills, s.late_refills });
    }
    if (has(got, "slow_gaps")) {
        _ = Printf(dl, "%-12s %d, last gap %d us, worst %d us, %d over a line, %d over 5 us\n", .{
            "Realigns",
            s.realigns,
            s.last_gap_us,
            s.worst_gap_us,
            s.long_gaps,
            s.slow_gaps,
        });
    }
    if (has(got, "walk_frames")) {
        _ = Printf(dl, "%-12s at stretch %d, moved %d over %d frames\n", .{
            "In step",
            s.stream_at,
            s.total_walk,
            s.walk_frames,
        });
    }
    if (has(got, "buffer_swaps") and s.buffer_swaps != 0) {
        _ = Printf(dl, "%-12s %d buffer(s) handed to the display\n", .{ "Swaps", s.buffer_swaps });
    }
}

// --- what the words are -----------------------------------------------------

const Named = struct { bit: u32, word: [*:0]const u8 };

const state_words = [_]Named{
    .{ .bit = rtg.boards.RTGBF_NO_DISPLAY, .word = "no-display" },
    .{ .bit = rtg.boards.RTGBF_MODE_SET, .word = "mode-set" },
    .{ .bit = rtg.boards.RTGBF_SHOWING, .word = "showing" },
    .{ .bit = rtg.boards.RTGBF_STREAMING, .word = "streaming" },
    .{ .bit = rtg.boards.RTGBF_ADOPTED, .word = "adopted" },
    .{ .bit = rtg.boards.RTGBF_POINTER, .word = "pointer-shown" },
    .{ .bit = rtg.boards.RTGBF_COMPOSE, .word = "composed" },
    .{ .bit = rtg.boards.RTGBF_GONE, .word = "gone" },
    .{ .bit = rtg.boards.RTGBF_FIRMWARE, .word = "firmware" },
    .{ .bit = rtg.boards.RTGBF_CONNECTOR, .word = "connector" },
    .{ .bit = rtg.boards.RTGBF_DIRECT_FLIP, .word = "direct-flip" },
    .{ .bit = rtg.boards.RTGBF_SCALES, .word = "scaling-planes" },
};

const monitor_words = [_]Named{
    .{ .bit = rtg.modes.RTGMON_HDMI, .word = "HDMI" },
    .{ .bit = rtg.modes.RTGMON_HDMI2, .word = "HDMI-2.0" },
    .{ .bit = rtg.modes.RTGMON_AUDIO, .word = "sound" },
    .{ .bit = rtg.modes.RTGMON_RANGE_SELECTABLE, .word = "range-selectable" },
    .{ .bit = rtg.modes.RTGMON_SCDC, .word = "scrambling" },
};

const rate_words = [_]Named{
    .{ .bit = rtg.modes.RTGAUDIO_RATE_32000, .word = "32" },
    .{ .bit = rtg.modes.RTGAUDIO_RATE_44100, .word = "44.1" },
    .{ .bit = rtg.modes.RTGAUDIO_RATE_48000, .word = "48" },
    .{ .bit = rtg.modes.RTGAUDIO_RATE_88200, .word = "88.2" },
    .{ .bit = rtg.modes.RTGAUDIO_RATE_96000, .word = "96" },
    .{ .bit = rtg.modes.RTGAUDIO_RATE_176400, .word = "176.4" },
    .{ .bit = rtg.modes.RTGAUDIO_RATE_192000, .word = "192" },
};

const size_words = [_]Named{
    .{ .bit = rtg.modes.RTGAUDIO_BITS_16, .word = "16" },
    .{ .bit = rtg.modes.RTGAUDIO_BITS_20, .word = "20" },
    .{ .bit = rtg.modes.RTGAUDIO_BITS_24, .word = "24" },
};

const speaker_words = [_]Named{
    .{ .bit = rtg.modes.RTGSPEAKER_FRONT, .word = "front" },
    .{ .bit = rtg.modes.RTGSPEAKER_LFE, .word = "LFE" },
    .{ .bit = rtg.modes.RTGSPEAKER_CENTRE, .word = "centre" },
    .{ .bit = rtg.modes.RTGSPEAKER_REAR, .word = "rear" },
    .{ .bit = rtg.modes.RTGSPEAKER_REAR_CENTRE, .word = "rear-centre" },
    .{ .bit = rtg.modes.RTGSPEAKER_FRONT_CENTRES, .word = "front-centres" },
    .{ .bit = rtg.modes.RTGSPEAKER_REAR_CENTRES, .word = "rear-centres" },
};

const mode_words = [_]Named{
    .{ .bit = rtg.modes.RTGMF_CURRENT, .word = "current" },
    .{ .bit = rtg.modes.RTGMF_DEFAULT, .word = "default" },
    .{ .bit = rtg.modes.RTGMF_TURNED, .word = "turned" },
    .{ .bit = rtg.modes.RTGMF_INTERLACED, .word = "interlaced" },
};

const cap_words = [_]Named{
    .{ .bit = rtg.boards.RTGBC_SHOW, .word = "show" },
    .{ .bit = rtg.boards.RTGBC_BANDS, .word = "bands" },
    .{ .bit = rtg.boards.RTGBC_SCALE_BANDS, .word = "scaled-bands" },
    .{ .bit = rtg.boards.RTGBC_VBLANK, .word = "frames" },
    .{ .bit = rtg.boards.RTGBC_REFRESH, .word = "refresh" },
    .{ .bit = rtg.boards.RTGBC_POWER, .word = "sleep" },
    .{ .bit = rtg.boards.RTGBC_BRIGHTNESS, .word = "brightness" },
    .{ .bit = rtg.boards.RTGBC_STATS, .word = "stats" },
    .{ .bit = rtg.boards.RTGBC_AUDIO, .word = "sound" },
    .{ .bit = rtg.boards.RTGBC_COLOR_RANGE, .word = "range" },
    .{ .bit = rtg.boards.RTGBC_CONTROL, .word = "control" },
    .{ .bit = rtg.boards.RTGBC_MIRROR_X, .word = "mirror-x" },
    .{ .bit = rtg.boards.RTGBC_MIRROR_Y, .word = "mirror-y" },
    .{ .bit = rtg.boards.RTGBC_MONITOR, .word = "monitor" },
    .{ .bit = rtg.boards.RTGBC_POINTER, .word = "pointer" },
    .{ .bit = rtg.boards.RTGBC_OVERLAY, .word = "overlay" },
    .{ .bit = rtg.boards.RTGBC_FILL_RECT, .word = "fill" },
    .{ .bit = rtg.boards.RTGBC_COPY_RECT, .word = "copy" },
    .{ .bit = rtg.boards.RTGBC_BLIT_TEMPLATE, .word = "template" },
    .{ .bit = rtg.boards.RTGBC_BLIT_PATTERN, .word = "pattern" },
    .{ .bit = rtg.boards.RTGBC_BLEND_PIXELS, .word = "blend" },
    .{ .bit = rtg.boards.RTGBC_BLEND_RECT, .word = "blend-fill" },
    .{ .bit = rtg.boards.RTGBC_SCALE_PIXELS, .word = "scale" },
    .{ .bit = rtg.boards.RTGBC_VIDEO, .word = "video" },
};

fn printWords(dl: *DosBase, bits: u32, words: []const Named, none: [*:0]const u8) void {
    var printed = false;
    for (words) |w| {
        if (bits & w.bit == 0) continue;
        _ = Printf(dl, "%s%s", .{ if (printed) " " else "", w.word });
        printed = true;
    }
    if (!printed) _ = Printf(dl, "%s", .{none});
    _ = dl.PutStr("\n");
}

fn printFlags(dl: *DosBase, flags: u32) void {
    printWords(dl, flags, &state_words, "idle");
}

/// What the board's own hardware does. Whatever is not here the caller
/// does itself: this layer holds no drawing.
fn printCaps(dl: *DosBase, caps: u32) void {
    printWords(dl, caps, &cap_words, "nothing");
}

fn kindOf(kind: u32) [*:0]const u8 {
    const board = kind & rtg.drivers.RTGDT_BOARD != 0;
    const bus = kind & rtg.drivers.RTGDT_TRANSPORT != 0;
    if (board and bus) return "board+bus";
    if (board) return "board";
    if (bus) return "bus";
    return "-";
}

fn formatName(format: rtg.PixelFormat) [*:0]const u8 {
    return switch (format) {
        .rgba32 => "rgba32",
        .bgra32 => "bgra32",
        .rgb24 => "rgb24",
        .bgr24 => "bgr24",
        .rgb565 => "rgb565",
        .argb1555 => "a1555",
        .indexed8 => "index8",
        .gray8 => "gray8",
        .mono1 => "mono1",
        else => "?",
    };
}

/// A module's id string, which is its "$VER:" line: past the "$VER: " and
/// cut before the carriage return every one of them ends with, so it can
/// go in a table without taking two lines.
fn idText(into: []u8, from: ?[*:0]const u8) [*:0]const u8 {
    const text = from orelse return "";
    var at: usize = 0;
    if (starts(text, "$VER: ")) at = 6;
    var put: usize = 0;
    while (text[at] != 0 and put + 1 < into.len) : (at += 1) {
        if (text[at] < ' ') break;
        into[put] = text[at];
        put += 1;
    }
    into[put] = 0;
    return @ptrCast(into.ptr);
}

fn starts(text: [*:0]const u8, comptime prefix: []const u8) bool {
    inline for (prefix, 0..) |want, i| {
        if (text[i] != want) return false;
    }
    return true;
}

/// A string the library may have left null.
fn name(s: ?[*:0]const u8) [*:0]const u8 {
    return s orelse "?";
}

/// Whether the answer reached far enough to hold a field. The ROM says how
/// many bytes it wrote; a field is there when its last byte is inside them.
fn has(got: u32, comptime field: []const u8) bool {
    const end = @offsetOf(rtg.RtgBoardStats, field) + @sizeOf(@FieldType(rtg.RtgBoardStats, field));
    return got >= end;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
