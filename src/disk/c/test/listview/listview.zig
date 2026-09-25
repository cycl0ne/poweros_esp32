// SPDX-License-Identifier: MIT
//! ListView: a directory in a list view, and a scroller. Built against the
//! SDK only.
//!
//!   ListView DIR
//!
//! It reads the directory - `SYS:c` unless another is named - into an exec
//! list, a node for each entry with the entry's name, a directory's
//! followed by a `/`, and opens a window object on the default public
//! screen holding one layout: the list in a listview.gadget, selected
//! lines shown, a text line "Selected" showing the name of the last line
//! chosen, a scroller "Scroll" across of 100 things with 10 shown and
//! arrows, and an OK button. Every line chosen and every scroller let go
//! is printed with its code. OK, the close gadget or Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const pg = intuition.propgclass;
const classusr = intuition.classusr;
const tx = sdk.gadgets.text;
const sr = sdk.gadgets.scroller;
const lv = sdk.gadgets.listview;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "ListView";
const VERSION_STRING = "\x00$VER: ListView 1.0 (25.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DIR";
const arg_dir = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NODIR = "Cannot read %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "%lu entries in %s. OK, the close gadget or Ctrl-C end it\n";
const MSG_LINE = "Line %lu: %s\n";
const MSG_SCROLL = "Scroller at %lu\n";

const ID_LIST = 1;
const ID_SELECTED = 2;
const ID_SCROLL = 3;
const ID_OK = 4;

/// An entry of the directory: its node and its name, in one allocation.
const Entry = extern struct {
    node: exec.Node = .{},
    name: [112]u8 = @splat(0),
};

/// Every entry of `dir` onto `list`, a directory's with a `/`. False when
/// the directory cannot be read.
fn readDir(sys: *ExecBase, dl: *DosBase, dir: [*:0]const u8, list: *exec.List) bool {
    const lock = dl.Lock(dir, dos.SHARED_LOCK) orelse return false;
    defer dl.UnLock(lock);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(lock, &fib)) return false;
    while (dl.ExNext(lock, &fib)) {
        const block = sys.AllocVec(@sizeOf(Entry), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse break;
        const entry: *Entry = @ptrCast(@alignCast(block));
        entry.* = .{};
        var i: usize = 0;
        while (i < fib.file_name.len and fib.file_name[i] != 0 and i + 2 < entry.name.len) : (i += 1) entry.name[i] = fib.file_name[i];
        if (fib.dir_entry_type > 0) {
            entry.name[i] = '/';
            i += 1;
        }
        entry.name[i] = 0;
        entry.node.name = @ptrCast(&entry.name);
        sys.AddTail(list, &entry.node);
    }
    return true;
}

fn freeList(sys: *ExecBase, list: *exec.List) void {
    while (sys.RemHead(list)) |node| {
        const entry: *Entry = @fieldParentPtr("node", node);
        sys.FreeVec(entry);
    }
}

const Shown = struct { layout: *Object, list: *Object, selected: *Object };

fn build(ib: *IntuitionBase, list: *exec.List) ?Shown {
    const view = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LIST },
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(list) },
        .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
        .{},
    });
    const selected = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_SELECTED },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("nothing") },
        .{ .tag = tx.TEXT_Border, .data = 1 },
        .{ .tag = tx.TEXT_Clipped, .data = 1 },
        .{},
    });
    const scroll = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_SCROLL },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = sr.SCROLLER_Total, .data = 100 },
        .{ .tag = sr.SCROLLER_Visible, .data = 10 },
        .{ .tag = sr.SCROLLER_Arrows, .data = 16 },
        .{},
    });
    const ok = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("OK") },
        .{ .tag = gc.GA_ID, .data = ID_OK },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
    const parts = [_]?*Object{ view, selected, scroll, ok };
    var whole = true;
    for (parts) |part| whole = whole and part != null;
    const layout = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(view) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(selected) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Selected") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(scroll) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Scroll") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(ok) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const made = layout orelse {
        for (parts) |part| ib.DisposeObject(part);
        return null;
    };
    return .{ .layout = made, .list = view.?, .selected = selected.? };
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
    const dir = dos.rdargs.string(argv[arg_dir]) orelse "SYS:c";

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // The class libraries, open for as long as their objects are there.
    const wanted = [_][*:0]const u8{ lv.LISTVIEW_LIBRARY, tx.TEXT_LIBRARY, sr.SCROLLER_LIBRARY };
    var libraries: [wanted.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }

    var list: exec.List = .{};
    list.init(.unknown);
    // Freed after the window object, which is disposed of first.
    defer freeList(sys, &list);
    if (!readDir(sys, dl, dir, &list)) {
        _ = Printf(dl, MSG_NODIR, .{dir});
        return dos.RETURN_ERROR;
    }
    var count: u64 = 0;
    var node = list.first();
    while (node) |n| : (node = n.next()) count += 1;

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    const shown = build(ib, &list) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(shown.layout, @ptrCast(&nominal));
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("ListView") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(nominal.domain.width + 60) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(nominal.domain.height + 80) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(shown.layout) },
        .{},
    }) orelse {
        ib.DisposeObject(shown.layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);
    _ = Printf(dl, MSG_HELLO, .{ count, dir });

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
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_OK => return dos.RETURN_OK,
                    ID_SCROLL => _ = Printf(dl, MSG_SCROLL, .{@as(u64, code)}),
                    ID_LIST => {
                        const picked = lv.nodeAt(&list, code) orelse continue;
                        const name: [*:0]const u8 = picked.name orelse "";
                        _ = Printf(dl, MSG_LINE, .{ @as(u64, code), name });
                        _ = ib.SetGadgetAttrsTagList(shown.selected, window, &[_]TagItem{
                            .{ .tag = tx.TEXT_Text, .data = @intFromPtr(name) },
                            .{},
                        });
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
}
