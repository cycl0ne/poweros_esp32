// SPDX-License-Identifier: MPL-2.0
//! exec, the kernel core. It owns the system memory list and the library
//! list, and SysBase is its own library base - on that list as
//! "exec.library", with exec's functions in its jump table, so that exec
//! is reached exactly as every other module is.
//!
//! **The jump table is exec_lvo.zig.** Each of its 111 entries is an
//! `lvo<Name>` wrapper there that hands over to an implementation in the
//! folders beside this file - list/, library/, memory/, interrupt/, task/,
//! ports/, locks/, device/, resident/, cache/ and rawio/ - a file per call,
//! carrying the call's full contract. The wrapper is the slot, which is why
//! it is the one piece of code allowed to reach an implementation directly.
//!
//! exec's ROM tag and init routine are exec_init.zig. This file holds
//! ExecBase and SysBase, what the bootstrap hands exec, the names the rest
//! of the kernel reaches exec by, and exec's host tests; the tests of the
//! jump table itself are with it.

const std = @import("std");
const sdk = @import("sdk");
/// exec.library's jump table: the wrapper in each slot, and the table.
const exec_lvo = @import("exec_lvo.zig");
/// exec's ROM tag and its init routine.
const exec_init = @import("exec_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from exec.
comptime {
    _ = &exec_init.exec_tag;
}
/// Libraries: making, adding, opening, patching, expunging (library/, and
/// the four standard vectors in exec_base.zig).
const _library = @import("library/_library.zig");
const exec_base = @import("exec_base.zig");
/// Memory regions, pools and the allocation trace (memory/).
const _memory = @import("memory/_memory.zig");
/// The allocation trace the shell reads and sets.
pub const Trace = _memory.Trace;
pub const trace = &_memory.trace;
/// Interrupt handlers, server chains, software interrupts, Disable
/// (interrupt/).
pub const Interrupt = sdk.exec.Interrupt;
pub const IntVector = sdk.exec.IntVector;
pub const IntHandlerFn = sdk.exec.IntHandlerFn;
pub const IntServerFn = sdk.exec.IntServerFn;
pub const InterruptHardware = _interrupt.InterruptHardware;
pub const SetIntVector = @import("interrupt/setintvector.zig").SetIntVector;
pub const AddIntServer = @import("interrupt/addintserver.zig").AddIntServer;
pub const RemIntServer = @import("interrupt/remintserver.zig").RemIntServer;
pub const Disable = @import("interrupt/disable.zig").Disable;
pub const Enable = @import("interrupt/enable.zig").Enable;
pub const dispatchInterrupt = _interrupt.dispatchInterrupt;
pub const Cause = @import("interrupt/cause.zig").Cause;
pub const SoftIntFn = sdk.exec.SoftIntFn;
pub const dispatchSoftInts = _interrupt.dispatchSoftInts;

/// CPU exceptions, trap codes and alerts (interrupt/).
const _interrupt = @import("interrupt/_interrupt.zig");
pub const TrapInfo = sdk.exec.TrapInfo;
pub const TrapFn = sdk.exec.TrapFn;
pub const AlertFn = _interrupt.AlertFn;
pub const Alert = @import("interrupt/alert.zig").Alert;
pub const SetTrapCode = @import("interrupt/settrapcode.zig").SetTrapCode;
pub const dispatchTrap = _interrupt.dispatchTrap;
pub const AT_DeadEnd = sdk.exec.AT_DeadEnd;
pub const AT_Recovery = sdk.exec.AT_Recovery;
pub const ACPU_Base = sdk.exec.ACPU_Base;
pub const AN_KernelPanic = sdk.exec.AN_KernelPanic;
pub const kernelPanic = _interrupt.kernelPanic;
pub const ColdReboot = @import("interrupt/coldreboot.zig").ColdReboot;

/// How alerts are shown; the kernel sets it before the bootstrap.
pub const alert_hook = &_interrupt.alert_hook;

/// RawDoFmt, the system's one formatter, and exec's own console (rawio/).
const _rawio = @import("rawio/_rawio.zig");
pub const RawDoFmt = @import("rawio/rawdofmt.zig").RawDoFmt;
pub const RawPutChar = @import("rawio/rawputchar.zig").RawPutChar;
pub const RawMayGetChar = @import("rawio/rawmaygetchar.zig").RawMayGetChar;
pub const RawIOInit = @import("rawio/rawioinit.zig").RawIOInit;
pub const kprintf = _rawio.kprintf;
pub const PutChProc = sdk.exec.PutChProc;
pub const RawIOHardware = _rawio.RawIOHardware;
/// The raw port's hardware: exec's own UART0 driver (rawio/_rawio.zig). Host
/// tests put their stub here.
pub const raw_io_hardware = &_rawio.raw_io_hardware;

/// The caches, and the two buses onto external memory (cache/).
const _cache = @import("cache/_cache.zig");
pub const CacheClearU = @import("cache/cacheclearu.zig").CacheClearU;
pub const CacheClearE = @import("cache/cachecleare.zig").CacheClearE;
pub const CachePreDMA = @import("cache/cachepredma.zig").CachePreDMA;
pub const CachePostDMA = @import("cache/cachepostdma.zig").CachePostDMA;
pub const CodeAddress = @import("cache/codeaddress.zig").CodeAddress;
pub const CodeMap = _cache.CodeMap;
/// Where loaded code runs (dos's LoadSeg); host tests point it at their own
/// memory.
pub const code_map = &_cache.code_map;
pub const CacheHardware = _cache.CacheHardware;
/// The caches' hardware: exec's own cache driver (cache/_cache.zig). Host
/// tests put their stub here.
pub const cache_hardware = &_cache.cache_hardware;

/// Tasks, signals and the scheduler (task/).
const _task = @import("task/_task.zig");
pub const Task = sdk.exec.Task;
pub const TaskState = sdk.exec.TaskState;
pub const TaskFn = sdk.exec.TaskFn;
pub const TaskSwitchFn = sdk.exec.TaskSwitchFn;
pub const TF_SWITCH = sdk.exec.TF_SWITCH;
pub const TF_LAUNCH = sdk.exec.TF_LAUNCH;
pub const TaskHardware = _task.TaskHardware;
pub const AddTask = @import("task/addtask.zig").AddTask;
pub const RemTask = @import("task/remtask.zig").RemTask;
pub const FindTask = @import("task/findtask.zig").FindTask;
pub const SetTaskPri = @import("task/settaskpri.zig").SetTaskPri;
pub const CreateTask = @import("task/createtask.zig").CreateTask;
pub const NewStackRun = @import("task/newstackrun.zig").NewStackRun;
pub const Forbid = @import("task/forbid.zig").Forbid;
pub const Permit = @import("task/permit.zig").Permit;
pub const interruptEnter = _task.interruptEnter;
pub const interruptExit = _task.interruptExit;
pub const tickQuantum = _task.tickQuantum;

/// Signals and task exceptions (task/).
pub const Signal = @import("task/signal.zig").Signal;
pub const Wait = @import("task/wait.zig").Wait;
pub const SetSignal = @import("task/setsignal.zig").SetSignal;
pub const AllocSignal = @import("task/allocsignal.zig").AllocSignal;
pub const FreeSignal = @import("task/freesignal.zig").FreeSignal;
pub const SetExcept = @import("task/setexcept.zig").SetExcept;
pub const ExceptFn = sdk.exec.tasks.ExceptFn;
pub const SIGF_ABORT = sdk.exec.tasks.SIGF_ABORT;
pub const SIGF_CHILD = sdk.exec.tasks.SIGF_CHILD;
pub const SIGF_SINGLE = sdk.exec.tasks.SIGF_SINGLE;
pub const SIGF_DOS = sdk.exec.tasks.SIGF_DOS;
pub const SIGBREAKF_CTRL_C = sdk.exec.tasks.SIGBREAKF_CTRL_C;
pub const SIGBREAKF_CTRL_D = sdk.exec.tasks.SIGBREAKF_CTRL_D;
pub const SIGBREAKF_CTRL_E = sdk.exec.tasks.SIGBREAKF_CTRL_E;
pub const SIGBREAKF_CTRL_F = sdk.exec.tasks.SIGBREAKF_CTRL_F;

/// Messages, which are passed by pointer and never copied (ports/).
pub const Message = sdk.exec.Message;
pub const PutMsg = @import("ports/putmsg.zig").PutMsg;
pub const GetMsg = @import("ports/getmsg.zig").GetMsg;
pub const ReplyMsg = @import("ports/replymsg.zig").ReplyMsg;

/// Message ports, and what each does when a message arrives (ports/).
pub const MsgPort = sdk.exec.MsgPort;
pub const WaitPort = @import("ports/waitport.zig").WaitPort;
pub const AddPort = @import("ports/addport.zig").AddPort;
pub const RemPort = @import("ports/remport.zig").RemPort;
pub const FindPort = @import("ports/findport.zig").FindPort;
pub const CreateMsgPort = @import("ports/createmsgport.zig").CreateMsgPort;
pub const DeleteMsgPort = @import("ports/deletemsgport.zig").DeleteMsgPort;
pub const PF_ACTION = sdk.exec.PF_ACTION;
pub const PA_SIGNAL = sdk.exec.PA_SIGNAL;
pub const PA_SOFTINT = sdk.exec.PA_SOFTINT;
pub const PA_IGNORE = sdk.exec.PA_IGNORE;

/// Signal semaphores: the lock for anywhere Forbid will not do (locks/).
const _locks = @import("locks/_locks.zig");
pub const SignalSemaphore = sdk.exec.SignalSemaphore;
pub const SemaphoreRequest = sdk.exec.SemaphoreRequest;
pub const InitSemaphore = @import("locks/initsemaphore.zig").InitSemaphore;
pub const ObtainSemaphore = @import("locks/obtainsemaphore.zig").ObtainSemaphore;
pub const ObtainSemaphoreShared = @import("locks/obtainsemaphoreshared.zig").ObtainSemaphoreShared;
pub const AttemptSemaphore = @import("locks/attemptsemaphore.zig").AttemptSemaphore;
pub const AttemptSemaphoreShared = @import("locks/attemptsemaphoreshared.zig").AttemptSemaphoreShared;
pub const ReleaseSemaphore = @import("locks/releasesemaphore.zig").ReleaseSemaphore;
pub const ObtainSemaphoreList = @import("locks/obtainsemaphorelist.zig").ObtainSemaphoreList;
pub const ReleaseSemaphoreList = @import("locks/releasesemaphorelist.zig").ReleaseSemaphoreList;
pub const AddSemaphore = @import("locks/addsemaphore.zig").AddSemaphore;
pub const RemSemaphore = @import("locks/remsemaphore.zig").RemSemaphore;
pub const FindSemaphore = @import("locks/findsemaphore.zig").FindSemaphore;
pub const AN_SemCorrupt = sdk.exec.AN_SemCorrupt;
pub const SemaphoreMessage = sdk.exec.SemaphoreMessage;
pub const Procure = @import("locks/procure.zig").Procure;
pub const Vacate = @import("locks/vacate.zig").Vacate;
pub const SM_EXCLUSIVE = sdk.exec.SM_EXCLUSIVE;
pub const SM_SHARED = sdk.exec.SM_SHARED;
pub const SFF_SAR = _task.SFF_SAR;
pub const SFF_TQE = _task.SFF_TQE;

/// How exec builds and switches task contexts; the kernel sets it before
/// the bootstrap (the default switches nothing, for host tests).
pub const task_hardware = &_task.task_hardware;

/// True once initExec has run (the kernel's trap code checks it).
pub var initialized = false;

/// Doubly linked lists, and the nodes on them (list/).
pub const Node = sdk.exec.Node;
pub const NodeType = sdk.exec.NodeType;
pub const List = sdk.exec.List;
pub const NewList = @import("list/newlist.zig").NewList;
pub const AddHead = @import("list/addhead.zig").AddHead;
pub const AddTail = @import("list/addtail.zig").AddTail;
pub const Insert = @import("list/insert.zig").Insert;
pub const Remove = @import("list/remove.zig").Remove;
pub const RemHead = @import("list/remhead.zig").RemHead;
pub const RemTail = @import("list/remtail.zig").RemTail;
pub const Enqueue = @import("list/enqueue.zig").Enqueue;
pub const FindName = @import("list/findname.zig").FindName;
pub const ExecList = @import("list/execlist.zig").ExecList;

pub const MemHeader = sdk.exec.MemHeader;
pub const MemChunk = sdk.exec.MemChunk;
pub const CreateMemHeader = @import("memory/creatememheader.zig").CreateMemHeader;
pub const AddMemList = @import("memory/addmemlist.zig").AddMemList;
pub const Allocate = @import("memory/allocate.zig").Allocate;
pub const Deallocate = @import("memory/deallocate.zig").Deallocate;
pub const AllocMem = @import("memory/allocmem.zig").AllocMem;
pub const FreeMem = @import("memory/freemem.zig").FreeMem;
pub const AvailMem = @import("memory/availmem.zig").AvailMem;
pub const AllocVec = @import("memory/allocvec.zig").AllocVec;
pub const FreeVec = @import("memory/freevec.zig").FreeVec;
pub const CreatePool = @import("memory/createpool.zig").CreatePool;
pub const DeletePool = @import("memory/deletepool.zig").DeletePool;
pub const AllocPooled = @import("memory/allocpooled.zig").AllocPooled;
pub const FreePooled = @import("memory/freepooled.zig").FreePooled;
/// Copying and filling memory (memory/).
pub const CopyMem = @import("memory/copymem.zig").CopyMem;
pub const CopyMemQuick = @import("memory/copymemquick.zig").CopyMemQuick;
pub const SetMem = @import("memory/setmem.zig").SetMem;

/// Devices: a library with BeginIO and AbortIO, opened with a request
/// (device/).
pub const Device = sdk.exec.Device;
pub const Unit = sdk.exec.Unit;
pub const IORequest = sdk.exec.IORequest;
pub const IOStdReq = sdk.exec.IOStdReq;
pub const AddDevice = @import("device/adddevice.zig").AddDevice;
pub const RemDevice = @import("device/remdevice.zig").RemDevice;
pub const OpenDevice = @import("device/opendevice.zig").OpenDevice;
pub const CloseDevice = @import("device/closedevice.zig").CloseDevice;
pub const DEV_BEGINIO = sdk.exec.DEV_BEGINIO;
pub const DEV_ABORTIO = sdk.exec.DEV_ABORTIO;
pub const IOF_QUICK = sdk.exec.IOF_QUICK;
pub const IOERR_OPENFAIL = sdk.exec.IOERR_OPENFAIL;
pub const IOERR_ABORTED = sdk.exec.IOERR_ABORTED;
pub const IOERR_NOCMD = sdk.exec.IOERR_NOCMD;
pub const IOERR_BADLENGTH = sdk.exec.IOERR_BADLENGTH;
pub const IOERR_NOREPLYPORT = sdk.exec.IOERR_NOREPLYPORT;
pub const CMD_READ = sdk.exec.CMD_READ;
pub const CMD_WRITE = sdk.exec.CMD_WRITE;

/// Resources: named system objects with no open count.
pub const AddResource = @import("library/addresource.zig").AddResource;
pub const RemResource = @import("library/remresource.zig").RemResource;
pub const OpenResource = @import("library/openresource.zig").OpenResource;

/// I/O on an open device, and the IOF_QUICK protocol it turns on
/// (device/; the protocol is described in device/doio.zig).
pub const DoIO = @import("device/doio.zig").DoIO;
pub const SendIO = @import("device/sendio.zig").SendIO;
pub const WaitIO = @import("device/waitio.zig").WaitIO;
pub const ReplyIO = @import("device/replyio.zig").ReplyIO;
pub const CheckIO = @import("device/checkio.zig").CheckIO;
pub const AbortIO = @import("device/abortio.zig").AbortIO;
pub const CreateIORequest = @import("device/createiorequest.zig").CreateIORequest;
pub const DeleteIORequest = @import("device/deleteiorequest.zig").DeleteIORequest;

/// ROM tags: what marks a module in an image, and what starts one
/// (resident/).
const _resident = @import("resident/_resident.zig");
pub const Resident = sdk.exec.Resident;
pub const InitTable = sdk.exec.InitTable;
pub const ResidentInitFn = sdk.exec.ResidentInitFn;
pub const RTC_MATCHWORD = sdk.exec.RTC_MATCHWORD;
pub const RTF_COLDSTART = sdk.exec.RTF_COLDSTART;
pub const RTF_SINGLETASK = sdk.exec.RTF_SINGLETASK;
pub const RTF_AFTERDOS = sdk.exec.RTF_AFTERDOS;
pub const RTF_AUTOINIT = sdk.exec.RTF_AUTOINIT;
pub const AG_MakeLib = sdk.exec.AG_MakeLib;
pub const FindResident = @import("resident/findresident.zig").FindResident;
pub const InitCode = @import("resident/initcode.zig").InitCode;
pub const InitResident = @import("resident/initresident.zig").InitResident;
pub const ResModules = @import("resident/resmodules.zig").ResModules;
pub const initResidents = _resident.initResidents;
/// A ROM tag by name, with no exec needed; the bootstrap finds exec's own
/// tag with it.
pub const findTag = _resident.findTag;
/// Laying exec.library out, for the bootstrap, which builds it before
/// there is an ExecBase (library/_library.zig).
pub const librarySizes = _library.librarySizes;
pub const buildLibrary = _library.buildLibrary;
/// Frees a library's memory, jump table included (library/_library.zig).
pub const freeLibraryMemory = _library.freeLibraryMemory;
/// A task's own code, run as its entry runs it (task/_task.zig).
pub const runCode = _task.runCode;
/// Whether anything listens to an interrupt number (interrupt/_interrupt.zig).
pub const inUse = _interrupt.inUse;
/// The formatter with no base, for the path that reports a broken machine
/// and may run before there is one (rawio/_rawio.zig).
pub const format = _rawio.format;
pub const AddMemHandler = @import("memory/addmemhandler.zig").AddMemHandler;
pub const RemMemHandler = @import("memory/remmemhandler.zig").RemMemHandler;
pub const MemHandlerData = sdk.exec.MemHandlerData;
pub const MemHandlerFn = sdk.exec.MemHandlerFn;
pub const MEMHF_RECYCLE = sdk.exec.MEMHF_RECYCLE;
pub const MEM_DID_NOTHING = sdk.exec.MEM_DID_NOTHING;
pub const MEM_ALL_DONE = sdk.exec.MEM_ALL_DONE;
pub const MEM_TRY_AGAIN = sdk.exec.MEM_TRY_AGAIN;
pub const MEM_BLOCKSIZE = sdk.exec.MEM_BLOCKSIZE;
pub const MEM_BLOCKMASK = sdk.exec.MEM_BLOCKMASK;
pub const MEMF_ANY = sdk.exec.MEMF_ANY;
pub const MEMF_INTERNAL = sdk.exec.MEMF_INTERNAL;
pub const MEMF_EXTERNAL = sdk.exec.MEMF_EXTERNAL;
pub const MEMF_DMA = sdk.exec.MEMF_DMA;
pub const MEMF_CLEAR = sdk.exec.MEMF_CLEAR;
pub const MEMF_LARGEST = sdk.exec.MEMF_LARGEST;
pub const MEMF_REVERSE = sdk.exec.MEMF_REVERSE;
pub const MEMF_TOTAL = sdk.exec.MEMF_TOTAL;
pub const MEMF_NO_EXPUNGE = sdk.exec.MEMF_NO_EXPUNGE;

pub const Library = sdk.exec.Library;
pub const LibraryInit = sdk.exec.LibraryInit;
pub const MakeLibrary = @import("library/makelibrary.zig").MakeLibrary;
pub const AddLibrary = @import("library/addlibrary.zig").AddLibrary;
pub const RemLibrary = @import("library/remlibrary.zig").RemLibrary;
pub const OpenLibrary = @import("library/openlibrary.zig").OpenLibrary;
pub const CloseLibrary = @import("library/closelibrary.zig").CloseLibrary;
pub const CreateLibrary = @import("library/createlibrary.zig").CreateLibrary;
pub const SetFunction = @import("library/setfunction.zig").SetFunction;
pub const SetRamLib = @import("library/setramlib.zig").SetRamLib;
pub const RamLib = @import("library/ramlib.zig").RamLib;
pub const SumLibrary = _library.SumLibrary;
pub const lvo = sdk.exec.lvo;
pub const vec = sdk.exec.vec;
pub const LIB_OPEN = sdk.exec.LIB_OPEN;
pub const LIB_CLOSE = sdk.exec.LIB_CLOSE;
pub const LIB_EXPUNGE = sdk.exec.LIB_EXPUNGE;
pub const LIB_EXTFUNC = sdk.exec.LIB_EXTFUNC;
pub const LIB_USERDEF = sdk.exec.LIB_USERDEF;
pub const LIBF_SUMMING = sdk.exec.LIBF_SUMMING;
pub const LIBF_CHANGED = sdk.exec.LIBF_CHANGED;
pub const LIBF_SUMUSED = sdk.exec.LIBF_SUMUSED;
pub const LIBF_DELEXP = sdk.exec.LIBF_DELEXP;

/// What exec is on the library list as, and its version: the ROM tag's
/// (exec_init.zig).
pub const LIBRARY_NAME = exec_init.LIBRARY_NAME;
pub const LIBRARY_VERSION = exec_init.LIBRARY_VERSION;
pub const LIBRARY_REVISION = exec_init.LIBRARY_REVISION;

/// struct ExecBase (exec_base.zig).
pub const ExecBase = exec_base.ExecBase;

/// Where exec routes interrupt numbers and masks interrupts; the kernel
/// sets it before the bootstrap (the default does nothing, for host tests).
pub const interrupt_hardware = &_interrupt.interrupt_hardware;

/// The system's one ExecBase. The bootstrap builds it before anything else
/// exists and this is where the kernel finds it again; a module outside the
/// kernel is handed it at init and keeps its own copy, since this symbol is
/// not reachable from there.
///
/// It is the kernel's own state and not a module's, which is why rule 2 of
/// the codex does not apply to it: there is exactly one machine.
pub var SysBase: *ExecBase = undefined;

/// A block of RAM handed to exec at startup.
pub const MemRegion = struct {
    name: [*:0]const u8,
    base: *anyopaque,
    size: usize,
    /// MEMF_* attributes of the region.
    attributes: u32,
    /// Position on the memory list; AllocMem tries higher priorities first.
    pri: i8 = 0,
};

/// What the bootstrap hands exec's init routine as its seg_list: where the
/// other ROM tags are. Without it (the host tests) exec starts no residents
/// and no exec task.
pub const BootInfo = extern struct {
    rom_start: usize,
    rom_end: usize,
};

/// Take exec.library down again, giving its memory back to its region.
/// Host tests only; every other library must be gone already.
pub fn deinit() void {
    _resident.deinitResidents(SysBase);
    _task.deinitTasks(SysBase);
    initialized = false;
    const sys = SysBase;
    SysBase.iface().Remove(&sys.lib.node);
    const start = @intFromPtr(&sys.lib) - sys.lib.neg_size;
    const size = @as(usize, sys.lib.neg_size) + sys.lib.pos_size;
    var it = sys.mem_list.iterator();
    while (it.next()) |node| {
        const mh: *MemHeader = @fieldParentPtr("node", node);
        if (start >= @intFromPtr(mh.lower) and start < @intFromPtr(mh.upper)) {
            // Through the table like everything else: the vector is read
            // before the call, and what it frees is the memory holding
            // both the table and SysBase, so nothing may use either after.
            return SysBase.iface().Deallocate(mh, @ptrFromInt(start), size);
        }
    }
}

/// exec.library's own vectors after Open, Close, Expunge and ExtFunc, and
/// their types: the SDK's contract (sdk/interface/exec.zig).
pub const interface = sdk.interface.exec;
pub const LVO = interface.LVO;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

/// The four standard vectors, for the libraries the tests make: each
/// library brings its own table.
const test_vectors = [_]*const anyopaque{
    vec(exec_base.libOpen),
    vec(exec_base.libClose),
    vec(exec_base.libExpunge),
    vec(exec_base.libExtFunc),
};

/// The six vectors of a device with no units that knows no command, for
/// the devices the tests make: each device brings its own.
const test_device_vectors = [_]*const anyopaque{
    vec(testDevOpen),
    vec(testDevClose),
    vec(exec_base.libExpunge),
    vec(exec_base.libExtFunc),
    vec(testDevBeginIO),
    vec(testDevAbortIO),
};

/// A test device's Open: counts the opener and cancels a pending expunge.
fn testDevOpen(dev: *Device, io: *IORequest, unit: u32, flags: u32) callconv(.c) i32 {
    _ = io;
    _ = unit;
    _ = flags;
    dev.open_cnt += 1;
    dev.flags &= ~LIBF_DELEXP;
    return 0;
}

/// A test device's Close: the library Close, since there are no units.
fn testDevClose(dev: *Device, io: *IORequest) callconv(.c) ?*anyopaque {
    _ = io;
    return exec_base.libClose(dev);
}

/// A test device's BeginIO: every command is unknown, and the request is
/// replied unless a quick answer was asked for.
fn testDevBeginIO(dev: *Device, io: *IORequest) callconv(.c) void {
    _ = dev;
    io.err = IOERR_NOCMD;
    if (io.flags & IOF_QUICK == 0) SysBase.iface().ReplyMsg(&io.message);
}

/// A test device's AbortIO: nothing is ever outstanding to abort.
fn testDevAbortIO(dev: *Device, io: *IORequest) callconv(.c) i32 {
    _ = dev;
    _ = io;
    return 0;
}
const native_endian = @import("builtin").cpu.arch.endian();

test {
    _ = exec_lvo;
    _ = @import("list/_list.zig");
    _ = @import("list/newlist.zig");
    _ = @import("list/addhead.zig");
    _ = @import("list/addtail.zig");
    _ = @import("list/insert.zig");
    _ = @import("list/remove.zig");
    _ = @import("list/remhead.zig");
    _ = @import("list/remtail.zig");
    _ = @import("list/enqueue.zig");
    _ = @import("list/findname.zig");
    _ = @import("list/execlist.zig");
    _ = @import("interrupt/intvector.zig");
    _ = @import("resident/resmodules.zig");
    _ = @import("library/setramlib.zig");
    _ = @import("library/ramlib.zig");
    _ = @import("memory/_memory.zig");
    _ = @import("memory/creatememheader.zig");
    _ = @import("memory/allocate.zig");
    _ = @import("memory/deallocate.zig");
    _ = @import("memory/allocmem.zig");
    _ = @import("memory/freemem.zig");
    _ = @import("memory/allocvec.zig");
    _ = @import("memory/freevec.zig");
    _ = @import("memory/availmem.zig");
    _ = @import("memory/addmemlist.zig");
    _ = @import("memory/addmemhandler.zig");
    _ = @import("memory/remmemhandler.zig");
    _ = @import("memory/createpool.zig");
    _ = @import("memory/deletepool.zig");
    _ = @import("memory/allocpooled.zig");
    _ = @import("memory/freepooled.zig");
    _ = @import("ports/_ports.zig");
    _ = @import("ports/putmsg.zig");
    _ = @import("ports/getmsg.zig");
    _ = @import("ports/replymsg.zig");
    _ = @import("ports/waitport.zig");
    _ = @import("ports/addport.zig");
    _ = @import("ports/remport.zig");
    _ = @import("ports/findport.zig");
    _ = @import("ports/createmsgport.zig");
    _ = @import("ports/deletemsgport.zig");
    _ = @import("resident/_resident.zig");
    _ = @import("resident/findresident.zig");
    _ = @import("resident/initcode.zig");
    _ = @import("resident/initresident.zig");
    _ = @import("locks/_locks.zig");
    _ = @import("locks/initsemaphore.zig");
    _ = @import("locks/obtainsemaphore.zig");
    _ = @import("locks/obtainsemaphoreshared.zig");
    _ = @import("locks/attemptsemaphore.zig");
    _ = @import("locks/attemptsemaphoreshared.zig");
    _ = @import("locks/releasesemaphore.zig");
    _ = @import("locks/obtainsemaphorelist.zig");
    _ = @import("locks/releasesemaphorelist.zig");
    _ = @import("locks/addsemaphore.zig");
    _ = @import("locks/remsemaphore.zig");
    _ = @import("locks/findsemaphore.zig");
    _ = @import("locks/procure.zig");
    _ = @import("locks/vacate.zig");
    _ = @import("task/_task.zig");
    _ = @import("task/addtask.zig");
    _ = @import("task/createtask.zig");
    _ = @import("task/remtask.zig");
    _ = @import("task/findtask.zig");
    _ = @import("task/settaskpri.zig");
    _ = @import("task/newstackrun.zig");
    _ = @import("task/signal.zig");
    _ = @import("task/wait.zig");
    _ = @import("task/setsignal.zig");
    _ = @import("task/allocsignal.zig");
    _ = @import("task/freesignal.zig");
    _ = @import("task/setexcept.zig");
    _ = @import("task/forbid.zig");
    _ = @import("task/permit.zig");
    _ = @import("cache/_cache.zig");
    _ = @import("cache/cacheclearu.zig");
    _ = @import("cache/cachecleare.zig");
    _ = @import("cache/cachepredma.zig");
    _ = @import("cache/cachepostdma.zig");
    _ = @import("cache/codeaddress.zig");
    _ = @import("memory/copymem.zig");
    _ = @import("memory/copymemquick.zig");
    _ = @import("memory/setmem.zig");
    _ = @import("device/adddevice.zig");
    _ = @import("device/remdevice.zig");
    _ = @import("device/opendevice.zig");
    _ = @import("device/closedevice.zig");
    _ = @import("rawio/_rawio.zig");
    _ = @import("rawio/rawdofmt.zig");
    _ = @import("rawio/rawputchar.zig");
    _ = @import("rawio/rawmaygetchar.zig");
    _ = @import("rawio/rawioinit.zig");
    _ = @import("interrupt/alert.zig");
    _ = @import("interrupt/coldreboot.zig");
    _ = @import("interrupt/settrapcode.zig");
    _ = @import("interrupt/_interrupt.zig");
    _ = @import("interrupt/disable.zig");
    _ = @import("interrupt/enable.zig");
    _ = @import("interrupt/setintvector.zig");
    _ = @import("interrupt/addintserver.zig");
    _ = @import("interrupt/remintserver.zig");
    _ = @import("interrupt/cause.zig");
    _ = @import("device/doio.zig");
    _ = @import("device/sendio.zig");
    _ = @import("device/waitio.zig");
    _ = @import("device/replyio.zig");
    _ = @import("device/checkio.zig");
    _ = @import("device/abortio.zig");
    _ = @import("device/createiorequest.zig");
    _ = @import("device/deleteiorequest.zig");
    _ = @import("library/_library.zig");
    _ = @import("exec_base.zig");
    _ = @import("library/makelibrary.zig");
    _ = @import("library/addlibrary.zig");
    _ = @import("library/remlibrary.zig");
    _ = @import("library/openlibrary.zig");
    _ = @import("library/closelibrary.zig");
    _ = @import("library/setfunction.zig");
    _ = @import("library/createlibrary.zig");
    _ = @import("library/addresource.zig");
    _ = @import("library/remresource.zig");
    _ = @import("library/openresource.zig");
}

var test_ram: [64 * 1024]u8 align(16) = undefined;
var test_ram_free: u32 = 0;

/// exec with 64 KiB of test RAM. It claims no attribute and sits at the
/// lowest priority, so a region a test adds itself is always picked first.
/// Also for the tests of the other libraries.
pub fn setUp() !void {
    try testBoot(&.{.{
        .name = "test ram",
        .base = &test_ram,
        .size = test_ram.len,
        .attributes = MEMF_ANY,
        .pri = -128,
    }}, null);
    test_ram_free = testRam().free;
}

/// The kernel's bootstrap (src/bootstrap.zig) for the host tests: the same
/// steps, with exec_tag at hand instead of looked up. Without a BootInfo,
/// exec starts no residents and no exec task.
fn testBoot(regions: []const MemRegion, boot: ?*const BootInfo) error{OutOfMemory}!void {
    const table: *const InitTable = @ptrCast(@alignCast(exec_init.exec_tag.init.?));
    const vectors = table.vectors[0..table.vector_count];
    const sizes = _library.librarySizes(vectors.len, table.data_size).?;
    // No ExecBase yet, as in the bootstrap: these calls get `undefined`
    // for it, and none of them reads it.
    const no_base: *ExecBase = undefined;
    var pending: List = .{};
    pending.init(.memory);
    var block: ?*anyopaque = null;
    for (regions) |r| {
        const mh = CreateMemHeader(no_base, r.size, r.attributes, r.pri, r.base, r.name) orelse continue;
        if (block == null) block = Allocate(no_base, mh, sizes.neg + sizes.pos);
        Enqueue(no_base, &pending, &mh.node);
    }
    const lib = _library.buildLibrary(@ptrCast(block orelse return error.OutOfMemory), vectors, sizes);
    lib.node.name = exec_init.exec_tag.name;
    lib.node.type = exec_init.exec_tag.type;
    lib.version = exec_init.exec_tag.version;
    lib.id_string = exec_init.exec_tag.id_string;
    const sys: *ExecBase = @fieldParentPtr("lib", lib);
    sys.mem_list.init(.memory);
    while (RemHead(sys, &pending)) |node| Enqueue(sys, &sys.mem_list, node);
    _ = table.init.?(lib, @constCast(boot), @ptrCast(sys)) orelse return error.OutOfMemory;
}

fn testRam() *MemHeader {
    return @fieldParentPtr("node", FindName(SysBase, &SysBase.mem_list, "test ram").?);
}

/// Everything the test took from exec's RAM (library bases) is back.
pub fn expectNoLeaks() !void {
    try testing.expectEqual(test_ram_free, testRam().free);
}

test "the bootstrap builds exec.library in the first region and lists the regions" {
    var other: [4096]u8 align(16) = undefined;
    try testBoot(&.{
        .{ .name = "first", .base = &test_ram, .size = test_ram.len, .attributes = MEMF_INTERNAL, .pri = -10 },
        .{ .name = "second", .base = &other, .size = other.len, .attributes = MEMF_EXTERNAL, .pri = 0 },
    }, null);
    try testing.expectEqualStrings(LIBRARY_NAME, SysBase.lib.name());
    try testing.expectEqual(@as(u16, LIBRARY_VERSION), SysBase.lib.version);
    try testing.expectEqual(@as(u16, LIBRARY_REVISION), SysBase.lib.revision);
    try testing.expectEqual(&SysBase.lib.node, FindName(SysBase, &SysBase.lib_list, LIBRARY_NAME).?);
    // exec is made once, by the bootstrap: InitResident refuses its tag.
    try testing.expect(InitResident(SysBase, &exec_init.exec_tag, null) == null);
    const first: *MemHeader = @fieldParentPtr("node", FindName(SysBase, &SysBase.mem_list, "first").?);
    const second: *MemHeader = @fieldParentPtr("node", FindName(SysBase, &SysBase.mem_list, "second").?);
    const sys = @intFromPtr(SysBase);
    try testing.expect(sys >= @intFromPtr(first.lower) and sys < @intFromPtr(first.upper));
    try testing.expectEqual(&second.node, SysBase.mem_list.first().?); // higher priority first

    // deinit gives back exec and the boot and idle tasks.
    const first_free = first.free;
    deinit();
    try testing.expectEqual(@intFromPtr(first.upper) - @intFromPtr(first.lower), @as(usize, first.free));
    try testing.expectEqual(@intFromPtr(second.upper) - @intFromPtr(second.lower), @as(usize, second.free));
    try testing.expect(first.free > first_free);

    try testing.expectError(error.OutOfMemory, testBoot(&.{}, null));
}

test "OpenLibrary: by name and version, counts openers" {
    try setUp();
    defer deinit();

    const lib = CreateLibrary(SysBase, &.{ .name = "test.library", .version = 3, .revision = 7, .id_string = "test 3.7", .vectors = &test_vectors }).?;
    try testing.expectEqualStrings("test.library", lib.name());
    try testing.expectEqualStrings("test 3.7", std.mem.span(lib.id_string.?));
    try testing.expect(OpenLibrary(SysBase, "test.library", 4) == null);
    try testing.expect(OpenLibrary(SysBase, "nope.library", 0) == null);

    const a = OpenLibrary(SysBase, "test.library", 3).?;
    const b = OpenLibrary(SysBase, "test.library", 0).?;
    try testing.expectEqual(lib, a);
    try testing.expectEqual(lib, b);
    try testing.expectEqual(@as(u16, 2), lib.open_cnt);
    CloseLibrary(SysBase, a);
    CloseLibrary(SysBase, b);
    CloseLibrary(SysBase, null);
    try testing.expectEqual(@as(u16, 0), lib.open_cnt);

    try testing.expect(RemLibrary(SysBase, lib) == null);
    try testing.expect(OpenLibrary(SysBase, "test.library", 0) == null);
    try testing.expectEqual(@as(i8, -1), SysBase.tdn_nest_cnt);
    try expectNoLeaks();
}

test "RemLibrary while open delays the expunge to the last close" {
    try setUp();
    defer deinit();

    _ = CreateLibrary(SysBase, &.{ .name = "busy.library", .vectors = &test_vectors }).?;
    const lib = OpenLibrary(SysBase, "busy.library", 0).?;
    _ = RemLibrary(SysBase, lib);
    try testing.expect(lib.flags & LIBF_DELEXP != 0);
    try testing.expect(FindName(SysBase, &SysBase.lib_list, "busy.library") != null);

    // Opening again cancels the pending expunge.
    _ = OpenLibrary(SysBase, "busy.library", 0).?;
    try testing.expect(lib.flags & LIBF_DELEXP == 0);
    _ = RemLibrary(SysBase, lib);
    CloseLibrary(SysBase, lib);
    try testing.expect(FindName(SysBase, &SysBase.lib_list, "busy.library") != null);
    CloseLibrary(SysBase, lib); // last close: expunged and freed
    try testing.expect(FindName(SysBase, &SysBase.lib_list, "busy.library") == null);
    try expectNoLeaks();
}

const CounterBase = extern struct {
    lib: Library,
    count: u32,
};
const BumpFn = *const fn (base: *CounterBase) callconv(.c) u32;

fn bump(base: *CounterBase) callconv(.c) u32 {
    base.count += 1;
    return base.count;
}
fn bumpTwice(base: *CounterBase) callconv(.c) u32 {
    base.count += 2;
    return base.count;
}
fn counterInit(lib: *Library, _: ?*anyopaque, _: *interface.ExecBase) callconv(.c) ?*Library {
    const base: *CounterBase = @fieldParentPtr("lib", lib);
    base.count = 100;
    return lib;
}
fn refuse(_: *Library, _: ?*anyopaque, _: *interface.ExecBase) callconv(.c) ?*Library {
    return null;
}

test "library functions go through the jump table; SetFunction patches it" {
    try setUp();
    defer deinit();

    const vectors = test_vectors ++ [_]*const anyopaque{vec(bump)};
    const lib = CreateLibrary(SysBase, &.{
        .name = "counter.library",
        .data_size = @sizeOf(CounterBase),
        .vectors = &vectors,
        .init = counterInit,
    }).?;
    lib.flags |= LIBF_SUMUSED | LIBF_CHANGED;
    SumLibrary(lib);

    const base: *CounterBase = @fieldParentPtr("lib", OpenLibrary(SysBase, "counter.library", 0).?);
    try testing.expectEqual(@as(u32, 101), lib.vector(BumpFn, LIB_USERDEF)(base));

    const old = SetFunction(SysBase, lib, LIB_USERDEF, vec(bumpTwice));
    try testing.expectEqual(vec(bump), old);
    try testing.expectEqual(@as(u32, 103), lib.vector(BumpFn, LIB_USERDEF)(base));
    SumLibrary(lib); // checksum was updated by SetFunction
    _ = SetFunction(SysBase, lib, LIB_USERDEF, old);

    CloseLibrary(SysBase, lib);
    _ = RemLibrary(SysBase, lib);
    try testing.expect(FindName(SysBase, &SysBase.lib_list, "counter.library") == null);
    try expectNoLeaks();
}

test "a library's base is 8-aligned whatever its vector count" {
    try setUp();
    defer deinit();
    const odd = test_vectors ++ [_]*const anyopaque{vec(bump)};
    const even = odd ++ [_]*const anyopaque{vec(bumpTwice)};
    inline for (.{ &odd, &even }) |vectors| {
        const lib = MakeLibrary(SysBase, vectors, @sizeOf(CounterBase), null, null).?;
        try testing.expectEqual(@as(usize, 0), @intFromPtr(lib) % 8);
        try testing.expectEqual(vec(bump), lib.vector(*const anyopaque, LIB_USERDEF));
        const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
        FreeMem(SysBase, start, @as(usize, lib.neg_size) + lib.pos_size);
    }
    try expectNoLeaks();
}

test "a refusing init leaves nothing behind" {
    try setUp();
    defer deinit();
    try testing.expect(CreateLibrary(SysBase, &.{ .name = "no.library", .init = refuse, .vectors = &test_vectors }) == null);
    try testing.expect(FindName(SysBase, &SysBase.lib_list, "no.library") == null);
    try testing.expect(CreateLibrary(SysBase, &.{ .name = "tiny.library", .data_size = 4, .vectors = &test_vectors }) == null);
    try expectNoLeaks();
}

test "exec.library is a library too: on the list, found and opened by name" {
    try setUp();
    defer deinit();

    try testing.expectEqual(&SysBase.lib, OpenLibrary(SysBase, "exec.library", 0).?);
    CloseLibrary(SysBase, &SysBase.lib);

    const made = CreateLibrary(SysBase, &.{ .name = "viajump.library", .version = 2, .vectors = &test_vectors }).?;
    const opened = OpenLibrary(SysBase, "viajump.library", 2).?;
    try testing.expectEqual(made, opened);
    CloseLibrary(SysBase, opened);
    _ = RemLibrary(SysBase, made);

    // exec refuses to be expunged.
    _ = RemLibrary(SysBase, &SysBase.lib);
    try testing.expect(FindName(SysBase, &SysBase.lib_list, "exec.library") != null);
    try expectNoLeaks();
}

test "list functions: a list built with every one of them" {
    try setUp();
    defer deinit();

    const sys = SysBase;

    var list: List = .{ .type = .message };
    NewList(sys, &list);
    try testing.expect(list.isEmpty());
    try testing.expectEqual(NodeType.message, list.type); // NewList leaves lh_Type alone
    var a: Node = .{ .name = "a", .pri = 0 };
    var b: Node = .{ .name = "b", .pri = 5 };
    var c: Node = .{ .name = "c", .pri = 0 };
    var d: Node = .{ .name = "d", .pri = -5 };
    var e: Node = .{ .name = "e" };

    AddTail(sys, &list, &a); // a
    AddHead(sys, &list, &b); // b a
    Enqueue(sys, &list, &c); // b a c
    Enqueue(sys, &list, &d); // b a c d
    Insert(sys, &list, &e, &a); // b a e c d

    const expected = [_]*Node{ &b, &a, &e, &c, &d };
    var it = list.iterator();
    for (expected) |want| try testing.expectEqual(want, it.next().?);
    try testing.expect(it.next() == null);

    try testing.expectEqual(&e, FindName(sys, &list, "e").?);
    Remove(sys, &e);
    try testing.expectEqual(&b, RemHead(sys, &list).?);
    try testing.expectEqual(&d, RemTail(sys, &list).?);
    try testing.expectEqual(&a, list.first().?);
    try testing.expectEqual(&c, list.last().?);
}

test "CreateMemHeader sets up a region, AddMemList puts it on MemList" {
    try setUp();
    defer deinit();

    var buf: [1000]u8 align(16) = undefined;
    const mh = CreateMemHeader(SysBase, buf.len, MEMF_EXTERNAL, 0, &buf, "test memory").?;
    const start = @intFromPtr(&buf);
    const lower = std.mem.alignForward(usize, start + @sizeOf(MemHeader), MEM_BLOCKSIZE);
    const upper = std.mem.alignBackward(usize, start + buf.len, MEM_BLOCKSIZE);
    try testing.expectEqual(start, @intFromPtr(mh));
    try testing.expectEqual(NodeType.memory, mh.node.type);
    try testing.expectEqualStrings("test memory", mh.name());
    try testing.expectEqual(@as(u16, MEMF_EXTERNAL), mh.attributes);
    try testing.expectEqual(lower, @intFromPtr(mh.lower));
    try testing.expectEqual(upper, @intFromPtr(mh.upper));
    try testing.expectEqual(lower, @intFromPtr(mh.first.?));
    try testing.expect(mh.first.?.next == null);
    try testing.expectEqual(@as(u32, @intCast(upper - lower)), mh.first.?.bytes);
    try testing.expectEqual(mh.first.?.bytes, mh.free);
    try testing.expect(FindName(SysBase, &SysBase.mem_list, "test memory") == null); // not added

    var tiny: [@sizeOf(MemHeader)]u8 align(16) = undefined;
    try testing.expect(CreateMemHeader(SysBase, tiny.len, MEMF_ANY, 0, &tiny, "tiny") == null);

    var low_buf: [512]u8 align(16) = undefined;
    var high_buf: [512]u8 align(16) = undefined;
    const low = AddMemList(SysBase, low_buf.len, MEMF_EXTERNAL, -10, &low_buf, "low").?;
    const high = AddMemList(SysBase, high_buf.len, MEMF_INTERNAL, 10, &high_buf, "high").?;
    try testing.expectEqual(&high.node, SysBase.mem_list.first().?);
    try testing.expectEqual(&low.node, FindName(SysBase, &SysBase.mem_list, "low").?);

    // A third region goes in between, by its priority.
    var more: [256]u8 align(16) = undefined;
    const mid = AddMemList(SysBase, more.len, MEMF_ANY, 0, &more, "more").?;
    try testing.expectEqual(&mid.node, low.node.pred.?); // between high (10) and low (-10)
}

test "Allocate and Deallocate on a region of the caller's" {
    try setUp();
    defer deinit();

    var buf: [512]u8 align(16) = undefined;
    const mh = CreateMemHeader(SysBase, buf.len, MEMF_ANY, 0, &buf, "jump").?;
    const free = mh.free;

    const block = Allocate(SysBase, mh, 64).?;
    try testing.expectEqual(free - 64, mh.free);
    Deallocate(SysBase, mh, block, 64);
    try testing.expectEqual(free, mh.free);
}

fn inRegion(mh: *MemHeader, p: *anyopaque) bool {
    return @intFromPtr(p) >= @intFromPtr(mh.lower) and @intFromPtr(p) < @intFromPtr(mh.upper);
}

test "AllocMem picks regions by attributes and priority, FreeMem returns blocks" {
    try setUp();
    defer deinit();

    var external_buf: [1024]u8 align(16) = undefined;
    var internal_buf: [1024]u8 align(16) = undefined;
    @memset(&external_buf, 0xAA);
    @memset(&internal_buf, 0xAA);
    const external = AddMemList(SysBase, external_buf.len, MEMF_EXTERNAL, 0, &external_buf, "external").?;
    const internal = AddMemList(SysBase, internal_buf.len, MEMF_INTERNAL, -10, &internal_buf, "internal").?;
    const external_free = external.free;
    const internal_free = internal.free;

    try testing.expect(AllocMem(SysBase, 0, MEMF_ANY) == null);
    try testing.expect(AllocMem(SysBase, 16, MEMF_INTERNAL | MEMF_EXTERNAL) == null); // no region has both

    const any = AllocMem(SysBase, 100, MEMF_ANY).?; // highest priority: the external region
    try testing.expect(inRegion(external, any));
    // Not cleared: past the stale MemChunk header that CreateMemHeader put
    // at the start of the free space, the old contents are still there.
    const dirty: [*]u8 = @ptrCast(any);
    try testing.expect(std.mem.allEqual(u8, dirty[MEM_BLOCKSIZE..100], 0xAA));

    const cleared = AllocMem(SysBase, 100, MEMF_INTERNAL | MEMF_CLEAR).?;
    try testing.expect(inRegion(internal, cleared));
    const zeroed: [*]u8 = @ptrCast(cleared);
    try testing.expect(std.mem.allEqual(u8, zeroed[0..100], 0));

    const top = AllocMem(SysBase, 64, MEMF_EXTERNAL | MEMF_REVERSE).?;
    try testing.expectEqual(@intFromPtr(external.upper), @intFromPtr(top) + 64);

    // When external is full, MEMF_ANY falls through to internal (before test ram).
    const rest = AllocMem(SysBase, external.free, MEMF_EXTERNAL).?;
    try testing.expectEqual(@as(u32, 0), external.free);
    const spill = AllocMem(SysBase, 32, MEMF_ANY).?;
    try testing.expect(inRegion(internal, spill));

    FreeMem(SysBase, rest, external_free - 64 - std.mem.alignForward(usize, 100, MEM_BLOCKSIZE));
    FreeMem(SysBase, top, 64);
    FreeMem(SysBase, any, 100);
    FreeMem(SysBase, cleared, 100);
    FreeMem(SysBase, spill, 32);
    FreeMem(SysBase, null, 32);
    try testing.expectEqual(external_free, external.free);
    try testing.expectEqual(internal_free, internal.free);

    // A block from the internal region goes back to it.
    const block = AllocMem(SysBase, 48, MEMF_INTERNAL).?;
    try testing.expect(inRegion(internal, block));
    FreeMem(SysBase, block, 48);
    try testing.expectEqual(internal_free, internal.free);
    try expectNoLeaks();
}

test "MEMF_DMA picks the regions a DMA engine addresses" {
    try setUp();
    defer deinit();

    var external_buf: [1024]u8 align(16) = undefined;
    var internal_buf: [1024]u8 align(16) = undefined;
    const external = AddMemList(SysBase, external_buf.len, MEMF_EXTERNAL, 0, &external_buf, "external").?;
    const internal = AddMemList(SysBase, internal_buf.len, MEMF_INTERNAL | MEMF_DMA, -10, &internal_buf, "internal").?;
    const external_free = external.free;
    const internal_free = internal.free;

    // The external region has the higher priority, but only the internal one
    // says a DMA engine reaches it, so that is where a descriptor chain goes.
    const chain = AllocMem(SysBase, 64, MEMF_DMA).?;
    try testing.expect(inRegion(internal, chain));
    try testing.expectEqual(external_free, external.free);

    // Both bits together still mean one region with both, which this is.
    const both = AllocMem(SysBase, 64, MEMF_INTERNAL | MEMF_DMA).?;
    try testing.expect(inRegion(internal, both));

    // With the internal region full, nothing else can answer for it.
    const rest = AllocMem(SysBase, internal.free, MEMF_DMA).?;
    try testing.expect(AllocMem(SysBase, 16, MEMF_DMA) == null);

    FreeMem(SysBase, rest, internal_free - 2 * 64);
    FreeMem(SysBase, both, 64);
    FreeMem(SysBase, chain, 64);
    try testing.expectEqual(internal_free, internal.free);
    try expectNoLeaks();
}

test "AvailMem: free, largest and total memory per attribute" {
    try setUp();
    defer deinit();

    try testing.expectEqual(@as(usize, 0), AvailMem(SysBase, MEMF_INTERNAL)); // test ram claims nothing

    var external_buf: [2048]u8 align(16) = undefined;
    var internal_buf: [1024]u8 align(16) = undefined;
    const external = AddMemList(SysBase, external_buf.len, MEMF_EXTERNAL, 0, &external_buf, "external").?;
    const internal = AddMemList(SysBase, internal_buf.len, MEMF_INTERNAL, -10, &internal_buf, "internal").?;
    const ram = testRam();
    const external_size = @intFromPtr(external.upper) - @intFromPtr(external.lower);
    const internal_size = @intFromPtr(internal.upper) - @intFromPtr(internal.lower);
    const ram_size = @intFromPtr(ram.upper) - @intFromPtr(ram.lower);
    const all_free = @as(usize, external.free) + internal.free + ram.free;

    try testing.expectEqual(all_free, AvailMem(SysBase, MEMF_ANY));
    try testing.expectEqual(@as(usize, internal.free), AvailMem(SysBase, MEMF_INTERNAL));
    try testing.expectEqual(@as(usize, 0), AvailMem(SysBase, MEMF_INTERNAL | MEMF_EXTERNAL));
    try testing.expectEqual(external_size + internal_size + ram_size, AvailMem(SysBase, MEMF_TOTAL));
    try testing.expectEqual(internal_size, AvailMem(SysBase, MEMF_INTERNAL | MEMF_TOTAL | MEMF_LARGEST));

    // Cut the external region into two free chunks; LARGEST sees the bigger one.
    const a = AllocMem(SysBase, 256, MEMF_EXTERNAL).?;
    const hole = AllocMem(SysBase, 512, MEMF_EXTERNAL).?;
    const b = AllocMem(SysBase, 64, MEMF_EXTERNAL).?;
    FreeMem(SysBase, hole, 512);
    const tail = external_size - 256 - 512 - 64;
    try testing.expectEqual(@max(@as(usize, 512), tail), AvailMem(SysBase, MEMF_EXTERNAL | MEMF_LARGEST));
    try testing.expectEqual(@as(usize, external.free) + internal.free + ram.free, AvailMem(SysBase, MEMF_ANY));
    try testing.expectEqual(external_size + internal_size + ram_size, AvailMem(SysBase, MEMF_TOTAL)); // allocations don't change it

    try testing.expectEqual(@as(usize, internal.free), AvailMem(SysBase, MEMF_INTERNAL));

    FreeMem(SysBase, a, 256);
    FreeMem(SysBase, b, 64);
    try testing.expectEqual(external_size, AvailMem(SysBase, MEMF_EXTERNAL | MEMF_LARGEST));
}

test "AllocMem flushes unused libraries when memory runs out" {
    try setUp();
    defer deinit();

    // Test RAM: SysBase, then big.library (20 KiB, unused), then
    // busy.library (open), then everything else taken by a filler block.
    const big = CreateLibrary(SysBase, &.{ .name = "big.library", .data_size = 20 * 1024, .vectors = &test_vectors }).?;
    _ = CreateLibrary(SysBase, &.{ .name = "busy.library", .vectors = &test_vectors }).?;
    const busy = OpenLibrary(SysBase, "busy.library", 0).?;
    const filler_size = AvailMem(SysBase, MEMF_ANY | MEMF_LARGEST);
    const filler = AllocMem(SysBase, filler_size, MEMF_ANY).?;
    try testing.expect(AvailMem(SysBase, MEMF_ANY | MEMF_LARGEST) < 10 * 1024);

    // MEMF_NO_EXPUNGE: fail, flush nothing.
    try testing.expect(AllocMem(SysBase, 10 * 1024, MEMF_ANY | MEMF_NO_EXPUNGE) == null);
    try testing.expectEqual(&big.node, FindName(SysBase, &SysBase.lib_list, "big.library").?);

    // Otherwise the unused library goes; the open one and exec stay.
    const block = AllocMem(SysBase, 10 * 1024, MEMF_ANY).?;
    try testing.expect(FindName(SysBase, &SysBase.lib_list, "big.library") == null);
    try testing.expect(FindName(SysBase, &SysBase.lib_list, "busy.library") != null);
    try testing.expect(FindName(SysBase, &SysBase.lib_list, "exec.library") != null);

    // Nothing left to flush: fails cleanly.
    try testing.expect(AllocMem(SysBase, 64 * 1024, MEMF_ANY) == null);

    FreeMem(SysBase, block, 10 * 1024);
    FreeMem(SysBase, filler, filler_size);
    CloseLibrary(SysBase, busy);
    _ = RemLibrary(SysBase, busy);
    try expectNoLeaks();
}

const HandlerLog = struct {
    calls: u32 = 0,
    recycle_calls: u32 = 0,
    blocks: [2]?*anyopaque = .{ null, null },
    block_size: usize = 256,
};

fn doNothing(_: *const MemHandlerData, is_data: ?*anyopaque) callconv(.c) i32 {
    const log: *HandlerLog = @ptrCast(@alignCast(is_data.?));
    log.calls += 1;
    return MEM_DID_NOTHING;
}

/// Frees one held block per call: MEM_TRY_AGAIN while more are held,
/// MEM_ALL_DONE with the last one.
fn releaseBlocks(data: *const MemHandlerData, is_data: ?*anyopaque) callconv(.c) i32 {
    const log: *HandlerLog = @ptrCast(@alignCast(is_data.?));
    log.calls += 1;
    if (data.flags & MEMHF_RECYCLE != 0) log.recycle_calls += 1;
    for (&log.blocks, 0..) |*slot, i| {
        const block = slot.* orelse continue;
        FreeMem(SysBase, block, log.block_size);
        slot.* = null;
        return if (i + 1 < log.blocks.len) MEM_TRY_AGAIN else MEM_ALL_DONE;
    }
    return MEM_DID_NOTHING;
}

test "memory handlers: priority order, MEM_TRY_AGAIN with recycle, MEM_ALL_DONE" {
    try setUp();
    defer deinit();

    var internal_buf: [1024]u8 align(16) = undefined;
    _ = AddMemList(SysBase, internal_buf.len, MEMF_INTERNAL, 0, &internal_buf, "internal").?;

    var nothing_log: HandlerLog = .{};
    var release_log: HandlerLog = .{};
    var nothing: Interrupt = .{ .node = .{ .type = .interrupt, .pri = 10, .name = "nothing" }, .data = &nothing_log, .code = vec(doNothing) };
    var release: Interrupt = .{ .node = .{ .type = .interrupt, .pri = 5, .name = "release" }, .data = &release_log, .code = vec(releaseBlocks) };
    AddMemHandler(SysBase, &nothing);
    AddMemHandler(SysBase, &release);
    try testing.expectEqual(&nothing.node, SysBase.mem_handlers.first().?);

    // The release handler holds two adjacent 256-byte blocks; the rest of
    // the region is taken by a filler.
    release_log.blocks[0] = AllocMem(SysBase, 256, MEMF_INTERNAL).?;
    release_log.blocks[1] = AllocMem(SysBase, 256, MEMF_INTERNAL).?;
    const filler_size = AvailMem(SysBase, MEMF_INTERNAL | MEMF_LARGEST);
    const filler = AllocMem(SysBase, filler_size, MEMF_INTERNAL).?;

    // 400 bytes need both blocks: the first release is not enough, so the
    // handler is called again with MEMHF_RECYCLE.
    const block = AllocMem(SysBase, 400, MEMF_INTERNAL).?;
    try testing.expectEqual(@as(u32, 1), nothing_log.calls);
    try testing.expectEqual(@as(u32, 2), release_log.calls);
    try testing.expectEqual(@as(u32, 1), release_log.recycle_calls);

    // Nobody can help any more: every handler is asked, then null.
    try testing.expect(AllocMem(SysBase, 4096, MEMF_INTERNAL) == null);
    try testing.expectEqual(@as(u32, 2), nothing_log.calls);
    try testing.expectEqual(@as(u32, 3), release_log.calls);

    RemMemHandler(SysBase, &nothing);
    RemMemHandler(SysBase, &release);
    try testing.expect(AllocMem(SysBase, 4096, MEMF_INTERNAL) == null);
    try testing.expectEqual(@as(u32, 2), nothing_log.calls); // no longer asked

    FreeMem(SysBase, block, 400);
    FreeMem(SysBase, filler, filler_size);
    try expectNoLeaks();
}

/// Interrupt hardware for tests: records routing and masking.
const FakeHardware = struct {
    var enabled: [sdk.hardware.intbits.INTB_COUNT]bool = @splat(false);
    /// Whether each source was last routed as one that may share a line.
    var shareable_as: [sdk.hardware.intbits.INTB_COUNT]bool = @splat(false);
    var routings: u32 = 0;
    var masks: u32 = 0;
    var restores: u32 = 0;
    var last_restore: u32 = 0;
    var causes: u32 = 0;

    fn causeSoftint() void {
        causes += 1;
    }

    fn enableSource(n: u32, shareable: bool) bool {
        shareable_as[n] = shareable;
        routings += 1;
        enabled[n] = true;
        return true;
    }
    fn disableSource(n: u32) void {
        enabled[n] = false;
    }
    fn mask() u32 {
        masks += 1;
        return masks; // a token naming this Disable
    }
    fn restore(state: u32) void {
        restores += 1;
        last_restore = state;
    }

    fn install() void {
        enabled = @splat(false);
        shareable_as = @splat(false);
        routings = 0;
        masks = 0;
        restores = 0;
        last_restore = 0;
        causes = 0;
        interrupt_hardware.* = .{
            .enable_source = enableSource,
            .disable_source = disableSource,
            .disable = mask,
            .restore = restore,
            .cause_softint = causeSoftint,
        };
    }
    fn uninstall() void {
        interrupt_hardware.* = _interrupt.no_hardware;
    }
};

var last_int_number: u32 = 0;

fn addOne(data: ?*anyopaque, int_number: u32) callconv(.c) void {
    const hits: *u32 = @ptrCast(@alignCast(data.?));
    hits.* += 1;
    last_int_number = int_number;
}
fn addTen(data: ?*anyopaque, _: u32) callconv(.c) void {
    const hits: *u32 = @ptrCast(@alignCast(data.?));
    hits.* += 10;
}

test "SetIntVector: one handler per number, routed while installed" {
    try setUp();
    defer deinit();
    FakeHardware.install();
    defer FakeHardware.uninstall();

    var hits: u32 = 0;
    var a: Interrupt = .{ .node = .{ .type = .interrupt, .name = "a" }, .data = &hits, .code = vec(addOne) };
    var b: Interrupt = .{ .node = .{ .type = .interrupt, .name = "b" }, .data = &hits, .code = vec(addTen) };

    try testing.expect(SetIntVector(SysBase, 79, &a) == null);
    try testing.expect(FakeHardware.enabled[79]);
    dispatchInterrupt(SysBase, 79);
    try testing.expectEqual(@as(u32, 1), hits);
    try testing.expectEqual(@as(u32, 79), last_int_number);

    try testing.expectEqual(&a, SetIntVector(SysBase, 79, &b).?);
    dispatchInterrupt(SysBase, 79);
    try testing.expectEqual(@as(u32, 11), hits);
    try testing.expect(FakeHardware.enabled[79]);

    try testing.expectEqual(&b, SetIntVector(SysBase, 79, null).?);
    try testing.expect(!FakeHardware.enabled[79]);
    try testing.expectEqual(@as(u32, 2), SysBase.int_vects[79].count);
}

test "interrupt routing: servers may share a line, a handler keeps its own" {
    try setUp();
    defer deinit();
    FakeHardware.install();
    defer FakeHardware.uninstall();

    var hits: u32 = 0;
    var server: Interrupt = .{ .node = .{ .type = .interrupt, .name = "s" }, .data = &hits, .code = vec(countServer) };
    var handler: Interrupt = .{ .node = .{ .type = .interrupt, .name = "h" }, .data = &hits, .code = vec(addOne) };

    // Servers only: routed as shareable, once.
    AddIntServer(SysBase, 81, &server);
    try testing.expect(FakeHardware.enabled[81]);
    try testing.expect(FakeHardware.shareable_as[81]);
    try testing.expectEqual(@as(u32, 1), FakeHardware.routings);

    // A handler joins: routed again, now to a line of its own.
    _ = SetIntVector(SysBase, 81, &handler);
    try testing.expect(!FakeHardware.shareable_as[81]);
    try testing.expectEqual(@as(u32, 2), FakeHardware.routings);

    // The handler goes and the server stays: shareable again.
    _ = SetIntVector(SysBase, 81, null);
    try testing.expect(FakeHardware.enabled[81]);
    try testing.expect(FakeHardware.shareable_as[81]);
    try testing.expectEqual(@as(u32, 3), FakeHardware.routings);

    RemIntServer(SysBase, 81, &server);
    try testing.expect(!FakeHardware.enabled[81]);
}

fn countServer(data: ?*anyopaque, _: u32) callconv(.c) i32 {
    const hits: *u32 = @ptrCast(@alignCast(data.?));
    hits.* += 1;
    return 0;
}

const ServerLog = struct {
    order: [8]u8 = undefined,
    len: usize = 0,
};
const ServerProbe = struct {
    log: *ServerLog,
    id: u8,
    result: i32,
};

fn probeServer(data: ?*anyopaque, _: u32) callconv(.c) i32 {
    const probe: *ServerProbe = @ptrCast(@alignCast(data.?));
    probe.log.order[probe.log.len] = probe.id;
    probe.log.len += 1;
    return probe.result;
}
fn probeHandler(data: ?*anyopaque, _: u32) callconv(.c) void {
    _ = probeServer(data, 0);
}

test "AddIntServer: chain by priority, stops at a non-zero server" {
    try setUp();
    defer deinit();
    FakeHardware.install();
    defer FakeHardware.uninstall();

    var log: ServerLog = .{};
    var high_probe: ServerProbe = .{ .log = &log, .id = 'H', .result = 0 };
    var mid_probe: ServerProbe = .{ .log = &log, .id = 'M', .result = 1 };
    var low_probe: ServerProbe = .{ .log = &log, .id = 'L', .result = 0 };
    var handler_probe: ServerProbe = .{ .log = &log, .id = 'h', .result = 0 };
    var high: Interrupt = .{ .node = .{ .type = .interrupt, .pri = 10, .name = "high" }, .data = &high_probe, .code = vec(probeServer) };
    var mid: Interrupt = .{ .node = .{ .type = .interrupt, .pri = 0, .name = "mid" }, .data = &mid_probe, .code = vec(probeServer) };
    var low: Interrupt = .{ .node = .{ .type = .interrupt, .pri = -10, .name = "low" }, .data = &low_probe, .code = vec(probeServer) };
    var handler: Interrupt = .{ .node = .{ .type = .interrupt, .name = "handler" }, .data = &handler_probe, .code = vec(probeHandler) };

    AddIntServer(SysBase, 80, &low);
    AddIntServer(SysBase, 80, &high);
    AddIntServer(SysBase, 80, &mid);
    try testing.expect(FakeHardware.enabled[80]);

    dispatchInterrupt(SysBase, 80); // mid handles it: low never runs
    try testing.expectEqualStrings("HM", log.order[0..log.len]);

    log.len = 0;
    RemIntServer(SysBase, 80, &mid);
    dispatchInterrupt(SysBase, 80);
    try testing.expectEqualStrings("HL", log.order[0..log.len]);

    // A handler and servers on the same number: handler first.
    log.len = 0;
    _ = SetIntVector(SysBase, 80, &handler);
    dispatchInterrupt(SysBase, 80);
    try testing.expectEqualStrings("hHL", log.order[0..log.len]);
    _ = SetIntVector(SysBase, 80, null);

    RemIntServer(SysBase, 80, &high);
    try testing.expect(FakeHardware.enabled[80]);
    RemIntServer(SysBase, 80, &low);
    try testing.expect(!FakeHardware.enabled[80]);
}

test "Disable/Enable nest; only the outermost Enable restores" {
    try setUp();
    defer deinit();
    FakeHardware.install();
    defer FakeHardware.uninstall();

    Disable(SysBase); // token 1: the state to restore later
    Disable(SysBase);
    Disable(SysBase);
    try testing.expectEqual(@as(i8, 2), SysBase.id_nest_cnt);
    Enable(SysBase);
    Enable(SysBase);
    try testing.expectEqual(@as(u32, 0), FakeHardware.restores);
    Enable(SysBase);
    try testing.expectEqual(@as(u32, 1), FakeHardware.restores);
    try testing.expectEqual(@as(u32, 1), FakeHardware.last_restore);
    try testing.expectEqual(@as(i8, -1), SysBase.id_nest_cnt);

    // One Disable and Enable pair from the start.
    Disable(SysBase);
    try testing.expectEqual(@as(i8, 0), SysBase.id_nest_cnt);
    Enable(SysBase);
    try testing.expectEqual(@as(i8, -1), SysBase.id_nest_cnt);
    try testing.expectEqual(@as(u32, 2), FakeHardware.restores);

    var hits: u32 = 0;
    var a: Interrupt = .{ .node = .{ .type = .interrupt, .name = "a" }, .data = &hits, .code = vec(addOne) };
    AddIntServer(SysBase, 81, &a);
    try testing.expect(FakeHardware.enabled[81]);
    RemIntServer(SysBase, 81, &a);
    try testing.expect(!FakeHardware.enabled[81]);
    try testing.expect(SetIntVector(SysBase, 82, &a) == null);
    dispatchInterrupt(SysBase, 82);
    try testing.expectEqual(@as(u32, 1), hits);
    try testing.expectEqual(&a, SetIntVector(SysBase, 82, null).?);
}

const SoftProbe = struct {
    log: *ServerLog,
    id: u8,
    /// Caused from inside this software interrupt.
    chain: ?*Interrupt = null,
};

fn softProbe(data: ?*anyopaque) callconv(.c) void {
    const probe: *SoftProbe = @ptrCast(@alignCast(data.?));
    probe.log.order[probe.log.len] = probe.id;
    probe.log.len += 1;
    if (probe.chain) |next| Cause(SysBase, next);
}

test "Cause: software interrupts run once each, highest priority first" {
    try setUp();
    defer deinit();
    FakeHardware.install();
    defer FakeHardware.uninstall();

    var log: ServerLog = .{};
    var p_low: SoftProbe = .{ .log = &log, .id = 'l' };
    var p_mid: SoftProbe = .{ .log = &log, .id = 'm' };
    var p_odd: SoftProbe = .{ .log = &log, .id = 'o' };
    var p_high: SoftProbe = .{ .log = &log, .id = 'h' };
    var low: Interrupt = .{ .node = .{ .type = .interrupt, .pri = -32, .name = "low" }, .data = &p_low, .code = vec(softProbe) };
    var mid: Interrupt = .{ .node = .{ .type = .interrupt, .pri = 0, .name = "mid" }, .data = &p_mid, .code = vec(softProbe) };
    var odd: Interrupt = .{ .node = .{ .type = .interrupt, .pri = 5, .name = "odd" }, .data = &p_odd, .code = vec(softProbe) };
    var high: Interrupt = .{ .node = .{ .type = .interrupt, .pri = 32, .name = "high" }, .data = &p_high, .code = vec(softProbe) };

    Cause(SysBase, &low);
    Cause(SysBase, &mid);
    Cause(SysBase, &mid); // already queued: ignored
    Cause(SysBase, &odd); // priority 5 rounds down to the 0 queue, behind mid
    Cause(SysBase, &high);
    try testing.expectEqual(@as(u32, 4), FakeHardware.causes);
    try testing.expectEqual(NodeType.softint, mid.node.type);

    dispatchSoftInts(SysBase);
    try testing.expectEqualStrings("hmol", log.order[0..log.len]);
    try testing.expectEqual(NodeType.interrupt, mid.node.type);
    log.len = 0;
    dispatchSoftInts(SysBase);
    try testing.expectEqual(@as(usize, 0), log.len);

    // A software interrupt may Cause another; it runs in the same pass.
    p_high.chain = &low;
    Cause(SysBase, &high);
    dispatchSoftInts(SysBase);
    try testing.expectEqualStrings("hl", log.order[0..log.len]);

    // A single one, caused and run.
    p_high.chain = null;
    log.len = 0;
    Cause(SysBase, &mid);
    dispatchSoftInts(SysBase);
    try testing.expectEqualStrings("m", log.order[0..log.len]);
}

/// Alert hook for tests: records instead of halting.
const FakeAlert = struct {
    var count: u32 = 0;
    var last_num: u32 = 0;
    var last_where: usize = 0;
    var last_info: ?*const TrapInfo = null;

    fn show(alert_num: u32, where: usize, info: ?*const TrapInfo) void {
        count += 1;
        last_num = alert_num;
        last_where = where;
        last_info = info;
    }
    fn install() void {
        count = 0;
        last_num = 0;
        last_where = 0;
        last_info = null;
        alert_hook.* = show;
    }
    fn uninstall() void {
        alert_hook.* = _interrupt.default_alert;
    }
};

fn skipThree(info: *TrapInfo, data: ?*anyopaque) callconv(.c) i32 {
    const handled: *u32 = @ptrCast(@alignCast(data.?));
    handled.* += 1;
    info.pc += 3;
    return 1;
}
fn decline(_: *TrapInfo, _: ?*anyopaque) callconv(.c) i32 {
    return 0;
}

test "CPU exceptions: the trap code first, otherwise a dead-end Alert" {
    try setUp();
    defer deinit();
    FakeAlert.install();
    defer FakeAlert.uninstall();

    // No trap code: Guru Meditation #8000001C.<pc>
    var info: TrapInfo = .{ .number = 28, .pc = 0x1000, .address = 0x10, .frame = null };
    dispatchTrap(SysBase, &info);
    try testing.expectEqual(@as(u32, 1), FakeAlert.count);
    try testing.expectEqual(@as(u32, 0x8000_001C), FakeAlert.last_num);
    try testing.expectEqual(@as(usize, 0x1000), FakeAlert.last_where);
    try testing.expectEqual(@as(?*const TrapInfo, &info), FakeAlert.last_info);

    // Trap code that handles it: no alert, execution continues at the new pc.
    var handled: u32 = 0;
    try testing.expect(SetTrapCode(SysBase, &skipThree, &handled) == null);
    dispatchTrap(SysBase, &info);
    try testing.expectEqual(@as(u32, 1), FakeAlert.count);
    try testing.expectEqual(@as(u32, 1), handled);
    try testing.expectEqual(@as(usize, 0x1003), info.pc);

    // Trap code that declines: the alert again.
    try testing.expectEqual(@as(?TrapFn, &skipThree), SetTrapCode(SysBase, &decline, null));
    dispatchTrap(SysBase, &info);
    try testing.expectEqual(@as(u32, 2), FakeAlert.count);
    _ = SetTrapCode(SysBase, null, null);

    // A recoverable alert returns.
    Alert(SysBase, AT_Recovery | 0x0001_0000);
    try testing.expectEqual(@as(u32, 3), FakeAlert.count);
    try testing.expectEqual(@as(u32, 0x0001_0000), FakeAlert.last_num);
    try testing.expect(FakeAlert.last_info == null);
    try testing.expect(FakeAlert.last_where != 0);

    // A recoverable Alert, and setting the trap code.
    Alert(SysBase, 0x0100_0000);
    try testing.expectEqual(@as(u32, 4), FakeAlert.count);
    try testing.expectEqual(@as(u32, 0x0100_0000), FakeAlert.last_num);
    try testing.expect(SetTrapCode(SysBase, &decline, null) == null);
    try testing.expectEqual(@as(?TrapFn, &decline), SysBase.this_task.trap_code);
}

/// Task hardware for tests: counts switch requests. The context of a task
/// is the task itself (_task.no_task_hardware.init_context).
const FakeTaskHardware = struct {
    var switches: u32 = 0;
    /// The context an exception was pushed onto, and what it returned.
    var pushed: ?*anyopaque = null;
    const exception_ctx: *anyopaque = @ptrFromInt(0x2000);

    fn switchNow() void {
        switches += 1;
    }
    fn pushException(context: *anyopaque, _: *const anyopaque) *anyopaque {
        pushed = context;
        return exception_ctx;
    }
    fn install() void {
        switches = 0;
        pushed = null;
        task_hardware.* = .{
            .init_context = _task.no_task_hardware.init_context,
            .switch_now = switchNow,
            .idle = _task.no_task_hardware.idle,
            .push_exception = pushException,
            .leave_exception = _task.no_task_hardware.leave_exception,
            .call_on_stack = _task.no_task_hardware.call_on_stack,
        };
    }
    fn uninstall() void {
        task_hardware.* = _task.no_task_hardware;
    }
};

fn idleCode(_: *interface.ExecBase) callconv(.c) void {}

/// What the kernel does on its way out of an exception.
fn exceptionExit(context: *anyopaque) *anyopaque {
    interruptEnter(SysBase);
    return interruptExit(SysBase, context);
}

fn ctx(task: *Task) *anyopaque {
    return task;
}

const boot_ctx: *anyopaque = @ptrFromInt(0x1000);

test "tasks: preemption, their code, NT_TASK, time slices, Forbid, FindTask and RemTask, switch and launch" {
    // A higher priority task preempts at the next exception exit.
    {
        try setUp();
        defer deinit();
        FakeTaskHardware.install();
        defer FakeTaskHardware.uninstall();

        const boot = SysBase.this_task;
        try testing.expectEqualStrings("kernel", boot.name());
        try testing.expectEqual(TaskState.run, boot.state);
        try testing.expect(FindTask(SysBase, "idle") != null);

        const same = CreateTask(SysBase, "same", 0, &idleCode, 1024).?;
        try testing.expectEqual(@as(u32, 0), FakeTaskHardware.switches); // equal priority: no preemption
        try testing.expectEqual(boot_ctx, exceptionExit(boot_ctx));

        const high = CreateTask(SysBase, "high", 10, &idleCode, 1024).?;
        try testing.expectEqual(@as(u32, 1), FakeTaskHardware.switches); // switch asked for at once
        try testing.expectEqual(ctx(high), exceptionExit(boot_ctx));
        try testing.expectEqual(high, SysBase.this_task);
        try testing.expectEqual(TaskState.ready, boot.state);
        try testing.expectEqual(boot_ctx, boot.sp_reg.?);

        // high drops below the others: the first ready one (same, FIFO) runs.
        try testing.expectEqual(@as(i8, 10), SetTaskPri(SysBase, high, -1));
        try testing.expectEqual(ctx(same), exceptionExit(ctx(high)));
        _ = SetTaskPri(SysBase, same, -2);
        try testing.expectEqual(boot_ctx, exceptionExit(ctx(same)));
        try testing.expectEqual(boot, SysBase.this_task);

        RemTask(SysBase, high);
        RemTask(SysBase, same);
        try testing.expect(FindTask(SysBase, "high") == null);
        try expectNoLeaks();
    }
    // InitialPC and finalPC get SysBase.
    {
        try setUp();
        defer deinit();
        TaskCode.calls = 0;

        var task: Task = .{ .node = .{ .name = "code", .pri = -1 } };
        _ = AddTask(SysBase, &task, &TaskCode.initial, &TaskCode.final);
        _task.runCode(SysBase, &task); // what taskEntry runs on the task's stack
        try testing.expectEqual(@as(u32, 2), TaskCode.calls);
        try testing.expectEqual(@as(u32, 0), TaskCode.initial_at);
        try testing.expectEqual(@as(u32, 1), TaskCode.final_at);
        try testing.expectEqual(SysBase.iface(), TaskCode.initial_sys.?);
        try testing.expectEqual(SysBase.iface(), TaskCode.final_sys.?);

        RemTask(SysBase, &task);
        try expectNoLeaks();
    }
    // AddTask makes a node NT_TASK, but leaves NT_PROCESS.
    {
        try setUp();
        defer deinit();
        var task: Task = .{ .node = .{ .name = "untyped", .pri = -1 } };
        _ = AddTask(SysBase, &task, &idleCode, null);
        try testing.expectEqual(NodeType.task, task.node.type);
        RemTask(SysBase, &task);
        var proc: Task = .{ .node = .{ .type = .process, .name = "process", .pri = -1 } };
        _ = AddTask(SysBase, &proc, &idleCode, null);
        try testing.expectEqual(NodeType.process, proc.node.type);
        RemTask(SysBase, &proc);
        try expectNoLeaks();
    }
    // Equal priorities take turns when the time slice is up.
    {
        try setUp();
        defer deinit();
        FakeTaskHardware.install();
        defer FakeTaskHardware.uninstall();

        const boot = SysBase.this_task;
        const other = CreateTask(SysBase, "other", 0, &idleCode, 1024).?;
        var tick: u32 = 1;
        while (tick < SysBase.quantum) : (tick += 1) {
            tickQuantum(SysBase);
            try testing.expectEqual(boot_ctx, exceptionExit(boot_ctx));
        }
        tickQuantum(SysBase); // time slice used up
        try testing.expectEqual(ctx(other), exceptionExit(boot_ctx));

        for (0..SysBase.quantum) |_| tickQuantum(SysBase);
        try testing.expectEqual(boot_ctx, exceptionExit(ctx(other)));
        try testing.expectEqual(boot, SysBase.this_task);

        RemTask(SysBase, other);
        try expectNoLeaks();
    }
    // Forbid holds off the switch until Permit.
    {
        try setUp();
        defer deinit();
        FakeTaskHardware.install();
        defer FakeTaskHardware.uninstall();

        Forbid(SysBase);
        const high = CreateTask(SysBase, "high", 10, &idleCode, 1024).?;
        try testing.expectEqual(@as(u32, 0), FakeTaskHardware.switches);
        try testing.expectEqual(boot_ctx, exceptionExit(boot_ctx)); // forbidden
        Permit(SysBase);
        try testing.expectEqual(@as(u32, 1), FakeTaskHardware.switches);
        try testing.expectEqual(ctx(high), exceptionExit(boot_ctx));

        _ = SetTaskPri(SysBase, high, -5);
        try testing.expectEqual(boot_ctx, exceptionExit(ctx(high)));
        RemTask(SysBase, high);
        try expectNoLeaks();
    }
    // FindTask and RemTask.
    {
        try setUp();
        defer deinit();

        const boot = SysBase.this_task;
        const t = CreateTask(SysBase, "finder", -3, &idleCode, 1024).?;
        try testing.expectEqual(t, FindTask(SysBase, "finder").?);
        try testing.expectEqual(boot, FindTask(SysBase, null).?);
        try testing.expect(FindTask(SysBase, "nope") == null);

        try testing.expectEqual(t, FindTask(SysBase, "finder").?);
        Signal(SysBase, t, SIGBREAKF_CTRL_C);
        try testing.expectEqual(SIGBREAKF_CTRL_C, t.sig_recvd);

        RemTask(SysBase, t);
        try testing.expect(FindTask(SysBase, "finder") == null);
        try expectNoLeaks();
    }
    // Tc_Switch when a task loses the CPU, tc_Launch when it gets it.
    {
        try setUp();
        defer deinit();
        FakeTaskHardware.install();
        defer FakeTaskHardware.uninstall();
        SwitchHooks.reset();

        const boot = SysBase.this_task;
        boot.switch_code = SwitchHooks.onSwitch;
        boot.launch_code = SwitchHooks.onLaunch;
        boot.flags |= TF_SWITCH | TF_LAUNCH;
        const high = CreateTask(SysBase, "high", 10, &idleCode, 1024).?;
        high.switch_code = SwitchHooks.onSwitch;
        high.launch_code = SwitchHooks.onLaunch;
        high.flags |= TF_LAUNCH; // no TF_SWITCH

        // boot loses the CPU to high: boot's tc_Switch, then high's tc_Launch.
        try testing.expectEqual(ctx(high), exceptionExit(boot_ctx));
        try testing.expectEqual(boot, SwitchHooks.switched.?);
        try testing.expectEqual(high, SwitchHooks.launched.?);
        try testing.expectEqual(@as(u32, 1), SwitchHooks.switches);
        try testing.expectEqual(@as(u32, 1), SwitchHooks.launches);
        try testing.expectEqual(SysBase.iface(), SwitchHooks.sys_base.?);

        // Back to boot: high has no TF_SWITCH, boot's tc_Launch runs.
        _ = SetTaskPri(SysBase, high, -1);
        try testing.expectEqual(boot_ctx, exceptionExit(ctx(high)));
        try testing.expectEqual(@as(u32, 1), SwitchHooks.switches);
        try testing.expectEqual(boot, SwitchHooks.launched.?);
        try testing.expectEqual(@as(u32, 2), SwitchHooks.launches);

        // A task that keeps the CPU calls neither.
        try testing.expectEqual(boot_ctx, exceptionExit(boot_ctx));
        try testing.expectEqual(@as(u32, 2), SwitchHooks.launches);

        // Without the flags the functions aren't called.
        boot.flags &= ~(TF_SWITCH | TF_LAUNCH);
        _ = SetTaskPri(SysBase, high, 10);
        try testing.expectEqual(ctx(high), exceptionExit(boot_ctx));
        try testing.expectEqual(@as(u32, 1), SwitchHooks.switches);
        try testing.expectEqual(@as(u32, 3), SwitchHooks.launches); // high's

        // A task that removes itself is gone: no tc_Switch for it.
        high.flags |= TF_SWITCH;
        RemTask(SysBase, null);
        try testing.expectEqual(boot_ctx, exceptionExit(ctx(high)));
        try testing.expectEqual(@as(u32, 1), SwitchHooks.switches);
        try testing.expectEqual(@as(u32, 3), SwitchHooks.launches);
        try expectNoLeaks();
    }
}

/// initialPC and finalPC for the test below: what they got, and in which
/// order they ran.
const TaskCode = struct {
    var calls: u32 = 0;
    var initial_sys: ?*interface.ExecBase = null;
    var initial_at: u32 = 0;
    var final_sys: ?*interface.ExecBase = null;
    var final_at: u32 = 0;

    fn initial(sys: *interface.ExecBase) callconv(.c) void {
        initial_sys = sys;
        initial_at = calls;
        calls += 1;
    }
    fn final(sys: *interface.ExecBase) callconv(.c) void {
        final_sys = sys;
        final_at = calls;
        calls += 1;
    }
};

test "signals: Signal wakes a waiting task, Wait, SetSignal, AllocSignal" {
    try setUp();
    defer deinit();
    FakeTaskHardware.install();
    defer FakeTaskHardware.uninstall();

    const boot = SysBase.this_task;
    const waiter = CreateTask(SysBase, "waiter", 5, &idleCode, 1024).?;
    try testing.expectEqual(ctx(waiter), exceptionExit(boot_ctx));

    // The waiter waits for bit 20 (the part of Wait before its switch).
    const sig: u32 = 1 << 20;
    _task.blockCurrent(SysBase, SysBase.this_task, sig);
    try testing.expectEqual(boot_ctx, exceptionExit(ctx(waiter)));
    try testing.expectEqual(TaskState.wait, waiter.state);

    Signal(SysBase, waiter, 1 << 3); // not waited for: still waiting
    try testing.expectEqual(TaskState.wait, waiter.state);
    const switches = FakeTaskHardware.switches;
    Signal(SysBase, waiter, sig); // wakes it; higher priority: switch
    try testing.expectEqual(TaskState.ready, waiter.state);
    try testing.expectEqual(switches + 1, FakeTaskHardware.switches);
    try testing.expectEqual(ctx(waiter), exceptionExit(boot_ctx));

    // Back in the waiter: Wait finds the signal and returns it.
    try testing.expectEqual(sig, Wait(SysBase, sig | (1 << 21)));
    try testing.expect(SetSignal(SysBase, 0, 0) & sig == 0);
    try testing.expect(SetSignal(SysBase, 0, 1 << 3) & (1 << 3) != 0); // old value, then cleared
    _ = SetSignal(SysBase, 1 << 7, 1 << 7); // set bit 7
    try testing.expect(SetSignal(SysBase, 0, 0) & (1 << 7) != 0);
    _ = SetSignal(SysBase, 0, 0xFFFF_FFFF);

    try testing.expectEqual(@as(i8, 31), AllocSignal(SysBase, -1));
    try testing.expectEqual(@as(i8, 30), AllocSignal(SysBase, -1));
    try testing.expectEqual(@as(i8, -1), AllocSignal(SysBase, 31));
    FreeSignal(SysBase, 31);
    try testing.expectEqual(@as(i8, 31), AllocSignal(SysBase, 31));
    try testing.expectEqual(@as(i8, -1), AllocSignal(SysBase, 4)); // a system signal

    _ = SetTaskPri(SysBase, waiter, -5);
    try testing.expectEqual(boot_ctx, exceptionExit(ctx(waiter)));
    try testing.expectEqual(boot, SysBase.this_task);
    RemTask(SysBase, waiter);
    try expectNoLeaks();
}

const FakeExcept = struct {
    var calls: u32 = 0;
    var last_signals: u32 = 0;
    var last_data: ?*anyopaque = null;
    var enable_again: u32 = 0;

    fn code(signals: u32, data: ?*anyopaque) callconv(.c) u32 {
        calls += 1;
        last_signals = signals;
        last_data = data;
        return enable_again;
    }
};

test "task exceptions: SetExcept, raised at the exception exit, after Forbid, in Wait" {
    try setUp();
    defer deinit();
    FakeTaskHardware.install();
    defer FakeTaskHardware.uninstall();
    FakeExcept.calls = 0;
    FakeExcept.enable_again = 0;

    const boot = SysBase.this_task;
    const ctrl_d = SIGBREAKF_CTRL_D;
    const ctrl_e = SIGBREAKF_CTRL_E;
    boot.except_code = &FakeExcept.code;
    boot.except_data = @ptrFromInt(0x55);
    try testing.expectEqual(@as(u32, 0), SetExcept(SysBase, ctrl_d | ctrl_e, ctrl_d | ctrl_e));
    try testing.expectEqual(boot_ctx, exceptionExit(boot_ctx)); // nothing pending

    // A signal for the running task: raised at the next exception exit,
    // on top of where the task was.
    Signal(SysBase, boot, ctrl_d);
    try testing.expectEqual(FakeTaskHardware.exception_ctx, exceptionExit(boot_ctx));
    try testing.expectEqual(boot_ctx, FakeTaskHardware.pushed.?);
    try testing.expectEqual(@as(u32, 0), FakeExcept.calls); // runs once resumed
    _task.exceptionBody(SysBase);
    try testing.expectEqual(@as(u32, 1), FakeExcept.calls);
    try testing.expectEqual(ctrl_d, FakeExcept.last_signals);
    try testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x55)), FakeExcept.last_data);
    try testing.expectEqual(@as(u32, 0), boot.sig_recvd & ctrl_d);
    try testing.expectEqual(ctrl_e, boot.sig_except); // the code enabled nothing again

    // CTRL-D is an ordinary signal now.
    Signal(SysBase, boot, ctrl_d);
    try testing.expectEqual(boot_ctx, exceptionExit(boot_ctx));
    try testing.expectEqual(ctrl_d, SetSignal(SysBase, 0, ctrl_d) & ctrl_d);

    // Inside Forbid it waits for Permit.
    FakeExcept.enable_again = ctrl_e;
    Forbid(SysBase);
    Signal(SysBase, boot, ctrl_e);
    try testing.expectEqual(boot_ctx, exceptionExit(boot_ctx));
    const switches = FakeTaskHardware.switches;
    Permit(SysBase);
    try testing.expectEqual(switches + 1, FakeTaskHardware.switches);
    try testing.expectEqual(FakeTaskHardware.exception_ctx, exceptionExit(boot_ctx));
    _task.exceptionBody(SysBase);
    try testing.expectEqual(@as(u32, 2), FakeExcept.calls);
    try testing.expectEqual(ctrl_e, boot.sig_except); // enabled again by the code

    // Wait runs it itself, then returns what it waited for.
    Signal(SysBase, boot, ctrl_e | SIGF_SINGLE);
    try testing.expectEqual(SIGF_SINGLE, Wait(SysBase, SIGF_SINGLE));
    try testing.expectEqual(@as(u32, 3), FakeExcept.calls);
    try testing.expectEqual(boot_ctx, exceptionExit(boot_ctx));

    // SetExcept with the signal already there raises it at once.
    try testing.expectEqual(ctrl_e, SetExcept(SysBase, 0, ctrl_e));
    Signal(SysBase, boot, ctrl_e);
    try testing.expectEqual(boot_ctx, exceptionExit(boot_ctx));
    _ = SetExcept(SysBase, ctrl_e, ctrl_e);
    try testing.expectEqual(FakeTaskHardware.exception_ctx, exceptionExit(boot_ctx));
    _task.exceptionBody(SysBase);
    try testing.expectEqual(@as(u32, 4), FakeExcept.calls);

    // A waiting task wakes for its exception and gets it when it runs.
    const waiter = CreateTask(SysBase, "waiter", 5, &idleCode, 1024).?;
    try testing.expectEqual(ctx(waiter), exceptionExit(boot_ctx));
    waiter.except_code = &FakeExcept.code;
    _ = SetExcept(SysBase, ctrl_d, ctrl_d);
    _task.blockCurrent(SysBase, SysBase.this_task, 1 << 20);
    try testing.expectEqual(boot_ctx, exceptionExit(ctx(waiter)));
    Signal(SysBase, waiter, ctrl_d);
    try testing.expectEqual(TaskState.ready, waiter.state);
    try testing.expectEqual(FakeTaskHardware.exception_ctx, exceptionExit(boot_ctx));
    try testing.expectEqual(ctx(waiter), FakeTaskHardware.pushed.?);
    _task.exceptionBody(SysBase);
    try testing.expectEqual(@as(u32, 5), FakeExcept.calls);
    try testing.expectEqual(ctrl_d, FakeExcept.last_signals);

    _ = SetTaskPri(SysBase, waiter, -5);
    try testing.expectEqual(boot_ctx, exceptionExit(ctx(waiter)));
    RemTask(SysBase, waiter);
    try expectNoLeaks();
}

