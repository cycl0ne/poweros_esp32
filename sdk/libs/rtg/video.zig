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
//!
//! A layer is asked for a kind of picture: the matrix, the curve, the
//! primaries, the range and the depth the frames will have
//! (`RTGVA_Matrix` and the rest). A controller's converter knows a few
//! of those and no more - the television matrices at eight bits, nothing
//! of high dynamic range - so a board hands out no layer for a film in
//! PQ or in BT.2020's colours, and the program puts it down through
//! graphics, which maps such a film into the screen's range. Better no
//! layer than a film shown flat and grey.

const tagitem = @import("../utility/tagitem.zig");
const bitmaps = @import("bitmaps.zig");
const RtgBoard = @import("boards.zig").RtgBoard;

const TAG_USER = tagitem.TAG_USER;

/// OpenVideoLayer's tags.
pub const RTGVA_Dummy = TAG_USER + 0x60E00;
/// bool: the layer under the screens' picture, seen through its `key`
/// colour. TRUE unless given; FALSE puts it over the picture.
pub const RTGVA_Under = RTGVA_Dummy + 1;
/// u8: which weights the pictures' colours come out of -
/// `RTGYUV_BT601`, `RTGYUV_BT709` or `RTGYUV_BT2020`. BT.709 unless
/// given.
pub const RTGVA_Matrix = RTGVA_Dummy + 2;
/// u8: what their numbers stand for - `RTGYUV_SDR`, or the high dynamic
/// range curves `RTGYUV_PQ` and `RTGYUV_HLG`. The ordinary range unless
/// given.
pub const RTGVA_Transfer = RTGVA_Dummy + 3;
/// u8: which red, green and blue they are - `RTGYUV_BT709`,
/// `RTGYUV_BT2020` or `RTGYUV_P3`. BT.709 unless given.
pub const RTGVA_Primaries = RTGVA_Dummy + 4;
/// u8: `RTGYUV_LIMITED`, video's 16 to 235, or `RTGYUV_FULL`. Video's
/// range unless given.
pub const RTGVA_Range = RTGVA_Dummy + 5;
/// u8: the bits a sample is in, 8 or 10. Eight unless given.
pub const RTGVA_Depth = RTGVA_Dummy + 6;

/// A layer, as OpenVideoLayer hands it out. The fields up to `depth` are
/// for the caller to read; it writes none of them - the five colour
/// fields are what its tags asked for, which the driver reads to tell
/// whether it can show such a picture at all.
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
    /// What the pictures will be, as the tags said them: `RtgYuv`'s
    /// `matrix`, `transfer`, `primaries`, `range` and `depth`.
    matrix: u8 = bitmaps.RTGYUV_BT709,
    transfer: u8 = bitmaps.RTGYUV_SDR,
    primaries: u8 = bitmaps.RTGYUV_BT709,
    range: u8 = bitmaps.RTGYUV_LIMITED,
    depth: u8 = 8,
    /// The driver's: which of the board's layers it is, and its own data.
    unit: u32 = 0,
    driver_data: ?*anyopaque = null,
};

/// RtgVideoLayer.flags: it is under the screens' picture, seen through
/// `key`. Clear: over the picture.
pub const RTGVLF_UNDER: u32 = 1 << 0;
