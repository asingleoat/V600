const std = @import("std");
const v600 = @import("v600");

const film_stocks = v600.processing.film_stocks;
const inversion = v600.processing.inversion;
const numeric = v600.processing.numeric_fixture;
const webgpu = v600.processing.webgpu;

const fixture_path = "test/fixtures/processing/numeric/invert-negative-kodak-gold-dmin.json";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const request = inversion.invertNegativeRequestFromEnvironment(init.environ_map) catch |err| {
        try stdout.print(
            "processing_gpu_runtime,operation,invert_negative,status,error,native_backend,wgpu-native,adapter,unknown,request,invalid,fallback,unknown,error,{s}\n",
            .{@errorName(err)},
        );
        return err;
    };

    var adapter_label: []const u8 = "unused";
    if (request.backend == .webgpu and webgpu.compiled) {
        webgpu.runAdapterDeviceSmoke(stdout, .{}) catch |err| {
            try stdout.print(
                "processing_gpu_runtime,operation,invert_negative,status,error,native_backend,wgpu-native,adapter,unknown,request,webgpu,fallback,{s},error,{s}\n",
                .{ fallbackName(request.fallback), @errorName(err) },
            );
            return err;
        };
        adapter_label = "selected";
    }

    var fixture = try numeric.loadJsonFixture(allocator, init.io, fixture_path);
    defer fixture.deinit();
    const value = fixture.value();

    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    _ = inversion.invertNegative(allocator, value.input, actual, .{
        .dmin = .{ 0.2, 0.1, 0.05 },
        .coeffs = film_stocks.kodak_gold_coeffs,
        .request = request,
    }) catch |err| {
        try stdout.print(
            "processing_gpu_runtime,operation,invert_negative,status,error,native_backend,wgpu-native,adapter,unknown,request,{s},fallback,{s},error,{s}\n",
            .{ backendName(request.backend), fallbackName(request.fallback), @errorName(err) },
        );
        return err;
    };

    const stats = try numeric.errorStats(value.expected, actual);
    if (numeric.assertCloseSlices(value.expected, actual, value.tolerance)) {
        try stdout.print(
            "processing_gpu_runtime,operation,invert_negative,status,ok,native_backend,wgpu-native,adapter,{s},request,{s},fallback,{s},count,{d},max_abs,{d:.9},rms,{d:.9},compiled,{}\n",
            .{
                adapter_label,
                backendName(request.backend),
                fallbackName(request.fallback),
                actual.len,
                stats.max_abs,
                stats.rms,
                webgpu.compiled,
            },
        );
    } else |err| {
        try stdout.print(
            "processing_gpu_runtime,operation,invert_negative,status,mismatch,native_backend,wgpu-native,adapter,{s},request,{s},fallback,{s},count,{d},max_abs,{d:.9},rms,{d:.9},error,{s}\n",
            .{
                adapter_label,
                backendName(request.backend),
                fallbackName(request.fallback),
                actual.len,
                stats.max_abs,
                stats.rms,
                @errorName(err),
            },
        );
        return err;
    }
}

fn backendName(backend: webgpu.Backend) []const u8 {
    return switch (backend) {
        .cpu => "cpu",
        .webgpu => "webgpu",
    };
}

fn fallbackName(fallback: webgpu.FallbackPolicy) []const u8 {
    return switch (fallback) {
        .fail => "fail",
        .allow_cpu => "allow_cpu",
    };
}
