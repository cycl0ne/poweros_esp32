// SPDX-License-Identifier: MIT
//! rtg.library: the displays of this machine, and the drivers that drive
//! them.
//!
//! A display driver is a module of its own. It registers with AddRtgDriver
//! and from then on a caller asks for a board by the driver's name, gets a
//! handle back, and works in terms of modes, buffers, a blanking and the
//! few operations the board's own engine can do. Nothing above the driver
//! knows what kind of display it is talking to; nothing below it knows who
//! is looking.
//!
//! The library holds no drawing code. A buffer is memory with a width, a
//! height, a pitch and a format, and whoever has it writes into it and
//! then hands the rows on with RefreshBitMap. An operation the board's
//! engine can do faster is offered through the board, and a board that has
//! not got it says so - it is never done in software instead.
//!
//! Two kinds of thing are registered: a **board**, which is a display, and
//! a **transport**, which is a bus a display is reached over. A display
//! wired straight to the pixels needs no transport; a controller on a bus
//! is a board and a transport together.
//!
//! Open it with OpenLibrary(RTGNAME, 1); its functions are in
//! sdk/interface/rtg.zig.

/// The library's name, for OpenLibrary.
pub const RTGNAME = "rtg.library";
/// The version a caller of this SDK asks for.
pub const RTG_VERSION = 1;

pub const bitmaps = @import("bitmaps.zig");
pub const boards = @import("boards.zig");
pub const transport = @import("transport.zig");
pub const events = @import("events.zig");
pub const errors = @import("errors.zig");
pub const tags = @import("tags.zig");

pub const RtgBase = @import("../../interface/rtg.zig").RtgBase;

// The types and constants flat, so a caller writes rtg.RtgBoard and not
// rtg.boards.RtgBoard.

pub const PixelFormat = bitmaps.PixelFormat;
pub const Surface = bitmaps.Surface;
pub const RtgBitMap = bitmaps.RtgBitMap;
pub const RtgRect = bitmaps.RtgRect;
pub const RtgCopy = bitmaps.RtgCopy;
pub const RtgRGB = bitmaps.RtgRGB;
pub const RtgTemplate = bitmaps.RtgTemplate;
pub const RtgPattern = bitmaps.RtgPattern;
pub const formatBits = bitmaps.formatBits;
pub const formatBytes = bitmaps.formatBytes;
pub const formatRowBytes = bitmaps.formatRowBytes;

pub const RtgMode = boards.RtgMode;
pub const RtgRegion = boards.RtgRegion;
pub const RtgBoard = boards.RtgBoard;
pub const RtgBoardInfo = boards.RtgBoardInfo;
pub const RtgBoardStats = boards.RtgBoardStats;
pub const RtgBoardOps = boards.RtgBoardOps;
pub const RtgDriver = boards.RtgDriver;
pub const RtgDriverOps = boards.RtgDriverOps;

pub const RtgTransport = transport.RtgTransport;
pub const RtgTransportOps = transport.RtgTransportOps;

pub const RtgEventFn = events.RtgEventFn;
