// SPDX-License-Identifier: MIT
//! What programs add to the desktop - a window files can be dropped on,
//! an icon on its ground, an item in its Tools menu - kept as an `App` in
//! the base's list, under the base's `app_lock`.
//!
//! **Adding** makes the record and puts it on the list while a desktop
//! runs, and signals the desktop's process, which takes it in: draws the
//! icon, puts the item in the menu. **Removing** takes the program's port
//! off the record at once, under the lock the desktop sends under, so
//! nothing reaches the port after the call returns; the record is marked
//! gone and the desktop lets go of it and frees it. With no desktop the
//! list is empty: the desktop frees every record as it ends, and a
//! remove then finds nothing and answers false.

const sdk = @import("sdk");
const exec = sdk.exec;
const icon = sdk.icon;
const intuition = sdk.intuition;
const ExecBase = sdk.interface.exec.ExecBase;
const AnvilBase = @import("../anvil_base.zig").AnvilBase;

/// The longest text an icon's name or a menu item has.
pub const text_max = 63;

pub const Kind = enum(u8) { window, icon, menu_item };

pub const App = struct {
    node: exec.Node = .{},
    kind: Kind,
    id: u32,
    user_data: usize,
    /// Where its messages go; null once the program has removed it.
    port: ?*exec.MsgPort,
    /// An AppWindow's window.
    window: ?*intuition.Window = null,
    /// An AppIcon's name or an AppMenuItem's words.
    text: [text_max + 1:0]u8 = @splat(0),
    /// An AppIcon's picture, copied into `pixels`, and the icon the desktop
    /// draws it from.
    image: icon.IconImage = undefined,
    object: icon.DiskObject = .{},
    pixels: ?[*]u8 = null,
    /// The desktop's: taken in (its icon made, its item in the menu).
    taken: bool = false,
    /// Removed by the program: the desktop lets go of it and frees it.
    gone: bool = false,
};

/// A record put on the list and the desktop told; false when no desktop
/// runs, and the record is still the caller's.
pub fn add(base: *AnvilBase, record: *App) bool {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.app_lock);
    defer sys.ReleaseSemaphore(&base.app_lock);
    const task = base.app_task orelse return false;
    sys.AddTail(&base.apps, &record.node);
    sys.Signal(task, base.app_signals);
    return true;
}

/// A record of `kind` made, with nothing in it but what every one has.
pub fn make(base: *AnvilBase, kind: Kind, id: u32, user_data: usize, port: *exec.MsgPort) ?*App {
    const memory = base.sys_base.AllocVec(@sizeOf(App), exec.MEMF_CLEAR) orelse return null;
    const record: *App = @ptrCast(@alignCast(memory));
    record.* = .{ .kind = kind, .id = id, .user_data = user_data, .port = port };
    return record;
}

/// `text` copied into the record, cut to `text_max`.
pub fn setText(record: *App, text: [*:0]const u8) void {
    var length: usize = 0;
    while (text[length] != 0 and length < text_max) : (length += 1) record.text[length] = text[length];
    record.text[length] = 0;
}

/// A record freed: its picture's copy, then itself.
pub fn free(sys: *ExecBase, record: *App) void {
    if (record.pixels) |pixels| sys.FreeVec(pixels);
    sys.FreeVec(record);
}

/// What the program added taken away, as its `Remove...` call does: true
/// when `handle` is a record of `kind` on the list.
pub fn remove(base: *AnvilBase, handle: ?*anyopaque, kind: Kind) bool {
    const wanted = handle orelse return false;
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.app_lock);
    defer sys.ReleaseSemaphore(&base.app_lock);
    var it = base.apps.iterator();
    while (it.next()) |node| {
        const record: *App = @fieldParentPtr("node", node);
        if (@intFromPtr(record) != @intFromPtr(wanted) or record.kind != kind or record.gone) continue;
        record.port = null;
        record.gone = true;
        if (base.app_task) |task| sys.Signal(task, base.app_signals);
        return true;
    }
    return false;
}
