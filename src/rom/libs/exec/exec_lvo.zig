// SPDX-License-Identifier: MPL-2.0
//! exec.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's contract.
//!
//! Each wrapper is the slot a caller reaches through the table. It hands
//! the work to the implementation - a file of its own in the folder for its
//! area, which carries the call's full contract in the form docs/style.md
//! sets out - with exec's base first.
//!
//! The sections follow the table's order: libraries, lists and holding the
//! scheduler, memory, interrupts, tasks, signals, messages and ports,
//! semaphores, devices and I/O, residents, the raw port, resources, the
//! caches, looking at the system, and memory pools.

const std = @import("std");
const sdk = @import("sdk");
const exec = @import("exec.zig");
const exec_base = @import("exec_base.zig");
const _interrupt = @import("interrupt/_interrupt.zig");
const int_vector = @import("interrupt/intvector.zig");

const vec = sdk.exec.vec;
const ExecBase = exec.ExecBase;
const Device = sdk.exec.Device;
const IORequest = sdk.exec.IORequest;
const Interrupt = sdk.exec.Interrupt;
const IntVector = sdk.exec.IntVector;
const Library = sdk.exec.Library;
const LibraryInit = sdk.exec.LibraryInit;
const List = sdk.exec.List;
const MemHeader = sdk.exec.MemHeader;
const Message = sdk.exec.Message;
const MsgPort = sdk.exec.MsgPort;
const Node = sdk.exec.Node;
const PutChProc = sdk.exec.PutChProc;
const Resident = sdk.exec.Resident;
const SemaphoreMessage = sdk.exec.SemaphoreMessage;
const SignalSemaphore = sdk.exec.SignalSemaphore;
const Task = sdk.exec.Task;
const TaskFn = sdk.exec.TaskFn;
const TrapFn = sdk.exec.TrapFn;

