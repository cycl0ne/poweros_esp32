// SPDX-License-Identifier: MPL-2.0
//! Software Failure: a task that failed is held and asked about on the
//! display, and the machine runs on. The chip's alert display
//! (`alert_hook`) prints the Guru and decides; what happens to the task
//! is here, the same on every chip.
//!
//! A dead-end alert of a task that may be held - not in an interrupt,
//! nothing forbidden, none of the display's locks in its hands - holds
//! that task (`hold`): a CPU exception's task is put on the wait list,
//! waiting for nothing, and the exception's exit switches to the next; a
//! task that called Alert waits for nothing there and then. The helper, a
//! task of exec's own started at boot, then puts up the requester, on the
//! default public screen, brought in front of the others first: a screen
//! of the failed task's own - a game's, with no title bar to send it back
//! with - would hide it, and the machine would look as if it had stopped.
//! It stays in front once the task is answered for.
//!
//! - **Suspend** leaves the task held for good: it stops, everything else
//!   runs on, and what it holds stays where it is.
//! - **Kill** ends it (`_task.killTask`): started again on its own stack,
//!   it lets go of its semaphores, runs its final code and ends - its end
//!   hooks close its windows, its private memory is freed, and its Task
//!   stays where it was for whatever still names it.
//! - **Reboot** keeps the end of the log for the next boot and starts the
//!   machine again.
//!
//! One failure at a time: a second while one is being asked about stops
//! the machine. A recoverable alert is shown on the display as well, for a
//! few seconds (`displayRecoverable`).
//!
//! The requester is intuition's, opened by name and never loaded for
//! this; without intuition in the system a failure stops the machine. A
//! kernel with no display at all says so in its root
//! (`pub const rom_has_display = false`): this then leaves intuition's
//! types alone - importing them puts intuition.library's ROM tag in the
//! image - and every failure stops the machine.

const sdk = @import("sdk");
const exec = @import("../exec.zig");
const _task = @import("../task/_task.zig");
const _debug = @import("../debug/_debug.zig");
const root = @import("root");

/// Whether the ROM has a display, and intuition.library on it: unless the
/// kernel's root says it has none.
const rom_has_display = !@hasDecl(root, "rom_has_display") or root.rom_has_display;
const IntuitionBase = @import("../../intuition/intuition.zig").IntuitionBase;
const Screen = @import("../../intuition/screen/_screen.zig").Screen;
const LayerInfo = @import("../../layers/layerinfo/_layerinfo.zig").LayerInfo;

const ExecBase = exec.ExecBase;
const Task = sdk.exec.Task;

/// What a failed task is asked about with, kept from its alert for the
/// helper, and the helper itself. In exec's base, cleared as the base is
/// made: no helper, nothing asked about.
pub const State = extern struct {
    /// The task asked about, from its alert until the answer.
    task: ?*Task = null,
    alert_num: u32 = 0,
    /// The Guru line and what went wrong in words.
    guru: [40]u8 = @splat(0),
    detail: [100]u8 = @splat(0),
    /// A failure is being asked about: another stops the machine.
    asking: bool = false,
    /// A recoverable alert is on the display: one raised meanwhile is
    /// printed only.
    displaying: bool = false,
    /// The helper and the signal it waits for; null and 0 until it has
    /// started, and until then a failure stops the machine.
    helper: ?*Task = null,
    mask: u32 = 0,
};

/// How much stack the helper has: a requester's call and its formatting.
const helper_stack = 8192;

/// How long a recoverable alert waits on the display for an answer, in
/// frames of a 60 Hz display: ten seconds, so a board nobody watches goes
/// on by itself.
const recoverable_frames = 600;

/// The helper started: a task of exec's own, with its stack and its Task
/// in one block of internal memory. The kernel starts it once exec is up.
///
/// INPUTS:
/// - `base` - exec.
pub fn startHelper(base: *ExecBase) void {
    const sys = base.iface();
    const room = _task.alignUp(@sizeOf(Task), 16);
    const block = sys.AllocMem(helper_stack + room, sdk.exec.MEMF_INTERNAL | sdk.exec.MEMF_CLEAR | sdk.exec.MEMF_SYSTEM) orelse return;
    const lower = @intFromPtr(block);
    const task: *Task = @ptrFromInt(lower + helper_stack);
    task.* = .{
        .node = .{ .type = .task, .pri = 10, .name = "software failure" },
        .sp_lower = lower,
        .sp_upper = lower + helper_stack,
    };
    _ = sys.AddTask(task, &helperMain, null);
    _task.makeSystemTask(task);
    base.failure.helper = task;
}

