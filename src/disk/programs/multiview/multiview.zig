// SPDX-License-Identifier: MIT
//! MultiView: a window round any data type object. Built against the SDK
//! only.
//!
//!   MultiView [FILE] [CLIP/K/N] [SCALE/S] [PUBSCREEN/K]
//!
//! It opens the named file through datatypes.library, which decides from
//! the file's own contents what class reads it, and puts the object that
//! comes back in a window with a scroll bar on the right and one below.
//! Without a name it asks for one with a file requester. `CLIP` takes
//! the contents of a clipboard unit instead of a file, `SCALE` shows a
//! picture at the size of the window rather than its own, and
//! `PUBSCREEN` names a screen other than the default.
//!
//! **MultiView knows no formats.** Everything it shows it shows by
//! opening the object and adding it to a window; a new kind of file is a
//! new class and a new descriptor, and this program does not change.
//!
//! The bars are the object's `ICA_TARGET`, and an `ICA_MAP` turns
//! `SCROLLER_Top` into `DTA_TopVert` and `DTA_TopHoriz`, so dragging one
//! moves the view without the program hearing anything. What the program
//! does is read back how much there is and how much of it is seen -
//! after the window opens and after every resize - and tell the bars.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const icc = intuition.icclass;
const classusr = intuition.classusr;
const pg = intuition.propgclass;
const sr = sdk.gadgets.scroller;
const asl = sdk.asl;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const AslBase = sdk.interface.asl.AslBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "MultiView";
const VERSION_STRING = "\x00$VER: MultiView 1.0 (29.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE,CLIP/K/N,SCALE/S,PUBSCREEN/K";
const arg_file = 0;
const arg_clip = 1;
const arg_scale = 2;
const arg_pubscreen = 3;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No screen - no display\n";
const MSG_NOMEMORY = "No memory for the window\n";
const MSG_NOWINDOW = "No window\n";
const MSG_NOOBJECT = "%s: %s\n";

const ID_VERT = 1;
const ID_HORIZ = 2;

// --- what is connected to what ------------------------------------------------
//
// The object and the two bars are joined through a model, and not by
// this program. A bar moving tells the model where its view now starts;
// the model tells the object, which scrolls. The object finishing a
// layout tells the model how much there is and how much of it is seen;
// the model tells the bars, which take their size and place from it.
// Each connection carries only the attributes it names, so the vertical
// bar never hears the horizontal one's numbers.
//
// None of that passes through this program, which is the point: it goes
// on inside the objects, in one task, without a message. What the
// program is told is that a layout has finished, which is the one thing
// only it can answer - by drawing the object again.

/// What a bar tells the model as it moves.
const vert_map = [_]TagItem{
    .{ .tag = sr.SCROLLER_Top, .data = dtc.DTA_TopVert },
    .{},
};
const horiz_map = [_]TagItem{
    .{ .tag = sr.SCROLLER_Top, .data = dtc.DTA_TopHoriz },
    .{},
};

/// What the model tells the object: where a view starts, and nothing
/// else - the totals are the object's own to work out.
const to_object_map = [_]TagItem{
    .{ .tag = dtc.DTA_TopVert, .data = dtc.DTA_TopVert },
    .{ .tag = dtc.DTA_TopHoriz, .data = dtc.DTA_TopHoriz },
    .{},
};

/// The object in a layout, which fills the part of the window inside
/// the border.
///
/// The bars are not in it: they live in the border itself, and are made
/// once the window is open and how deep its borders came out is known.
fn build(ib: *IntuitionBase, object: *Object) ?*Object {
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(object) },
        .{},
    });
}

/// The two bars and the model that joins them to the object.
const Bars = struct {
    vert: *Object,
    horiz: *Object,
    /// Disposing of it disposes of the connections in it.
    model: *Object,
};

