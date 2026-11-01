// SPDX-License-Identifier: MIT
//! CELT's inverse MDCT: N/2 coefficients into N/2 samples and the overlap
//! the next frame finishes (RFC 6716 4.3.7), for N = 1920, 960, 480 or
//! 240 - one long block or the short blocks of a transient frame.
//!
//! **The transform** is a complex FFT of N/4 points between two turns:
//! the coefficients paired from both ends and turned by cos/sin of
//! 2 pi (i + 1/8) / N - written straight into the order the FFT takes its
//! input in - transformed, and turned back the same way from both ends of
//! the buffer at once. Real and imaginary parts swap on the way in and
//! out, so a forward FFT does the work of an inverse one.
//!
//! **The overlap**: the window is 1 except over 120 samples at each end,
//! so only 60 samples past the block are aliased into it. The first 120
//! samples of the output are mixed with what the block before left there
//! (TDAC): both mirrored through the window, the low-overlap way.
//!
//! **The FFT** is mixed radix - 480 = 5 * 3 * 4 * 2 * 4 points, and the
//! smaller ones without the radix 2 - in place on its digit-reversed
//! input, radix-2, 3, 4 and 5 butterflies with turns from one table of
//! 480.

const tables = @import("celt_tables.zig");

const Complex = extern struct { r: f32, i: f32 };

inline fn mul(a: Complex, b: [2]f32) Complex {
    return .{ .r = a.r * b[0] - a.i * b[1], .i = a.r * b[1] + a.i * b[0] };
}

inline fn add(a: Complex, b: Complex) Complex {
    return .{ .r = a.r + b.r, .i = a.i + b.i };
}

inline fn sub(a: Complex, b: Complex) Complex {
    return .{ .r = a.r - b.r, .i = a.i - b.i };
}

/// The output of the transform of N = 1920 >> shift into `out`: N/2
/// samples from out[60] on, the first 120 mixed with what lies there.
/// `in` holds the coefficients `stride` apart.
pub fn backward(in: [*]const f32, out: [*]f32, shift: u2, stride: usize) void {
    var n: usize = 1920;
    var trig: [*]const f32 = &tables.mdct_trig;
    for (0..shift) |_| {
        n >>= 1;
        trig += n;
    }
    const n2 = n >> 1;
    const n4 = n >> 2;
    const half = tables.overlap / 2;

    // Turned and put in the FFT's order.
    {
        const bitrev = &tables.fft_bitrev[shift];
        var xp1: usize = 0;
        var xp2: usize = stride * (n2 - 1);
        const yp = out + half;
        for (0..n4) |i| {
            const rev: usize = bitrev[i];
            const yr = in[xp2] * trig[i] + in[xp1] * trig[n4 + i];
            const yi = in[xp1] * trig[i] - in[xp2] * trig[n4 + i];
            yp[2 * rev + 1] = yr;
            yp[2 * rev] = yi;
            xp1 += 2 * stride;
            xp2 -%= 2 * stride;
        }
    }

    fft(@ptrCast(@alignCast(out + half)), shift);

    // Turned back from both ends at once.
    {
        var yp0 = out + half;
        var yp1 = out + half + n2 - 2;
        for (0..(n4 + 1) >> 1) |i| {
            var re = yp0[1];
            var im = yp0[0];
            var t0 = trig[i];
            var t1 = trig[n4 + i];
            var yr = re * t0 + im * t1;
            var yi = re * t1 - im * t0;
            re = yp1[1];
            im = yp1[0];
            yp0[0] = yr;
            yp1[1] = yi;
            t0 = trig[n4 - i - 1];
            t1 = trig[n2 - i - 1];
            yr = re * t0 + im * t1;
            yi = re * t1 - im * t0;
            yp1[0] = yr;
            yp0[1] = yi;
            yp0 += 2;
            yp1 -= 2;
        }
    }

    // The overlap mirrored through the window.
    const window = &tables.window;
    for (0..half) |i| {
        const x1 = out[tables.overlap - 1 - i];
        const x2 = out[i];
        out[i] = window[tables.overlap - 1 - i] * x2 - window[i] * x1;
        out[tables.overlap - 1 - i] = window[i] * x2 + window[tables.overlap - 1 - i] * x1;
    }
}

/// The FFT of 480 >> shift points in place, its input digit-reversed.
fn fft(data: [*]Complex, shift: u2) void {
    const factors = &tables.fft_factors[shift];
    var fstride: [6]usize = undefined;
    fstride[0] = 1;
    var stages: usize = 0;
    while (true) {
        const p = factors[2 * stages];
        const m = factors[2 * stages + 1];
        fstride[stages + 1] = fstride[stages] * p;
        stages += 1;
        if (m == 1) break;
    }
    var m: usize = factors[2 * stages - 1];
    var i = stages;
    while (i > 0) {
        i -= 1;
        const m2: usize = if (i != 0) factors[2 * i - 1] else 1;
        const step = fstride[i] << shift;
        switch (factors[2 * i]) {
            2 => butterfly2(data, m, fstride[i]),
            3 => butterfly3(data, step, m, fstride[i], m2),
            4 => butterfly4(data, step, m, fstride[i], m2),
            else => butterfly5(data, step, m, fstride[i], m2),
        }
        m = m2;
    }
}

