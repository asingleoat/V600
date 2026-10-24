//! Fourier transforms of any length, for the dust fills' grain spectra:
//! mixed radix over the length's factors (decimation in time, each stage's
//! output in order, as KISS FFT does it), or Bluestein's chirp z-transform
//! through a power-of-two transform when a prime factor is large.

const std = @import("std");

pub const Complex = std.math.Complex(f64);

/// Prime factors up to this run as direct butterflies, at a cost of p^2 per
/// group; a length with a larger one goes through Bluestein.
const max_direct_radix = 31;

pub const PlanError = std.mem.Allocator.Error || error{ InvalidFftLength, Overflow };

pub const Plan = struct {
    len: usize,
    /// Radices in the order the stages apply them; their product is `len`.
    radices: []usize,
    /// exp(-2 pi i k / len) for k below len.
    twiddles: []Complex,
    bluestein: ?*Bluestein = null,
    /// For the inverse transform's conjugated input.
    scratch: []Complex,

    pub fn init(allocator: std.mem.Allocator, len: usize) PlanError!Plan {
        if (len == 0) return error.InvalidFftLength;
        const scratch = try allocator.alloc(Complex, len);
        errdefer allocator.free(scratch);
        const radices = try factor(allocator, len);
        if (radices[radices.len - 1] > max_direct_radix) {
            allocator.free(radices);
            const bluestein = try allocator.create(Bluestein);
            errdefer allocator.destroy(bluestein);
            bluestein.* = try Bluestein.init(allocator, len);
            return .{ .len = len, .radices = &.{}, .twiddles = &.{}, .bluestein = bluestein, .scratch = scratch };
        }
        errdefer allocator.free(radices);
        const twiddles = try allocator.alloc(Complex, len);
        for (twiddles, 0..) |*twiddle, k| twiddle.* = unitRoot(k, len);
        return .{ .len = len, .radices = radices, .twiddles = twiddles, .scratch = scratch };
    }

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        if (self.bluestein) |bluestein| {
            bluestein.deinit(allocator);
            allocator.destroy(bluestein);
        } else {
            allocator.free(self.radices);
            allocator.free(self.twiddles);
        }
        allocator.free(self.scratch);
        self.* = undefined;
    }

    /// output[k] = sum over j of input[j] exp(-2 pi i jk / len).
    pub fn forward(self: *Plan, input: []const Complex, output: []Complex) void {
        std.debug.assert(input.len == self.len and output.len == self.len);
        if (self.bluestein) |bluestein| return bluestein.transform(input, output);
        self.work(output, input, 0, 1, 0);
    }

    /// output[k] = sum over j of input[j] exp(+2 pi i jk / len), unscaled.
    pub fn inverse(self: *Plan, input: []const Complex, output: []Complex) void {
        for (self.scratch, input) |*value, x| value.* = x.conjugate();
        self.forward(self.scratch, output);
        for (output) |*value| value.* = value.conjugate();
    }

    fn work(self: *const Plan, output: []Complex, input: []const Complex, offset: usize, stride: usize, level: usize) void {
        const p = self.radices[level];
        const m = output.len / p;
        if (m == 1) {
            for (output, 0..) |*out, q| out.* = input[offset + q * stride];
        } else {
            for (0..p) |q| self.work(output[q * m ..][0..m], input, offset + q * stride, stride * p, level + 1);
        }
        // The stride into the input is also the twiddle step for this stage.
        switch (p) {
            2 => self.butterfly2(output, stride, m),
            4 => self.butterfly4(output, stride, m),
            else => self.butterflyGeneric(output, stride, m, p),
        }
    }

    fn butterfly2(self: *const Plan, out: []Complex, stride: usize, m: usize) void {
        for (0..m) |k| {
            const t = out[k + m].mul(self.twiddles[k * stride]);
            out[k + m] = out[k].sub(t);
            out[k] = out[k].add(t);
        }
    }

    fn butterfly4(self: *const Plan, out: []Complex, stride: usize, m: usize) void {
        for (0..m) |k| {
            const s0 = out[k + m].mul(self.twiddles[k * stride]);
            const s1 = out[k + 2 * m].mul(self.twiddles[2 * k * stride]);
            const s2 = out[k + 3 * m].mul(self.twiddles[3 * k * stride]);
            const s5 = out[k].sub(s1);
            const s0_plus = out[k].add(s1);
            const s3 = s0.add(s2);
            const s4 = s0.sub(s2);
            out[k + 2 * m] = s0_plus.sub(s3);
            out[k] = s0_plus.add(s3);
            out[k + m] = .{ .re = s5.re + s4.im, .im = s5.im - s4.re };
            out[k + 3 * m] = .{ .re = s5.re - s4.im, .im = s5.im + s4.re };
        }
    }

    fn butterflyGeneric(self: *const Plan, out: []Complex, stride: usize, m: usize, p: usize) void {
        var gathered: [max_direct_radix]Complex = undefined;
        for (0..m) |u| {
            for (0..p) |q| gathered[q] = out[u + q * m];
            for (0..p) |q1| {
                const k = u + q1 * m;
                var sum = gathered[0];
                var index: usize = 0;
                for (1..p) |q| {
                    index += stride * k;
                    if (index >= self.len) index %= self.len;
                    sum = sum.add(gathered[q].mul(self.twiddles[index]));
                }
                out[k] = sum;
            }
        }
    }
};

