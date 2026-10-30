// SPDX-License-Identifier: MIT
//! Objects: made and freed.
//!
//! An object is the caller's memory, like everything a program asks for:
//! the program that made it deletes it, and one that ends without doing
//! so leaves it where it was. Every object is one size - `Data` holds
//! what any kind keeps - so a tree is freed without asking what each
//! node is.

const sdk = @import("sdk");
const exec = sdk.exec;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;
const Object = _base.Object;

/// A cleared object of `kind`, active, with an empty list; null without
/// memory.
pub fn make(base: *CxBase, kind: u32) ?*Object {
    const block = base.sys_base.AllocMem(@sizeOf(Object), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const object: *Object = @ptrCast(@alignCast(block));
    object.* = .{ .kind = kind, .flags = _base.COF_ENABLE };
    object.list.init(.unknown);
    return object;
}

pub fn free(base: *CxBase, object: *Object) void {
    base.sys_base.FreeMem(object, @sizeOf(Object));
}

/// Every object on `list`, and every one attached to those, freed. The
/// list is out of the network already, so nothing else walks it.
pub fn freeTree(base: *CxBase, list: *exec.List) void {
    const sys = base.sys_base;
    while (sys.RemHead(list)) |node| {
        const object: *Object = @ptrCast(@alignCast(node));
        freeTree(base, &object.list);
        free(base, object);
    }
}
