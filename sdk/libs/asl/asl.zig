// SPDX-License-Identifier: MIT
//! asl.library: the requesters a program asks a question with - which
//! file, which font, which screen mode.
//!
//! A requester is made once with `AllocAslRequest`, put up as often as
//! wanted with `AslRequest`, and given back with `FreeAslRequest`. What
//! it was answered with is in the request structure, which belongs to the
//! library: it holds until the next `AslRequest` on that requester or
//! until it is freed, so a program that wants to keep an answer copies
//! it.
//!
//! The tags are read both by `AllocAslRequest`, which sets what the
//! requester starts as, and by `AslRequest`, which changes it for that
//! one showing.
//!
//!   const lib = sys.OpenLibrary(asl.ASLNAME, 0) orelse return;
//!   defer sys.CloseLibrary(lib);
//!   const ab: *AslBase = @ptrCast(lib);
//!   const req: *asl.FileRequester = @ptrCast(@alignCast(
//!       ab.AllocAslRequest(asl.ASL_FileRequest, &.{
//!           .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr("Open") },
//!           .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr("SYS:") },
//!           .{},
//!       }) orelse return));
//!   defer ab.FreeAslRequest(req);
//!   if (ab.AslRequest(req, null)) open(req.drawer, req.file);
//!
//! A requester remembers where it was, how big it was and what was typed
//! in it, so the next `AslRequest` on the same requester opens where the
//! one before it was left.

const utility = @import("../utility/utility.zig");
const dos = @import("../dos/dos.zig");
const graphics = @import("../graphics/graphics.zig");

/// The name to open it by.
pub const ASLNAME = "asl.library";

/// What `AllocAslRequest` is asked for.
pub const ASL_FileRequest: u32 = 0;
pub const ASL_FontRequest: u32 = 1;
pub const ASL_ScreenModeRequest: u32 = 2;

/// Where asl's tags begin.
pub const ASL_TB = utility.TAG_USER + 0x0008_0000;

/// One of the things a requester was answered with: the drawer it is in
/// and its name in that drawer. A name with no lock is a name on its own;
/// a lock with no name is the drawer itself.
///
/// The pair rather than a path is what a program is handed, because a
/// lock goes on naming the drawer while the requester's text of it may
/// not: the drawer can be renamed or the volume taken out from under it.
/// It is also the shape a Workbench hands a program its arguments in, so
/// a program that takes files from either reads them the one way.
///
/// The locks and the names are the library's: they hold until the next
/// `AslRequest` on that requester or until it is freed.
pub const WBArg = extern struct {
    lock: ?*dos.FileLock = null,
    name: ?[*:0]const u8 = null,
};

// --- the file requester -----------------------------------------------------

/// What a file requester was answered with. The library makes it and the
/// program reads it.
pub const FileRequester = extern struct {
    /// The name in the File field, empty when none was given.
    file: ?[*:0]u8 = null,
    /// The drawer the File field's name is in.
    drawer: ?[*:0]u8 = null,
    /// The Pattern field, with `ASLFR_DoPatterns`.
    pattern: ?[*:0]u8 = null,
    /// Where the requester was and how big, when it was answered.
    left_edge: i32 = 0,
    top_edge: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// With `ASLFR_DoMultiSelect`: how many names were picked and which.
    /// 0 with no multi-select, where `file` and `drawer` are the answer.
    num_args: i32 = 0,
    arg_list: ?[*]WBArg = null,
    /// `ASLFR_UserData`, kept for the program.
    user_data: usize = 0,
};

// Window control.
/// The window the requester belongs to; it opens on that window's screen.
pub const ASLFR_Window = ASL_TB + 2;
/// The screen to open on, when no window is given.
pub const ASLFR_Screen = ASL_TB + 40;
/// The public screen to open on, by name.
pub const ASLFR_PubScreenName = ASL_TB + 41;
/// Bool: the parent window takes no input while the requester is up.
pub const ASLFR_SleepWindow = ASL_TB + 43;
/// A `*utility.Hook` called with every message the requester does not
/// want itself, so the program's window can go on drawing.
pub const ASLFR_IntuiMsgFunc = ASL_TB + 70;
/// What `user_data` is set to.
pub const ASLFR_UserData = ASL_TB + 52;

