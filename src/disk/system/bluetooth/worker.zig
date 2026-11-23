// SPDX-License-Identifier: MIT
//! The calls that wait for a device - a link made or ended, a bond ended
//! - made on a process of the window's own, "Bluetooth worker", so that
//! the window goes on drawing, and answering what a pairing asks, while a
//! device is paged or does not answer. The window asks for one call at a
//! time (`ask`) and dims what would ask for another until the worker has
//! signalled its end, which the window then takes (`take`). The worker
//! ends when it is told to (`free`), after the call it is in, which the
//! window does once its own window is gone.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const TagItem = sdk.utility.TagItem;

const process_name = "Bluetooth worker";
const process_priority = 0;
const process_stack = 2 * dos.CLI_DEFAULT_STACK;
/// What the window signals the worker with: a call asked for.
const asked_signal = exec.SIGBREAKF_CTRL_F;

/// The longest name a job keeps of its device, its NUL aside.
pub const who_most = bluetooth.BT_BOND_NAME_MOST;

pub const Kind = enum(u32) {
    /// ConnectBTDevice.
    connect,
    /// DisconnectBTDevice.
    disconnect,
    /// UnpairBTDevice.
    forget,
};

/// A call asked for, and what the window says of its device.
pub const Job = struct {
    kind: Kind = .connect,
    controller: u32 = 0,
    address: bluetooth.BTAddress = .{},
    who: [who_most + 1]u8 = @splat(0),
};

pub const Worker = struct {
    sys: *ExecBase,
    bt: *BluetoothBase,

    // --- the window's ------------------------------------------------------------

    window: *exec.Task,
    news_bit: i8,
    end_port: *exec.MsgPort,
    ended: exec.Message = .{},
    gone: bool = false,
    process: *exec.Task = undefined,

    // --- between them, under `lock` ------------------------------------------------

    lock: exec.SignalSemaphore = .{},
    /// The calls asked for and answered, counted; the last asked, and the
    /// last answered with its result.
    asked: u32 = 0,
    answered: u32 = 0,
    taken: u32 = 0,
    job: Job = .{},
    done: Job = .{},
    result: i32 = 0,
    /// The window told the worker to end.
    halted: u32 = 0,

    // --- the window's calls ------------------------------------------------------

    /// The worker started on `bt`; null without the memory, a signal or
    /// the process.
    pub fn start(sys: *ExecBase, dl: *DosBase, bt: *BluetoothBase) ?*Worker {
        const memory = sys.AllocVec(@sizeOf(Worker), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
        const end_port = sys.CreateMsgPort();
        const news_bit = sys.AllocSignal(-1);
        if (end_port == null or news_bit < 0) {
            if (news_bit >= 0) sys.FreeSignal(news_bit);
            sys.DeleteMsgPort(end_port);
            sys.FreeVec(memory);
            return null;
        }
        const worker: *Worker = @ptrCast(@alignCast(memory));
        worker.* = .{
            .sys = sys,
            .bt = bt,
            .window = sys.FindTask(null).?,
            .news_bit = news_bit,
            .end_port = end_port.?,
        };
        worker.ended = .{ .reply_port = worker.end_port, .length = @sizeOf(exec.Message) };
        sys.InitSemaphore(&worker.lock);
        const tags = [_]TagItem{
            .{ .tag = dos.NP_Entry, .data = @intFromPtr(&workerEntry) },
            .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
            .{ .tag = dos.NP_UserData, .data = @intFromPtr(worker) },
            .{ .tag = dos.NP_StackSize, .data = process_stack },
            .{ .tag = dos.NP_Priority, .data = @bitCast(@as(isize, process_priority)) },
            .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&worker.ended) },
            .{},
        };
        const process = dl.CreateNewProc(&tags) orelse {
            worker.freeParts();
            return null;
        };
        worker.process = &process.task;
        return worker;
    }

    /// The worker told to end and waited for until it is gone - after the
    /// call it is in; then the rest given back.
    pub fn free(worker: *Worker) void {
        const sys = worker.sys;
        @atomicStore(u32, &worker.halted, 1, .seq_cst);
        sys.Signal(worker.process, exec.SIGBREAKF_CTRL_C);
        while (!worker.gone) {
            while (sys.GetMsg(worker.end_port)) |message| {
                if (message == &worker.ended) worker.gone = true;
            }
            if (!worker.gone) _ = sys.WaitPort(worker.end_port);
        }
        worker.freeParts();
    }

    fn freeParts(worker: *Worker) void {
        const sys = worker.sys;
        sys.FreeSignal(worker.news_bit);
        sys.DeleteMsgPort(worker.end_port);
        sys.FreeVec(worker);
    }

    /// The window's signal: a call is over.
    pub fn signal(worker: *const Worker) u32 {
        return @as(u32, 1) << @intCast(worker.news_bit);
    }

    /// `job` asked for. One at a time: the window asks for none while
    /// `busy`.
    pub fn ask(worker: *Worker, job: *const Job) void {
        const sys = worker.sys;
        sys.ObtainSemaphore(&worker.lock);
        worker.job = job.*;
        worker.asked +%= 1;
        sys.ReleaseSemaphore(&worker.lock);
        sys.Signal(worker.process, asked_signal);
    }

    /// Whether a call asked for is not over yet.
    pub fn busy(worker: *Worker) bool {
        worker.sys.ObtainSemaphore(&worker.lock);
        defer worker.sys.ReleaseSemaphore(&worker.lock);
        return worker.asked != worker.answered;
    }

    /// The call over since the last take, into `into` with its result:
    /// false where none is.
    pub fn take(worker: *Worker, into: *Job, result: *i32) bool {
        worker.sys.ObtainSemaphore(&worker.lock);
        defer worker.sys.ReleaseSemaphore(&worker.lock);
        if (worker.taken == worker.answered) return false;
        worker.taken = worker.answered;
        into.* = worker.done;
        result.* = worker.result;
        return true;
    }

    // --- the worker -------------------------------------------------------------------

    fn isHalted(worker: *const Worker) bool {
        return @atomicLoad(u32, &worker.halted, .seq_cst) != 0;
    }

    /// Each call asked for made, until the window tells the worker to end.
    fn serve(worker: *Worker) void {
        const sys = worker.sys;
        const bt = worker.bt;
        while (!worker.isHalted()) {
            sys.ObtainSemaphore(&worker.lock);
            const round = worker.asked;
            const job = worker.job;
            const pending = round != worker.answered;
            sys.ReleaseSemaphore(&worker.lock);
            if (!pending) {
                _ = sys.Wait(asked_signal | exec.SIGBREAKF_CTRL_C);
                continue;
            }
            const result = switch (job.kind) {
                .connect => bt.ConnectBTDevice(job.controller, &job.address),
                .disconnect => bt.DisconnectBTDevice(job.controller, &job.address),
                .forget => bt.UnpairBTDevice(job.controller, &job.address),
            };
            sys.ObtainSemaphore(&worker.lock);
            worker.done = job;
            worker.result = result;
            worker.answered = round;
            sys.ReleaseSemaphore(&worker.lock);
            sys.Signal(worker.window, worker.signal());
        }
    }
};

fn workerEntry(sys: *ExecBase) callconv(.c) void {
    const worker: *Worker = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    worker.serve();
}
