// SPDX-License-Identifier: MPL-2.0
//! dos.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's contract
//! - the signatures and the documented LVOs at compile time, the slots and
//! the forwarding in the tests at the end.
//!
//! Each wrapper is the slot a caller reaches through the table. It hands
//! the work to the call - a file of its own in the folder for its
//! category - with the library's base first.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const TagItem = sdk.utility.TagItem;
const MsgPort = exec.MsgPort;
const DosPacket = dos.DosPacket;
const Process = dos.Process;
const Segment = dos.Segment;
const FileLock = dos.FileLock;
const FileHandle = dos.FileHandle;
const DosList = dos.DosList;
const DevProc = dos.DevProc;
const vec = exec.vec;
const dos_base = @import("dos_base.zig");
const DosBase = dos_base.DosBase;

const DoPkt = @import("packet/dopkt.zig").DoPkt;
const SendPkt = @import("packet/sendpkt.zig").SendPkt;
const WaitPkt = @import("packet/waitpkt.zig").WaitPkt;
const ReplyPkt = @import("packet/replypkt.zig").ReplyPkt;
const AbortPkt = @import("packet/abortpkt.zig").AbortPkt;
const AllocDosObject = @import("packet/allocdosobject.zig").AllocDosObject;
const FreeDosObject = @import("packet/freedosobject.zig").FreeDosObject;
const IoErr = @import("process/ioerr.zig").IoErr;
const SetIoErr = @import("process/setioerr.zig").SetIoErr;
const CreateNewProc = @import("process/createnewproc.zig").CreateNewProc;
const LockDosList = @import("doslist/lockdoslist.zig").LockDosList;
const UnLockDosList = @import("doslist/unlockdoslist.zig").UnLockDosList;
const AttemptLockDosList = @import("doslist/attemptlockdoslist.zig").AttemptLockDosList;
const AddDosEntry = @import("doslist/adddosentry.zig").AddDosEntry;
const RemDosEntry = @import("doslist/remdosentry.zig").RemDosEntry;
const FindDosEntry = @import("doslist/finddosentry.zig").FindDosEntry;
const NextDosEntry = @import("doslist/nextdosentry.zig").NextDosEntry;
const MakeDosEntry = @import("doslist/makedosentry.zig").MakeDosEntry;
const FreeDosEntry = @import("doslist/freedosentry.zig").FreeDosEntry;
const GetDeviceProc = @import("doslist/getdeviceproc.zig").GetDeviceProc;
const FreeDeviceProc = @import("doslist/freedeviceproc.zig").FreeDeviceProc;
const AddPart = @import("text/addpart.zig").AddPart;
const FilePart = @import("text/filepart.zig").FilePart;
const PathPart = @import("text/pathpart.zig").PathPart;
const SplitName = @import("text/splitname.zig").SplitName;
const ParsePath = @import("text/parsepath.zig").ParsePath;
const AddSegment = @import("program/addsegment.zig").AddSegment;
const FindSegment = @import("program/findsegment.zig").FindSegment;
const RemSegment = @import("program/remsegment.zig").RemSegment;
const LockSegmentList = @import("program/locksegmentlist.zig").LockSegmentList;
const UnLockSegmentList = @import("program/unlocksegmentlist.zig").UnLockSegmentList;
const Lock = @import("lock/lock.zig").Lock;
const UnLock = @import("lock/unlock.zig").UnLock;
const DupLock = @import("lock/duplock.zig").DupLock;
const ParentDir = @import("lock/parentdir.zig").ParentDir;
const SameLock = @import("lock/samelock.zig").SameLock;
const CurrentDir = @import("lock/currentdir.zig").CurrentDir;
const CreateDir = @import("lock/createdir.zig").CreateDir;
const DeleteFile = @import("lock/deletefile.zig").DeleteFile;
const DateStamp = @import("date/datestamp.zig").DateStamp;
const CompareDates = @import("date/comparedates.zig").CompareDates;
const DateToStr = @import("date/datetostr.zig").DateToStr;
const StrToDate = @import("date/strtodate.zig").StrToDate;
const Open = @import("file/open.zig").Open;
const Close = @import("file/close.zig").Close;
const Read = @import("file/read.zig").Read;
const Write = @import("file/write.zig").Write;
const Seek = @import("file/seek.zig").Seek;
const Input = @import("file/input.zig").Input;
const Output = @import("file/output.zig").Output;
const SelectInput = @import("file/selectinput.zig").SelectInput;
const SelectOutput = @import("file/selectoutput.zig").SelectOutput;
const IsInteractive = @import("file/isinteractive.zig").IsInteractive;
const Examine = @import("lock/examine.zig").Examine;
const ExNext = @import("lock/exnext.zig").ExNext;
const ExamineFH = @import("lock/examinefh.zig").ExamineFH;
const ExAll = @import("lock/exall.zig").ExAll;
const ExAllEnd = @import("lock/exallend.zig").ExAllEnd;
const Cli = @import("process/cli.zig").Cli;
const SelectError = @import("process/selecterror.zig").SelectError;
const ErrorOutput = @import("process/erroroutput.zig").ErrorOutput;
const GetConsoleTask = @import("process/getconsoletask.zig").GetConsoleTask;
const SetConsoleTask = @import("process/setconsoletask.zig").SetConsoleTask;
const GetFileSysTask = @import("process/getfilesystask.zig").GetFileSysTask;
const SetFileSysTask = @import("process/setfilesystask.zig").SetFileSysTask;
const GetProgramDir = @import("process/getprogramdir.zig").GetProgramDir;
const SetProgramDir = @import("process/setprogramdir.zig").SetProgramDir;
const SetProgramName = @import("process/setprogramname.zig").SetProgramName;
const GetProgramName = @import("process/getprogramname.zig").GetProgramName;
const SetPrompt = @import("process/setprompt.zig").SetPrompt;
const GetPrompt = @import("process/getprompt.zig").GetPrompt;
const SetCurrentDirName = @import("process/setcurrentdirname.zig").SetCurrentDirName;
const GetCurrentDirName = @import("process/getcurrentdirname.zig").GetCurrentDirName;
const NameFromLock = @import("process/namefromlock.zig").NameFromLock;
const AssignLock = @import("doslist/assignlock.zig").AssignLock;
const AssignLate = @import("doslist/assignlate.zig").AssignLate;
const AssignPath = @import("doslist/assignpath.zig").AssignPath;
const AssignAdd = @import("doslist/assignadd.zig").AssignAdd;
const RemAssignList = @import("doslist/remassignlist.zig").RemAssignList;
const MatchFirst = @import("lock/matchfirst.zig").MatchFirst;
const MatchNext = @import("lock/matchnext.zig").MatchNext;
const MatchEnd = @import("lock/matchend.zig").MatchEnd;
const Rename = @import("lock/rename.zig").Rename;
const SetProtection = @import("lock/setprotection.zig").SetProtection;
const SetComment = @import("lock/setcomment.zig").SetComment;
const SetFileDate = @import("lock/setfiledate.zig").SetFileDate;
const SetOwner = @import("lock/setowner.zig").SetOwner;
const SetFileSize = @import("file/setfilesize.zig").SetFileSize;
const DupLockFromFH = @import("file/duplockfromfh.zig").DupLockFromFH;
const ParentOfFH = @import("file/parentoffh.zig").ParentOfFH;
const NameFromFH = @import("process/namefromfh.zig").NameFromFH;
const OpenFromLock = @import("file/openfromlock.zig").OpenFromLock;
const ChangeMode = @import("lock/changemode.zig").ChangeMode;
const Info = @import("lock/info.zig").Info;
const IsFileSystem = @import("lock/isfilesystem.zig").IsFileSystem;
const SameDevice = @import("lock/samedevice.zig").SameDevice;
const Flush = @import("file/flush.zig").Flush;
const FGetC = @import("file/fgetc.zig").FGetC;
const UnGetC = @import("file/ungetc.zig").UnGetC;
const FPutC = @import("file/fputc.zig").FPutC;
const FRead = @import("file/fread.zig").FRead;
const FWrite = @import("file/fwrite.zig").FWrite;
const FGets = @import("file/fgets.zig").FGets;
const FPuts = @import("file/fputs.zig").FPuts;
const SetVBuf = @import("file/setvbuf.zig").SetVBuf;
const VFPrintf = @import("file/vfprintf.zig").VFPrintf;
const VPrintf = @import("file/vprintf.zig").VPrintf;
const PutStr = @import("file/putstr.zig").PutStr;
const WriteChars = @import("file/writechars.zig").WriteChars;
const ReadArgs = @import("text/readargs.zig").ReadArgs;
const FreeArgs = @import("text/freeargs.zig").FreeArgs;
const ReadItem = @import("text/readitem.zig").ReadItem;
const FindArg = @import("text/findarg.zig").FindArg;
const StrToLong = @import("text/strtolong.zig").StrToLong;
const SetMode = @import("file/setmode.zig").SetMode;
const WaitForChar = @import("file/waitforchar.zig").WaitForChar;
const Fault = @import("text/fault.zig").Fault;
const PrintFault = @import("text/printfault.zig").PrintFault;
const SetVar = @import("process/setvar.zig").SetVar;
const GetVar = @import("process/getvar.zig").GetVar;
const DeleteVar = @import("process/deletevar.zig").DeleteVar;
const FindVar = @import("process/findvar.zig").FindVar;
const CheckSignal = @import("process/checksignal.zig").CheckSignal;
const Delay = @import("date/delay.zig").Delay;
const GetArgStr = @import("process/getargstr.zig").GetArgStr;
const SetArgStr = @import("process/setargstr.zig").SetArgStr;
const MaxCli = @import("process/maxcli.zig").MaxCli;
const FindCliProc = @import("process/findcliproc.zig").FindCliProc;
const RunCommand = @import("program/runcommand.zig").RunCommand;
const SystemTagList = @import("program/systemtaglist.zig").SystemTagList;
const Execute = @import("program/execute.zig").Execute;
const LoadSeg = @import("program/loadseg.zig").LoadSeg;
const UnLoadSeg = @import("program/unloadseg.zig").UnLoadSeg;