// The words on it.
/// A `*graphics.TextAttr` for the requester's own text.
pub const ASLFR_TextAttr = ASL_TB + 51;
/// The requester's title.
pub const ASLFR_TitleText = ASL_TB + 1;
/// The word on the button that answers it; `Open` unless given.
pub const ASLFR_PositiveText = ASL_TB + 18;
/// The word on the button that gives it up; `Cancel` unless given.
pub const ASLFR_NegativeText = ASL_TB + 19;

// What it starts as.
pub const ASLFR_InitialLeftEdge = ASL_TB + 3;
pub const ASLFR_InitialTopEdge = ASL_TB + 4;
pub const ASLFR_InitialWidth = ASL_TB + 5;
pub const ASLFR_InitialHeight = ASL_TB + 6;
/// What the File field starts with.
pub const ASLFR_InitialFile = ASL_TB + 8;
/// What the Drawer field starts with.
pub const ASLFR_InitialDrawer = ASL_TB + 9;
/// What the Pattern field starts with.
pub const ASLFR_InitialPattern = ASL_TB + 10;

// What it does.
/// `FRF_*` all at once, in place of the bools below.
pub const ASLFR_Flags1 = ASL_TB + 20;
/// `FRF2_*` all at once.
pub const ASLFR_Flags2 = ASL_TB + 22;
/// Bool: a name that is not there is an answer, and one that is asks
/// before it is taken - the requester is for saving, not for opening.
pub const ASLFR_DoSaveMode = ASL_TB + 44;
/// Bool: several names may be picked at once (`num_args`, `arg_list`).
pub const ASLFR_DoMultiSelect = ASL_TB + 45;
/// Bool: the requester has a Pattern field.
pub const ASLFR_DoPatterns = ASL_TB + 46;

// What it shows.
/// Bool: drawers only, no files - what a program that asks for a place
/// to put something wants.
pub const ASLFR_DrawersOnly = ASL_TB + 47;
/// A `*utility.Hook` asked about every entry: true shows it.
pub const ASLFR_FilterFunc = ASL_TB + 49;
/// Bool: names ending in `.info` are not shown.
pub const ASLFR_RejectIcons = ASL_TB + 60;
/// A pattern, already parsed or not, that a name must not match.
pub const ASLFR_RejectPattern = ASL_TB + 61;
/// A pattern a name must match.
pub const ASLFR_AcceptPattern = ASL_TB + 62;
/// Bool: the patterns are put to drawers as well as to files.
pub const ASLFR_FilterDrawers = ASL_TB + 63;

/// `ASLFR_Flags1`.
pub const FRF_FILTERFUNC: u32 = 1 << 7;
pub const FRF_INTUIFUNC: u32 = 1 << 6;
pub const FRF_DOSAVEMODE: u32 = 1 << 5;
pub const FRF_DOMULTISELECT: u32 = 1 << 3;
pub const FRF_DOPATTERNS: u32 = 1 << 0;

/// `ASLFR_Flags2`.
pub const FRF2_DRAWERSONLY: u32 = 1 << 0;
pub const FRF2_FILTERDRAWERS: u32 = 1 << 1;
pub const FRF2_REJECTICONS: u32 = 1 << 2;

// --- the font requester -----------------------------------------------------

/// What a font requester was answered with.
pub const FontRequester = extern struct {
    /// The font picked: its name, its size in the units `flags` says, its
    /// style and its flags, ready for `OpenDiskFont`.
    attr: graphics.TextAttr = .{ .name = "", .y_size = 0 },
    front_pen: u32 = 0,
    back_pen: u32 = 0,
    draw_mode: u32 = 0,
    left_edge: i32 = 0,
    top_edge: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    user_data: usize = 0,
};

