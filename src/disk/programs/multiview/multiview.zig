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
//! `PUBSCREEN` names a screen other than the default. A file dragged from
//! the desktop and let go on the window is shown in place of the one
//! there, in a window where the last one was. Space pauses what the
//! object holds, or goes on with it, when the object says it can be
//! (`STM_PAUSE` among its trigger methods).
//!
//! **A link is followed.** A press on a link in a page of text - the
//! object says which (`TDTA_Link`) - shows where it leads in place of
//! the page, in a window where the last one was and as large: another
//! file, read from the drawer the page is in, or a page on the web; a
//! link to a place on the page scrolls there (`DTM_GOTO`), and one to a
//! place on another page shows that page there. Backspace goes back the
//! way the links came, to where each page was left. FILE may itself be
//! an address on the web, `http://` or `https://`. A page on the web is
//! fetched whole through http.library and shown from memory, and the
//! network is opened for the first one and not before (fetch.zig); where
//! a link leads is links.zig's.
//!
//! **MultiView knows no formats.** Everything it shows it shows by
//! opening the object and adding it to a window; a new kind of file is a
//! new class and a new descriptor, and this program does not change. A
//! page fetched from the web comes without a file's name, and its class
//! knows it by what it holds.
//!
//! The bars are the window object's (`WINDOWA_VertScroller`,
//! `WINDOWA_HorizScroller`), made with the program's tags: their
//! `ICA_TARGET` is a model whose one connection is to the object, and an
//! `ICA_MAP` turns `SCROLLER_Top` into `DTA_TopVert` and `DTA_TopHoriz`,
//! so dragging one moves the view without the program hearing anything.
//! What the program does is read back how much there is and how much of
//! it is seen - once the window is open, and each time the object says it
//! has laid itself out - and tell the bars.

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
const sr = sdk.gadgets.scroller;
const asl = sdk.asl;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const tdc = datatypes.textclass;
const links = @import("links.zig");
const fetch = @import("fetch.zig");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const AslBase = sdk.interface.asl.AslBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "MultiView";
const VERSION = "1.5";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (10.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while one of its windows is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

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
/// The object's, so that a press let go on it is told from the bars'.
const ID_OBJECT = 3;

/// The key that goes back.
const KEY_BACK = 8;

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

/// What a bar tells the model as it moves. Its GA_ID goes no further:
/// the object would take it for its own.
const vert_map = [_]TagItem{
    .{ .tag = sr.SCROLLER_Top, .data = dtc.DTA_TopVert },
    .{ .tag = gc.GA_ID, .data = utility.TAG_IGNORE },
    .{},
};
const horiz_map = [_]TagItem{
    .{ .tag = sr.SCROLLER_Top, .data = dtc.DTA_TopHoriz },
    .{ .tag = gc.GA_ID, .data = utility.TAG_IGNORE },
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
/// The bars are not in it: they live in the borders, and are the window
/// object's.
fn build(ib: *IntuitionBase, object: *Object) ?*Object {
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(object) },
        .{},
    });
}

/// The two bars, the window object's; either is null when it could not
/// be made, and the window does without it.
const Bars = struct { vert: ?*Object, horiz: ?*Object };

