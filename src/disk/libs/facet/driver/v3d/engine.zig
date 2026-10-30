// SPDX-License-Identifier: MIT
//! The V3D's lists started and their end heard of, from its two interrupts:
//! the core's when the binner or the renderer finishes or the binner runs
//! out of memory, and the hub's when the MMU faults.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const regs = @import("regs.zig");
const Gpu = @import("gpu.zig").Gpu;
const spaces = @import("space.zig");
const Block = spaces.Block;
const Space = spaces.Space;

const core_irqs = regs.INT_OUTOMEM | regs.INT_FLDONE | regs.INT_FRDONE;
const hub_irqs = regs.HUB_INT_MMU_WRV | regs.HUB_INT_MMU_PTI | regs.HUB_INT_MMU_CAP;

/// How much a job is given before it counts as lost.
const job_wait_us: u64 = 5_000_000;
/// What the binner gets when it runs out: blocks ready, since an interrupt
/// cannot allocate.
const overflow_bytes: u32 = 256 * 1024;
const overflow_blocks = 8;

pub const Fault = struct {
    status: u32,
    client: u32,
    address: u64,
};

pub const Engine = struct {
    pub const Finished = enum { done, fault, lost };

    sys: *ExecBase,
    gpu: *const Gpu,
    space: *Space,
    core_int: exec.Interrupt,
    hub_int: exec.Interrupt,
    bin_done: exec.Waitable = .{},
    render_done: exec.Waitable = .{},
    faulted: exec.Waitable = .{},
    overflow: [overflow_blocks]Block,
    overflow_made: u32 = 0,
    /// How many blocks the binner has been given.
    overflow_used: u32 = 0,
    /// The binner asked and nothing was left: it will not finish.
    overflow_short: bool = false,
    last_fault: Fault = .{ .status = 0, .client = 0, .address = 0 },
    core_interrupts: u32 = 0,
    hub_interrupts: u32 = 0,
    virtual_bits: u32,

    /// Its blocks made and its interrupts on: `engine` stays where it is
    /// until `stop`.
    pub fn start(engine: *Engine, gpu: *const Gpu, space: *Space, virtual_bits: u32) bool {
        engine.* = .{
            .sys = gpu.sys,
            .gpu = gpu,
            .space = space,
            .core_int = .{
                .node = .{ .type = .interrupt, .pri = 0, .name = "v3d core" },
                .data = engine,
                .code = @ptrCast(&coreServer),
            },
            .hub_int = .{
                .node = .{ .type = .interrupt, .pri = 0, .name = "v3d hub" },
                .data = engine,
                .code = @ptrCast(&hubServer),
            },
            .overflow = undefined,
            .virtual_bits = virtual_bits,
        };
        while (engine.overflow_made < overflow_blocks) : (engine.overflow_made += 1) {
            engine.overflow[engine.overflow_made] = space.alloc(overflow_bytes) orelse break;
        }
        if (engine.overflow_made == 0 or !space.flush()) {
            engine.freeOverflow();
            return false;
        }
        gpu.coreWrite(regs.CTL_INT_CLR, core_irqs);
        gpu.hubWrite(regs.HUB_INT_CLR, hub_irqs);
        engine.sys.AddIntServer(gpu.irq_core, &engine.core_int);
        engine.sys.AddIntServer(gpu.irq_hub, &engine.hub_int);
        gpu.coreWrite(regs.CTL_INT_MSK_SET, ~core_irqs);
        gpu.coreWrite(regs.CTL_INT_MSK_CLR, core_irqs);
        gpu.hubWrite(regs.HUB_INT_MSK_SET, ~hub_irqs);
        gpu.hubWrite(regs.HUB_INT_MSK_CLR, hub_irqs);
        return true;
    }

    pub fn stop(engine: *Engine) void {
        const gpu = engine.gpu;
        gpu.coreWrite(regs.CTL_INT_MSK_SET, ~@as(u32, 0));
        gpu.hubWrite(regs.HUB_INT_MSK_SET, ~@as(u32, 0));
        engine.sys.RemIntServer(gpu.irq_core, &engine.core_int);
        engine.sys.RemIntServer(gpu.irq_hub, &engine.hub_int);
        engine.freeOverflow();
    }

    fn freeOverflow(engine: *Engine) void {
        var index: u32 = 0;
        while (index < engine.overflow_made) : (index += 1) {
            engine.space.free(&engine.overflow[index]);
        }
        engine.overflow_made = 0;
    }

    fn invalidateCaches(engine: *Engine) void {
        const gpu = engine.gpu;
        gpu.coreWrite(regs.CTL_L2TCACTL, regs.L2TCACTL_L2TFLS | regs.L2TCACTL_FLM_FLUSH);
        gpu.coreWrite(regs.CTL_SLCACTL, regs.SLCACTL_ALL);
    }

    /// The renderer through `start`..`end`, until it is done.
    pub fn render(engine: *Engine, start_at: u32, end: u32) Finished {
        const sys = engine.sys;
        sys.ResetWaitable(&engine.render_done);
        sys.ResetWaitable(&engine.faulted);
        engine.invalidateCaches();
        engine.gpu.coreWrite(regs.CLE_CT1QBA, start_at);
        // Writing the end is what starts it.
        engine.gpu.coreWrite(regs.CLE_CT1QEA, end);
        return engine.wait(&engine.render_done);
    }

    /// The binner through `start`..`end`, until it is done: `lists` the
    /// memory its lists go in, `state` where it keeps its state of a tile.
    pub fn bin(engine: *Engine, start_at: u32, end: u32, lists: *const Block, state: *const Block) Finished {
        const sys = engine.sys;
        const gpu = engine.gpu;
        sys.ResetWaitable(&engine.bin_done);
        sys.ResetWaitable(&engine.faulted);
        engine.overflow_used = 0;
        engine.overflow_short = false;
        engine.invalidateCaches();
        gpu.coreWrite(regs.CLE_CT0QMA, lists.address);
        gpu.coreWrite(regs.CLE_CT0QMS, lists.bytes);
        gpu.coreWrite(regs.CLE_CT0QTS, regs.CLE_CT0QTS_ENABLE | state.address);
        gpu.coreWrite(regs.CLE_CT0QBA, start_at);
        gpu.coreWrite(regs.CLE_CT0QEA, end);
        return engine.wait(&engine.bin_done);
    }

    fn wait(engine: *Engine, done: *exec.Waitable) Finished {
        const waiting = [2]*exec.Waitable{ done, &engine.faulted };
        return switch (engine.sys.WaitForAny(&waiting, waiting.len, job_wait_us)) {
            0 => .done,
            1 => .fault,
            else => .lost,
        };
    }
};

