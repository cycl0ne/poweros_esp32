// SPDX-License-Identifier: MIT
//! The Player's public port: what a program asks the Player that runs
//! (`SYS:Programs/Player`) - what it plays, and how far it is.
//!
//! The Player keeps the public port `PORT_NAME` while it runs. A program
//! sends it a `State` with `SafePutToPort` - the find and the send under
//! one hold of exec's port lock, so a Player ending at that moment still
//! answers it - and the Player fills it in and replies. A `State` replied
//! with `doing` still `PLAYER_GONE` came back from a Player that was
//! ending, unanswered. The message is told from the others the port takes
//! by its length, which `State.asking` sets.
//!
//!   var state = player.State.asking(reply_port);
//!   if (!sys.SafePutToPort(&state.message, player.PORT_NAME)) return; // no Player
//!   _ = sys.WaitPort(reply_port);
//!   _ = sys.GetMsg(reply_port);
//!   if (state.doing == player.PLAYER_PLAYING) ...
//!
//! The Player answers between two of its looks, so a program that must
//! not wait - a docklet, which the dock calls - sends the question and
//! takes the answer from its port at its next look.

const exec = @import("../exec/exec.zig");

/// The public port of the Player that runs.
pub const PORT_NAME = "Player";

/// `State.doing`: no answer - no Player, or one that was ending.
pub const PLAYER_GONE: u32 = 0;
/// A song is shown but not played: stopped, or not yet started.
pub const PLAYER_STOPPED: u32 = 1;
pub const PLAYER_PLAYING: u32 = 2;
pub const PLAYER_PAUSED: u32 = 3;

/// What the Player is doing, asked and answered in one message. The
/// asker's memory; the Player's from the send until the reply.
pub const State = extern struct {
    message: exec.Message = .{},
    /// A `PLAYER_*`, set by the answer.
    doing: u32 = PLAYER_GONE,
    /// How far into the song the sound is, in seconds, and how long the
    /// song is: 0 for a station, which has no end.
    seconds: u32 = 0,
    length: u32 = 0,
    /// The song's title and artist as the Player's window shows them,
    /// NUL-terminated and cut to fit; empty when it shows none.
    title: [96]u8 = @splat(0),
    artist: [64]u8 = @splat(0),

    /// A question to send, answered to `reply_port`.
    pub fn asking(reply_port: *exec.MsgPort) State {
        return .{ .message = .{ .reply_port = reply_port, .length = @sizeOf(State) } };
    }
};
