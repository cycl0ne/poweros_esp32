// SPDX-License-Identifier: MIT
//! CPULoad: how busy each core is, now and over the last minutes, in a
//! window. Built against the SDK only.
//!
//!   CPULoad INTERVAL/K/N,HISTORY/K/N
//!
//! INTERVAL is how often it looks, in seconds (1); HISTORY how many looks
//! the chart keeps (120, two minutes at a second).
//!
//! Each core has a bar with how busy it was over the last interval - in
//! tasks and in interrupts together - and a line under it saying how much
//! of that was each. Every core the machine runs gets one, in a grid kept
//! roughly square, so a machine with sixteen cores is four rows of four
//! rather than eight rows of two.
//!
//! The chart under them holds a line per core: how busy it was, and -
//! while there are eight cores or fewer - a second, lighter line for how
//! much of that was interrupts, so a load a task makes and one the
//! hardware makes look different at once. Past eight cores the second
//! line goes and each core keeps one, which is as many as can be told
//! apart on one chart.
//!
//! The figures are exec's (`ReadCoreTimes`): each core's time in tasks,
//! idle and in interrupts, read at every interval; what changed in between
//! is the interval's share. They are exact rather than sampled, so a task
//! that runs a moment after each tick shows as much as it takes.
//!
//! The close gadget or Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const motion = sdk.motion;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const MotionBase = sdk.interface.motion.MotionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const fg = sdk.gadgets.fuelgauge;
const tx = sdk.gadgets.text;
const cr = sdk.gadgets.chart;

