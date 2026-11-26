// SPDX-License-Identifier: MIT
//! Gpu: an AMD graphics device tried a part at a time, each step said:
//! its video BIOS read, the display's clocks asked for, the display
//! controller read or started, its hot-plug lines and notifications
//! counted, an AUX read through it, a monitor's EDID read over its DDC
//! line, the picture's checksum read, the display's pipe taken down and
//! brought up again in its mode or put in each mode it offers, its
//! monitor put to sleep and woken, its colours' range tried, its security
//! processor started and the video decoder's firmware loaded by it, the
//! display's interrupt at each frame counted, or one flip of the picture
//! the display reads. Built against the SDK only.
//!
//!   Gpu TOC/K,FIRMWARE/K,FRAMES/S,FLIP/S,BIOS/S,CLOCKS/S,DMCUB/S,START/S,CRC/S,EVENTS/S,LINE/K/N,AUX/K/N,ADDRESS/K/N,LENGTH/K/N,I2C/S,CONTROLLER/S,EDID/S,CONNECTOR/K/N,PIPE/K/N,FETCHER/K/N,CYCLE/S,DUMP/K/N,SEGMENT/K/N,MODES/S,HOLD/K/N,
//!       SLEEP/K/N,RANGE/S,POINTER/S,WATCHDOG/K/N
//!
//! BIOS prints the device's video BIOS image (GetGPUBios): where it is
//! and how long, its tables' header's version, the version of each of
//! the command tables the display's pipe is switched with and of each
//! data table it lists, and the display's connectors as amdgpu.resource read
//! them from it (GetGPUConnector) - each one's kind, the PHY that drives
//! it, its DDC line and its hot-plug pin. Nothing is written to the
//! device, and no watchdog is wanted.
//!
//! CLOCKS has the display's board ("amd.0") ask the device's power
//! manager, through the display's own mailbox, for its firmware's
//! version and its table of clock levels, and read the clocks running
//! now (RTGCTRL_AMD_CLOCKS): the levels of each of the display's clocks,
//! the SoC's and the data fabric's states, then the PLL the display's
//! clocks are divided from, the display clock and the pipes' clock. The
//! messages change nothing, but they are written to the device: the
//! watchdog is armed for them.
//!
//! DMCUB prints the display controller - the display engine's own
//! processor - as its registers read (RTGCTRL_AMD_CONTROLLER): whether
//! it is enabled, in reset, running its firmware (its clock read twice),
//! its boot status and options, its rings, the windows it reaches memory
//! through, its last faults. Read only, no watchdog wanted. The board
//! starts it as it is made; with START the board starts it again
//! (RTGCTRL_AMD_START_CONTROLLER): the firmware
//! dcn_<version>_dmcub.bin loaded by the security processor, the memory
//! it runs with set up, the controller let out of reset and asked what
//! it can do; printed are how far that got, the controller as it then
//! reads, its answer and the start of its trace, and the picture's
//! checksum before and after, which should be the same. The watchdog is
//! armed for it.
//!
//! CRC prints the checksum the display's timing generator computes over
//! the picture (RTGCTRL_AMD_CRC), switching it on the first time: the
//! watchdog is armed for it.
//!
//! EVENTS prints what the display engine's hot-plug lines and its
//! controller's notifications have done (RTGCTRL_AMD_EVENTS): each
//! line's changes, whether it senses a monitor and whether it is on, and
//! the controller's notifications by kind. The first time after the
//! controller started it has the controller's notifications listened
//! to, so the watchdog is armed for it; a cable pulled and put
//! back between two EVENTS shows as a line's changes. With LINE the
//! line of that number is first made to raise its interrupt once, by
//! waiting for what it already senses - the path tested without a hand
//! at the cable.
//!
//! AUX reads LENGTH bytes (16 unless given, at most 16) at ADDRESS (0
//! unless given) through the socket's AUX channel AUX - its DDC line's
//! number - by the channel's own AUX engine (RTGCTRL_AMD_AUX), or with
//! CONTROLLER by the display controller, which must run: the sink's own
//! registers, or with I2C its I2C bus. Printed
//! are the result, the sink's reply, the bytes and the channel's
//! registers before and after. The watchdog is armed for it.
//!
//! EDID reads the EDID of the monitor on the board's connector, or on
//! connector CONNECTOR as BIOS numbers them, as the board's own look at
//! its connector does (RTGCTRL_AMD_EDID): over its DDC line by the
//! display engine's I2C engine on HDMI and DVI, by I2C over its AUX
//! channel on DisplayPort. Printed are the connector's lines, whether its
//! hot-plug line senses a monitor, how the read went, the engine's
//! registers before and after, what the EDID says of the monitor and its
//! bytes. The watchdog is armed for it.
//!
//! CYCLE has the board take the display's pipe down and bring it up
//! again in the mode it is in (RTGCTRL_AMD_PIPE): the timing generator
//! stopped, the link's front end let go, the PHY switched off and its PLL
//! powered down by the video BIOS's command tables, which the display
//! controller runs, then all of it the other way. Printed are what was taken (the pipe, the link's ends,
//! the PHY, the link's kind, its deep colour and its clocks), how far it
//! got and how long the pipe was down, the pipe's registers before, while
//! down and after, and the picture's checksum before and after, which
//! should be the same: a picture that changes by itself - a clock's
//! seconds - is first waited for to change and then to hold 100 ms (2 s
//! at the most), and the pipe taken down right after. The watchdog is
//! armed for it.
//!
//! MODES puts the display's board in each mode it offers, in turn, and
//! back in the one it was in. First the board's settings line is applied
//! as it stands (SetBoardSettings), which has the board's modes made
//! again of what the monitor names - all it can make while the display
//! controller runs, the one it scans where it does not. Each mode is
//! shown with a picture of its own size: eight bars of colour, a white
//! frame round the edge. Printed for each are the mode, how its set went
//! (RTGCTRL_AMD_MODE: the link, the pixel clock, how far it got, how long
//! the pipe was down, whether the fetcher or the output ran short of
//! pixels) and the picture's checksum read twice, a few frames after the
//! show and again more than a frame later, which should be the same; then it is held HOLD seconds (2 unless given) for
//! a look at the monitor. Ctrl-C stops after the mode shown. The watchdog
//! is armed for it and fed after each mode.
//!
//! SLEEP puts the display's board's monitor to sleep for SLEEP seconds
//! (SetBoardPower, RTGPWR_ASLEEP) and wakes it (RTGPWR_ON). Printed are
//! the picture's checksum before, while asleep - the last frame's, the
//! timing generator stopped - and after, which should be the one before;
//! pipe 0's count of frames and how many it counts in 100 ms, before,
//! twice while asleep (none) and after; each answer and the power state
//! the board then says it is in. With MODES, the board is shown in the
//! first other mode it offers while asleep, and back in its own, each set
//! printed: the monitor is woken for each set and put to sleep after.
//! How long the PHY took to go off and come on is on the system's lines.
//! The watchdog is armed for it and fed while the monitor sleeps.
//!
//! RANGE shows the board's mode with a still picture - eight bars of
//! colour, a white frame - and reads the picture's checksum with the
//! colours in full range, in limited range and in full again, each
//! twice: the first and the last should be the same, the second
//! another, and each steady. The range is the board's settings line's
//! (SetBoardSettings), which is put back as it was, and so is the
//! picture. The watchdog is armed for it.
//!
//! POINTER shows the same still picture and reads its checksum with the
//! board's pointer hidden, shown at three places - the last partly off
//! the picture's top left - and hidden again, with what pipe 0's cursor
//! is told at each: shown or not, its place and its hot spot. The first
//! and the last checksum should be the same and the others each another.
//! The pointer is put back where it was, shown or not as it was, and so
//! is the picture. The watchdog is armed for it.
//!
//! DUMP prints LENGTH (16 unless given, at most 512) of the display
//! engine's registers from DUMP on, in 32-bit words from the engine's
//! address SEGMENT (2 unless given: the one its pipes, links and
//! endpoints are counted from; 1 is its clocks'). Read only, but a
//! register of a block switched off can stop the machine: the watchdog
//! is armed for it.
//!
//! Without BIOS, CLOCKS, DMCUB, CRC, EVENTS, AUX, EDID, CYCLE, MODES,
//! SLEEP, RANGE, POINTER, DUMP, FRAMES or FLIP the two files are read from
//! DEVS:firmware/amdgpu/, named for the blocks that use them as the
//! device's table gives their versions - psp_13_0_4_toc.bin for the
//! security processor 13.0.4, vcn_4_0_2.bin for the video decoder 4.0.2 -
//! unless TOC and FIRMWARE name others. amdgpu.resource is asked to make
//! the processor ready (StartGPUSecurity) and to load the firmware
//! (LoadGPUFirmware), and where it put it is printed. What the processor
//! answered to each command is on the system's lines (C:Log).
//!
//! FRAMES hooks the interrupt the display's pipe PIPE (0 unless given)
//! raises at each frame, where it takes up its double-buffered registers
//! (AddGPUIntServer), switches it on, and counts it for three seconds
//! beside the pipe's own count of frames; then switches it off. The first
//! server starts the device's interrupt ring, which says so on the
//! system's lines.
//!
//! FLIP has the fetcher FETCHER (0 unless given) of that pipe read a
//! frame of the device's own memory instead of the firmware's screen:
//! the frame holds a copy of the default public screen, rows as far
//! apart as the fetcher reads them, so the display shows what it showed -
//! but for the pointer, which is not in the screen's buffer. The flip is
//! the fetcher's new address, taken up at the pipe's next update; it is
//! waited for by the interrupt FRAMES counts, and how many frames and how
//! long it took is printed, with the address the fetcher then reads. Held
//! three seconds, then flipped back the same way, and the frame given
//! back.
//!
//! WATCHDOG is the watchdog's time in milliseconds, armed before the
//! first write to the device, fed after each step and disarmed at the
//! end: a block that stops the machine has it reset. Every step but BIOS
//! requires it, since nothing else brings a machine back that stopped
//! there.