/// One of the window's numbers.
fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, attr: utility.Tag) i32 {
    var value: usize = 0;
    const wanted = [_]TagItem{ .{ .tag = attr, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(window, &wanted);
    return @truncate(@as(isize, @bitCast(value)));
}

/// A bar down the right border and one along the bottom one.
///
/// Each fills its border but for the frame's outer line, and reaches
/// from the far edge of the window to the sizing gadget in the corner,
/// which is why the window is opened with the sizing gadget in both
/// borders. Each is placed from the edge it sits at, so that it stays
/// there and keeps that length as the window is resized, and its arrow
/// buttons are as long as the bar is wide, which makes them square.
fn bars(ib: *IntuitionBase, window: *intuition.Window, object: *Object) ?Bars {
    // The model is made first, because the bars are connected to it as
    // they are made. Its own target is this program, so that what the
    // object says about a finished layout arrives as an IDCMP message.
    const model = ib.NewObjectTagList(null, classusr.MODELCLASS, &[_]TagItem{
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{},
    }) orelse return null;

    const left: isize = windowAttr(ib, window, wn.WA_BorderLeft);
    const top: isize = windowAttr(ib, window, wn.WA_BorderTop);
    const right: isize = windowAttr(ib, window, wn.WA_BorderRight);
    const bottom: isize = windowAttr(ib, window, wn.WA_BorderBottom);
    // The whole depth of the border, out to its last column: what sits
    // there is the bar's to draw, and the bar puts a gap of its own at
    // each side so that the border still shows round it.
    const across = right;
    const deep = bottom;
    // How far an arrow reaches along its bar. It is not the bar's own
    // thickness: the two arrows of a bar that runs across are drawn
    // longer than the two of one that runs down, by half again, and
    // both are drawn to the height of the bar along the bottom - which
    // is the title bar's height, and so the one thing both bars can be
    // measured in.
    const arrow_down = deep;
    const arrow_along = @divTrunc(deep * 16, 11);

    const vert = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_VERT },
        .{ .tag = gc.GA_RightBorder, .data = 1 },
        .{ .tag = gc.GA_RelRight, .data = @bitCast(-(across - 1)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(top) },
        .{ .tag = gc.GA_Width, .data = @bitCast(across) },
        .{ .tag = gc.GA_RelHeight, .data = @bitCast(-(top + bottom)) },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
        .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(arrow_down) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(model) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&vert_map) },
        .{},
    }) orelse {
        ib.DisposeObject(model);
        return null;
    };
    const horiz = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_HORIZ },
        .{ .tag = gc.GA_BottomBorder, .data = 1 },
        .{ .tag = gc.GA_Left, .data = @bitCast(left) },
        .{ .tag = gc.GA_RelBottom, .data = @bitCast(-(deep - 1)) },
        .{ .tag = gc.GA_RelWidth, .data = @bitCast(-(left + right)) },
        .{ .tag = gc.GA_Height, .data = @bitCast(deep) },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(arrow_along) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(model) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&horiz_map) },
        .{},
    }) orelse {
        ib.DisposeObject(model);
        ib.DisposeObject(vert);
        return null;
    };
    // The one connection out of the model: to the object, carrying
    // where a view starts. A bar dragged moves the object through it,
    // in the task that is handling the press, without this program
    // hearing anything.
    //
    // The other direction is not wired this way. What the object works
    // out when it is laid out is worked out on a process of its own,
    // and that process must draw nothing: the window it was told about
    // may not be there any more by the time it finishes. A bar set from
    // there would draw itself, through that window, and take its layer
    // to do it. So the object tells this program instead, and this
    // program - which owns the window and knows it is still open - puts
    // the numbers into the bars.
    const ic = ib.NewObjectTagList(null, classusr.ICCLASS, &[_]TagItem{
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(object) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&to_object_map) },
        .{},
    }) orelse {
        ib.DisposeObject(model);
        ib.DisposeObject(vert);
        ib.DisposeObject(horiz);
        return null;
    };
    var joining = classusr.OpMember{ .method_id = classusr.OM_ADDMEMBER, .object = ic };
    _ = ib.SendMessage(model, @ptrCast(&joining));

    _ = ib.AddGList(window, vert, -1, 1);
    _ = ib.AddGList(window, horiz, -1, 1);
    // A bar shorter than its own two arrow buttons has nothing left to
    // drag, so the window is not allowed to be made that small: each bar
    // keeps at least its arrows and as much again, and the interior at
    // least one row and column of the picture.
    _ = ib.WindowLimits(window, left + right + 4 * bottom, top + bottom + 4 * right, -1, -1);
    // A gadget in the border is drawn whenever the border is.
    ib.RefreshWindowFrame(window);
    return .{ .vert = vert, .horiz = horiz, .model = model };
}

/// One of the object's numbers.
fn ask(ib: *IntuitionBase, object: *Object, attr: utility.Tag) i32 {
    var storage: usize = 0;
    if (ib.GetAttr(attr, object, &storage) == 0) return 0;
    return @truncate(@as(isize, @bitCast(storage)));
}

/// The bars told how much there is and how much of it is seen, which is
/// what the object worked out when it was laid out.
fn followObject(ib: *IntuitionBase, shown: Bars, object: *Object, window: *intuition.Window) void {
    const pairs = [_]struct { bar: *Object, total: utility.Tag, visible: utility.Tag, top: utility.Tag }{
        .{ .bar = shown.vert, .total = dtc.DTA_TotalVert, .visible = dtc.DTA_VisibleVert, .top = dtc.DTA_TopVert },
        .{ .bar = shown.horiz, .total = dtc.DTA_TotalHoriz, .visible = dtc.DTA_VisibleHoriz, .top = dtc.DTA_TopHoriz },
    };
    for (pairs) |pair| {
        _ = ib.SetGadgetAttrsTagList(pair.bar, window, &[_]TagItem{
            .{ .tag = sr.SCROLLER_Total, .data = @bitCast(@as(isize, ask(ib, object, pair.total))) },
            .{ .tag = sr.SCROLLER_Visible, .data = @bitCast(@as(isize, ask(ib, object, pair.visible))) },
            .{ .tag = sr.SCROLLER_Top, .data = @bitCast(@as(isize, ask(ib, object, pair.top))) },
            .{},
        });
    }
}

