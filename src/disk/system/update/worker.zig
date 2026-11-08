// SPDX-License-Identifier: MIT
//! The run on a process of its own - "Update worker" - so that the window
//! never waits on a package: the window says what to do (`Job`), starts
//! the worker (`start`), and is signalled as the run goes, reading what
//! it said (`take`) and, once the worker has ended, what it came to.
//!
//! **What a run says** comes to the worker through update.library's hook:
//! each path becomes a row of the window's list (what happens to it, the
//! path, its size), each file put in place adds its bytes to what the
//! gauge shows, and each line of prose is kept as the last one said. All
//! of it is kept under `lock` and the window is signalled; the window
//! takes the rows over and shows the rest.
//!
//! **Stop** is Ctrl-C to the worker, which the run looks for between
//! files: it ends with what it wrote in place and the system's list as it
//! was, so the next check finds the rest.
//!
//! **A job** is one of four: a check, an update, a look for a partition
//! being tried (`ConfirmUpdate` with `UPD_Check`, whose words are not
//! shown), and keeping it.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const update = sdk.update;
const utility = sdk.utility;
const lb = sdk.gadgets.listbrowser;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UpdateBase = sdk.interface.update.UpdateBase;
const TagItem = utility.TagItem;

const process_name = "Update worker";
/// Beside the window: the run waits on disks and the network.
const process_priority = 0;
const process_stack = 2 * dos.CLI_DEFAULT_STACK;

/// The longest package name kept, its NUL aside.
pub const source_max = 255;
/// The longest line of prose kept, its NUL aside.
pub const line_max = 255;

/// What the worker is to do.
pub const Kind = enum {
    /// What an update would do, said.
    check,
    /// The update done.
    update,
    /// Whether this system was started on a partition the firmware was
    /// told to try, which Keep would make its own.
    look,
    /// That partition kept.
    keep,
};