const sdk = @import("sdk");
const dos = sdk.dos;
const datatypes = sdk.datatypes;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const watchdog = sdk.resources.watchdog;
const WatchdogBase = sdk.interface.watchdog.WatchdogBase;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = sdk.interface.amdgpu.AMDGPUBase;
const exec = sdk.exec;
const intuition = sdk.intuition;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const timer = sdk.devices.timer;
const TimerBase = sdk.interface.timer.TimerBase;
const dcn = sdk.hardware.amd_dcn;
const reg = sdk.hardware.mmio.reg;
const Printf = dos.stdio.Printf;
const rtg = sdk.rtg;
const RtgBase = sdk.interface.rtg.RtgBase;

pub const COMMAND_NAME = "Gpu";
const VERSION_STRING = "\x00$VER: Gpu 1.14 (26.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TOC/K,FIRMWARE/K,FRAMES/S,FLIP/S,BIOS/S,CLOCKS/S,DMCUB/S,START/S,CRC/S,EVENTS/S,LINE/K/N,AUX/K/N,ADDRESS/K/N,LENGTH/K/N,I2C/S,CONTROLLER/S,EDID/S,CONNECTOR/K/N,PIPE/K/N,FETCHER/K/N,CYCLE/S,DUMP/K/N,SEGMENT/K/N,MODES/S,HOLD/K/N,SLEEP/K/N,RANGE/S,POINTER/S,WATCHDOG/K/N";
const arg_toc = 0;
const arg_firmware = 1;
const arg_frames = 2;
const arg_flip = 3;
const arg_bios = 4;
const arg_clocks = 5;
const arg_dmcub = 6;
const arg_start = 7;
const arg_crc = 8;
const arg_events = 9;
const arg_line = 10;
const arg_aux = 11;
const arg_address = 12;
const arg_length = 13;
const arg_i2c = 14;
const arg_controller = 15;
const arg_edid = 16;
const arg_connector = 17;
const arg_pipe = 18;
const arg_fetcher = 19;
const arg_cycle = 20;
const arg_dump = 21;
const arg_segment = 22;
const arg_modes = 23;
const arg_hold = 24;
const arg_sleep = 25;
const arg_range = 26;
const arg_pointer = 27;
const arg_watchdog = 28;
const arg_count = 29;

/// Where the files are.
const directory = "DEVS:firmware/amdgpu/";

/// The image's marks: where its tables' header's offset is, the header's
/// mark four bytes into it, and where the header names the list of
/// command tables and the list of data tables.
const atom_header_offset_at = 0x48;
const atom_mark_at = 4;
const atom_commands_at = 0x1E;
const atom_data_tables_at = 0x20;

/// A table of the BIOS's, by its place in its list.
const NamedTable = struct { index: u32, name: [*:0]const u8 };

/// The command tables the display driver runs.
const command_table_names = [_]NamedTable{
    .{ .index = 4, .name = "front end" },
    .{ .index = 12, .name = "pixel clock" },
    .{ .index = 13, .name = "display power gating" },
    .{ .index = 76, .name = "transmitter" },
};

/// The data tables the display driver reads.
const data_table_names = [_]NamedTable{
    .{ .index = 4, .name = "firmware info" },
    .{ .index = 8, .name = "power manager info" },
    .{ .index = 11, .name = "memory the firmware uses" },
    .{ .index = 12, .name = "GPIO pins" },
    .{ .index = 14, .name = "graphics info" },
    .{ .index = 15, .name = "power play" },
    .{ .index = 22, .name = "display objects" },
    .{ .index = 27, .name = "display engine info" },
    .{ .index = 30, .name = "integrated system info" },
    .{ .index = 32, .name = "voltage objects" },
};

/// A file's name, put together from its parts.
const Name = struct {
    room: [64]u8 = undefined,
    len: usize = 0,

    fn text(name: *Name, part: []const u8) void {
        for (part) |c| {
            if (name.len + 1 >= name.room.len) return;
            name.room[name.len] = c;
            name.len += 1;
        }
    }

    fn number(name: *Name, value: u32) void {
        var digits: [10]u8 = undefined;
        var count: usize = 0;
        var left = value;
        while (true) {
            digits[count] = @intCast('0' + left % 10);
            count += 1;
            left /= 10;
            if (left == 0) break;
        }
        while (count > 0) {
            count -= 1;
            name.text(digits[count .. count + 1]);
        }
    }

    /// `prefix` with the block's version, `suffix` after it.
    fn of(prefix: []const u8, block: amdgpu.GPUBlock, suffix: []const u8) Name {
        var name: Name = .{};
        name.text(directory);
        name.text(prefix);
        name.number(block.major);
        name.text("_");
        name.number(block.minor);
        name.text("_");
        name.number(block.revision);
        name.text(suffix);
        name.room[name.len] = 0;
        return name;
    }

    fn string(name: *const Name) [*:0]const u8 {
        return @ptrCast(&name.room);
    }
};

/// The file `name` read whole into memory of its own (FreeVec), or null
/// with why said.
fn readFile(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8) ?[]u8 {
    var length: usize = 0;
    const bytes = dl.ReadFile(name, ~@as(usize, 0), exec.MEMF_ANY, &length) orelse {
        _ = Printf(dl, "%s: cannot be %s\n", .{ name, @as([*:0]const u8, if (dl.IoErr() == dos.ERROR_OBJECT_NOT_FOUND) "found" else "read") });
        return null;
    };
    if (length == 0) {
        sys.FreeVec(bytes);
        _ = Printf(dl, "%s: cannot be read\n", .{name});
        return null;
    }
    return bytes[0..length];
}

/// The 16-bit number at `at` in `image`, or null past its end.
fn half(image: []const u8, at: usize) ?u16 {
    if (at + 2 > image.len) return null;
    return @as(u16, image[at]) | @as(u16, image[at + 1]) << 8;
}

/// What a table at `at` says its version and its size are: its first
/// four bytes.
fn tableHeader(image: []const u8, at: usize) ?struct { bytes: u16, format: u8, content: u8 } {
    const bytes = half(image, at) orelse return null;
    if (at + 4 > image.len) return null;
    return .{ .bytes = bytes, .format = image[at + 2], .content = image[at + 3] };
}

/// The tables `names` of the list at `list` in `image`, each where it
/// is, its version and its length.
fn printTables(dl: *DosBase, image: []const u8, list: u16, names: []const NamedTable) void {
    for (names) |named| {
        const at = half(image, @as(usize, list) + 4 + named.index * 2) orelse continue;
        if (at == 0) {
            _ = Printf(dl, "  %2u %-26s none\n", .{ named.index, named.name });
            continue;
        }
        const table = tableHeader(image, at) orelse continue;
        _ = Printf(dl, "  %2u %-26s at 0x%04x, version %u.%u, %u bytes\n", .{
            named.index,            named.name,              @as(u32, at),
            @as(u32, table.format), @as(u32, table.content), @as(u32, table.bytes),
        });
    }
}

/// The video BIOS image and the connectors read from it, printed.
fn bios(dl: *DosBase, ab: *AMDGPUBase) i32 {
    var found: amdgpu.GPUBios = .{};
    if (!ab.GetGPUBios(&found)) {
        _ = Printf(dl, "The firmware kept no video BIOS image for the device: see C:Log\n", .{});
        return dos.RETURN_WARN;
    }
    const image = found.image.?[0..found.bytes];
    _ = Printf(dl, "Video BIOS: %u bytes at 0x%lx\n", .{ found.bytes, @as(u64, @intFromPtr(found.image.?)) });
    if (half(image, atom_header_offset_at)) |header| {
        if (tableHeader(image, header)) |atom| {
            _ = Printf(dl, "Tables' header at 0x%04x, version %u.%u\n", .{ @as(u32, header), @as(u32, atom.format), @as(u32, atom.content) });
        }
        const commands = half(image, @as(usize, header) + atom_commands_at) orelse 0;
        if (tableHeader(image, commands)) |list| {
            _ = Printf(dl, "Command tables: list at 0x%04x, %u entries\n", .{ @as(u32, commands), @as(u32, list.bytes -| 4) / 2 });
            printTables(dl, image, commands, &command_table_names);
        }
        const data = half(image, @as(usize, header) + atom_data_tables_at) orelse 0;
        if (tableHeader(image, data)) |list| {
            _ = Printf(dl, "Data tables: list at 0x%04x, %u entries\n", .{ @as(u32, data), @as(u32, list.bytes -| 4) / 2 });
            printTables(dl, image, data, &data_table_names);
        }
    }
    var connector: amdgpu.GPUConnector = .{};
    var index: u32 = 0;
    while (ab.GetGPUConnector(index, &connector)) : (index += 1) {
        const phy: u32 = if (connector.phy == amdgpu.GPULINE_NONE) '?' else 'A' + connector.phy;
        _ = Printf(dl, "Connector %u: %s %u on PHY %c, DDC line 0x%02x, hot plug 0x%02x (object 0x%04x, encoder 0x%04x)\n", .{
            index,         kindName(connector.kind), connector.number, phy,
            connector.ddc, connector.hpd,            connector.object, connector.encoder,
        });
    }
    if (index == 0) _ = Printf(dl, "The video BIOS lists no connectors this reads\n", .{});
    return dos.RETURN_OK;
}

/// The display's board, by the name its driver gives it.
const amd_board = "amd.0";

