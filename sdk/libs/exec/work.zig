// SPDX-License-Identifier: MIT
//! Work shared between the cores (ShareWork): a job cut into parts that
//! a task on each core and the task that asked do at once.
//!
//! A job is a function and its data. The function is called once for each
//! part, with the part's number and how many parts there are, and works
//! out from them which piece of the job is that part's - rows of a
//! picture, lines of a range of memory. The parts run at the same time,
//! so no two may write the same memory. How many there are is exec's to
//! choose, up to what was asked for; one part is the whole job.

/// A job's code: `data` as ShareWork was given it, which part this is (0
/// up to `parts`), and how many parts there are.
pub const WorkFn = *const fn (data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void;
