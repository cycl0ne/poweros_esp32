// SPDX-License-Identifier: MIT
//! About: a window of the desktop's name and version over what it runs
//! on - the system's release and its kernel, the board, the processor,
//! its cores and its clock, the memory and how much of it is in use, the
//! screen, the system disk and how long the machine has been up. Each is
//! asked of the running system when About is picked, so it is the
//! machine's now and not what the desktop was built for; one the system
//! cannot answer is left out.
//!
//! **The window** is on a process of its own, so the desktop goes on
//! answering while it is up, and About picked while one is up does
//! nothing more. Its rows are a label each and what it is, the labels
//! lined up in a column, in a box under the desktop's name; the memory
//! in use is a bar as well as a number. OK, its key, or the close gadget
//! closes it. What it shows is gathered on the desktop's process, which
//! has the libraries it is asked of, into the window's own block; the
//! window's process opens only what draws it, and frees the block as it
//! ends. Its words are the desktop's (`anvil.cd`): the rows' texts are
//! put together in the desktop's language, and the window's process
//! opens the catalog itself for the labels, its button and its title,
//! since the window may stay up after the desktop has quit.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const intuition = sdk.intuition;
const utility = sdk.utility;
const platform = sdk.resources.platform;
const sc = intuition.screens;
const wn = intuition.windows;
const wc = intuition.windowclass;
const lg = intuition.layoutgclass;
const gc = intuition.gadgetclass;
const classusr = intuition.classusr;
const tx = sdk.gadgets.text;
const fg = sdk.gadgets.fuelgauge;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const PlatformBase = sdk.interface.platform.PlatformBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const _base = @import("../anvil_base.zig");
const AnvilBase = _base.AnvilBase;
const anvil_init = @import("../anvil_init.zig");
const drawer_path = @import("../drawer/path.zig");
const _desktop = @import("_desktop.zig");
const Desktop = _desktop.Desktop;
const strings = @import("strings");
const Text = sdk.locale.Strings(strings);
const Id = strings.Id;

/// The window's process, by the name it is found by while it runs.
const process_name = "About Anvil";

/// The most rows: release, kernel, board, processor, cores, clock, the
/// memory and its two kinds, the screen, the system disk, the time up.
const rows_max = 12;
/// The bytes of a row's text, its NUL aside.
const value_max = 63;

const ID_OK = 1;

/// One window's state, in one block its process frees as it ends.
const About = struct {
    base: *AnvilBase,
    screen: ?*intuition.Screen = null,
    /// The name and version over the box, as text.gadget's markup.
    heading: [160:0]u8 = @splat(0),
    /// Each row's label, put in by the window's process.
    labels: [rows_max]Id = undefined,
    values: [rows_max][value_max + 1:0]u8 = @splat(@splat(0)),
    lines: [rows_max]Line = undefined,
    count: usize = 0,
    /// The row the memory is on, and how much of it is in use in
    /// hundredths; null for no bar.
    memory_row: ?usize = null,
    in_use: u32 = 0,
    /// What parts the thousands of a size, as the default locale writes
    /// them.
    group: [*:0]const u8 = ",",

    /// A row with its label, its text to be put together; null past
    /// `rows_max`, and the row is left out.
    fn row(about: *About, label: Id) ?*Line {
        if (about.count == rows_max) return null;
        const at = about.count;
        about.count += 1;
        about.labels[at] = label;
        about.lines[at] = .{ .into = &about.values[at], .group = about.group };
        return &about.lines[at];
    }
};

