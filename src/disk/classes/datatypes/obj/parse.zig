// SPDX-License-Identifier: MIT
//! Wavefront OBJ read into the vertices and triangles obj.datatype hands
//! model.datatype, and its MTL into the materials they are drawn with.
//!
//! What a viewer needs of a model is its faces: each a polygon of corners,
//! a corner a position (`v`) and perhaps a place on a texture (`vt`) and a
//! normal (`vn`), all by number in the order the file gives them - from 1,
//! or from the end when below 0. A polygon of more than three corners is
//! cut into a fan from its first. What comes out is the vertices, each
//! with everything it is drawn with, and three indices into them for every
//! triangle, in runs of one material (`usemtl`), so that a run is one
//! draw. Groups, objects, smoothing groups, lines and points are passed
//! over.
//!
//! **A corner is shared where it can be.** Corners alike in all three -
//! where they are, their place and their normal - are one vertex, however
//! many faces meet there: a hash of the vertices made finds the one made
//! before. A corner without a normal takes its triangle's, so that the
//! face is lit flat, and is that triangle's alone; one without a place on
//! the texture is at 0, 0.
//!
//! **It is read three times.** The first pass counts what there is - the
//! positions, places and normals, the most vertices the faces can make,
//! their indices and the runs - so that one block of memory, large
//! enough, holds it all; the second reads the numbers, so that a face may
//! name a position given after it; the third makes the triangles.
//!
//! A place on a texture comes from the bottom up in OBJ and from the top
//! down in facet.library: `v` is turned over on the way.
//!
//! Nothing here draws, allocates or opens anything: obj.datatype gives it
//! the text and the memory.

const std = @import("std");

/// A vertex, as model.datatype takes it (`ModelVertex`).
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
};

/// Triangles drawn with one material: `count` indices from `first`, and
/// the name `usemtl` gave them, in the text - empty before the first.
pub const Run = struct {
    first: u32,
    count: u32,
    material: []const u8,
};

pub const Error = error{
    /// A face names a position, place or normal the file does not have,
    /// or a number is not one.
    Malformed,
    /// No face at all.
    Empty,
};

/// The memory `read` is given: aligned for everything it holds.
pub const Memory = [*]align(@alignOf(Run)) u8;

/// How much a model takes: what `count` finds, for the memory `read` is
/// given.
pub const Sizes = struct {
    positions: u32 = 0,
    uvs: u32 = 0,
    normals: u32 = 0,
    /// The most vertices the faces can make: each corner of a face whose
    /// corners all have normals, three for each triangle of one that has
    /// a corner without.
    vertices: u32 = 0,
    /// Three for each triangle.
    indices: u32 = 0,
    runs: u32 = 0,

    /// The bytes of the block `read` fills: its vertices, runs and
    /// indices, the positions, places and normals they are made from,
    /// and the hash that finds a vertex made before.
    pub fn bytes(sizes: Sizes) usize {
        return @as(usize, sizes.vertices) * @sizeOf(Vertex) +
            @as(usize, sizes.runs) * @sizeOf(Run) +
            @as(usize, sizes.indices) * @sizeOf(u32) +
            @as(usize, sizes.positions) * @sizeOf([3]f32) +
            @as(usize, sizes.normals) * @sizeOf([3]f32) +
            @as(usize, sizes.uvs) * @sizeOf([2]f32) +
            sizes.slots() * @sizeOf(u32);
    }

    /// The hash's slots: at least twice as many as there can be vertices,
    /// so that a search ends at an empty one soon.
    fn slots(sizes: Sizes) usize {
        return std.math.ceilPowerOfTwoAssert(usize, @max(@as(usize, sizes.vertices) * 2, 2));
    }
};

/// A model read: its vertices, its triangles' indices in runs, and the box
/// its positions fill.
pub const Model = struct {
    vertices: []Vertex,
    indices: []u32,
    runs: []Run,
    /// The least and the greatest of x, y and z over the positions.
    low: [3]f32,
    high: [3]f32,
    /// The file `mtllib` names, in the text, or empty.
    library: []const u8,
};