const SoftMsg = struct {
    var port: ?*MsgPort = null;
    var got: u32 = 0;

    fn code(_: ?*anyopaque) callconv(.c) void {
        while (GetMsg(SysBase, port.?)) |_| got += 1;
    }
};

test "messages: PutMsg, GetMsg, ReplyMsg, WaitPort and the port actions" {
    try setUp();
    defer deinit();
    FakeTaskHardware.install();
    defer FakeTaskHardware.uninstall();

    const boot = SysBase.this_task;
    const port = CreateMsgPort(SysBase).?;
    const reply = CreateMsgPort(SysBase).?;
    try testing.expectEqual(@as(u8, 31), port.sig_bit);
    try testing.expectEqual(@as(u8, 30), reply.sig_bit);
    try testing.expectEqual(@as(?*anyopaque, boot), port.sig_task);
    _ = SetSignal(SysBase, 0, 0xFFFF_FFFF);

    // PA_SIGNAL: queued, and the port's task gets the signal.
    var msg: Message = .{ .reply_port = reply };
    var second: Message = .{};
    PutMsg(SysBase, port, &msg);
    PutMsg(SysBase, port, &second);
    try testing.expectEqual(NodeType.message, msg.node.type);
    try testing.expect(SetSignal(SysBase, 0, 0) & port.sigMask() != 0);
    try testing.expectEqual(&msg, WaitPort(SysBase, port)); // there already: no waiting
    try testing.expectEqual(&msg, GetMsg(SysBase, port).?); // oldest first
    try testing.expectEqual(&second, GetMsg(SysBase, port).?);
    try testing.expect(GetMsg(SysBase, port) == null);

    // ReplyMsg: back to the reply port, or NT_FREEMSG without one.
    ReplyMsg(SysBase, &msg);
    try testing.expectEqual(NodeType.replymsg, msg.node.type);
    try testing.expect(SetSignal(SysBase, 0, 0) & reply.sigMask() != 0);
    try testing.expectEqual(&msg, GetMsg(SysBase, reply).?);
    ReplyMsg(SysBase, &second);
    try testing.expectEqual(NodeType.freemsg, second.node.type);

    // PA_IGNORE: only queued.
    _ = SetSignal(SysBase, 0, 0xFFFF_FFFF);
    port.flags = PA_IGNORE;
    PutMsg(SysBase, port, &msg);
    try testing.expectEqual(@as(u32, 0), SetSignal(SysBase, 0, 0));
    try testing.expectEqual(&msg, GetMsg(SysBase, port).?);

    // PA_SOFTINT: causes the software interrupt, which takes the message.
    var soft: Interrupt = .{ .code = vec(SoftMsg.code) };
    SoftMsg.port = port;
    SoftMsg.got = 0;
    port.flags = PA_SOFTINT;
    port.sig_task = &soft;
    PutMsg(SysBase, port, &msg);
    try testing.expectEqual(NodeType.softint, soft.node.type);
    dispatchSoftInts(SysBase);
    try testing.expectEqual(@as(u32, 1), SoftMsg.got);
    port.flags = PA_SIGNAL;
    port.sig_task = boot;

    // A task waiting on its port wakes for a message.
    const waiter = CreateTask(SysBase, "waiter", 5, &idleCode, 1024).?;
    try testing.expectEqual(ctx(waiter), exceptionExit(boot_ctx));
    const wport = CreateMsgPort(SysBase).?;
    try testing.expectEqual(@as(?*anyopaque, waiter), wport.sig_task);
    _task.blockCurrent(SysBase, SysBase.this_task, wport.sigMask()); // WaitPort's Wait
    try testing.expectEqual(boot_ctx, exceptionExit(ctx(waiter)));
    PutMsg(SysBase, wport, &msg);
    try testing.expectEqual(TaskState.ready, waiter.state);
    try testing.expectEqual(ctx(waiter), exceptionExit(boot_ctx));
    try testing.expectEqual(&msg, GetMsg(SysBase, wport).?);
    DeleteMsgPort(SysBase, wport); // by its task, which owns the signal
    _ = SetTaskPri(SysBase, waiter, -5);
    try testing.expectEqual(boot_ctx, exceptionExit(ctx(waiter)));
    RemTask(SysBase, waiter);

    DeleteMsgPort(SysBase, reply);
    DeleteMsgPort(SysBase, port);
    try testing.expectEqual(sdk.exec.tasks.system_signals, boot.sig_alloc); // signals freed
    try expectNoLeaks();
}

