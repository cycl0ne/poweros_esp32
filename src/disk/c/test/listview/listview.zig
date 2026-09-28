// SPDX-License-Identifier: MIT
//! ListView: a directory in a list view, and a scroller. Built against the
//! SDK only.
//!
//!   ListView DIR
//!
//!   ListView DIR MULTI/S
//!
//! It reads the directory - `SYS:c` unless another is named - into an exec
//! list, a node for each entry with the entry's name, a directory's
//! followed by a `/`, and opens a window object on the default public
//! screen holding one layout: the list in a listview.gadget, selected
//! lines shown, a line to type in, "Selected", that the list writes the
//! name of the chosen line into (`LISTVIEW_SelectString`), a scroller
//! "Scroll" across of 100 things with 10 shown and arrows, and an OK
//! button. Every line chosen and every scroller let go
//! is printed with its code. OK, the close gadget or Ctrl-C end it.
//!
//! Each line is drawn by a hook of the program's own in two columns: the
//! name at the left, and at the right the size in bytes or the word
//! `Drawer`.
//!
//! With `MULTI` several lines may be selected at once - a press with Shift
//! held adds one or takes it away, a drag with Shift held carries that
//! over the lines it crosses - and every line chosen prints all of them.
//! A double-click on a line is printed as one.
//!
//! The letter underlined in a label works its gadget: `f` moves the list's
//! selection down a line and Shift-`f` up, `s` moves the scroller, `o`
//! presses OK.

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
const st = sdk.gadgets.string;
const sr = sdk.gadgets.scroller;
const lv = sdk.gadgets.listview;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "ListView";
const VERSION_STRING = "\x00$VER: ListView 1.3 (28.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DIR,MULTI/S";
const arg_dir = 0;
const arg_multi = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NODIR = "Cannot read %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "%lu entries in %s. OK, the close gadget or Ctrl-C end it\n";
const MSG_LINE = "Line %lu: %s\n";
const MSG_DOUBLE = "Line %lu: %s, twice over\n";
const MSG_ALSO = "  and %lu: %s\n";
const MSG_SCROLL = "Scroller at %lu\n";

const ID_LIST = 1;
const ID_SELECTED = 2;
const ID_SCROLL = 3;
const ID_OK = 4;

/// An entry of the directory: its node, its name and what the right-hand
/// column says about it, in one allocation.
const Entry = extern struct {
    node: exec.Node = .{},
    name: [112]u8 = @splat(0),
    right: [16]u8 = @splat(0),
};

/// `value` written into `into` as decimal digits, and how many there are.
fn decimal(value: u32, into: []u8) usize {
    var digits: [10]u8 = undefined;
    var left = value;
    var count: usize = 0;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    var i: usize = 0;
    while (i < count and i < into.len) : (i += 1) into[i] = digits[count - 1 - i];
    return i;
}

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
        if (fib.dir_entry_type > 0) {
            const word = "Drawer";
            for (word, 0..) |c, at| entry.right[at] = c;
            entry.right[word.len] = 0;
        } else {
            const digits = decimal(@truncate(fib.size), entry.right[0 .. entry.right.len - 1]);
            entry.right[digits] = 0;
        }
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

/// How many pixels lie between a line's text and the frame at either side.
const column_margin = 4;