pub const ASLFO_Window = ASL_TB + 2;
pub const ASLFO_Screen = ASL_TB + 40;
pub const ASLFO_PubScreenName = ASL_TB + 41;
pub const ASLFO_SleepWindow = ASL_TB + 43;
pub const ASLFO_IntuiMsgFunc = ASL_TB + 70;
pub const ASLFO_UserData = ASL_TB + 52;
pub const ASLFO_TextAttr = ASL_TB + 51;
pub const ASLFO_TitleText = ASL_TB + 1;
pub const ASLFO_PositiveText = ASL_TB + 18;
pub const ASLFO_NegativeText = ASL_TB + 19;
pub const ASLFO_InitialLeftEdge = ASL_TB + 3;
pub const ASLFO_InitialTopEdge = ASL_TB + 4;
pub const ASLFO_InitialWidth = ASL_TB + 5;
pub const ASLFO_InitialHeight = ASL_TB + 6;
/// The family the requester starts on.
pub const ASLFO_InitialName = ASL_TB + 10;
/// The size it starts on.
pub const ASLFO_InitialSize = ASL_TB + 11;
pub const ASLFO_InitialStyle = ASL_TB + 12;
pub const ASLFO_InitialFlags = ASL_TB + 13;
pub const ASLFO_InitialFrontPen = ASL_TB + 14;
pub const ASLFO_InitialBackPen = ASL_TB + 15;
pub const ASLFO_InitialDrawMode = ASL_TB + 59;
pub const ASLFO_Flags = ASL_TB + 20;
/// Bool: the requester shows a pen to draw the text in.
pub const ASLFO_DoFrontPen = ASL_TB + 44;
/// Bool: and one to draw the ground in.
pub const ASLFO_DoBackPen = ASL_TB + 45;
/// Bool: the requester shows the styles.
pub const ASLFO_DoStyle = ASL_TB + 46;
/// Bool: and the drawing mode.
pub const ASLFO_DoDrawMode = ASL_TB + 47;
/// Bool: only fonts every character of which is the same width.
pub const ASLFO_FixedWidthOnly = ASL_TB + 48;
pub const ASLFO_MinHeight = ASL_TB + 16;
pub const ASLFO_MaxHeight = ASL_TB + 17;
pub const ASLFO_FilterFunc = ASL_TB + 49;

/// `ASLFO_Flags`.
pub const FOF_DOFRONTPEN: u32 = 1 << 0;
pub const FOF_DOBACKPEN: u32 = 1 << 1;
pub const FOF_DOSTYLE: u32 = 1 << 2;
pub const FOF_DODRAWMODE: u32 = 1 << 3;
pub const FOF_FIXEDWIDTHONLY: u32 = 1 << 4;
pub const FOF_INTUIFUNC: u32 = 1 << 6;
pub const FOF_FILTERFUNC: u32 = 1 << 7;

// --- the screen mode requester ----------------------------------------------

/// What a screen mode requester was answered with: a board and one of its
/// modes, as rtg names them.
pub const ScreenModeRequester = extern struct {
    /// The board the mode is on, and the mode's id on it.
    board: ?*anyopaque = null,
    mode_id: u32 = 0,
    display_width: u32 = 0,
    display_height: u32 = 0,
    display_depth: u32 = 0,
    left_edge: i32 = 0,
    top_edge: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    user_data: usize = 0,
};

pub const ASLSM_Window = ASL_TB + 2;
pub const ASLSM_Screen = ASL_TB + 40;
pub const ASLSM_PubScreenName = ASL_TB + 41;
pub const ASLSM_SleepWindow = ASL_TB + 43;
pub const ASLSM_IntuiMsgFunc = ASL_TB + 70;
pub const ASLSM_UserData = ASL_TB + 52;
pub const ASLSM_TextAttr = ASL_TB + 51;
pub const ASLSM_TitleText = ASL_TB + 1;
pub const ASLSM_PositiveText = ASL_TB + 18;
pub const ASLSM_NegativeText = ASL_TB + 19;
pub const ASLSM_InitialLeftEdge = ASL_TB + 3;
pub const ASLSM_InitialTopEdge = ASL_TB + 4;
pub const ASLSM_InitialWidth = ASL_TB + 5;
pub const ASLSM_InitialHeight = ASL_TB + 6;
/// The mode the requester starts on.
pub const ASLSM_InitialDisplayID = ASL_TB + 10;
pub const ASLSM_FilterFunc = ASL_TB + 49;