test "ports: AddPort, FindPort, RemPort" {
    try setUp();
    defer deinit();

    const port = CreateMsgPort(SysBase).?;
    port.node.name = "test.port";
    AddPort(SysBase, port);
    try testing.expectEqual(port, FindPort(SysBase, "test.port").?);
    try testing.expect(FindPort(SysBase, "other.port") == null);

    try testing.expectEqual(port, FindPort(SysBase, "test.port").?);
    var msg: Message = .{};
    PutMsg(SysBase, port, &msg);
    try testing.expectEqual(&msg, GetMsg(SysBase, port).?);

    RemPort(SysBase, port);
    try testing.expect(FindPort(SysBase, "test.port") == null);
    DeleteMsgPort(SysBase, port);
    try expectNoLeaks();
}

test "semaphores: exclusive and shared, the list, public ones, Procure and Vacate" {
    // Exclusive, nesting, waiters in order, bad releases.
    {
        try setUp();
        defer deinit();
        FakeTaskHardware.install();
        defer FakeTaskHardware.uninstall();

        const boot = SysBase.this_task;
        const a = CreateTask(SysBase, "a", -1, &idleCode, 1024).?;
        const b = CreateTask(SysBase, "b", -1, &idleCode, 1024).?;
        var sem: SignalSemaphore = .{};
        InitSemaphore(SysBase, &sem);
        try testing.expectEqual(@as(i16, -1), sem.queue_count);

        ObtainSemaphore(SysBase, &sem); // free: at once
        ObtainSemaphore(SysBase, &sem); // the owner again: nested
        try testing.expect(AttemptSemaphore(SysBase, &sem));
        try testing.expectEqual(boot, sem.owner.?);
        try testing.expectEqual(@as(i16, 3), sem.nest_count);
        ReleaseSemaphore(SysBase, &sem);

        // a, then b ask for it (the part of ObtainSemaphore before its Wait).
        var ra: SemaphoreRequest = .{ .waiter = a };
        var rb: SemaphoreRequest = .{ .waiter = b };
        try testing.expect(!_locks.enter(SysBase, &sem, &ra));
        try testing.expect(!_locks.enter(SysBase, &sem, &rb));
        try testing.expectEqual(@as(i16, 3), sem.queue_count); // 2 holds + 2 waiters - 1

        ReleaseSemaphore(SysBase, &sem); // still held once
        try testing.expectEqual(boot, sem.owner.?);
        try testing.expectEqual(@as(u32, 0), a.sig_recvd & SIGF_SINGLE);
        ReleaseSemaphore(SysBase, &sem); // straight to a, the first waiter
        try testing.expectEqual(a, sem.owner.?);
        try testing.expectEqual(@as(i16, 1), sem.nest_count);
        try testing.expect(ra.granted);
        try testing.expect(a.sig_recvd & SIGF_SINGLE != 0); // and woken
        try testing.expect(!rb.granted);
        try testing.expect(!AttemptSemaphore(SysBase, &sem));
        _locks.leave(SysBase, &sem, a);
        try testing.expectEqual(b, sem.owner.?);
        _locks.leave(SysBase, &sem, b);
        try testing.expectEqual(@as(i16, -1), sem.queue_count);
        try testing.expect(sem.owner == null);

        // Releasing a free semaphore, or one another task holds, is an alert.
        FakeAlert.install();
        defer FakeAlert.uninstall();
        ReleaseSemaphore(SysBase, &sem);
        try testing.expectEqual(@as(u32, 1), FakeAlert.count);
        try testing.expectEqual(AN_SemCorrupt, FakeAlert.last_num);
        var ra2: SemaphoreRequest = .{ .waiter = a };
        try testing.expect(_locks.enter(SysBase, &sem, &ra2));
        ReleaseSemaphore(SysBase, &sem);
        try testing.expectEqual(@as(u32, 2), FakeAlert.count);
        try testing.expectEqual(a, sem.owner.?); // untouched
        _locks.leave(SysBase, &sem, a);

        RemTask(SysBase, a);
        RemTask(SysBase, b);
        try expectNoLeaks();
    }
    // Shared holders, exclusive waiters, shared hand-over.
    {
        try setUp();
        defer deinit();
        FakeTaskHardware.install();
        defer FakeTaskHardware.uninstall();

        const boot = SysBase.this_task;
        const a = CreateTask(SysBase, "a", -1, &idleCode, 1024).?;
        const b = CreateTask(SysBase, "b", -1, &idleCode, 1024).?;
        const c = CreateTask(SysBase, "c", -1, &idleCode, 1024).?;
        var sem: SignalSemaphore = .{};
        InitSemaphore(SysBase, &sem);

        ObtainSemaphoreShared(SysBase, &sem);
        try testing.expect(sem.owner == null);
        var ra: SemaphoreRequest = .{ .waiter = a, .shared = true };
        try testing.expect(_locks.enter(SysBase, &sem, &ra)); // shared with boot
        try testing.expect(!AttemptSemaphore(SysBase, &sem)); // not exclusively
        try testing.expect(AttemptSemaphoreShared(SysBase, &sem));
        try testing.expectEqual(@as(i16, 3), sem.nest_count);
        ReleaseSemaphore(SysBase, &sem);

        // An exclusive request waits for every shared holder, and shared
        // requests still get in meanwhile - which is the reader-starves-writer
        // property ObtainSemaphoreShared's contract warns about.
        var rb: SemaphoreRequest = .{ .waiter = b };
        try testing.expect(!_locks.enter(SysBase, &sem, &rb));
        var rc: SemaphoreRequest = .{ .waiter = c, .shared = true };
        try testing.expect(_locks.enter(SysBase, &sem, &rc));
        ReleaseSemaphore(SysBase, &sem);
        _locks.leave(SysBase, &sem, a);
        try testing.expect(!rb.granted);
        _locks.leave(SysBase, &sem, c); // the last shared holder: b gets it
        try testing.expectEqual(b, sem.owner.?);
        try testing.expect(rb.granted);

        // Behind the exclusive owner: all shared waiters get it together, the
        // exclusive waiter between them after they are done.
        var ra2: SemaphoreRequest = .{ .waiter = a, .shared = true };
        var rx: SemaphoreRequest = .{ .waiter = boot };
        var rc2: SemaphoreRequest = .{ .waiter = c, .shared = true };
        try testing.expect(!_locks.enter(SysBase, &sem, &ra2));
        try testing.expect(!_locks.enter(SysBase, &sem, &rx));
        try testing.expect(!_locks.enter(SysBase, &sem, &rc2));
        _locks.leave(SysBase, &sem, b);
        try testing.expect(sem.owner == null);
        try testing.expectEqual(@as(i16, 2), sem.nest_count);
        try testing.expect(ra2.granted and rc2.granted);
        try testing.expect(!rx.granted);
        _locks.leave(SysBase, &sem, a);
        _locks.leave(SysBase, &sem, c);
        try testing.expectEqual(boot, sem.owner.?);
        try testing.expect(rx.granted);

        // The exclusive owner taking it shared just nests.
        ObtainSemaphoreShared(SysBase, &sem);
        try testing.expectEqual(boot, sem.owner.?);
        try testing.expectEqual(@as(i16, 2), sem.nest_count);
        ReleaseSemaphore(SysBase, &sem);
        ReleaseSemaphore(SysBase, &sem);
        try testing.expectEqual(@as(i16, -1), sem.queue_count);

        RemTask(SysBase, a);
        RemTask(SysBase, b);
        RemTask(SysBase, c);
        try expectNoLeaks();
    }
    // ObtainSemaphoreList and public semaphores.
    {
        try setUp();
        defer deinit();
        FakeTaskHardware.install();
        defer FakeTaskHardware.uninstall();

        const boot = SysBase.this_task;
        const a = CreateTask(SysBase, "a", -1, &idleCode, 1024).?;
        var sems: [3]SignalSemaphore = .{ .{}, .{}, .{} };
        var list: List = .{};
        list.init(.signalsem);
        for (&sems) |*s| {
            InitSemaphore(SysBase, s);
            AddTail(SysBase, &list, &s.link);
        }

        // All free: the whole list at once.
        ObtainSemaphoreList(SysBase, &list);
        for (&sems) |*s| try testing.expectEqual(boot, s.owner.?);
        ReleaseSemaphoreList(SysBase, &list);
        for (&sems) |*s| try testing.expectEqual(@as(i16, -1), s.queue_count);

        // a holds the middle one: the others are taken, that one is queued,
        // and it comes when a releases it.
        var ra: SemaphoreRequest = .{ .waiter = a };
        try testing.expect(_locks.enter(SysBase, &sems[1], &ra));
        // ObtainSemaphoreList's first half: a request queued on every
        // semaphore before any is waited for (locks/obtainsemaphorelist.zig).
        // The waiting half would need task switching the host has not got.
        Forbid(SysBase);
        var queue_it = list.iterator();
        while (queue_it.next()) |node| {
            const sem: *SignalSemaphore = @fieldParentPtr("link", node);
            sem.multiple_link = .{ .waiter = boot };
            _ = _locks.enter(SysBase, sem, &sem.multiple_link);
        }
        Permit(SysBase);
        try testing.expectEqual(boot, sems[0].owner.?);
        try testing.expectEqual(boot, sems[2].owner.?);
        try testing.expect(!sems[1].multiple_link.granted);
        _locks.leave(SysBase, &sems[1], a);
        try testing.expectEqual(boot, sems[1].owner.?);
        try testing.expect(sems[1].multiple_link.granted);
        ReleaseSemaphoreList(SysBase, &list);

        // Public semaphores.
        var public: SignalSemaphore = .{ .link = .{ .name = "test.sem" } };
        AddSemaphore(SysBase, &public);
        try testing.expectEqual(&public, FindSemaphore(SysBase, "test.sem").?);
        try testing.expectEqual(&public, FindSemaphore(SysBase, "test.sem").?);
        ObtainSemaphoreShared(SysBase, &public);
        try testing.expect(AttemptSemaphoreShared(SysBase, &public));
        ReleaseSemaphore(SysBase, &public);
        ReleaseSemaphore(SysBase, &public);
        try testing.expectEqual(@as(i16, -1), public.queue_count);
        RemSemaphore(SysBase, &public);
        try testing.expect(FindSemaphore(SysBase, "test.sem") == null);

        RemTask(SysBase, a);
        try expectNoLeaks();
    }
    // Procure and Vacate.
    {
        try setUp();
        defer deinit();
        FakeTaskHardware.install();
        defer FakeTaskHardware.uninstall();

        const boot = SysBase.this_task;
        const b = CreateTask(SysBase, "b", -1, &idleCode, 1024).?;
        var sem: SignalSemaphore = .{};
        InitSemaphore(SysBase, &sem);
        const port = CreateMsgPort(SysBase).?;

        // Free: granted at once, the bid comes back with the semaphore.
        var bid = SemaphoreMessage.init(port, false);
        Procure(SysBase, &sem, &bid);
        try testing.expectEqual(&bid.msg, GetMsg(SysBase, port).?);
        try testing.expectEqual(NodeType.replymsg, bid.msg.node.type);
        try testing.expectEqual(&sem, bid.semaphore.?);
        try testing.expectEqual(boot, sem.owner.?);

        // The owner bidding exclusively again nests: granted at once too.
        // Vacate clears ssm_Semaphore even for a granted bid.
        var again = SemaphoreMessage.init(port, false);
        Procure(SysBase, &sem, &again);
        try testing.expectEqual(&again.msg, GetMsg(SysBase, port).?);
        try testing.expectEqual(@as(i16, 2), sem.nest_count);
        Vacate(SysBase, &sem, &again);
        try testing.expect(again.semaphore == null);
        try testing.expectEqual(@as(i16, 1), sem.nest_count);

        // A shared bid from the exclusive owner is no nesting (as in the ROM):
        // it waits until the exclusive hold is gone. Any non-zero ln_Name
        // means shared.
        var own_shared = SemaphoreMessage.init(port, false);
        own_shared.msg.node.name = @ptrFromInt(2);
        Procure(SysBase, &sem, &own_shared);
        try testing.expect(GetMsg(SysBase, port) == null);
        try testing.expect(own_shared.request.shared);

        // Task a bids shared: it waits behind boot's exclusive hold.
        const a = CreateTask(SysBase, "a", 5, &idleCode, 1024).?;
        try testing.expectEqual(ctx(a), exceptionExit(boot_ctx));
        var shared_bid = SemaphoreMessage.init(port, true);
        Procure(SysBase, &sem, &shared_bid);
        try testing.expect(GetMsg(SysBase, port) == null);
        _ = SetTaskPri(SysBase, a, -1);
        try testing.expectEqual(boot_ctx, exceptionExit(ctx(a)));

        // Then b asks exclusively (the part of ObtainSemaphore before its Wait).
        var rb: SemaphoreRequest = .{ .waiter = b };
        try testing.expect(!_locks.enter(SysBase, &sem, &rb));

        // Vacating boot's exclusive bid hands the semaphore to both shared
        // bids together.
        Vacate(SysBase, &sem, &bid);
        try testing.expect(bid.semaphore == null);
        try testing.expectEqual(&own_shared.msg, GetMsg(SysBase, port).?);
        try testing.expectEqual(&shared_bid.msg, GetMsg(SysBase, port).?);
        try testing.expectEqual(&sem, shared_bid.semaphore.?);
        try testing.expect(sem.owner == null);
        try testing.expectEqual(@as(i16, 2), sem.nest_count);
        Vacate(SysBase, &sem, &own_shared);
        try testing.expectEqual(@as(i16, 1), sem.nest_count);

        // A bid still waiting is withdrawn: back without the semaphore.
        var late = SemaphoreMessage.init(port, false);
        Procure(SysBase, &sem, &late);
        try testing.expect(GetMsg(SysBase, port) == null);
        const queued = sem.queue_count;
        Vacate(SysBase, &sem, &late);
        try testing.expectEqual(&late.msg, GetMsg(SysBase, port).?);
        try testing.expect(late.semaphore == null);
        try testing.expectEqual(queued - 1, sem.queue_count);

        // boot vacates a's bid (any task may): b gets it. Vacating it again
        // does nothing.
        Vacate(SysBase, &sem, &shared_bid);
        try testing.expectEqual(b, sem.owner.?);
        try testing.expect(rb.granted);
        Vacate(SysBase, &sem, &shared_bid);
        try testing.expectEqual(b, sem.owner.?);
        _locks.leave(SysBase, &sem, b);
        try testing.expectEqual(@as(i16, -1), sem.queue_count);

        DeleteMsgPort(SysBase, port);
        RemTask(SysBase, a);
        RemTask(SysBase, b);
        try expectNoLeaks();
    }
}

