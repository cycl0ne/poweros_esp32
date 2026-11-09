// SPDX-License-Identifier: MIT
//! vector.library's base: exec's Library header and what it was loaded
//! as. Everything a call works on - a path, a canvas - is the caller's,
//! so one base is shared by every opener and holds nothing else.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const draw = @import("vector");

pub const VectorBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
};

/// The base from exec's Library header.
pub fn vectorBase(lib: *exec.Library) *VectorBase {
    return @fieldParentPtr("lib", lib);
}

/// Where a path's and a canvas's memory comes from: exec's, any kind.
pub fn memoryOf(vb: *VectorBase) draw.Memory {
    return .{ .context = vb.sys_base, .allocFn = alloc, .freeFn = free };
}

fn alloc(context: ?*anyopaque, bytes: usize) ?[*]align(8) u8 {
    const sys: *ExecBase = @ptrCast(@alignCast(context.?));
    return @ptrCast(@alignCast(sys.AllocVec(bytes, exec.MEMF_ANY) orelse return null));
}

fn free(context: ?*anyopaque, block: [*]align(8) u8, bytes: usize) void {
    _ = bytes;
    const sys: *ExecBase = @ptrCast(@alignCast(context.?));
    sys.FreeVec(block);
}

/// The module's path behind the handle a program holds.
pub fn pathOf(path: anytype) switch (@TypeOf(path)) {
    *sdk.vector.Path => *draw.Path,
    *const sdk.vector.Path => *const draw.Path,
    else => @compileError("pathOf: a vector.Path pointer"),
} {
    return @ptrCast(@alignCast(path));
}

/// The module's canvas behind the handle a program holds.
pub fn canvasOf(canvas: *sdk.vector.Canvas) *draw.Canvas {
    return @ptrCast(@alignCast(canvas));
}
