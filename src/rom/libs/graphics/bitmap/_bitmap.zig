// SPDX-License-Identifier: MPL-2.0
//! Bitmaps of one's own: memory to draw into that is not the screen.
//!
//! A board's display memory is not where these come from. On this machine
//! the board's region is exactly one framebuffer and nothing is left in it
//! - `Rtg MEMORY` says `1228800 bytes, 0 free` - so a bitmap a program
//! asks for is ordinary system memory, and what comes back is a `Surface`
//! rather than an `RtgBitMap`. A Surface is all that drawing needs; what
//! an RtgBitMap adds is a board, and there is no board behind this one.
//!
//! The header and the pixels are **one allocation**, the pixels aligned to
//! a cache line behind the header. So there is no flag saying who owns the
//! pixels and no second pointer to lose: `FreeBitMap` frees what
//! `AllocBitMapTagList` returned, and that is the whole of it. A caller
//! that wants to wrap memory it already has does not need this call at all
//! - it fills in a Surface of its own and passes `RPTAG_Surface`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const Surface = rtg.Surface;
const PixelFormat = rtg.bitmaps.PixelFormat;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const RastPort = rastport.RastPort;

/// What the pixels are aligned to. A display reads its memory a cache line
/// at a time, so a buffer that began inside one would be fetched in pieces
/// that do not line up with what was asked for - and a bitmap made here
/// may well end up being moved to one.
pub const pixel_alignment = 64;

/// Where the pixels sit behind the header: the header's size, rounded up
/// to `pixel_alignment`. Worked out at compile time.
pub const pixel_offset = std.mem.alignForward(usize, @sizeOf(Surface), pixel_alignment);