/// The display's clocks, asked of its board with the watchdog armed, and
/// printed.
fn clocks(sys: *ExecBase, dl: *DosBase, millis: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = rb.FindBoard(amd_board) orelse {
        _ = Printf(dl, "No board %s: the display is not driven by rtg-amd\n", .{amd_board});
        return dos.RETURN_WARN;
    };
    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "No %s\n", .{watchdog.WATCHDOGNAME});
        return dos.RETURN_FAIL;
    });
    if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
        _ = Printf(dl, "The watchdog refuses %u ms\n", .{millis});
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "Watchdog armed: %u ms\n", .{millis});
    var found: rtg.tags.RtgAmdClocks = .{};
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CLOCKS, @bitCast(@intFromPtr(&found)));
    wb.DisarmWatchdog();
    if (found.pll_khz != 0) {
        _ = Printf(dl, "Running: PLL %u kHz, display clock %u kHz, pipes' clock %u kHz\n", .{ found.pll_khz, found.disp_khz, found.dpp_khz });
    } else _ = Printf(dl, "Running: the clock generator is not known\n", .{});
    if (found.firmware != 0) {
        _ = Printf(dl, "Power manager's firmware %u.%u.%u\n", .{ found.firmware >> 16 & 0xff, found.firmware >> 8 & 0xff, found.firmware & 0xff });
    }
    if (result != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "The clocks were not had: error %ld, message 0x%x answered 0x%x\n", .{ @as(i64, result), found.message, found.answer });
        return dos.RETURN_ERROR;
    }
    printLevels(dl, "Display controller (DCFCLK)", found.dcf_mhz[0..found.dcf_count]);
    printLevels(dl, "Display (DISPCLK)", found.disp_mhz[0..found.disp_count]);
    printLevels(dl, "Pipes (DPPCLK)", found.dpp_mhz[0..found.disp_count]);
    printLevels(dl, "SoC (SOCCLK)", found.soc_mhz[0..found.soc_count]);
    for (0..found.fabric_count) |index| {
        _ = Printf(dl, "Fabric state %u: fabric %u MHz, memory %u MHz, %u.%02u mV\n", .{
            @as(u32, @intCast(index)),
            found.fabric_mhz[index],
            found.memory_mhz[index],
            found.fabric_voltage[index] / 4,
            found.fabric_voltage[index] % 4 * 25,
        });
    }
    return dos.RETURN_OK;
}

/// The display's board, from rtg.library opened as `base`: null with why
/// said.
fn amdBoard(dl: *DosBase, rb: *RtgBase) ?*rtg.RtgBoard {
    return rb.FindBoard(amd_board) orelse {
        _ = Printf(dl, "No board %s: the display is not driven by rtg-amd\n", .{amd_board});
        return null;
    };
}

/// The watchdog armed for `millis`: its resource, or null with why said.
fn arm(sys: *ExecBase, dl: *DosBase, millis: u32) ?*WatchdogBase {
    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "No %s\n", .{watchdog.WATCHDOGNAME});
        return null;
    });
    if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
        _ = Printf(dl, "The watchdog refuses %u ms\n", .{millis});
        return null;
    }
    _ = Printf(dl, "Watchdog armed: %u ms\n", .{millis});
    return wb;
}

/// The display controller read, or - with the watchdog's `millis` -
/// started; printed either way.
fn controller(sys: *ExecBase, dl: *DosBase, millis: ?u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    var found: rtg.tags.RtgAmdController = .{};
    const time = millis orelse {
        const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CONTROLLER, @bitCast(@intFromPtr(&found)));
        if (result != rtg.errors.RTGERR_OK) {
            _ = Printf(dl, "The controller was not read: error %ld\n", .{@as(i64, result)});
            return dos.RETURN_ERROR;
        }
        printController(dl, &found);
        return dos.RETURN_OK;
    };
    const wb = arm(sys, dl, time) orelse return dos.RETURN_FAIL;
    var before: rtg.tags.RtgAmdCrc = .{};
    const crc_before = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&before)));
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_START_CONTROLLER, @bitCast(@intFromPtr(&found)));
    var after: rtg.tags.RtgAmdCrc = .{};
    const crc_after = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&after)));
    wb.DisarmWatchdog();
    const stages = [_][*:0]const u8{ "nothing done", "the files read", "the firmware loaded", "set up", "up", "answered" };
    _ = Printf(dl, "Start: error %ld, %s\n", .{ @as(i64, result), stages[@min(found.stage, stages.len - 1)] });
    printController(dl, &found);
    if (found.stage >= rtg.tags.RTG_AMD_STAGE_UP) {
        _ = Printf(dl, "Answer:", .{});
        for (found.reply) |reply_word| _ = Printf(dl, " %08lx", .{@as(u64, reply_word)});
        _ = Printf(dl, "\nTrace:", .{});
        for (found.trace) |trace_word| _ = Printf(dl, " %08lx", .{@as(u64, trace_word)});
        _ = Printf(dl, "\n", .{});
    }
    printCrc(dl, "Picture before", crc_before, &before);
    printCrc(dl, "Picture after ", crc_after, &after);
    if (crc_before == rtg.errors.RTGERR_OK and crc_after == rtg.errors.RTGERR_OK) {
        const same = before.red == after.red and before.green == after.green and before.blue == after.blue;
        _ = Printf(dl, "The picture is %s\n", .{@as([*:0]const u8, if (same) "unchanged" else "CHANGED")});
    }
    return if (result == rtg.errors.RTGERR_OK) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// The controller as RtgAmdController holds it, a line a part.
fn printController(dl: *DosBase, found: *const rtg.tags.RtgAmdController) void {
    if (found.present == 0) {
        _ = Printf(dl, "The display engine has no controller\n", .{});
        return;
    }
    _ = Printf(dl, "Control %08lx: %s, %s; reset %08lx (%s); secure %08lx\n", .{
        @as(u64, found.control),
        @as([*:0]const u8, if (found.control & 1 << 16 != 0) "enabled" else "disabled"),
        @as([*:0]const u8, if (found.control & 1 << 20 != 0) "waiting" else "not waiting"),
        @as(u64, found.reset),
        @as([*:0]const u8, if (found.reset & 1 != 0) "held" else "released"),
        @as(u64, found.secure),
    });
    _ = Printf(dl, "Status %08lx: firmware %s, mailbox %s; options %08lx; clock %lu then %lu (%s)\n", .{
        @as(u64, found.status),
        @as([*:0]const u8, if (found.status & 1 != 0) "runs" else "does not run"),
        @as([*:0]const u8, if (found.status & 2 != 0) "ready" else "not ready"),
        @as(u64, found.options),
        @as(u64, found.timer[0]),
        @as(u64, found.timer[1]),
        @as([*:0]const u8, if (found.timer[0] != found.timer[1]) "running" else "still"),
    });
    if (found.firmware != 0) {
        _ = Printf(dl, "Firmware %u.%u.%u\n", .{ found.firmware >> 24, found.firmware >> 16 & 0xff, found.firmware >> 8 & 0xff });
    }
    _ = Printf(dl, "Inbox  base %08lx size %lu read %lu write %lu\n", .{ @as(u64, found.inbox[0]), @as(u64, found.inbox[1]), @as(u64, found.inbox[2]), @as(u64, found.inbox[3]) });
    _ = Printf(dl, "Outbox base %08lx size %lu read %lu write %lu\n", .{ @as(u64, found.outbox[0]), @as(u64, found.outbox[1]), @as(u64, found.outbox[2]), @as(u64, found.outbox[3]) });
    for (found.windows, 0..) |window, n| {
        if (window[1] & 1 << 31 == 0) continue;
        _ = Printf(dl, "Window %u: %08lx..%08lx onto %08lx%08lx\n", .{
            @as(u32, @intCast(n)), @as(u64, window[0]), @as(u64, window[1] & 0x1fff_ffff), @as(u64, window[3]), @as(u64, window[2]),
        });
    }
    _ = Printf(dl, "Faults: undefined %08lx, fetch %08lx, write %08lx\n", .{ @as(u64, found.faults[0]), @as(u64, found.faults[1]), @as(u64, found.faults[2]) });
}

/// A checksum as RtgAmdCrc holds it, or why there is none.
fn printCrc(dl: *DosBase, name: [*:0]const u8, result: isize, found: *const rtg.tags.RtgAmdCrc) void {
    if (result != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "%s: no checksum, error %ld\n", .{ name, @as(i64, result) });
        return;
    }
    _ = Printf(dl, "%s: pipe %u red %04x green %04x blue %04x%s\n", .{
        name,                                                                         found.pipe, found.red, found.green, found.blue,
        @as([*:0]const u8, if (found.started != 0) " (summing switched on)" else ""),
    });
}

/// The hot-plug lines' and the controller's events, listened to the first
/// time with the watchdog armed, and printed.
fn events(sys: *ExecBase, dl: *DosBase, millis: u32, line: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    var found: rtg.tags.RtgAmdEvents = .{ .poke = line };
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_EVENTS, @bitCast(@intFromPtr(&found)));
    wb.DisarmWatchdog();
    if (result != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "No events: error %ld\n", .{@as(i64, result)});
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, "Hot-plug lines %s, %u interrupts\n", .{
        @as([*:0]const u8, if (found.lines_heard != 0) "listened to" else "not listened to"), found.hot_plug_interrupts,
    });
    for (0..rtg.tags.RTG_AMD_HOT_PLUG_LINES) |index| {
        const status = found.line_status[index];
        _ = Printf(dl, "  line %u: %s, %s, %u changes (status %08lx, control %08lx)\n", .{
            @as(u32, @intCast(index + 1)),
            @as([*:0]const u8, if (found.line_control[index] & 1 << 28 != 0) "on" else "off"),
            @as([*:0]const u8, if (status & 1 << 4 != 0) "a monitor" else "nothing"),
            found.line_changes[index],
            @as(u64, status),
            @as(u64, found.line_control[index]),
        });
    }
    _ = Printf(dl, "The board's connector looked at %u times\n", .{found.connector_looks});
    if (found.controller_heard == 0) {
        _ = Printf(dl, "The controller is not listened to: it does not run (DMCUB START starts it)\n", .{});
    } else {
        _ = Printf(dl, "Controller: %u interrupts, %u notifications - %u AUX replies, %u hot plugs, %u others\n", .{
            found.controller_interrupts, found.notes, found.aux_replies, found.hot_plug_notes, found.other_notes,
        });
    }
    return dos.RETURN_OK;
}