/// The file to show: what the argument said, or what a requester was
/// asked for. The name is written into `into`.
fn fileWanted(al: *AslBase, given: ?[*:0]const u8, into: *[264]u8) ?[*:0]const u8 {
    if (given) |name| return name;
    const request = al.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
        .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr("Show which file?") },
        .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr("SYS:") },
        .{},
    }) orelse return null;
    defer al.FreeAslRequest(request);
    if (!al.AslRequest(request, null)) return null;
    const file: *asl.FileRequester = @ptrCast(@alignCast(request));
    const drawer = file.drawer orelse return null;
    const name = file.file orelse return null;
    var at: usize = 0;
    while (drawer[at] != 0 and at + 2 < into.len) : (at += 1) into[at] = drawer[at];
    if (at != 0 and into[at - 1] != ':' and into[at - 1] != '/') {
        into[at] = '/';
        at += 1;
    }
    var i: usize = 0;
    while (name[i] != 0 and at + 1 < into.len) : (i += 1) {
        into[at] = name[i];
        at += 1;
    }
    into[at] = 0;
    return @ptrCast(into);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    const dt_lib = sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{datatypes.DATATYPESNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(dt_lib);
    const dt: *DataTypesBase = @ptrCast(dt_lib);

    const asl_lib = sys.OpenLibrary(asl.ASLNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{asl.ASLNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(asl_lib);
    const al: *AslBase = @ptrCast(asl_lib);

    const scroller_lib = sys.OpenLibrary(sr.SCROLLER_LIBRARY, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{sr.SCROLLER_LIBRARY});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(scroller_lib);

    const screen_name: ?[*:0]const u8 = @ptrFromInt(argv[arg_pubscreen]);
    const screen = ib.LockPubScreen(screen_name) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    // The clipboard, or a file - named, or asked for.
    var unit_name: [8]u8 = @splat(0);
    var chosen: [264]u8 = @splat(0);
    var source: u32 = dtc.DTST_FILE;
    var name: ?[*:0]const u8 = null;
    if (argv[arg_clip] != 0) {
        const unit: *const i32 = @ptrFromInt(argv[arg_clip]);
        source = dtc.DTST_CLIPBOARD;
        name = writeNumber(&unit_name, @max(unit.*, 0));
    } else {
        name = fileWanted(al, @ptrFromInt(argv[arg_file]), &chosen) orelse return dos.RETURN_WARN;
    }
    const shown_name = name.?;

    // The window is titled with the file's own name, not the path it
    // was reached by: a drawer name that fills the title bar tells a
    // person nothing they did not just type.
    const object = dt.NewDTObjectA(@ptrCast(shown_name), &[_]TagItem{
        .{ .tag = dtc.DTA_SourceType, .data = source },
        .{ .tag = dtc.DTA_Title, .data = @intFromPtr(dl.FilePart(shown_name)) },
        // The object lays itself out on a process of its own, so the
        // numbers the bars need are not right until it says so. It says
        // so as an IDCMP message, which is the only way a program hears
        // from a gadget it did not ask anything of.
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = if (argv[arg_scale] != 0) pic.PDTA_Scale else utility.TAG_IGNORE, .data = 1 },
        // An animation plays as soon as it is shown; anything else
        // passes this by.
        .{ .tag = dtc.DTA_Immediate, .data = 1 },
        .{},
    }) orelse {
        var why: [128]u8 = @splat(0);
        _ = Printf(dl, MSG_NOOBJECT, .{ shown_name, faultText(dl, &why) });
        return dos.RETURN_FAIL;
    };
    // From here on the object is the layout's child, and a layout
    // disposes of what is in it: this program disposes of the object
    // itself only while it is still in no layout.
    const layout = build(ib, object) orelse {
        dt.DisposeDTObject(object);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };

    var title_storage: usize = 0;
    _ = ib.GetAttr(dtc.DTA_Title, object, &title_storage);
    const named: [*:0]const u8 = if (title_storage != 0) @ptrFromInt(title_storage) else shown_name;
    // A picture too large to hold whole is kept smaller, and the title
    // says so: a picture silently shown at half its size would have a
    // person measuring the wrong thing.
    var titled: [320]u8 = @splat(0);
    const title = withShrink(ib, object, named, &titled);

    const window_object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(title) },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        // The sizing gadget in both borders, so that the two bars each
        // have a border deep enough to sit in and stop short of it.
        .{ .tag = wn.WA_SizeBRight, .data = 1 },
        .{ .tag = wn.WA_SizeBBottom, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
        .{},
    }) orelse {
        ib.DisposeObject(layout); // and the object in it
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // The window, and with it the layout, the bars and the object: a
    // layout disposes of what is in it, and a data type object gives
    // its kind back when it goes, so this is the whole of it.
    defer ib.DisposeObject(window_object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(window_object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, window_object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);
    const made = bars(ib, window, object) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // The bars are this program's, not the window object's, and they are
    // in a window: it is closed first, which takes them out of it, and
    // the window object is left with nothing but itself to give back.
    defer {
        var shut = wc.WmClose{};
        _ = ib.SendMessage(window_object, @ptrCast(&shut));
        ib.DisposeObject(made.model); // and the connections in it
        ib.DisposeObject(made.vert);
        ib.DisposeObject(made.horiz);
    }
    // What the object already knows, put into the bars once. From here
    // on the model keeps them level with it.
    followObject(ib, made, object, window);

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        // Everything waiting is taken first and answered once.
        //
        // A resize on its own is nothing to this program: the object
        // lays itself out again because intuition told it to. What is
        // this program's is what the object reports when that has
        // finished - the numbers go into the bars and the object is
        // drawn again - and doing that once for a batch says as much as
        // doing it for every message in it, which, since each drawing
        // takes about as long as a step of a drag does, is what kept
        // the program behind the pointer instead of level with it.
        var draw = false;
        while (true) {
            const word = ib.SendMessage(window_object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                // The object finished laying itself out on a process of
                // its own: its numbers are right only now, and what is
                // on the screen was drawn from the layout before it.
                wc.WMHI_IDCMPUPDATE => draw = true,
                wc.WMHI_VANILLAKEY => if (word & wc.WMHI_KEYMASK == 27) return dos.RETURN_OK,
                else => {},
            }
        }
        if (draw) {
            followObject(ib, made, object, window);
            dt.RefreshDTObjectA(object, window, null, null);
        }
    }
}

