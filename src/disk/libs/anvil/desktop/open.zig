// SPDX-License-Identifier: MIT
//! The desktop's side of `OpenObject`: the port programs put their
//! requests on (`open/_open.zig`), each opened as a double click opens
//! an icon (`run.openObject`) and replied with what came of it.
//!
//! The port is in the base from the desktop's start until it quits, under
//! `app_lock`. Whatever is still on it then is replied with
//! ERROR_OBJECT_NOT_FOUND, as a call made with no desktop is answered.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const Desktop = @import("_desktop.zig").Desktop;
const _open = @import("../open/_open.zig");
const run = @import("run.zig");

/// The port made, and put in the base for `OpenObject`. False without
/// the memory.
pub fn setUp(d: *Desktop) bool {
    const sys = d.sys;
    const port = sys.CreateMsgPort() orelse return false;
    d.open_port = port;
    sys.ObtainSemaphore(&d.base.app_lock);
    defer sys.ReleaseSemaphore(&d.base.app_lock);
    d.base.open_port = port;
    return true;
}

/// No more requests taken: the port out of the base, and those that came
/// meanwhile answered that there is no desktop. Done again by `tearDown`,
/// to no effect.
pub fn leave(d: *Desktop) void {
    const sys = d.sys;
    const port = d.open_port orelse return;
    sys.ObtainSemaphore(&d.base.app_lock);
    if (d.base.open_port == port) d.base.open_port = null;
    sys.ReleaseSemaphore(&d.base.app_lock);
    while (sys.GetMsg(port)) |message| {
        const request: *_open.Request = @fieldParentPtr("message", message);
        request.failure = dos.ERROR_OBJECT_NOT_FOUND;
        sys.ReplyMsg(message);
    }
}

/// The port given back, after `leave`.
pub fn tearDown(d: *Desktop) void {
    leave(d);
    d.sys.DeleteMsgPort(d.open_port);
    d.open_port = null;
}

/// Each request on the port opened, and replied.
pub fn requests(d: *Desktop) void {
    const port = d.open_port orelse return;
    while (d.sys.GetMsg(port)) |message| {
        const request: *_open.Request = @fieldParentPtr("message", message);
        request.failure = run.openObject(d, request);
        d.sys.ReplyMsg(message);
    }
}