pub const COMMAND_NAME = "CPULoad";
const VERSION = "1.3";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (06.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while one of its windows is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "INTERVAL/K/N,HISTORY/K/N";
const arg_interval = 0;
const arg_history = 1;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory for the gadgets\n";
const MSG_NOWINDOW = "%s: no window\n";
const MSG_MORECORES = "%s: this machine runs %u cores; the first %u are shown\n";

/// The most cores shown: a line each on the chart, which holds that many
/// series. A machine with more says so and shows the first of them.
const max_cores = cr.CHART_MAX_SERIES;

/// Up to this many cores the chart draws each core's interrupts as a
/// second line beside its load; past it, one line a core.
const both_lines_to = 8;

/// A core's line and, lighter, its interrupts' line. Sixteen of them, so
/// every core of a machine with sixteen has a colour of its own; a
/// machine with more goes round the list again, and those cores are told
/// apart by where they are in the grid rather than by colour.
const colours = [_][2]u32{
    .{ 0xFF3070C0, 0xFF9DB8E0 },
    .{ 0xFF2E9E4F, 0xFF9FD3AE },
    .{ 0xFFD07A1E, 0xFFEBC08F },
    .{ 0xFF8A4FC0, 0xFFC9ADE3 },
    .{ 0xFF1F9E9E, 0xFF9ED6D6 },
    .{ 0xFFC83C3C, 0xFFE89D9D },
    .{ 0xFF8A9E1F, 0xFFCDD69E },
    .{ 0xFFC84F9E, 0xFFE3ADD1 },
    .{ 0xFF3CA0D0, 0xFFA8D5EA },
    .{ 0xFF6EC03C, 0xFFBCE0A8 },
    .{ 0xFFC0A03C, 0xFFE0D3A8 },
    .{ 0xFF6A4FC8, 0xFFB6ADE6 },
    .{ 0xFF2EB0A0, 0xFFA0DDD6 },
    .{ 0xFFD0607A, 0xFFEAB0BD },
    .{ 0xFF4F8A5F, 0xFFADC9B4 },
    .{ 0xFF9E4F6E, 0xFFD6ADBB },
};
const colour_names = [colours.len][*:0]const u8{
    "blue", "green", "orange", "purple",
    "teal", "red",   "olive",  "pink",
    "sky",  "lime",  "amber",  "violet",
    "cyan", "rose",  "moss",   "plum",
};

/// How many cores go side by side in the grid of their bars: as many as
/// keeps it roughly square, so the window grows in both directions
/// rather than only downwards.
fn perRow(count: usize) usize {
    var columns: usize = 2;
    while (columns * columns < count and columns < 6) columns += 1;
    return @min(columns, count);
}

/// How wide a core's bar is, which narrows as the grid widens so that a
/// machine with many cores still has a window that fits on a screen.
fn gaugeWidth(columns: usize) usize {
    if (columns <= 2) return 220;
    if (columns <= 4) return 170;
    return 130;
}

/// How many lines the chart holds for each core.
fn linesPer(count: usize) usize {
    return if (count <= both_lines_to) 2 else 1;
}

fn pair(t: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

/// What one core shows: its bar, its line of figures, and the times they
/// were last worked out from.
const Core = struct {
    gauge: ?*Object = null,
    figures: ?*Object = null,
    title: [24:0]u8 = @splat(0),
    text: [48:0]u8 = @splat(0),
    last: exec.CoreTimes = .{},
};

/// `part` of `whole`, in whole percent.
fn percent(part: u64, whole: u64) u32 {
    if (whole == 0) return 0;
    return @intCast(@min(part * 100 / whole, 100));
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const interval: u32 = @intCast(@max(rdargs.number(argv[arg_interval]) orelse 1, 1));
    const history: u32 = @intCast(@min(@max(rdargs.number(argv[arg_history]) orelse 120, 2), 1024));

    var libraries: [5]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{ intuition.INTUITIONNAME, motion.MOTIONNAME, fg.GAUGE_LIBRARY, tx.TEXT_LIBRARY, cr.CHART_LIBRARY };
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const motion_base: *MotionBase = @ptrCast(libraries[1].?);

    // The cores the machine runs, as the machine says itself, and room
    // for that many: how many cores there are is not something this
    // program should hold a number for.
    const told: usize = sys.CoreCount();
    const count: usize = @min(told, max_cores);
    if (told > count) {
        _ = Printf(dl, MSG_MORECORES, .{ COMMAND_NAME, @as(u32, @intCast(told)), @as(u32, @intCast(count)) });
    }
    const room = sys.AllocVec(count * @sizeOf(Core), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(room);
    const held: [*]Core = @ptrCast(@alignCast(room));
    const cores = held[0..count];
    const columns = perRow(count);
    const width = gaugeWidth(columns);
    const lines = linesPer(count);

    // A bar and a line of figures for each.
    var made_all = true;
    for (cores, 0..) |*core, index| {
        core.* = .{};
        _ = sys.ReadCoreTimes(@intCast(index), &core.last);
        // Its colour is in its frame's title, which is how a bar is told
        // from the line it has on the chart. A core past the colours
        // there are has only its number.
        if (index < colour_names.len) {
            const title_stream = exec.fmtStream(.{ @as(u32, @intCast(index)), colour_names[index] });
            comptime exec.checkFormat("Core %u, %s", @TypeOf(.{ @as(u32, 0), colour_names[0] }));
            _ = sys.RawDoFmt("Core %u, %s", &title_stream, null, &core.title);
        } else {
            const title_stream = exec.fmtStream(.{@as(u32, @intCast(index))});
            comptime exec.checkFormat("Core %u", @TypeOf(.{@as(u32, 0)}));
            _ = sys.RawDoFmt("Core %u", &title_stream, null, &core.title);
        }
        const none = "Tasks -, interrupts -";
        @memcpy(core.text[0..none.len], none);
        core.gauge = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
            pair(fg.GAUGE_Format, @intFromPtr("%ld%%")),
            pair(gc.GA_Width, width),
            .{},
        });
        core.figures = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            pair(tx.TEXT_Text, @intFromPtr(&core.text)),
            pair(gc.GA_Width, width),
            .{},
        });
        if (core.gauge == null or core.figures == null) made_all = false;
    }

    // The chart: a line per core, with its interrupts beside it while
    // there are few enough cores for two lines each to be told apart.
    // Its tags and the ones a look adds with are one block, both being
    // as long as the machine has cores.
    const chart_room = 8 + 2 * lines * count;
    const add_room = 2 + 2 * lines * count;
    const tags_memory = sys.AllocVec((chart_room + add_room) * @sizeOf(TagItem), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(tags_memory);
    const tags: [*]TagItem = @ptrCast(@alignCast(tags_memory));
    const chart_tags = tags[0..chart_room];
    const add_tags = tags[chart_room..][0..add_room];
    var n: usize = 0;
    chart_tags[n] = pair(cr.CHART_Series, lines * count);
    n += 1;
    chart_tags[n] = pair(cr.CHART_Capacity, history);
    n += 1;
    chart_tags[n] = pair(cr.CHART_Min, 0);
    n += 1;
    chart_tags[n] = pair(cr.CHART_Max, 100);
    n += 1;
    chart_tags[n] = pair(cr.CHART_Lines, 4);
    n += 1;
    for (0..count) |index| {
        for (0..lines) |line| {
            chart_tags[n] = pair(cr.CHART_Current, lines * index + line);
            chart_tags[n + 1] = pair(cr.CHART_ColourRGB, colours[index % colours.len][line]);
            n += 2;
        }
    }
    chart_tags[n] = pair(gc.GA_Width, @max(460, columns * width));
    chart_tags[n + 1] = pair(gc.GA_Height, 160);
    chart_tags[n + 2] = .{};
    const plot = ib.NewObjectTagList(null, cr.CHART_CLASS, chart_tags.ptr);
    if (plot == null) made_all = false;
    if (!made_all) {
        for (cores) |core| {
            ib.DisposeObject(core.gauge);
            ib.DisposeObject(core.figures);
        }
        ib.DisposeObject(plot);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }

    // The cores side by side, `columns` to a row, the chart under them.
    var groups: [max_cores]?*Object = @splat(null);
    for (cores, 0..) |*core, index| {
        groups[index] = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_FrameTitle, @intFromPtr(&core.title)),
            pair(lg.LAYOUTA_Margin, 6),
            pair(lg.LAYOUTA_Spacing, 4),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(core.gauge)),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(core.figures)),
            pair(lg.CHILDA_WeightHeight, 0),
            .{},
        });
    }
    var grid_list: [4 + max_cores]TagItem = undefined;
    var r: usize = 0;
    grid_list[r] = pair(lg.LAYOUTA_Orientation, lg.LORIENT_GRID);
    r += 1;
    grid_list[r] = pair(lg.LAYOUTA_Columns, columns);
    r += 1;
    grid_list[r] = pair(lg.LAYOUTA_Spacing, 6);
    r += 1;
    for (groups[0..count]) |group| {
        grid_list[r] = pair(lg.LAYOUTA_AddChild, @intFromPtr(group));
        r += 1;
    }
    grid_list[r] = .{};
    const top = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &grid_list);
    var chart_title: [48:0]u8 = @splat(0);
    const chart_stream = exec.fmtStream(.{history * interval});
    comptime exec.checkFormat("Busy and interrupts, last %u s", @TypeOf(.{@as(u32, 0)}));
    comptime exec.checkFormat("Busy, last %u s", @TypeOf(.{@as(u32, 0)}));
    const chart_form: [*:0]const u8 = if (lines == 2) "Busy and interrupts, last %u s" else "Busy, last %u s";
    _ = sys.RawDoFmt(chart_form, &chart_stream, null, &chart_title);
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(top)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_FrameTitle, @intFromPtr(&chart_title)),
            pair(lg.LAYOUTA_Margin, 6),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(plot)),
            .{},
        }))),
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr("CPU Load")),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    var window_pointer: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_pointer);
    const window: *intuition.Window = @ptrFromInt(window_pointer);

    // The clock: a look every interval.
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const tick = motion_base.CreateTimerTagList(&[_]TagItem{
        pair(motion.TIMER_Period, interval * 1000),
        pair(motion.TIMER_Repeat, motion.TIMER_FOREVER),
        pair(motion.TIMER_Signal, @intCast(bit)),
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer motion_base.DeleteTimer(tick);
    motion_base.StartTimer(tick);
    const tick_mask = @as(u32, 1) << @intCast(bit);

    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        const got = ib.WaitIMsg(window, tick_mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & tick_mask != 0) look(sys, ib, window, plot.?, cores, lines, add_tags);
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            if (word & wc.WMHI_CLASSMASK == wc.WMHI_CLOSEWINDOW) return dos.RETURN_OK;
        }
    }
}