/// What went wrong, in words. The library answers its own numbers for
/// what it could not do with a file, and dos's for everything else.
fn faultText(dl: *DosBase, into: *[128]u8) [*:0]const u8 {
    const said: [*:0]const u8 = switch (dl.IoErr()) {
        datatypes.DTERROR_UNKNOWN_DATATYPE => "there is no class for this kind of file",
        datatypes.DTERROR_COULDNT_OPEN => "it could not be opened",
        datatypes.DTERROR_COULDNT_OPEN_CLIPBOARD => "the clipboard could not be opened",
        datatypes.DTERROR_UNKNOWN_COMPRESSION => "it is packed in a way this system does not read",
        // What a class says when it asked for memory and did not get
        // it, which for a picture usually means it is larger than this
        // machine can hold.
        datatypes.DTERROR_TOO_LARGE => "it is larger than this machine can hold",
        datatypes.DTERROR_NOT_ENOUGH_DATA => "there is not enough memory for it, or it ends too soon",
        datatypes.DTERROR_INVALID_DATA => "it is not the kind of file it says it is",
        else => {
            _ = dl.Fault(dl.IoErr(), null, into, into.len);
            return @ptrCast(into);
        },
    };
    return said;
}

/// The name, and after it how much the picture was shrunk to fit, when
/// it was. The name alone for anything else.
fn withShrink(ib: *IntuitionBase, object: *Object, name: [*:0]const u8, into: *[320]u8) [*:0]const u8 {
    var by: usize = 1;
    if (ib.GetAttr(pic.PDTA_ShrunkBy, object, &by) == 0 or by <= 1) return name;
    var at: usize = 0;
    while (name[at] != 0 and at + 24 < into.len) : (at += 1) into[at] = name[at];
    const said = switch (by) {
        2 => " (half size)",
        4 => " (quarter size)",
        8 => " (eighth size)",
        else => " (smaller)",
    };
    for (said) |byte| {
        into[at] = byte;
        at += 1;
    }
    into[at] = 0;
    return @ptrCast(into);
}

/// The number as a string, for the clipboard unit a name stands for.
fn writeNumber(into: *[8]u8, value: i32) [*:0]const u8 {
    var digits: [8]u8 = undefined;
    var count: usize = 0;
    var left: u32 = @intCast(value);
    while (true) {
        digits[count] = '0' + @as(u8, @truncate(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..count) |i| into[i] = digits[count - 1 - i];
    into[count] = 0;
    return @ptrCast(into);
}
