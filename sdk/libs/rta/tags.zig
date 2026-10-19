// SPDX-License-Identifier: MIT
//! How a sink and a transport are made.
//!
//! What a sink is told goes in as a tag list: the generic tags below,
//! which the library reads itself, and the facts of the part it drives -
//! its pads, its bus, its address - which are the part's own tags from the
//! board's system list (`PART_*`, sdk/libs/expansion/systemtags.zig),
//! chained on with TAG_MORE. A value that is absent is absent, so no
//! number has to be reserved to mean "not set": 0 is a real pad, a real
//! unit and a real address.

const TAG_USER = @import("../utility/tagitem.zig").TAG_USER;

pub const RTAA_Dummy = TAG_USER + 0x60800;

/// [*:0]const u8: what to call this sink or transport. Absent: the
/// driver's name and a number ("es83110").
pub const RTAA_Name = RTAA_Dummy + 1;
/// ?*anyopaque: the caller's, kept in the handle and never touched.
pub const RTAA_UserData = RTAA_Dummy + 2;
/// *AudioTransport: the line a sink's part is fed over, made first with
/// CreateAudioTransportTagList.
pub const RTAA_Transport = RTAA_Dummy + 3;
/// i8: where the sink goes on the list, highest first; the first is the
/// output audio.device plays through. Absent: 0.
pub const RTAA_Priority = RTAA_Dummy + 4;
/// *i32: where to write why a create failed, for a caller that cannot
/// be sure RtaLastError is still its own.
pub const RTAA_ErrorPtr = RTAA_Dummy + 5;