/// A text as it is put together: cut at the end of `into`, which starts
/// cleared and has its NUL past its end.
const Line = struct {
    into: []u8,
    length: usize = 0,
    /// What parts the thousands of an amount.
    group: [*:0]const u8 = ",",

    fn add(line: *Line, part: []const u8) void {
        const take = @min(part.len, line.into.len - line.length);
        @memcpy(line.into[line.length..][0..take], part[0..take]);
        line.length += take;
    }

    fn addString(line: *Line, part: [*:0]const u8) void {
        var length: usize = 0;
        while (part[length] != 0) length += 1;
        line.add(part[0..length]);
    }

    /// A count, a size in pixels or a version's part: its digits alone,
    /// no commas.
    fn number(line: *Line, value: u64) void {
        var digits: [20]u8 = undefined;
        var count: usize = 0;
        var left = value;
        while (true) {
            digits[digits.len - 1 - count] = '0' + @as(u8, @intCast(left % 10));
            count += 1;
            left /= 10;
            if (left == 0) break;
        }
        line.add(digits[digits.len - count ..]);
    }

    fn amount(line: *Line, bytes: u64) void {
        var digits: [32]u8 = undefined;
        line.add(digits[0..drawer_path.amount(&digits, bytes, line.group)]);
    }
};

fn pair(tag: utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

/// About's window opened on the desktop's screen, on its process: what
/// it shows gathered first. Nothing when one is up already, or there is
/// no memory or no process.
pub fn show(d: *Desktop) void {
    if (d.sys.FindTask(process_name) != null) return;
    const block = d.sys.AllocVec(@sizeOf(About), exec.MEMF_CLEAR) orelse return d.tell(.MSG_NO_MEMORY_ABOUT, .{});
    const about: *About = @ptrCast(@alignCast(block));
    about.* = .{ .base = d.base, .screen = d.screen };
    gather(d, about);
    _base.holdLibrary(d.base, 1);
    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&aboutMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
        .{ .tag = dos.NP_StackSize, .data = 16384 },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(about) },
        .{ .tag = dos.NP_HoldLibrary, .data = @intFromPtr(&d.base.lib) },
        .{},
    };
    if (d.dl.CreateNewProc(&tags) == null) {
        _base.holdLibrary(d.base, -1);
        d.sys.FreeVec(block);
        d.tell(.MSG_NO_MEMORY_ABOUT, .{});
    }
}

// --- what it shows ---------------------------------------------------------------

/// Every row, in the order the window shows them, and the heading at the
/// screen font's twice height.
fn gather(d: *Desktop, about: *About) void {
    about.group = drawer_path.Separators.of(d.text.locale).group;
    heading(d, about);
    release(d, about);
    kernel(d, about);
    board(d, about);
    processor(d, about);
    memory(d, about);
    screen(d, about);
    systemDisk(d, about);
    upFor(d, about);
}

/// "Anvil", large, and under it its version and what it is.
fn heading(d: *Desktop, about: *About) void {
    var line = Line{ .into = &about.heading };
    line.add("<b><s=");
    line.number(headingSize(d));
    line.add(">Anvil</></><br>");
    line.addString(d.text.get(.MSG_ABOUT_WHAT));
    line.add(", ");
    line.add(anvil_init.VERSION_TEXT);
}

/// Twice the screen font's height, the most a font is opened at for it.
fn headingSize(d: *Desktop) u32 {
    const shown = d.screen orelse return 16;
    const draw_info = d.ib.GetScreenDrawInfo(shown);
    defer d.ib.FreeScreenDrawInfo(shown, draw_info);
    const font = draw_info.font orelse return 16;
    return @max(@as(u32, font.image.height) * 2, 12);
}

/// "Release  PowerOS 0.2 (13.10.2026)": the system's ROM tag.
fn release(d: *Desktop, about: *About) void {
    const tag = d.sys.FindResident(sdk.release.RELEASE_RESIDENT) orelse return;
    const id = tag.id_string orelse return;
    const line = about.row(.MSG_ABOUT_RELEASE) orelse return;
    line.addString(id);
}

/// "Kernel  exec.library 1.33".
fn kernel(d: *Desktop, about: *About) void {
    const lib = d.sys.lib();
    const line = about.row(.MSG_ABOUT_KERNEL) orelse return;
    line.add("exec.library ");
    line.number(lib.version);
    line.add(".");
    line.number(lib.revision);
}