/// dos.library's interface, as the SDK generates it from sdk/fd/dos_lib.fd.
const interface = sdk.interface.dos;
const LVO = interface.LVO;

// Every function in LVO is an lvo* function here, with the SDK's signature
// (after the base), in its slot.
comptime {
    @setEvalBranchQuota(20_000);
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("dos.library's lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
        }
        if (vectors[@divExact(-@field(LVO, d.name), exec.slot_size) - 1] != vec(f)) {
            @compileError("dos.library's lvo" ++ d.name ++ " isn't in the slot of LVO." ++ d.name);
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(50_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "dos.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`: every
/// call of the table.
const contract_files = [_][]const u8{
    @embedFile("packet/dopkt.zig"),
    @embedFile("packet/sendpkt.zig"),
    @embedFile("packet/waitpkt.zig"),
    @embedFile("packet/replypkt.zig"),
    @embedFile("packet/abortpkt.zig"),
    @embedFile("packet/allocdosobject.zig"),
    @embedFile("packet/freedosobject.zig"),
    @embedFile("process/ioerr.zig"),
    @embedFile("process/setioerr.zig"),
    @embedFile("process/createnewproc.zig"),
    @embedFile("doslist/lockdoslist.zig"),
    @embedFile("doslist/unlockdoslist.zig"),
    @embedFile("doslist/attemptlockdoslist.zig"),
    @embedFile("doslist/adddosentry.zig"),
    @embedFile("doslist/remdosentry.zig"),
    @embedFile("doslist/finddosentry.zig"),
    @embedFile("doslist/nextdosentry.zig"),
    @embedFile("doslist/makedosentry.zig"),
    @embedFile("doslist/freedosentry.zig"),
    @embedFile("doslist/getdeviceproc.zig"),
    @embedFile("doslist/freedeviceproc.zig"),
    @embedFile("text/addpart.zig"),
    @embedFile("text/filepart.zig"),
    @embedFile("text/pathpart.zig"),
    @embedFile("text/splitname.zig"),
    @embedFile("text/parsepath.zig"),
    @embedFile("program/addsegment.zig"),
    @embedFile("program/findsegment.zig"),
    @embedFile("program/remsegment.zig"),
    @embedFile("program/locksegmentlist.zig"),
    @embedFile("program/unlocksegmentlist.zig"),
    @embedFile("lock/lock.zig"),
    @embedFile("lock/unlock.zig"),
    @embedFile("lock/duplock.zig"),
    @embedFile("lock/parentdir.zig"),
    @embedFile("lock/samelock.zig"),
    @embedFile("lock/currentdir.zig"),
    @embedFile("lock/createdir.zig"),
    @embedFile("lock/deletefile.zig"),
    @embedFile("date/datestamp.zig"),
    @embedFile("date/comparedates.zig"),
    @embedFile("date/datetostr.zig"),
    @embedFile("date/strtodate.zig"),
    @embedFile("file/open.zig"),
    @embedFile("file/close.zig"),
    @embedFile("file/read.zig"),
    @embedFile("file/write.zig"),
    @embedFile("file/seek.zig"),
    @embedFile("file/input.zig"),
    @embedFile("file/output.zig"),
    @embedFile("file/selectinput.zig"),
    @embedFile("file/selectoutput.zig"),
    @embedFile("file/isinteractive.zig"),
    @embedFile("lock/examine.zig"),
    @embedFile("lock/exnext.zig"),
    @embedFile("lock/examinefh.zig"),
    @embedFile("lock/exall.zig"),
    @embedFile("lock/exallend.zig"),
    @embedFile("process/cli.zig"),
    @embedFile("process/selecterror.zig"),
    @embedFile("process/erroroutput.zig"),
    @embedFile("process/getconsoletask.zig"),
    @embedFile("process/setconsoletask.zig"),
    @embedFile("process/getfilesystask.zig"),
    @embedFile("process/setfilesystask.zig"),
    @embedFile("process/getprogramdir.zig"),
    @embedFile("process/setprogramdir.zig"),
    @embedFile("process/setprogramname.zig"),
    @embedFile("process/getprogramname.zig"),
    @embedFile("process/setprompt.zig"),
    @embedFile("process/getprompt.zig"),
    @embedFile("process/setcurrentdirname.zig"),
    @embedFile("process/getcurrentdirname.zig"),
    @embedFile("process/namefromlock.zig"),
    @embedFile("doslist/assignlock.zig"),
    @embedFile("doslist/assignlate.zig"),
    @embedFile("doslist/assignpath.zig"),
    @embedFile("doslist/assignadd.zig"),
    @embedFile("doslist/remassignlist.zig"),
    @embedFile("lock/matchfirst.zig"),
    @embedFile("lock/matchnext.zig"),
    @embedFile("lock/matchend.zig"),
    @embedFile("lock/rename.zig"),
    @embedFile("lock/setprotection.zig"),
    @embedFile("lock/setcomment.zig"),
    @embedFile("lock/setfiledate.zig"),
    @embedFile("lock/setowner.zig"),
    @embedFile("file/setfilesize.zig"),
    @embedFile("file/duplockfromfh.zig"),
    @embedFile("file/parentoffh.zig"),
    @embedFile("process/namefromfh.zig"),
    @embedFile("file/openfromlock.zig"),
    @embedFile("lock/changemode.zig"),
    @embedFile("lock/info.zig"),
    @embedFile("lock/isfilesystem.zig"),
    @embedFile("lock/samedevice.zig"),
    @embedFile("file/flush.zig"),
    @embedFile("file/fgetc.zig"),
    @embedFile("file/ungetc.zig"),
    @embedFile("file/fputc.zig"),
    @embedFile("file/fread.zig"),
    @embedFile("file/fwrite.zig"),
    @embedFile("file/fgets.zig"),
    @embedFile("file/fputs.zig"),
    @embedFile("file/setvbuf.zig"),
    @embedFile("file/vfprintf.zig"),
    @embedFile("file/vprintf.zig"),
    @embedFile("file/putstr.zig"),
    @embedFile("file/writechars.zig"),
    @embedFile("text/readargs.zig"),
    @embedFile("text/freeargs.zig"),
    @embedFile("text/readitem.zig"),
    @embedFile("text/findarg.zig"),
    @embedFile("text/strtolong.zig"),
    @embedFile("file/setmode.zig"),
    @embedFile("file/waitforchar.zig"),
    @embedFile("text/fault.zig"),
    @embedFile("text/printfault.zig"),
    @embedFile("process/setvar.zig"),
    @embedFile("process/getvar.zig"),
    @embedFile("process/deletevar.zig"),
    @embedFile("process/findvar.zig"),
    @embedFile("process/checksignal.zig"),
    @embedFile("date/delay.zig"),
    @embedFile("process/getargstr.zig"),
    @embedFile("process/setargstr.zig"),
    @embedFile("process/maxcli.zig"),
    @embedFile("process/findcliproc.zig"),
    @embedFile("program/runcommand.zig"),
    @embedFile("program/systemtaglist.zig"),
    @embedFile("program/execute.zig"),
    @embedFile("program/loadseg.zig"),
    @embedFile("program/unloadseg.zig"),
};

fn lvoDoPkt(db: *DosBase, port: *MsgPort, action: i32, arg1: isize, arg2: isize, arg3: isize, arg4: isize, arg5: isize) callconv(.c) isize {
    return DoPkt(db, port, action, arg1, arg2, arg3, arg4, arg5);
}
fn lvoSendPkt(db: *DosBase, packet: *DosPacket, port: *MsgPort, reply_port: *MsgPort) callconv(.c) void {
    SendPkt(db, packet, port, reply_port);
}
fn lvoWaitPkt(db: *DosBase) callconv(.c) ?*DosPacket {
    return WaitPkt(db);
}
fn lvoReplyPkt(db: *DosBase, packet: ?*DosPacket, res1: isize, res2: i32) callconv(.c) void {
    ReplyPkt(db, packet, res1, res2);
}
fn lvoAbortPkt(db: *DosBase, port: *MsgPort, packet: *DosPacket) callconv(.c) void {
    AbortPkt(db, port, packet);
}
fn lvoAllocDosObject(db: *DosBase, obj_type: u32, tags: ?[*]const TagItem) callconv(.c) ?*anyopaque {
    return AllocDosObject(db, obj_type, tags);
}
fn lvoFreeDosObject(db: *DosBase, obj_type: u32, ptr: ?*anyopaque) callconv(.c) void {
    FreeDosObject(db, obj_type, ptr);
}
fn lvoIoErr(db: *DosBase) callconv(.c) i32 {
    return IoErr(db);
}
fn lvoSetIoErr(db: *DosBase, code: i32) callconv(.c) i32 {
    return SetIoErr(db, code);
}
fn lvoCreateNewProc(db: *DosBase, tags: ?[*]const TagItem) callconv(.c) ?*Process {
    return CreateNewProc(db, tags);
}
fn lvoLockDosList(db: *DosBase, flags: u32) callconv(.c) ?*DosList {
    return LockDosList(db, flags);
}
fn lvoUnLockDosList(db: *DosBase, flags: u32) callconv(.c) void {
    UnLockDosList(db, flags);
}
fn lvoAttemptLockDosList(db: *DosBase, flags: u32) callconv(.c) ?*DosList {
    return AttemptLockDosList(db, flags);
}
fn lvoAddDosEntry(db: *DosBase, dlist: *DosList) callconv(.c) bool {
    return AddDosEntry(db, dlist);
}
fn lvoRemDosEntry(db: *DosBase, dlist: *DosList) callconv(.c) bool {
    return RemDosEntry(db, dlist);
}
fn lvoFindDosEntry(db: *DosBase, dlist: *DosList, name: ?[*:0]const u8, flags: u32) callconv(.c) ?*DosList {
    return FindDosEntry(db, dlist, name, flags);
}
fn lvoNextDosEntry(db: *DosBase, dlist: *DosList, flags: u32) callconv(.c) ?*DosList {
    return NextDosEntry(db, dlist, flags);
}
fn lvoMakeDosEntry(db: *DosBase, name: [*:0]const u8, dlt: i32) callconv(.c) ?*DosList {
    return MakeDosEntry(db, name, dlt);
}
fn lvoFreeDosEntry(db: *DosBase, dlist: ?*DosList) callconv(.c) void {
    FreeDosEntry(db, dlist);
}
fn lvoGetDeviceProc(db: *DosBase, name: [*:0]const u8, olddp: ?*DevProc) callconv(.c) ?*DevProc {
    return GetDeviceProc(db, name, olddp);
}
fn lvoFreeDeviceProc(db: *DosBase, dp: ?*DevProc) callconv(.c) void {
    FreeDeviceProc(db, dp);
}
fn lvoAddPart(db: *DosBase, dirname: [*:0]u8, filename: [*:0]const u8, size: u32) callconv(.c) bool {
    return AddPart(db, dirname, filename, size);
}
fn lvoFilePart(db: *DosBase, name: [*:0]const u8) callconv(.c) [*:0]const u8 {
    return FilePart(db, name);
}
fn lvoPathPart(db: *DosBase, name: [*:0]const u8) callconv(.c) [*:0]const u8 {
    return PathPart(db, name);
}
fn lvoSplitName(db: *DosBase, name: [*:0]const u8, separator: u8, buf: [*]u8, oldpos: i32, size: u32) callconv(.c) i32 {
    return SplitName(db, name, separator, buf, oldpos, size);
}
fn lvoParsePath(db: *DosBase, name: [*:0]const u8, parsed: *dos.ParsedPath) callconv(.c) bool {
    return ParsePath(db, name, parsed);
}
fn lvoAddSegment(db: *DosBase, name: [*:0]const u8, code: ?*const dos.SegCode, seg_type: i32) callconv(.c) bool {
    return AddSegment(db, name, code, seg_type);
}
fn lvoFindSegment(db: *DosBase, name: [*:0]const u8, start: ?*Segment, system: bool) callconv(.c) ?*Segment {
    return FindSegment(db, name, start, system);
}
fn lvoRemSegment(db: *DosBase, seg: *Segment) callconv(.c) bool {
    return RemSegment(db, seg);
}
fn lvoLockSegmentList(db: *DosBase, shared: bool) callconv(.c) ?*Segment {
    return LockSegmentList(db, shared);
}
fn lvoUnLockSegmentList(db: *DosBase) callconv(.c) void {
    UnLockSegmentList(db);
}
fn lvoLock(db: *DosBase, name: [*:0]const u8, mode: i32) callconv(.c) ?*FileLock {
    return Lock(db, name, mode);
}
fn lvoUnLock(db: *DosBase, lock: ?*FileLock) callconv(.c) void {
    UnLock(db, lock);
}
fn lvoDupLock(db: *DosBase, lock: ?*FileLock) callconv(.c) ?*FileLock {
    return DupLock(db, lock);
}
fn lvoParentDir(db: *DosBase, lock: ?*FileLock) callconv(.c) ?*FileLock {
    return ParentDir(db, lock);
}
fn lvoSameLock(db: *DosBase, lock1: ?*FileLock, lock2: ?*FileLock) callconv(.c) i32 {
    return SameLock(db, lock1, lock2);
}
fn lvoCurrentDir(db: *DosBase, lock: ?*FileLock) callconv(.c) ?*FileLock {
    return CurrentDir(db, lock);
}
fn lvoCreateDir(db: *DosBase, name: [*:0]const u8) callconv(.c) ?*FileLock {
    return CreateDir(db, name);
}
fn lvoDeleteFile(db: *DosBase, name: [*:0]const u8) callconv(.c) bool {
    return DeleteFile(db, name);
}
fn lvoDateStamp(db: *DosBase, date: *dos.DateStamp) callconv(.c) *dos.DateStamp {
    return DateStamp(db, date);
}
fn lvoCompareDates(db: *DosBase, date1: *const dos.DateStamp, date2: *const dos.DateStamp) callconv(.c) i32 {
    return CompareDates(db, date1, date2);
}
fn lvoDateToStr(db: *DosBase, datetime: *dos.DateTime) callconv(.c) bool {
    return DateToStr(db, datetime);
}
fn lvoStrToDate(db: *DosBase, datetime: *dos.DateTime) callconv(.c) bool {
    return StrToDate(db, datetime);
}
fn lvoOpen(db: *DosBase, name: [*:0]const u8, mode: i32) callconv(.c) ?*FileHandle {
    return Open(db, name, mode);
}
fn lvoClose(db: *DosBase, file: ?*FileHandle) callconv(.c) bool {
    return Close(db, file);
}
fn lvoRead(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, length: isize) callconv(.c) isize {
    return Read(db, file, buffer, length);
}
fn lvoWrite(db: *DosBase, file: ?*FileHandle, buffer: [*]const u8, length: isize) callconv(.c) isize {
    return Write(db, file, buffer, length);
}
fn lvoSeek(db: *DosBase, file: ?*FileHandle, position: isize, mode: i32) callconv(.c) isize {
    return Seek(db, file, position, mode);
}
fn lvoInput(db: *DosBase) callconv(.c) ?*FileHandle {
    return Input(db);
}
fn lvoOutput(db: *DosBase) callconv(.c) ?*FileHandle {
    return Output(db);
}
fn lvoSelectInput(db: *DosBase, file: ?*FileHandle) callconv(.c) ?*FileHandle {
    return SelectInput(db, file);
}
fn lvoSelectOutput(db: *DosBase, file: ?*FileHandle) callconv(.c) ?*FileHandle {
    return SelectOutput(db, file);
}
fn lvoIsInteractive(db: *DosBase, file: ?*FileHandle) callconv(.c) bool {
    return IsInteractive(db, file);
}
fn lvoExamine(db: *DosBase, lock: ?*FileLock, fib: *dos.FileInfoBlock) callconv(.c) bool {
    return Examine(db, lock, fib);
}
fn lvoExNext(db: *DosBase, lock: ?*FileLock, fib: *dos.FileInfoBlock) callconv(.c) bool {
    return ExNext(db, lock, fib);
}
fn lvoExamineFH(db: *DosBase, file: ?*FileHandle, fib: *dos.FileInfoBlock) callconv(.c) bool {
    return ExamineFH(db, file, fib);
}
fn lvoExAll(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: isize, data_type: i32, control: *dos.ExAllControl) callconv(.c) bool {
    return ExAll(db, lock, buffer, size, data_type, control);
}
fn lvoExAllEnd(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: isize, data_type: i32, control: *dos.ExAllControl) callconv(.c) void {
    ExAllEnd(db, lock, buffer, size, data_type, control);
}
fn lvoCli(db: *DosBase) callconv(.c) ?*dos.CommandLineInterface {
    return Cli(db);
}
fn lvoSelectError(db: *DosBase, file: ?*FileHandle) callconv(.c) ?*FileHandle {
    return SelectError(db, file);
}
fn lvoErrorOutput(db: *DosBase) callconv(.c) ?*FileHandle {
    return ErrorOutput(db);
}
fn lvoGetConsoleTask(db: *DosBase) callconv(.c) ?*MsgPort {
    return GetConsoleTask(db);
}
fn lvoSetConsoleTask(db: *DosBase, port: ?*MsgPort) callconv(.c) ?*MsgPort {
    return SetConsoleTask(db, port);
}
fn lvoGetFileSysTask(db: *DosBase) callconv(.c) ?*MsgPort {
    return GetFileSysTask(db);
}
fn lvoSetFileSysTask(db: *DosBase, port: ?*MsgPort) callconv(.c) ?*MsgPort {
    return SetFileSysTask(db, port);
}
fn lvoGetProgramDir(db: *DosBase) callconv(.c) ?*FileLock {
    return GetProgramDir(db);
}
fn lvoSetProgramDir(db: *DosBase, lock: ?*FileLock) callconv(.c) ?*FileLock {
    return SetProgramDir(db, lock);
}
fn lvoSetProgramName(db: *DosBase, name: [*:0]const u8) callconv(.c) bool {
    return SetProgramName(db, name);
}
fn lvoGetProgramName(db: *DosBase, buffer: [*]u8, size: u32) callconv(.c) bool {
    return GetProgramName(db, buffer, size);
}
fn lvoSetPrompt(db: *DosBase, name: [*:0]const u8) callconv(.c) bool {
    return SetPrompt(db, name);
}
fn lvoGetPrompt(db: *DosBase, buffer: [*]u8, size: u32) callconv(.c) bool {
    return GetPrompt(db, buffer, size);
}
fn lvoSetCurrentDirName(db: *DosBase, name: [*:0]const u8) callconv(.c) bool {
    return SetCurrentDirName(db, name);
}
fn lvoGetCurrentDirName(db: *DosBase, buffer: [*]u8, size: u32) callconv(.c) bool {
    return GetCurrentDirName(db, buffer, size);
}
fn lvoNameFromLock(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: u32) callconv(.c) bool {
    return NameFromLock(db, lock, buffer, size);
}
fn lvoAssignLock(db: *DosBase, name: [*:0]const u8, lock: ?*FileLock) callconv(.c) bool {
    return AssignLock(db, name, lock);
}
fn lvoAssignLate(db: *DosBase, name: [*:0]const u8, path: [*:0]const u8) callconv(.c) bool {
    return AssignLate(db, name, path);
}
fn lvoAssignPath(db: *DosBase, name: [*:0]const u8, path: [*:0]const u8) callconv(.c) bool {
    return AssignPath(db, name, path);
}
fn lvoAssignAdd(db: *DosBase, name: [*:0]const u8, lock: *FileLock) callconv(.c) bool {
    return AssignAdd(db, name, lock);
}
fn lvoRemAssignList(db: *DosBase, name: [*:0]const u8, lock: *FileLock) callconv(.c) bool {
    return RemAssignList(db, name, lock);
}
fn lvoMatchFirst(db: *DosBase, pattern: [*:0]const u8, anchor: *dos.AnchorPath) callconv(.c) i32 {
    return MatchFirst(db, pattern, anchor);
}
fn lvoMatchNext(db: *DosBase, anchor: *dos.AnchorPath) callconv(.c) i32 {
    return MatchNext(db, anchor);
}
fn lvoMatchEnd(db: *DosBase, anchor: *dos.AnchorPath) callconv(.c) void {
    MatchEnd(db, anchor);
}
fn lvoRename(db: *DosBase, from: [*:0]const u8, to: [*:0]const u8) callconv(.c) bool {
    return Rename(db, from, to);
}
fn lvoSetProtection(db: *DosBase, name: [*:0]const u8, bits: u32) callconv(.c) bool {
    return SetProtection(db, name, bits);
}
fn lvoSetComment(db: *DosBase, name: [*:0]const u8, comment: [*:0]const u8) callconv(.c) bool {
    return SetComment(db, name, comment);
}
fn lvoSetFileDate(db: *DosBase, name: [*:0]const u8, date: *const dos.DateStamp) callconv(.c) bool {
    return SetFileDate(db, name, date);
}
fn lvoSetOwner(db: *DosBase, name: [*:0]const u8, owner_info: u32) callconv(.c) bool {
    return SetOwner(db, name, owner_info);
}
fn lvoSetFileSize(db: *DosBase, file: ?*FileHandle, offset: isize, mode: i32) callconv(.c) isize {
    return SetFileSize(db, file, offset, mode);
}
fn lvoDupLockFromFH(db: *DosBase, file: ?*FileHandle) callconv(.c) ?*FileLock {
    return DupLockFromFH(db, file);
}
fn lvoParentOfFH(db: *DosBase, file: ?*FileHandle) callconv(.c) ?*FileLock {
    return ParentOfFH(db, file);
}
fn lvoNameFromFH(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, size: u32) callconv(.c) bool {
    return NameFromFH(db, file, buffer, size);
}
fn lvoOpenFromLock(db: *DosBase, lock: ?*FileLock) callconv(.c) ?*FileHandle {
    return OpenFromLock(db, lock);
}
fn lvoChangeMode(db: *DosBase, kind: i32, object: ?*anyopaque, mode: i32) callconv(.c) bool {
    return ChangeMode(db, kind, object, mode);
}
fn lvoInfo(db: *DosBase, lock: ?*FileLock, data: *dos.InfoData) callconv(.c) bool {
    return Info(db, lock, data);
}
fn lvoIsFileSystem(db: *DosBase, name: [*:0]const u8) callconv(.c) bool {
    return IsFileSystem(db, name);
}
fn lvoSameDevice(db: *DosBase, lock1: ?*FileLock, lock2: ?*FileLock) callconv(.c) bool {
    return SameDevice(db, lock1, lock2);
}
fn lvoFlush(db: *DosBase, file: ?*FileHandle) callconv(.c) bool {
    return Flush(db, file);
}
fn lvoFGetC(db: *DosBase, file: ?*FileHandle) callconv(.c) i32 {
    return FGetC(db, file);
}
fn lvoUnGetC(db: *DosBase, file: ?*FileHandle, character: i32) callconv(.c) bool {
    return UnGetC(db, file, character);
}
fn lvoFPutC(db: *DosBase, file: ?*FileHandle, character: i32) callconv(.c) i32 {
    return FPutC(db, file, character);
}
fn lvoFRead(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, length: isize) callconv(.c) isize {
    return FRead(db, file, buffer, length);
}
fn lvoFWrite(db: *DosBase, file: ?*FileHandle, buffer: [*]const u8, length: isize) callconv(.c) isize {
    return FWrite(db, file, buffer, length);
}
fn lvoFGets(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, size: u32) callconv(.c) ?[*]u8 {
    return FGets(db, file, buffer, size);
}
fn lvoFPuts(db: *DosBase, file: ?*FileHandle, string: [*:0]const u8) callconv(.c) i32 {
    return FPuts(db, file, string);
}
fn lvoSetVBuf(db: *DosBase, file: ?*FileHandle, buffer: ?[*]u8, mode: i32, size: isize) callconv(.c) i32 {
    return SetVBuf(db, file, buffer, mode, size);
}
fn lvoVFPrintf(db: *DosBase, file: ?*FileHandle, format: [*:0]const u8, args: ?*const anyopaque) callconv(.c) i32 {
    return VFPrintf(db, file, format, args);
}
fn lvoVPrintf(db: *DosBase, format: [*:0]const u8, args: ?*const anyopaque) callconv(.c) i32 {
    return VPrintf(db, format, args);
}
fn lvoPutStr(db: *DosBase, string: [*:0]const u8) callconv(.c) i32 {
    return PutStr(db, string);
}
fn lvoWriteChars(db: *DosBase, buffer: [*]const u8, length: isize) callconv(.c) isize {
    return WriteChars(db, buffer, length);
}
fn lvoReadArgs(db: *DosBase, template: [*:0]const u8, argv: [*]usize, rdargs: ?*dos.RDArgs) callconv(.c) ?*dos.RDArgs {
    return ReadArgs(db, template, argv, rdargs);
}
fn lvoFreeArgs(db: *DosBase, rdargs: ?*dos.RDArgs) callconv(.c) void {
    FreeArgs(db, rdargs);
}
fn lvoReadItem(db: *DosBase, buffer: [*]u8, maxchars: i32, csource: ?*dos.CSource) callconv(.c) i32 {
    return ReadItem(db, buffer, maxchars, csource);
}
fn lvoFindArg(db: *DosBase, template: [*:0]const u8, keyword: [*:0]const u8) callconv(.c) i32 {
    return FindArg(db, template, keyword);
}
fn lvoStrToLong(db: *DosBase, string: [*:0]const u8, value: *i32) callconv(.c) i32 {
    return StrToLong(db, string, value);
}
fn lvoSetMode(db: *DosBase, file: ?*FileHandle, mode: i32) callconv(.c) bool {
    return SetMode(db, file, mode);
}
fn lvoWaitForChar(db: *DosBase, file: ?*FileHandle, timeout: isize) callconv(.c) bool {
    return WaitForChar(db, file, timeout);
}
fn lvoFault(db: *DosBase, code: i32, header: ?[*:0]const u8, buffer: [*]u8, len: i32) callconv(.c) i32 {
    return Fault(db, code, header, buffer, len);
}
fn lvoPrintFault(db: *DosBase, code: i32, header: ?[*:0]const u8) callconv(.c) bool {
    return PrintFault(db, code, header);
}
fn lvoSetVar(db: *DosBase, name: [*:0]const u8, buffer: ?[*]const u8, size: isize, flags: u32) callconv(.c) bool {
    return SetVar(db, name, buffer, size, flags);
}
fn lvoGetVar(db: *DosBase, name: [*:0]const u8, buffer: [*]u8, size: isize, flags: u32) callconv(.c) isize {
    return GetVar(db, name, buffer, size, flags);
}
fn lvoDeleteVar(db: *DosBase, name: [*:0]const u8, flags: u32) callconv(.c) bool {
    return DeleteVar(db, name, flags);
}
fn lvoFindVar(db: *DosBase, name: [*:0]const u8, var_type: u32) callconv(.c) ?*dos.LocalVar {
    return FindVar(db, name, var_type);
}
fn lvoCheckSignal(db: *DosBase, mask: u32) callconv(.c) u32 {
    return CheckSignal(db, mask);
}
fn lvoDelay(db: *DosBase, ticks: u32) callconv(.c) void {
    Delay(db, ticks);
}
fn lvoGetArgStr(db: *DosBase) callconv(.c) ?[*:0]const u8 {
    return GetArgStr(db);
}
fn lvoSetArgStr(db: *DosBase, string: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return SetArgStr(db, string);
}
fn lvoMaxCli(db: *DosBase) callconv(.c) u32 {
    return MaxCli(db);
}
fn lvoFindCliProc(db: *DosBase, num: u32) callconv(.c) ?*Process {
    return FindCliProc(db, num);
}
fn lvoRunCommand(db: *DosBase, code: ?*const dos.SegCode, stack_size: u32, args: [*]const u8, length: isize) callconv(.c) i32 {
    return RunCommand(db, code, stack_size, args, length);
}
fn lvoSystemTagList(db: *DosBase, command: ?[*:0]const u8, tags: ?[*]const TagItem) callconv(.c) i32 {
    return SystemTagList(db, command, tags);
}
fn lvoExecute(db: *DosBase, command: [*:0]const u8, input: ?*FileHandle, output: ?*FileHandle) callconv(.c) bool {
    return Execute(db, command, input, output);
}
fn lvoLoadSeg(db: *DosBase, name: [*:0]const u8) callconv(.c) ?*dos.SegList {
    return LoadSeg(db, name);
}
fn lvoUnLoadSeg(db: *DosBase, seg_list: ?*dos.SegList) callconv(.c) void {
    UnLoadSeg(db, seg_list);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(dos_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoDoPkt),
    vec(lvoSendPkt),
    vec(lvoWaitPkt),
    vec(lvoReplyPkt),
    vec(lvoAbortPkt),
    vec(lvoAllocDosObject),
    vec(lvoFreeDosObject),
    vec(lvoIoErr),
    vec(lvoSetIoErr),
    vec(lvoCreateNewProc),
    vec(lvoLockDosList),
    vec(lvoUnLockDosList),
    vec(lvoAttemptLockDosList),
    vec(lvoAddDosEntry),
    vec(lvoRemDosEntry),
    vec(lvoFindDosEntry),
    vec(lvoNextDosEntry),
    vec(lvoMakeDosEntry),
    vec(lvoFreeDosEntry),
    vec(lvoGetDeviceProc),
    vec(lvoFreeDeviceProc),
    vec(lvoAddPart),
    vec(lvoFilePart),
    vec(lvoPathPart),
    vec(lvoSplitName),
    vec(lvoParsePath),
    vec(lvoAddSegment),
    vec(lvoFindSegment),
    vec(lvoRemSegment),
    vec(lvoLockSegmentList),
    vec(lvoUnLockSegmentList),
    vec(lvoLock),
    vec(lvoUnLock),
    vec(lvoDupLock),
    vec(lvoParentDir),
    vec(lvoSameLock),
    vec(lvoCurrentDir),
    vec(lvoCreateDir),
    vec(lvoDeleteFile),
    vec(lvoDateStamp),
    vec(lvoCompareDates),
    vec(lvoDateToStr),
    vec(lvoStrToDate),
    vec(lvoOpen),
    vec(lvoClose),
    vec(lvoRead),
    vec(lvoWrite),
    vec(lvoSeek),
    vec(lvoInput),
    vec(lvoOutput),
    vec(lvoSelectInput),
    vec(lvoSelectOutput),
    vec(lvoIsInteractive),
    vec(lvoExamine),
    vec(lvoExNext),
    vec(lvoExamineFH),
    vec(lvoExAll),
    vec(lvoExAllEnd),
    vec(lvoCli),
    vec(lvoSelectError),
    vec(lvoErrorOutput),
    vec(lvoGetConsoleTask),
    vec(lvoSetConsoleTask),
    vec(lvoGetFileSysTask),
    vec(lvoSetFileSysTask),
    vec(lvoGetProgramDir),
    vec(lvoSetProgramDir),
    vec(lvoSetProgramName),
    vec(lvoGetProgramName),
    vec(lvoSetPrompt),
    vec(lvoGetPrompt),
    vec(lvoSetCurrentDirName),
    vec(lvoGetCurrentDirName),
    vec(lvoNameFromLock),
    vec(lvoAssignLock),
    vec(lvoAssignLate),
    vec(lvoAssignPath),
    vec(lvoAssignAdd),
    vec(lvoRemAssignList),
    vec(lvoMatchFirst),
    vec(lvoMatchNext),
    vec(lvoMatchEnd),
    vec(lvoRename),
    vec(lvoSetProtection),
    vec(lvoSetComment),
    vec(lvoSetFileDate),
    vec(lvoSetOwner),
    vec(lvoSetFileSize),
    vec(lvoDupLockFromFH),
    vec(lvoParentOfFH),
    vec(lvoNameFromFH),
    vec(lvoOpenFromLock),
    vec(lvoChangeMode),
    vec(lvoInfo),
    vec(lvoIsFileSystem),
    vec(lvoSameDevice),
    vec(lvoFlush),
    vec(lvoFGetC),
    vec(lvoUnGetC),
    vec(lvoFPutC),
    vec(lvoFRead),
    vec(lvoFWrite),
    vec(lvoFGets),
    vec(lvoFPuts),
    vec(lvoSetVBuf),
    vec(lvoVFPrintf),
    vec(lvoVPrintf),
    vec(lvoPutStr),
    vec(lvoWriteChars),
    vec(lvoReadArgs),
    vec(lvoFreeArgs),
    vec(lvoReadItem),
    vec(lvoFindArg),
    vec(lvoStrToLong),
    vec(lvoSetMode),
    vec(lvoWaitForChar),
    vec(lvoFault),
    vec(lvoPrintFault),
    vec(lvoSetVar),
    vec(lvoGetVar),
    vec(lvoDeleteVar),
    vec(lvoFindVar),
    vec(lvoCheckSignal),
    vec(lvoDelay),
    vec(lvoGetArgStr),
    vec(lvoSetArgStr),
    vec(lvoMaxCli),
    vec(lvoFindCliProc),
    vec(lvoRunCommand),
    vec(lvoSystemTagList),
    vec(lvoExecute),
    vec(lvoLoadSeg),
    vec(lvoUnLoadSeg),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the ROM's slots, every LVO at its function" {
    try testing.expectEqual(@as(usize, 137), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("dos_lvo.zig"), LVO, &.{});
}