pub const Job = struct {
    sys: *ExecBase,
    dl: *DosBase,

    // --- the window's ------------------------------------------------------------
    window: *exec.Task,
    news_bit: i8,
    end_port: *exec.MsgPort,
    ended: exec.Message = .{},
    worker: ?*exec.Task = null,

    // --- what to do, set before `start` ------------------------------------------
    kind: Kind = .check,
    /// The package; empty for the one the library looks for.
    source: [source_max:0]u8 = @splat(0),
    boot: bool = false,
    force: bool = false,

    // --- between them, under `lock` ------------------------------------------------
    lock: exec.SignalSemaphore = .{},
    /// Rows made and not yet taken by the window.
    rows: exec.List = .{},
    /// The last line said; whether the run failed is its code's to say.
    line: [line_max:0]u8 = @splat(0),
    /// What has been written so far.
    wrote_bytes: u64 = 0,
    wrote_files: u32 = 0,

    // --- the end, set by the worker before it ends -------------------------------
    code: i32 = dos.RETURN_OK,
    info: update.UpdateInfo = .{},
    /// The package that was read, which `info.source` points into.
    used: [source_max:0]u8 = @splat(0),

    /// A job for the window that calls this: its signal and the port its
    /// worker's end comes to. False without them.
    pub fn init(job: *Job, sys: *ExecBase, dl: *DosBase) bool {
        const end_port = sys.CreateMsgPort() orelse return false;
        const news_bit = sys.AllocSignal(-1);
        if (news_bit < 0) {
            sys.DeleteMsgPort(end_port);
            return false;
        }
        job.* = .{
            .sys = sys,
            .dl = dl,
            .window = sys.FindTask(null).?,
            .news_bit = news_bit,
            .end_port = end_port,
        };
        job.ended = .{ .reply_port = end_port, .length = @sizeOf(exec.Message) };
        job.rows.init(.unknown);
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
        lb.freeRows(job.sys, &job.rows);
        job.line = @splat(0);
        job.wrote_bytes = 0;
        job.wrote_files = 0;
        job.sys.ReleaseSemaphore(&job.lock);
        job.code = dos.RETURN_OK;
        job.info = .{};
        job.used = @splat(0);
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

    /// The run told to stop, between two files.
    pub fn stop(job: *Job) void {
        if (job.worker) |worker| job.sys.Signal(worker, exec.SIGBREAKF_CTRL_C);
    }

    /// Whether the worker's end has come: then `code`, `info` and `used`
    /// are what it came to, and another job can start.
    pub fn finished(job: *Job) bool {
        var gone = false;
        while (job.sys.GetMsg(job.end_port)) |message| {
            if (message == &job.ended) gone = true;
        }
        if (gone) job.worker = null;
        return gone;
    }

    /// The rows made since the last take moved onto `into`, and the rest
    /// of what was said copied out: the last line, and what has been
    /// written so far.
    pub fn take(job: *Job, into: *exec.List, line: *[line_max:0]u8, wrote_bytes: *u64, wrote_files: *u32) void {
        const sys = job.sys;
        sys.ObtainSemaphore(&job.lock);
        defer sys.ReleaseSemaphore(&job.lock);
        while (sys.RemHead(&job.rows)) |node| sys.AddTail(into, node);
        line.* = job.line;
        wrote_bytes.* = job.wrote_bytes;
        wrote_files.* = job.wrote_files;
    }

    /// Stopped and waited for, as the window closes; what was not taken
    /// let go with the signal and the port.
    pub fn free(job: *Job) void {
        const sys = job.sys;
        if (job.worker) |worker| {
            sys.Signal(worker, exec.SIGBREAKF_CTRL_C);
            while (!job.finished()) _ = sys.WaitPort(job.end_port);
        }
        lb.freeRows(sys, &job.rows);
        sys.FreeSignal(job.news_bit);
        sys.DeleteMsgPort(job.end_port);
    }

    // --- the worker's --------------------------------------------------------------

    /// The job done, on the worker.
    fn serve(job: *Job) void {
        const sys = job.sys;
        const library = sys.OpenLibrary(update.UPDATENAME, 1) orelse {
            job.said("update.library 1 is not there");
            job.code = dos.RETURN_FAIL;
            return;
        };
        defer sys.CloseLibrary(library);
        const upd: *UpdateBase = @ptrCast(library);
        var hook: utility.Hook = .{ .entry = &heard, .data = job };

        switch (job.kind) {
            .look, .keep => {
                job.code = upd.ConfirmUpdate(&[_]TagItem{
                    .{ .tag = update.UPD_Check, .data = @intFromBool(job.kind == .look) },
                    .{ .tag = update.UPD_Hook, .data = @intFromPtr(&hook) },
                    .{},
                });
                return;
            },
            .check, .update => {},
        }
        const named = job.source[0] != 0;
        const run = upd.CreateUpdate(&[_]TagItem{
            .{ .tag = if (named) update.UPD_Source else utility.TAG_IGNORE, .data = @intFromPtr(&job.source) },
            .{ .tag = update.UPD_Hook, .data = @intFromPtr(&hook) },
            .{},
        }) orelse {
            job.code = dos.RETURN_FAIL;
            return;
        };
        defer upd.DeleteUpdate(run);
        job.code = upd.DoUpdate(run, &[_]TagItem{
            .{ .tag = update.UPD_Check, .data = @intFromBool(job.kind == .check) },
            .{ .tag = update.UPD_Boot, .data = @intFromBool(job.boot) },
            .{ .tag = update.UPD_Force, .data = @intFromBool(job.force) },
            .{},
        });
        upd.GetUpdateInfo(run, &job.info);
        copyText(&job.used, job.info.source);
        job.info.source = @ptrCast(&job.used);
    }

    /// A line kept as the last one said, and the window told.
    fn said(job: *Job, text: [*:0]const u8) void {
        job.sys.ObtainSemaphore(&job.lock);
        copyText(&job.line, text);
        job.sys.ReleaseSemaphore(&job.lock);
        job.sys.Signal(job.window, job.signal());
    }
};

/// What update.library said, on the worker: a row, a file in place, or a
/// line. A look's words are not shown - only its answer is.
fn heard(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const job: *Job = @ptrCast(@alignCast(hook.data.?));
    const said: *const update.UpdateMessage = @ptrCast(@alignCast(message.?));
    const sys = job.sys;
    switch (said.kind) {
        update.UPDM_PATH => {
            var size: [16:0]u8 = @splat(0);
            if (said.bytes != 0) update.bytesAsText(&size, said.bytes);
            const texts = [_][*:0]const u8{ said.what, said.text, @ptrCast(&size) };
            const row = lb.allocRow(sys, &texts, 0) orelse return 0;
            sys.ObtainSemaphore(&job.lock);
            sys.AddTail(&job.rows, &row.node);
            sys.ReleaseSemaphore(&job.lock);
            sys.Signal(job.window, job.signal());
        },
        update.UPDM_WROTE => {
            sys.ObtainSemaphore(&job.lock);
            job.wrote_bytes += said.bytes;
            job.wrote_files += 1;
            sys.ReleaseSemaphore(&job.lock);
            sys.Signal(job.window, job.signal());
        },
        else => if (job.kind != .look) job.said(said.text),
    }
    return 0;
}

fn workerEntry(sys: *ExecBase) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    job.serve();
}

/// `from` into `into`, cut to fit, the rest of it NULs.
pub fn copyText(into: anytype, from: [*:0]const u8) void {
    into.* = @splat(0);
    var at: usize = 0;
    while (from[at] != 0 and at < into.len) : (at += 1) into[at] = from[at];
}
