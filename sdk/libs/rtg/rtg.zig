// SPDX-License-Identifier: MIT
//! rtg.library: the displays of this machine, and the drivers that drive
//! them.
//!
//! A display driver is a module of its own: a constant description behind
//! a ROM tag (`drivers.zig`), which the library puts on its list. The
//! library offers each display the machine has - a panel of the board's
//! list, a function on PCI - to the drivers that say they take such a
//! thing (`BindRtgDrivers`), and the one that takes it makes a board for
//! each output. A caller walks the boards (`NextBoard`: the first is the
//! machine's display), and works in terms of modes, buffers, a blanking
//! and the few operations the board's own engine can do. Nothing above
//! the driver knows what kind of display it is talking to; nothing below
//! it knows who is looking.
//!
//! The library holds no drawing code. A buffer is memory with a width, a
//! height, a pitch and a format, and whoever has it writes into it and
//! then hands the rows on with RefreshBitMap. An operation the board's
//! engine can do faster is offered through the board, and a board that has
//! not got it says so - it is never done in software instead.
//!
//! Two kinds of thing a driver makes: a **board**, which is a display, and
//! a **transport**, which is a bus a display is reached over. A display
//! wired straight to the pixels needs no transport; a controller on a bus
//! is a board and a transport together.
//!
//! Open it with OpenLibrary(RTGNAME, 1). Its functions are two
//! interfaces of the one base: what a program calls is in
//! sdk/interface/rtg.zig (`RtgBase`), what a driver calls in
//! sdk/interface/rtgdriver.zig (`RtgDriverBase`).

/// The library's name, for OpenLibrary.
pub const RTGNAME = "rtg.library";
/// The version a caller of this SDK asks for.
pub const RTG_VERSION = 1;

pub const bitmaps = @import("bitmaps.zig");
pub const boards = @import("boards.zig");
pub const drivers = @import("drivers.zig");
pub const modes = @import("modes.zig");
pub const transport = @import("transport.zig");
pub const events = @import("events.zig");
pub const errors = @import("errors.zig");
pub const tags = @import("tags.zig");
pub const video = @import("video.zig");

/// The library's base as a program calls it, and as a driver does: the
/// two interfaces of the one jump table.
pub const RtgBase = @import("../../interface/rtg.zig").RtgBase;
pub const RtgDriverBase = @import("../../interface/rtgdriver.zig").RtgDriverBase;

// The types and constants flat, so a caller writes rtg.RtgBoard and not
// rtg.boards.RtgBoard.

pub const PixelFormat = bitmaps.PixelFormat;
pub const Surface = bitmaps.Surface;
pub const RtgBitMap = bitmaps.RtgBitMap;
pub const RtgRect = bitmaps.RtgRect;
pub const RtgCopy = bitmaps.RtgCopy;
pub const RtgPixels = bitmaps.RtgPixels;
pub const RTGPIXF_OPAQUE = bitmaps.RTGPIXF_OPAQUE;
pub const RtgYuv = bitmaps.RtgYuv;
pub const RTGYUV_NV12 = bitmaps.RTGYUV_NV12;
pub const RTGYUV_I420 = bitmaps.RTGYUV_I420;
pub const RTGYUV_BT601 = bitmaps.RTGYUV_BT601;
pub const RTGYUV_BT709 = bitmaps.RTGYUV_BT709;
pub const RTGYUV_BT2020 = bitmaps.RTGYUV_BT2020;
pub const RTGYUV_P3 = bitmaps.RTGYUV_P3;
pub const RTGYUV_SDR = bitmaps.RTGYUV_SDR;
pub const RTGYUV_PQ = bitmaps.RTGYUV_PQ;
pub const RTGYUV_HLG = bitmaps.RTGYUV_HLG;
pub const RTGYUV_LIMITED = bitmaps.RTGYUV_LIMITED;
pub const RTGYUV_FULL = bitmaps.RTGYUV_FULL;
pub const RTGYUV_PEAK_DEFAULT = bitmaps.RTGYUV_PEAK_DEFAULT;
pub const RTGCICP_MATRIX = bitmaps.RTGCICP_MATRIX;
pub const RTGCICP_TRANSFER = bitmaps.RTGCICP_TRANSFER;
pub const RTGCICP_PRIMARIES = bitmaps.RTGCICP_PRIMARIES;
pub const RtgTemplate = bitmaps.RtgTemplate;
pub const RtgPattern = bitmaps.RtgPattern;

pub const RtgMode = modes.RtgMode;
pub const RtgTimings = modes.RtgTimings;
pub const RTG_ANY = modes.RTG_ANY;
pub const RtgRegion = boards.RtgRegion;
pub const RtgBoard = boards.RtgBoard;
pub const RtgBoardSpec = boards.RtgBoardSpec;
pub const RtgBoardInfo = boards.RtgBoardInfo;
pub const RtgBoardStats = boards.RtgBoardStats;
pub const RtgBand = boards.RtgBand;
pub const RTGBANDF_REPEAT = boards.RTGBANDF_REPEAT;
pub const RTG_MAX_BANDS = boards.RTG_MAX_BANDS;
pub const RTG_MAX_COPIES = boards.RTG_MAX_COPIES;
pub const RtgBoardOps = boards.RtgBoardOps;
pub const RtgPointerImage = boards.RtgPointerImage;

pub const RtgDriver = drivers.RtgDriver;
pub const RtgDriverOps = drivers.RtgDriverOps;
pub const RtgDriverSpec = drivers.RtgDriverSpec;
pub const ResidentRtgDriver = drivers.ResidentRtgDriver;
pub const RtgMatch = drivers.RtgMatch;
pub const RtgDevice = drivers.RtgDevice;
pub const RtgDriverInfo = drivers.RtgDriverInfo;
pub const RtgDeviceInfo = drivers.RtgDeviceInfo;

pub const RtgVideoLayer = video.RtgVideoLayer;
pub const RTGVLF_UNDER = video.RTGVLF_UNDER;
pub const RTGVA_Dummy = video.RTGVA_Dummy;
pub const RTGVA_Under = video.RTGVA_Under;
pub const RTGVA_Matrix = video.RTGVA_Matrix;
pub const RTGVA_Transfer = video.RTGVA_Transfer;
pub const RTGVA_Primaries = video.RTGVA_Primaries;
pub const RTGVA_Range = video.RTGVA_Range;
pub const RTGVA_Depth = video.RTGVA_Depth;

pub const RtgTransport = transport.RtgTransport;
pub const RtgTransportOps = transport.RtgTransportOps;

pub const RtgEventFn = events.RtgEventFn;