/// One AUX read with the watchdog armed, and printed.
fn auxRead(sys: *ExecBase, dl: *DosBase, millis: u32, request: *rtg.tags.RtgAmdAux) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_AUX, @bitCast(@intFromPtr(request)));
    wb.DisarmWatchdog();
    if (result != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "No reply: error %ld%s\n", .{
            @as(i64, result),
            @as([*:0]const u8, if (result == rtg.errors.RTGERR_NOT_SUPPORTED) " - the controller does not run (DMCUB START starts it)" else ""),
        });
        return dos.RETURN_ERROR;
    }
    const results = [_][*:0]const u8{ "replied", "an unknown failure", "a reply that could not be read", "no reply in time", "nothing plugged in", "the channel busy", "refused", "a broken reply" };
    _ = Printf(dl, "AUX %u at %lx: %s, reply %x, %u bytes\n", .{
        request.instance,
        @as(u64, request.address),
        results[@min(request.result, results.len - 1)],
        request.reply,
        request.replied,
    });
    if (request.replied != 0) {
        for (request.data[0..request.replied]) |byte| _ = Printf(dl, " %02x", .{@as(u32, byte)});
        _ = Printf(dl, "\n", .{});
    }
    _ = Printf(dl, "Channel found: control %08lx arbitration %08lx status %08lx receive %08lx\n", .{
        @as(u64, request.found[0]), @as(u64, request.found[1]), @as(u64, request.found[2]), @as(u64, request.found[3]),
    });
    _ = Printf(dl, "Channel after: control %08lx arbitration %08lx status %08lx receive %08lx\n", .{
        @as(u64, request.after[0]), @as(u64, request.after[1]), @as(u64, request.after[2]), @as(u64, request.after[3]),
    });
    return if (request.result == rtg.tags.RTG_AMD_AUX_OK) dos.RETURN_OK else dos.RETURN_WARN;
}

/// A monitor's EDID read with the watchdog armed, and printed.
fn edidRead(sys: *ExecBase, dl: *DosBase, millis: u32, request: *rtg.tags.RtgAmdEdid) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_EDID, @bitCast(@intFromPtr(request)));
    wb.DisarmWatchdog();
    if (result == rtg.errors.RTGERR_BAD_ARG) {
        _ = Printf(dl, "No connector %u\n", .{request.connector});
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, "Connector: kind %u, DDC line %u, hot-plug line %u (0 for none), %s\n", .{
        request.kind,
        if (request.ddc_line == 0xFF) @as(u32, 0) else request.ddc_line + 1,
        if (request.hpd_line == 0xFF) @as(u32, 0) else request.hpd_line + 1,
        @as([*:0]const u8, if (request.present != 0) "a monitor sensed" else "no monitor sensed"),
    });
    if (result == rtg.errors.RTGERR_NOT_SUPPORTED) {
        _ = Printf(dl, "Its monitor is not read here: a connector of another kind, or no engine for its DDC line\n", .{});
        return dos.RETURN_WARN;
    }
    if (result != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "No read: error %ld\n", .{@as(i64, result)});
        return dos.RETURN_ERROR;
    }
    const read_ok = if (request.kind == amdgpu.GPUCONNECTOR_DISPLAYPORT) request.result == rtg.tags.RTG_AMD_AUX_OK and request.answer == 0 else request.result == rtg.tags.RTG_AMD_DDC_OK;
    if (request.kind == amdgpu.GPUCONNECTOR_DISPLAYPORT) {
        const results = [_][*:0]const u8{ "read", "an unknown failure", "a reply that could not be read", "no reply in time", "nothing plugged in", "the channel busy", "refused", "a broken reply" };
        _ = Printf(dl, "EDID over AUX: %s, answer %x, %u bytes\n", .{ results[@min(request.result, results.len - 1)], request.answer, request.bytes });
        const names = [_][*:0]const u8{ "control", "arbitration", "status", "receive" };
        for (names, 0..) |name, index| {
            _ = Printf(dl, "  %-12s %08lx -> %08lx\n", .{ name, @as(u64, request.found[index]), @as(u64, request.after[index]) });
        }
    } else {
        const results = [_][*:0]const u8{ "read", "the engine taken", "no answer", "no end in time", "the engine gave up", "too long for the engine" };
        _ = Printf(dl, "EDID: %s, %u bytes\n", .{ results[@min(request.result, results.len - 1)], request.bytes });
        const names = [_][*:0]const u8{ "control", "arbitration", "status", "line status", "speed", "setup", "time base", "pads" };
        for (names, 0..) |name, index| {
            _ = Printf(dl, "  %-12s %08lx -> %08lx\n", .{ name, @as(u64, request.found[index]), @as(u64, request.after[index]) });
        }
    }
    if (request.bytes < 128) return if (read_ok) dos.RETURN_OK else dos.RETURN_WARN;
    const edid = request.edid[0..request.bytes];
    // The maker's three letters, five bits each from 'A' less one; the
    // product's number, little-endian; the year from 1990.
    const maker: u16 = @as(u16, edid[8]) << 8 | edid[9];
    const letters = [4]u8{ @intCast('@' + (maker >> 10 & 0x1f)), @intCast('@' + (maker >> 5 & 0x1f)), @intCast('@' + (maker & 0x1f)), 0 };
    _ = Printf(dl, "Monitor %s %04x, made %u, EDID %u.%u, %u extension(s)\n", .{
        @as([*:0]const u8, @ptrCast(&letters)),
        @as(u32, edid[10]) | @as(u32, edid[11]) << 8,
        @as(u32, edid[17]) + 1990,
        @as(u32, edid[18]),
        @as(u32, edid[19]),
        @as(u32, edid[126]),
    });
    var row: usize = 0;
    while (row < edid.len) : (row += 16) {
        _ = Printf(dl, "  %03x:", .{@as(u32, @intCast(row))});
        for (edid[row..][0..16]) |byte| _ = Printf(dl, " %02x", .{@as(u32, byte)});
        _ = Printf(dl, "\n", .{});
    }
    return if (read_ok) dos.RETURN_OK else dos.RETURN_WARN;
}

/// The picture's checksum read with the watchdog armed, and printed.
fn checksum(sys: *ExecBase, dl: *DosBase, millis: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    var found: rtg.tags.RtgAmdCrc = .{};
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&found)));
    wb.DisarmWatchdog();
    printCrc(dl, "Picture", result, &found);
    return if (result == rtg.errors.RTGERR_OK) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// The display's pipe taken down and up again (RTGCTRL_AMD_PIPE), the
/// watchdog armed, the picture's checksum read before and after; printed.
fn pipeCycle(sys: *ExecBase, dl: *DosBase, millis: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    var before: rtg.tags.RtgAmdCrc = .{};
    var crc_before = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&before)));
    // A picture that changes by itself - a clock's seconds - is waited
    // for to change and then to hold, so that the pipe is down and up
    // again before it changes next.
    var waited: u32 = 0;
    var changed = false;
    var held: u32 = 0;
    while (crc_before == rtg.errors.RTGERR_OK and waited < change_wait_ticks) : (waited += 1) {
        dl.Delay(1);
        var now: rtg.tags.RtgAmdCrc = .{};
        crc_before = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&now)));
        if (now.red == before.red and now.green == before.green and now.blue == before.blue) {
            held += 1;
            if (changed and held == held_ticks) break;
            continue;
        }
        before = now;
        changed = true;
        held = 0;
    }
    var request: rtg.tags.RtgAmdPipe = .{};
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_PIPE, @bitCast(@intFromPtr(&request)));
    var after: rtg.tags.RtgAmdCrc = .{};
    const crc_after = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&after)));
    wb.DisarmWatchdog();
    const stages = [_][*:0]const u8{
        "nothing done",                 "the stream taken",     "the monitor muted",
        "the timing generator stopped", "the front end let go", "the PHY off",
        "down",                         "the clocks on",        "the timing generator started",
        "the stream set up",            "the PHY on",           "up",
    };
    _ = Printf(dl, "Cycle: error %ld, %s\n", .{ @as(i64, result), stages[@min(request.stage, stages.len - 1)] });
    if (request.stage >= rtg.tags.RTG_AMD_PIPE_TAKEN) {
        const link: [*:0]const u8 = if (request.link == rtg.tags.RTG_AMD_LINK_HDMI) "HDMI" else "DVI";
        const bits = [_]u32{ 8, 10, 12, 16 };
        _ = Printf(dl, "Pipe %u, front end %u, back end %u, PHY %c: %s, %u bits a colour, pixels %u kHz, symbols %u kHz; transmitter table revision %u\n", .{
            request.pipe,                 request.front,                request.back,      'A' + request.phy,
            link,                         bits[request.deep_color & 3], request.pixel_khz, request.symbol_khz,
            request.transmitter_revision,
        });
        _ = Printf(dl, "Down and up in %u us\n", .{request.down_us});
        _ = Printf(dl, "         timing   clocks   front    fifo     back     on       hdmi     gc\n", .{});
        printPipe(dl, "before", &request.before);
        if (request.stage > rtg.tags.RTG_AMD_PIPE_TAKEN) printPipe(dl, "down", &request.down);
        if (request.stage > rtg.tags.RTG_AMD_PIPE_DOWN) printPipe(dl, "after", &request.after);
    }
    if (waited < change_wait_ticks) {
        _ = Printf(dl, "The picture changed by itself and held %u ms after %u ms, the pipe was taken down then\n", .{ held_ticks * 20, (waited + 1) * 20 });
    } else if (changed) {
        _ = Printf(dl, "The picture changed by itself and did not hold %u ms in %u ms\n", .{ held_ticks * 20, change_wait_ticks * 20 });
    } else {
        _ = Printf(dl, "The picture did not change by itself in %u ms\n", .{change_wait_ticks * 20});
    }
    printCrc(dl, "Picture before", crc_before, &before);
    printCrc(dl, "Picture after ", crc_after, &after);
    if (crc_before == rtg.errors.RTGERR_OK and crc_after == rtg.errors.RTGERR_OK) {
        const same = before.red == after.red and before.green == after.green and before.blue == after.blue;
        _ = Printf(dl, "The picture is %s\n", .{@as([*:0]const u8, if (same) "unchanged" else "CHANGED")});
    }
    return if (result == rtg.errors.RTGERR_OK) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// MODES: the board put in each mode it offers, in turn, a picture of