test "memory pools: puddles, the threshold, clearing" {
    // Many small blocks share a puddle, DeletePool frees the lot.
    {
        try setUp();
        defer deinit();

        const before = AvailMem(SysBase, MEMF_ANY);
        const pool = CreatePool(SysBase, MEMF_ANY, 4096, 256).?;
        // Nothing is taken from the system yet beyond the pool itself.
        const empty = AvailMem(SysBase, MEMF_ANY);
        try testing.expect(empty > before - 4096);

        // Forty small nodes, all of them out of one puddle.
        var blocks: [40]*anyopaque = undefined;
        for (&blocks) |*b| b.* = AllocPooled(SysBase, pool, 24).?;
        for (blocks, 0..) |b, i| {
            for (blocks[i + 1 ..]) |other| try testing.expect(b != other);
        }
        const filled = AvailMem(SysBase, MEMF_ANY);
        try testing.expect(empty - filled >= 4096);
        try testing.expect(empty - filled < 8192);

        // A freed block is space the next request can have back.
        FreePooled(SysBase, pool, blocks[10], 24);
        try testing.expectEqual(blocks[10], AllocPooled(SysBase, pool, 24).?);

        // Nothing has to be freed first, and it all comes back.
        DeletePool(SysBase, pool);
        try testing.expectEqual(before, AvailMem(SysBase, MEMF_ANY));

        DeletePool(SysBase, null); // ignored
        try testing.expect(AllocPooled(SysBase, null, 8) == null);
        try expectNoLeaks();
    }
    // The threshold, clearing, and a puddle too small to be one.
    {
        try setUp();
        defer deinit();

        const before = AvailMem(SysBase, MEMF_ANY);
        // A puddle that could not hold its own header is not a puddle.
        try testing.expect(CreatePool(SysBase, MEMF_ANY, 8, 0) == null);
        try testing.expectEqual(before, AvailMem(SysBase, MEMF_ANY));

        const pool = CreatePool(SysBase, MEMF_ANY, 4096, 256).?;
        const empty = AvailMem(SysBase, MEMF_ANY);

        // At or above the threshold the block gets a puddle of its own, which
        // goes straight back to the system when the block is freed.
        const big = AllocPooled(SysBase, pool, 1024).?;
        try testing.expect(AvailMem(SysBase, MEMF_ANY) < empty);
        FreePooled(SysBase, pool, big, 1024);
        try testing.expectEqual(empty, AvailMem(SysBase, MEMF_ANY));

        // Below it the puddle stays with the pool, which is what makes the
        // next request cost nothing.
        const small = AllocPooled(SysBase, pool, 32).?;
        const with_puddle = AvailMem(SysBase, MEMF_ANY);
        FreePooled(SysBase, pool, small, 32);
        try testing.expectEqual(with_puddle, AvailMem(SysBase, MEMF_ANY));
        FreePooled(SysBase, pool, null, 32); // ignored
        FreePooled(SysBase, null, small, 32); // ignored
        DeletePool(SysBase, pool);
        try testing.expectEqual(before, AvailMem(SysBase, MEMF_ANY));

        // MEMF_CLEAR clears every block, not only the first: this one is
        // reused memory that was written to.
        const cleared = CreatePool(SysBase, MEMF_ANY | MEMF_CLEAR, 4096, 0).?;
        const dirty = AllocPooled(SysBase, cleared, 64).?;
        @memset(@as([*]u8, @ptrCast(dirty))[0..64], 0xA5);
        FreePooled(SysBase, cleared, dirty, 64);
        const again: [*]const u8 = @ptrCast(AllocPooled(SysBase, cleared, 64).?);
        for (again[0..64]) |b| try testing.expectEqual(@as(u8, 0), b);
        DeletePool(SysBase, cleared);

        // A pool made and freed again gives back all it took.
        const p = CreatePool(SysBase, MEMF_ANY, 2048, 0).?;
        _ = AllocPooled(SysBase, p, 16).?;
        DeletePool(SysBase, p);
        try testing.expectEqual(before, AvailMem(SysBase, MEMF_ANY));
        try expectNoLeaks();
    }
}

