// SPDX-License-Identifier: MIT
//! The decoder: NAL units in, pictures out in the order they are shown.
//!
//! A picture's slices are decoded into its store as they come, each
//! macroblock parsed, its motion derived and its samples put together;
//! when the next picture begins (or the stream ends) the picture is
//! filtered, the macroblocks no slice brought are concealed, the
//! references are marked and the picture goes into the decoded picture
//! buffer, which gives the pictures out in their order.

const bits_mod = @import("bits.zig");
const Bits = bits_mod.Bits;
pub const Error = bits_mod.Error;
const nal = @import("nal.zig");
const params = @import("params.zig");
const slice_mod = @import("slice.zig");
const Header = slice_mod.Header;
const common = @import("common.zig");
const Env = common.Env;
const Store = common.Store;
const MbInfo = common.MbInfo;
const Motion = common.Motion;
const RefPic = common.RefPic;
const dpb_mod = @import("dpb.zig");
const Dpb = dpb_mod.Dpb;
const mbm = @import("mb.zig");
const mvpred = @import("mvpred.zig");
const recon = @import("recon.zig");
const deblock = @import("deblock.zig");
const transform = @import("transform.zig");
const cabac = @import("cabac.zig");

/// A slice's data partitions (7.3.2.9, 7.3.2.10) waiting for each other.
const Partitions = struct {
    pending: bool = false,
    unit: nal.Header = .{ .ref_idc = 0, .kind = 0 },
    id: u32 = 0,
    a: []u8 = &.{},
    a_len: usize = 0,
    /// Where partition A's slice data starts, in bits.
    a_pos: usize = 0,
    b: []u8 = &.{},
    b_len: usize = 0,
    b_pos: usize = 0,
    has_b: bool = false,
    c: []u8 = &.{},
    c_len: usize = 0,
    c_pos: usize = 0,
    has_c: bool = false,
};