/// One of the window's numbers.
fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, attr: utility.Tag) i32 {
    var value: usize = 0;
    const wanted = [_]TagItem{ .{ .tag = attr, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(window, &wanted);
    return @truncate(@as(isize, @bitCast(value)));
}

/// The model the bars are joined to the object through, its one
/// connection made: to the object, carrying where a view starts. A bar
/// dragged moves the object through it, in the task that is handling the
/// press, without this program hearing anything. Made before the window
/// object, whose bars are made with it as their target.
///
/// The other direction is not wired this way. What the object works out
/// when it is laid out is worked out on a process of its own, and that
/// process must draw nothing: the window it was told about may not be
/// there any more by the time it finishes. A bar set from there would
/// draw itself, through that window, and take its layer to do it. So the
/// object tells this program instead, and this program - which owns the
/// window and knows it is still open - puts the numbers into the bars.
fn connect(ib: *IntuitionBase, object: *Object) ?*Object {
    // Its own target is this program, so that what the object says about
    // a finished layout arrives as an IDCMP message.
    const model = ib.NewObjectTagList(null, classusr.MODELCLASS, &[_]TagItem{
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{},
    }) orelse return null;
    const ic = ib.NewObjectTagList(null, classusr.ICCLASS, &[_]TagItem{
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(object) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&to_object_map) },
        .{},
    }) orelse {
        ib.DisposeObject(model);
        return null;
    };
    var joining = classusr.OpMember{ .method_id = classusr.OM_ADDMEMBER, .object = ic };
    _ = ib.SendMessage(model, @ptrCast(&joining));
    return model;
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
    const pairs = [_]struct { bar: ?*Object, total: utility.Tag, visible: utility.Tag, top: utility.Tag }{
        .{ .bar = shown.vert, .total = dtc.DTA_TotalVert, .visible = dtc.DTA_VisibleVert, .top = dtc.DTA_TopVert },
        .{ .bar = shown.horiz, .total = dtc.DTA_TotalHoriz, .visible = dtc.DTA_VisibleHoriz, .top = dtc.DTA_TopHoriz },
    };
    for (pairs) |pair| {
        const bar = pair.bar orelse continue;
        _ = ib.SetGadgetAttrsTagList(bar, window, &[_]TagItem{
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

    const utility_lib = sys.OpenLibrary(utility.UTILITYNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{utility.UTILITYNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(utility_lib);
    const ub: *UtilityBase = @ptrCast(utility_lib);

    const screen_name: ?[*:0]const u8 = @ptrFromInt(argv[arg_pubscreen]);
    const screen = ib.LockPubScreen(screen_name) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    // The pages shown and the way back through them, which are larger
    // than a stack is to be asked for.
    const session: *Session = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(Session), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }));
    defer sys.FreeVec(session);
    // Cleared, it is a session with nothing shown yet and no network.
    session.web.sys = sys;
    defer session.web.close();

    const shown = Shown{ .sys = sys, .dl = dl, .ib = ib, .dt = dt, .ub = ub, .screen = screen, .scale = argv[arg_scale] != 0, .session = session };

    // The clipboard, or a file or a page on the web - named, or asked
    // for.
    var unit_name: [8]u8 = @splat(0);
    var chosen: [264]u8 = @splat(0);
    var object: *Object = undefined;
    if (argv[arg_clip] != 0) {
        const unit: *const i32 = @ptrFromInt(argv[arg_clip]);
        const name = writeNumber(&unit_name, @max(unit.*, 0));
        object = makeObject(dl, dt, name, dtc.DTST_CLIPBOARD, shown.scale) orelse {
            var why: [128]u8 = @splat(0);
            _ = Printf(dl, MSG_NOOBJECT, .{ name, faultText(dl, &why) });
            return dos.RETURN_FAIL;
        };
    } else {
        const name = fileWanted(al, @ptrFromInt(argv[arg_file]), &chosen) orelse return dos.RETURN_WARN;
        var length: usize = 0;
        while (name[length] != 0) length += 1;
        if (!session.next.take(name[0..length])) {
            _ = Printf(dl, MSG_NOOBJECT, .{ name, "the name is too long" });
            return dos.RETURN_FAIL;
        }
        object = shown.load(&session.next) orelse {
            if (session.next.web) {
                _ = Printf(dl, MSG_NOOBJECT, .{ name, @as([*:0]const u8, @ptrCast(&session.web.why)) });
            } else {
                var why: [128]u8 = @splat(0);
                _ = Printf(dl, MSG_NOOBJECT, .{ name, faultText(dl, &why) });
            }
            return dos.RETURN_FAIL;
        };
        session.now = session.next;
    }
    var place: ?Place = null;
    while (true) {
        switch (shown.show(object, &place)) {
            .done => |code| return code,
            .next => |next| object = next,
        }
    }
}

/// A file or a clipboard unit opened as a data type object; null with
/// IoErr saying why.
fn makeObject(dl: *DosBase, dt: *DataTypesBase, name: [*:0]const u8, source: u32, scale: bool) ?*Object {
    // The window is titled with the file's own name, not the path it
    // was reached by: a drawer name that fills the title bar tells a
    // person nothing they did not just type. A class whose contents name
    // themselves - a page's title - says so instead.
    return dt.NewDTObjectA(@ptrCast(name), &[_]TagItem{
        .{ .tag = dtc.DTA_SourceType, .data = source },
        .{ .tag = dtc.DTA_Title, .data = @intFromPtr(dl.FilePart(name)) },
        .{ .tag = gc.GA_ID, .data = ID_OBJECT },
        // The object lays itself out on a process of its own, so the
        // numbers the bars need are not right until it says so. It says
        // so as an IDCMP message, which is the only way a program hears
        // from a gadget it did not ask anything of.
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = if (scale) pic.PDTA_Scale else utility.TAG_IGNORE, .data = 1 },
        // An animation plays as soon as it is shown; anything else
        // passes this by.
        .{ .tag = dtc.DTA_Immediate, .data = 1 },
        .{},
    });
}

/// Bytes fetched from the web opened as a data type object: without a
/// file's name, so that what they hold says what they are, and titled
/// with their address until they name themselves.
fn memoryObject(dt: *DataTypesBase, bytes: []const u8, address: [*:0]const u8, scale: bool) ?*Object {
    return dt.NewDTObjectA(null, &[_]TagItem{
        .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_MEMORY },
        .{ .tag = dtc.DTA_Handle, .data = @intFromPtr(bytes.ptr) },
        .{ .tag = dtc.DTA_SourceSize, .data = bytes.len },
        .{ .tag = dtc.DTA_Title, .data = @intFromPtr(address) },
        .{ .tag = gc.GA_ID, .data = ID_OBJECT },
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = if (scale) pic.PDTA_Scale else utility.TAG_IGNORE, .data = 1 },
        .{ .tag = dtc.DTA_Immediate, .data = 1 },
        .{},
    });
}