// exec implements the SDK's contract: every function in LVO is an lvo*
// function here, with the signature the SDK gives it (after the base).
comptime {
    @setEvalBranchQuota(20_000);
    for (@typeInfo(exec.LVO).@"struct".decls) |d| {
        if (!sdk.exec.libraries.sameSignature(@TypeOf(&@field(@This(), "lvo" ++ d.name)), @field(exec.interface.Fn, d.name))) {
            @compileError("exec's lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it. The number in a
// SINCE line is written by hand and read by whoever writes against exec, so
// nothing else would ever compare the two. It caught one wrong already.
comptime {
    // One quota for the whole run: the files' branches add up.
    @setEvalBranchQuota(50_000_000);
    for (contract_files) |source| {
        sdk.exec.libraries.checkDocumentedLvosAt(source, exec.LVO, exec.LIBRARY_NAME, "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`: every
/// call of the table.
const contract_files = [_][]const u8{
    @embedFile("list/execlist.zig"),
    @embedFile("interrupt/intvector.zig"),
    @embedFile("resident/resmodules.zig"),
    @embedFile("library/setramlib.zig"),
    @embedFile("library/ramlib.zig"),
    @embedFile("library/makelibrary.zig"),
    @embedFile("library/addlibrary.zig"),
    @embedFile("library/remlibrary.zig"),
    @embedFile("library/openlibrary.zig"),
    @embedFile("library/closelibrary.zig"),
    @embedFile("library/setfunction.zig"),
    @embedFile("library/createlibrary.zig"),
    @embedFile("list/findname.zig"),
    @embedFile("task/forbid.zig"),
    @embedFile("task/permit.zig"),
    @embedFile("list/insert.zig"),
    @embedFile("list/addhead.zig"),
    @embedFile("list/addtail.zig"),
    @embedFile("list/remove.zig"),
    @embedFile("list/remhead.zig"),
    @embedFile("list/remtail.zig"),
    @embedFile("list/enqueue.zig"),
    @embedFile("list/newlist.zig"),
    @embedFile("memory/creatememheader.zig"),
    @embedFile("memory/addmemlist.zig"),
    @embedFile("memory/allocate.zig"),
    @embedFile("memory/deallocate.zig"),
    @embedFile("memory/allocmem.zig"),
    @embedFile("memory/freemem.zig"),
    @embedFile("memory/availmem.zig"),
    @embedFile("memory/addmemhandler.zig"),
    @embedFile("memory/remmemhandler.zig"),
    @embedFile("interrupt/setintvector.zig"),
    @embedFile("interrupt/addintserver.zig"),
    @embedFile("interrupt/remintserver.zig"),
    @embedFile("interrupt/disable.zig"),
    @embedFile("interrupt/enable.zig"),
    @embedFile("interrupt/cause.zig"),
    @embedFile("interrupt/alert.zig"),
    @embedFile("interrupt/settrapcode.zig"),
    @embedFile("task/addtask.zig"),
    @embedFile("task/remtask.zig"),
    @embedFile("task/findtask.zig"),
    @embedFile("task/settaskpri.zig"),
    @embedFile("task/signal.zig"),
    @embedFile("task/wait.zig"),
    @embedFile("task/setsignal.zig"),
    @embedFile("task/allocsignal.zig"),
    @embedFile("task/freesignal.zig"),
    @embedFile("task/createtask.zig"),
    @embedFile("task/setexcept.zig"),
    @embedFile("ports/putmsg.zig"),
    @embedFile("ports/getmsg.zig"),
    @embedFile("ports/replymsg.zig"),
    @embedFile("ports/waitport.zig"),
    @embedFile("ports/addport.zig"),
    @embedFile("ports/remport.zig"),
    @embedFile("ports/findport.zig"),
    @embedFile("ports/createmsgport.zig"),
    @embedFile("ports/deletemsgport.zig"),
    @embedFile("locks/initsemaphore.zig"),
    @embedFile("locks/obtainsemaphore.zig"),
    @embedFile("locks/releasesemaphore.zig"),
    @embedFile("locks/attemptsemaphore.zig"),
    @embedFile("locks/obtainsemaphorelist.zig"),
    @embedFile("locks/releasesemaphorelist.zig"),
    @embedFile("locks/findsemaphore.zig"),
    @embedFile("locks/addsemaphore.zig"),
    @embedFile("locks/remsemaphore.zig"),
    @embedFile("locks/obtainsemaphoreshared.zig"),
    @embedFile("locks/attemptsemaphoreshared.zig"),
    @embedFile("locks/procure.zig"),
    @embedFile("locks/vacate.zig"),
    @embedFile("memory/allocvec.zig"),
    @embedFile("memory/freevec.zig"),
    @embedFile("memory/copymem.zig"),
    @embedFile("memory/copymemquick.zig"),
    @embedFile("memory/setmem.zig"),
    @embedFile("device/adddevice.zig"),
    @embedFile("device/remdevice.zig"),
    @embedFile("device/opendevice.zig"),
    @embedFile("device/closedevice.zig"),
    @embedFile("device/doio.zig"),
    @embedFile("device/sendio.zig"),
    @embedFile("device/waitio.zig"),
    @embedFile("device/replyio.zig"),
    @embedFile("device/checkio.zig"),
    @embedFile("device/abortio.zig"),
    @embedFile("resident/findresident.zig"),
    @embedFile("resident/initcode.zig"),
    @embedFile("resident/initresident.zig"),
    @embedFile("device/createiorequest.zig"),
    @embedFile("device/deleteiorequest.zig"),
    @embedFile("rawio/rawdofmt.zig"),
    @embedFile("rawio/rawputchar.zig"),
    @embedFile("rawio/rawmaygetchar.zig"),
    @embedFile("rawio/rawioinit.zig"),
    @embedFile("library/addresource.zig"),
    @embedFile("library/remresource.zig"),
    @embedFile("library/openresource.zig"),
    @embedFile("interrupt/coldreboot.zig"),
    @embedFile("cache/cacheclearu.zig"),
    @embedFile("cache/cachecleare.zig"),
    @embedFile("cache/cachepredma.zig"),
    @embedFile("cache/cachepostdma.zig"),
    @embedFile("task/newstackrun.zig"),
    @embedFile("cache/codeaddress.zig"),
    @embedFile("memory/createpool.zig"),
    @embedFile("memory/deletepool.zig"),
    @embedFile("memory/allocpooled.zig"),
    @embedFile("memory/freepooled.zig"),
};

/// exec.library's jump table, in slot order: the four standard vectors,
/// then every call of the SDK's LVO.
pub const exec_vectors = [_]*const anyopaque{
    vec(exec_base.libOpen),
    vec(exec_base.libClose),
    vec(exec_base.execExpunge),
    vec(exec_base.libExtFunc),
    vec(lvoMakeLibrary),
    vec(lvoAddLibrary),
    vec(lvoRemLibrary),
    vec(lvoOpenLibrary),
    vec(lvoCloseLibrary),
    vec(lvoSetFunction),
    vec(lvoCreateLibrary),
    vec(lvoFindName),
    vec(lvoForbid),
    vec(lvoPermit),
    vec(lvoInsert),
    vec(lvoAddHead),
    vec(lvoAddTail),
    vec(lvoRemove),
    vec(lvoRemHead),
    vec(lvoRemTail),
    vec(lvoEnqueue),
    vec(lvoNewList),
    vec(lvoCreateMemHeader),
    vec(lvoAddMemList),
    vec(lvoAllocate),
    vec(lvoDeallocate),
    vec(lvoAllocMem),
    vec(lvoFreeMem),
    vec(lvoAvailMem),
    vec(lvoAddMemHandler),
    vec(lvoRemMemHandler),
    vec(lvoSetIntVector),
    vec(lvoAddIntServer),
    vec(lvoRemIntServer),
    vec(lvoDisable),
    vec(lvoEnable),
    vec(lvoCause),
    vec(lvoAlert),
    vec(lvoSetTrapCode),
    vec(lvoAddTask),
    vec(lvoRemTask),
    vec(lvoFindTask),
    vec(lvoSetTaskPri),
    vec(lvoSignal),
    vec(lvoWait),
    vec(lvoSetSignal),
    vec(lvoAllocSignal),
    vec(lvoFreeSignal),
    vec(lvoCreateTask),
    vec(lvoSetExcept),
    vec(lvoPutMsg),
    vec(lvoGetMsg),
    vec(lvoReplyMsg),
    vec(lvoWaitPort),
    vec(lvoAddPort),
    vec(lvoRemPort),
    vec(lvoFindPort),
    vec(lvoCreateMsgPort),
    vec(lvoDeleteMsgPort),
    vec(lvoInitSemaphore),
    vec(lvoObtainSemaphore),
    vec(lvoReleaseSemaphore),
    vec(lvoAttemptSemaphore),
    vec(lvoObtainSemaphoreList),
    vec(lvoReleaseSemaphoreList),
    vec(lvoFindSemaphore),
    vec(lvoAddSemaphore),
    vec(lvoRemSemaphore),
    vec(lvoObtainSemaphoreShared),
    vec(lvoAttemptSemaphoreShared),
    vec(lvoProcure),
    vec(lvoVacate),
    vec(lvoAllocVec),
    vec(lvoFreeVec),
    vec(lvoCopyMem),
    vec(lvoCopyMemQuick),
    vec(lvoSetMem),
    vec(lvoAddDevice),
    vec(lvoRemDevice),
    vec(lvoOpenDevice),
    vec(lvoCloseDevice),
    vec(lvoDoIO),
    vec(lvoSendIO),
    vec(lvoWaitIO),
    vec(lvoReplyIO),
    vec(lvoCheckIO),
    vec(lvoAbortIO),
    vec(lvoFindResident),
    vec(lvoInitCode),
    vec(lvoInitResident),
    vec(lvoCreateIORequest),
    vec(lvoDeleteIORequest),
    vec(lvoRawDoFmt),
    vec(lvoRawPutChar),
    vec(lvoRawMayGetChar),
    vec(lvoRawIOInit),
    vec(lvoAddResource),
    vec(lvoRemResource),
    vec(lvoOpenResource),
    vec(lvoColdReboot),
    vec(lvoCacheClearU),
    vec(lvoCacheClearE),
    vec(lvoCachePreDMA),
    vec(lvoCachePostDMA),
    vec(lvoNewStackRun),
    vec(lvoCodeAddress),
    vec(lvoExecList),
    vec(lvoIntVector),
    vec(lvoResModules),
    vec(lvoSetRamLib),
    vec(lvoRamLib),
    vec(lvoCreatePool),
    vec(lvoDeletePool),
    vec(lvoAllocPooled),
    vec(lvoFreePooled),
};

// --- libraries --------------------------------------------------------------

fn lvoMakeLibrary(base: *ExecBase, vectors: [*]const *const anyopaque, count: usize, data_size: usize, init_fn: ?sdk.exec.InitFn, seg_list: ?*anyopaque) callconv(.c) ?*Library {
    return exec.MakeLibrary(base, vectors[0..count], data_size, init_fn, seg_list);
}

fn lvoAddLibrary(base: *ExecBase, lib: *Library) callconv(.c) void {
    exec.AddLibrary(base, lib);
}

fn lvoRemLibrary(base: *ExecBase, lib: *Library) callconv(.c) ?*anyopaque {
    return exec.RemLibrary(base, lib);
}

fn lvoOpenLibrary(base: *ExecBase, name: [*:0]const u8, ver: u32) callconv(.c) ?*Library {
    return exec.OpenLibrary(base, name, ver);
}

fn lvoCloseLibrary(base: *ExecBase, lib: ?*Library) callconv(.c) void {
    exec.CloseLibrary(base, lib);
}

fn lvoSetFunction(base: *ExecBase, lib: *Library, offset: isize, new: *const anyopaque) callconv(.c) *const anyopaque {
    return exec.SetFunction(base, lib, offset, new);
}

fn lvoCreateLibrary(base: *ExecBase, desc: *const LibraryInit) callconv(.c) ?*Library {
    return exec.CreateLibrary(base, desc);
}
// --- lists, and holding the scheduler ---------------------------------------

fn lvoFindName(base: *ExecBase, list: *List, name: [*:0]const u8) callconv(.c) ?*Node {
    return exec.FindName(base, list, name);
}

fn lvoForbid(base: *ExecBase) callconv(.c) void {
    exec.Forbid(base);
}

fn lvoPermit(base: *ExecBase) callconv(.c) void {
    exec.Permit(base);
}

fn lvoInsert(base: *ExecBase, list: *List, node: *Node, pred: ?*Node) callconv(.c) void {
    exec.Insert(base, list, node, pred);
}

fn lvoAddHead(base: *ExecBase, list: *List, node: *Node) callconv(.c) void {
    exec.AddHead(base, list, node);
}

fn lvoAddTail(base: *ExecBase, list: *List, node: *Node) callconv(.c) void {
    exec.AddTail(base, list, node);
}

fn lvoRemove(base: *ExecBase, node: *Node) callconv(.c) void {
    exec.Remove(base, node);
}

fn lvoRemHead(base: *ExecBase, list: *List) callconv(.c) ?*Node {
    return exec.RemHead(base, list);
}

fn lvoRemTail(base: *ExecBase, list: *List) callconv(.c) ?*Node {
    return exec.RemTail(base, list);
}

fn lvoEnqueue(base: *ExecBase, list: *List, node: *Node) callconv(.c) void {
    exec.Enqueue(base, list, node);
}

fn lvoNewList(base: *ExecBase, list: *List) callconv(.c) void {
    exec.NewList(base, list);
}
// --- memory -----------------------------------------------------------------

fn lvoCreateMemHeader(base: *ExecBase, size: usize, attributes: u32, pri: i8, region: *anyopaque, name: ?[*:0]const u8) callconv(.c) ?*MemHeader {
    return exec.CreateMemHeader(base, size, attributes, pri, region, name);
}

fn lvoAddMemList(base: *ExecBase, size: usize, attributes: u32, pri: i8, region: *anyopaque, name: ?[*:0]const u8) callconv(.c) ?*MemHeader {
    return exec.AddMemList(base, size, attributes, pri, region, name);
}

fn lvoAllocate(base: *ExecBase, mh: *MemHeader, byte_size: usize) callconv(.c) ?*anyopaque {
    return exec.Allocate(base, mh, byte_size);
}

fn lvoDeallocate(base: *ExecBase, mh: *MemHeader, memory_block: ?*anyopaque, byte_size: usize) callconv(.c) void {
    exec.Deallocate(base, mh, memory_block, byte_size);
}

fn lvoAllocMem(base: *ExecBase, byte_size: usize, requirements: u32) callconv(.c) ?*anyopaque {
    return exec.AllocMem(base, byte_size, requirements);
}

fn lvoFreeMem(base: *ExecBase, memory_block: ?*anyopaque, byte_size: usize) callconv(.c) void {
    exec.FreeMem(base, memory_block, byte_size);
}

fn lvoAvailMem(base: *ExecBase, requirements: u32) callconv(.c) usize {
    return exec.AvailMem(base, requirements);
}

fn lvoAddMemHandler(base: *ExecBase, handler: *Interrupt) callconv(.c) void {
    exec.AddMemHandler(base, handler);
}

fn lvoRemMemHandler(base: *ExecBase, handler: *Interrupt) callconv(.c) void {
    exec.RemMemHandler(base, handler);
}
// --- interrupts and alerts --------------------------------------------------

fn lvoSetIntVector(base: *ExecBase, int_number: u32, interrupt: ?*Interrupt) callconv(.c) ?*Interrupt {
    return exec.SetIntVector(base, int_number, interrupt);
}

fn lvoAddIntServer(base: *ExecBase, int_number: u32, interrupt: *Interrupt) callconv(.c) void {
    exec.AddIntServer(base, int_number, interrupt);
}

fn lvoRemIntServer(base: *ExecBase, int_number: u32, interrupt: *Interrupt) callconv(.c) void {
    exec.RemIntServer(base, int_number, interrupt);
}

fn lvoDisable(base: *ExecBase) callconv(.c) void {
    exec.Disable(base);
}

fn lvoEnable(base: *ExecBase) callconv(.c) void {
    exec.Enable(base);
}

fn lvoCause(base: *ExecBase, interrupt: *Interrupt) callconv(.c) void {
    exec.Cause(base, interrupt);
}

fn lvoAlert(_: *ExecBase, alert_num: u32) callconv(.c) void {
    _interrupt.alertAt(alert_num, @returnAddress());
}

fn lvoSetTrapCode(base: *ExecBase, code: ?TrapFn, data: ?*anyopaque) callconv(.c) ?TrapFn {
    return exec.SetTrapCode(base, code, data);
}
// --- tasks ------------------------------------------------------------------

fn lvoAddTask(base: *ExecBase, task: *Task, init_pc: TaskFn, final_pc: ?TaskFn) callconv(.c) *Task {
    return exec.AddTask(base, task, init_pc, final_pc);
}

fn lvoRemTask(base: *ExecBase, task: ?*Task) callconv(.c) void {
    exec.RemTask(base, task);
}

fn lvoFindTask(base: *ExecBase, name: ?[*:0]const u8) callconv(.c) ?*Task {
    return exec.FindTask(base, name);
}

fn lvoSetTaskPri(base: *ExecBase, task: *Task, pri: i8) callconv(.c) i8 {
    return exec.SetTaskPri(base, task, pri);
}
// --- signals ----------------------------------------------------------------

fn lvoSignal(base: *ExecBase, task: *Task, signals: u32) callconv(.c) void {
    exec.Signal(base, task, signals);
}

fn lvoWait(base: *ExecBase, signal_set: u32) callconv(.c) u32 {
    return exec.Wait(base, signal_set);
}

fn lvoSetSignal(base: *ExecBase, new_signals: u32, signal_mask: u32) callconv(.c) u32 {
    return exec.SetSignal(base, new_signals, signal_mask);
}

fn lvoAllocSignal(base: *ExecBase, signal_num: i8) callconv(.c) i8 {
    return exec.AllocSignal(base, signal_num);
}

fn lvoFreeSignal(base: *ExecBase, signal_num: i8) callconv(.c) void {
    exec.FreeSignal(base, signal_num);
}
fn lvoCreateTask(base: *ExecBase, name: [*:0]const u8, pri: i8, init_pc: TaskFn, stack_size: usize) callconv(.c) ?*Task {
    return exec.CreateTask(base, std.mem.span(name), pri, init_pc, stack_size);
}
fn lvoSetExcept(base: *ExecBase, new_signals: u32, signal_set: u32) callconv(.c) u32 {
    return exec.SetExcept(base, new_signals, signal_set);
}
// --- messages and ports -----------------------------------------------------

fn lvoPutMsg(base: *ExecBase, port: *MsgPort, msg: *Message) callconv(.c) void {
    exec.PutMsg(base, port, msg);
}

fn lvoGetMsg(base: *ExecBase, port: *MsgPort) callconv(.c) ?*Message {
    return exec.GetMsg(base, port);
}

fn lvoReplyMsg(base: *ExecBase, msg: *Message) callconv(.c) void {
    exec.ReplyMsg(base, msg);
}

fn lvoWaitPort(base: *ExecBase, port: *MsgPort) callconv(.c) *Message {
    return exec.WaitPort(base, port);
}

fn lvoAddPort(base: *ExecBase, port: *MsgPort) callconv(.c) void {
    exec.AddPort(base, port);
}

fn lvoRemPort(base: *ExecBase, port: *MsgPort) callconv(.c) void {
    exec.RemPort(base, port);
}

fn lvoFindPort(base: *ExecBase, name: [*:0]const u8) callconv(.c) ?*MsgPort {
    return exec.FindPort(base, name);
}

fn lvoCreateMsgPort(base: *ExecBase) callconv(.c) ?*MsgPort {
    return exec.CreateMsgPort(base);
}

fn lvoDeleteMsgPort(base: *ExecBase, port: ?*MsgPort) callconv(.c) void {
    exec.DeleteMsgPort(base, port);
}
// --- semaphores -------------------------------------------------------------

fn lvoInitSemaphore(base: *ExecBase, sem: *SignalSemaphore) callconv(.c) void {
    exec.InitSemaphore(base, sem);
}

fn lvoObtainSemaphore(base: *ExecBase, sem: *SignalSemaphore) callconv(.c) void {
    exec.ObtainSemaphore(base, sem);
}

fn lvoReleaseSemaphore(base: *ExecBase, sem: *SignalSemaphore) callconv(.c) void {
    exec.ReleaseSemaphore(base, sem);
}

fn lvoAttemptSemaphore(base: *ExecBase, sem: *SignalSemaphore) callconv(.c) bool {
    return exec.AttemptSemaphore(base, sem);
}

fn lvoObtainSemaphoreList(base: *ExecBase, list: *List) callconv(.c) void {
    exec.ObtainSemaphoreList(base, list);
}

fn lvoReleaseSemaphoreList(base: *ExecBase, list: *List) callconv(.c) void {
    exec.ReleaseSemaphoreList(base, list);
}

fn lvoFindSemaphore(base: *ExecBase, name: [*:0]const u8) callconv(.c) ?*SignalSemaphore {
    return exec.FindSemaphore(base, name);
}

fn lvoAddSemaphore(base: *ExecBase, sem: *SignalSemaphore) callconv(.c) void {
    exec.AddSemaphore(base, sem);
}

fn lvoRemSemaphore(base: *ExecBase, sem: *SignalSemaphore) callconv(.c) void {
    exec.RemSemaphore(base, sem);
}

fn lvoObtainSemaphoreShared(base: *ExecBase, sem: *SignalSemaphore) callconv(.c) void {
    exec.ObtainSemaphoreShared(base, sem);
}

fn lvoAttemptSemaphoreShared(base: *ExecBase, sem: *SignalSemaphore) callconv(.c) bool {
    return exec.AttemptSemaphoreShared(base, sem);
}

fn lvoProcure(base: *ExecBase, sem: *SignalSemaphore, bid: *SemaphoreMessage) callconv(.c) void {
    exec.Procure(base, sem, bid);
}

fn lvoVacate(base: *ExecBase, sem: *SignalSemaphore, bid: *SemaphoreMessage) callconv(.c) void {
    exec.Vacate(base, sem, bid);
}
// --- memory that remembers its size, and moving bytes -----------------------

fn lvoAllocVec(base: *ExecBase, byte_size: usize, requirements: u32) callconv(.c) ?*anyopaque {
    return exec.AllocVec(base, byte_size, requirements);
}

fn lvoFreeVec(base: *ExecBase, memory_block: ?*anyopaque) callconv(.c) void {
    exec.FreeVec(base, memory_block);
}

fn lvoCopyMem(base: *ExecBase, source: *const anyopaque, dest: *anyopaque, size: usize) callconv(.c) void {
    exec.CopyMem(base, source, dest, size);
}

fn lvoCopyMemQuick(base: *ExecBase, source: *const anyopaque, dest: *anyopaque, size: usize) callconv(.c) void {
    exec.CopyMemQuick(base, source, dest, size);
}

fn lvoSetMem(base: *ExecBase, dest: *anyopaque, value: u8, size: usize) callconv(.c) void {
    exec.SetMem(base, dest, value, size);
}
// --- devices and I/O --------------------------------------------------------

fn lvoAddDevice(base: *ExecBase, dev: *Device) callconv(.c) void {
    exec.AddDevice(base, dev);
}

fn lvoRemDevice(base: *ExecBase, dev: *Device) callconv(.c) ?*anyopaque {
    return exec.RemDevice(base, dev);
}

fn lvoOpenDevice(base: *ExecBase, name: [*:0]const u8, unit: u32, io: *IORequest, flags: u32) callconv(.c) i32 {
    return exec.OpenDevice(base, name, unit, io, flags);
}

fn lvoCloseDevice(base: *ExecBase, io: *IORequest) callconv(.c) void {
    exec.CloseDevice(base, io);
}

fn lvoDoIO(base: *ExecBase, io: *IORequest) callconv(.c) i32 {
    return exec.DoIO(base, io);
}

fn lvoSendIO(base: *ExecBase, io: *IORequest) callconv(.c) void {
    exec.SendIO(base, io);
}

fn lvoWaitIO(base: *ExecBase, io: *IORequest) callconv(.c) i32 {
    return exec.WaitIO(base, io);
}

fn lvoReplyIO(base: *ExecBase, io: *IORequest) callconv(.c) void {
    exec.ReplyIO(base, io);
}

fn lvoCheckIO(base: *ExecBase, io: *IORequest) callconv(.c) ?*IORequest {
    return exec.CheckIO(base, io);
}

fn lvoAbortIO(base: *ExecBase, io: *IORequest) callconv(.c) i32 {
    return exec.AbortIO(base, io);
}
// --- resident modules -------------------------------------------------------

fn lvoFindResident(base: *ExecBase, name: [*:0]const u8) callconv(.c) ?*const Resident {
    return exec.FindResident(base, name);
}

fn lvoInitCode(base: *ExecBase, start_class: u32, min_version: u32) callconv(.c) ?*anyopaque {
    return exec.InitCode(base, start_class, min_version);
}

fn lvoInitResident(base: *ExecBase, tag: *const Resident, seg_list: ?*anyopaque) callconv(.c) ?*anyopaque {
    return exec.InitResident(base, tag, seg_list);
}
fn lvoCreateIORequest(base: *ExecBase, reply_port: ?*MsgPort, size: u32) callconv(.c) ?*IORequest {
    return exec.CreateIORequest(base, reply_port, size);
}

fn lvoDeleteIORequest(base: *ExecBase, io: ?*IORequest) callconv(.c) void {
    exec.DeleteIORequest(base, io);
}
// --- formatting, and exec's own console -------------------------------------

fn lvoRawDoFmt(base: *ExecBase, format_string: [*:0]const u8, data_stream: ?*const anyopaque, put_ch_proc: ?PutChProc, put_ch_data: ?*anyopaque) callconv(.c) ?*const anyopaque {
    return exec.RawDoFmt(base, format_string, data_stream, put_ch_proc, put_ch_data);
}

fn lvoRawPutChar(base: *ExecBase, ch: u8) callconv(.c) void {
    exec.RawPutChar(base, ch);
}

fn lvoRawMayGetChar(base: *ExecBase) callconv(.c) i32 {
    return exec.RawMayGetChar(base);
}

fn lvoRawIOInit(base: *ExecBase) callconv(.c) void {
    exec.RawIOInit(base);
}
// --- resources, and starting again ------------------------------------------

fn lvoAddResource(base: *ExecBase, resource: *anyopaque) callconv(.c) void {
    exec.AddResource(base, resource);
}

fn lvoRemResource(base: *ExecBase, resource: *anyopaque) callconv(.c) void {
    exec.RemResource(base, resource);
}

fn lvoOpenResource(base: *ExecBase, res_name: [*:0]const u8) callconv(.c) ?*anyopaque {
    return exec.OpenResource(base, res_name);
}

fn lvoColdReboot(base: *ExecBase) callconv(.c) noreturn {
    exec.ColdReboot(base);
}
// --- the caches -------------------------------------------------------------

fn lvoCacheClearU(base: *ExecBase) callconv(.c) void {
    exec.CacheClearU(base);
}

fn lvoCacheClearE(base: *ExecBase, address: *anyopaque, length: u32, caches: u32) callconv(.c) void {
    exec.CacheClearE(base, address, length, caches);
}

fn lvoCachePreDMA(base: *ExecBase, address: *anyopaque, length: *u32, flags: u32) callconv(.c) *anyopaque {
    return exec.CachePreDMA(base, address, length, flags);
}

fn lvoCachePostDMA(base: *ExecBase, address: *anyopaque, length: *u32, flags: u32) callconv(.c) void {
    exec.CachePostDMA(base, address, length, flags);
}
fn lvoNewStackRun(base: *ExecBase, code: sdk.exec.StackFn, arg: ?*anyopaque, stack_size: u32) callconv(.c) i32 {
    return exec.NewStackRun(base, code, arg, stack_size);
}
fn lvoCodeAddress(base: *ExecBase, address: *anyopaque, length: u32) callconv(.c) ?*anyopaque {
    return exec.CodeAddress(base, address, length);
}

// --- looking at the system --------------------------------------------------

fn lvoExecList(base: *ExecBase, which: u32) callconv(.c) ?*List {
    return exec.ExecList(base, which);
}

fn lvoIntVector(base: *ExecBase, int_number: u32) callconv(.c) ?*IntVector {
    return int_vector.IntVector(base, int_number);
}

fn lvoResModules(base: *ExecBase) callconv(.c) ?[*]const ?*const Resident {
    return exec.ResModules(base);
}

fn lvoSetRamLib(base: *ExecBase, loader: ?*anyopaque) callconv(.c) void {
    exec.SetRamLib(base, loader);
}

fn lvoRamLib(base: *ExecBase) callconv(.c) ?*anyopaque {
    return exec.RamLib(base);
}

// --- memory pools -----------------------------------------------------------

fn lvoCreatePool(base: *ExecBase, requirements: u32, puddle_size: usize, thresh_size: usize) callconv(.c) ?*anyopaque {
    return exec.CreatePool(base, requirements, puddle_size, thresh_size);
}

fn lvoDeletePool(base: *ExecBase, pool: ?*anyopaque) callconv(.c) void {
    exec.DeletePool(base, pool);
}

fn lvoAllocPooled(base: *ExecBase, pool: ?*anyopaque, byte_size: usize) callconv(.c) ?*anyopaque {
    return exec.AllocPooled(base, pool, byte_size);
}

fn lvoFreePooled(base: *ExecBase, pool: ?*anyopaque, memory_block: ?*anyopaque, byte_size: usize) callconv(.c) void {
    exec.FreePooled(base, pool, memory_block, byte_size);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "ExecList hands back exec's own lists, and IntVector its own vectors" {
    try exec.setUp();
    defer exec.deinit();
    const base = exec.SysBase;

    // Each number is the list it says it is, and it is exec's list, not a
    // copy: the addresses are the ones in the base.
    try testing.expectEqual(&base.lib_list, lvoExecListFor(sdk.exec.EXECLIST_LIBRARIES).?);
    try testing.expectEqual(&base.device_list, lvoExecListFor(sdk.exec.EXECLIST_DEVICES).?);
    try testing.expectEqual(&base.resource_list, lvoExecListFor(sdk.exec.EXECLIST_RESOURCES).?);
    try testing.expectEqual(&base.port_list, lvoExecListFor(sdk.exec.EXECLIST_PORTS).?);
    try testing.expectEqual(&base.sem_list, lvoExecListFor(sdk.exec.EXECLIST_SEMAPHORES).?);
    try testing.expectEqual(&base.mem_list, lvoExecListFor(sdk.exec.EXECLIST_MEMORY).?);
    try testing.expectEqual(&base.task_ready, lvoExecListFor(sdk.exec.EXECLIST_TASK_READY).?);
    try testing.expectEqual(&base.task_wait, lvoExecListFor(sdk.exec.EXECLIST_TASK_WAIT).?);
    try testing.expectEqual(&base.mem_handlers, lvoExecListFor(sdk.exec.EXECLIST_MEM_HANDLERS).?);
    // A number it has not got is no list at all.
    try testing.expect(lvoExecListFor(9999) == null);

    // exec.library is on the list this call hands back, which is the whole
    // point of handing it back.
    try testing.expect(exec.FindName(exec.SysBase, lvoExecListFor(sdk.exec.EXECLIST_LIBRARIES).?, exec.LIBRARY_NAME) != null);

    // A vector per source, and nothing past the last.
    try testing.expect(lvoIntVector(base, 0) != null);
    try testing.expect(lvoIntVector(base, sdk.hardware.intbits.INTB_COUNT - 1) != null);
    try testing.expect(lvoIntVector(base, sdk.hardware.intbits.INTB_COUNT) == null);
    try testing.expectEqual(&base.int_vects[7], lvoIntVector(base, 7).?);
}

/// The call as a program makes it, without a jump table to go through.
fn lvoExecListFor(which: u32) ?*List {
    return lvoExecList(exec.SysBase, which);
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    // Alert takes the caller's address, which only the wrapper has, and
    // hands on to the helper that takes it.
    try sdk.exec.libraries.checkForwarding(@embedFile("exec_lvo.zig"), exec.LVO, &.{"Alert"});
}

test "the vector table: every function of the SDK's LVO at its slot" {
    try testing.expectEqual(sdk.exec.libraries.standard_vectors + @typeInfo(exec.LVO).@"struct".decls.len, exec_vectors.len);
    inline for (@typeInfo(exec.LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(exec.LVO, d.name), sdk.exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), exec_vectors[index]);
    }
}