/// "Board  Waveshare ESP32-S3-Touch-LCD-7B", as the board's system tag
/// list names it.
fn board(d: *Desktop, about: *About) void {
    const library = d.sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return;
    defer d.sys.CloseLibrary(library);
    const eb: *ExpansionBase = @ptrCast(library);
    const name = d.ub.GetTagData(sdk.expansion.systemtags.SYSTAG_Name, 0, eb.SystemTags());
    if (name == 0) return;
    const line = about.row(.MSG_ABOUT_BOARD) orelse return;
    line.addString(@ptrFromInt(name));
}

/// "Processor  ESP32-S3", "Cores  2 Xtensa LX7", "Clock  240 MHz": the
/// chip and its core as platform.resource names them, how many cores
/// the machine runs on, and the clock as measured.
fn processor(d: *Desktop, about: *About) void {
    const resource = d.sys.OpenResource(platform.PLATFORMNAME) orelse return;
    const pr: *PlatformBase = @ptrCast(@alignCast(resource));
    var info: platform.PlatformInfo = .{};
    _ = pr.GetPlatformInfo(&info, @sizeOf(platform.PlatformInfo));
    if (about.row(.MSG_ABOUT_PROCESSOR)) |line| line.addString(pr.PlatformName());
    // What the machine says it runs on, not a number counted up to a
    // ceiling of this file's own: a machine with sixteen cores has
    // sixteen.
    const cores = d.sys.CoreCount();
    if (cores > 0 or info.core != null) {
        if (about.row(.MSG_ABOUT_CORES)) |line| {
            if (cores > 0) line.number(cores);
            if (info.core) |core| {
                if (cores > 0) line.add(" ");
                line.addString(core);
            }
        }
    }
    const hz = pr.CpuClock();
    if (hz == 0) return;
    const line = about.row(.MSG_ABOUT_CLOCK) orelse return;
    line.number(hz / 1_000_000);
    line.add(" MHz");
}

/// "Memory  8,703K, 5,685K free" - all there is, and how much of it is
/// free - with a bar of how much is in use under it; then the internal
/// memory and the PSRAM apart, the PSRAM only where the board has some.
/// On a machine whose RAM is one kind (`Desktop.unified`) every region is
/// both, so the line of all of it is the whole story.
fn memory(d: *Desktop, about: *About) void {
    const sys = d.sys;
    const total = if (d.unified) sys.AvailMem(exec.MEMF_ANY | exec.MEMF_TOTAL) else sys.AvailMem(exec.MEMF_INTERNAL | exec.MEMF_TOTAL) + sys.AvailMem(exec.MEMF_EXTERNAL | exec.MEMF_TOTAL);
    const free = if (d.unified) sys.AvailMem(exec.MEMF_ANY) else sys.AvailMem(exec.MEMF_INTERNAL) + sys.AvailMem(exec.MEMF_EXTERNAL);
    if (total == 0) return;
    const free_word = d.text.get(.MSG_TITLE_FREE);
    const line = about.row(.MSG_TITLE_MEMORY) orelse return;
    line.amount(total);
    line.add(", ");
    line.amount(free);
    line.add(" ");
    line.addString(free_word);
    about.memory_row = about.count - 1;
    const used = total -| free;
    about.in_use = @intCast(@min(used * 100 / total, 100));
    if (d.unified) return;
    kind(about, .MSG_TITLE_INTERNAL, sys.AvailMem(exec.MEMF_INTERNAL | exec.MEMF_TOTAL), sys.AvailMem(exec.MEMF_INTERNAL), free_word);
    const external = sys.AvailMem(exec.MEMF_EXTERNAL | exec.MEMF_TOTAL);
    if (external != 0) kind(about, .MSG_TITLE_PSRAM, external, sys.AvailMem(exec.MEMF_EXTERNAL), free_word);
}