/// Where the window was, for the next one, and how large when the next
/// is a link's page, which takes the size it was read at.
const Place = struct { left: i32, top: i32, width: i32 = 0, height: i32 = 0 };

/// What showing an object came to: the program done, with its return
/// code, or another object to show in its place.
const Outcome = union(enum) { done: i32, next: *Object };

/// How many pages back are kept.
const back_most = 16;
/// The longest name of a place on a page that is gone to.
const place_most = 255;

/// A page left by a link: where it came from, and how far down it was.
const Visit = struct { where: links.Location, top: i32 };

/// What is done once a page shown is laid out.
const Arrival = enum { none, place, top };

/// The pages a window shows, and the way back through them.
const Session = struct {
    /// The page shown, and the next one, while it is being opened.
    now: links.Location = .{},
    next: links.Location = .{},
    /// The pages left, the last the most recent.
    back: [back_most]Visit = undefined,
    back_count: usize = 0,
    /// Where on the page being shown it is to be: a place's name, or a
    /// top it was left at.
    arrival: Arrival = .none,
    arrive_place: [place_most + 1]u8 = @splat(0),
    arrive_top: i32 = 0,
    web: fetch.Web,

    /// The page shown remembered, `top` down, before another is gone to;
    /// the oldest forgotten when there are as many as are kept.
    fn remember(session: *Session, top: i32) void {
        if (session.back_count == back_most) {
            for (0..back_most - 1) |k| session.back[k] = session.back[k + 1];
            session.back_count -= 1;
        }
        session.back[session.back_count] = .{ .where = session.now, .top = top };
        session.back_count += 1;
    }

    /// The place on the next page to be gone to once it is laid out.
    fn arriveAt(session: *Session, place: []const u8) void {
        if (place.len == 0 or place.len > place_most) {
            session.arrival = .none;
            return;
        }
        @memcpy(session.arrive_place[0..place.len], place);
        session.arrive_place[place.len] = 0;
        session.arrival = .place;
    }
};

