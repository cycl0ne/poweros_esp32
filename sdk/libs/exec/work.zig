// SPDX-License-Identifier: MIT
//! Work for the other cores: a job shared out in parts that a task on each
//! core and the task that asked do at once (ShareWork), or a job posted to
//! run beside its poster (PostWork, SINCE exec 1.27).
//!
//! A shared job is a function and its data. The function is called once
//! for each part, with the part's number and how many parts there are, and
//! works out from them which piece of the job is that part's - rows of a
//! picture, lines of a range of memory. The parts run at the same time,
//! so no two may write the same memory. How many there are is exec's to
//! choose, up to what was asked for; one part is the whole job.
//!
//! A posted job is a message the poster owns, as an IORequest is: a worker
//! calls its code once and replies it to its port, and the poster goes on
//! meanwhile - waiting for the reply with its other signals, as a handler
//! waits for its packets.

const Message = @import("ports.zig").Message;

/// A job's code: `data` as ShareWork was given it, which part this is (0
/// up to `parts`), and how many parts there are.
pub const WorkFn = *const fn (data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void;

/// A posted job's code: called once, on a worker, with the job.
pub const JobFn = *const fn (job: *WorkJob) callconv(.c) void;

/// A job posted with PostWork: replied to `message.reply_port` once
/// `work` has returned. `data` is what it works on - or a program makes
/// the job the first field of a larger struct of its own. PostWork sets
/// the message's node: its type, and its priority - the poster's, which
/// the job is run at.
pub const WorkJob = extern struct {
    message: Message = .{},
    work: JobFn,
    data: ?*anyopaque = null,
};