test "AllocVec remembers the size, FreeVec gives it all back" {
    try setUp();
    defer deinit();

    const before = AvailMem(SysBase, MEMF_ANY);
    const v = AllocVec(SysBase, 100, MEMF_CLEAR).?;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(v) % sdk.exec.MEM_BLOCKSIZE);
    const bytes: [*]const u8 = @ptrCast(v);
    for (bytes[0..100]) |b| try testing.expectEqual(@as(u8, 0), b);
    // The whole block's size is in the word just below what AllocVec
    // answered, which is what lets FreeVec take only the address.
    const size_word: *const u32 = @ptrFromInt(@intFromPtr(v) - 4);
    try testing.expectEqual(@as(u32, 100 + _memory.vec_header), size_word.*);
    try testing.expect(AvailMem(SysBase, MEMF_ANY) < before);
    FreeVec(SysBase, v);
    FreeVec(SysBase, null); // ignored
    try testing.expectEqual(before, AvailMem(SysBase, MEMF_ANY));
    try testing.expect(AllocVec(SysBase, 0, MEMF_ANY) == null);

    const w = AllocVec(SysBase, 8, MEMF_ANY).?;
    FreeVec(SysBase, w);
    try testing.expectEqual(before, AvailMem(SysBase, MEMF_ANY));
    try expectNoLeaks();
}