/// How much `text` holds, or why it holds nothing to draw.
pub fn count(text: []const u8) Error!Sizes {
    var sizes = Sizes{};
    var used = false;
    var lines = Lines{ .text = text };
    while (lines.next()) |line| {
        var words = Words{ .line = line };
        const key = words.next() orelse continue;
        if (eql(key, "v")) {
            sizes.positions += 1;
        } else if (eql(key, "vt")) {
            sizes.uvs += 1;
        } else if (eql(key, "vn")) {
            sizes.normals += 1;
        } else if (eql(key, "f")) {
            var corners: u32 = 0;
            var normals = true;
            while (words.next()) |word| {
                corners += 1;
                if (!hasNormal(word)) normals = false;
            }
            if (corners < 3) return error.Malformed;
            if (!used) {
                // Faces before any `usemtl` are a run of their own.
                if (sizes.runs == 0) sizes.runs = 1;
                used = true;
            }
            const triangles = corners - 2;
            sizes.vertices += if (normals) corners else triangles * 3;
            sizes.indices += triangles * 3;
        } else if (eql(key, "usemtl")) {
            sizes.runs += 1;
            used = true;
        }
    }
    if (sizes.indices == 0) return error.Empty;
    return sizes;
}

/// `text` read into `memory`, `sizes.bytes()` of it, as `count` found it.
/// What comes out points into both.
pub fn read(text: []const u8, sizes: Sizes, memory: Memory) Error!Model {
    var at: usize = 0;
    const vertices = carve(Vertex, memory, &at, sizes.vertices);
    const runs = carve(Run, memory, &at, sizes.runs);
    const indices = carve(u32, memory, &at, sizes.indices);
    const positions = carve([3]f32, memory, &at, sizes.positions);
    const normals = carve([3]f32, memory, &at, sizes.normals);
    const uvs = carve([2]f32, memory, &at, sizes.uvs);
    var corners = Corners{ .vertices = vertices, .slots = carve(u32, memory, &at, @intCast(sizes.slots())) };
    @memset(corners.slots, 0);

    // The numbers, every one, before the faces that name them.
    var model = Model{ .vertices = vertices, .indices = indices, .runs = runs[0..0], .low = @splat(std.math.inf(f32)), .high = @splat(-std.math.inf(f32)), .library = "" };
    var seen = Sizes{};
    var lines = Lines{ .text = text };
    while (lines.next()) |line| {
        var words = Words{ .line = line };
        const key = words.next() orelse continue;
        if (eql(key, "v")) {
            const position = try floats(3, &words, null);
            positions[seen.positions] = position;
            seen.positions += 1;
            for (&model.low, &model.high, position) |*low, *high, value| {
                low.* = @min(low.*, value);
                high.* = @max(high.*, value);
            }
        } else if (eql(key, "vt")) {
            const uv = try floats(2, &words, 0);
            uvs[seen.uvs] = .{ uv[0], 1 - uv[1] };
            seen.uvs += 1;
        } else if (eql(key, "vn")) {
            normals[seen.normals] = normalized(try floats(3, &words, null));
            seen.normals += 1;
        } else if (eql(key, "mtllib")) {
            model.library = words.rest();
        }
    }

    // The triangles, a run for each material.
    var made: u32 = 0;
    var run_count: u32 = 0;
    var before = Sizes{};
    lines = .{ .text = text };
    while (lines.next()) |line| {
        var words = Words{ .line = line };
        const key = words.next() orelse continue;
        if (eql(key, "v")) {
            before.positions += 1;
        } else if (eql(key, "vt")) {
            before.uvs += 1;
        } else if (eql(key, "vn")) {
            before.normals += 1;
        } else if (eql(key, "usemtl")) {
            closeRun(runs, &run_count, made);
            runs[run_count] = .{ .first = made, .count = 0, .material = words.rest() };
            run_count += 1;
        } else if (eql(key, "f")) {
            if (run_count == 0) {
                runs[0] = .{ .first = 0, .count = 0, .material = "" };
                run_count = 1;
            }
            const first = try corner(words.next().?, before, sizes, positions, uvs, normals);
            var last = try corner(words.next().?, before, sizes, positions, uvs, normals);
            while (words.next()) |word| {
                const next = try corner(word, before, sizes, positions, uvs, normals);
                var triangle = [3]Vertex{ first, last, next };
                const alone = faceNormals(&triangle);
                for (triangle, alone, indices[made..][0..3]) |vertex, own, *slot| slot.* = try corners.put(vertex, !own);
                made += 3;
                last = next;
            }
        }
    }
    closeRun(runs, &run_count, made);
    model.vertices = vertices[0..corners.made];
    model.indices = indices[0..made];
    model.runs = runs[0..run_count];
    return model;
}

