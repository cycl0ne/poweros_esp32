// SPDX-License-Identifier: MIT
//! datatypes.library: a file opened by what is in it, not by what a
//! program knows how to read.
//!
//! A **data type** is one kind of file - ILBM, BMP, plain text - and is
//! described by a text file in `DEVS:DataTypes` read with `ReadArgs`:
//!
//!   NAME=ILBM BASE=ilbm GROUP=pict ID=ILBM TYPE=IFF PRI=0
//!   PATTERN=#?.(iff|ilbm|lbm)
//!
//! `C:AddDataTypes` reads them all into one list and publishes it as the
//! named object `DataTypesList`, which is where datatypes.library finds
//! it. The startup-sequence runs it before anything opens the library.
//!
//! A file is recognised by trying the descriptors in order of `PRI`:
//!
//! - `TYPE=IFF` matches when the file is IFF and its form's type is
//!   `ID`.
//! - `MASK` matches the bytes at the start of the file. `?` stands for
//!   any byte and `\xNN` for one written as a number, so a signature
//!   that is not text can be written down.
//! - `PATTERN` matches the file's name, without regard to case unless
//!   `CASE` is given.
//! - `DIR` says the descriptor is for a directory, which is how a
//!   directory is told from a file of the same name.
//! - `RECOGNISE` says the class knows how to tell: the library opens
//!   `datatypes/<BASE>.datatype` and calls the one function in its jump
//!   table, which answers yes or no. It is asked only after whatever
//!   else the descriptor says has already matched.
//!
//! A descriptor with none of the four matches anything of its `TYPE`,
//! which is how plain text and plain binary are caught at the end.
//!
//! What is recognised becomes an **object**: a BOOPSI gadget of the
//! class `datatypes/<BASE>.datatype`, which a program adds to a window
//! and gets drawn, scrolled and played without knowing the format. The
//! object's attributes and methods are `datatypesclass.zig`.

const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
const dos = @import("../dos/dos.zig");
const iffparse = @import("../iffparse/iffparse.zig");
const libraries = @import("../exec/libraries.zig");

pub const DATATYPESNAME = "datatypes.library";

/// The named object `C:AddDataTypes` publishes the list under, and where
/// the descriptors are read from.
pub const DATATYPESLIST_NAME = "DataTypesList";
pub const DATATYPES_DIR = "DEVS:DataTypes";

/// Where a class library is looked for: `datatypes/<base>.datatype`
/// through the `LIBS:` multi-assign that holds `SYS:classes`.
pub const class_prefix = "datatypes/";
pub const class_suffix = ".datatype";

// --- what a descriptor says -------------------------------------------------

/// struct DataTypeHeader: one kind of file.
pub const DataTypeHeader = extern struct {
    /// dth_Name: what it is called, for a person to read.
    name: [*:0]const u8,
    /// dth_BaseName: the class's name, without `.datatype`.
    base_name: [*:0]const u8,
    /// dth_Pattern: the file-name pattern, already parsed; null for
    /// none.
    pattern: ?[*:0]const u8 = null,
    /// dth_Mask: the bytes the file starts with, and which of them are
    /// wildcards. Null for none.
    mask: ?[*]const u8 = null,
    mask_any: ?[*]const u8 = null,
    /// dth_MaskLen
    mask_len: u16 = 0,
    /// dth_Flags: `DTF_`.
    flags: u16 = 0,
    /// dth_GroupID: `GID_`.
    group_id: u32 = 0,
    /// dth_ID: the IFF form type, or the first four characters of the
    /// name.
    id: u32 = 0,
    /// dth_Priority: higher is tried first.
    priority: i16 = 0,
    pad: u16 = 0,
};

/// dth_Flags: what kind of file it is at bottom.
pub const DTF_TYPE_MASK: u16 = 0x000F;
pub const DTF_BINARY: u16 = 0x0000;
pub const DTF_ASCII: u16 = 0x0001;
pub const DTF_IFF: u16 = 0x0002;
pub const DTF_MISC: u16 = 0x0003;
/// The pattern is matched with regard to case.
pub const DTF_CASE: u16 = 0x0010;
/// The class has a recognise function, which is asked last.
pub const DTF_RECOGNISE: u16 = 0x0020;
/// It describes a directory. A directory matches only a descriptor with
/// this, and a file matches only one without.
pub const DTF_DIRECTORY: u16 = 0x0040;

/// The groups. A program that wants only pictures asks for `GID_PICTURE`
/// and is refused anything else.
pub const GID_SYSTEM = iffparse.MakeID("syst");
pub const GID_TEXT = iffparse.MakeID("text");
pub const GID_DOCUMENT = iffparse.MakeID("docu");
pub const GID_SOUND = iffparse.MakeID("soun");
pub const GID_INSTRUMENT = iffparse.MakeID("inst");
pub const GID_MUSIC = iffparse.MakeID("musi");
pub const GID_PICTURE = iffparse.MakeID("pict");
pub const GID_ANIMATION = iffparse.MakeID("anim");
pub const GID_MOVIE = iffparse.MakeID("movi");