/// One look: each core's times read again, the interval's share worked
/// out, and the bars, the figures and the chart brought up to it.
fn look(sys: *ExecBase, ib: *IntuitionBase, window: *intuition.Window, plot: *Object, cores: []Core, lines: usize, add: []TagItem) void {
    var n: usize = 0;
    for (cores, 0..) |*core, index| {
        var now: exec.CoreTimes = .{};
        if (!sys.ReadCoreTimes(@intCast(index), &now)) continue;
        const tasks = now.tasks -% core.last.tasks;
        const idle = now.idle -% core.last.idle;
        const interrupts = now.interrupts -% core.last.interrupts;
        core.last = now;
        const all = tasks + idle + interrupts;
        const busy = percent(tasks + interrupts, all);
        const in_interrupts = percent(interrupts, all);
        const stream = exec.fmtStream(.{ percent(tasks, all), in_interrupts });
        comptime exec.checkFormat("Tasks %u%%, interrupts %u%%", @TypeOf(.{ @as(u32, 0), @as(u32, 0) }));
        _ = sys.RawDoFmt("Tasks %u%%, interrupts %u%%", &stream, null, &core.text);
        _ = ib.SetGadgetAttrsTagList(core.gauge.?, window, &[_]TagItem{ pair(fg.GAUGE_Level, busy), .{} });
        _ = ib.SetGadgetAttrsTagList(core.figures.?, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&core.text)), .{} });
        add[n] = pair(cr.CHART_Current, lines * index);
        add[n + 1] = pair(cr.CHART_Add, busy);
        n += 2;
        if (lines == 2) {
            add[n] = pair(cr.CHART_Current, lines * index + 1);
            add[n + 1] = pair(cr.CHART_Add, in_interrupts);
            n += 2;
        }
    }
    add[n] = .{};
    _ = ib.SetGadgetAttrsTagList(plot, window, add.ptr);
}