fn helperMain(sys_base: *sdk.interface.exec.ExecBase) callconv(.c) void {
    const base: *ExecBase = @ptrCast(@alignCast(sys_base));
    const bit = sys_base.AllocSignal(-1);
    if (bit < 0) return;
    base.failure.mask = @as(u32, 1) << @intCast(bit);
    while (true) {
        _ = sys_base.Wait(base.failure.mask);
        askAbout(base);
    }
}

/// Whether the running task may be held and asked about: it is a task,
/// out of any interrupt (a CPU exception counts as one level, taken from
/// the task's own code), with interrupts on and nothing forbidden; it is
/// neither the helper nor intuition's input task, which answers
/// requesters; intuition is in the system with a screen open - a
/// requester that cannot be made answers as Reboot does; and the task
/// holds none of the locks the input task needs to put a requester up and
/// take it down - held for good, it would keep them. Otherwise the machine
/// is stopped.
///
/// INPUTS:
/// - `base` - exec: this core's state.
/// - `exception` - the alert is a CPU exception's.
pub fn canAsk(base: *ExecBase, exception: bool) bool {
    if (comptime !rom_has_display) return false;
    if (!exec.initialized) return false;
    const state = &base.failure;
    if (state.asking or state.mask == 0) return false;
    if (base.cpu().int_depth != @intFromBool(exception)) return false;
    // Waiting for the answer must be possible: switching on, nothing
    // masked, no spinlock held.
    if (base.multitasking == 0 or base.cpu().id_nest_cnt >= 0 or base.cpu().hold_count != 0) return false;
    const task = base.cpu().this_task;
    if (task == state.helper) return false;
    if (sameName(task.node.name, "intuition input")) return false;
    const ib = findIntuition(base) orelse return false;
    if (ib.screen_list.isEmpty()) return false;
    return !holdsDisplayLocks(ib, task);
}

/// The running task held, and the helper told to ask about it: `canAsk`
/// said it may be. A CPU exception's task never runs another instruction
/// - it is put on the wait list here, and the exception's exit switches
/// to the next task, so this returns. A task that called Alert waits here
/// for nothing, and this does not return: Suspend leaves it there, Kill
/// starts it again elsewhere.
///
/// INPUTS:
/// - `base` - exec.
/// - `alert_num` - the alert.
/// - `guru` - the Guru line, for the requester.
/// - `detail` - what went wrong in words: the alert's text, or a CPU
///   exception's cause and address.
/// - `exception` - the alert is a CPU exception's.
pub fn hold(base: *ExecBase, alert_num: u32, guru: []const u8, detail: []const u8, exception: bool) void {
    const state = &base.failure;
    const task = base.cpu().this_task;
    state.asking = true;
    state.task = task;
    state.alert_num = alert_num;
    copyText(&state.guru, guru);
    copyText(&state.detail, detail);
    exec.kprintf("*** task held, and asked about on the display\n", .{});
    const sys = base.iface();
    if (exception) {
        _task.blockCurrent(base, task, 0);
        sys.Signal(state.helper.?, state.mask);
        return;
    }
    sys.Signal(state.helper.?, state.mask);
    _ = sys.Wait(0);
    unreachable;
}

/// The Software Failure requester for the held task, on the helper, its
/// screen brought to the front: Suspend leaves the task held, Kill ends
/// it, Reboot starts the machine again.
fn askAbout(base: *ExecBase) void {
    const state = &base.failure;
    defer state.asking = false;
    const task = state.task orelse return;
    state.task = null;
    var name: [*:0]const u8 = task.name().ptr;
    if (task.node.type == .process) {
        const process: *sdk.dos.Process = @ptrCast(@alignCast(task));
        if (process.cli) |cli| if (cli.command_name) |command| if (command[0] != 0) {
            name = command;
        };
    }
    // The name cut so the message fits its buffer: the guru line and the
    // detail are bounded already.
    var short: [61]u8 = @splat(0);
    var length: usize = 0;
    while (name[length] != 0 and length < short.len - 1) : (length += 1) short[length] = name[length];
    var message: [256]u8 = undefined;
    const stream = sdk.exec.fmtStream(.{ @as([*:0]const u8, @ptrCast(&short)), @as([*:0]const u8, @ptrCast(&state.guru)), @as([*:0]const u8, @ptrCast(&state.detail)) });
    _ = exec.format("%s has failed.\n%s\n%s\nWait for disk activity to finish.", &stream, null, &message);

    const sys = base.iface();
    const library = sys.OpenLibrary("intuition.library", 0) orelse return;
    defer sys.CloseLibrary(library);
    const ib: *sdk.interface.intuition.IntuitionBase = @ptrCast(library);
    const easy = sdk.intuition.EasyStruct{
        .title = "Software Failure",
        .text_format = "%s",
        .gadget_format = "Suspend|Kill|Reboot",
    };
    const args = sdk.exec.fmtStream(.{@as([*:0]const u8, @ptrCast(&message))});
    if (ib.LockPubScreen(null)) |screen| {
        ib.ScreenToFront(screen);
        ib.UnlockPubScreen(null, screen);
    }
    // 1 is Suspend, 2 Kill, 0 the rightmost, Reboot - with the log's end
    // kept for the next boot to show.
    switch (ib.EasyRequestArgs(null, &easy, null, &args)) {
        1 => exec.kprintf("exec: task \"%.32s\" #%u suspended\n", .{ task.name().ptr, task.id }),
        2 => {
            exec.kprintf("exec: task \"%.32s\" #%u killed\n", .{ task.name().ptr, task.id });
            _ = _task.killTask(base, task);
        },
        else => {
            if (_debug.debug_hardware) |chip| if (chip.keepLastWords) |keepLastWords| keepLastWords();
            sys.ColdReboot();
        },
    }
}

