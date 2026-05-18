const std = @import("std");
const build_options = @import("build_options");
const native = if (build_options.webgpu) @import("webgpu_native.zig") else struct {};

pub const compiled = build_options.webgpu;

pub const Backend = enum {
    cpu,
    webgpu,
};

pub const FallbackPolicy = enum {
    fail,
    allow_cpu,
};

pub const Request = struct {
    backend: Backend = .cpu,
    fallback: FallbackPolicy = .fail,
};

pub const processing_gpu_env_var = "V600_PROCESSING_GPU";

pub const Capability = struct {
    compiled: bool,

    pub fn current() Capability {
        return .{ .compiled = compiled };
    }
};

pub const SmokeOptions = struct {
    allow_no_adapter: bool = false,
    timeout_ns: u64 = 5_000_000_000,
};

pub const ComputeOptions = struct {
    timeout_ns: u64 = 5_000_000_000,
};

pub const SigmoidKernelParams = struct {
    white_target: f64,
    paper_exposure: f64,
    film_fog: f64,
    film_power: f64,
    paper_power: f64,
};

pub const InvertNegativeKernelParams = struct {
    dmin: [3]f64,
    coeffs: [10][3]f64,
    default_light: f64 = 65535.0,
};

pub const SigmoidBenchmarkOptions = struct {
    e2e_iterations: usize,
    resident_iterations: usize,
    timeout_ns: u64 = 5_000_000_000,
};

pub const InvertNegativeBenchmarkOptions = SigmoidBenchmarkOptions;

pub const SigmoidBenchmarkResult = struct {
    bytes_uploaded: usize,
    bytes_downloaded: usize,
    gpu_e2e_ns: u64,
    gpu_resident_ns: u64,
    backend: []const u8,
    adapter: []const u8,

    pub fn deinit(self: SigmoidBenchmarkResult, allocator: std.mem.Allocator) void {
        allocator.free(self.adapter);
    }
};

pub const InvertNegativeBenchmarkResult = SigmoidBenchmarkResult;

pub fn requireCompiled() !void {
    if (!compiled) return error.WebGpuNotCompiled;
}

pub fn canUseWebGpu(request: Request) bool {
    return request.backend == .webgpu and compiled;
}

pub fn shouldUseCpu(request: Request) !bool {
    return switch (request.backend) {
        .cpu => true,
        .webgpu => if (compiled) false else switch (request.fallback) {
            .fail => error.WebGpuNotCompiled,
            .allow_cpu => true,
        },
    };
}

pub fn requestFromEnvironment(environ_map: *const std.process.Environ.Map) !Request {
    const value = environ_map.get(processing_gpu_env_var) orelse return .{};
    if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "")) return .{};
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "webgpu")) {
        return .{ .backend = .webgpu };
    }
    if (std.mem.eql(u8, value, "allow-cpu") or std.mem.eql(u8, value, "webgpu-allow-cpu")) {
        return .{ .backend = .webgpu, .fallback = .allow_cpu };
    }
    return error.InvalidProcessingGpuEnv;
}

pub fn runAdapterDeviceSmoke(stdout: anytype, options: SmokeOptions) !void {
    try requireCompiled();
    return native.runAdapterDeviceSmoke(stdout, options);
}

pub fn applySigmoidKernel(
    allocator: std.mem.Allocator,
    input: []const f64,
    params: SigmoidKernelParams,
    options: ComputeOptions,
) ![]f64 {
    try requireCompiled();
    if (comptime compiled) {
        return native.applySigmoidKernel(allocator, input, params, options);
    }
    unreachable;
}

pub fn applyInvertNegativeKernel(
    allocator: std.mem.Allocator,
    input: []const f64,
    params: InvertNegativeKernelParams,
    options: ComputeOptions,
) ![]f64 {
    try requireCompiled();
    if (comptime compiled) {
        return native.applyInvertNegativeKernel(allocator, input, params, options);
    }
    unreachable;
}

