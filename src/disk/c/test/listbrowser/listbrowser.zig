// SPDX-License-Identifier: MIT
//! ListBrowser: a drawer as a tree in a list browser. Built against the
//! SDK only.
//!
//!   ListBrowser [DIR]
//!
//! It opens listbrowser.gadget and a window object on the default public
//! screen holding one: the entries of DIR (SYS: when not given) in three
//! columns - Name, Size and Kind - each drawer the head of a closed branch
//! holding its own entries one level down. A press on a heading sorts by
//! that column, a second press turns the order round; a press on a
//! drawer's triangle opens it. A row chosen is printed with its place and
//! name, a double-click said as such. The close gadget or Ctrl-C end it.
//!
//! The scroll bar is in the window's right border, the list browser made
//! without one of its own: the bar's `ICA_TARGET` is the list browser and
//! its `ICA_MAP` turns its top into `LISTBROWSER_Top`, and the list
//! browser tells the window where its view is (`IDCMP_IDCMPUPDATE`), from
//! which the bar is set.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const icc = intuition.icclass;
const pg = intuition.propgclass;
const sr = sdk.gadgets.scroller;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const lb = sdk.gadgets.listbrowser;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "ListBrowser";
const VERSION_STRING = "\x00$VER: ListBrowser 1.0 (07.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DIR";
const arg_dir = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NODIR = "%s: no such drawer\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "%lu entries. Press the headings and the triangles. The close gadget or Ctrl-C end it\n";
const MSG_CHOSEN = "Row %lu: %s\n";
const MSG_DOUBLE = "Row %lu: %s, a double-click\n";

/// The most entries read from one drawer.
const most = 200;

const columns = [_]lb.Column{
    .{ .title = "Name", .weight = 3 },
    .{ .title = "Size", .weight = 1, .flags = lb.COLUMN_RIGHT | lb.COLUMN_NUMBER },
    .{ .title = "Kind", .weight = 1 },
    .{},
};

/// The entries of the drawer `lock` stands for, each a row `depth` deep at
/// the end of `rows`, a drawer's own entries under it when `depth` is 0.
/// How many rows were added.
fn readDrawer(sys: *ExecBase, dl: *DosBase, lock: *dos.FileLock, rows: *exec.List, depth: u16) u32 {
    const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_CLEAR) orelse return 0));
    defer sys.FreeVec(@ptrCast(fib));
    if (!dl.Examine(lock, fib)) return 0;
    var added: u32 = 0;
    var read: u32 = 0;
    while (read < most and dl.ExNext(lock, fib)) : (read += 1) {
        const drawer = fib.dir_entry_type > 0;
        var size_text: [24:0]u8 = @splat(0);
        if (!drawer) decimal(&size_text, fib.size);
        const name: [*:0]const u8 = @ptrCast(&fib.file_name);
        const row = lb.allocRow(sys, &.{ name, if (drawer) "" else @ptrCast(&size_text), if (drawer) "Drawer" else "File" }, depth) orelse break;
        sys.AddTail(rows, &row.node);
        added += 1;
        if (drawer and depth == 0) {
            // Its entries under it, from a lock of its own: the walk of
            // this drawer goes on from `fib` afterwards.
            const old = dl.CurrentDir(lock);
            defer _ = dl.CurrentDir(old);
            if (dl.Lock(name, dos.ACCESS_READ)) |inner| {
                defer dl.UnLock(inner);
                added += readDrawer(sys, dl, inner, rows, 1);
            }
        }
    }
    return added;
}

/// `number` in decimal into `into`, ended by a 0.
fn decimal(into: *[24:0]u8, number: u64) void {
    var digits: [20]u8 = undefined;
    var at: usize = digits.len;
    var left = number;
    while (true) {
        at -= 1;
        digits[at] = '0' + @as(u8, @intCast(left % 10));
        left /= 10;
        if (left == 0) break;
    }
    const length = digits.len - at;
    @memcpy(into[0..length], digits[at..]);
    into[length] = 0;
}

/// What the bar tells the list browser as it is dragged; its GA_ID goes
/// no further, or the list browser would take it for its own.
const bar_map = [_]TagItem{
    .{ .tag = sr.SCROLLER_Top, .data = lb.LISTBROWSER_Top },
    .{ .tag = gc.GA_ID, .data = utility.TAG_IGNORE },
    .{},
};

fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, attr: utility.Tag) isize {
    var value: usize = 0;
    const wanted = [_]TagItem{ .{ .tag = attr, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(window, &wanted);
    return @bitCast(value);
}

/// A bar down the right border, from the title bar to the sizing gadget,
/// joined to the list browser; made once the window is open. Only the
/// right border holds the sizing gadget, so the bottom one is thin: the
/// gadget sits in the right border's foot, as tall as the title bar, and
/// the bar stops above it, its arrows that tall as well.
fn makeBar(ib: *IntuitionBase, window: *intuition.Window, browser: *Object) ?*Object {
    const top = windowAttr(ib, window, wn.WA_BorderTop);
    const right = windowAttr(ib, window, wn.WA_BorderRight);
    const sizer = top;
    const bar = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_RightBorder, .data = 1 },
        .{ .tag = gc.GA_RelRight, .data = @bitCast(-(right - 1)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(top) },
        .{ .tag = gc.GA_Width, .data = @bitCast(right) },
        .{ .tag = gc.GA_RelHeight, .data = @bitCast(-(top + sizer)) },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
        .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(sizer) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(browser) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&bar_map) },
        .{},
    }) orelse return null;
    _ = ib.AddGList(window, bar, -1, 1);
    ib.RefreshWindowFrame(window);
    return bar;
}

/// The bar set from where the list browser's view is.
fn followView(ib: *IntuitionBase, window: *intuition.Window, bar: *Object, browser: *Object) void {
    var total: usize = 0;
    var visible: usize = 0;
    var top: usize = 0;
    _ = ib.GetAttr(lb.LISTBROWSER_Total, browser, &total);
    _ = ib.GetAttr(lb.LISTBROWSER_Visible, browser, &visible);
    _ = ib.GetAttr(lb.LISTBROWSER_Top, browser, &top);
    _ = ib.SetGadgetAttrsTagList(bar, window, &[_]TagItem{
        .{ .tag = sr.SCROLLER_Total, .data = @max(total, 1) },
        .{ .tag = sr.SCROLLER_Visible, .data = @max(visible, 1) },
        .{ .tag = sr.SCROLLER_Top, .data = top },
        .{},
    });
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const dir: [*:0]const u8 = if (argv[arg_dir] != 0) @ptrFromInt(argv[arg_dir]) else "SYS:";

    var rows: exec.List = .{};
    rows.init(.unknown);
    defer lb.freeRows(sys, &rows);
    const lock = dl.Lock(dir, dos.ACCESS_READ) orelse {
        _ = Printf(dl, MSG_NODIR, .{dir});
        return dos.RETURN_FAIL;
    };
    const count = readDrawer(sys, dl, lock, &rows, 0);
    dl.UnLock(lock);

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const class_lib = sys.OpenLibrary(lb.LISTBROWSER_LIBRARY, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{lb.LISTBROWSER_LIBRARY});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(class_lib);
    const scroller_lib = sys.OpenLibrary(sr.SCROLLER_LIBRARY, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{sr.SCROLLER_LIBRARY});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(scroller_lib);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    const browser = ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 1 },
        .{ .tag = lb.LISTBROWSER_Columns, .data = @intFromPtr(&columns) },
        .{ .tag = lb.LISTBROWSER_Rows, .data = @intFromPtr(&rows) },
        .{ .tag = lb.LISTBROWSER_SortColumn, .data = 0 },
        .{ .tag = lb.LISTBROWSER_Scrollers, .data = 0 },
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 4 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(browser) },
        .{},
    }) orelse {
        ib.DisposeObject(browser);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(dir) },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_SizeBRight, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // The window and the gadget go before the rows they show.
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);
    // The bar is the program's, not the window object's: the window is
    // closed first, which takes it out of it, and then it goes.
    const bar = makeBar(ib, window, browser);
    defer {
        var shut = wc.WmClose{};
        _ = ib.SendMessage(object, @ptrCast(&shut));
        ib.DisposeObject(bar);
    }
    if (bar) |made| followView(ib, window, made, browser);
    _ = Printf(dl, MSG_HELLO, .{@as(u64, count)});

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_IDCMPUPDATE, wc.WMHI_NEWSIZE => if (bar) |made| followView(ib, window, made, browser),
                wc.WMHI_GADGETUP => {
                    var row_ptr: usize = 0;
                    _ = ib.GetAttr(lb.LISTBROWSER_SelectedRow, browser, &row_ptr);
                    if (row_ptr == 0) continue;
                    const row: *lb.Row = @ptrFromInt(row_ptr);
                    const place: u64 = code & ~lb.LISTBROWSER_DOUBLE;
                    const name = row.cells[0] orelse "";
                    if (code & lb.LISTBROWSER_DOUBLE != 0) {
                        _ = Printf(dl, MSG_DOUBLE, .{ place, name });
                    } else {
                        _ = Printf(dl, MSG_CHOSEN, .{ place, name });
                    }
                },
                else => {},
            }
        }
    }
}