/// The run being made given its indices, up to `made`: one with none is
/// dropped, so that every run draws something.
fn closeRun(runs: []Run, run_count: *u32, made: u32) void {
    if (run_count.* == 0) return;
    const open = &runs[run_count.* - 1];
    open.count = made - open.first;
    if (open.count == 0) run_count.* -= 1;
}

/// Whether a corner, `v/vt/vn` or `v//vn`, names a normal.
fn hasNormal(word: []const u8) bool {
    var parts = std.mem.splitScalar(u8, word, '/');
    _ = parts.next();
    _ = parts.next() orelse return false;
    const normal = parts.next() orelse return false;
    return normal.len != 0;
}

/// A corner's vertex, `v`, `v/vt`, `v//vn` or `v/vt/vn`: a normal not
/// given is NaN, for `faceNormals` to put right.
fn corner(word: []const u8, before: Sizes, sizes: Sizes, positions: []const [3]f32, uvs: []const [2]f32, normals: []const [3]f32) Error!Vertex {
    var parts = std.mem.splitScalar(u8, word, '/');
    const position = try index(parts.next().?, before.positions, sizes.positions) orelse return error.Malformed;
    const uv = if (parts.next()) |part| try index(part, before.uvs, sizes.uvs) else null;
    const normal = if (parts.next()) |part| try index(part, before.normals, sizes.normals) else null;
    return .{
        .position = positions[position],
        .normal = if (normal) |k| normals[k] else @splat(std.math.nan(f32)),
        .uv = if (uv) |k| uvs[k] else .{ 0, 0 },
    };
}

/// A number of a position, place or normal, from 0: `word` counts from 1,
/// or back from the last given `before` it when below 0. Null for an
/// empty one, as in `v//vn`.
fn index(word: []const u8, before: u32, total: u32) Error!?u32 {
    if (word.len == 0) return null;
    const number = std.fmt.parseInt(i64, word, 10) catch return error.Malformed;
    const found: i64 = if (number < 0) @as(i64, before) + number else number - 1;
    if (number == 0 or found < 0 or found >= total) return error.Malformed;
    return @intCast(found);
}

/// Where a corner lacks its normal, the triangle's own, the way its
/// corners go round, so that the face is lit flat. Which corners took it.
fn faceNormals(triangle: *[3]Vertex) [3]bool {
    var took: [3]bool = undefined;
    for (triangle, &took) |vertex, *it| it.* = std.math.isNan(vertex.normal[0]);
    if (!took[0] and !took[1] and !took[2]) return took;
    const a = triangle[0].position;
    const b = triangle[1].position;
    const c = triangle[2].position;
    const u = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const v = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    const normal = normalized(.{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] });
    for (triangle, took) |*vertex, it| {
        if (it) vertex.normal = normal;
    }
    return took;
}

/// The vertices made so far, and a hash of the ones that may be shared.
const Corners = struct {
    vertices: []Vertex,
    /// A vertex's number and 1 in each slot that holds one; a power of two
    /// of them.
    slots: []u32,
    made: u32 = 0,

    /// The number of a vertex like `vertex`: the one made before, if it
    /// may be `shared` and there is one, or a new one.
    fn put(corners: *Corners, vertex: Vertex, shared: bool) Error!u32 {
        const mask = corners.slots.len - 1;
        var at = hash(vertex) & mask;
        if (shared) {
            while (corners.slots[at] != 0) : (at = (at + 1) & mask) {
                const k = corners.slots[at] - 1;
                if (alike(corners.vertices[k], vertex)) return k;
            }
        }
        // More than `count` allowed for: not the text it counted.
        if (corners.made == corners.vertices.len) return error.Malformed;
        const k = corners.made;
        corners.vertices[k] = vertex;
        corners.made += 1;
        if (shared) corners.slots[at] = k + 1;
        return k;
    }

    fn hash(vertex: Vertex) usize {
        const words: [8]u32 = @bitCast(vertex);
        var h: u32 = 0x811C_9DC5;
        for (words) |word| {
            h = (h ^ word) *% 0x9E37_79B1;
            h ^= h >> 15;
        }
        h *%= 0x85EB_CA6B;
        h ^= h >> 13;
        return h;
    }

    /// Alike to the bit.
    fn alike(a: Vertex, b: Vertex) bool {
        const left: [8]u32 = @bitCast(a);
        const right: [8]u32 = @bitCast(b);
        return std.mem.eql(u32, &left, &right);
    }
};