/// the mode's own shown in it, what the set did and the checksum printed,
/// each held `seconds`; then back in the mode it was in, showing
/// what it showed.
fn everyMode(sys: *ExecBase, dl: *DosBase, millis: u32, seconds: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();

    // The board's line applied as it stands: its modes made again.
    var line: rtg.RtgSettings = .{};
    _ = rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));
    _ = rb.SetBoardSettings(board, &line);
    wb.FeedWatchdog();
    var list: [modes_most]rtg.RtgMode = undefined;
    const count = @min(rb.GetBoardModes(board, &list, modes_most), modes_most);
    var was: u32 = 0;
    for (list[0..count]) |*one| {
        if (one.flags & rtg.modes.RTGMF_CURRENT != 0) was = one.id;
    }
    const before = rb.BoardDisplayBitMap(board);
    _ = Printf(dl, "%u modes\n", .{count});

    var failed: u32 = 0;
    // A picture is given back once another is shown: the board does not
    // let go of the one it reads.
    var shown_before: ?*rtg.RtgBitMap = null;
    defer if (shown_before) |last| rb.FreeBitMap(last);
    for (list[0..count]) |*one| {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
        const name: [*:0]const u8 = @ptrCast(&one.name);
        _ = Printf(dl, "%-14s %4ux%-4u %3u.%03u Hz %6u kHz: ", .{ name, one.width, one.height, one.refresh_mhz / 1000, one.refresh_mhz % 1000, one.pixel_clock_hz / 1000 });
        const picture = rb.AllocBitMap(board, one.width, one.height, @intFromEnum(one.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse {
            _ = Printf(dl, "no room for its picture\n", .{});
            failed += 1;
            continue;
        };
        bars(picture);
        _ = rb.RefreshRect(picture, null);

        var account_before: rtg.tags.RtgAmdPipe = .{};
        _ = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_MODE, @bitCast(@intFromPtr(&account_before)));
        const band = [_]rtg.RtgBand{.{ .bitmap = picture }};
        const shown = rb.ShowBoard(board, one.id, &band, band.len);
        wb.FeedWatchdog();
        if (shown == rtg.errors.RTGERR_OK) {
            if (shown_before) |old| rb.FreeBitMap(old);
            shown_before = picture;
        } else {
            rb.FreeBitMap(picture);
        }
        var account: rtg.tags.RtgAmdPipe = .{};
        _ = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_MODE, @bitCast(@intFromPtr(&account)));
        if (shown != rtg.errors.RTGERR_OK) {
            _ = Printf(dl, "not shown: %s, set stopped at stage %u\n", .{ rb.RtgErrorText(shown), account.stage });
            failed += 1;
            continue;
        }
        if (sameAccount(&account_before, &account)) {
            _ = Printf(dl, "the mode the pipe scanned, not set; ", .{});
        } else {
            const link: [*:0]const u8 = if (account.link == rtg.tags.RTG_AMD_LINK_HDMI) "HDMI" else "DVI";
            _ = Printf(dl, "set on %s at %u kHz, down %u us%s; ", .{
                link,
                account.pixel_khz,
                account.down_us,
                @as([*:0]const u8, if (account.underflow & rtg.tags.RTG_AMD_UNDERFLOW_FETCHER != 0) ", the fetcher ran short" else if (account.underflow != 0) ", the output ran short" else ""),
            });
            if (account.underflow != 0) failed += 1;
        }
        // Read a few frames on, then again more than a frame later.
        var first: rtg.tags.RtgAmdCrc = .{};
        var second: rtg.tags.RtgAmdCrc = .{};
        dl.Delay(8);
        const read_first = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&first)));
        dl.Delay(3);
        const read_second = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&second)));
        if (read_first != rtg.errors.RTGERR_OK or read_second != rtg.errors.RTGERR_OK) {
            _ = Printf(dl, "no checksum\n", .{});
        } else {
            const same = first.red == second.red and first.green == second.green and first.blue == second.blue;
            _ = Printf(dl, "checksum %04x %04x %04x%s\n", .{ second.red, second.green, second.blue, @as([*:0]const u8, if (same) "" else " CHANGING") });
            if (!same) failed += 1;
        }
        hold(dl, wb, 2 * seconds);
    }

    // The mode it was in, showing what it showed; the last picture is
    // given back after.
    if (before) |picture| {
        const band = [_]rtg.RtgBand{.{ .bitmap = picture }};
        const back = rb.ShowBoard(board, was, &band, band.len);
        if (back != rtg.errors.RTGERR_OK) _ = Printf(dl, "Not put back: %s\n", .{rb.RtgErrorText(back)});
    }
    _ = Printf(dl, "%u of %u modes failed\n", .{ failed, count });
    return if (failed == 0) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// The most modes MODES goes through.
const modes_most = 32;

/// Whether two of the board's accounts of a mode set are the same: no
/// set came between them.
fn sameAccount(a: *const rtg.tags.RtgAmdPipe, b: *const rtg.tags.RtgAmdPipe) bool {
    const left: [*]const u8 = @ptrCast(a);
    const right: [*]const u8 = @ptrCast(b);
    for (0..@sizeOf(rtg.tags.RtgAmdPipe)) |index| {
        if (left[index] != right[index]) return false;
    }
    return true;
}

/// A picture of a mode's: eight bars of colour across it and a white
/// frame round its edge, a pixel wide. In 32 bits a pixel only; another
/// format is left as it is.
fn bars(picture: *rtg.RtgBitMap) void {
    if (picture.format != .bgra32) return;
    const colours = [_]u32{ 0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00, 0xFF00FF, 0xFF0000, 0x0000FF, 0x202020 };
    const pixels = picture.pixels orelse return;
    var row: u32 = 0;
    while (row < picture.height) : (row += 1) {
        const line: [*]u32 = @ptrCast(@alignCast(pixels + @as(usize, row) * picture.pitch));
        var column: u32 = 0;
        while (column < picture.width) : (column += 1) {
            const edge = row == 0 or row == picture.height - 1 or column == 0 or column == picture.width - 1;
            line[column] = 0xFF000000 | (if (edge) 0xFFFFFF else colours[@as(usize, column) * colours.len / picture.width]);
        }
    }
}

/// `length` of the display engine's registers from `first` on, counted
/// from its address `segment`, the watchdog armed; printed eight a line.
fn dump(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32, segment: u32, first: u32, length: u32) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or segment >= block.count) {
        _ = Printf(dl, "The device has no display engine's address %u\n", .{segment});
        return dos.RETURN_WARN;
    }
    const words = @min(length, dump_most);
    const end = (@as(u64, block.addresses[segment]) + first + words) * 4;
    if (end > info.registers_bytes) {
        _ = Printf(dl, "Words %u to %u from address %u are past the registers' end\n", .{ first, first + words, segment });
        return dos.RETURN_WARN;
    }
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    var index: u32 = 0;
    while (index < words) : (index += 1) {
        if (index % 8 == 0) _ = Printf(dl, "%s0x%04x:", .{ @as([*:0]const u8, if (index == 0) "" else "\n"), first + index });
        const at: usize = @intCast(info.registers + (@as(u64, block.addresses[segment]) + first + index) * 4);
        _ = Printf(dl, " %08lx", .{@as(u64, reg(at).*)});
    }
    _ = Printf(dl, "\n", .{});
    return dos.RETURN_OK;
}

/// The most registers DUMP prints.
const dump_most: u32 = 512;

/// How long CYCLE waits for a picture to change by itself and then to
/// hold, in ticks of 20 ms.
const change_wait_ticks: u32 = 100;
const held_ticks: u32 = 5;

/// The pipe's registers as RtgAmdPipe holds them, on one line.
fn printPipe(dl: *DosBase, name: [*:0]const u8, registers: *const [rtg.tags.RTG_AMD_PIPE_REGISTERS]u32) void {
    _ = Printf(dl, "%-8s", .{name});
    for (registers) |register| _ = Printf(dl, " %08lx", .{@as(u64, register)});
    _ = Printf(dl, "\n", .{});
}

/// A clock's levels on one line, in MHz.
fn printLevels(dl: *DosBase, name: [*:0]const u8, levels: []const u32) void {
    _ = Printf(dl, "%-28s", .{name});
    if (levels.len == 0) _ = Printf(dl, " none", .{});
    for (levels) |level| _ = Printf(dl, " %u", .{level});
    _ = Printf(dl, " MHz\n", .{});
}