/// A kind of memory's row: how much there is, how much is free.
fn kind(about: *About, label: Id, total: u64, free: u64, free_word: [*:0]const u8) void {
    const line = about.row(label) orelse return;
    line.amount(total);
    line.add(", ");
    line.amount(free);
    line.add(" ");
    line.addString(free_word);
}

/// "Screen  1024 x 600, 16 bits a pixel": the desktop's screen.
fn screen(d: *Desktop, about: *About) void {
    const shown = d.screen orelse return;
    var depth: usize = 0;
    d.ib.GetScreenAttrs(shown, &[_]TagItem{ .{ .tag = sc.SA_Depth, .data = @intFromPtr(&depth) }, .{} });
    const line = about.row(.MSG_ABOUT_SCREEN) orelse return;
    line.number(@intCast(d.screen_width));
    line.add(" x ");
    line.number(@intCast(d.screen_height));
    if (depth != 0) {
        line.add(", ");
        line.number(depth);
        line.add(" ");
        line.addString(d.text.get(.MSG_ABOUT_BITS));
    }
}

/// "System disk  System, 1,204M of 3,840M free": the disk SYS: is on,
/// by its name, and how much of it is free.
fn systemDisk(d: *Desktop, about: *About) void {
    const lock = d.dl.Lock("SYS:", dos.SHARED_LOCK) orelse return;
    defer d.dl.UnLock(lock);
    var name: [dos.path_max + 1:0]u8 = @splat(0);
    if (!d.dl.NameFromLock(lock, &name, name.len)) return;
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    const line = about.row(.MSG_ABOUT_SYSTEM_DISK) orelse return;
    line.add(drawer_path.lastPart(name[0..length]));
    var info: dos.InfoData = .{};
    if (!d.dl.Info(lock, &info) or info.bytes_per_block == 0) return;
    const block: u64 = info.bytes_per_block;
    line.add(", ");
    line.amount((info.num_blocks -| info.num_blocks_used) * block);
    line.add(" ");
    line.addString(d.text.get(.MSG_ABOUT_OF));
    line.add(" ");
    line.amount(info.num_blocks * block);
    line.add(" ");
    line.addString(d.text.get(.MSG_TITLE_FREE));
}

/// "Up for  2 days 3 h 12 min": the time since the machine started, as
/// timer.device's E-clock counts it from then.
fn upFor(d: *Desktop, about: *About) void {
    if (!d.clock_open) return;
    const device = d.clock.node.device orelse return;
    const tb: *TimerBase = @ptrCast(@alignCast(device));
    var clock: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&clock);
    if (rate == 0) return;
    const minutes = clock.toTicks() / rate / 60;
    const line = about.row(.MSG_ABOUT_UP_FOR) orelse return;
    const days = minutes / (24 * 60);
    const hours = minutes / 60 % 24;
    if (days > 0) {
        line.number(days);
        line.add(" ");
        line.addString(d.text.get(if (days == 1) .MSG_ABOUT_DAY else .MSG_ABOUT_DAYS));
        line.add(" ");
    }
    if (days > 0 or hours > 0) {
        line.number(hours);
        line.add(" h ");
    }
    line.number(minutes % 60);
    line.add(" min");
}

// --- the window --------------------------------------------------------------------

/// The window's process: the window shown and answered, its block freed.
fn aboutMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const about: *About = @ptrCast(@alignCast(me.user_data orelse return));
    defer sys.FreeVec(about);
    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return;
    defer sys.CloseLibrary(intuition_lib);
    const text_lib = sys.OpenLibrary(tx.TEXT_LIBRARY, 0) orelse return;
    defer sys.CloseLibrary(text_lib);
    // Without the bar's class the memory is its row alone.
    const gauge_lib = sys.OpenLibrary(fg.GAUGE_LIBRARY, 0);
    defer if (gauge_lib) |lib| sys.CloseLibrary(lib);
    if (gauge_lib == null) about.memory_row = null;
    var text = Text.open(sys);
    defer text.close();
    window(about, @ptrCast(intuition_lib), &text);
}

