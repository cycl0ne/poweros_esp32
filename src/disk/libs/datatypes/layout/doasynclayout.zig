// SPDX-License-Identifier: MIT
//! DoAsyncLayout: the object laid out on a process of its own.
//!
//! The job block outlives the caller and is the process's to free. The
//! GadgetInfo is copied into it, because the one intuition hands to
//! `GM_LAYOUT` is only good for the length of that call. A size that
//! changes again while the process works is copied over that one, under
//! the object's lock, so that the pass that follows measures against the
//! size the window has now.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("../datatypes_base.zig");
const _class = @import("../class/_class.zig");
const DataTypesBase = _base.DataTypesBase;
const Object = classes.Object;

/// The layout process's stack: a class's own layout runs on it.
const stack_bytes = 16384;

/// What the process is given.
const Job = extern struct {
    base: *DataTypesBase,
    object: *Object,
    info: classusr.GadgetInfo,
    initial: u32 = 0,
};

/// The layout process: the object laid out, again if its size changed
/// while it was being done, and then gone.
fn layoutProcess(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const job: *Job = @ptrCast(@alignCast(me.user_data orelse return));
    const db = job.base;
    const own = _class.dataOf(db, job.object) orelse {
        sys.FreeVec(job);
        return;
    };
    while (true) {
        // A copy of its own to work from: `job.info` is where a resize
        // that arrives meanwhile puts the new size, and it may be
        // written while this pass is running.
        sys.ObtainSemaphore(&own.special.lock);
        var info = job.info;
        sys.ReleaseSemaphore(&own.special.lock);
        var lay = gc.GpLayout{
            .method_id = dtc.DTM_ASYNCLAYOUT,
            .gadget_info = &info,
            .initial = job.initial,
        };
        sys.ObtainSemaphore(&own.special.lock);
        own.special.flags |= dtc.DTSIF_LAYOUT;
        sys.ReleaseSemaphore(&own.special.lock);
        _ = db.intuition_base.SendMessage(job.object, @ptrCast(&lay));
        sys.ObtainSemaphore(&own.special.lock);
        own.special.flags &= ~dtc.DTSIF_LAYOUT;
        if (own.special.flags & dtc.DTSIF_NEWSIZE == 0) {
            own.special.flags &= ~dtc.DTSIF_LAYOUTPROC;
            own.layout_proc = null;
            own.layout_job = null;
            sys.ReleaseSemaphore(&own.special.lock);
            break;
        }
        own.special.flags &= ~dtc.DTSIF_NEWSIZE;
        sys.ReleaseSemaphore(&own.special.lock);
    }
    // The numbers the object answers are only right once this is done,
    // and what is on the screen was drawn from the layout this one
    // replaces. Anything following the object hears `DTA_Sync` and reads
    // the numbers again; a program whose object follows
    // `ICTARGET_IDCMP` hears it as an IDCMP message and draws the object
    // again with `RefreshDTObjectA`.
    //
    // **Nothing is drawn here.** The GadgetInfo this process was given
    // is a copy, and the window it names may have been closed while the
    // laying out went on; drawing through it would draw into a window
    // that is no longer there.
    const told = [_]utility.TagItem{
        .{ .tag = dtc.DTA_Sync, .data = 1 },
        .{},
    };
    sys.ObtainSemaphore(&own.special.lock);
    var last = job.info;
    sys.ReleaseSemaphore(&own.special.lock);
    sdk.gadgets.support.notify(db.intuition_base, job.object, &last, &told, 0);
    sys.FreeVec(job);
}

