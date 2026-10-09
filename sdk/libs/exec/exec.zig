// SPDX-License-Identifier: MIT
//! exec's structures and constants (include/exec). The files follow the
//! headers, one each; everything is also here by name.

pub const nodes = @import("nodes.zig");
pub const lists = @import("lists.zig");
pub const libraries = @import("libraries.zig");
pub const memory = @import("memory.zig");
pub const interrupts = @import("interrupts.zig");
pub const tasks = @import("tasks.zig");
pub const ports = @import("ports.zig");
pub const semaphores = @import("semaphores.zig");
pub const locks = @import("locks.zig");
pub const devices = @import("devices.zig");
pub const resident = @import("resident.zig");
pub const alerts = @import("alerts.zig");
pub const fmt = @import("fmt.zig");
pub const log = @import("log.zig");
pub const cache = @import("cache.zig");

/// SysBase: exec.library's base, with its functions.
pub const ExecBase = @import("../../interface/exec.zig").ExecBase;

/// The one fixed address in the system: the word holding SysBase, written
/// once while exec is made and never again. Code that is handed SysBase
/// keeps what it was handed; this is for code that has no base to hand -
/// a panic handler, whose signature is Zig's. The word sits in internal
/// memory right below the chip ROM's reserved area: on the ESP32-S3 just
/// above the kernel's stack, on the ESP32-P4 at the top of the low part of
/// L2MEM.
pub const AbsExecBase: *const *ExecBase = @ptrFromInt(switch (@import("../../hardware/hardware.zig").chip) {
    .esp32s3 => 0x3FCE_9700,
    .esp32p4 => 0x4FF3_ABC0,
});

pub const NodeType = nodes.NodeType;
pub const Node = nodes.Node;
pub const MinNode = nodes.MinNode;
pub const List = lists.List;
pub const MinList = lists.MinList;

pub const Library = libraries.Library;
pub const LibraryInit = libraries.LibraryInit;
pub const InitFn = libraries.InitFn;
pub const OpenFn = libraries.OpenFn;
pub const CloseFn = libraries.CloseFn;
pub const ExpungeFn = libraries.ExpungeFn;
pub const ExtFuncFn = libraries.ExtFuncFn;
pub const lvo = libraries.lvo;
pub const vec = libraries.vec;
pub const slot_size = libraries.slot_size;
pub const libOpen = libraries.libOpen;
pub const libClose = libraries.libClose;
pub const libExtFunc = libraries.libExtFunc;
pub const LIB_OPEN = libraries.LIB_OPEN;
pub const LIB_CLOSE = libraries.LIB_CLOSE;
pub const LIB_EXPUNGE = libraries.LIB_EXPUNGE;
pub const LIB_EXTFUNC = libraries.LIB_EXTFUNC;
pub const LIB_USERDEF = libraries.LIB_USERDEF;
pub const LIBF_SUMMING = libraries.LIBF_SUMMING;
pub const LIBF_CHANGED = libraries.LIBF_CHANGED;
pub const LIBF_SUMUSED = libraries.LIBF_SUMUSED;
pub const LIBF_DELEXP = libraries.LIBF_DELEXP;
pub const LIBF_GOING = libraries.LIBF_GOING;

pub const MemChunk = memory.MemChunk;
pub const MemHeader = memory.MemHeader;
pub const MemHandlerData = memory.MemHandlerData;
pub const MemHandlerFn = memory.MemHandlerFn;
pub const MEM_BLOCKSIZE = memory.MEM_BLOCKSIZE;
pub const MEM_BLOCKMASK = memory.MEM_BLOCKMASK;
pub const MEMF_ANY = memory.MEMF_ANY;
pub const MEMF_INTERNAL = memory.MEMF_INTERNAL;
pub const MEMF_EXTERNAL = memory.MEMF_EXTERNAL;
pub const MEMF_DMA = memory.MEMF_DMA;
pub const MEMF_CLEAR = memory.MEMF_CLEAR;
pub const MEMF_LARGEST = memory.MEMF_LARGEST;
pub const MEMF_REVERSE = memory.MEMF_REVERSE;
pub const MEMF_TOTAL = memory.MEMF_TOTAL;
pub const MEMF_NO_EXPUNGE = memory.MEMF_NO_EXPUNGE;
pub const MEMHF_RECYCLE = memory.MEMHF_RECYCLE;
pub const MEM_DID_NOTHING = memory.MEM_DID_NOTHING;
pub const MEM_ALL_DONE = memory.MEM_ALL_DONE;
pub const MEM_TRY_AGAIN = memory.MEM_TRY_AGAIN;