/// Tags put together for a layout, cut at their end.
const Tags = struct {
    tags: [3 * rows_max + 16]TagItem = undefined,
    count: usize = 0,

    fn tag(tags: *Tags, tag_id: utility.Tag, data: usize) void {
        if (tags.count + 1 >= tags.tags.len) return;
        tags.tags[tags.count] = pair(tag_id, data);
        tags.count += 1;
    }

    fn end(tags: *Tags) []const TagItem {
        tags.tags[tags.count] = .{};
        return tags.tags[0 .. tags.count + 1];
    }
};

/// The window made and answered until OK or its close gadget; everything
/// it was made of gone with it.
fn window(about: *About, ib: *IntuitionBase, text: *const Text) void {
    var box: Tags = .{};
    box.tag(lg.LAYOUTA_Orientation, lg.LORIENT_VERT);
    box.tag(lg.LAYOUTA_Frame, 1);
    box.tag(lg.LAYOUTA_Margin, 8);
    // The gap between the rows, and between the labels and what they
    // name.
    box.tag(lg.LAYOUTA_Spacing, 6);
    for (0..about.count) |at| {
        const value = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&about.values[at])), .{} });
        box.tag(lg.LAYOUTA_AddChild, @intFromPtr(value));
        box.tag(lg.CHILDA_Label, @intFromPtr(text.get(about.labels[at])));
        box.tag(lg.CHILDA_WeightHeight, 0);
        if (about.memory_row != at) continue;
        const bar = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
            pair(fg.GAUGE_Level, about.in_use),
            pair(fg.GAUGE_Percent, 1),
            pair(fg.GAUGE_Format, @intFromPtr("%ld%%")),
            .{},
        });
        box.tag(lg.LAYOUTA_AddChild, @intFromPtr(bar));
        box.tag(lg.CHILDA_Label, @intFromPtr(text.get(.MSG_ABOUT_IN_USE)));
        box.tag(lg.CHILDA_WeightHeight, 0);
    }
    const machine = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, box.end().ptr);

    const title = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(&about.heading)),
        pair(tx.TEXT_Markup, 1),
        pair(tx.TEXT_Justification, tx.TEXT_JUSTIFY_CENTER),
        .{},
    });
    const ok = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(text.get(.MSG_OK))),
        pair(gc.GA_ID, ID_OK),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
    const buttons = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_AddSpace, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ok)),
        pair(lg.CHILDA_MinWidth, 96),
        pair(lg.LAYOUTA_AddSpace, 0),
        .{},
    });
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 8),
        pair(lg.LAYOUTA_Spacing, 8),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(title)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(machine)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.CHILDA_MinWidth, 300),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(buttons)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse return;
    const window_object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(text.get(.MSG_ABOUT_TITLE))),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_Position, wn.WPOS_CENTERSCREEN),
        pair(if (about.screen != null) wn.WA_CustomScreen else utility.TAG_IGNORE, @intFromPtr(about.screen)),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        return;
    };
    // The window object disposes of its layout, and the layout of its
    // gadgets.
    defer ib.DisposeObject(window_object);
    var opening = wc.WmOpen{};
    if (ib.SendMessage(window_object, @ptrCast(&opening)) == 0) return;
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, window_object, &window_ptr);
    const shown: *intuition.Window = @ptrFromInt(window_ptr);

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        _ = ib.WaitIMsg(shown, 0);
        while (true) {
            const word = ib.SendMessage(window_object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return,
                wc.WMHI_GADGETUP => if (word & wc.WMHI_GADGETMASK == ID_OK) return,
                else => {},
            }
        }
    }
}