/// A recoverable alert on the display as well, through intuition's
/// TimedDisplayAlert: a box with the alert's title, its number and its
/// text, answered by a press or a touch or by the time running out. Only
/// where waiting for that is safe - a task raised it, not an interrupt;
/// interrupts are on and no spinlock is held; it is not intuition's input
/// task, whose events answer it - and only with intuition already in the
/// system: it is opened by name, and never loaded for this.
///
/// INPUTS:
/// - `base` - exec: this core's state.
/// - `alert_num` - the alert.
/// - `guru` - the Guru line.
/// - `text` - what went wrong in words, or null.
pub fn displayRecoverable(base: *ExecBase, alert_num: u32, guru: []const u8, text: ?[*:0]const u8) void {
    if (comptime !rom_has_display) return;
    if (!exec.initialized or base.failure.displaying) return;
    if (base.cpu().int_depth != 0) return;
    if (base.multitasking == 0 or base.cpu().id_nest_cnt >= 0 or base.cpu().hold_count != 0) return;
    if (sameName(base.cpu().this_task.node.name, "intuition input")) return;
    if (findIntuition(base) == null) return;
    const sys = base.iface();
    const library = sys.OpenLibrary("intuition.library", 0) orelse return;
    defer sys.CloseLibrary(library);
    const ib: *sdk.interface.intuition.IntuitionBase = @ptrCast(library);

    var message: [256]u8 = undefined;
    var at: usize = 0;
    const parts = [_][]const u8{ "Recoverable Alert.   Left button or left half: go on\n", guru, "\n", if (text) |line| spanOf(line) else "" };
    for (parts) |part| {
        const room = message.len - 1 - at;
        const take = @min(part.len, room);
        @memcpy(message[at..][0..take], part[0..take]);
        at += take;
    }
    message[at] = 0;
    base.failure.displaying = true;
    defer base.failure.displaying = false;
    _ = ib.TimedDisplayAlert(alert_num, @ptrCast(&message), 40, recoverable_frames);
}

/// Intuition's base, if it is in the system, from exec's library list
/// walked as it stands.
fn findIntuition(base: *ExecBase) ?*IntuitionBase {
    var node = base.lib_list.first();
    while (node) |library| : (node = library.next()) {
        if (!sameName(library.name, "intuition.library")) continue;
        const lib: *sdk.exec.Library = @fieldParentPtr("node", library);
        return @fieldParentPtr("lib", lib);
    }
    return null;
}

/// Whether a task holds intuition's screen list or any lock of a screen's
/// layers.
fn holdsDisplayLocks(ib: *IntuitionBase, task: *Task) bool {
    if (ib.screen_lock.owner == task) return true;
    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const screen: *Screen = @ptrCast(@alignCast(n));
        const info: *LayerInfo = @ptrCast(@alignCast(screen.layer_info));
        if (info.lock.owner == task) return true;
        var lock = info.locks.first();
        while (lock) |l| : (lock = l.next()) {
            const semaphore: *sdk.exec.SignalSemaphore = @fieldParentPtr("link", l);
            if (semaphore.owner == task) return true;
        }
    }
    return false;
}

/// Whether a node's name is `wanted`.
fn sameName(name: ?[*:0]const u8, wanted: [:0]const u8) bool {
    const text = name orelse return false;
    for (wanted, 0..) |char, index| {
        if (text[index] != char) return false;
    }
    return text[wanted.len] == 0;
}

/// A NUL-terminated string as a slice.
fn spanOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

/// `text` into `into`, cut to leave its last byte a NUL.
fn copyText(into: []u8, text: []const u8) void {
    const take = @min(text.len, into.len - 1);
    @memcpy(into[0..take], text[0..take]);
    @memset(into[take..], 0);
}