/// The length's prime factors, fours first, smallest to largest otherwise.
fn factor(allocator: std.mem.Allocator, len: usize) ![]usize {
    var radices: std.ArrayList(usize) = .empty;
    errdefer radices.deinit(allocator);
    var rest = len;
    while (rest % 4 == 0) : (rest /= 4) try radices.append(allocator, 4);
    while (rest % 2 == 0) : (rest /= 2) try radices.append(allocator, 2);
    var p: usize = 3;
    while (p * p <= rest) : (p += 2) {
        while (rest % p == 0) : (rest /= p) try radices.append(allocator, p);
    }
    if (rest > 1 or radices.items.len == 0) try radices.append(allocator, rest);
    return radices.toOwnedSlice(allocator);
}

fn unitRoot(k: usize, n: usize) Complex {
    const angle = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
    return .{ .re = @cos(angle), .im = @sin(angle) };
}

/// A length-n transform as a circular convolution of power-of-two length:
/// with jk = (j^2 + k^2 - (k - j)^2) / 2, X[k] = w[k] sum_j (x[j] w[j])
/// conj(w[k - j]), where w[j] = exp(-pi i j^2 / n).
const Bluestein = struct {
    len: usize,
    chirp: []Complex,
    /// The transform of conj(w) laid out circularly.
    kernel: []Complex,
    inner: Plan,
    work_a: []Complex,
    work_b: []Complex,

    fn init(allocator: std.mem.Allocator, len: usize) PlanError!Bluestein {
        const padded = try std.math.ceilPowerOfTwo(usize, 2 * len - 1);
        var inner = try Plan.init(allocator, padded);
        errdefer inner.deinit(allocator);
        const chirp = try allocator.alloc(Complex, len);
        errdefer allocator.free(chirp);
        for (chirp, 0..) |*value, j| {
            // j^2 taken modulo 2n keeps the angle small and exact.
            const angle = -std.math.pi * @as(f64, @floatFromInt((j * j) % (2 * len))) / @as(f64, @floatFromInt(len));
            value.* = .{ .re = @cos(angle), .im = @sin(angle) };
        }
        const kernel = try allocator.alloc(Complex, padded);
        errdefer allocator.free(kernel);
        const work_a = try allocator.alloc(Complex, padded);
        errdefer allocator.free(work_a);
        const work_b = try allocator.alloc(Complex, padded);
        errdefer allocator.free(work_b);
        @memset(work_a, .{ .re = 0.0, .im = 0.0 });
        for (chirp, 0..) |value, j| {
            work_a[j] = value.conjugate();
            if (j > 0) work_a[padded - j] = value.conjugate();
        }
        inner.forward(work_a, kernel);
        return .{ .len = len, .chirp = chirp, .kernel = kernel, .inner = inner, .work_a = work_a, .work_b = work_b };
    }

    fn deinit(self: *Bluestein, allocator: std.mem.Allocator) void {
        self.inner.deinit(allocator);
        allocator.free(self.chirp);
        allocator.free(self.kernel);
        allocator.free(self.work_a);
        allocator.free(self.work_b);
    }

    fn transform(self: *Bluestein, input: []const Complex, output: []Complex) void {
        @memset(self.work_a, .{ .re = 0.0, .im = 0.0 });
        for (self.work_a[0..self.len], input, self.chirp) |*a, x, w| a.* = x.mul(w);
        self.inner.forward(self.work_a, self.work_b);
        // The convolution's inverse transform, through the conjugate.
        for (self.work_b, self.kernel) |*b, k| b.* = b.mul(k).conjugate();
        self.inner.forward(self.work_b, self.work_a);
        const scale = 1.0 / @as(f64, @floatFromInt(self.work_a.len));
        for (output, self.work_a[0..self.len], self.chirp) |*out, c, w| {
            out.* = c.conjugate().mul(w).mul(.{ .re = scale, .im = 0.0 });
        }
    }
};

/// The 2-D transform of a real image (`width` per row): rows, then columns.
pub fn forwardReal2d(allocator: std.mem.Allocator, input: []const f64, width: usize, height: usize, output: []Complex) !void {
    if (input.len != width * height or output.len != input.len) return error.InvalidFftBuffer;
    var rows = try Plan.init(allocator, width);
    defer rows.deinit(allocator);
    const row_in = try allocator.alloc(Complex, width);
    defer allocator.free(row_in);
    for (0..height) |y| {
        for (row_in, input[y * width ..][0..width]) |*value, x| value.* = .{ .re = x, .im = 0.0 };
        rows.forward(row_in, output[y * width ..][0..width]);
    }
    try transformColumns(allocator, output, width, height, .forward);
}