/// Lays an object out on a process of its own.
///
/// SYNOPSIS:
/// ```zig
/// fn DoAsyncLayout(db: *DataTypesBase, object: *classusr.Object, layout: *gc.GpLayout) u32
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `object` - a data type object.
/// - `layout` - the `GM_LAYOUT` message that asked for it. Its
///   `gadget_info` is copied, so it need not outlive the call.
///
/// RESULT:
/// 1 when a process is doing it, 0 when none could be started - and
/// then nothing has been laid out, so the caller does it itself.
///
/// BEHAVIOR:
/// The object is sent `DTM_ASYNCLAYOUT` on the new process. A second
/// call while one is already running does not start another: the
/// running one is told the size changed and lays the object out again
/// when it is done, which is what keeps a window being dragged to a new
/// size from starting a process for every pixel.
///
/// `DTSIF_LAYOUT` is set while the work is going on and the object's
/// lock is held over it, so nothing disposes of an object mid-layout.
///
/// CONTEXT:
/// - Waits: for memory and for the object's lock, briefly.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do; the work itself needs a Process, which is
///   why there is one.
///
/// OWNERSHIP:
/// The job block is the new process's and goes with it.
///
/// NOTES:
/// datatypesclass answers `GM_LAYOUT` with this call, so a format's
/// class does its laying out in `DTM_ASYNCLAYOUT` and never in
/// `GM_LAYOUT`.
///
/// SEE ALSO:
/// `AddDTObject`, `RefreshDTObjectA`
///
/// EXAMPLES:
/// ```zig
/// gc.GM_LAYOUT => return db.DoAsyncLayout(object, @ptrCast(@alignCast(msg))),
/// ```
pub fn DoAsyncLayout(db: *DataTypesBase, object: *classusr.Object, layout: *gc.GpLayout) u32 {
    const sys = db.sys_base;
    const own = _class.dataOf(db, object) orelse return 0;
    const info = layout.gadget_info orelse return 0;

    sys.ObtainSemaphore(&own.special.lock);
    if (own.special.flags & dtc.DTSIF_LAYOUTPROC != 0) {
        own.special.flags |= dtc.DTSIF_NEWSIZE;
        // The room to lay out against is this one, not the one the
        // process started with: a window resized again while it works
        // has a size it does not know about, and laying out against the
        // old one leaves the object drawing over its window's border -
        // or, where the old one was smaller than the border, drawing
        // nothing at all.
        if (own.layout_job) |block| {
            const running: *Job = @ptrCast(@alignCast(block));
            running.info = info.*;
        }
        sys.ReleaseSemaphore(&own.special.lock);
        return 1;
    }
    own.special.flags |= dtc.DTSIF_LAYOUTPROC;
    sys.ReleaseSemaphore(&own.special.lock);

    const memory = sys.AllocVec(@sizeOf(Job), exec.MEMF_ANY | exec.MEMF_CLEAR);
    if (memory) |block| {
        const job: *Job = @ptrCast(@alignCast(block));
        job.* = .{ .base = db, .object = object, .info = info.*, .initial = layout.initial };
        const tags = [_]utility.TagItem{
            .{ .tag = dos.NP_Entry, .data = @intFromPtr(&layoutProcess) },
            .{ .tag = dos.NP_Name, .data = @intFromPtr("datatypes layout") },
            .{ .tag = dos.NP_StackSize, .data = stack_bytes },
            .{ .tag = dos.NP_UserData, .data = @intFromPtr(job) },
            .{},
        };
        sys.ObtainSemaphore(&own.special.lock);
        own.layout_job = block;
        sys.ReleaseSemaphore(&own.special.lock);
        if (db.dos_base.CreateNewProc(&tags)) |process| {
            own.layout_proc = @ptrCast(process);
            return 1;
        }
        sys.ObtainSemaphore(&own.special.lock);
        own.layout_job = null;
        sys.ReleaseSemaphore(&own.special.lock);
        sys.FreeVec(block);
    }

    // No process: the work is done here, which is slower than it should
    // be but better than not at all.
    sys.ObtainSemaphore(&own.special.lock);
    own.special.flags &= ~dtc.DTSIF_LAYOUTPROC;
    sys.ReleaseSemaphore(&own.special.lock);
    var here = gc.GpLayout{
        .method_id = dtc.DTM_ASYNCLAYOUT,
        .gadget_info = info,
        .initial = layout.initial,
    };
    _ = db.intuition_base.SendMessage(object, @ptrCast(&here));
    return 0;
}