test "CopyMem, CopyMemQuick and SetMem" {
    try setUp();
    defer deinit();

    var src: [64]u8 align(4) = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i + 1);
    var dst: [64]u8 align(4) = @splat(0);

    // Any alignment, any length.
    CopyMem(SysBase, &src[3], &dst[5], 21);
    try testing.expectEqualSlices(u8, src[3..24], dst[5..26]);
    try testing.expectEqual(@as(u8, 0), dst[4]);
    try testing.expectEqual(@as(u8, 0), dst[26]);
    CopyMem(SysBase, &src[0], &dst[0], 0); // nothing
    try testing.expectEqual(@as(u8, 0), dst[0]);

    // Overlapping, both ways.
    var buf: [32]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast(i);
    CopyMem(SysBase, &buf[0], &buf[4], 16);
    for (buf[4..20], 0..) |b, i| try testing.expectEqual(@as(u8, @intCast(i)), b);
    for (&buf, 0..) |*b, i| b.* = @intCast(i);
    CopyMem(SysBase, &buf[4], &buf[0], 16);
    for (buf[0..16], 4..) |b, i| try testing.expectEqual(@as(u8, @intCast(i)), b);

    // CopyMemQuick: longwords; unaligned arguments are still copied right.
    @memset(&dst, 0);
    CopyMemQuick(SysBase, &src[0], &dst[8], 32);
    try testing.expectEqualSlices(u8, src[0..32], dst[8..40]);
    try testing.expectEqual(@as(u8, 0), dst[40]);
    CopyMemQuick(SysBase, &src[1], &dst[3], 10);
    try testing.expectEqualSlices(u8, src[1..11], dst[3..13]);

    // SetMem
    @memset(&dst, 0);
    SetMem(SysBase, &dst[2], 0xAB, 7);
    try testing.expectEqual(@as(u8, 0), dst[1]);
    for (dst[2..9]) |b| try testing.expectEqual(@as(u8, 0xAB), b);
    try testing.expectEqual(@as(u8, 0), dst[9]);

    // A copy, a quick copy and a fill, side by side.
    @memset(&dst, 0);
    CopyMem(SysBase, &src, &dst, 5);
    CopyMemQuick(SysBase, &src[8], &dst[8], 8);
    SetMem(SysBase, &dst[20], 7, 3);
    try testing.expectEqualSlices(u8, src[0..5], dst[0..5]);
    try testing.expectEqualSlices(u8, src[8..16], dst[8..16]);
    try testing.expectEqualSlices(u8, &.{ 7, 7, 7 }, dst[20..23]);
}

