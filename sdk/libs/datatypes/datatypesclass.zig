// SPDX-License-Identifier: MIT
//! datatypesclass: what every data type object is.
//!
//! An object is a gadgetclass gadget, so a program adds it to a window
//! or puts it in a layout and intuition drives it like any other. What
//! this class adds is what every kind of contents has in common: how
//! much of it there is and how much is shown (`DTA_TotalVert` and its
//! like), what it is called, where it came from, and the methods a
//! program uses to work it - `DTM_COPY` to put it on the clipboard,
//! `DTM_WRITE` to save it, `DTM_TRIGGER` to start and stop it.
//!
//! The scroll numbers are in units, not pixels: a text object's unit is
//! a line and a picture's is a pixel, and `DTA_VertUnit` says how many
//! pixels one unit is. A scroller gadget is driven straight from
//! `DTA_TopVert`, `DTA_VisibleVert` and `DTA_TotalVert`.
//!
//! **Laying out happens on a process of its own.** `GM_LAYOUT` may
//! arrive from intuition's input, which may not wait, and reflowing a
//! long text takes as long as it takes. The class starts a process, and
//! the work is `DTM_PROCLAYOUT` there; `DTM_ASYNCLAYOUT` is the same
//! thing when a class does it itself.

const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const intuition = @import("../intuition/intuition.zig");
const classusr = intuition.classusr;

pub const DATATYPESCLASS = "datatypesclass";

pub const DTA_Dummy = utility.TAG_USER + 0x1000;

// --- what every object has --------------------------------------------------

/// The font text in the object is drawn in (`*graphics.TextAttr`).
pub const DTA_TextAttr = DTA_Dummy + 10;
/// Where the view starts, how much of it is seen and how much there is,
/// in units. Set, and read.
pub const DTA_TopVert = DTA_Dummy + 11;
pub const DTA_VisibleVert = DTA_Dummy + 12;
pub const DTA_TotalVert = DTA_Dummy + 13;
/// How many pixels one vertical unit is.
pub const DTA_VertUnit = DTA_Dummy + 14;
/// The same across.
pub const DTA_TopHoriz = DTA_Dummy + 15;
pub const DTA_VisibleHoriz = DTA_Dummy + 16;
pub const DTA_TotalHoriz = DTA_Dummy + 17;
pub const DTA_HorizUnit = DTA_Dummy + 18;
/// The part of the object being shown, by name - a node of a guide.
pub const DTA_NodeName = DTA_Dummy + 19;
/// What to call it in a window's title.
pub const DTA_Title = DTA_Dummy + 20;
/// A `*DTMethod` array, ending in a null label: what the object can be
/// told to do, with a name for each.
pub const DTA_TriggerMethods = DTA_Dummy + 21;
/// The class's own data, for a subclass that wants at it.
pub const DTA_Data = DTA_Dummy + 22;
/// The font itself (`*graphics.TextFont`).
pub const DTA_TextFont = DTA_Dummy + 23;
/// A `[*]const MethodID` ending in `~0`: the methods the object answers.
pub const DTA_Methods = DTA_Dummy + 24;
/// The process laying the object out, while one is running.
pub const DTA_LayoutProc = DTA_Dummy + 27;
/// Bool: the program's pointer shows that something is going on.
pub const DTA_Busy = DTA_Dummy + 28;
/// Bool: new contents have been loaded, so anything that cached the
/// numbers above reads them again.
pub const DTA_Sync = DTA_Dummy + 29;
/// The class's base name, as the descriptor gave it.
pub const DTA_BaseName = DTA_Dummy + 30;
/// The group the object must be in, when one is asked for.
pub const DTA_GroupID = DTA_Dummy + 31;
/// What went wrong: how bad, which number, and what it was about.
pub const DTA_ErrorLevel = DTA_Dummy + 32;
pub const DTA_ErrorNumber = DTA_Dummy + 33;
pub const DTA_ErrorString = DTA_Dummy + 34;
/// Bool: the object shows controls of its own - a tape deck for a sound.
pub const DTA_ControlPanel = DTA_Dummy + 36;
/// Bool: it starts playing as soon as it is added.
pub const DTA_Immediate = DTA_Dummy + 37;
/// Bool: it plays again when it reaches the end.
pub const DTA_Repeat = DTA_Dummy + 38;

// --- what the object was made from ------------------------------------------