/// `v` made one long, or left as it is with no length.
fn normalized(v: [3]f32) [3]f32 {
    const length = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (length == 0) return v;
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

/// `n` numbers from `words`; past the last given, `missing`, or an error
/// where there is none.
fn floats(comptime n: usize, words: *Words, missing: ?f32) Error![n]f32 {
    var out: [n]f32 = undefined;
    for (&out) |*value| {
        const word = words.next() orelse {
            value.* = missing orelse return error.Malformed;
            continue;
        };
        value.* = std.fmt.parseFloat(f32, word) catch return error.Malformed;
    }
    return out;
}

/// `n` of `T` from `memory` at `at`, which moves past them.
fn carve(comptime T: type, memory: Memory, at: *usize, n: u32) []T {
    const start = std.mem.alignForward(usize, at.*, @alignOf(T));
    at.* = start + @as(usize, n) * @sizeOf(T);
    const first: [*]T = @ptrCast(@alignCast(memory + start));
    return first[0..n];
}

// --- recognising ------------------------------------------------------------

/// What the start of a text says it is.
pub const Look = enum {
    /// Lines of OBJ, and among them at least one of a model's own.
    model,
    /// A line that is not OBJ.
    not,
    /// Nothing but comments and blank lines so far.
    unsure,
};

/// Whether `start`, the first bytes of a file, is OBJ: every whole line
/// in it blank, a comment, or one OBJ begins with, and at least one of
/// them a position, a place, a normal, a face or a material library. The
/// last line is only looked at if it is whole - `complete`, the file
/// ending there. Numbers are only seen to begin like numbers: this is
/// asked of every file a requester shows, and reads nothing.
pub fn looks(start: []const u8, complete: bool) Look {
    const whole = if (complete) start else if (std.mem.lastIndexOfScalar(u8, start, '\n')) |end| start[0..end] else return .unsure;
    var found = false;
    var lines = Lines{ .text = whole };
    while (lines.next()) |line| {
        var words = Words{ .line = line };
        const key = words.next() orelse continue;
        if (eql(key, "v") or eql(key, "vt") or eql(key, "vn") or eql(key, "f")) {
            const first = words.next() orelse return .not;
            if (!numberLike(first[0])) return .not;
            found = true;
        } else if (eql(key, "mtllib")) {
            found = true;
        } else if (!(eql(key, "o") or eql(key, "g") or eql(key, "s") or eql(key, "usemtl") or
            eql(key, "vp") or eql(key, "l") or eql(key, "p")))
        {
            return .not;
        }
    }
    return if (found) .model else .unsure;
}

fn numberLike(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or byte == '-' or byte == '+' or byte == '.';
}

/// A file's name, as another system writes it in a model's file -
/// directories between `/` or `\`, `.` for here and `..` for the one
/// above - as this one does: `..` is a `/` of its own. In `into`, with
/// room left for its end; null when it does not fit.
pub fn portable(name: []const u8, into: []u8) ?[]u8 {
    var length: usize = 0;
    var after_name = false;
    var parts = std.mem.tokenizeAny(u8, name, "/\\");
    while (parts.next()) |part| {
        if (eql(part, ".")) continue;
        const up = eql(part, "..");
        const adding = @as(usize, @intFromBool(after_name)) + if (up) 1 else part.len;
        if (length + adding >= into.len) return null;
        if (after_name) {
            into[length] = '/';
            length += 1;
        }
        if (up) {
            into[length] = '/';
            length += 1;
        } else {
            @memcpy(into[length..][0..part.len], part);
            length += part.len;
        }
        after_name = !up;
    }
    return into[0..length];
}

// --- MTL --------------------------------------------------------------------

/// A material as obj.datatype draws it: its colour, and the picture over
/// it, if it names one.
pub const Material = struct {
    name: []const u8,
    /// `Kd`, 0 to 1 each.
    diffuse: [3]f32 = .{ 1, 1, 1 },
    /// `map_Kd`'s file, in the text, or empty.
    picture: []const u8 = "",
};

/// How many materials `text` names (`newmtl`).
pub fn countMaterials(text: []const u8) u32 {
    var found: u32 = 0;
    var lines = Lines{ .text = text };
    while (lines.next()) |line| {
        var words = Words{ .line = line };
        const key = words.next() orelse continue;
        if (eql(key, "newmtl")) found += 1;
    }
    return found;
}

/// `text`'s materials into `into`, `countMaterials` of them. A value that
/// is not a number leaves the material's own.
pub fn readMaterials(text: []const u8, into: []Material) void {
    var made: usize = 0;
    var lines = Lines{ .text = text };
    while (lines.next()) |line| {
        var words = Words{ .line = line };
        const key = words.next() orelse continue;
        if (eql(key, "newmtl")) {
            if (made == into.len) return;
            into[made] = .{ .name = words.rest() };
            made += 1;
            continue;
        }
        if (made == 0) continue;
        const material = &into[made - 1];
        if (eql(key, "Kd")) {
            material.diffuse = floats(3, &words, null) catch material.diffuse;
        } else if (eql(key, "map_Kd")) {
            // Options come first (`-s 1 1 1 file`): the file is the last
            // word.
            var file: []const u8 = "";
            while (words.next()) |word| file = word;
            material.picture = file;
        }
    }
}

/// The material named `name`, or null.
pub fn find(materials: []const Material, name: []const u8) ?*const Material {
    for (materials) |*material| {
        if (eql(material.name, name)) return material;
    }
    return null;
}

// --- reading the text -------------------------------------------------------

/// The lines of a text, without their ends and their comments.
const Lines = struct {
    text: []const u8,
    at: usize = 0,

    fn next(lines: *Lines) ?[]const u8 {
        if (lines.at >= lines.text.len) return null;
        const start = lines.at;
        const end = std.mem.indexOfScalarPos(u8, lines.text, start, '\n') orelse lines.text.len;
        lines.at = end + 1;
        var line = lines.text[start..end];
        if (std.mem.indexOfScalar(u8, line, '#')) |comment| line = line[0..comment];
        return line;
    }
};

/// The words of a line, between spaces, tabs and a line's `\r`.
const Words = struct {
    line: []const u8,
    at: usize = 0,

    fn next(words: *Words) ?[]const u8 {
        while (words.at < words.line.len and blank(words.line[words.at])) words.at += 1;
        if (words.at == words.line.len) return null;
        const start = words.at;
        while (words.at < words.line.len and !blank(words.line[words.at])) words.at += 1;
        return words.line[start..words.at];
    }

    /// The rest of the line, without the blanks round it: a name may have
    /// spaces in it.
    fn rest(words: *Words) []const u8 {
        return std.mem.trim(u8, words.line[words.at..], " \t\r");
    }

    fn blank(byte: u8) bool {
        return byte == ' ' or byte == '\t' or byte == '\r';
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

/// `text` read into memory of the test's.
fn readAll(text: []const u8) !struct { model: Model, memory: []align(@alignOf(Run)) u8 } {
    const sizes = try count(text);
    const memory = try testing.allocator.alignedAlloc(u8, .of(Run), sizes.bytes());
    errdefer testing.allocator.free(memory);
    return .{ .model = try read(text, sizes, memory.ptr), .memory = memory };
}

/// The vertex the `k`th index names.
fn named(model: Model, k: usize) Vertex {
    return model.vertices[model.indices[k]];
}

test "a square of two faces: a fan from its first corner, its corners shared, its places turned over, its box" {
    const text =
        \\# a square
        \\mtllib square.mtl
        \\v 0 0 0
        \\v 2 0 0
        \\v 2 1 0
        \\v 0 1 0
        \\vt 0 0
        \\vt 1 0
        \\vt 1 1
        \\vt 0 1
        \\vn 0 0 3
        \\usemtl Paper
        \\f 1/1/1 2/2/1 3/3/1 4/4/1
        \\
    ;
    try testing.expectEqual(@as(u32, 4), (try count(text)).vertices);
    const got = try readAll(text);
    defer testing.allocator.free(got.memory);
    const model = got.model;
    try testing.expectEqual(@as(usize, 4), model.vertices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3 }, model.indices);
    try testing.expectEqual(@as(usize, 1), model.runs.len);
    try testing.expectEqualStrings("Paper", model.runs[0].material);
    try testing.expectEqualStrings("square.mtl", model.library);
    try testing.expectEqual(@as(u32, 6), model.runs[0].count);
    // 1 2 3, then 1 3 4.
    try testing.expectEqual([3]f32{ 0, 0, 0 }, named(model, 0).position);
    try testing.expectEqual([3]f32{ 2, 1, 0 }, named(model, 2).position);
    try testing.expectEqual([3]f32{ 0, 1, 0 }, named(model, 5).position);
    try testing.expectEqual([2]f32{ 0, 1 }, named(model, 0).uv);
    try testing.expectEqual([2]f32{ 1, 0 }, named(model, 2).uv);
    try testing.expectEqual([3]f32{ 0, 0, 1 }, named(model, 1).normal);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, model.low);
    try testing.expectEqual([3]f32{ 2, 1, 0 }, model.high);
}

test "corners without normals take their triangle's; numbers from the end; positions after the face" {
    const text =
        "v 0 0 0\r\nv 1 0 0\r\n" ++
        "f -2 -1 3\r\n" ++
        "v 0 1 0\r\n";
    const got = try readAll(text);
    defer testing.allocator.free(got.memory);
    const model = got.model;
    try testing.expectEqual(@as(usize, 3), model.vertices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, model.indices);
    try testing.expectEqual([3]f32{ 1, 0, 0 }, named(model, 1).position);
    try testing.expectEqual([3]f32{ 0, 1, 0 }, named(model, 2).position);
    for (model.vertices) |vertex| try testing.expectEqual([3]f32{ 0, 0, 1 }, vertex.normal);
    try testing.expectEqual([2]f32{ 0, 0 }, named(model, 0).uv);
    try testing.expectEqualStrings("", model.runs[0].material);
}

test "faces with normals share the corners they meet at; faces lit flat do not" {
    const text =
        \\v 0 0 0
        \\v 1 0 0
        \\v 1 1 0
        \\v 0 1 0
        \\vn 0 0 1
        \\f 1//1 2//1 3//1
        \\f 1//1 3//1 4//1
        \\f 1 2 3
        \\f 1 3 4
    ;
    try testing.expectEqual(@as(u32, 12), (try count(text)).vertices);
    const got = try readAll(text);
    defer testing.allocator.free(got.memory);
    const model = got.model;
    // Four for the two faces with normals, three each for the two without.
    try testing.expectEqual(@as(usize, 10), model.vertices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3, 4, 5, 6, 7, 8, 9 }, model.indices);
}

