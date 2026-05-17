const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_ui = b.option(bool, "ui", "Build the SDL3/Nuklear native UI") orelse false;

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.linkSystemLibrary("c", .{});
    root_module.linkSystemLibrary("libtiff-4", .{});
    root_module.linkSystemLibrary("zlib", .{ .use_pkg_config = .force });
    root_module.linkSystemLibrary("libjpeg", .{ .use_pkg_config = .force });
    root_module.linkSystemLibrary("opencv4", .{ .use_pkg_config = .force });
    root_module.linkSystemLibrary("superlu", .{ .use_pkg_config = .no });

    const ecc_obj_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "c++ -std=c++17 -fPIC -fno-exceptions $(pkg-config --cflags opencv4) -c \"$1\" -o \"$2\"",
        "compile-opencv-ecc",
    });
    ecc_obj_cmd.addFileArg(b.path("src/processing/opencv_ecc.cpp"));
    const ecc_obj = ecc_obj_cmd.addOutputFileArg("opencv_ecc.o");
    root_module.addObjectFile(ecc_obj);

    const ir_obj_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "c++ -std=c++17 -fPIC -fno-exceptions $(pkg-config --cflags opencv4) -c \"$1\" -o \"$2\"",
        "compile-opencv-ir",
    });
    ir_obj_cmd.addFileArg(b.path("src/processing/opencv_ir.cpp"));
    const ir_obj = ir_obj_cmd.addOutputFileArg("opencv_ir.o");
    root_module.addObjectFile(ir_obj);

    const preview_obj_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "c++ -std=c++17 -fPIC -fno-exceptions $(pkg-config --cflags opencv4) -c \"$1\" -o \"$2\"",
        "compile-opencv-preview",
    });
    preview_obj_cmd.addFileArg(b.path("src/processing/opencv_preview.cpp"));
    const preview_obj = preview_obj_cmd.addOutputFileArg("opencv_preview.o");
    root_module.addObjectFile(preview_obj);

    const jpeg_obj_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cc -std=c99 -fPIC $(pkg-config --cflags libjpeg) -c \"$1\" -o \"$2\"",
        "compile-jpeg-encode",
    });
    jpeg_obj_cmd.addFileArg(b.path("src/processing/jpeg_encode.c"));
    const jpeg_obj = jpeg_obj_cmd.addOutputFileArg("jpeg_encode.o");
    root_module.addObjectFile(jpeg_obj);

    const sparse_obj_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cc -std=c99 -fPIC -c \"$1\" -o \"$2\"",
        "compile-superlu-sparse",
    });
    sparse_obj_cmd.addFileArg(b.path("src/processing/superlu_sparse.c"));
    const sparse_obj = sparse_obj_cmd.addOutputFileArg("superlu_sparse.o");
    root_module.addObjectFile(sparse_obj);

    const exe = b.addExecutable(.{
        .name = "v600-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "v600", .module = root_module },
            },
        }),
    });
    b.installArtifact(exe);

    if (enable_ui) {
        const nuklear_obj_cmd = b.addSystemCommand(&.{
            "sh",
            "-c",
            "cc -std=c99 -fPIC $(pkg-config --cflags nuklear) -c \"$1\" -o \"$2\"",
            "compile-nuklear",
        });
        nuklear_obj_cmd.addFileArg(b.path("src/ui/nuklear_impl.c"));
        const nuklear_obj = nuklear_obj_cmd.addOutputFileArg("nuklear_impl.o");

        const ui_module = b.createModule(.{
            .root_source_file = b.path("src/ui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "v600", .module = root_module },
            },
        });
        ui_module.linkSystemLibrary("c", .{});
        ui_module.linkSystemLibrary("m", .{});
        ui_module.linkSystemLibrary("sdl3", .{ .use_pkg_config = .force });
        ui_module.linkSystemLibrary("nuklear", .{ .use_pkg_config = .force });
        ui_module.addObjectFile(nuklear_obj);

        const ui_exe = b.addExecutable(.{
            .name = "v600-ui",
            .root_module = ui_module,
        });
        b.installArtifact(ui_exe);

        const ui_run_cmd = b.addRunArtifact(ui_exe);
        if (b.args) |args| {
            ui_run_cmd.addArgs(args);
        }
        const ui_run_step = b.step("run-ui", "Run the SDL3/Nuklear native UI");
        ui_run_step.dependOn(&ui_run_cmd.step);

        const ui_smoke_cmd = b.addRunArtifact(ui_exe);
        ui_smoke_cmd.addArg("--smoke");
        const ui_smoke_step = b.step("ui-smoke", "Run one native UI frame and exit");
        ui_smoke_step.dependOn(&ui_smoke_cmd.step);

        const scanner_connect_smoke_cmd = b.addRunArtifact(ui_exe);
        scanner_connect_smoke_cmd.addArg("--scanner-connect-smoke");
        const scanner_connect_smoke_step = b.step("native-scanner-connect-smoke", "Verify native scanner startup begins in connecting state");
        scanner_connect_smoke_step.dependOn(&scanner_connect_smoke_cmd.step);

        const process_worker_smoke_cmd = b.addRunArtifact(ui_exe);
        process_worker_smoke_cmd.addArg("--process-worker-smoke");
        const process_worker_smoke_step = b.step("native-process-worker-smoke", "Verify native Process worker keeps the UI responsive for a frame");
        process_worker_smoke_step.dependOn(&process_worker_smoke_cmd.step);

        const process_dump_smoke_cmd = b.addRunArtifact(ui_exe);
        process_dump_smoke_cmd.addArg("--process-dump-smoke");
        const process_dump_smoke_step = b.step("native-process-dump-smoke", "Verify native Process selection dump diagnostics");
        process_dump_smoke_step.dependOn(&process_dump_smoke_cmd.step);

        const preview_worker_smoke_skip_cmd = b.addRunArtifact(ui_exe);
        preview_worker_smoke_skip_cmd.clearEnvironment();
        preview_worker_smoke_skip_cmd.addArg("--preview-worker-smoke");
        const preview_worker_smoke_skip_step = b.step("native-preview-worker-smoke-skip", "Verify native preview hardware smoke skips without V600_HARDWARE_SMOKE=1");
        preview_worker_smoke_skip_step.dependOn(&preview_worker_smoke_skip_cmd.step);

        const scan_worker_smoke_skip_cmd = b.addRunArtifact(ui_exe);
        scan_worker_smoke_skip_cmd.clearEnvironment();
        scan_worker_smoke_skip_cmd.addArg("--scan-worker-smoke");
        const scan_worker_smoke_skip_step = b.step("native-scan-worker-smoke-skip", "Verify native scan hardware smoke skips without V600_HARDWARE_SMOKE=1");
        scan_worker_smoke_skip_step.dependOn(&scan_worker_smoke_skip_cmd.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the V600 Zig CLI");
    run_step.dependOn(&run_cmd.step);

    const smoke_cmd = b.addRunArtifact(exe);
    smoke_cmd.addArgs(&.{ "scanner", "smoke" });
    const smoke_step = b.step("scanner-smoke", "Run gated scanner hardware smoke test");
    smoke_step.dependOn(&smoke_cmd.step);

    const scanner_smoke_skip_cmd = b.addRunArtifact(exe);
    scanner_smoke_skip_cmd.clearEnvironment();
    scanner_smoke_skip_cmd.addArgs(&.{ "scanner", "smoke" });
    const scanner_smoke_skip_step = b.step("scanner-smoke-skip", "Verify scanner hardware smoke skips without V600_HARDWARE_SMOKE=1");
    scanner_smoke_skip_step.dependOn(&scanner_smoke_skip_cmd.step);

    const scanner_processing_smoke_skip_cmd = b.addRunArtifact(exe);
    scanner_processing_smoke_skip_cmd.clearEnvironment();
    scanner_processing_smoke_skip_cmd.addArgs(&.{ "scanner", "processing-smoke" });
    const scanner_processing_smoke_skip_step = b.step("scanner-processing-smoke-skip", "Verify scanner processing smoke skips without V600_HARDWARE_SMOKE=1");
    scanner_processing_smoke_skip_step.dependOn(&scanner_processing_smoke_skip_cmd.step);

    const macos_scanner_smoke_skip_cmd = b.addRunArtifact(exe);
    macos_scanner_smoke_skip_cmd.clearEnvironment();
    macos_scanner_smoke_skip_cmd.addArgs(&.{ "scanner", "macos-smoke" });
    const macos_scanner_smoke_skip_step = b.step("macos-scanner-smoke-skip", "Verify future macOS scanner hardware smoke skips without V600_MACOS_HARDWARE_SMOKE=1");
    macos_scanner_smoke_skip_step.dependOn(&macos_scanner_smoke_skip_cmd.step);

    const bench_color = b.addExecutable(.{
        .name = "bench-color-paths",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks/color_paths.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "v600", .module = root_module },
            },
        }),
    });
    const bench_color_cmd = b.addRunArtifact(bench_color);
    const bench_color_step = b.step("bench-color", "Run headless processing color-path benchmarks");
    bench_color_step.dependOn(&bench_color_cmd.step);

    const bench_gpu_readiness_cmd = b.addRunArtifact(bench_color);
    bench_gpu_readiness_cmd.addArg("--gpu-readiness-gate");
    const bench_gpu_readiness_step = b.step("bench-gpu-readiness", "Run CPU benchmark coverage gate before GPU backend work");
    bench_gpu_readiness_step.dependOn(&bench_gpu_readiness_cmd.step);

    const bench_ir_inpaint = b.addExecutable(.{
        .name = "bench-ir-inpaint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks/ir_inpaint.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "v600", .module = root_module },
            },
        }),
    });
    const bench_ir_inpaint_cmd = b.addRunArtifact(bench_ir_inpaint);
    const bench_ir_inpaint_step = b.step("bench-ir-inpaint", "Run headless IR biharmonic inpaint benchmark");
    bench_ir_inpaint_step.dependOn(&bench_ir_inpaint_cmd.step);

    const bench_processing_commands = b.addExecutable(.{
        .name = "bench-processing-commands",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks/processing_commands.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "v600", .module = root_module },
            },
        }),
    });
    const bench_processing_commands_cmd = b.addRunArtifact(bench_processing_commands);
    if (b.args) |args| {
        bench_processing_commands_cmd.addArgs(args);
    }
    const bench_processing_commands_step = b.step("bench-processing-commands", "Run user-visible Process command benchmarks");
    bench_processing_commands_step.dependOn(&bench_processing_commands_cmd.step);

    const tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_tests.step);
}