pub fn benchmarkApplySigmoidKernel(
    allocator: std.mem.Allocator,
    input: []const f64,
    params: SigmoidKernelParams,
    options: SigmoidBenchmarkOptions,
) !SigmoidBenchmarkResult {
    try requireCompiled();
    if (comptime compiled) {
        return native.benchmarkApplySigmoidKernel(allocator, input, params, options);
    }
    unreachable;
}

pub fn benchmarkInvertNegativeKernel(
    allocator: std.mem.Allocator,
    input: []const f64,
    params: InvertNegativeKernelParams,
    options: InvertNegativeBenchmarkOptions,
) !InvertNegativeBenchmarkResult {
    try requireCompiled();
    if (comptime compiled) {
        return native.benchmarkInvertNegativeKernel(allocator, input, params, options);
    }
    unreachable;
}

test "WebGPU capability flag is compile-time accessible" {
    try std.testing.expectEqual(build_options.webgpu, compiled);
    try std.testing.expectEqual(compiled, Capability.current().compiled);
}

test "CPU backend is the default request" {
    const request = Request{};
    try std.testing.expectEqual(Backend.cpu, request.backend);
    try std.testing.expect(try shouldUseCpu(request));
    try std.testing.expect(!canUseWebGpu(request));
}

test "explicit WebGPU request reports compile-time availability" {
    const request = Request{ .backend = .webgpu };
    if (compiled) {
        try requireCompiled();
        try std.testing.expect(!try shouldUseCpu(request));
        try std.testing.expect(canUseWebGpu(request));
    } else {
        try std.testing.expectError(error.WebGpuNotCompiled, requireCompiled());
        try std.testing.expectError(error.WebGpuNotCompiled, shouldUseCpu(request));
        try std.testing.expect(!canUseWebGpu(request));
    }
}

test "explicit WebGPU request can opt into CPU fallback when not compiled" {
    const request = Request{ .backend = .webgpu, .fallback = .allow_cpu };
    if (compiled) {
        try std.testing.expect(!try shouldUseCpu(request));
    } else {
        try std.testing.expect(try shouldUseCpu(request));
    }
}

test "runtime request parser honors processing GPU env" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectEqual(Backend.cpu, (try requestFromEnvironment(&env)).backend);
    try env.put(processing_gpu_env_var, "0");
    try std.testing.expectEqual(Backend.cpu, (try requestFromEnvironment(&env)).backend);
    try env.put(processing_gpu_env_var, "1");
    const webgpu_request = try requestFromEnvironment(&env);
    try std.testing.expectEqual(Backend.webgpu, webgpu_request.backend);
    try std.testing.expectEqual(FallbackPolicy.fail, webgpu_request.fallback);

    try env.put(processing_gpu_env_var, "allow-cpu");
    const fallback_request = try requestFromEnvironment(&env);
    try std.testing.expectEqual(Backend.webgpu, fallback_request.backend);
    try std.testing.expectEqual(FallbackPolicy.allow_cpu, fallback_request.fallback);

    try env.put(processing_gpu_env_var, "yes-please");
    try std.testing.expectError(error.InvalidProcessingGpuEnv, requestFromEnvironment(&env));
}

test "adapter-device smoke capability is gated by compile option" {
    if (compiled) {
        try requireCompiled();
    } else {
        try std.testing.expectError(error.WebGpuNotCompiled, requireCompiled());
    }
}

test "apply sigmoid kernel capability is gated by compile option" {
    if (compiled) return;
    try std.testing.expectError(
        error.WebGpuNotCompiled,
        applySigmoidKernel(std.testing.allocator, &.{ 0.0, 0.1, 0.2 }, .{
            .white_target = 1.0,
            .paper_exposure = 1.0,
            .film_fog = 0.0,
            .film_power = 1.0,
            .paper_power = 1.0,
        }, .{}),
    );
}

test "invert negative kernel capability is gated by compile option" {
    if (compiled) return;
    try std.testing.expectError(
        error.WebGpuNotCompiled,
        applyInvertNegativeKernel(std.testing.allocator, &.{ 0.0, 0.1, 0.2 }, .{
            .dmin = .{ 0.0, 0.0, 0.0 },
            .coeffs = std.mem.zeroes([10][3]f64),
        }, .{}),
    );
}