test "a run for each material, the faces before the first a run of their own, an empty run dropped" {
    const text =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\f 1 2 3
        \\usemtl Unused
        \\usemtl Red
        \\f 1 2 3
        \\f 3 2 1
        \\usemtl Blue
        \\f 1//1 2 3
        \\vn 1 0 0
    ;
    const got = try readAll(text);
    defer testing.allocator.free(got.memory);
    const runs = got.model.runs;
    try testing.expectEqual(@as(usize, 3), runs.len);
    try testing.expectEqualStrings("", runs[0].material);
    try testing.expectEqualStrings("Red", runs[1].material);
    try testing.expectEqual(@as(u32, 3), runs[1].first);
    try testing.expectEqual(@as(u32, 6), runs[1].count);
    try testing.expectEqualStrings("Blue", runs[2].material);
    try testing.expectEqual(@as(u32, 3), runs[2].count);
    try testing.expectEqual([3]f32{ 1, 0, 0 }, named(got.model, 9).normal);
}

test "what is not a model is refused" {
    try testing.expectError(error.Empty, count("v 0 0 0\nv 1 1 1\n"));
    try testing.expectError(error.Malformed, count("v 0 0 0\nf 1 1\n"));
    const sizes = try count("v 0 0 0\nf 1 2 3\n");
    var memory: [256]u8 align(@alignOf(Run)) = undefined;
    try testing.expect(sizes.bytes() <= memory.len);
    try testing.expectError(error.Malformed, read("v 0 0 0\nf 1 2 3\n", sizes, &memory));
    try testing.expectError(error.Malformed, read("v 0 0 0\nf 1 0 1\n", try count("v 0 0 0\nf 1 0 1\n"), &memory));
    try testing.expectError(error.Malformed, read("v 0 x 0\nf 1 1 1\n", try count("v 0 x 0\nf 1 1 1\n"), &memory));
}