/// The inverse 2-D transform, scaled by 1 / (width height), keeping the real
/// part (the input is the transform of a real image).
pub fn inverseToReal2d(allocator: std.mem.Allocator, input: []const Complex, width: usize, height: usize, output: []f64) !void {
    if (input.len != width * height or output.len != input.len) return error.InvalidFftBuffer;
    const values = try allocator.dupe(Complex, input);
    defer allocator.free(values);
    try transformColumns(allocator, values, width, height, .inverse);
    var rows = try Plan.init(allocator, width);
    defer rows.deinit(allocator);
    const row_out = try allocator.alloc(Complex, width);
    defer allocator.free(row_out);
    const scale = 1.0 / @as(f64, @floatFromInt(width * height));
    for (0..height) |y| {
        rows.inverse(values[y * width ..][0..width], row_out);
        for (output[y * width ..][0..width], row_out) |*out, value| out.* = value.re * scale;
    }
}

fn transformColumns(allocator: std.mem.Allocator, values: []Complex, width: usize, height: usize, direction: enum { forward, inverse }) !void {
    var columns = try Plan.init(allocator, height);
    defer columns.deinit(allocator);
    const column_in = try allocator.alloc(Complex, height);
    defer allocator.free(column_in);
    const column_out = try allocator.alloc(Complex, height);
    defer allocator.free(column_out);
    for (0..width) |x| {
        for (column_in, 0..) |*value, y| value.* = values[y * width + x];
        switch (direction) {
            .forward => columns.forward(column_in, column_out),
            .inverse => columns.inverse(column_in, column_out),
        }
        for (column_out, 0..) |value, y| values[y * width + x] = value;
    }
}

fn directDft(input: []const Complex, output: []Complex) void {
    for (output, 0..) |*out, k| {
        var sum = Complex{ .re = 0.0, .im = 0.0 };
        for (input, 0..) |x, j| sum = sum.add(x.mul(unitRoot((j * k) % input.len, input.len)));
        out.* = sum;
    }
}

test "transforms of many lengths match the direct DFT" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    const lengths = [_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 15, 16, 17, 25, 27, 30, 31, 32, 37, 49, 60, 61, 64, 97, 100, 101, 128, 210, 243, 256, 257, 331, 500, 509, 1000, 1021 };
    for (lengths) |len| {
        const input = try allocator.alloc(Complex, len);
        defer allocator.free(input);
        for (input) |*value| value.* = .{ .re = random.float(f64) - 0.5, .im = random.float(f64) - 0.5 };
        const expected = try allocator.alloc(Complex, len);
        defer allocator.free(expected);
        directDft(input, expected);
        const actual = try allocator.alloc(Complex, len);
        defer allocator.free(actual);
        var plan = try Plan.init(allocator, len);
        defer plan.deinit(allocator);
        plan.forward(input, actual);
        const tolerance = 1e-12 * @as(f64, @floatFromInt(len));
        for (expected, actual) |e, a| {
            try std.testing.expectApproxEqAbs(e.re, a.re, tolerance);
            try std.testing.expectApproxEqAbs(e.im, a.im, tolerance);
        }
        // The inverse undoes it, up to the length.
        const back = try allocator.alloc(Complex, len);
        defer allocator.free(back);
        plan.inverse(actual, back);
        for (input, back) |x, b| {
            try std.testing.expectApproxEqAbs(x.re, b.re / @as(f64, @floatFromInt(len)), 1e-12);
            try std.testing.expectApproxEqAbs(x.im, b.im / @as(f64, @floatFromInt(len)), 1e-12);
        }
    }
}

test "2-D real transform and its inverse round-trip" {
    const allocator = std.testing.allocator;
    const width = 37;
    const height = 24;
    var image: [width * height]f64 = undefined;
    for (&image, 0..) |*value, index| value.* = @sin(@as(f64, @floatFromInt(index)) * 0.37) + @as(f64, @floatFromInt(index % 7));
    var spectrum: [width * height]Complex = undefined;
    try forwardReal2d(allocator, &image, width, height, &spectrum);
    // The DC term is the sum.
    var total: f64 = 0.0;
    for (image) |value| total += value;
    try std.testing.expectApproxEqAbs(total, spectrum[0].re, 1e-9);
    var back: [width * height]f64 = undefined;
    try inverseToReal2d(allocator, &spectrum, width, height, &back);
    for (image, back) |expected, actual| try std.testing.expectApproxEqAbs(expected, actual, 1e-12);
}