/// What a connector's kind is called.
fn kindName(kind: u32) [*:0]const u8 {
    return switch (kind) {
        amdgpu.GPUCONNECTOR_DVI => "DVI",
        amdgpu.GPUCONNECTOR_HDMI => "HDMI",
        amdgpu.GPUCONNECTOR_DISPLAYPORT => "DP",
        amdgpu.GPUCONNECTOR_EDP => "eDP",
        amdgpu.GPUCONNECTOR_USBC => "USB-C",
        else => "other",
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const ab: *AMDGPUBase = @ptrCast(sys.OpenResource(amdgpu.AMDGPUNAME) orelse {
        _ = Printf(dl, "No %s\n", .{amdgpu.AMDGPUNAME});
        return dos.RETURN_FAIL;
    });
    var info: amdgpu.GPUInfo = .{};
    if (!ab.GetGPUInfo(&info)) {
        _ = Printf(dl, "No AMD graphics device\n", .{});
        return dos.RETURN_WARN;
    }
    if (argv[arg_bios] != 0) return bios(dl, ab);
    if (argv[arg_dmcub] != 0 and argv[arg_start] == 0) return controller(sys, dl, null);
    if (argv[arg_watchdog] == 0) {
        _ = Printf(dl, "%s: WATCHDOG is required for a step that writes to the device\n", .{COMMAND_NAME});
        return dos.RETURN_ERROR;
    }
    const millis: u32 = @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[arg_watchdog])).*));
    if (argv[arg_clocks] != 0) return clocks(sys, dl, millis);
    if (argv[arg_dmcub] != 0) return controller(sys, dl, millis);
    if (argv[arg_crc] != 0) return checksum(sys, dl, millis);
    if (argv[arg_events] != 0) return events(sys, dl, millis, if (argv[arg_line] != 0) number(argv[arg_line]) else 0);
    if (argv[arg_aux] != 0) {
        var request: rtg.tags.RtgAmdAux = .{
            .instance = number(argv[arg_aux]),
            .kind = if (argv[arg_i2c] != 0) rtg.tags.RTG_AMD_AUX_I2C else rtg.tags.RTG_AMD_AUX_DPCD,
            .address = number(argv[arg_address]),
            .length = if (argv[arg_length] != 0) number(argv[arg_length]) else 16,
            .through = if (argv[arg_controller] != 0) rtg.tags.RTG_AMD_AUX_BY_CONTROLLER else rtg.tags.RTG_AMD_AUX_BY_ENGINE,
        };
        return auxRead(sys, dl, millis, &request);
    }
    if (argv[arg_edid] != 0) {
        var request: rtg.tags.RtgAmdEdid = .{};
        if (argv[arg_connector] != 0) request.connector = number(argv[arg_connector]);
        return edidRead(sys, dl, millis, &request);
    }
    if (argv[arg_cycle] != 0) return pipeCycle(sys, dl, millis);
    if (argv[arg_modes] != 0 and argv[arg_sleep] == 0) return everyMode(sys, dl, millis, if (argv[arg_hold] != 0) number(argv[arg_hold]) else 2);
    if (argv[arg_range] != 0) return rangeCheck(sys, dl, millis);
    if (argv[arg_pointer] != 0) return pointerCheck(sys, dl, ab, info, millis);
    if (argv[arg_sleep] != 0) return asleepFor(sys, dl, ab, info, millis, number(argv[arg_sleep]), argv[arg_modes] != 0);
    if (argv[arg_dump] != 0) {
        const length = if (argv[arg_length] != 0) number(argv[arg_length]) else 16;
        const segment = if (argv[arg_segment] != 0) number(argv[arg_segment]) else 2;
        return dump(sys, dl, ab, info, millis, segment, number(argv[arg_dump]), length);
    }
    if (argv[arg_frames] != 0 or argv[arg_flip] != 0) {
        const pipe = number(argv[arg_pipe]);
        const fetcher = number(argv[arg_fetcher]);
        return display(sys, dl, ab, info, millis, pipe, fetcher, argv[arg_flip] != 0);
    }
    var security: amdgpu.GPUBlock = .{};
    var video: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_SECURITY, 0, &security) or !ab.FindGPUBlock(amdgpu.GPUBLOCK_VIDEO, 0, &video)) {
        _ = Printf(dl, "The device %04x:%04x names no security processor or no video decoder\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "Device %04x:%04x: security processor %u.%u.%u, video decoder %u.%u.%u\n", .{
        info.vendor,                 info.device,           @as(u32, security.major), @as(u32, security.minor),
        @as(u32, security.revision), @as(u32, video.major), @as(u32, video.minor),    @as(u32, video.revision),
    });

    const toc_name = Name.of("psp_", security, "_toc.bin");
    const firmware_name = Name.of("vcn_", video, ".bin");
    const toc_path: [*:0]const u8 = if (argv[arg_toc] != 0) @ptrFromInt(argv[arg_toc]) else toc_name.string();
    const firmware_path: [*:0]const u8 = if (argv[arg_firmware] != 0) @ptrFromInt(argv[arg_firmware]) else firmware_name.string();
    const toc = readFile(sys, dl, toc_path) orelse return dos.RETURN_ERROR;
    defer sys.FreeVec(toc.ptr);
    const firmware = readFile(sys, dl, firmware_path) orelse return dos.RETURN_ERROR;
    defer sys.FreeVec(firmware.ptr);
    _ = Printf(dl, "%s: %lu bytes\n%s: %lu bytes\n", .{ toc_path, @as(u64, toc.len), firmware_path, @as(u64, firmware.len) });

    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "No %s\n", .{watchdog.WATCHDOGNAME});
        return dos.RETURN_FAIL;
    });
    if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
        _ = Printf(dl, "The watchdog refuses %u ms\n", .{millis});
        return dos.RETURN_FAIL;
    }
    defer wb.DisarmWatchdog();
    _ = Printf(dl, "Watchdog armed: %u ms\n", .{millis});

    if (!ab.StartGPUSecurity(toc.ptr, @intCast(toc.len))) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The security processor is not ready: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    _ = Printf(dl, "The security processor is ready\n", .{});

    var address: u64 = 0;
    if (!ab.LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO, firmware.ptr, @intCast(firmware.len), &address)) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The video decoder's firmware is not loaded: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    _ = Printf(dl, "The video decoder's firmware is at 0x%lx\n", .{address});
    return dos.RETURN_OK;
}

fn number(arg: usize) u32 {
    if (arg == 0) return 0;
    return @intCast(@max(0, @as(*const i32, @ptrFromInt(arg)).*));
}

// --- the display ---------------------------------------------------------------------

/// The display engine's registers, and the pipe and fetcher tried.
const Display = struct {
    registers: usize,
    segment: u32,
    pipe: u32,
    fetcher: u32,

    fn at(display_: Display, offset: u32) *volatile u32 {
        return reg(display_.registers + @as(usize, display_.segment + offset) * 4);
    }

    fn otg(display_: Display, offset: u32) *volatile u32 {
        return display_.at(offset + dcn.OTG_STRIDE * display_.pipe);
    }

    fn hubp(display_: Display, offset: u32) *volatile u32 {
        return display_.at(offset + dcn.HUBP_STRIDE * display_.fetcher);
    }

    /// The address the fetcher is told to read, and the one it reads.
    fn told(display_: Display) u64 {
        return @as(u64, display_.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH).* & dcn.ADDRESS_HIGH_MASK) << 32 |
            display_.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS).*;
    }

    fn reading(display_: Display) u64 {
        return @as(u64, display_.hubp(dcn.DCSURF_SURFACE_EARLIEST_INUSE_HIGH).* & dcn.ADDRESS_HIGH_MASK) << 32 |
            display_.hubp(dcn.DCSURF_SURFACE_EARLIEST_INUSE).*;
    }
};

/// The pipe's interrupt at each frame: counted, acknowledged, and the
/// task told.
const Frames = struct {
    sys: *ExecBase,
    display: Display,
    count: u32 = 0,
    came: exec.Waitable = .{},
    server: exec.Interrupt = .{},
};

fn frameServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const frames: *Frames = @ptrCast(@alignCast(data.?));
    const status = frames.display.otg(dcn.OTG_GLOBAL_SYNC_STATUS);
    status.* = status.* | dcn.VUPDATE_NO_LOCK_EVENT_CLEAR;
    @atomicStore(u32, &frames.count, frames.count +% 1, .release);
    frames.sys.SignalWaitable(&frames.came);
    return 1;
}

/// The server on and the interrupt switched on at the pipe; false where
/// the resource takes no server.
fn hook(ab: *AMDGPUBase, frames: *Frames) bool {
    frames.server = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = COMMAND_NAME },
        .data = frames,
        .code = &frameServer,
    };
    if (!ab.AddGPUIntServer(amdgpu.GPUINT_CLIENT_DISPLAY, amdgpu.GPUINT_DISPLAY_UPDATE + frames.display.pipe, &frames.server)) return false;
    const status = frames.display.otg(dcn.OTG_GLOBAL_SYNC_STATUS);
    frames.sys.Disable();
    status.* = status.* | dcn.VUPDATE_NO_LOCK_EVENT_CLEAR | dcn.VUPDATE_NO_LOCK_INT_EN;
    frames.sys.Enable();
    return true;
}

fn unhook(ab: *AMDGPUBase, frames: *Frames) void {
    const status = frames.display.otg(dcn.OTG_GLOBAL_SYNC_STATUS);
    frames.sys.Disable();
    status.* = status.* & ~dcn.VUPDATE_NO_LOCK_INT_EN | dcn.VUPDATE_NO_LOCK_EVENT_CLEAR;
    frames.sys.Enable();
    ab.RemGPUIntServer(&frames.server);
}

/// The E-clock in microseconds.
fn micros(tb: *TimerBase) u64 {
    var value: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&value);
    const count = value.toTicks();
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}