test "materials: their colours and pictures, options before the file passed over" {
    const text =
        \\newmtl Red
        \\Kd 1 0 0
        \\newmtl Wood grain
        \\Kd 0.5 0.25 0.125
        \\map_Kd -s 2 2 1 textures/wood.png
    ;
    try testing.expectEqual(@as(u32, 2), countMaterials(text));
    var materials: [2]Material = undefined;
    readMaterials(text, &materials);
    try testing.expectEqualStrings("Red", materials[0].name);
    try testing.expectEqual([3]f32{ 1, 0, 0 }, materials[0].diffuse);
    try testing.expectEqualStrings("", materials[0].picture);
    try testing.expectEqualStrings("Wood grain", materials[1].name);
    try testing.expectEqualStrings("textures/wood.png", materials[1].picture);
    try testing.expect(find(&materials, "Wood grain") == &materials[1]);
    try testing.expect(find(&materials, "Blue") == null);
}

test "recognised by its lines: a model's file, and the texts and object files that are not" {
    const blender =
        \\# Blender 4.2 OBJ File: 'cube.blend'
        \\# www.blender.org
        \\mtllib cube.mtl
        \\o Cube
        \\v 1.000000 1.000000 -1.000000
        \\v 1.000000 -1.000000 -1.000000
        \\vn -0.0000 1.0000 -0.0000
        \\s 0
        \\usemtl Material
        \\f 1/1/1 5/2/1 7/3/1 3/4/1
        \\
    ;
    try testing.expectEqual(Look.model, looks(blender, true));
    // Cut in the middle of a line: that line is not looked at.
    try testing.expectEqual(Look.model, looks(blender[0..90], false));
    try testing.expectEqual(Look.unsure, looks("# only\n# comments\n", true));
    try testing.expectEqual(Look.unsure, looks("# a comment with no end", false));
    try testing.expectEqual(Look.not, looks("Dear reader,\nv is for vertex\n", true));
    try testing.expectEqual(Look.not, looks("v is for vertex\n", true));
    try testing.expectEqual(Look.not, looks("o hello\ng goodbye\nf me\n", true));
    try testing.expectEqual(Look.unsure, looks("o hello\ng goodbye\n", true));
}