/// The file's name (a C string). Made and read.
pub const DTA_Name = DTA_Dummy + 100;
/// `DTST_`: where the contents came from.
pub const DTA_SourceType = DTA_Dummy + 101;
/// What the source is: a `*dos.FileHandle` for a file, a
/// `*ClipboardHandle` for the clipboard, a `[*]u8` for memory.
pub const DTA_Handle = DTA_Dummy + 102;
/// The `*DataType` the file was recognised as. Read only.
pub const DTA_DataType = DTA_Dummy + 103;
/// The box the object is drawn in (`*graphics.Rect`).
pub const DTA_Domain = DTA_Dummy + 104;
/// What the contents say about themselves.
pub const DTA_ObjName = DTA_Dummy + 109;
pub const DTA_ObjAuthor = DTA_Dummy + 110;
pub const DTA_ObjAnnotation = DTA_Dummy + 111;
pub const DTA_ObjCopyright = DTA_Dummy + 112;
pub const DTA_ObjVersion = DTA_Dummy + 113;
/// A number of the program's own, kept with the object.
pub const DTA_ObjectID = DTA_Dummy + 114;
pub const DTA_UserData = DTA_Dummy + 115;
/// A `*FrameInfo` the object fills in about what it needs.
pub const DTA_FrameInfo = DTA_Dummy + 116;
/// The size the object would like to be, in units.
pub const DTA_NominalVert = DTA_Dummy + 124;
pub const DTA_NominalHoriz = DTA_Dummy + 125;

/// Where an object's contents come from.
pub const DTST_RAM: u32 = 1;
pub const DTST_FILE: u32 = 2;
pub const DTST_CLIPBOARD: u32 = 3;

// --- the scroll numbers, as the class keeps them ----------------------------

/// struct DTSpecialInfo: hung on the gadget, and read and written
/// through the attributes above rather than by hand.
pub const DTSpecialInfo = extern struct {
    /// Held while the object is being laid out.
    lock: exec.SignalSemaphore = .{},
    /// `DTSIF_`.
    flags: u32 = 0,
    top_vert: i32 = 0,
    vis_vert: i32 = 0,
    tot_vert: i32 = 0,
    old_top_vert: i32 = 0,
    vert_unit: i32 = 1,
    top_horiz: i32 = 0,
    vis_horiz: i32 = 0,
    tot_horiz: i32 = 0,
    old_top_horiz: i32 = 0,
    horiz_unit: i32 = 1,
};

/// The object is being laid out.
pub const DTSIF_LAYOUT: u32 = 1 << 0;
/// Its size changed and it must be laid out again.
pub const DTSIF_NEWSIZE: u32 = 1 << 1;
pub const DTSIF_DRAGGING: u32 = 1 << 2;
pub const DTSIF_DRAGSELECT: u32 = 1 << 3;
pub const DTSIF_HIGHLIGHT: u32 = 1 << 4;
/// A process is doing the laying out.
pub const DTSIF_LAYOUTPROC: u32 = 1 << 6;

// --- the methods ------------------------------------------------------------

pub const DTM_Dummy: classusr.MethodID = 0x600;
/// What the object needs of the display it is shown on.
pub const DTM_FRAMEBOX: classusr.MethodID = 0x601;
/// `GM_LAYOUT`, but on a process, so it may take its time.
pub const DTM_PROCLAYOUT: classusr.MethodID = 0x602;
/// The laying out itself, on the layout process.
pub const DTM_ASYNCLAYOUT: classusr.MethodID = 0x603;
/// The object is being taken out of its window.
pub const DTM_REMOVEDTOBJECT: classusr.MethodID = 0x604;
/// A part of the contents picked, or the pick cleared.
pub const DTM_SELECT: classusr.MethodID = 0x605;
pub const DTM_CLEARSELECTED: classusr.MethodID = 0x606;
/// What is picked put on the clipboard.
pub const DTM_COPY: classusr.MethodID = 0x607;
/// Go to a part by name, and do one of the trigger methods.
pub const DTM_GOTO: classusr.MethodID = 0x630;
pub const DTM_TRIGGER: classusr.MethodID = 0x631;
/// Drawing into a RastPort that is not the object's window.
pub const DTM_OBTAINDRAWINFO: classusr.MethodID = 0x640;
pub const DTM_DRAW: classusr.MethodID = 0x641;
pub const DTM_RELEASEDRAWINFO: classusr.MethodID = 0x642;
/// The contents written out.
pub const DTM_WRITE: classusr.MethodID = 0x650;

/// One of the things an object can be told to do, with a name for a menu
/// and a word for a script.
pub const DTMethod = extern struct {
    label: ?[*:0]const u8 = null,
    command: ?[*:0]const u8 = null,
    method: u32 = 0,
};