/// Half-seconds waited, the watchdog fed after each.
/// SLEEP: the board's monitor asleep for `seconds`, then woken, the
/// picture's checksum and pipe 0's count of frames read before, while
/// asleep and after; with `moving`, shown in another mode and back while
/// asleep.
fn asleepFor(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32, seconds: u32, moving: bool) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 3) {
        _ = Printf(dl, "The device %04x:%04x names no display engine\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = 0, .fetcher = 0 };
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();

    printChecksum(dl, rb, board, "before");
    printFrames(dl, engine, "before");
    const slept = rb.SetBoardPower(board, rtg.boards.RTGPWR_ASLEEP);
    wb.FeedWatchdog();
    _ = Printf(dl, "asleep: %s, the board says %s\n", .{ powerAnswer(rb, slept), powerName(powerOf(rb, board)) });
    dl.Delay(8);
    printChecksum(dl, rb, board, "asleep");
    printFrames(dl, engine, "asleep");
    hold(dl, wb, 2 * seconds);
    printFrames(dl, engine, "later");
    var moved = true;
    if (moving) moved = anotherMode(dl, rb, board, wb);
    const woken = rb.SetBoardPower(board, rtg.boards.RTGPWR_ON);
    wb.FeedWatchdog();
    _ = Printf(dl, "awake: %s, the board says %s\n", .{ powerAnswer(rb, woken), powerName(powerOf(rb, board)) });
    dl.Delay(8);
    printChecksum(dl, rb, board, "after");
    printFrames(dl, engine, "after");
    if (slept != @as(i32, @intCast(rtg.boards.RTGPWR_ASLEEP)) or woken != @as(i32, @intCast(rtg.boards.RTGPWR_ON))) return dos.RETURN_WARN;
    return if (moved) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// The board shown in the first mode it offers but the one it is in,
/// with a picture of bars, the set printed and the frames counted; then
/// back in its mode, showing what it showed. Whether both shows went.
fn anotherMode(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, wb: *WatchdogBase) bool {
    var list: [modes_most]rtg.RtgMode = undefined;
    const count = @min(rb.GetBoardModes(board, &list, modes_most), modes_most);
    var was: ?*const rtg.RtgMode = null;
    var other: ?*const rtg.RtgMode = null;
    for (list[0..count]) |*one| {
        if (one.flags & rtg.modes.RTGMF_CURRENT != 0) was = one else if (other == null) other = one;
    }
    const from = was orelse return false;
    const to = other orelse {
        _ = Printf(dl, "no other mode\n", .{});
        return false;
    };
    const before = rb.BoardDisplayBitMap(board) orelse return false;
    const picture = rb.AllocBitMap(board, to.width, to.height, @intFromEnum(to.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse {
        _ = Printf(dl, "no room for a picture of %ux%u\n", .{ to.width, to.height });
        return false;
    };
    bars(picture);
    _ = rb.RefreshRect(picture, null);
    const band = [_]rtg.RtgBand{.{ .bitmap = picture }};
    const shown = rb.ShowBoard(board, to.id, &band, band.len);
    wb.FeedWatchdog();
    var account: rtg.tags.RtgAmdPipe = .{};
    _ = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_MODE, @bitCast(@intFromPtr(&account)));
    const name: [*:0]const u8 = @ptrCast(&to.name);
    _ = Printf(dl, "asleep, shown in %s: %s, set at %u kHz, the board says %s\n", .{ name, rb.RtgErrorText(shown), account.pixel_khz, powerName(powerOf(rb, board)) });
    const back_band = [_]rtg.RtgBand{.{ .bitmap = before }};
    const back = rb.ShowBoard(board, from.id, &back_band, back_band.len);
    wb.FeedWatchdog();
    _ = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_MODE, @bitCast(@intFromPtr(&account)));
    const back_name: [*:0]const u8 = @ptrCast(&from.name);
    _ = Printf(dl, "asleep, back in %s: %s, set at %u kHz, the board says %s\n", .{ back_name, rb.RtgErrorText(back), account.pixel_khz, powerName(powerOf(rb, board)) });
    // Shown no longer, the bars are given back.
    if (shown == rtg.errors.RTGERR_OK and back == rtg.errors.RTGERR_OK) rb.FreeBitMap(picture);
    return shown == rtg.errors.RTGERR_OK and back == rtg.errors.RTGERR_OK;
}

/// The picture's checksum, read twice a few frames apart, on a line.
fn printChecksum(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, when: [*:0]const u8) void {
    var first: rtg.tags.RtgAmdCrc = .{};
    var second: rtg.tags.RtgAmdCrc = .{};
    const read_first = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&first)));
    dl.Delay(3);
    const read_second = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&second)));
    if (read_first != rtg.errors.RTGERR_OK or read_second != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "%-7s no checksum\n", .{when});
        return;
    }
    const same = first.red == second.red and first.green == second.green and first.blue == second.blue;
    _ = Printf(dl, "%-7s checksum %04x %04x %04x%s\n", .{ when, second.red, second.green, second.blue, @as([*:0]const u8, if (same) "" else " CHANGING") });
}

/// A still picture of bars shown on the board in the mode it is in, and
/// the picture shown before, which `end` shows again.
const Still = struct {
    rb: *RtgBase,
    board: *rtg.RtgBoard,
    mode_id: u32,
    before: *rtg.RtgBitMap,
    picture: *rtg.RtgBitMap,

    fn begin(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) ?Still {
        var list: [modes_most]rtg.RtgMode = undefined;
        const count = @min(rb.GetBoardModes(board, &list, modes_most), modes_most);
        var current: ?*const rtg.RtgMode = null;
        for (list[0..count]) |*one| {
            if (one.flags & rtg.modes.RTGMF_CURRENT != 0) current = one;
        }
        const shown = current orelse {
            _ = Printf(dl, "The board is in no mode\n", .{});
            return null;
        };
        const before = rb.BoardDisplayBitMap(board) orelse {
            _ = Printf(dl, "The board shows no picture\n", .{});
            return null;
        };
        const picture = rb.AllocBitMap(board, shown.width, shown.height, @intFromEnum(shown.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse {
            _ = Printf(dl, "No room for a picture of %ux%u\n", .{ shown.width, shown.height });
            return null;
        };
        bars(picture);
        _ = rb.RefreshRect(picture, null);
        const band = [_]rtg.RtgBand{.{ .bitmap = picture }};
        if (rb.ShowBoard(board, shown.id, &band, band.len) != rtg.errors.RTGERR_OK) {
            rb.FreeBitMap(picture);
            _ = Printf(dl, "The bars were not shown\n", .{});
            return null;
        }
        return .{ .rb = rb, .board = board, .mode_id = shown.id, .before = before, .picture = picture };
    }

    /// The picture before shown again, and the bars freed once they are
    /// no longer shown.
    fn end(still: Still) void {
        const band = [_]rtg.RtgBand{.{ .bitmap = still.before }};
        if (still.rb.ShowBoard(still.board, still.mode_id, &band, band.len) == rtg.errors.RTGERR_OK) still.rb.FreeBitMap(still.picture);
    }
};

/// RANGE: a still picture's checksum in full range, limited and full
/// again.
fn rangeCheck(sys: *ExecBase, dl: *DosBase, millis: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    var info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    if (info.caps & rtg.boards.RTGBC_COLOR_RANGE == 0) {
        _ = Printf(dl, "The board does not send its colours in another range\n", .{});
        return dos.RETURN_WARN;
    }
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    const still = Still.begin(dl, rb, board) orelse return dos.RETURN_FAIL;
    defer still.end();
    wb.FeedWatchdog();
    var line: rtg.RtgSettings = .{};
    _ = rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));
    const kept = line;

    dl.Delay(8);
    printChecksum(dl, rb, board, "full");
    line.flags |= rtg.RTGSET_RANGE | rtg.RTGSET_LIMITED_RANGE;
    _ = rb.SetBoardSettings(board, &line);
    wb.FeedWatchdog();
    dl.Delay(8);
    printChecksum(dl, rb, board, "limited");
    line.flags &= ~@as(u32, rtg.RTGSET_LIMITED_RANGE);
    _ = rb.SetBoardSettings(board, &line);
    wb.FeedWatchdog();
    dl.Delay(8);
    printChecksum(dl, rb, board, "full");

    var back = kept;
    _ = rb.SetBoardSettings(board, &back);
    return dos.RETURN_OK;
}

/// Pipe 0's cursor, a fetcher's stride apart: its control - bit 0 shown
/// - its place and its hot spot.
const cursor_control = 0x0678;
const cursor_position = 0x067c;
const cursor_hot_spot = 0x067d;