test "names from another system: directories, here and the one above" {
    var into: [32]u8 = undefined;
    try testing.expectEqualStrings("wood.png", portable("wood.png", &into).?);
    try testing.expectEqualStrings("textures/wood.png", portable("textures\\wood.png", &into).?);
    try testing.expectEqualStrings("textures/wood.png", portable("./textures//wood.png", &into).?);
    try testing.expectEqualStrings("/wood.png", portable("../wood.png", &into).?);
    try testing.expectEqualStrings("//wood.png", portable("..\\..\\wood.png", &into).?);
    try testing.expectEqualStrings("a//b", portable("a/../b", &into).?);
    try testing.expect(portable("a/name/longer/than/thirty/two/bytes.png", &into) == null);
    var exact: [9]u8 = undefined;
    try testing.expect(portable("wood.png", &exact) != null);
    try testing.expect(portable("woods.png", &exact) == null);
}

test "the models on the disk: recognised, and their corners shared as they should be" {
    const Case = struct { text: []const u8, vertices: usize, indices: usize, runs: usize };
    const cases = [_]Case{
        // Four corners a face: each face's normal is its own.
        .{ .text = @embedFile("../../../tests/datatypes/Crate.obj"), .vertices = 24, .indices = 36, .runs = 1 },
        // 32 x 16 corners, each shared by the four faces round it.
        .{ .text = @embedFile("../../../tests/datatypes/Torus.obj"), .vertices = 512, .indices = 32 * 16 * 6, .runs = 2 },
        // No normals: three corners a face, none shared.
        .{ .text = @embedFile("../../../tests/datatypes/Icosahedron.obj"), .vertices = 60, .indices = 60, .runs = 1 },
    };
    for (cases) |case| {
        try testing.expectEqual(Look.model, looks(case.text[0..@min(case.text.len, 512)], case.text.len <= 512));
        const got = try readAll(case.text);
        defer testing.allocator.free(got.memory);
        try testing.expectEqual(case.vertices, got.model.vertices.len);
        try testing.expectEqual(case.indices, got.model.indices.len);
        try testing.expectEqual(case.runs, got.model.runs.len);
        for (got.model.indices) |k| try testing.expect(k < got.model.vertices.len);
    }
    var materials: [1]Material = undefined;
    readMaterials(@embedFile("../../../tests/datatypes/Crate.mtl"), &materials);
    try testing.expectEqualStrings("Crate.png", materials[0].picture);
}
