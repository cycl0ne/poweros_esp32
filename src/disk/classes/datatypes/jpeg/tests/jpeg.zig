// SPDX-License-Identifier: MIT
//! Host tests of jpeg.datatype's decoder (`jpegdecode`) on whole files: a
//! picture written in passes of increasing detail (SYS:Tests/datatypes/
//! Progressive.jpg), one written a component a scan, and one in passes
//! with a restart after every block,
//! each the same numbers as SYS:Tests/datatypes/Garden.jpg written
//! another way - so each must come out as that file does, to the byte,
//! inside the picture.

const std = @import("std");
const decode = @import("jpegdecode");

const testing = std.testing;

const garden = @embedFile("../../../../tests/datatypes/Garden.jpg");

/// A file's planes, as jpeg.datatype makes them.
const Decoded = struct {
    work: *decode.Work,
    planes: [4][]u8 = @splat(&.{}),
    gathered: [4][]i16 = @splat(&.{}),

    fn of(file: []const u8) !Decoded {
        const work = try testing.allocator.create(decode.Work);
        work.* = .{};
        var made = Decoded{ .work = work };
        errdefer made.deinit();
        try decode.readHeaders(file, work);
        for (work.component[0..work.count], 0..) |*component, i| {
            component.stride = decode.planeStride(work, component);
            component.lines = decode.planeLines(work, component);
            made.planes[i] = try testing.allocator.alloc(u8, @as(usize, component.stride) * component.lines);
            @memset(made.planes[i], 0);
            component.plane = made.planes[i].ptr;
            if (work.in_passes) {
                made.gathered[i] = try testing.allocator.alloc(i16, decode.coefficientBytes(work, component) / 2);
                @memset(made.gathered[i], 0);
                component.coefficients = made.gathered[i].ptr;
            }
        }
        try decode.readScan(file, work);
        return made;
    }

    fn deinit(made: *Decoded) void {
        for (made.planes) |plane| testing.allocator.free(plane);
        for (made.gathered) |numbers| testing.allocator.free(numbers);
        testing.allocator.destroy(made.work);
    }
};

fn expectSameAsGarden(file: []const u8, progressive: bool) !void {
    var expected = try Decoded.of(garden);
    defer expected.deinit();
    var got = try Decoded.of(file);
    defer got.deinit();
    try testing.expect(!expected.work.in_passes);
    try testing.expect(got.work.in_passes);
    try testing.expectEqual(progressive, got.work.progressive);
    try testing.expectEqual(expected.work.count, got.work.count);
    // The picture's part of each plane: what only fills out the last
    // unit is a scan of one component's to leave out.
    const work = expected.work;
    for (work.component[0..work.count], 0..) |*component, i| {
        const across = (work.width * component.across + work.max_across - 1) / work.max_across;
        const down = (work.height * component.down + work.max_down - 1) / work.max_down;
        for (0..down) |y| {
            const row = y * component.stride;
            try testing.expectEqualSlices(u8, expected.planes[i][row..][0..across], got.planes[i][row..][0..across]);
        }
    }
}

test "a picture in passes of increasing detail comes out as the one in one scan" {
    try expectSameAsGarden(@embedFile("../../../../tests/datatypes/Progressive.jpg"), true);
}

test "a picture written a component a scan comes out as the one in one scan" {
    try expectSameAsGarden(@embedFile("Apart.jpg"), false);
}

test "a picture in passes that starts its codes again after every block" {
    try expectSameAsGarden(@embedFile("Restarts.jpg"), true);
}

test "a picture in passes cut short keeps what its first scans said" {
    const file = @embedFile("../../../../tests/datatypes/Progressive.jpg");
    var whole = try Decoded.of(file);
    defer whole.deinit();
    var cut = try Decoded.of(file[0 .. file.len / 2]);
    defer cut.deinit();
    // Not the whole picture, but near it: the flat numbers and the first
    // bands came first, and the scan cut short leaves the blocks it did
    // not reach as they were.
    var differ: usize = 0;
    var far: usize = 0;
    for (whole.planes[0], cut.planes[0]) |sharp, rough| {
        const apart = @abs(@as(i32, sharp) - rough);
        if (apart != 0) differ += 1;
        if (apart > 64) far += 1;
    }
    try testing.expect(differ != 0);
    try testing.expect(far * 100 < whole.planes[0].len);
}