/// struct DataType: a descriptor on the list, with everything it needs
/// in one block of memory.
pub const DataType = extern struct {
    /// dtn_Node1: on the list of every data type, by name.
    node: exec.Node = .{},
    /// dtn_Node2: on the list of its own kind.
    kind_node: exec.Node = .{},
    /// dtn_Header
    header: *DataTypeHeader,
    /// dtn_ToolList: what opens, prints or edits a file of this kind.
    tools: exec.List = .{},
    /// dtn_AttrList: tags given to every object made of this type; null
    /// for none.
    attrs: ?[*]const utility.TagItem = null,
    /// dtn_Length: the whole block, which `FreeVec` gives back.
    length: u32 = 0,
    /// How many holders `ObtainDataTypeA` has given out and
    /// `ReleaseDataType` has not taken back. A descriptor in use cannot
    /// be taken off the list.
    uses: u32 = 0,
};

/// struct Tool: a program that does something with a file of this kind.
pub const Tool = extern struct {
    /// tn_Which: `TW_`.
    which: u16 = 0,
    /// tn_Flags: `TF_`.
    flags: u16 = 0,
    /// tn_Program
    program: ?[*:0]const u8 = null,
};

pub const ToolNode = extern struct {
    node: exec.Node = .{},
    tool: Tool = .{},
    length: u32 = 0,
};

pub const TW_INFO: u16 = 1;
pub const TW_BROWSE: u16 = 2;
pub const TW_EDIT: u16 = 3;
pub const TW_PRINT: u16 = 4;
pub const TW_MAIL: u16 = 5;

pub const TF_LAUNCH_MASK: u16 = 0x000F;
pub const TF_SHELL: u16 = 0x0001;
pub const TF_WORKBENCH: u16 = 0x0002;

/// The program a data type names for `which` (`TW_*`) - what its
/// descriptor's INFO, BROWSE, EDIT, PRINT or MAIL says - or null. BROWSE's
/// is the one a file of the kind is opened with: what shows it.
pub fn toolFor(dt: *DataType, which: u16) ?[*:0]const u8 {
    var walk = dt.tools.iterator();
    while (walk.next()) |node| {
        const tool: *const ToolNode = @ptrCast(@alignCast(node));
        if (tool.tool.which == which) return tool.tool.program;
    }
    return null;
}

// --- the list, as everything shares it --------------------------------------

/// What `C:AddDataTypes` publishes and datatypes.library reads: every
/// descriptor, sorted so that the ones that say most are tried first.
pub const DataTypesList = extern struct {
    /// Held while the list is read or changed.
    lock: exec.SignalSemaphore = .{},
    /// Every data type, highest priority first.
    all: exec.List = .{},
    /// How many there are.
    count: u32 = 0,
    /// When it was last read in.
    stamp: dos.DateStamp = .{},
};

// --- what a recognise function is given -------------------------------------

/// The one call a class library has when its descriptor says
/// `RECOGNISE`: the first slot after the standard four.
pub const DTRECOGNISE_LVO = libraries.lvo(4);

/// struct DTHookContext: what a recognise function is told about the
/// file. Everything in it is open and is the library's to close.
pub const DTHookContext = extern struct {
    /// The libraries it may use without opening them.
    sys_base: *anyopaque,
    dos_base: *anyopaque,
    iffparse_base: *anyopaque,
    utility_base: *anyopaque,
    /// A lock on the file, and what `Examine` said about it.
    lock: ?*dos.FileLock = null,
    fib: ?*dos.FileInfoBlock = null,
    /// The file, open and positioned at its start; null for a source
    /// that is not a file.
    file: ?*dos.FileHandle = null,
    /// The file as IFF, walked as far as the first form's type; null
    /// when it is not IFF.
    iff: ?*iffparse.IFFHandle = null,
    /// The first bytes of the file, and how many were read.
    buffer: ?[*]const u8 = null,
    buffer_length: u32 = 0,
};

/// A recognise function: true when the file is one of its class's.
pub const RecogniseFn = *const fn (base: *anyopaque, context: *DTHookContext) callconv(.c) bool;

// --- what can go wrong ------------------------------------------------------

pub const DTERROR_UNKNOWN_DATATYPE: i32 = 2000;
pub const DTERROR_COULDNT_SAVE: i32 = 2001;
pub const DTERROR_COULDNT_OPEN: i32 = 2002;
pub const DTERROR_COULDNT_SEND_MESSAGE: i32 = 2003;
pub const DTERROR_COULDNT_OPEN_CLIPBOARD: i32 = 2004;
pub const DTERROR_UNKNOWN_COMPRESSION: i32 = 2006;
pub const DTERROR_NOT_ENOUGH_DATA: i32 = 2007;
pub const DTERROR_INVALID_DATA: i32 = 2008;
/// What is in the file is more than this machine can hold: a picture
/// kept as pens is four bytes a pixel, and a wallpaper is millions of
/// them. A class says this before it reads anything, so a file too
/// large is refused rather than failing somewhere in the middle.
pub const DTERROR_TOO_LARGE: i32 = 2009;

/// The class's attributes, methods and messages.
pub const datatypesclass = @import("datatypesclass.zig");
/// picture.datatype's, which every still picture is one of.
pub const pictureclass = @import("pictureclass.zig");
pub const animationclass = @import("animationclass.zig");
/// jpeg.datatype's: which decoder reads a file.
pub const jpegclass = @import("jpegclass.zig");
/// text.datatype's, which every piece of text is one of.
pub const textclass = @import("textclass.zig");
/// What every format's class does that is not format work.
pub const subclass = @import("subclass.zig");
/// A PNG file read: its chunks, its header, its rows unpacked and turned
/// into colour (sdk/libs/datatypes/png/). png.datatype and icon.library
/// both read PNGs with it.
pub const png = struct {
    pub const decode = @import("png/decode.zig");
    pub const inflate = @import("png/inflate.zig");
};
