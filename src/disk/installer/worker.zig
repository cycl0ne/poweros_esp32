// SPDX-License-Identifier: MIT
//! The install on a process of its own - "Installer worker" - so that the
//! window keeps answering while a disk is written: the window says where
//! to install and what settings the new system gets (`Job`), starts the
//! worker (`start`), and is signalled as the install goes, reading what it
//! has come to (`take`) and, once the worker has ended, how it ended.
//!
//! **The install is C:Install's**, run the way the command runs it with
//! its defaults - the running system as the source, the drives and labels
//! it names, as many boot partitions as the board starts from - and the
//! settings the window chose left in the new system's `ENVARC:` as
//! `Sys/locale.prefs`. What the run says reaches the worker through the
//! run's `Watcher`: each line is kept as the last one said, and each file
//! written adds its bytes; the window is signalled, under `lock`.
//!
//! **Stop** is Ctrl-C to the worker, which the run looks for between
//! files: it ends where it is, the disk holding the table and as much of
//! the system as was written.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const expansion = sdk.expansion;
const utility = sdk.utility;
const install = @import("install");
const shared = install.shared;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RDBBase = sdk.interface.rdb.RDBBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TagItem = utility.TagItem;

const process_name = "Installer worker";
/// Beside the window: the install waits on disks.
const process_priority = 0;
const process_stack = 2 * dos.CLI_DEFAULT_STACK;

/// The longest line kept, its NUL aside.
pub const line_max = shared.line_max;
/// The longest device name kept, its NUL aside.
pub const device_max = 63;
/// The most bytes of the settings left in the new system: the file's
/// explanation and its line.
pub const settings_max = sdk.prefs.locale.header.len + 256;

/// Where the install is.
pub const Phase = enum {
    /// What the system is installed from, looked at.
    looking,
    /// The table, the partitions and their file systems made.
    preparing,
    /// The files copied.
    copying,
    /// The settings left in the new system.
    settings,
};

