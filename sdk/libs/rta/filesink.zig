// SPDX-License-Identifier: MIT
//! The file sink: an output that writes what audio.device mixes for it
//! to a WAV file as it plays - the machine's sound recorded with no way
//! in, the sound of a program kept to listen to again or to compare.
//!
//! Its driver, "file", is in the ROM of every machine with sound, and
//! makes no sink by itself. A program makes one with
//! `CreateSinkTagList(FILE_DRIVER_NAME, tags)` - `FILEA_Name` the file,
//! `RTAA_Name` what the output is called - has audio.device play through
//! it (AUDIOCMD_SETOUTPUT), and deletes it when it is done; deleted while
//! it plays, it is closed once audio.device has moved to the next output.
//!
//! It runs in time, at 48 or 44.1 kHz, 16-bit stereo, as a real output
//! would. Each time it is started the file is written anew: a WAV header,
//! then every buffer from the first that is not silent on; when it is
//! stopped the header's lengths are filled in. A buffer the file cannot
//! take in time - the disk too slow - is lost, and counted in the
//! console's log as the file is closed.

const TAG_USER = @import("../utility/tagitem.zig").TAG_USER;

/// The driver's name, for CreateSinkTagList.
pub const FILE_DRIVER_NAME = "file";

pub const FILEA_Dummy = TAG_USER + 0x60900;

/// [*:0]const u8: the file written, copied, up to FILE_NAME_LEN bytes
/// with its NUL. Absent: FILE_DEFAULT_NAME.
pub const FILEA_Name = FILEA_Dummy + 1;

pub const FILE_DEFAULT_NAME = "RAM:Audio.wav";
pub const FILE_NAME_LEN = 256;