/// One line in two columns: the name at the left, what the entry is at
/// the right. The hook fills the line's ground itself, so it answers
/// `LVCB_OK` and the gadget draws nothing more of it.
fn drawEntry(hook: *sdk.utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const lv.LVDrawMsg = @ptrCast(@alignCast(message.?));
    if (msg.method_id != lv.LV_DRAW) return lv.LVCB_UNKNOWN;
    const gb: *sdk.interface.graphics.GraphicsBase = @ptrCast(@alignCast(hook.data.?));
    const rp = msg.rast_port.?;
    const node: *exec.Node = @ptrCast(@alignCast(object.?));
    const entry: *Entry = @fieldParentPtr("node", node);
    const pens = msg.draw_info.?.pens;
    const selected = msg.state == lv.LVR_SELECTED or msg.state == lv.LVR_SELECTEDDISABLED;

    const ground = [_]TagItem{
        .{ .tag = sdk.graphics.RPTAG_APen, .data = pens[if (selected) intuition.screens.FILLPEN else intuition.screens.BACKGROUNDPEN] },
        .{ .tag = sdk.graphics.RPTAG_DrMd, .data = sdk.graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &ground);
    gb.RectFill(rp, &msg.bounds);

    var baseline: u32 = 0;
    var height: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = sdk.graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{ .tag = sdk.graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    const top = msg.bounds.min_y + @divTrunc(msg.bounds.max_y - msg.bounds.min_y - @as(i32, @intCast(height)), 2) + @as(i32, @intCast(baseline));

    const ink = [_]TagItem{
        .{ .tag = sdk.graphics.RPTAG_APen, .data = pens[if (selected) intuition.screens.FILLTEXTPEN else intuition.screens.TEXTPEN] },
        .{},
    };
    gb.SetRPAttrs(rp, &ink);

    const right: [*:0]const u8 = @ptrCast(&entry.right);
    var right_len: u32 = 0;
    while (right[right_len] != 0) right_len += 1;
    const right_width = gb.TextLength(rp, right, right_len);
    const right_at = msg.bounds.max_x - column_margin - right_width;

    const name: [*:0]const u8 = @ptrCast(&entry.name);
    var name_len: u32 = 0;
    while (name[name_len] != 0) name_len += 1;
    // The name gives way to the right-hand column.
    const room = right_at - (msg.bounds.min_x + column_margin) - column_margin;
    if (gb.TextLength(rp, name, name_len) > room) {
        var extent: sdk.graphics.TextExtent = .{};
        name_len = gb.TextFit(rp, name, name_len, &extent, null, 1, @max(room, 0), 0);
    }
    gb.Move(rp, msg.bounds.min_x + column_margin, top);
    gb.Text(rp, name, name_len);
    gb.Move(rp, right_at, top);
    gb.Text(rp, right, right_len);
    return lv.LVCB_OK;
}

const Shown = struct { layout: *Object, list: *Object, selected: *Object };

fn build(ib: *IntuitionBase, list: *exec.List, hook: *sdk.utility.Hook, multi: bool) ?Shown {
    const view = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LIST },
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(list) },
        .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
        .{ .tag = lv.LISTVIEW_CallBack, .data = @intFromPtr(hook) },
        .{ .tag = if (multi) lv.LISTVIEW_MultiSelect else sdk.utility.TAG_IGNORE, .data = 1 },
        .{},
    });
    // The list writes the selected line's name here, and it can be
    // edited: what a file requester's name field does.
    const selected = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_SELECTED },
        .{ .tag = gc.STRINGA_MaxChars, .data = 128 },
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
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_OK") },
        .{ .tag = gc.GA_ID, .data = ID_OK },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
    // The list writes into the field, once both are there.
    if (view != null and selected != null) _ = ib.SetAttrsTagList(view, &[_]TagItem{
        .{ .tag = lv.LISTVIEW_SelectString, .data = @intFromPtr(selected) },
        .{},
    });
    const parts = [_]?*Object{ view, selected, scroll, ok };
    var whole = true;
    for (parts) |part| whole = whole and part != null;
    const layout = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(view) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Files") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(selected) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Selected") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(scroll) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Scroll") },
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

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const dir = dos.rdargs.string(argv[arg_dir]) orelse "SYS:c";
    const multi = argv[arg_multi] != 0;

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // The hook that draws a line draws it itself, so it needs graphics.
    const gfx_lib = sys.OpenLibrary(sdk.graphics.GRAPHICSNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{sdk.graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(gfx_lib);
    var draw_hook = sdk.utility.Hook{ .entry = &drawEntry, .data = gfx_lib };

    // The class libraries, open for as long as their objects are there.
    const wanted = [_][*:0]const u8{ lv.LISTVIEW_LIBRARY, st.STRING_LIBRARY, sr.SCROLLER_LIBRARY };
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

    const shown = build(ib, &list, &draw_hook, multi) orelse {
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
                        const line = code & ~lv.LISTVIEW_DOUBLE;
                        const picked = lv.nodeAt(&list, line) orelse continue;
                        const name: [*:0]const u8 = picked.name orelse "";
                        if (code & lv.LISTVIEW_DOUBLE != 0)
                            _ = Printf(dl, MSG_DOUBLE, .{ @as(u64, line), name })
                        else
                            _ = Printf(dl, MSG_LINE, .{ @as(u64, line), name });
                        // With several at once, the rest of them follow.
                        var chosen: usize = 0;
                        _ = ib.GetAttr(lv.LISTVIEW_SelectedArray, shown.list, &chosen);
                        if (chosen != 0) {
                            const bits: *const lv.LVSelected = @ptrFromInt(chosen);
                            var at: u32 = 0;
                            while (at < bits.count) : (at += 1) {
                                if (at == line or !bits.has(at)) continue;
                                const node_at = lv.nodeAt(&list, at) orelse continue;
                                _ = Printf(dl, MSG_ALSO, .{ @as(u64, at), node_at.name orelse "" });
                            }
                        }
                        // The list writes the name into the field itself.
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
}
