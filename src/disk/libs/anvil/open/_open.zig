// SPDX-License-Identifier: MIT
//! What `OpenObject` hands the desktop: a request, made on the caller's
//! task and put on the desktop's port (`AnvilBase.open_port`), which the
//! desktop opens as a double click opens an icon (`desktop/open.zig`) and
//! replies.
//!
//! **The names** are made full on the caller's task, from its current
//! directory: the desktop's own is another. **The port** is in the base
//! only while the desktop takes requests, and a request is put on it
//! under `app_lock`; one there when the desktop quits is replied with
//! ERROR_OBJECT_NOT_FOUND, as a call with no desktop is answered.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const anvil = sdk.anvil;
const utility = sdk.utility;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const AnvilBase = @import("../anvil_base.zig").AnvilBase;

pub const files_max = anvil.OPEN_FILES_MAX;

pub const Request = struct {
    message: exec.Message = .{},
    /// The object's full name, and each file's.
    path: [dos.path_max + 1:0]u8 = @splat(0),
    files: [files_max][dos.path_max + 1:0]u8 = undefined,
    file_count: usize = 0,
    /// The caller's (`ANVO_EndMsg`), replied when what was opened ends.
    end_msg: ?*exec.Message = null,
    /// The desktop's answer: 0, or the dos error why it was not opened.
    failure: i32 = 0,
};

/// A request made for `name` and the tags' files, its reply port
/// `reply`: null with IoErr when a name cannot be found or there is no
/// memory.
pub fn make(base: *AnvilBase, name: [*:0]const u8, tags: ?[*]const utility.TagItem, reply: *exec.MsgPort) ?*Request {
    const sys = base.sys_base;
    const dl = base.dos_base;
    const memory = sys.AllocVec(@sizeOf(Request), exec.MEMF_ANY) orelse return failed(dl, dos.ERROR_NO_FREE_STORE);
    const request: *Request = @ptrCast(@alignCast(memory));
    request.* = .{ .message = .{ .reply_port = reply, .length = @sizeOf(Request) } };
    if (!fullName(dl, name, &request.path) or !readTags(base, request, tags)) {
        sys.FreeVec(memory);
        return null;
    }
    return request;
}

/// The tags read into the request: each file's full name, the end
/// message. False with IoErr.
fn readTags(base: *AnvilBase, request: *Request, tags: ?[*]const utility.TagItem) bool {
    if (tags == null) return true;
    const sys = base.sys_base;
    const dl = base.dos_base;
    const library = sys.OpenLibrary(sdk.interface.utility.NAME, 0) orelse {
        _ = dl.SetIoErr(dos.ERROR_INVALID_RESIDENT_LIBRARY);
        return false;
    };
    defer sys.CloseLibrary(library);
    const ub: *UtilityBase = @ptrCast(library);
    var walk = tags;
    while (ub.NextTagItem(&walk)) |item| {
        switch (item.tag) {
            anvil.ANVO_File => {
                if (request.file_count == files_max) continue;
                const file: [*:0]const u8 = @ptrFromInt(item.data);
                if (!fullName(dl, file, &request.files[request.file_count])) return false;
                request.file_count += 1;
            },
            anvil.ANVO_EndMsg => request.end_msg = @ptrFromInt(item.data),
            else => {},
        }
    }
    return true;
}

/// `name` as its full name, from the caller's current directory, into
/// `into`. False with IoErr.
fn fullName(dl: *DosBase, name: [*:0]const u8, into: *[dos.path_max + 1:0]u8) bool {
    const lock = dl.Lock(name, dos.SHARED_LOCK) orelse return false;
    defer dl.UnLock(lock);
    return dl.NameFromLock(lock, into, into.len);
}

/// The request put on the desktop's port; false when no desktop takes
/// requests.
pub fn send(base: *AnvilBase, request: *Request) bool {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.app_lock);
    defer sys.ReleaseSemaphore(&base.app_lock);
    const port = base.open_port orelse return false;
    sys.PutMsg(port, &request.message);
    return true;
}

/// Whether the caller is the desktop's own process, which would wait for
/// itself.
pub fn isDesktop(base: *AnvilBase) bool {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.app_lock);
    defer sys.ReleaseSemaphore(&base.app_lock);
    return base.app_task != null and base.app_task == sys.FindTask(null);
}

fn failed(dl: *DosBase, code: i32) ?*Request {
    _ = dl.SetIoErr(code);
    return null;
}