pub const Job = struct {
    sys: *ExecBase,
    dl: *DosBase,
    rb: *RDBBase,
    eb: *ExpansionBase,
    ub: *UtilityBase,

    // --- the window's ------------------------------------------------------------
    window: *exec.Task,
    news_bit: i8,
    end_port: *exec.MsgPort,
    ended: exec.Message = .{},
    worker: ?*exec.Task = null,

    // --- what to do, set before `start` ------------------------------------------
    /// The block device and its unit.
    device: [device_max:0]u8 = @splat(0),
    unit: u32 = 0,
    /// `Sys/locale.prefs` for the new system, whole.
    settings: [settings_max]u8 = undefined,
    settings_length: usize = 0,

    // --- between them, under `lock` ------------------------------------------------
    lock: exec.SignalSemaphore = .{},
    phase: Phase = .looking,
    /// The last line said, and whether it said what went wrong.
    line: [line_max:0]u8 = @splat(0),
    failure: bool = false,
    /// What has been written so far.
    wrote_bytes: u64 = 0,
    wrote_files: u32 = 0,

    // --- the end, set by the worker before it ends -------------------------------
    code: i32 = dos.RETURN_OK,

    /// Told what the run says, on the worker.
    watcher: shared.Watcher = .{ .said = &said, .wrote = &wrote },

    /// A job for the window that calls this: its signal and the port its
    /// worker's end comes to. False without them.
    pub fn init(job: *Job, sys: *ExecBase, dl: *DosBase, rb: *RDBBase, eb: *ExpansionBase, ub: *UtilityBase) bool {
        const end_port = sys.CreateMsgPort() orelse return false;
        const news_bit = sys.AllocSignal(-1);
        if (news_bit < 0) {
            sys.DeleteMsgPort(end_port);
            return false;
        }
        job.* = .{
            .sys = sys,
            .dl = dl,
            .rb = rb,
            .eb = eb,
            .ub = ub,
            .window = sys.FindTask(null).?,
            .news_bit = news_bit,
            .end_port = end_port,
        };
        job.ended = .{ .reply_port = end_port, .length = @sizeOf(exec.Message) };
        sys.InitSemaphore(&job.lock);
        return true;
    }

    /// The signal the window waits for news on.
    pub fn signal(job: *const Job) u32 {
        return @as(u32, 1) << @intCast(job.news_bit);
    }

    /// The signal the worker's end comes with.
    pub fn endSignal(job: *const Job) u32 {
        return job.end_port.sigMask();
    }

    /// Whether a worker is running.
    pub fn running(job: *const Job) bool {
        return job.worker != null;
    }

    /// The worker started on the job set: false where it could not be,
    /// or one is running already.
    pub fn start(job: *Job) bool {
        if (job.worker != null) return false;
        job.sys.ObtainSemaphore(&job.lock);
        job.phase = .looking;
        job.line = @splat(0);
        job.failure = false;
        job.wrote_bytes = 0;
        job.wrote_files = 0;
        job.sys.ReleaseSemaphore(&job.lock);
        job.code = dos.RETURN_OK;
        const tags = [_]TagItem{
            .{ .tag = dos.NP_Entry, .data = @intFromPtr(&workerEntry) },
            .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
            .{ .tag = dos.NP_UserData, .data = @intFromPtr(job) },
            .{ .tag = dos.NP_StackSize, .data = process_stack },
            .{ .tag = dos.NP_Priority, .data = @bitCast(@as(isize, process_priority)) },
            .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&job.ended) },
            .{},
        };
        const process = job.dl.CreateNewProc(&tags) orelse return false;
        job.worker = &process.task;
        return true;
    }

    /// The install told to stop, between two files.
    pub fn stop(job: *Job) void {
        if (job.worker) |worker| job.sys.Signal(worker, exec.SIGBREAKF_CTRL_C);
    }

    /// Whether the worker's end has come: then `code` is what it came
    /// to, and another job can start.
    pub fn finished(job: *Job) bool {
        var gone = false;
        while (job.sys.GetMsg(job.end_port)) |message| {
            if (message == &job.ended) gone = true;
        }
        if (gone) job.worker = null;
        return gone;
    }

    /// What the install has come to, copied out: where it is, the last
    /// line and whether it said what went wrong, and what has been
    /// written so far.
    pub fn take(job: *Job, phase: *Phase, line: *[line_max:0]u8, failure: *bool, wrote_bytes: *u64, wrote_files: *u32) void {
        const sys = job.sys;
        sys.ObtainSemaphore(&job.lock);
        defer sys.ReleaseSemaphore(&job.lock);
        phase.* = job.phase;
        line.* = job.line;
        failure.* = job.failure;
        wrote_bytes.* = job.wrote_bytes;
        wrote_files.* = job.wrote_files;
    }

    /// Stopped and waited for, as the window closes, and the signal and
    /// the port let go.
    pub fn free(job: *Job) void {
        const sys = job.sys;
        if (job.worker) |worker| {
            sys.Signal(worker, exec.SIGBREAKF_CTRL_C);
            while (!job.finished()) _ = sys.WaitPort(job.end_port);
        }
        sys.FreeSignal(job.news_bit);
        sys.DeleteMsgPort(job.end_port);
    }

    // --- the worker's --------------------------------------------------------------

    /// The install, on the worker: C:Install's steps in its order, with
    /// its defaults.
    fn serve(job: *Job) i32 {
        var run: shared.Run = .{
            .sys = job.sys,
            .dl = job.dl,
            .rb = job.rb,
            .eb = job.eb,
            .ub = job.ub,
            .device = @ptrCast(&job.device),
            .unit = job.unit,
            .watcher = &job.watcher,
        };
        run.system = .{ .name = shared.default_system, .label = shared.default_label, .dos_type = dos.posfs.ID_POSFS_DISK };
        run.work = .{ .name = shared.default_work, .label = shared.work_label, .dos_type = dos.posfs.ID_POSFS_DISK };
        const fat32 = dos.fat.typeWithFormat(dos.ID_MSDOS_DISK, dos.fat.FORMAT_FAT32);
        run.boot[0] = .{ .name = shared.default_boot, .label = "Boot", .dos_type = fat32 };
        run.boot[1] = .{ .name = shared.default_boot_b, .label = "Boot B", .dos_type = fat32 };
        run.slots = slotsOf(&run);

        const looked = install.files.look(&run);
        if (looked != dos.RETURN_OK) return looked;
        if (install.units.onIt(&run, run.device, run.unit)) {
            return shared.fail(&run, "the running system is on %s unit %d\n", .{ run.device, run.unit });
        }
        const bytes = install.disk.size(&run) orelse {
            return shared.fail(&run, "%s unit %d cannot be read: no such unit, or no medium in it\n", .{ run.device, run.unit });
        };
        if (bytes < leastBytes(run.slots)) {
            return shared.fail(&run, "%s unit %d is too small for this board's layout\n", .{ run.device, run.unit });
        }

        job.enter(.preparing);
        defer install.disk.done(&run);
        const made = install.disk.prepare(&run);
        if (made != dos.RETURN_OK) return made;

        job.enter(.copying);
        const copied = install.files.copy(&run);
        if (copied != dos.RETURN_OK) return copied;

        job.enter(.settings);
        return install.files.leaveSetting(&run, "Sys/locale.prefs", job.settings[0..job.settings_length]);
    }

    /// The install gone on to `phase`, and the window told.
    fn enter(job: *Job, phase: Phase) void {
        job.sys.ObtainSemaphore(&job.lock);
        job.phase = phase;
        job.sys.ReleaseSemaphore(&job.lock);
        job.sys.Signal(job.window, job.signal());
    }
};

/// How many boot partitions this board's firmware starts from - the
/// board's own fact, one where it says nothing.
pub fn slotsOf(run: *shared.Run) u32 {
    return @intCast(@min(shared.max_slots, @max(1, shared.boardFact(run, expansion.systemtags.SYSTAG_BootSlots, 1))));
}

/// The least a disk holds for `slots` boot partitions and a container
/// worth having.
pub fn leastBytes(slots: u32) u64 {
    return @as(u64, slots) * shared.boot_bytes + shared.least_container;
}

/// A line the run said, on the worker: kept as the last one, and the
/// window told.
fn said(watcher: *shared.Watcher, text: [*:0]const u8, failure: bool) void {
    const job: *Job = @fieldParentPtr("watcher", watcher);
    job.sys.ObtainSemaphore(&job.lock);
    copyText(&job.line, text);
    job.failure = failure;
    job.sys.ReleaseSemaphore(&job.lock);
    job.sys.Signal(job.window, job.signal());
}

/// A file the run wrote, on the worker: its bytes added, and the window
/// told.
fn wrote(watcher: *shared.Watcher, bytes: u64) void {
    const job: *Job = @fieldParentPtr("watcher", watcher);
    job.sys.ObtainSemaphore(&job.lock);
    job.wrote_bytes += bytes;
    job.wrote_files += 1;
    job.sys.ReleaseSemaphore(&job.lock);
    job.sys.Signal(job.window, job.signal());
}

fn workerEntry(sys: *ExecBase) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    job.code = job.serve();
}

/// `from` into `into`, cut to fit, the rest of it NULs.
pub fn copyText(into: anytype, from: [*:0]const u8) void {
    into.* = @splat(0);
    var at: usize = 0;
    while (from[at] != 0 and at < into.len) : (at += 1) into[at] = from[at];
}