fn butterfly2(data: [*]Complex, m: usize, count: usize) void {
    // Always after a radix 4: m is 4.
    _ = m;
    const tw: f32 = 0.7071067812;
    var f = data;
    for (0..count) |_| {
        const g = f + 4;
        var t = g[0];
        g[0] = sub(f[0], t);
        f[0] = add(f[0], t);
        t = .{ .r = (g[1].r + g[1].i) * tw, .i = (g[1].i - g[1].r) * tw };
        g[1] = sub(f[1], t);
        f[1] = add(f[1], t);
        t = .{ .r = g[2].i, .i = -g[2].r };
        g[2] = sub(f[2], t);
        f[2] = add(f[2], t);
        t = .{ .r = (g[3].i - g[3].r) * tw, .i = -(g[3].i + g[3].r) * tw };
        g[3] = sub(f[3], t);
        f[3] = add(f[3], t);
        f += 8;
    }
}

fn butterfly4(data: [*]Complex, step: usize, m: usize, count: usize, mm: usize) void {
    const tw = &tables.fft_twiddles;
    if (m == 1) {
        var f = data;
        for (0..count) |_| {
            const s0 = sub(f[0], f[2]);
            f[0] = add(f[0], f[2]);
            var s1 = add(f[1], f[3]);
            f[2] = sub(f[0], s1);
            f[0] = add(f[0], s1);
            s1 = sub(f[1], f[3]);
            f[1] = .{ .r = s0.r + s1.i, .i = s0.i - s1.r };
            f[3] = .{ .r = s0.r - s1.i, .i = s0.i + s1.r };
            f += 4;
        }
        return;
    }
    for (0..count) |i| {
        var f = data + i * mm;
        for (0..m) |j| {
            const s0 = mul(f[m], tw[j * step]);
            const s1 = mul(f[2 * m], tw[2 * j * step]);
            const s2 = mul(f[3 * m], tw[3 * j * step]);
            const s5 = sub(f[0], s1);
            f[0] = add(f[0], s1);
            const s3 = add(s0, s2);
            const s4 = sub(s0, s2);
            f[2 * m] = sub(f[0], s3);
            f[0] = add(f[0], s3);
            f[m] = .{ .r = s5.r + s4.i, .i = s5.i - s4.r };
            f[3 * m] = .{ .r = s5.r - s4.i, .i = s5.i + s4.r };
            f += 1;
        }
    }
}

fn butterfly3(data: [*]Complex, step: usize, m: usize, count: usize, mm: usize) void {
    const tw = &tables.fft_twiddles;
    const epi3 = tw[step * m];
    for (0..count) |i| {
        var f = data + i * mm;
        for (0..m) |k| {
            const s1 = mul(f[m], tw[k * step]);
            const s2 = mul(f[2 * m], tw[2 * k * step]);
            const s3 = add(s1, s2);
            var s0 = sub(s1, s2);
            f[m] = .{ .r = f[0].r - 0.5 * s3.r, .i = f[0].i - 0.5 * s3.i };
            s0 = .{ .r = s0.r * epi3[1], .i = s0.i * epi3[1] };
            f[0] = add(f[0], s3);
            f[2 * m] = .{ .r = f[m].r + s0.i, .i = f[m].i - s0.r };
            f[m] = .{ .r = f[m].r - s0.i, .i = f[m].i + s0.r };
            f += 1;
        }
    }
}

fn butterfly5(data: [*]Complex, step: usize, m: usize, count: usize, mm: usize) void {
    const tw = &tables.fft_twiddles;
    const ya = tw[step * m];
    const yb = tw[step * 2 * m];
    for (0..count) |i| {
        const f = data + i * mm;
        for (0..m) |u| {
            const s0 = f[u];
            const s1 = mul(f[m + u], tw[u * step]);
            const s2 = mul(f[2 * m + u], tw[2 * u * step]);
            const s3 = mul(f[3 * m + u], tw[3 * u * step]);
            const s4 = mul(f[4 * m + u], tw[4 * u * step]);
            const s7 = add(s1, s4);
            const s10 = sub(s1, s4);
            const s8 = add(s2, s3);
            const s9 = sub(s2, s3);
            f[u] = .{ .r = f[u].r + (s7.r + s8.r), .i = f[u].i + (s7.i + s8.i) };
            const s5: Complex = .{
                .r = s0.r + (s7.r * ya[0] + s8.r * yb[0]),
                .i = s0.i + (s7.i * ya[0] + s8.i * yb[0]),
            };
            const s6: Complex = .{
                .r = s10.i * ya[1] + s9.i * yb[1],
                .i = -(s10.r * ya[1] + s9.r * yb[1]),
            };
            f[m + u] = sub(s5, s6);
            f[4 * m + u] = add(s5, s6);
            const s11: Complex = .{
                .r = s0.r + (s7.r * yb[0] + s8.r * ya[0]),
                .i = s0.i + (s7.i * yb[0] + s8.i * ya[0]),
            };
            const s12: Complex = .{
                .r = s9.i * ya[1] - s10.i * yb[1],
                .i = s10.r * yb[1] - s9.r * ya[1],
            };
            f[2 * m + u] = add(s11, s12);
            f[3 * m + u] = sub(s11, s12);
        }
    }
}