fn coreServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const engine: *Engine = @ptrCast(@alignCast(is_data.?));
    const gpu = engine.gpu;
    const raised = gpu.coreRead(regs.CTL_INT_STS) & core_irqs;
    if (raised == 0) return 0;
    gpu.coreWrite(regs.CTL_INT_CLR, raised);
    engine.core_interrupts += 1;
    if (raised & regs.INT_OUTOMEM != 0) {
        // It is signalled on the edge, and comes again only once the
        // binner has been given more.
        if (engine.overflow_used < engine.overflow_made) {
            const block = &engine.overflow[engine.overflow_used];
            engine.overflow_used += 1;
            gpu.coreWrite(regs.PTB_BPOA, block.address);
            gpu.coreWrite(regs.PTB_BPOS, block.bytes);
        } else {
            engine.overflow_short = true;
        }
    }
    if (raised & regs.INT_FLDONE != 0) engine.sys.SignalWaitable(&engine.bin_done);
    if (raised & regs.INT_FRDONE != 0) engine.sys.SignalWaitable(&engine.render_done);
    return 1;
}

fn hubServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const engine: *Engine = @ptrCast(@alignCast(is_data.?));
    const gpu = engine.gpu;
    const raised = gpu.hubRead(regs.HUB_INT_STS) & hub_irqs;
    if (raised == 0) return 0;
    gpu.hubWrite(regs.HUB_INT_CLR, raised);
    engine.hub_interrupts += 1;
    engine.last_fault = .{
        .status = raised,
        .client = gpu.hubRead(regs.MMU_VIO_ID),
        .address = @as(u64, gpu.hubRead(regs.MMU_VIO_ADDR)) << @intCast(engine.virtual_bits - 32),
    };
    // Written back, its flags are cleared.
    gpu.hubWrite(regs.MMU_CTL, gpu.hubRead(regs.MMU_CTL));
    engine.sys.SignalWaitable(&engine.faulted);
    return 1;
}