/// A device with two units that refuses other unit numbers.
const TestDevice = struct {
    var units: [2]Unit = .{ .{}, .{} };
    var closes: u32 = 0;
    /// A device's own error code. Positive, so it cannot be mistaken for
    /// one of the system's IOERR_* values, which are negative.
    const no_such_unit: i32 = 32;

    fn open(dev: *Device, io: *IORequest, unit: u32, flags: u32) callconv(.c) i32 {
        _ = flags;
        if (unit >= units.len) return no_such_unit;
        dev.open_cnt += 1;
        dev.flags &= ~LIBF_DELEXP;
        units[unit].open_cnt += 1;
        io.unit = &units[unit];
        return 0;
    }
    fn close(dev: *Device, io: *IORequest) callconv(.c) ?*anyopaque {
        closes += 1;
        io.unit.?.open_cnt -= 1;
        return testDevClose(dev, io);
    }
    const vectors = [_]*const anyopaque{
        vec(open),
        vec(close),
        vec(exec_base.libExpunge),
        vec(exec_base.libExtFunc),
        vec(testDevBeginIO),
        vec(testDevAbortIO),
    };
};

test "devices: AddDevice, OpenDevice with units, CloseDevice, RemDevice" {
    try setUp();
    defer deinit();
    TestDevice.closes = 0;
    TestDevice.units = .{ .{}, .{} };

    const dev = MakeLibrary(SysBase, &TestDevice.vectors, @sizeOf(Device), null, null).?;
    dev.node.name = "test.device";
    AddDevice(SysBase, dev);
    try testing.expectEqual(NodeType.device, dev.node.type);
    try testing.expect(OpenLibrary(SysBase, "test.device", 0) == null); // not a library

    // Missing device: IOERR_OPENFAIL. A unit the device refuses: the error
    // its Open returned, in io_Error too. io_Device is null either way.
    var io: IORequest = .{};
    try testing.expectEqual(@as(i32, IOERR_OPENFAIL), OpenDevice(SysBase, "nope.device", 0, &io, 0));
    try testing.expect(io.device == null);
    try testing.expectEqual(IOERR_OPENFAIL, io.err);
    try testing.expectEqual(TestDevice.no_such_unit, OpenDevice(SysBase, "test.device", 5, &io, 0));
    try testing.expect(io.device == null);
    try testing.expectEqual(@as(i8, TestDevice.no_such_unit), io.err);
    try testing.expectEqual(@as(u16, 0), dev.open_cnt);

    // Success: io_Device and the unit Open picked; io_Error cleared.
    try testing.expectEqual(@as(i32, 0), OpenDevice(SysBase, "test.device", 1, &io, 0));
    try testing.expectEqual(dev, io.device.?);
    try testing.expectEqual(&TestDevice.units[1], io.unit.?);
    try testing.expectEqual(@as(i8, 0), io.err);
    try testing.expectEqual(@as(u16, 1), dev.open_cnt);
    try testing.expectEqual(@as(u16, 1), TestDevice.units[1].open_cnt);

    // The standard BeginIO knows no commands.
    io.command = CMD_READ;
    io.flags = IOF_QUICK;
    dev.vector(sdk.exec.BeginIOFn, DEV_BEGINIO)(dev, &io);
    try testing.expectEqual(IOERR_NOCMD, io.err);

    // RemDevice while open only marks it; the last CloseDevice expunges.
    try testing.expect(RemDevice(SysBase, dev) == null);
    try testing.expect(dev.flags & LIBF_DELEXP != 0);
    try testing.expect(FindName(SysBase, &SysBase.device_list, "test.device") != null);
    CloseDevice(SysBase, &io);
    try testing.expectEqual(@as(u32, 1), TestDevice.closes);
    try testing.expectEqual(@as(u16, 0), TestDevice.units[1].open_cnt);
    try testing.expect(io.device == null and io.unit == null);
    try testing.expect(FindName(SysBase, &SysBase.device_list, "test.device") == null);
    CloseDevice(SysBase, &io); // closed already: nothing
    try testing.expectEqual(@as(u32, 1), TestDevice.closes);

    // Low memory flushes devices nobody has open, as libraries.
    const idle = MakeLibrary(SysBase, &test_device_vectors, @sizeOf(Device), null, null).?;
    idle.node.name = "idle.device";
    AddDevice(SysBase, idle);
    const data: sdk.exec.MemHandlerData = .{ .request_size = 0, .request_flags = 0, .flags = 0 };
    try testing.expectEqual(sdk.exec.MEM_TRY_AGAIN, _library.flushLibraries(&data, SysBase));
    try testing.expect(FindName(SysBase, &SysBase.device_list, "idle.device") == null);
    try expectNoLeaks();
}

/// A device that does CMD_READ at once (io_Actual = io_Length) and keeps
/// CMD_WRITE on its unit's port to finish later.
const IoTestDevice = struct {
    var unit: Unit = .{};

    fn open(dev: *Device, io: *IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
        _ = unit_number;
        _ = flags;
        dev.open_cnt += 1;
        io.unit = &unit;
        return 0;
    }
    fn beginIO(dev: *Device, io: *IORequest) callconv(.c) void {
        _ = dev;
        const std_req: *IOStdReq = @fieldParentPtr("req", io);
        switch (io.command) {
            CMD_READ => {
                std_req.actual = std_req.length;
                io.err = 0;
                ReplyIO(SysBase, io);
            },
            CMD_WRITE => {
                io.flags &= ~IOF_QUICK; // not done yet
                PutMsg(SysBase, &unit.msg_port, &io.message);
            },
            sdk.exec.CMD_FLUSH => ReplyIO(SysBase, io), // "done", but io_Error left alone
            else => {
                io.err = IOERR_NOCMD;
                ReplyIO(SysBase, io);
            },
        }
    }
    /// Its AbortIO's error for a request it doesn't have (any more).
    const cannot_abort: i32 = 1;

    /// Takes back a CMD_WRITE still on the unit's port.
    fn abortIO(dev: *Device, io: *IORequest) callconv(.c) i32 {
        _ = dev;
        Disable(SysBase);
        defer Enable(SysBase);
        var it = unit.msg_port.msg_list.iterator();
        while (it.next()) |node| {
            if (node != &io.message.node) continue;
            Remove(SysBase, node);
            io.err = IOERR_ABORTED;
            ReplyIO(SysBase, io);
            return 0;
        }
        return cannot_abort;
    }
    const vectors = [_]*const anyopaque{
        vec(open),
        vec(testDevClose),
        vec(exec_base.libExpunge),
        vec(exec_base.libExtFunc),
        vec(beginIO),
        vec(abortIO),
    };
};

test "device I/O: DoIO, SendIO, WaitIO, ReplyIO" {
    try setUp();
    defer deinit();
    FakeTaskHardware.install();
    defer FakeTaskHardware.uninstall();

    IoTestDevice.unit = .{};
    IoTestDevice.unit.msg_port.flags = PA_IGNORE;
    IoTestDevice.unit.msg_port.msg_list.init(.message);
    const dev = MakeLibrary(SysBase, &IoTestDevice.vectors, @sizeOf(Device), null, null).?;
    dev.node.name = "io.device";
    AddDevice(SysBase, dev);
    const port = CreateMsgPort(SysBase).?;
    var req: IOStdReq = .{ .req = .{ .message = .{ .reply_port = port, .length = @sizeOf(IOStdReq) } } };
    try testing.expectEqual(@as(i32, 0), OpenDevice(SysBase, "io.device", 0, &req.req, 0));

    // DoIO, done inside BeginIO: no reply message, the result is there.
    // As in the ROM, ln_Type is left alone.
    req.req.command = CMD_READ;
    req.length = 12;
    req.req.message.node.type = .replymsg;
    try testing.expectEqual(@as(i32, 0), DoIO(SysBase, &req.req));
    try testing.expectEqual(@as(u64, 12), req.actual);
    try testing.expect(req.req.flags & IOF_QUICK != 0);
    try testing.expectEqual(NodeType.replymsg, req.req.message.node.type);
    try testing.expect(GetMsg(SysBase, port) == null);

    // DoIO returns io_Error, sign-extended.
    req.req.command = 99;
    try testing.expectEqual(@as(i32, IOERR_NOCMD), DoIO(SysBase, &req.req));

    // io_Error starts as IOERR_OPENFAIL: a device that doesn't clear it
    // reports a failure.
    req.req.command = sdk.exec.CMD_FLUSH;
    try testing.expectEqual(@as(i32, IOERR_OPENFAIL), DoIO(SysBase, &req.req));

    // DoIO sets io_Flags to just IOF_QUICK, as the ROM does.
    req.req.flags = 0x80;
    req.req.command = CMD_READ;
    try testing.expectEqual(@as(i32, 0), DoIO(SysBase, &req.req));
    try testing.expectEqual(IOF_QUICK, req.req.flags);

    // SendIO clears io_Flags (IOF_QUICK from the DoIO and any other bit):
    // even a command the device does at once is replied, and WaitIO takes
    // it off the port.
    req.req.command = CMD_READ;
    req.req.flags |= 0x80;
    req.length = 7;
    SendIO(SysBase, &req.req);
    try testing.expectEqual(@as(u8, 0), req.req.flags);
    try testing.expectEqual(NodeType.replymsg, req.req.message.node.type);
    try testing.expectEqual(&req.req, CheckIO(SysBase, &req.req).?);
    try testing.expectEqual(@as(i32, 0), WaitIO(SysBase, &req.req));
    try testing.expectEqual(@as(u64, 7), req.actual);
    try testing.expect(GetMsg(SysBase, port) == null);

    // SendIO of one the device finishes later: it waits at the unit.
    _ = SetSignal(SysBase, 0, port.sigMask());
    req.req.command = CMD_WRITE;
    SendIO(SysBase, &req.req);
    try testing.expectEqual(NodeType.message, req.req.message.node.type);
    try testing.expect(CheckIO(SysBase, &req.req) == null); // not done
    try testing.expectEqual(@as(u32, 0), SetSignal(SysBase, 0, 0) & port.sigMask());
    // The device is done: ReplyIO sends it back, and signals the port.
    try testing.expectEqual(&req.req.message, GetMsg(SysBase, &IoTestDevice.unit.msg_port).?);
    req.req.err = 0;
    ReplyIO(SysBase, &req.req);
    try testing.expect(SetSignal(SysBase, 0, 0) & port.sigMask() != 0);
    try testing.expectEqual(&req.req, CheckIO(SysBase, &req.req).?);
    try testing.expectEqual(@as(i32, 0), WaitIO(SysBase, &req.req));
    try testing.expect(GetMsg(SysBase, port) == null);

    // ReplyIO of a request still marked quick replies nothing.
    req.req.flags = IOF_QUICK;
    ReplyIO(SysBase, &req.req);
    try testing.expect(GetMsg(SysBase, port) == null);

    // A read, done at once and then sent and waited for.
    req.req.command = CMD_READ;
    req.length = 3;
    try testing.expectEqual(@as(i32, 0), DoIO(SysBase, &req.req));
    try testing.expectEqual(@as(u64, 3), req.actual);
    SendIO(SysBase, &req.req);
    try testing.expectEqual(&req.req, CheckIO(SysBase, &req.req).?);
    try testing.expectEqual(@as(i32, 0), WaitIO(SysBase, &req.req));
    try testing.expect(GetMsg(SysBase, port) == null);

    // AbortIO: the device takes back a request it still has, which comes
    // back with IOERR_ABORTED. For one it doesn't have: the device's error.
    req.req.command = CMD_WRITE;
    SendIO(SysBase, &req.req);
    try testing.expect(CheckIO(SysBase, &req.req) == null);
    try testing.expectEqual(@as(i32, 0), AbortIO(SysBase, &req.req));
    try testing.expectEqual(&req.req, CheckIO(SysBase, &req.req).?);
    try testing.expectEqual(@as(i32, IOERR_ABORTED), WaitIO(SysBase, &req.req));
    try testing.expect(GetMsg(SysBase, &IoTestDevice.unit.msg_port) == null);
    try testing.expect(GetMsg(SysBase, port) == null);
    try testing.expectEqual(IoTestDevice.cannot_abort, AbortIO(SysBase, &req.req));

    // A request without a reply port: WaitIO can't wait for it.
    var lone: IOStdReq = .{};
    try testing.expectEqual(@as(i32, 0), OpenDevice(SysBase, "io.device", 0, &lone.req, 0));
    lone.req.command = CMD_WRITE;
    SendIO(SysBase, &lone.req);
    try testing.expectEqual(@as(i32, IOERR_NOREPLYPORT), WaitIO(SysBase, &lone.req));
    try testing.expectEqual(&lone.req.message, GetMsg(SysBase, &IoTestDevice.unit.msg_port).?);
    CloseDevice(SysBase, &lone.req);

    CloseDevice(SysBase, &req.req);

    // No device: DoIO and AbortIO return IOERR_OPENFAIL. SendIO sets it and
    // leaves the request marked quick, so WaitIO returns it at once.
    try testing.expectEqual(@as(i32, IOERR_OPENFAIL), DoIO(SysBase, &req.req));
    try testing.expectEqual(@as(i32, IOERR_OPENFAIL), AbortIO(SysBase, &req.req));
    req.req.err = 0;
    SendIO(SysBase, &req.req);
    try testing.expectEqual(IOERR_OPENFAIL, req.req.err);
    try testing.expectEqual(@as(i32, IOERR_OPENFAIL), WaitIO(SysBase, &req.req));
    try testing.expect(GetMsg(SysBase, port) == null);

    _ = RemDevice(SysBase, dev);
    DeleteMsgPort(SysBase, port);
    try expectNoLeaks();
}

test "CreateIORequest, DeleteIORequest" {
    try setUp();
    defer deinit();
    FakeTaskHardware.install();
    defer FakeTaskHardware.uninstall();
    const port = CreateMsgPort(SysBase).?;

    // No port, or a size that can't hold an IORequest or fit mn_Length.
    try testing.expect(CreateIORequest(SysBase, null, @sizeOf(IOStdReq)) == null);
    try testing.expect(CreateIORequest(SysBase, port, @sizeOf(IORequest) - 1) == null);
    try testing.expect(CreateIORequest(SysBase, port, 0x10000) == null);

    // Cleared, "finished" (NT_REPLYMSG), for the port, with its size.
    const io = CreateIORequest(SysBase, port, @sizeOf(IOStdReq)).?;
    try testing.expectEqual(NodeType.replymsg, io.message.node.type);
    try testing.expectEqual(port, io.message.reply_port.?);
    try testing.expectEqual(@as(u16, @sizeOf(IOStdReq)), io.message.length);
    try testing.expect(io.device == null);
    const std_req: *IOStdReq = @fieldParentPtr("req", io);
    try testing.expectEqual(@as(u64, 0), std_req.length);
    try testing.expectEqual(io, CheckIO(SysBase, io).?); // nothing in progress
    DeleteIORequest(SysBase, io);
    DeleteIORequest(SysBase, null);

    // A request exactly the size of an IORequest.
    const via = CreateIORequest(SysBase, port, @sizeOf(IORequest)).?;
    try testing.expectEqual(@as(u16, @sizeOf(IORequest)), via.message.length);
    DeleteIORequest(SysBase, via);

    DeleteMsgPort(SysBase, port);
    try expectNoLeaks();
}

