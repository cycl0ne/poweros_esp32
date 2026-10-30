// SPDX-License-Identifier: MIT
//! Video layers: a plane of a display's controller that shows a picture
//! in YUV itself, scaled into a place on the display.
//!
//! A film's frames come out of a decoder in YUV. Shown through graphics
//! (`ScaleYUVPixelArray`) each is turned into colours, scaled and written
//! into a window by the processor, and composed onto the display from
//! there. A layer does none of that: the frame is handed to it as it is
//! (`ShowVideoFrame`), and the controller reads its planes as it scans
//! the display out, turning and scaling them on the way.
//!
//! A layer sits under the screens' picture or over it. Under it, it is
//! seen where the picture has the layer's `key` colour - a program fills
//! its film's place with that colour, and windows laid over the place
//! hide the film as they hide anything else. Over it, it covers whatever
//! is there. A board that cannot put its picture over a layer opens it
//! over, and says so in `flags`.
//!
//! `OpenVideoLayer` hands one out where the board has one free
//! (`RTGBC_VIDEO`); a program that gets none puts its frames down through
//! graphics instead. Places are in the display's coordinates: a screen's
//! are the display's, from its top edge down.

const tagitem = @import("../utility/tagitem.zig");
const RtgBoard = @import("boards.zig").RtgBoard;

const TAG_USER = tagitem.TAG_USER;

/// OpenVideoLayer's tags.
pub const RTGVA_Dummy = TAG_USER + 0x60E00;
/// bool: the layer under the screens' picture, seen through its `key`
/// colour. TRUE unless given; FALSE puts it over the picture.
pub const RTGVA_Under = RTGVA_Dummy + 1;

/// A layer, as OpenVideoLayer hands it out. The fields up to `max_down`
/// are for the caller to read; it writes none of them.
pub const RtgVideoLayer = extern struct {
    /// The board it is a plane of.
    board: *RtgBoard,
    /// `RTGVLF_*`.
    flags: u32 = 0,
    /// Under the picture: the colour, 0x00RRGGBB, through which it is
    /// seen. A place filled with it shows the layer; anything else hides
    /// it - but a board may show it through the shades of `key` a window's
    /// shadow darkens it to as well, so that a shadow on a film is no dark
    /// band. 0 over the picture.
    key: u32 = 0,
    /// The largest picture it takes, each way.
    max_width: u32 = 0,
    max_height: u32 = 0,
    /// How far it scales a picture: up to `max_up` times its size, down
    /// to one `max_down`th of it, each way on its own.
    max_up: u32 = 1,
    max_down: u32 = 1,
    /// The driver's: which of the board's layers it is, and its own data.
    unit: u32 = 0,
    driver_data: ?*anyopaque = null,
};

/// RtgVideoLayer.flags: it is under the screens' picture, seen through
/// `key`. Clear: over the picture.
pub const RTGVLF_UNDER: u32 = 1 << 0;