/// What every window is shown with.
const Shown = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    dt: *DataTypesBase,
    ub: *UtilityBase,
    screen: *intuition.Screen,
    scale: bool,
    session: *Session,

    /// `object` in a window - where the last one was, when there was one
    /// - until the window is closed, or a link pressed or a file dropped
    /// on it leads to something to be shown instead. The object is the
    /// window's from here on.
    fn show(shown: *const Shown, object: *Object, place: *?Place) Outcome {
        const ib = shown.ib;
        const dl = shown.dl;
        const dt = shown.dt;
        // From here on the object is the layout's child, and a layout
        // disposes of what is in it: this program disposes of the object
        // itself only while it is still in no layout.
        const layout = build(ib, object) orelse {
            dt.DisposeDTObject(object);
            _ = Printf(dl, MSG_NOMEMORY, .{});
            return .{ .done = dos.RETURN_FAIL };
        };

        var title_storage: usize = 0;
        _ = ib.GetAttr(dtc.DTA_Title, object, &title_storage);
        const named: [*:0]const u8 = if (title_storage != 0) @ptrFromInt(title_storage) else "MultiView";
        // A picture too large to hold whole is kept smaller, and the title
        // says so: a picture silently shown at half its size would have a
        // person measuring the wrong thing.
        var titled: [320]u8 = @splat(0);
        const title = withShrink(ib, object, named, &titled);

        // Made before the window object, whose bars are made with it as
        // their target; disposed of after it, so no bar is ever left
        // pointing at nothing.
        const model = connect(ib, object) orelse {
            ib.DisposeObject(layout); // and the object in it
            _ = Printf(dl, MSG_NOMEMORY, .{});
            return .{ .done = dos.RETURN_FAIL };
        };
        defer ib.DisposeObject(model); // and the connection in it
        const vert_bar = [_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_VERT },
            .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(model) },
            .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&vert_map) },
            .{},
        };
        const horiz_bar = [_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_HORIZ },
            .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(model) },
            .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&horiz_map) },
            .{},
        };

        const at = place.*;
        const sized = if (at) |p| p.width > 0 and p.height > 0 else false;
        const window_object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            .{ .tag = wn.WA_Title, .data = @intFromPtr(title) },
            .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
            .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(shown.screen) },
            .{ .tag = if (at != null) wn.WA_Left else utility.TAG_IGNORE, .data = if (at) |p| @bitCast(@as(isize, p.left)) else 0 },
            .{ .tag = if (at != null) wn.WA_Top else utility.TAG_IGNORE, .data = if (at) |p| @bitCast(@as(isize, p.top)) else 0 },
            .{ .tag = if (sized) wn.WA_Width else utility.TAG_IGNORE, .data = if (at) |p| @bitCast(@as(isize, p.width)) else 0 },
            .{ .tag = if (sized) wn.WA_Height else utility.TAG_IGNORE, .data = if (at) |p| @bitCast(@as(isize, p.height)) else 0 },
            // A larger object than the last is moved in from the edge
            // rather than not shown.
            .{ .tag = wn.WA_AutoAdjust, .data = 1 },
            .{ .tag = wn.WA_CloseGadget, .data = 1 },
            .{ .tag = wn.WA_DragBar, .data = 1 },
            .{ .tag = wn.WA_DepthGadget, .data = 1 },
            .{ .tag = wn.WA_SizeGadget, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE },
            .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
            .{ .tag = wc.WINDOWA_VertScroller, .data = @intFromPtr(&vert_bar) },
            .{ .tag = wc.WINDOWA_HorizScroller, .data = @intFromPtr(&horiz_bar) },
            .{},
        }) orelse {
            ib.DisposeObject(layout); // and the object in it
            _ = Printf(dl, MSG_NOMEMORY, .{});
            return .{ .done = dos.RETURN_FAIL };
        };
        // The window, and with it the layout, the bars and the object: a
        // layout disposes of what is in it, and a data type object gives
        // its kind back when it goes, so this is the whole of it.
        defer ib.DisposeObject(window_object);

        var open = wc.WmOpen{};
        if (ib.SendMessage(window_object, @ptrCast(&open)) == 0) {
            _ = Printf(dl, MSG_NOWINDOW, .{});
            return .{ .done = dos.RETURN_FAIL };
        }
        var window_ptr: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_Window, window_object, &window_ptr);
        const window: *intuition.Window = @ptrFromInt(window_ptr);
        var vert: usize = 0;
        var horiz: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_VertScroller, window_object, &vert);
        _ = ib.GetAttr(wc.WINDOWA_HorizScroller, window_object, &horiz);
        const made = Bars{ .vert = @ptrFromInt(vert), .horiz = @ptrFromInt(horiz) };
        // Where the window was, for the next one, while it is still open:
        // and as large, for a page a link led to.
        var keep_size = false;
        defer place.* = .{
            .left = windowAttr(ib, window, wn.WA_Left),
            .top = windowAttr(ib, window, wn.WA_Top),
            .width = if (keep_size) windowAttr(ib, window, wn.WA_Width) else 0,
            .height = if (keep_size) windowAttr(ib, window, wn.WA_Height) else 0,
        };
        // Files let go on the window, while the desktop runs; taken off
        // its list before the window closes.
        var target: sdk.anvil.DropTarget = .{};
        target.add(shown.sys, window);
        defer target.remove();
        // What the object already knows, put into the bars. From here on
        // each IDCMPUPDATE puts in what its new layout worked out.
        followObject(ib, made, object, window);

        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        while (true) {
            const got = ib.WaitIMsg(window, target.signal() | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0) return .{ .done = dos.RETURN_WARN };
            if (got & target.signal() != 0) {
                if (shown.dropped(&target, window, object)) |next| return .{ .next = next };
            }
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
                    wc.WMHI_CLOSEWINDOW => return .{ .done = dos.RETURN_OK },
                    // The object finished laying itself out on a process of
                    // its own: its numbers are right only now, and what is
                    // on the screen was drawn from the layout before it.
                    wc.WMHI_IDCMPUPDATE => draw = true,
                    // A press let go on the object: on a link, it is
                    // followed.
                    wc.WMHI_GADGETUP => if (word & wc.WMHI_GADGETMASK == ID_OBJECT) {
                        if (shown.follow(object, window)) |next| {
                            keep_size = true;
                            return .{ .next = next };
                        }
                    },
                    wc.WMHI_VANILLAKEY => switch (word & wc.WMHI_KEYMASK) {
                        27 => return .{ .done = dos.RETURN_OK },
                        ' ' => pause(dt, object, window),
                        KEY_BACK => if (shown.goBack(object, window, made)) |next| {
                            keep_size = true;
                            return .{ .next = next };
                        },
                        else => {},
                    },
                    else => {},
                }
            }
            if (draw) {
                // A page that is to be shown somewhere down is put there
                // once it has been laid out for the window: not before,
                // as where anything is is not known until then.
                if (shown.session.arrival != .none and laidOut(ib, object)) shown.arrive(object, window);
                followObject(ib, made, object, window);
                dt.RefreshDTObjectA(object, window, null, null);
            }
        }
    }

    /// The page at `where` opened: a file, or a page fetched from the
    /// web, after which `where` names where it came from. Null when it
    /// could not be.
    fn load(shown: *const Shown, where: *links.Location) ?*Object {
        if (!where.web) return makeObject(shown.dl, shown.dt, where.name(), dtc.DTST_FILE, shown.scale);
        const bytes = shown.session.web.fetch(shown.dl, where) orelse return null;
        defer shown.sys.FreeVec(bytes.ptr);
        return memoryObject(shown.dt, bytes, where.name(), shown.scale);
    }

    /// The page at `where` opened while the window waits, with the busy
    /// pointer up; the screen flashed when it could not be.
    fn loadWaiting(shown: *const Shown, window: *intuition.Window, where: *links.Location) ?*Object {
        shown.ib.SetWindowPointerA(window, &[_]TagItem{ .{ .tag = wn.WA_BusyPointer, .data = 1 }, .{} });
        const made = shown.load(where);
        if (made == null) {
            shown.ib.SetWindowPointerA(window, null);
            shown.ib.DisplayBeep(shown.screen);
        }
        return made;
    }

    /// The link the press was let go on followed: a place on this page
    /// scrolled to, or the page it leads to opened, to be shown in place
    /// of this one.
    fn follow(shown: *const Shown, object: *Object, window: *intuition.Window) ?*Object {
        const session = shown.session;
        var storage: usize = 0;
        if (shown.ib.GetAttr(tdc.TDTA_Link, object, &storage) == 0 or storage == 0) return null;
        const pressed: [*:0]const u8 = @ptrFromInt(storage);
        var length: usize = 0;
        while (pressed[length] != 0) length += 1;
        if (length == 0) return null;
        const top = ask(shown.ib, object, dtc.DTA_TopVert);
        switch (links.resolve(shown.ub, &session.now, pressed[0..length], &session.next)) {
            .nowhere => shown.ib.DisplayBeep(shown.screen),
            .here => |name| {
                var goto_name: [place_most + 1]u8 = @splat(0);
                if (name.len > place_most) {
                    shown.ib.DisplayBeep(shown.screen);
                    return null;
                }
                @memcpy(goto_name[0..name.len], name);
                session.remember(top);
                var goto = dtc.DtGoto{ .node_name = @ptrCast(&goto_name) };
                if (shown.dt.DoDTMethodA(object, window, null, @ptrCast(&goto)) == 0) {
                    session.back_count -= 1;
                    shown.ib.DisplayBeep(shown.screen);
                }
            },
            .page => |name| {
                // The place's name is the old object's, which goes with
                // the window: kept before the next page is opened.
                session.arriveAt(name);
                const next = shown.loadWaiting(window, &session.next) orelse {
                    session.arrival = .none;
                    return null;
                };
                session.remember(top);
                session.now = session.next;
                return next;
            },
        }
        return null;
    }

    /// Back where the last link was pressed: on this page, scrolled there;
    /// on another, that page opened, to be shown where it was left.
    fn goBack(shown: *const Shown, object: *Object, window: *intuition.Window, bars: Bars) ?*Object {
        const session = shown.session;
        if (session.back_count == 0) {
            shown.ib.DisplayBeep(shown.screen);
            return null;
        }
        const visit = &session.back[session.back_count - 1];
        if (visit.where.same(&session.now)) {
            session.back_count -= 1;
            scrollTo(shown.ib, object, window, visit.top);
            followObject(shown.ib, bars, object, window);
            shown.dt.RefreshDTObjectA(object, window, null, null);
            return null;
        }
        session.next = visit.where;
        const next = shown.loadWaiting(window, &session.next) orelse return null;
        session.back_count -= 1;
        session.now = session.next;
        session.arrival = .top;
        session.arrive_top = visit.top;
        return next;
    }

    /// The page just laid out put where it is to be: at a place on it, or
    /// as far down as it was left.
    fn arrive(shown: *const Shown, object: *Object, window: *intuition.Window) void {
        const session = shown.session;
        switch (session.arrival) {
            .none => {},
            .place => {
                var goto = dtc.DtGoto{ .node_name = @ptrCast(&session.arrive_place) };
                _ = shown.dt.DoDTMethodA(object, window, null, @ptrCast(&goto));
            },
            .top => scrollTo(shown.ib, object, window, session.arrive_top),
        }
        session.arrival = .none;
    }

    /// The last file let go on the window opened as an object; null, and
    /// the screen flashed, when none of them could be. It is gone to as a
    /// link is: Backspace comes back.
    fn dropped(shown: *const Shown, target: *sdk.anvil.DropTarget, window: *intuition.Window, object: *Object) ?*Object {
        const session = shown.session;
        var name: [dos.path_max + 1]u8 = undefined;
        var next: ?*Object = null;
        while (target.next(shown.dl, &name)) |file| {
            if (file.is_drawer) continue;
            const made = makeObject(shown.dl, shown.dt, file.name, dtc.DTST_FILE, shown.scale) orelse {
                shown.ib.DisplayBeep(shown.screen);
                continue;
            };
            if (next) |earlier| shown.dt.DisposeDTObject(earlier);
            next = made;
            var length: usize = 0;
            while (file.name[length] != 0) length += 1;
            if (!session.next.take(file.name[0..length])) session.next = .{};
        }
        if (next != null) {
            session.remember(ask(shown.ib, object, dtc.DTA_TopVert));
            session.now = session.next;
            session.arrival = .none;
            shown.ib.ActivateWindow(window);
        }
        return next;
    }
};