/// What `DTM_TRIGGER` is asked for.
pub const STM_PAUSE: u32 = 1;
pub const STM_PLAY: u32 = 2;
pub const STM_CONTENTS: u32 = 3;
pub const STM_INDEX: u32 = 4;
pub const STM_RETRACE: u32 = 5;
pub const STM_BROWSE_PREV: u32 = 6;
pub const STM_BROWSE_NEXT: u32 = 7;
pub const STM_NEXT_FIELD: u32 = 8;
pub const STM_PREV_FIELD: u32 = 9;
pub const STM_ACTIVATE_FIELD: u32 = 10;
pub const STM_COMMAND: u32 = 11;
pub const STM_REWIND: u32 = 12;
pub const STM_FASTFORWARD: u32 = 13;
pub const STM_STOP: u32 = 14;
pub const STM_RESUME: u32 = 15;
pub const STM_LOCATE: u32 = 16;

// --- the messages -----------------------------------------------------------

/// `DTM_REMOVEDTOBJECT`, `DTM_CLEARSELECTED`, `DTM_COPY`.
pub const DtGeneral = extern struct {
    method_id: classusr.MethodID = 0,
    gadget_info: ?*classusr.GadgetInfo = null,
};

/// `DTM_SELECT`: the part of the contents picked.
pub const DtSelect = extern struct {
    method_id: classusr.MethodID = DTM_SELECT,
    gadget_info: ?*classusr.GadgetInfo = null,
    select: graphics.Rect = .{},
};

/// What an object says it needs of a display.
pub const FrameInfo = extern struct {
    /// How fine the display is, and how many bits of colour it has.
    resolution: graphics.Point = .{},
    red_bits: u8 = 0,
    green_bits: u8 = 0,
    blue_bits: u8 = 0,
    pad: u8 = 0,
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
    screen: ?*intuition.Screen = null,
    /// `FIF_`.
    flags: u32 = 0,
};

/// The object can be scaled, scrolled, or shown in other colours.
pub const FIF_SCALABLE: u32 = 1;
pub const FIF_SCROLLABLE: u32 = 2;
pub const FIF_REMAPPABLE: u32 = 4;

/// `DTM_FRAMEBOX`: what the object needs, given what there is.
pub const DtFrameBox = extern struct {
    method_id: classusr.MethodID = DTM_FRAMEBOX,
    gadget_info: ?*classusr.GadgetInfo = null,
    /// What is there, and what the object answers it needs.
    contents_info: *FrameInfo,
    frame_info: *FrameInfo,
    size_frame_info: u32 = @sizeOf(FrameInfo),
    /// `FRAMEF_SPECIFY`: make do with what is there.
    frame_flags: u32 = 0,
};

pub const FRAMEF_SPECIFY: u32 = 1 << 0;

/// `DTM_GOTO`: the part to show, by name.
pub const DtGoto = extern struct {
    method_id: classusr.MethodID = DTM_GOTO,
    gadget_info: ?*classusr.GadgetInfo = null,
    node_name: ?[*:0]const u8 = null,
    attrs: ?[*]const utility.TagItem = null,
};

/// `DTM_TRIGGER`: one of the `STM_` things to do.
pub const DtTrigger = extern struct {
    method_id: classusr.MethodID = DTM_TRIGGER,
    gadget_info: ?*classusr.GadgetInfo = null,
    function: u32 = 0,
    data: ?*anyopaque = null,
};

/// `DTM_DRAW`: the object drawn into a RastPort of the caller's, at a
/// size and from an offset of the caller's choosing.
pub const DtDraw = extern struct {
    method_id: classusr.MethodID = DTM_DRAW,
    rast_port: *graphics.RastPort,
    left: i32 = 0,
    top: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    top_horiz: i32 = 0,
    top_vert: i32 = 0,
    attrs: ?[*]const utility.TagItem = null,
};

/// `DTM_OBTAINDRAWINFO`, `DTM_RELEASEDRAWINFO`.
pub const DtDrawInfo = extern struct {
    method_id: classusr.MethodID = 0,
    attrs: ?[*]const utility.TagItem = null,
    /// What `DTM_OBTAINDRAWINFO` answered, given back to
    /// `DTM_RELEASEDRAWINFO`.
    handle: ?*anyopaque = null,
};

/// `DTM_WRITE`: the contents written to an open file.
pub const DtWrite = extern struct {
    method_id: classusr.MethodID = DTM_WRITE,
    gadget_info: ?*classusr.GadgetInfo = null,
    file: ?*anyopaque = null,
    /// `DTWM_IFF` or `DTWM_RAW`.
    mode: u32 = 0,
    attrs: ?[*]const utility.TagItem = null,
};

/// Written as IFF, which anything that reads the group understands, or
/// in the format the file was read from.
pub const DTWM_IFF: u32 = 0;
pub const DTWM_RAW: u32 = 1;