pub const Interrupt = interrupts.Interrupt;
pub const IntVector = interrupts.IntVector;

/// Which of exec's own lists LockExecList is to hand back, with the lock
/// exec keeps it under taken, until UnlockExecList. They are exec's, so a
/// caller reads them and does not write into them. The list header itself
/// never moves.
pub const EXECLIST_MEMORY: u32 = 0;
pub const EXECLIST_LIBRARIES: u32 = 1;
pub const EXECLIST_DEVICES: u32 = 2;
pub const EXECLIST_RESOURCES: u32 = 3;
pub const EXECLIST_PORTS: u32 = 4;
pub const EXECLIST_SEMAPHORES: u32 = 5;
pub const EXECLIST_TASK_READY: u32 = 6;
pub const EXECLIST_TASK_WAIT: u32 = 7;
pub const EXECLIST_MEM_HANDLERS: u32 = 8;
pub const IntHandlerFn = interrupts.IntHandlerFn;
pub const IntServerFn = interrupts.IntServerFn;
pub const SoftIntFn = interrupts.SoftIntFn;

pub const Task = tasks.Task;
pub const TaskState = tasks.TaskState;
pub const TaskFn = tasks.TaskFn;
pub const TaskEndFn = tasks.TaskEndFn;
pub const TaskEndHook = tasks.TaskEndHook;
pub const StackFn = tasks.StackFn;
pub const ExceptFn = tasks.ExceptFn;
pub const TrapInfo = tasks.TrapInfo;
pub const TrapFn = tasks.TrapFn;
pub const TaskSwitchFn = tasks.TaskSwitchFn;
pub const TF_SWITCH = tasks.TF_SWITCH;
pub const TF_LAUNCH = tasks.TF_LAUNCH;
pub const TF_GUARDED = tasks.TF_GUARDED;
pub const TB_CORE0 = tasks.TB_CORE0;
pub const TB_CORE1 = tasks.TB_CORE1;
pub const TF_CORE0 = tasks.TF_CORE0;
pub const TF_CORE1 = tasks.TF_CORE1;
pub const CoreTimes = tasks.CoreTimes;
pub const SIGF_ABORT = tasks.SIGF_ABORT;
pub const SIGF_CHILD = tasks.SIGF_CHILD;
pub const SIGF_BLIT = tasks.SIGF_BLIT;
pub const SIGF_SINGLE = tasks.SIGF_SINGLE;
pub const SIGF_INTUITION = tasks.SIGF_INTUITION;
pub const SIGF_NET = tasks.SIGF_NET;
pub const SIGF_DOS = tasks.SIGF_DOS;
pub const SIGBREAKF_CTRL_C = tasks.SIGBREAKF_CTRL_C;
pub const SIGBREAKF_CTRL_D = tasks.SIGBREAKF_CTRL_D;
pub const SIGBREAKF_CTRL_E = tasks.SIGBREAKF_CTRL_E;
pub const SIGBREAKF_CTRL_F = tasks.SIGBREAKF_CTRL_F;

pub const Message = ports.Message;
pub const MsgPort = ports.MsgPort;
pub const PF_ACTION = ports.PF_ACTION;
pub const PA_SIGNAL = ports.PA_SIGNAL;
pub const PA_SOFTINT = ports.PA_SOFTINT;
pub const PA_IGNORE = ports.PA_IGNORE;

pub const SignalSemaphore = semaphores.SignalSemaphore;
pub const Lock = locks.Lock;
pub const LOCKF_INTERRUPT = locks.LOCKF_INTERRUPT;
pub const LOCKORDER_DRIVER = locks.LOCKORDER_DRIVER;
pub const LOCKORDER_SYSTEM = locks.LOCKORDER_SYSTEM;
pub const SemaphoreRequest = semaphores.SemaphoreRequest;
pub const SemaphoreMessage = semaphores.SemaphoreMessage;
pub const SM_EXCLUSIVE = semaphores.SM_EXCLUSIVE;
pub const SM_SHARED = semaphores.SM_SHARED;