/// POINTER: a still picture's checksum with the pointer hidden, at
/// three places and hidden again, and what the cursor is told at each.
fn pointerCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 3) {
        _ = Printf(dl, "The device %04x:%04x names no display engine\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = 0, .fetcher = 0 };
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const was_x = board.pointer_x;
    const was_y = board.pointer_y;
    const was_shown = board.info.flags & rtg.boards.RTGBF_POINTER != 0;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    const still = Still.begin(dl, rb, board) orelse return dos.RETURN_FAIL;
    defer still.end();
    defer {
        rb.MoveBoardPointer(board, was_x, was_y);
        _ = rb.ShowBoardPointer(board, was_shown);
    }

    _ = rb.ShowBoardPointer(board, false);
    pointerAt(dl, rb, board, engine, "hidden");
    const places = [_][2]i32{ .{ 200, 150 }, .{ 900, 500 }, .{ -5, -5 } };
    for (places) |place| {
        rb.MoveBoardPointer(board, place[0], place[1]);
        _ = rb.ShowBoardPointer(board, true);
        wb.FeedWatchdog();
        var name: [24]u8 = undefined;
        const stream = exec.fmtStream(.{ place[0], place[1] });
        _ = sys.RawDoFmt("%d,%d", &stream, null, &name);
        pointerAt(dl, rb, board, engine, @ptrCast(&name));
    }
    _ = rb.ShowBoardPointer(board, false);
    wb.FeedWatchdog();
    pointerAt(dl, rb, board, engine, "hidden");
    return dos.RETURN_OK;
}

/// The checksum once the pipe has taken the pointer, and what its cursor
/// is told.
fn pointerAt(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, engine: Display, when: [*:0]const u8) void {
    dl.Delay(5);
    printChecksum(dl, rb, board, when);
    const control = engine.hubp(cursor_control).*;
    const position = engine.hubp(cursor_position).*;
    const hot_spot = engine.hubp(cursor_hot_spot).*;
    _ = Printf(dl, "        cursor %s at %u,%u, hot spot %u,%u\n", .{
        @as([*:0]const u8, if (control & 1 != 0) "shown" else "hidden"),
        position >> 16 & 0x3fff,
        position & 0x3fff,
        hot_spot >> 16 & 0xff,
        hot_spot & 0xff,
    });
}

/// The pipe's count of frames, read twice 100 ms apart, on a line.
fn printFrames(dl: *DosBase, engine: Display, when: [*:0]const u8) void {
    const first = engine.otg(dcn.OTG_STATUS_FRAME_COUNT).*;
    dl.Delay(5);
    const second = engine.otg(dcn.OTG_STATUS_FRAME_COUNT).*;
    _ = Printf(dl, "%-7s frame %u, %u frames in 100 ms\n", .{ when, second, (second -% first) & frame_count_mask });
}

/// The bits a pipe's count of frames has.
const frame_count_mask: u32 = 0xff_ffff;

/// The power state the board says it is in.
fn powerOf(rb: *RtgBase, board: *rtg.RtgBoard) u32 {
    var info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    return info.power;
}

fn powerName(state: u32) [*:0]const u8 {
    return switch (state) {
        rtg.boards.RTGPWR_ON => "on",
        rtg.boards.RTGPWR_BLANK => "blank",
        rtg.boards.RTGPWR_ASLEEP => "asleep",
        else => "?",
    };
}

/// What SetBoardPower answered: the state reached, or the error's text.
fn powerAnswer(rb: *RtgBase, answer: i32) [*:0]const u8 {
    if (answer < 0) return rb.RtgErrorText(answer);
    return powerName(@intCast(answer));
}

fn hold(dl: *DosBase, wb: *WatchdogBase, halves: u32) void {
    for (0..halves) |_| {
        dl.Delay(25);
        wb.FeedWatchdog();
    }
}

/// FRAMES or FLIP, the watchdog armed for both.
fn display(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32, pipe: u32, fetcher: u32, flipping: bool) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 3) {
        _ = Printf(dl, "The device %04x:%04x names no display engine\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = pipe, .fetcher = fetcher };
    _ = Printf(dl, "Display engine %u.%u.%u: pipe %u, frame %u, interrupts %x; fetcher %u reads 0x%lx, told 0x%lx, flip control %x\n", .{
        @as(u32, block.major),                  @as(u32, block.minor),                    @as(u32, block.revision),
        pipe,                                   engine.otg(dcn.OTG_STATUS_FRAME_COUNT).*, engine.otg(dcn.OTG_GLOBAL_SYNC_STATUS).*,
        fetcher,                                engine.reading(),                         engine.told(),
        engine.hubp(dcn.DCSURF_FLIP_CONTROL).*,
    });

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    const tb: *TimerBase = @ptrCast(@alignCast(clock.node.device.?));

    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "No %s\n", .{watchdog.WATCHDOGNAME});
        return dos.RETURN_FAIL;
    });
    if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
        _ = Printf(dl, "The watchdog refuses %u ms\n", .{millis});
        return dos.RETURN_FAIL;
    }
    defer wb.DisarmWatchdog();
    _ = Printf(dl, "Watchdog armed: %u ms\n", .{millis});
    _ = dl.Flush(dl.Output());

    var frames = Frames{ .sys = sys, .display = engine };
    if (!hook(ab, &frames)) {
        wb.FeedWatchdog();
        _ = Printf(dl, "No server for the pipe's interrupt: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    defer unhook(ab, &frames);
    wb.FeedWatchdog();
    _ = Printf(dl, "Its interrupt is on: %x\n", .{engine.otg(dcn.OTG_GLOBAL_SYNC_STATUS).*});
    _ = dl.Flush(dl.Output());

    if (!flipping) {
        const first_frame = engine.otg(dcn.OTG_STATUS_FRAME_COUNT).*;
        const first_count = @atomicLoad(u32, &frames.count, .acquire);
        const started = micros(tb);
        hold(dl, wb, 6);
        const took = micros(tb) - started;
        const counted = @atomicLoad(u32, &frames.count, .acquire) - first_count;
        const scanned = engine.otg(dcn.OTG_STATUS_FRAME_COUNT).* -% first_frame;
        _ = Printf(dl, "%u interrupts and %u frames in %lu ms: %lu a second\n", .{
            counted, scanned, took / 1000, @as(u64, counted) * 1_000_000 / @max(took, 1),
        });
        return if (counted == 0) dos.RETURN_ERROR else dos.RETURN_OK;
    }
    return flipOnce(sys, dl, ab, tb, wb, &frames);
}

/// What one flip took.
const Flip = struct { frames: u32, micros: u64, pending: bool, reading: u64 };

/// The fetcher told to read `address` from the pipe's next update, and
/// that waited for: until the flip is no longer pending and the fetcher
/// reads it, or four frames.
fn flipTo(frames: *Frames, tb: *TimerBase, address: u64) Flip {
    const sys = frames.sys;
    const engine = frames.display;
    const control = engine.hubp(dcn.DCSURF_FLIP_CONTROL);
    control.* = control.* & ~(dcn.SURFACE_FLIP_TYPE | dcn.SURFACE_UPDATE_LOCK);
    // Every write of the frame reaches the device's memory before the
    // fetcher is told: a locked instruction drains the gathered writes.
    var drain: u32 = 0;
    _ = @atomicRmw(u32, &drain, .Add, 0, .seq_cst);
    const first = @atomicLoad(u32, &frames.count, .acquire);
    const started = micros(tb);
    engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH).* = @truncate(address >> 32 & dcn.ADDRESS_HIGH_MASK);
    engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS).* = @truncate(address);
    var waited: u32 = 0;
    while (waited < 4) {
        sys.ResetWaitable(&frames.came);
        if (@atomicLoad(u32, &frames.count, .acquire) == first +% waited) {
            _ = sys.WaitForAny(&[_]*exec.Waitable{&frames.came}, 1, 50_000);
        }
        waited = @atomicLoad(u32, &frames.count, .acquire) -% first;
        if (control.* & dcn.SURFACE_FLIP_PENDING == 0 and engine.reading() == address) break;
    }
    return .{
        .frames = waited,
        .micros = micros(tb) - started,
        .pending = control.* & dcn.SURFACE_FLIP_PENDING != 0,
        .reading = engine.reading(),
    };
}

fn sayFlip(dl: *DosBase, what: [*:0]const u8, address: u64, flip: Flip) bool {
    const taken = !flip.pending and flip.reading == address;
    _ = Printf(dl, "%s 0x%lx: %s after %u frames, %lu us; the fetcher reads 0x%lx\n", .{
        what,                                                    address,
        if (taken) @as([*:0]const u8, "taken") else "NOT taken", flip.frames,
        flip.micros,                                             flip.reading,
    });
    _ = dl.Flush(dl.Output());
    return taken;
}

/// One flip to a copy of the screen in the device's memory, held, and
/// one back.
fn flipOnce(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, tb: *TimerBase, wb: *WatchdogBase, frames: *Frames) i32 {
    const engine = frames.display;
    const lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const ib: *IntuitionBase = @ptrCast(lib);
    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, "No default public screen\n", .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);
    const buffer = ib.AllocScreenBuffer(screen, intuition.screens.SB_SCREEN_BITMAP) orelse {
        _ = Printf(dl, "The screen's buffer cannot be had\n", .{});
        return dos.RETURN_FAIL;
    };
    defer ib.FreeScreenBuffer(screen, buffer);
    const bitmap = buffer.bitmap;
    const pixels = bitmap.pixels orelse return dos.RETURN_FAIL;
    const pitch_pixels = (engine.hubp(dcn.DCSURF_SURFACE_PITCH).* & dcn.PITCH_MASK) + 1;
    const pitch: usize = @as(usize, pitch_pixels) * 4;
    if (bitmap.width > pitch_pixels or bitmap.pitch < bitmap.width * 4) {
        _ = Printf(dl, "The screen is %u wide, the fetcher's rows %u\n", .{ bitmap.width, pitch_pixels });
        return dos.RETURN_FAIL;
    }
    var frame: amdgpu.GPUMemory = .{};
    if (!ab.AllocGPUMemory(@intCast(pitch * bitmap.height), 4096, &frame)) {
        _ = Printf(dl, "No %lu bytes of the device's memory\n", .{@as(u64, pitch * bitmap.height)});
        return dos.RETURN_FAIL;
    }
    defer ab.FreeGPUMemory(&frame);
    const into: [*]u8 = @ptrFromInt(@as(usize, @intCast(frame.cpu)));
    for (0..bitmap.height) |y| {
        sys.CopyMem(pixels + y * bitmap.pitch, into + y * pitch, bitmap.width * 4);
    }
    _ = Printf(dl, "The screen, %ux%u, copied to 0x%lx (0x%lx to the device), rows %lu bytes apart\n", .{
        bitmap.width, bitmap.height, frame.cpu, frame.device, @as(u64, pitch),
    });
    _ = dl.Flush(dl.Output());
    wb.FeedWatchdog();

    const firmware = engine.told();
    const there = flipTo(frames, tb, frame.device);
    wb.FeedWatchdog();
    const went = sayFlip(dl, "Flipped to", frame.device, there);
    hold(dl, wb, 6);
    const back = flipTo(frames, tb, firmware);
    wb.FeedWatchdog();
    const came = sayFlip(dl, "Flipped back to", firmware, back);
    if (!came) {
        // Told again at once, wherever the scan is, so that the screen is
        // the firmware's whatever the update point did.
        const control = engine.hubp(dcn.DCSURF_FLIP_CONTROL);
        control.* = control.* | dcn.SURFACE_FLIP_TYPE;
        engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH).* = @truncate(firmware >> 32 & dcn.ADDRESS_HIGH_MASK);
        engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS).* = @truncate(firmware);
        dl.Delay(5);
        control.* = control.* & ~dcn.SURFACE_FLIP_TYPE;
        _ = Printf(dl, "Told the firmware's screen at once: the fetcher reads 0x%lx\n", .{engine.reading()});
        // The frame may still be read: it is not given back.
        frame = .{};
    }
    return if (went and came) dos.RETURN_OK else dos.RETURN_ERROR;
}
