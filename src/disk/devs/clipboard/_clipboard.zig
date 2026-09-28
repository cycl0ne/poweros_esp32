// SPDX-License-Identifier: MIT
//! clipboard.device's base and units, and what both files here need.
//!
//! **A unit is a clip**, and its number the one a program asked for -
//! `PRIMARY_CLIP` is the one they share. The clip's bytes are a file in
//! `CLIPS:` named after the unit, so a clip costs the device no memory,
//! outlives the program that cut it, and can be looked at with `Type`.
//!
//! **The work is done by a process of its own** (`server.zig`), because
//! the files are reached through dos and dos needs one. `BeginIO` only
//! puts the request on that process's port, so any task may use the
//! clipboard.
//!
//! Each clip has a number, which counts up every time a write is begun.
//! `CBD_CURRENTWRITEID` is the one being written, `CBD_CURRENTREADID`
//! the last one finished, and they are the same when no write is going
//! on.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const clipboard = sdk.devices.clipboard;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;

pub const DEVICE_NAME = clipboard.CLIPBOARDNAME;

/// Where a clip's file goes. The startup-sequence assigns it.
pub const clips_prefix = "CLIPS:";

/// The server's stack: dos calls run on it.
pub const stack_bytes = 8192;
/// Above the programs it serves, as the other devices' tasks are.
pub const server_pri = 5;

pub const ClipBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    /// Opened when the device is first opened, since every clip is a
    /// file.
    dos_base: ?*DosBase = null,
    /// The units that have been made, one per number.
    units: exec.List = .{},
    /// The process that does the file work, and where its requests go.
    server: ?*exec.Task = null,
    port: exec.MsgPort = .{},
    /// Starting the server, and being told it is up.
    start_lock: exec.SignalSemaphore = .{},
    starter: ?*exec.Task = null,
    start_signal: i8 = 0,
    /// Making and freeing units.
    lock: exec.SignalSemaphore = .{},
};

/// One clip.
pub const Unit = extern struct {
    unit: exec.Unit = .{},
    base: *ClipBase,
    number: u32 = 0,
    /// The clip that can be read, and the one being written.
    read_id: i32 = 0,
    write_id: i32 = 0,
    /// How long the clip that can be read is.
    length: u64 align(4) = 0,
    /// The file while it is being read, and while it is being written.
    read_file: ?*dos.FileHandle = null,
    write_file: ?*dos.FileHandle = null,
    /// How much of the write has been put down.
    written: u64 align(4) = 0,
    /// `CLIPS:<number>`, as a C string.
    name: [24]u8 = @splat(0),
    /// What is told whenever the clip changes.
    hooks: exec.MinList = .{},
    hook_lock: exec.SignalSemaphore = .{},
};

pub fn clipBase(dev: *exec.Device) *ClipBase {
    return @fieldParentPtr("dev", dev);
}

pub fn unitOf(io: *exec.IORequest) *Unit {
    return @fieldParentPtr("unit", io.unit.?);
}

pub fn requestOf(msg: *exec.Message) *clipboard.IOClipReq {
    const req: *exec.IORequest = @fieldParentPtr("message", msg);
    const std_req: *exec.IOStdReq = @fieldParentPtr("req", req);
    return @fieldParentPtr("io", std_req);
}

/// `CLIPS:<number>` written into the unit's name.
pub fn nameUnit(unit: *Unit) void {
    @memcpy(unit.name[0..clips_prefix.len], clips_prefix);
    var digits: [10]u8 = undefined;
    var left = unit.number;
    var count: usize = 0;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..count) |i| unit.name[clips_prefix.len + i] = digits[count - 1 - i];
    unit.name[clips_prefix.len + count] = 0;
}

/// Everything the unit has open, closed: a clip that is being written is
/// left unfinished and the one that could be read stays as it was.
pub fn closeFiles(unit: *Unit) void {
    const dl = unit.base.dos_base orelse return;
    if (unit.read_file) |file| _ = dl.Close(file);
    if (unit.write_file) |file| _ = dl.Close(file);
    unit.read_file = null;
    unit.write_file = null;
}

/// Everything listening told the clip changed.
pub fn tellHooks(unit: *Unit, command: i32) void {
    const sys = unit.base.sys_base;
    var message = clipboard.ClipHookMsg{ .change_cmd = command, .clip_id = unit.read_id };
    sys.ObtainSemaphore(&unit.hook_lock);
    defer sys.ReleaseSemaphore(&unit.hook_lock);
    var at = unit.hooks.head;
    while (at) |node| {
        const next = node.succ orelse break;
        const hook: *utility.Hook = @ptrCast(@alignCast(node));
        if (hook.entry) |entry| _ = entry(hook, unit, &message);
        at = next;
    }
}