/// A made-up ROM for the resident tests.
const TestRom = struct {
    var plain_inits: u32 = 0;
    var plain_fails = false;
    var device_fails = false;

    fn plainInit(seg_list: ?*anyopaque, sys: *interface.ExecBase) callconv(.c) ?*anyopaque {
        _ = seg_list;
        plain_inits += 1;
        return if (plain_fails) null else sys;
    }
    fn deviceInit(lib: *Library, seg_list: ?*anyopaque, _: *interface.ExecBase) callconv(.c) ?*Library {
        _ = seg_list;
        return if (device_fails) null else lib;
    }
    const device_table = InitTable{
        .data_size = @sizeOf(Device),
        .vectors = &test_device_vectors,
        .vector_count = test_device_vectors.len,
        .init = &deviceInit,
    };
    const library_table = InitTable{
        .data_size = @sizeOf(Library),
        .vectors = &test_vectors,
        .vector_count = test_vectors.len,
    };

    /// ROM tags between other words; two of those look like a match word,
    /// but no match tag points back at them.
    var rom: extern struct {
        junk: [4]u32,
        device: Resident,
        gap: u32,
        library: Resident,
        plain: Resident,
        old_device: Resident,
        tail: [2]u32,
    } = undefined;

    fn build() void {
        rom.junk = .{ 0x1234_5678, RTC_MATCHWORD, 0xDEAD_BEEF, 0 };
        rom.device = .{
            .match_tag = &rom.device,
            .flags = RTF_COLDSTART | RTF_AUTOINIT,
            .version = 2,
            .type = .device,
            .pri = 5,
            .name = "test.device",
            .id_string = "test.device 2.0",
            .init = &device_table,
        };
        rom.gap = RTC_MATCHWORD;
        rom.library = .{
            .match_tag = &rom.library,
            .flags = RTF_AUTOINIT, // no start class: InitResident only
            .version = 1,
            .type = .library,
            .name = "test.library",
            .init = &library_table,
        };
        rom.plain = .{
            .match_tag = &rom.plain,
            .flags = RTF_COLDSTART,
            .version = 1,
            .pri = 10,
            .name = "plain",
            .init = vec(plainInit),
        };
        // An older test.device: the scan keeps version 2.
        rom.old_device = rom.device;
        rom.old_device.match_tag = &rom.old_device;
        rom.old_device.version = 1;
        rom.tail = .{ 0, 0 };
        plain_inits = 0;
        plain_fails = false;
        device_fails = false;
    }
};

test "residents: ROM scan, FindResident, InitCode, InitResident" {
    try setUp();
    defer deinit();

    TestRom.build();
    const start = @intFromPtr(&TestRom.rom);
    try initResidents(SysBase, start, start + @sizeOf(@TypeOf(TestRom.rom)));

    // By priority; of the two test.device tags the newer one counts.
    const table = SysBase.res_modules.?;
    try testing.expectEqual(&TestRom.rom.plain, table[0].?);
    try testing.expectEqual(&TestRom.rom.device, table[1].?);
    try testing.expectEqual(&TestRom.rom.library, table[2].?);
    try testing.expect(table[3] == null);
    try testing.expectEqual(&TestRom.rom.device, FindResident(SysBase, "test.device").?);
    try testing.expect(FindResident(SysBase, "nope") == null);

    // Version 3 and up: none of them.
    try testing.expect(InitCode(SysBase, RTF_COLDSTART, 3) != null);
    try testing.expectEqual(@as(u32, 0), TestRom.plain_inits);

    // A failing resident stops InitCode.
    TestRom.plain_fails = true;
    try testing.expect(InitCode(SysBase, RTF_COLDSTART, 0) == null);
    try testing.expectEqual(@as(u32, 1), TestRom.plain_inits);
    try testing.expect(FindName(SysBase, &SysBase.device_list, "test.device") == null);

    // Cold start: plain runs first, then test.device is made and added.
    // test.library has no start class.
    TestRom.plain_fails = false;
    try testing.expect(InitCode(SysBase, RTF_COLDSTART, 0) != null);
    try testing.expectEqual(@as(u32, 2), TestRom.plain_inits);
    const dev: *Device = @fieldParentPtr("node", FindName(SysBase, &SysBase.device_list, "test.device").?);
    try testing.expectEqual(@as(u16, 2), dev.version);
    try testing.expectEqual(NodeType.device, dev.node.type);
    try testing.expectEqualStrings("test.device 2.0", std.mem.span(dev.id_string.?));
    try testing.expect(OpenLibrary(SysBase, "test.library", 0) == null);

    // InitResident on demand.
    const made = InitResident(SysBase, FindResident(SysBase, "test.library").?, null).?;
    const lib: *Library = @ptrCast(@alignCast(made));
    try testing.expectEqual(lib, OpenLibrary(SysBase, "test.library", 1).?);
    CloseLibrary(SysBase, lib);

    // A wrong match word is refused.
    var bad = TestRom.rom.library;
    bad.match_word = 0;
    try testing.expect(InitResident(SysBase, &bad, null) == null);

    // An RTF_AUTOINIT resident that fails in InitCode: dead-end alert.
    FakeAlert.install();
    defer FakeAlert.uninstall();
    TestRom.device_fails = true;
    try testing.expect(InitCode(SysBase, RTF_COLDSTART | RTF_AUTOINIT, 0) == null);
    try testing.expectEqual(@as(u32, 1), FakeAlert.count);
    try testing.expectEqual(AT_DeadEnd | AG_MakeLib, FakeAlert.last_num);
    try testing.expectEqual(@as(u32, 2), TestRom.plain_inits); // not RTF_AUTOINIT: skipped

    _ = RemDevice(SysBase, dev);
    _ = RemLibrary(SysBase, lib);
    _resident.deinitResidents(SysBase);
    try expectNoLeaks();
}

test "system start: ROM scan, single-task stage; the exec task runs cold start and ends" {
    try setUp();
    defer deinit();
    FakeTaskHardware.install();
    defer FakeTaskHardware.uninstall();

    TestRom.build();
    TestRom.rom.plain.flags = RTF_SINGLETASK;
    const first = SysBase.this_task;
    const start = @intFromPtr(&TestRom.rom);
    const info: BootInfo = .{ .rom_start = start, .rom_end = start + @sizeOf(@TypeOf(TestRom.rom)) };
    try exec_init.startSystem(SysBase, &info);

    // Single task: plain ran. Task switching stays off; the exec task waits.
    try testing.expectEqual(@as(u32, 1), TestRom.plain_inits);
    try testing.expect(SysBase.tdn_nest_cnt >= 0);
    const exec_task = FindTask(SysBase, "exec").?;
    try testing.expectEqual(TaskState.ready, exec_task.state);
    try testing.expectEqual(boot_ctx, exceptionExit(boot_ctx)); // Forbid
    try testing.expect(FindName(SysBase, &SysBase.device_list, "test.device") == null);

    // Permit: multitasking, the exec task runs first and starts cold start.
    Permit(SysBase);
    try testing.expectEqual(ctx(exec_task), exceptionExit(boot_ctx));
    exec_init.execTask(SysBase.iface());
    try testing.expect(FindName(SysBase, &SysBase.device_list, "test.device") != null);
    try testing.expectEqual(@as(u32, 1), TestRom.plain_inits); // not cold start

    // It returns and ends (taskEntry's RemTask); the first task goes on.
    RemTask(SysBase, null);
    try testing.expectEqual(boot_ctx, exceptionExit(ctx(exec_task)));
    try testing.expectEqual(first, SysBase.this_task);
    try testing.expect(FindTask(SysBase, "exec") == null);

    const dev: *Device = @fieldParentPtr("node", FindName(SysBase, &SysBase.device_list, "test.device").?);
    _ = RemDevice(SysBase, dev);
    _resident.deinitResidents(SysBase);
    try expectNoLeaks();
}

test "libraries are listed by priority" {
    try setUp();
    defer deinit();
    const low = CreateLibrary(SysBase, &.{ .name = "low.library", .pri = -10, .vectors = &test_vectors }).?;
    const high = CreateLibrary(SysBase, &.{ .name = "high.library", .pri = 10, .vectors = &test_vectors }).?;
    try testing.expectEqual(&high.node, SysBase.lib_list.first().?);
    try testing.expectEqual(&low.node, SysBase.lib_list.last().?);
    _ = RemLibrary(SysBase, low);
    _ = RemLibrary(SysBase, high);
    try expectNoLeaks();
}

/// tc_Switch and tc_Launch for the test below: who ran, how often, and
/// with which SysBase.
const SwitchHooks = struct {
    var switched: ?*Task = null;
    var launched: ?*Task = null;
    var switches: u32 = 0;
    var launches: u32 = 0;
    var sys_base: ?*interface.ExecBase = null;

    fn reset() void {
        switched = null;
        launched = null;
        switches = 0;
        launches = 0;
        sys_base = null;
    }
    fn onSwitch(task: *Task, sys: *interface.ExecBase) callconv(.c) void {
        std.debug.assert(task.sp_reg != null); // called after the save
        switched = task;
        switches += 1;
        sys_base = sys;
    }
    fn onLaunch(task: *Task, sys: *interface.ExecBase) callconv(.c) void {
        launched = task;
        launches += 1;
        sys_base = sys;
    }
};

/// Raw I/O for the test below: what RawPutChar sent, what RawMayGetChar
/// gets.
const TestRawIO = struct {
    var sent: [32]u8 = undefined;
    var sent_len: usize = 0;
    var input: []const u8 = "";
    var inits: u32 = 0;

    fn init() void {
        inits += 1;
    }
    fn put(c: u8) void {
        sent[sent_len] = c;
        sent_len += 1;
    }
    fn get() ?u8 {
        if (input.len == 0) return null;
        defer input = input[1..];
        return input[0];
    }
};

test "RawPutChar, RawMayGetChar and kprintf go to the kernel's raw I/O" {
    try setUp();
    defer deinit();
    raw_io_hardware.* = .{ .init = TestRawIO.init, .put = TestRawIO.put, .get = TestRawIO.get };
    defer raw_io_hardware.* = _rawio.no_raw_io;
    TestRawIO.sent_len = 0;
    TestRawIO.input = "z";

    const sys = SysBase.iface();
    sys.RawPutChar('A');
    try testing.expectEqual(@as(i32, 'z'), sys.RawMayGetChar());
    try testing.expectEqual(@as(i32, -1), sys.RawMayGetChar());
    sdk.exec.kprintf(sys, "k%d\n", .{@as(u32, 7)}); // "\n" as "\r\n", no final NUL
    try testing.expectEqualStrings("Ak7\r\n", TestRawIO.sent[0..TestRawIO.sent_len]);
    kprintf("[%s]", .{"kernel"}); // the kernel's own, without SysBase
    try testing.expectEqualStrings("Ak7\r\n[kernel]", TestRawIO.sent[0..TestRawIO.sent_len]);
    try expectNoLeaks();
}

test "RawIOInit: the raw port is silent until exec's init sets it up" {
    try setUp(); // initExec did RawIOInit, on no hardware
    defer deinit();
    raw_io_hardware.* = .{ .init = TestRawIO.init, .put = TestRawIO.put, .get = TestRawIO.get };
    defer raw_io_hardware.* = _rawio.no_raw_io;
    _rawio.raw_ready = false; // as at boot
    defer _rawio.raw_ready = true;
    TestRawIO.sent_len = 0;
    TestRawIO.inits = 0;
    TestRawIO.input = "q";

    RawPutChar(SysBase, 'x');
    kprintf("lost", .{});
    try testing.expectEqual(@as(i32, -1), RawMayGetChar(SysBase));
    try testing.expectEqual(@as(usize, 0), TestRawIO.sent_len);

    SysBase.iface().RawIOInit();
    try testing.expectEqual(@as(u32, 1), TestRawIO.inits);
    RawPutChar(SysBase, 'y');
    RawPutChar(SysBase, 0); // skipped
    try testing.expectEqual(@as(i32, 'q'), RawMayGetChar(SysBase));
    try testing.expectEqualStrings("y", TestRawIO.sent[0..TestRawIO.sent_len]);
    try expectNoLeaks();
}

/// A resource for the test below: one function, made by InitResident.
const TestResource = struct {
    fn ping(_: *Library) callconv(.c) u32 {
        return 42;
    }
    const vectors = [_]*const anyopaque{vec(ping)};
    const table = InitTable{ .data_size = @sizeOf(Library), .vectors = &vectors, .vector_count = vectors.len, .init = null };
    const tag: Resident = .{ .match_tag = &tag, .flags = RTF_AUTOINIT, .version = 1, .type = .resource, .name = "test.resource", .init = &table };
};

test "resources: AddResource, OpenResource, RemResource; InitResident adds NT_RESOURCE tags" {
    try setUp();
    defer deinit();
    var res: Library = .{ .node = .{ .name = "plain.resource" } };
    AddResource(SysBase, &res);
    try testing.expectEqual(NodeType.resource, res.node.type);
    try testing.expectEqual(@as(?*anyopaque, &res), OpenResource(SysBase, "plain.resource"));
    try testing.expectEqual(@as(?*anyopaque, &res), SysBase.iface().OpenResource("plain.resource"));
    try testing.expect(OpenResource(SysBase, "other.resource") == null);
    RemResource(SysBase, &res);
    try testing.expect(OpenResource(SysBase, "plain.resource") == null);

    const made: *Library = @ptrCast(@alignCast(InitResident(SysBase, &TestResource.tag, null).?));
    try testing.expectEqual(@as(?*anyopaque, made), OpenResource(SysBase, "test.resource"));
    try testing.expectEqual(NodeType.resource, made.node.type);
    // No standard vectors: its first function is in the first slot.
    try testing.expectEqual(@as(u32, 42), made.vector(*const fn (*Library) callconv(.c) u32, lvo(0))(made));
    RemResource(SysBase, made);
    _library.freeLibraryMemory(SysBase, made);
    try expectNoLeaks();
}

/// Records what the cache functions ask of the hardware.
const TestCache = struct {
    const Op = struct { op: u8, addr: usize = 0, size: usize = 0 };
    var ops: [16]Op = undefined;
    var n: usize = 0;

    fn log(op: u8, addr: usize, size: usize) void {
        ops[n] = .{ .op = op, .addr = addr, .size = size };
        n += 1;
    }
    fn writebackAll() void {
        log('W', 0, 0);
    }
    fn invalidateICacheAll() void {
        log('I', 0, 0);
    }
    fn writeback(addr: usize, size: usize) void {
        log('w', addr, size);
    }
    fn writebackLine(addr: usize) void {
        log('l', addr, 0);
    }
    fn invalidate(addr: usize, size: usize) void {
        log('i', addr, size);
    }
    const hardware: CacheHardware = .{
        .writeback_all = writebackAll,
        .invalidate_icache_all = invalidateICacheAll,
        .writeback = writeback,
        .writeback_line = writebackLine,
        .invalidate = invalidate,
    };

    /// The operations since the last call are `want`.
    fn expect(want: []const Op) !void {
        defer n = 0;
        try testing.expectEqual(want.len, n);
        for (want, ops[0..n]) |w, got| try testing.expectEqual(w, got);
    }
};

fn testAddress(addr: usize) *anyopaque {
    return @ptrFromInt(addr);
}

test "caches: CacheClearU, CacheClearE, CachePreDMA, CachePostDMA on the cached ranges" {
    try setUp();
    defer deinit();
    cache_hardware.* = TestCache.hardware;
    defer cache_hardware.* = _cache.no_cache;
    TestCache.n = 0;
    const sys = SysBase.iface();
    const both = sdk.exec.CACRF_ClearI | sdk.exec.CACRF_ClearD;

    sys.CacheClearU();
    try TestCache.expect(&.{ .{ .op = 'W' }, .{ .op = 'I' } });

    // Internal SRAM is not cached.
    sys.CacheClearE(testAddress(0x3FC9_0000), 64, both);
    var len: u32 = 64;
    _ = sys.CachePreDMA(testAddress(0x3FC9_0000), &len, 0);
    sys.CachePostDMA(testAddress(0x3FC9_0000), &len, 0);
    try TestCache.expect(&.{});

    // Whole lines: one range call; the DMA address and length stay.
    len = 0x100;
    try testing.expectEqual(testAddress(0x3C00_1000), sys.CachePreDMA(testAddress(0x3C00_1000), &len, 0));
    try testing.expectEqual(@as(u32, 0x100), len);
    try TestCache.expect(&.{.{ .op = 'w', .addr = 0x3C00_1000, .size = 0x100 }});

    // Lines only partly in the range: on their own, frozen.
    len = 0xC0;
    _ = sys.CachePreDMA(testAddress(0x3C00_1004), &len, 0);
    try TestCache.expect(&.{
        .{ .op = 'l', .addr = 0x3C00_1000 },
        .{ .op = 'l', .addr = 0x3C00_10C0 },
        .{ .op = 'w', .addr = 0x3C00_1040, .size = 0x80 },
    });
    len = 8;
    _ = sys.CachePreDMA(testAddress(0x3C00_1004), &len, 0);
    try TestCache.expect(&.{.{ .op = 'l', .addr = 0x3C00_1000 }});

    // After DMA into memory: invalidated, shared lines written back first
    // with interrupts off; nothing if the device only read.
    const nest = SysBase.id_nest_cnt;
    len = 0xC0;
    sys.CachePostDMA(testAddress(0x3C00_1004), &len, sdk.exec.DMAF_ReadFromRAM);
    sys.CachePostDMA(testAddress(0x3C00_1004), &len, sdk.exec.DMAF_NoModify);
    try TestCache.expect(&.{});
    sys.CachePostDMA(testAddress(0x3C00_1004), &len, 0);
    try TestCache.expect(&.{
        .{ .op = 'l', .addr = 0x3C00_1000 },
        .{ .op = 'i', .addr = 0x3C00_1000, .size = 0x40 },
        .{ .op = 'l', .addr = 0x3C00_10C0 },
        .{ .op = 'i', .addr = 0x3C00_10C0, .size = 0x40 },
        .{ .op = 'i', .addr = 0x3C00_1040, .size = 0x80 },
    });
    try testing.expectEqual(nest, SysBase.id_nest_cnt);

    // 4 MB per hardware call; the range ends with the data bus.
    len = 0x60_0000;
    _ = sys.CachePreDMA(testAddress(0x3C00_0000), &len, 0);
    len = 0x40;
    _ = sys.CachePreDMA(testAddress(0x3DFF_FFC0), &len, 0);
    try TestCache.expect(&.{
        .{ .op = 'w', .addr = 0x3C00_0000, .size = 0x40_0000 },
        .{ .op = 'w', .addr = 0x3C40_0000, .size = 0x20_0000 },
        .{ .op = 'w', .addr = 0x3DFF_FFC0, .size = 0x40 },
    });

    // CacheClearE: ClearD writes back and invalidates; ClearI invalidates
    // instruction-bus lines, or the whole ICache for a data-bus range;
    // 0xFFFFFFFF is all addresses.
    sys.CacheClearE(testAddress(0x3C00_2000), 0x40, sdk.exec.CACRF_ClearD);
    sys.CacheClearE(testAddress(0x4200_0010), 8, sdk.exec.CACRF_ClearI);
    sys.CacheClearE(testAddress(0x3C00_2000), 4, sdk.exec.CACRF_ClearI);
    sys.CacheClearE(testAddress(0x3C00_2000), 0xFFFF_FFFF, both);
    try TestCache.expect(&.{
        .{ .op = 'w', .addr = 0x3C00_2000, .size = 0x40 },
        .{ .op = 'i', .addr = 0x3C00_2000, .size = 0x40 },
        .{ .op = 'i', .addr = 0x4200_0000, .size = 0x40 },
        .{ .op = 'I' },
        .{ .op = 'W' },
        .{ .op = 'I' },
    });
}