/// Whether the object has been laid out for its window: no process is
/// laying it out any more.
fn laidOut(ib: *IntuitionBase, object: *Object) bool {
    var process: usize = 0;
    _ = ib.GetAttr(dtc.DTA_LayoutProc, object, &process);
    return process == 0;
}

/// The object's view moved to start `top` down.
fn scrollTo(ib: *IntuitionBase, object: *Object, window: *intuition.Window, top: i32) void {
    _ = ib.SetGadgetAttrsTagList(object, window, &[_]TagItem{
        .{ .tag = dtc.DTA_TopVert, .data = @bitCast(@as(isize, top)) },
        .{},
    });
}

/// What the object holds paused, or gone on with, if it lists `STM_PAUSE`
/// among what it can be told to do: a program offers what the object
/// says, not what it guesses from the kind of file.
fn pause(dt: *DataTypesBase, object: *Object, window: *intuition.Window) void {
    const methods = dt.GetDTTriggerMethods(object) orelse return;
    var k: usize = 0;
    while (methods[k].label != null) : (k += 1) {
        if (methods[k].method != dtc.STM_PAUSE) continue;
        var trigger = dtc.DtTrigger{ .function = dtc.STM_PAUSE };
        _ = dt.DoDTMethodA(object, window, null, @ptrCast(&trigger));
        return;
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
