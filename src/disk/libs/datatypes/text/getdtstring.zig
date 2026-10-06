// SPDX-License-Identifier: MIT
//! GetDTString: the text of one of the library's messages.
//!
//! The texts are here rather than in a file because a program that
//! cannot open a picture has to be able to say so, and the moment it
//! needs the words is the moment least likely to be a good one for
//! reading a file.

const sdk = @import("sdk");
const datatypes = sdk.datatypes;
const _base = @import("../datatypes_base.zig");
const DataTypesBase = _base.DataTypesBase;

/// What each number says.
const messages = [_]struct { id: u32, text: [*:0]const u8 }{
    .{ .id = @intCast(datatypes.DTERROR_UNKNOWN_DATATYPE), .text = "Unknown data type" },
    .{ .id = @intCast(datatypes.DTERROR_COULDNT_SAVE), .text = "Could not save" },
    .{ .id = @intCast(datatypes.DTERROR_COULDNT_OPEN), .text = "Could not open" },
    .{ .id = @intCast(datatypes.DTERROR_COULDNT_SEND_MESSAGE), .text = "Could not send the message" },
    .{ .id = @intCast(datatypes.DTERROR_COULDNT_OPEN_CLIPBOARD), .text = "Could not open the clipboard" },
    .{ .id = @intCast(datatypes.DTERROR_UNKNOWN_COMPRESSION), .text = "Unknown compression" },
    .{ .id = @intCast(datatypes.DTERROR_NOT_ENOUGH_DATA), .text = "Not enough data" },
    .{ .id = @intCast(datatypes.DTERROR_INVALID_DATA), .text = "The data is not what it says it is" },
    .{ .id = @intCast(datatypes.DTERROR_TOO_LARGE), .text = "Too large for this machine" },
    // The groups, by name, for a program listing what it can open.
    .{ .id = datatypes.GID_SYSTEM, .text = "system" },
    .{ .id = datatypes.GID_TEXT, .text = "text" },
    .{ .id = datatypes.GID_DOCUMENT, .text = "document" },
    .{ .id = datatypes.GID_SOUND, .text = "sound" },
    .{ .id = datatypes.GID_INSTRUMENT, .text = "instrument" },
    .{ .id = datatypes.GID_MUSIC, .text = "music" },
    .{ .id = datatypes.GID_PICTURE, .text = "picture" },
    .{ .id = datatypes.GID_ANIMATION, .text = "animation" },
    .{ .id = datatypes.GID_MOVIE, .text = "movie" },
};

/// Answers the text of one of the library's messages.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDTString(db: *DataTypesBase, id: u32) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `id` - a `DTERROR_` number, or a `GID_` group.
///
/// RESULT:
/// The text, which is never null: a number nothing is written for
/// answers an empty string.
///
/// BEHAVIOR:
/// The words are the library's own and are the same for everyone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The text belongs to the library and lasts as long as it is open.
///
/// NOTES:
/// A group's name is here as well as an error's, so that a program
/// listing what it can open says "picture" rather than four characters.
///
/// SEE ALSO:
/// `NewDTObjectA`, `ObtainDataTypeA`
///
/// EXAMPLES:
/// ```zig
/// _ = Printf(dl, "%s: %s\n", .{ name, dt.GetDTString(@intCast(dl.IoErr())) });
/// ```
pub fn GetDTString(db: *DataTypesBase, id: u32) [*:0]const u8 {
    _ = db;
    for (messages) |one| {
        if (one.id == id) return one.text;
    }
    return "";
}