pub const Device = devices.Device;
pub const Unit = devices.Unit;
pub const IORequest = devices.IORequest;
pub const IOStdReq = devices.IOStdReq;
pub const DevOpenFn = devices.DevOpenFn;
pub const DevCloseFn = devices.DevCloseFn;
pub const BeginIOFn = devices.BeginIOFn;
pub const AbortIOFn = devices.AbortIOFn;
pub const DEV_BEGINIO = devices.DEV_BEGINIO;
pub const DEV_ABORTIO = devices.DEV_ABORTIO;
pub const DEV_USERDEF = devices.DEV_USERDEF;
pub const IOF_QUICK = devices.IOF_QUICK;
pub const IOF_QUEUED = devices.IOF_QUEUED;
pub const IOF_CURRENT = devices.IOF_CURRENT;
pub const IOF_SERVICING = devices.IOF_SERVICING;
pub const IOF_DONE = devices.IOF_DONE;
pub const IOERR_OPENFAIL = devices.IOERR_OPENFAIL;
pub const IOERR_ABORTED = devices.IOERR_ABORTED;
pub const IOERR_NOCMD = devices.IOERR_NOCMD;
pub const IOERR_BADLENGTH = devices.IOERR_BADLENGTH;
pub const IOERR_BADADDRESS = devices.IOERR_BADADDRESS;
pub const IOERR_UNITBUSY = devices.IOERR_UNITBUSY;
pub const IOERR_SELFTEST = devices.IOERR_SELFTEST;
pub const IOERR_NOREPLYPORT = devices.IOERR_NOREPLYPORT;
pub const IOERR_ENDOFSTREAM = devices.IOERR_ENDOFSTREAM;
pub const CMD_INVALID = devices.CMD_INVALID;
pub const CMD_RESET = devices.CMD_RESET;
pub const CMD_READ = devices.CMD_READ;
pub const CMD_WRITE = devices.CMD_WRITE;
pub const CMD_UPDATE = devices.CMD_UPDATE;
pub const CMD_CLEAR = devices.CMD_CLEAR;
pub const CMD_STOP = devices.CMD_STOP;
pub const CMD_START = devices.CMD_START;
pub const CMD_FLUSH = devices.CMD_FLUSH;
pub const CMD_NONSTD = devices.CMD_NONSTD;
pub const UNITF_ACTIVE = devices.UNITF_ACTIVE;
pub const UNITF_INTASK = devices.UNITF_INTASK;

pub const Resident = resident.Resident;
pub const InitTable = resident.InitTable;
pub const ResidentInitFn = resident.ResidentInitFn;
pub const ResidentHandler = resident.ResidentHandler;
pub const RTC_MATCHWORD = resident.RTC_MATCHWORD;
pub const RTF_COLDSTART = resident.RTF_COLDSTART;
pub const RTF_SINGLETASK = resident.RTF_SINGLETASK;
pub const RTF_AFTERDOS = resident.RTF_AFTERDOS;
pub const RTF_AUTOINIT = resident.RTF_AUTOINIT;

pub const CACRF_ClearI = cache.CACRF_ClearI;
pub const CACRF_ClearD = cache.CACRF_ClearD;
pub const DMAF_Continue = cache.DMAF_Continue;
pub const DMAF_NoModify = cache.DMAF_NoModify;
pub const DMAF_ReadFromRAM = cache.DMAF_ReadFromRAM;

pub const PutChProc = fmt.PutChProc;
pub const fmtStream = fmt.fmtStream;
pub const checkFormat = fmt.checkFormat;
pub const kprintf = fmt.kprintf;
pub const klog = fmt.klog;

pub const LOG_ERROR = log.LOG_ERROR;
pub const LOG_WARNING = log.LOG_WARNING;
pub const LOG_INFO = log.LOG_INFO;
pub const LOG_DEBUG = log.LOG_DEBUG;
pub const LOGCTRL_LEVEL = log.LOGCTRL_LEVEL;
pub const LOGCTRL_MIRROR = log.LOGCTRL_MIRROR;
pub const LOGCTRL_USBPORT = log.LOGCTRL_USBPORT;
pub const LOGCTRL_ASK = log.LOGCTRL_ASK;

pub const AT_DeadEnd = alerts.AT_DeadEnd;
pub const AT_Recovery = alerts.AT_Recovery;
pub const ACPU_Base = alerts.ACPU_Base;
pub const AN_SemCorrupt = alerts.AN_SemCorrupt;
pub const AN_StackProbe = alerts.AN_StackProbe;
pub const AN_KernelPanic = alerts.AN_KernelPanic;
pub const AN_ProgramPanic = alerts.AN_ProgramPanic;
pub const AN_LockRule = alerts.AN_LockRule;
pub const AN_LockDeadlock = alerts.AN_LockDeadlock;
pub const panic = @import("panic.zig").panic;
pub const AG_MakeLib = alerts.AG_MakeLib;