pub const Decoder = struct {
    env: Env,
    limits: params.Limits = .{},
    sps: [32]params.Sps = @splat(.{}),
    pps: [256]params.Pps = @splat(.{}),
    /// Slice group maps of type 6, each PPS's own.
    group_ids: [256][]u8 = @splat(&.{}),
    dpb: Dpb = .{},

    // --- the active parameter sets and what follows from them ---
    active_sps: ?*const params.Sps = null,
    active_pps: ?*const params.Pps = null,
    width_mbs: u32 = 0,
    height_mbs: u32 = 0,
    cat: u2 = 0,
    chroma_format: u2 = 0,
    depth_y: u5 = 8,
    depth_c: u5 = 8,
    wide: bool = false,
    /// 1, or 3 with separate colour planes: each plane's macroblocks are
    /// kept apart, in `infos` and in a store's motion, one after the other.
    colour_planes: u32 = 1,
    infos: []MbInfo = &.{},
    /// The slice group of each map unit and each macroblock of a picture.
    unit_map: []u8 = &.{},
    mb_map: []u8 = &.{},
    scales: transform.Scales = undefined,
    scales_pps: ?*const params.Pps = null,

    // --- the picture being decoded ---
    cur: ?*Store = null,
    structure: u2 = 3,
    hdr0: Header = .{},
    first_slice: u32 = 0,
    slice_next: u32 = 1,
    second_field: bool = false,
    /// A first field decoded, waiting for its second.
    lone_field: ?*Store = null,
    lone_structure: u2 = 0,
    lone_ref: bool = false,
    /// The last reference picture decoded: what concealment copies.
    last_ref: ?*Store = null,
    lists: [2][33]RefPic = @splat(@splat(.{})),
    /// The end of stream or sequence was seen: the next picture is an IDR.
    after_end: bool = false,

    // --- scratch ---
    hdr: Header = .{},
    mb: mbm.Mb = .{},
    recon: recon.Scratch = .{},
    rbsp: []u8 = &.{},
    parts: Partitions = .{},
    time: i64 = 0,
    /// Slices that ended in an error, and where the last one did.
    slice_errors: u32 = 0,
    error_mb: u32 = 0,

    /// A decoder with nothing decoded, in memory `env` gives.
    pub fn create(env: Env, limits: params.Limits) ?*Decoder {
        const bytes = env.alloc(env.ctx, @sizeOf(Decoder), false) orelse return null;
        const dec: *Decoder = @ptrCast(@alignCast(bytes));
        dec.* = .{ .env = env, .limits = limits };
        return dec;
    }

    pub fn destroy(dec: *Decoder) void {
        const env = dec.env;
        for (&dec.dpb.stores) |*s| freeStoreMemory(dec, s);
        for (&dec.group_ids) |g| env.freeSlice(u8, g);
        env.freeSlice(MbInfo, dec.infos);
        env.freeSlice(u8, dec.unit_map);
        env.freeSlice(u8, dec.mb_map);
        env.freeSlice(u8, dec.rbsp);
        env.freeSlice(u8, dec.parts.a);
        env.freeSlice(u8, dec.parts.b);
        env.freeSlice(u8, dec.parts.c);
        env.free(env.ctx, @ptrCast(dec), @sizeOf(Decoder));
    }

    // --- units ---------------------------------------------------------------

    /// One NAL unit (without start code or length), from a packet shown
    /// at `time`.
    pub fn decodeUnit(dec: *Decoder, unit: []const u8, time: i64) Error!void {
        if (unit.len == 0) return;
        const h = try nal.header(unit[0]);
        // Data partitions B and C belong to the A before them; anything
        // else ends the wait.
        if (dec.parts.pending and h.kind != nal.Type.partition_b and h.kind != nal.Type.partition_c) try dec.flushPartitions();
        switch (h.kind) {
            nal.Type.slice, nal.Type.idr => {
                const n = try dec.unescape(unit[1..], &dec.rbsp);
                dec.time = time;
                var b = Bits.init(dec.rbsp[0..n]);
                try dec.slice(&b, h, null);
            },
            nal.Type.partition_a => {
                dec.time = time;
                try dec.partitionA(unit, h);
            },
            nal.Type.partition_b, nal.Type.partition_c => try dec.partitionBC(unit, h),
            nal.Type.sps => {
                dec.finishPicture();
                const n = try dec.unescape(unit[1..], &dec.rbsp);
                var b = Bits.init(dec.rbsp[0..n]);
                var s: params.Sps = .{};
                const id = try params.parseSps(&b, &s, dec.limits);
                if (id >= 32) return error.Corrupt;
                // The active one changes only at an IDR picture.
                dec.sps[id] = s;
            },
            nal.Type.pps => {
                dec.finishPicture();
                const n = try dec.unescape(unit[1..], &dec.rbsp);
                var b = Bits.init(dec.rbsp[0..n]);
                var peek = b;
                const ids = try params.ppsIds(&peek);
                const sps = &dec.sps[ids.sps];
                if (!sps.valid) return error.Corrupt;
                const units = sps.width_mbs * sps.height_map_units;
                if (dec.group_ids[ids.pps].len < units) {
                    dec.env.freeSlice(u8, dec.group_ids[ids.pps]);
                    dec.group_ids[ids.pps] = &.{};
                    dec.group_ids[ids.pps] = dec.env.slice(u8, units) orelse return error.NoMemory;
                }
                var p: params.Pps = .{};
                try params.parsePps(&b, &p, sps, dec.group_ids[ids.pps]);
                dec.pps[ids.pps] = p;
                if (dec.scales_pps == &dec.pps[ids.pps]) dec.scales_pps = null;
            },
            nal.Type.aud, nal.Type.sei, nal.Type.sps_ext, nal.Type.prefix, nal.Type.subset_sps, 16, 17, 18 => dec.finishPicture(),
            nal.Type.end_of_seq, nal.Type.end_of_stream => {
                dec.finishPicture();
                dec.after_end = true;
            },
            else => {},
        }
    }

    /// Everything decoded and every picture put out to be shown.
    pub fn flush(dec: *Decoder) void {
        dec.flushPartitions() catch {};
        dec.finishPicture();
        dec.storeLoneField();
        dec.dpb.flush();
    }

    /// The next picture to show, or null. It stays valid until `release`.
    pub fn next(dec: *Decoder) ?*Store {
        return dec.dpb.peekOutput();
    }

    pub fn release(dec: *Decoder) void {
        dec.dpb.taken();
    }

    /// Everything dropped, for a seek: the next picture must be an IDR or
    /// a recovery point.
    pub fn reset(dec: *Decoder) void {
        dec.parts.pending = false;
        dec.cur = null;
        dec.lone_field = null;
        dec.last_ref = null;
        while (dec.dpb.peekOutput() != null) dec.dpb.taken();
        dec.dpb.reset();
    }

    fn unescape(dec: *Decoder, payload: []const u8, buf: *[]u8) Error!usize {
        if (buf.len < payload.len + 8) {
            dec.env.freeSlice(u8, buf.*);
            buf.* = &.{};
            buf.* = dec.env.slice(u8, payload.len + 64) orelse return error.NoMemory;
        }
        const n = nal.unescape(payload, buf.*);
        return n;
    }

    // --- data partitions ---------------------------------------------------

    fn partitionA(dec: *Decoder, unit: []const u8, h: nal.Header) Error!void {
        const p = &dec.parts;
        p.a_len = try dec.unescape(unit[1..], &p.a);
        var b = Bits.init(p.a[0..p.a_len]);
        // The header is read again when the slice is decoded; here only
        // where the data starts and its slice_id.
        var hdr: Header = .{};
        const pps_id = try slice_mod.peekPpsId(p.a[0..p.a_len]);
        const pps = &dec.pps[pps_id];
        if (!pps.valid) return error.Corrupt;
        const sps = &dec.sps[pps.sps_id];
        if (!sps.valid) return error.Corrupt;
        try slice_mod.parse(&b, &hdr, h, sps, pps);
        const mbs = sps.width_mbs * sps.heightMbs();
        p.id = try b.ueMax(mbs);
        p.a_pos = b.pos;
        p.unit = h;
        p.pending = true;
        p.has_b = false;
        p.has_c = false;
    }

    fn partitionBC(dec: *Decoder, unit: []const u8, h: nal.Header) Error!void {
        const p = &dec.parts;
        if (!p.pending) return;
        const is_b = h.kind == nal.Type.partition_b;
        const buf = if (is_b) &p.b else &p.c;
        const len = try dec.unescape(unit[1..], buf);
        var b = Bits.init(buf.*[0..len]);
        const pps_id = try slice_mod.peekPpsId(p.a[0..p.a_len]);
        const pps = &dec.pps[pps_id];
        const sps = &dec.sps[pps.sps_id];
        const id = try b.ue();
        if (id != p.id) return;
        if (sps.separate_colour_plane) _ = b.u(2);
        if (pps.redundant_pic_cnt_present) _ = try b.ue();
        if (is_b) {
            p.b_len = len;
            p.b_pos = b.pos;
            p.has_b = true;
        } else {
            p.c_len = len;
            p.c_pos = b.pos;
            p.has_c = true;
            try dec.flushPartitions();
        }
    }

    fn flushPartitions(dec: *Decoder) Error!void {
        const p = &dec.parts;
        if (!p.pending) return;
        p.pending = false;
        var b = Bits.init(p.a[0..p.a_len]);
        try dec.slice(&b, p.unit, p);
    }

    // --- slices ----------------------------------------------------------------

    fn slice(dec: *Decoder, b: *Bits, unit: nal.Header, parts: ?*Partitions) Error!void {
        const data = b.data;
        const pps_id = try slice_mod.peekPpsId(data);
        const pps = &dec.pps[pps_id];
        if (!pps.valid) return error.Corrupt;
        const sps = &dec.sps[pps.sps_id];
        if (!sps.valid) return error.Corrupt;
        const hdr = &dec.hdr;
        try slice_mod.parse(b, hdr, unit, sps, pps);
        if (hdr.redundant_pic_cnt > 0) return;
        // SP and SI are the Extended profile's: 4:2:0, 8 bits, 4x4 transforms.
        if ((hdr.kind == .sp or hdr.kind == .si) and (sps.chroma_format_idc != 1 or sps.bit_depth_luma != 8 or sps.bit_depth_chroma != 8 or pps.transform_8x8)) return error.Unsupported;
        if (parts) |p| b.pos = p.a_pos;

        if (dec.cur != null and dec.newPicture(hdr, sps)) dec.finishPicture();
        if (dec.cur == null) try dec.startPicture(hdr, sps, pps);
        if (dec.active_pps != pps) return error.Corrupt;

        const slice_id = dec.slice_next;
        dec.slice_next += 1;
        var cur_poc: i32 = undefined;
        const s = dec.cur.?;
        cur_poc = switch (dec.structure) {
            1 => s.poc[0],
            2 => s.poc[1],
            else => @min(s.poc[0], s.poc[1]),
        };
        const current: dpb_mod.Current = .{
            .store = s,
            .structure = dec.structure,
            .frame_num = hdr.frame_num,
            .max_frame_num = @as(u32, 1) << sps.log2_max_frame_num,
            .second_field = dec.second_field,
            .poc = cur_poc,
        };
        try dec.dpb.buildLists(hdr, &current, &dec.lists);
        dec.sliceData(b, sps, pps, slice_id, parts) catch |e| {
            s.damaged = true;
            dec.slice_errors += 1;
            if (e == error.NoMemory) return e;
        };
    }

    /// Whether the slice `h` begins a new picture (7.4.1.2.4).
    fn newPicture(dec: *const Decoder, h: *const Header, sps: *const params.Sps) bool {
        const o = &dec.hdr0;
        if (h.frame_num != o.frame_num or h.pps_id != o.pps_id or h.field_pic != o.field_pic) return true;
        if (h.field_pic and h.bottom_field != o.bottom_field) return true;
        if ((h.nal_ref_idc == 0) != (o.nal_ref_idc == 0)) return true;
        if (h.idr != o.idr) return true;
        if (h.idr and h.idr_pic_id != o.idr_pic_id) return true;
        if (sps.poc_type == 0) {
            if (h.poc_lsb != o.poc_lsb or h.delta_poc_bottom != o.delta_poc_bottom) return true;
        } else if (sps.poc_type == 1) {
            if (h.delta_poc[0] != o.delta_poc[0] or h.delta_poc[1] != o.delta_poc[1]) return true;
        }
        return false;
    }

    // --- pictures --------------------------------------------------------------

    /// The sequence `sps` made the active one; memory for its size when
    /// that changed.
    fn activate(dec: *Decoder, sps: *const params.Sps) Error!void {
        const same = dec.infos.len != 0 and dec.width_mbs == sps.width_mbs and dec.height_mbs == sps.heightMbs() and
            dec.chroma_format == sps.chroma_format_idc and dec.depth_y == sps.bit_depth_luma and
            dec.depth_c == sps.bit_depth_chroma and dec.cat == sps.chromaArrayType() and
            dec.colour_planes == planesOf(sps);
        dec.active_sps = sps;
        dec.dpb.size = sps.dpbFrames();
        dec.dpb.reorder = if (sps.restriction) @min(sps.num_reorder_frames, dec.dpb.size) else dec.dpb.size;
        if (same) return;
        // A new size: what is waiting is shown first.
        dec.storeLoneField();
        dec.dpb.flush();
        dec.last_ref = null;
        const env = dec.env;
        const mbs = sps.width_mbs * sps.heightMbs() * planesOf(sps);
        env.freeSlice(MbInfo, dec.infos);
        dec.infos = &.{};
        env.freeSlice(u8, dec.unit_map);
        dec.unit_map = &.{};
        env.freeSlice(u8, dec.mb_map);
        dec.mb_map = &.{};
        dec.infos = env.slice(MbInfo, mbs) orelse return error.NoMemory;
        for (dec.infos) |*i| i.* = .{};
        dec.unit_map = env.slice(u8, sps.width_mbs * sps.height_map_units) orelse return error.NoMemory;
        dec.mb_map = env.slice(u8, sps.width_mbs * sps.heightMbs()) orelse return error.NoMemory;
        dec.width_mbs = sps.width_mbs;
        dec.height_mbs = sps.heightMbs();
        dec.chroma_format = sps.chroma_format_idc;
        dec.cat = sps.chromaArrayType();
        dec.depth_y = @intCast(sps.bit_depth_luma);
        dec.depth_c = @intCast(sps.bit_depth_chroma);
        dec.wide = sps.bit_depth_luma > 8 or sps.bit_depth_chroma > 8;
        dec.colour_planes = planesOf(sps);
    }

    fn planesOf(sps: *const params.Sps) u32 {
        return if (sps.separate_colour_plane) 3 else 1;
    }

    fn freeStoreMemory(dec: *Decoder, s: *Store) void {
        if (s.memory) |m| dec.env.free(dec.env.ctx, m, s.memory_len);
        s.memory = null;
        s.memory_len = 0;
        dec.env.freeSlice(Motion, s.motion);
        s.motion = &.{};
    }

    /// A store's samples and motion for the active sequence.
    fn prepareStore(dec: *Decoder, s: *Store) Error!void {
        const w = dec.width_mbs * 16;
        const h = dec.height_mbs * 16;
        var cw: u32 = w;
        var ch: u32 = h;
        switch (dec.chroma_format) {
            0, 1 => {
                cw = w / 2;
                ch = h / 2;
            },
            2 => cw = w / 2,
            3 => {},
        }
        const size: usize = if (dec.wide) 2 else 1;
        const luma = @as(usize, w) * h;
        const chroma = @as(usize, cw) * ch;
        const len = (luma + 2 * chroma) * size;
        const mbs = @as(usize, dec.width_mbs) * dec.height_mbs * dec.colour_planes;
        if (s.memory == null or s.memory_len != len or s.width[0] != w or s.width[1] != cw or s.motion.len != mbs) {
            freeStoreMemory(dec, s);
            const m = dec.env.alloc(dec.env.ctx, len, false) orelse return error.NoMemory;
            s.memory = m;
            s.memory_len = len;
            s.motion = dec.env.slice(Motion, mbs) orelse return error.NoMemory;
            s.planes = .{ m, m + luma * size, m + (luma + chroma) * size };
            s.stride = .{ w, cw, cw };
            s.width = .{ w, cw, cw };
            s.height = .{ h, ch, ch };
            if (dec.chroma_format == 0) {
                // No chroma: grey, as it is shown.
                const grey: u16 = @as(u16, 1) << @intCast(dec.depth_c - 1);
                if (dec.wide) {
                    const c: [*]u16 = @ptrCast(@alignCast(s.planes[1]));
                    for (0..2 * chroma) |i| c[i] = grey;
                } else {
                    for (0..2 * chroma) |i| s.planes[1][i] = @intCast(grey);
                }
            }
        }
    }

    fn startPicture(dec: *Decoder, hdr: *const Header, sps: *const params.Sps, pps: *const params.Pps) Error!void {
        try dec.activate(sps);
        dec.after_end = false;
        dec.active_pps = pps;
        if (dec.scales_pps != pps) {
            dec.scales.init(&pps.scaling.m4, &pps.scaling.m8);
            dec.scales_pps = pps;
        }
        const structure: u2 = if (!hdr.field_pic) 3 else if (hdr.bottom_field) 2 else 1;
        // The second field of the frame the last picture began?
        if (dec.lone_field) |lf| {
            const pairs = hdr.field_pic and structure != dec.lone_structure and lf.frame_num == hdr.frame_num and
                !hdr.idr and dec.lone_ref == (hdr.nal_ref_idc != 0);
            if (pairs) {
                dec.lone_field = null;
                dec.cur = lf;
                dec.structure = structure;
                dec.second_field = true;
                dec.hdr0 = hdr.*;
                dec.first_slice = dec.slice_next;
                dec.dpb.computePoc(hdr, sps, &lf.poc);
                lf.fields |= structure;
                try dec.buildSliceGroups(hdr, sps, pps);
                return;
            }
            dec.storeLoneField();
        }
        if (hdr.idr) {
            if (!hdr.no_output_of_prior_pics) dec.dpb.flush();
            dec.dpb.reset();
            dec.last_ref = null;
        } else {
            try dec.frameNumGap(hdr, sps);
        }
        const s = dec.dpb.freeStore() orelse return error.NoMemory;
        try dec.prepareStore(s);
        s.in_use = true;
        s.uid = dec.dpb.uid_next;
        dec.dpb.uid_next += 1;
        s.fields = structure;
        s.frame_coded = !hdr.field_pic;
        s.mbaff = hdr.mbaff(sps);
        s.ref = .{ .none, .none };
        s.frame_num = hdr.frame_num;
        s.frame_num_wrap = @intCast(hdr.frame_num);
        s.long_term_idx = 0;
        s.poc = .{ 0, 0 };
        s.output_needed = false;
        s.non_existing = false;
        s.idr = hdr.idr;
        s.mmco5 = false;
        s.time = dec.time;
        s.damaged = false;
        dec.dpb.computePoc(hdr, sps, &s.poc);
        if (hdr.field_pic) {
            // The other field, until it comes, as this one.
            if (structure == 1) s.poc[1] = s.poc[0] else s.poc[0] = s.poc[1];
        }
        dec.cur = s;
        dec.structure = structure;
        dec.second_field = false;
        dec.hdr0 = hdr.*;
        dec.first_slice = dec.slice_next;
        try dec.buildSliceGroups(hdr, sps, pps);
    }

    /// Frames for the frame_num values a stream skipped (8.2.5.2): each a
    /// short-term reference that is never shown, a copy of the last
    /// reference picture.
    fn frameNumGap(dec: *Decoder, hdr: *const Header, sps: *const params.Sps) Error!void {
        const max: u32 = @as(u32, 1) << sps.log2_max_frame_num;
        const prev = dec.dpb.prev_ref_frame_num;
        if (hdr.frame_num == prev or hdr.frame_num == (prev + 1) % max) return;
        var num = (prev + 1) % max;
        // Only the last max_num_ref_frames of them outlast the sliding
        // window; the ones before would leave at once.
        const keep = @max(@as(u32, sps.max_num_ref_frames), 1);
        const gap = (hdr.frame_num + max - num) % max;
        if (gap > keep) num = (hdr.frame_num + max - keep) % max;
        var guard: u32 = 0;
        while (num != hdr.frame_num and guard < max) : (guard += 1) {
            const s = dec.dpb.freeStore() orelse return error.NoMemory;
            try dec.prepareStore(s);
            s.in_use = true;
            s.uid = dec.dpb.uid_next;
            s.fields = 3;
            s.frame_coded = true;
            s.mbaff = false;
            s.frame_num = num;
            s.frame_num_wrap = @intCast(num);
            s.long_term_idx = 0;
            s.poc = .{ 0, 0 };
            s.output_needed = false;
            s.non_existing = true;
            s.idr = false;
            s.mmco5 = false;
            s.damaged = false;
            dec.dpb.uid_next += 1;
            if (dec.last_ref) |src| {
                // A store emptied since may have come back as this one.
                if (src != s and src.in_use and src.memory_len == s.memory_len) @memcpy(s.memory.?[0..s.memory_len], src.memory.?[0..s.memory_len]);
            }
            for (s.motion) |*m| m.* = .{};
            const gh: Header = .{ .frame_num = num, .nal_ref_idc = 1 };
            if (sps.poc_type != 0) {
                // Their FrameNumOffset keeps the count going; type 0's
                // count is the next real picture's alone.
                dec.dpb.computePoc(&gh, sps, &s.poc);
                dec.dpb.afterPicture(&gh, sps, s, false);
            } else {
                dec.dpb.prev_frame_num = num;
                dec.dpb.prev_ref_frame_num = num;
            }
            const current: dpb_mod.Current = .{ .store = s, .structure = 3, .frame_num = num, .max_frame_num = max, .second_field = false, .poc = 0 };
            dec.dpb.slidingWindow(sps, &current);
            s.ref = .{ .short, .short };
            dec.dpb.store(s);
            num = (num + 1) % max;
        }
    }

    /// mbToSliceGroupMap (8.2.2) of the picture.
    fn buildSliceGroups(dec: *Decoder, hdr: *const Header, sps: *const params.Sps, pps: *const params.Pps) Error!void {
        if (pps.num_slice_groups <= 1) return;
        const w = sps.width_mbs;
        const hu = sps.height_map_units;
        const units = w * hu;
        const map = dec.unit_map[0..units];
        const n = pps.num_slice_groups;
        const group0 = @min(hdr.slice_group_change_cycle * pps.change_rate, units);
        const dir: u8 = @intFromBool(pps.change_direction);
        switch (pps.slice_group_map_type) {
            0 => {
                var i: u32 = 0;
                while (i < units) {
                    var g: u32 = 0;
                    while (g < n and i < units) : (g += 1) {
                        var j: u32 = 0;
                        while (j < pps.run_length[g] and i + j < units) : (j += 1) map[i + j] = @intCast(g);
                        i += pps.run_length[g];
                    }
                }
            },
            1 => for (0..units) |i| {
                const ii: u32 = @intCast(i);
                map[i] = @intCast(((ii % w) + (((ii / w) * n) / 2)) % n);
            },
            2 => {
                @memset(map, n - 1);
                var g: i32 = @as(i32, n) - 2;
                while (g >= 0) : (g -= 1) {
                    const gi: usize = @intCast(g);
                    const y0 = pps.top_left[gi] / w;
                    const x0 = pps.top_left[gi] % w;
                    const y1 = pps.bottom_right[gi] / w;
                    const x1 = pps.bottom_right[gi] % w;
                    var y = y0;
                    while (y <= y1) : (y += 1) {
                        var x = x0;
                        while (x <= x1) : (x += 1) map[y * w + x] = @intCast(gi);
                    }
                }
            },
            3 => {
                @memset(map, 1);
                const cd: i32 = dir;
                const wi: i32 = @intCast(w);
                const hi: i32 = @intCast(hu);
                var x: i32 = @divTrunc(wi - cd, 2);
                var y: i32 = @divTrunc(hi - cd, 2);
                var left = x;
                var top = y;
                var right = x;
                var bottom = y;
                var xd: i32 = cd - 1;
                var yd: i32 = cd;
                var k: u32 = 0;
                var guard: u32 = 0;
                while (k < group0 and guard < 4 * units + 16) : (guard += 1) {
                    const idx: usize = @intCast(y * wi + x);
                    const vacant = map[idx] == 1;
                    if (vacant) map[idx] = 0;
                    if (xd == -1 and x == left) {
                        left = @max(left - 1, 0);
                        x = left;
                        xd = 0;
                        yd = 2 * cd - 1;
                    } else if (xd == 1 and x == right) {
                        right = @min(right + 1, wi - 1);
                        x = right;
                        xd = 0;
                        yd = 1 - 2 * cd;
                    } else if (yd == -1 and y == top) {
                        top = @max(top - 1, 0);
                        y = top;
                        xd = 1 - 2 * cd;
                        yd = 0;
                    } else if (yd == 1 and y == bottom) {
                        bottom = @min(bottom + 1, hi - 1);
                        y = bottom;
                        xd = 2 * cd - 1;
                        yd = 0;
                    } else {
                        x += xd;
                        y += yd;
                    }
                    if (vacant) k += 1;
                }
            },
            4 => {
                const upper = if (dir != 0) units - group0 else group0;
                for (0..units) |i| map[i] = if (i < upper) dir else 1 - dir;
            },
            5 => {
                const upper = if (dir != 0) units - group0 else group0;
                var k: u32 = 0;
                for (0..w) |j| {
                    for (0..hu) |i| {
                        map[i * w + j] = if (k < upper) dir else 1 - dir;
                        k += 1;
                    }
                }
            },
            6 => @memcpy(map, pps.group_ids[0..units]),
            else => return error.Unsupported,
        }
        const mbs = dec.picMbs(hdr);
        const mbaff = hdr.mbaff(sps);
        for (0..mbs) |i| {
            const ii: u32 = @intCast(i);
            dec.mb_map[i] = if (sps.frame_mbs_only or hdr.field_pic)
                map[ii]
            else if (mbaff)
                map[ii / 2]
            else
                map[(ii / (2 * w)) * w + (ii % w)];
        }
    }

    /// PicSizeInMbs of the picture.
    fn picMbs(dec: *const Decoder, hdr: *const Header) u32 {
        const mbs = dec.width_mbs * dec.height_mbs;
        return if (hdr.field_pic) mbs / 2 else mbs;
    }

    fn nextAddr(dec: *const Decoder, addr: u32, mbs: u32) u32 {
        const pps = dec.active_pps.?;
        if (pps.num_slice_groups <= 1) return addr + 1;
        var i = addr + 1;
        while (i < mbs and dec.mb_map[i] != dec.mb_map[addr]) i += 1;
        return i;
    }

    /// The first field of a pair whose second never came, kept as it is.
    fn storeLoneField(dec: *Decoder) void {
        const lf = dec.lone_field orelse return;
        dec.lone_field = null;
        dec.dpb.store(lf);
    }

    /// The picture being decoded finished: concealed where slices were
    /// missing, filtered, marked and stored.
    fn finishPicture(dec: *Decoder) void {
        const s = dec.cur orelse return;
        dec.cur = null;
        const sps = dec.active_sps.?;
        const hdr = &dec.hdr0;
        dec.conceal(s);
        const mbs = dec.width_mbs * dec.height_mbs;
        for (0..dec.colour_planes) |k| {
            // A separate colour plane is filtered as the luma of a picture
            // of its own, with its own macroblocks.
            var view = s.*;
            view.planes[0] = s.planes[k];
            const db: deblock.Db = .{
                .store = &view,
                .infos = dec.infos[k * mbs ..][0..mbs],
                .width = dec.width_mbs,
                .rows = dec.height_mbs,
                .mbaff = hdr.mbaff(sps),
                .field_pic = hdr.field_pic,
                .bottom = hdr.bottom_field,
                .first_slice = dec.first_slice,
                .cat = dec.cat,
                .mbh_c = mbhC(dec.cat),
                .depth_y = dec.depth_y,
                .depth_c = dec.depth_c,
            };
            if (dec.wide) deblock.Deblock(u16).picture(&db) else deblock.Deblock(u8).picture(&db);
        }

        var mmco5 = false;
        if (hdr.nal_ref_idc != 0) {
            const current: dpb_mod.Current = .{
                .store = s,
                .structure = dec.structure,
                .frame_num = hdr.frame_num,
                .max_frame_num = @as(u32, 1) << sps.log2_max_frame_num,
                .second_field = dec.second_field,
                .poc = 0,
            };
            mmco5 = dec.dpb.mark(hdr, sps, &current);
            dec.last_ref = s;
        }
        if (mmco5) {
            // Everything before is shown first; the picture counts as
            // frame_num 0 from now on and its order count starts again
            // from it (8.2.1, 7.4.3).
            s.mmco5 = true;
            s.frame_num = 0;
            switch (dec.structure) {
                1 => s.poc[0] = 0,
                2 => s.poc[1] = 0,
                else => {
                    const t = @min(s.poc[0], s.poc[1]);
                    s.poc[0] -= t;
                    s.poc[1] -= t;
                },
            }
            dec.dpb.flush();
        }
        dec.dpb.afterPicture(hdr, sps, s, mmco5);
        if (dec.structure != 3 and !dec.second_field) {
            dec.lone_field = s;
            dec.lone_structure = dec.structure;
            dec.lone_ref = hdr.nal_ref_idc != 0;
            return;
        }
        dec.dpb.store(s);
    }

    /// Macroblocks no slice brought: the last reference picture's samples
    /// there, or grey.
    fn conceal(dec: *Decoder, s: *Store) void {
        const w = dec.width_mbs;
        const hdr = &dec.hdr0;
        const step: u32 = if (hdr.field_pic) 2 else 1;
        var mb_y: u32 = if (hdr.field_pic and hdr.bottom_field) 1 else 0;
        const src = dec.last_ref;
        const planes: usize = if (dec.chroma_format == 0) 1 else 3;
        const sep = dec.colour_planes == 3;
        const mbs = w * dec.height_mbs;
        while (mb_y < dec.height_mbs) : (mb_y += step) {
            for (0..w) |x| {
                const xy = mb_y * w + @as(u32, @intCast(x));
                for (0..planes) |p| {
                    // Separate colour planes are each missing on their own.
                    const k: u32 = if (sep) @as(u32, @intCast(p)) * mbs else 0;
                    if (dec.infos[k + xy].slice >= dec.first_slice) continue;
                    s.damaged = true;
                    if (p == 0 or sep) s.motion[k + xy] = .{};
                    const mbw: u32 = if (p == 0) 16 else @intCast(s.width[p] / w);
                    const mbh: u32 = if (p == 0) 16 else @intCast(s.height[p] / dec.height_mbs);
                    const size: usize = if (dec.wide) 2 else 1;
                    // A field macroblock's rows are every other row.
                    const y0: usize = if (hdr.field_pic) mbh * (mb_y & ~@as(u32, 1)) + (mb_y & 1) else mbh * mb_y;
                    for (0..mbh) |r| {
                        const row = y0 + r * step;
                        const o = (row * s.stride[p] + @as(usize, @intCast(x)) * mbw) * size;
                        const dst = s.planes[p] + o;
                        if (src != null and src.? != s and src.?.memory_len == s.memory_len) {
                            @memcpy(dst[0 .. mbw * size], (src.?.planes[p] + o)[0 .. mbw * size]);
                        } else if (dec.wide) {
                            const d16: [*]u16 = @ptrCast(@alignCast(dst));
                            const grey: u16 = @as(u16, 1) << @intCast((if (p == 0 or sep) dec.depth_y else dec.depth_c) - 1);
                            for (0..mbw) |i| d16[i] = grey;
                        } else @memset(dst[0..mbw], 128);
                    }
                }
            }
        }
    }

    fn mbhC(cat: u2) u32 {
        return switch (cat) {
            1 => 8,
            2, 3 => 16,
            0 => 0,
        };
    }

    // --- slice data -----------------------------------------------------------

    fn sliceData(dec: *Decoder, b: *Bits, sps: *const params.Sps, pps: *const params.Pps, slice_id: u32, parts: ?*Partitions) Error!void {
        const hdr = &dec.hdr;
        const s = dec.cur.?;
        const w = dec.width_mbs;
        const mbaff = hdr.mbaff(sps);
        // The macroblocks of the slice's colour plane.
        const base: usize = @as(usize, hdr.colour_plane) * w * dec.height_mbs;
        const infos = dec.infos[base..][0 .. w * dec.height_mbs];
        const motion = s.motion[base..][0 .. w * dec.height_mbs];
        var d: mbm.Dec = .{
            .sps = sps,
            .pps = pps,
            .hdr = hdr,
            .infos = infos,
            .width = w,
            .mbaff = mbaff,
            .field_pic = hdr.field_pic,
            .cat = dec.cat,
            .mbh_c = mbhC(dec.cat),
            .slice_id = slice_id,
            .scales = &dec.scales,
        };
        d.bits = b.*;
        if (parts) |p| {
            d.partitioned = true;
            d.has_b = p.has_b;
            d.has_c = p.has_c;
            if (p.has_b) {
                d.bits_b = Bits.init(p.b[0..p.b_len]);
                d.bits_b.pos = p.b_pos;
            }
            if (p.has_c) {
                d.bits_c = Bits.init(p.c[0..p.c_len]);
                d.bits_c.pos = p.c_pos;
            }
        }
        d.qp = hdr.qp;
        const use_cabac = pps.cabac;
        if (use_cabac) {
            d.bits.alignByte();
            if (!d.eng.init(d.bits.data, d.bits.pos >> 3)) return error.Corrupt;
            cabac.initContexts(&d.ctx, hdr.kind == .i or hdr.kind == .si, hdr.cabac_init_idc, hdr.qp);
        }
        const b_slice = hdr.kind == .b;
        var col: ?RefPic = null;
        var col_parity: u1 = 0;
        var col_fieldoff: i32 = 0;
        if (b_slice) {
            col = dec.lists[1][0];
            if (col.?.store) |cs| {
                if (dec.structure == 3) {
                    const cur_poc = @min(s.poc[0], s.poc[1]);
                    col_parity = @intFromBool(@abs(cs.poc[0] - cur_poc) >= @abs(cs.poc[1] - cur_poc));
                } else if (col.?.structure != dec.structure and !cs.mbaff) {
                    col_fieldoff = if (col.?.structure == 1) -1 else 1;
                }
            } else col = null;
        }
        const ctx: mvpred.Ctx = .{
            .lists = &dec.lists,
            .cur = s,
            .structure = dec.structure,
            .direct_spatial = hdr.direct_spatial,
            .direct_8x8_inference = sps.direct_8x8_inference,
            .col = col,
            .col_parity = col_parity,
            .col_fieldoff = col_fieldoff,
            .motion_base = base,
        };
        const rc: recon.Rc = .{
            .store = s,
            .scratch = &dec.recon,
            .mv = &ctx,
            .hdr = hdr,
            .depth_y = dec.depth_y,
            .depth_c = dec.depth_c,
            .weighting = if (hdr.weighted) .explicit else if (b_slice and pps.weighted_bipred_idc == 2) .implicit else .none,
            .colour = hdr.colour_plane,
        };
        const mbs = dec.picMbs(hdr);
        const inter_slice = hdr.isInter();
        const switching = hdr.kind == .sp or hdr.kind == .si;
        const bdc: i32 = 6 * (@as(i32, sps.bit_depth_chroma) - 8);
        const bdy: i32 = 6 * (@as(i32, sps.bit_depth_luma) - 8);

        var addr: u32 = hdr.first_mb * @as(u32, if (mbaff) 2 else 1);
        var need_run = true;
        var run_left: u32 = 0;
        var end_after_skip = false;
        var prev_skipped = false;
        var next_skipped = false;
        var field_read = false;
        const m = &dec.mb;
        while (true) {
            if (addr >= mbs) return error.Corrupt;
            dec.error_mb = addr;
            const top = mbaff and addr & 1 == 0;
            const bottom = mbaff and addr & 1 == 1;
            if (mbaff) {
                const pair = addr >> 1;
                d.mb_x = pair % w;
                d.mb_y = 2 * (pair / w) + (addr & 1);
            } else if (hdr.field_pic) {
                d.mb_x = addr % w;
                d.mb_y = 2 * (addr / w) + @intFromBool(hdr.bottom_field);
            } else {
                d.mb_x = addr % w;
                d.mb_y = addr / w;
            }
            d.xy = d.mb_y * w + d.mb_x;
            if (top) {
                // The pair's field flag as inferred, until it is read.
                d.field = d.pairField(true) orelse d.pairField(false) orelse false;
                field_read = false;
            } else if (!mbaff) d.field = hdr.field_pic;
            d.neighbours();

            var skipped = false;
            if (inter_slice) {
                if (!use_cabac) {
                    if (need_run) {
                        run_left = try d.bits.ueMax(mbs - addr);
                        need_run = false;
                        prev_skipped = run_left > 0;
                    }
                    if (run_left > 0) {
                        skipped = true;
                        run_left -= 1;
                        if (run_left == 0) {
                            end_after_skip = !d.bits.moreRbspData();
                            if (top and !end_after_skip) {
                                // The bottom's field flag comes next: the pair's.
                                d.field = d.bits.flag();
                                field_read = true;
                                d.neighbours();
                            }
                        }
                    } else need_run = true;
                } else {
                    if (bottom and prev_skipped) {
                        skipped = next_skipped;
                    } else skipped = mbm.readSkipCabac(&d, b_slice);
                    if (skipped and top) {
                        // The bottom's skip flag, and if it is coded the
                        // pair's field flag, before the top is decoded; the
                        // bottom sees the top as skipped.
                        infos[d.xy].slice = slice_id;
                        infos[d.xy].flags = common.F_SKIP | (if (d.field) common.F_FIELD else 0);
                        d.mb_y += 1;
                        d.xy += w;
                        d.neighbours();
                        next_skipped = mbm.readSkipCabac(&d, b_slice);
                        d.mb_y -= 1;
                        d.xy -= w;
                        if (!next_skipped) {
                            d.field = mbm.readFieldCabac(&d);
                            field_read = true;
                        }
                        d.neighbours();
                    }
                    prev_skipped = skipped;
                }
            }

            if (skipped) {
                m.reset();
                m.skip = true;
                m.kind = .inter;
                if (b_slice) {
                    m.direct = 0xF;
                    m.direct16 = true;
                    m.shape = .p8x8;
                } else {
                    m.shape = .p16x16;
                    m.pred = @splat(mbm.L0);
                    m.ref = .{ @splat(0), @splat(-1) };
                }
                m.qp = d.qp;
                d.last_dqp = false;
            } else {
                if (mbaff and !field_read and (top or bottom)) {
                    d.field = if (use_cabac) mbm.readFieldCabac(&d) else d.bits.flag();
                    field_read = true;
                    d.neighbours();
                }
                try mbm.parse(&d, m);
                d.qp = m.qp;
            }

            var out: mvpred.Out = .{};
            if (m.kind == .inter) try mvpred.derive(&ctx, &d, m, &out);
            if (dec.wide) recon.Recon(u16).mb(&rc, &d, m, &out) else recon.Recon(u8).mb(&rc, &d, m, &out);

            // What later macroblocks and pictures need of it.
            const info = &infos[d.xy];
            const intra = m.kind != .inter;
            var flags: u8 = 0;
            if (d.field) flags |= common.F_FIELD;
            if (m.t8x8) flags |= common.F_T8X8;
            if (m.skip) flags |= common.F_SKIP;
            if (m.direct16) flags |= common.F_DIRECT;
            if (intra) flags |= common.F_INTRA;
            if (m.kind == .ipcm) flags |= common.F_PCM;
            if (switching) flags |= common.F_SWITCH;
            info.slice = slice_id;
            info.kind = m.kind;
            info.flags = flags | common.F_DONE;
            const qp_db: i32 = if (m.kind == .ipcm) -bdy else m.qp;
            info.qp = @intCast(qp_db);
            info.qpc = .{
                @intCast(mbm.chromaQp(qp_db, pps.chroma_qp_offset[0], bdc)),
                @intCast(mbm.chromaQp(qp_db, pps.chroma_qp_offset[1], bdc)),
            };
            info.cbp = m.cbp;
            info.chroma_mode = if (intra and m.kind != .ipcm) m.chroma_mode else 0;
            info.direct8 = if (m.kind == .inter) m.direct else 0;
            info.cbf_dc = m.cbf_dc;
            info.i_modes = m.i_modes;
            info.nnz = m.nnz;
            info.nz8 = m.nz8;
            info.filter = hdr.disable_deblocking;
            info.alpha_off = hdr.alpha_offset;
            info.beta_off = hdr.beta_offset;
            const mo = &motion[d.xy];
            mo.intra = intra;
            mo.field = d.field;
            for (0..2) |l| {
                for (0..16) |i| {
                    for (0..2) |c| {
                        const v = m.mvd[l][i][c];
                        info.mvd[l][i][c] = @intCast(@min(@abs(v), 127));
                    }
                }
                for (0..4) |b8| {
                    const r = if (intra) -1 else out.ref[l][b8];
                    info.ref[l][b8] = r;
                    const id: u32 = if (r >= 0) mvpred.refPic(&ctx, &d, l, r).id() else 0;
                    info.ref_id[l][b8] = id;
                    mo.ref[l][b8] = r;
                    mo.ref_id[l][b8] = id;
                }
                for (0..16) |i| {
                    const b8 = (i >> 3) * 2 + ((i & 3) >> 1);
                    const used = !intra and out.ref[l][b8] >= 0;
                    const v: [2]i16 = if (used) .{ @intCast(out.mv[l][i][0]), @intCast(out.mv[l][i][1]) } else .{ 0, 0 };
                    info.mv[l][i] = v;
                    mo.mv[l][i] = v;
                }
            }

            // More?
            var more: bool = undefined;
            if (!use_cabac) {
                more = if (skipped) run_left > 0 or !end_after_skip else d.bits.moreRbspData();
                if (skipped and run_left == 0 and !end_after_skip) need_run = false;
            } else if (top) {
                more = true;
            } else {
                more = !mbm.readEndOfSlice(&d);
            }
            if (!use_cabac and d.bits.overrun()) return error.Corrupt;
            if (use_cabac and d.eng.overrun()) return error.Corrupt;
            if (!more) break;
            addr = dec.nextAddr(addr, mbs);
        }
    }
};
