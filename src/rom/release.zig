// SPDX-License-Identifier: MPL-2.0
//! The system's release: its number, the banner a console prints from it,
//! and the ROM tag a program reads it from at run time
//! (`sdk.release.RELEASE_RESIDENT`).
//!
//! Every module carries its own version in its `$VER:` string, and the SDK
//! has the ABI's. Neither is the system's own number, which is what a
//! banner has to say, so it lives here and nowhere else.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;

/// The system's name, as the SDK has it.
pub const NAME = sdk.release.NAME;

/// The system's release. Change it here: the banner, the ROM tag, and
/// whatever asks the running system, read it.
pub const VERSION = 0;
pub const REVISION = 1;
const DATE = "24.9.2026";

/// "0.1".
pub const RELEASE_STRING = std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION });

/// What a console prints above its first output. The blank line sets it
/// apart from the prompt that follows. A console turns each "\n" into CR LF
/// itself.
pub const BANNER = NAME ++ " ROM Operating System and Libraries\n" ++
    "All Rights Reserved.\n" ++
    "Release " ++ RELEASE_STRING ++ "\n\n";

const ID_STRING = NAME ++ " " ++ RELEASE_STRING ++ " (" ++ DATE ++ ")";

/// The release, where a program finds it: its version is the release's
/// version, its ID string the system, the release and its date. No start
/// flags: there is nothing to start, and it is found by name.
pub export const release_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &release_tag,
    .version = VERSION,
    .name = sdk.release.RELEASE_RESIDENT,
    .id_string = ID_STRING,
};
