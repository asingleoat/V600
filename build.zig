const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_ui = b.option(bool, "ui", "Build the SDL3/Nuklear native UI") orelse false;
    const enable_webgpu = b.option(bool, "webgpu", "Build the optional WebGPU processing backend") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "webgpu", enable_webgpu);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", build_options);
    root_module.linkSystemLibrary("c", .{});
    root_module.linkSystemLibrary("libtiff-4", .{});
    root_module.linkSystemLibrary("zlib", .{ .use_pkg_config = .force });
    root_module.linkSystemLibrary("libjpeg", .{ .use_pkg_config = .force });
    root_module.linkSystemLibrary("opencv4", .{ .use_pkg_config = .force });
    root_module.linkSystemLibrary("superlu", .{ .use_pkg_config = .no });

    if (enable_webgpu) {
        const include_dir = requiredEnvPath(b, "WGPU_NATIVE_INCLUDE_DIR");
        const library_dir = requiredEnvPath(b, "WGPU_NATIVE_LIBRARY_DIR");
        root_module.addSystemIncludePath(.{ .cwd_relative = include_dir });
        root_module.addLibraryPath(.{ .cwd_relative = library_dir });
        root_module.addRPath(.{ .cwd_relative = library_dir });
        root_module.linkSystemLibrary("wgpu_native", .{ .use_pkg_config = .no });
    }

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

        const process_export_smoke_cmd = b.addRunArtifact(ui_exe);
        process_export_smoke_cmd.addArg("--process-export-smoke");
        const process_export_smoke_step = b.step("native-process-export-smoke", "Verify native Process export flow starts from the UI");
        process_export_smoke_step.dependOn(&process_export_smoke_cmd.step);

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

    const wasm_build_options = b.addOptions();
    wasm_build_options.addOption(bool, "webgpu", false);
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm64,
        .os_tag = .freestanding,
    });
    const wasm_optimize: std.builtin.OptimizeMode = switch (optimize) {
        .Debug => .ReleaseFast,
        else => optimize,
    };
    const wasm_core_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_core.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
        .single_threaded = true,
    });
    wasm_core_module.addOptions("build_options", wasm_build_options);
    const wasm_core = b.addExecutable(.{
        .name = "v600-wasm-core",
        .root_module = wasm_core_module,
    });
    wasm_core.entry = .disabled;
    wasm_core.rdynamic = true;
    wasm_core.export_memory = true;
    const install_wasm_core = b.addInstallArtifact(wasm_core, .{});
    const wasm_core_step = b.step("wasm-core", "Build the dependency-free browser WebAssembly processing core");
    wasm_core_step.dependOn(&install_wasm_core.step);

    const wasm32_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm32_core_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_core.zig"),
        .target = wasm32_target,
        .optimize = wasm_optimize,
        .single_threaded = true,
    });
    wasm32_core_module.addOptions("build_options", wasm_build_options);
    const wasm32_core = b.addExecutable(.{
        .name = "v600-wasm-core32",
        .root_module = wasm32_core_module,
    });
    wasm32_core.entry = .disabled;
    wasm32_core.rdynamic = true;
    wasm32_core.export_memory = true;
    const install_wasm32_core = b.addInstallArtifact(wasm32_core, .{});
    const wasm32_core_step = b.step("wasm32-core", "Build the optional wasm32 compatibility processing core");
    wasm32_core_step.dependOn(&install_wasm32_core.step);

    const wasm32_core_smoke_cmd = b.addSystemCommand(&.{"node"});
    wasm32_core_smoke_cmd.addFileArg(b.path("test/wasm/wasm_core_smoke.mjs"));
    wasm32_core_smoke_cmd.addFileArg(wasm32_core.getEmittedBin());
    const wasm32_core_smoke_step = b.step("wasm32-core-smoke", "Load and execute the optional wasm32 compatibility processing core with Node");
    wasm32_core_smoke_step.dependOn(&wasm32_core_smoke_cmd.step);

    const wasm_core_smoke_cmd = b.addSystemCommand(&.{"node"});
    wasm_core_smoke_cmd.addFileArg(b.path("test/wasm/wasm_core_smoke.mjs"));
    wasm_core_smoke_cmd.addFileArg(wasm_core.getEmittedBin());
    const wasm_core_smoke_step = b.step("wasm-core-smoke", "Load and execute the browser WebAssembly processing core with Node");
    wasm_core_smoke_step.dependOn(&wasm_core_smoke_cmd.step);

    const wasm_worker_protocol_smoke_cmd = b.addSystemCommand(&.{"node"});
    wasm_worker_protocol_smoke_cmd.addFileArg(b.path("test/wasm/worker_protocol_smoke.mjs"));
    const wasm_worker_protocol_smoke_step = b.step("wasm-worker-protocol-smoke", "Verify the browser worker protocol and cache-key boundary");
    wasm_worker_protocol_smoke_step.dependOn(&wasm_worker_protocol_smoke_cmd.step);

    const wasm_worker_runtime_smoke_cmd = b.addSystemCommand(&.{"node"});
    wasm_worker_runtime_smoke_cmd.addFileArg(b.path("test/wasm/worker_runtime_smoke.mjs"));
    wasm_worker_runtime_smoke_cmd.addFileArg(wasm_core.getEmittedBin());
    const wasm_worker_runtime_smoke_step = b.step("wasm-worker-runtime-smoke", "Run the browser worker runtime against the Wasm preview core");
    wasm_worker_runtime_smoke_step.dependOn(&wasm_worker_runtime_smoke_cmd.step);

    const wasm_webapp_shell_smoke_cmd = b.addSystemCommand(&.{"node"});
    wasm_webapp_shell_smoke_cmd.addFileArg(b.path("test/wasm/webapp_shell_smoke.mjs"));
    wasm_webapp_shell_smoke_cmd.addFileArg(wasm_core.getEmittedBin());
    const wasm_webapp_shell_smoke_step = b.step("wasm-webapp-shell-smoke", "Run the browser processing shell orchestration against the Wasm worker");
    wasm_webapp_shell_smoke_step.dependOn(&wasm_webapp_shell_smoke_cmd.step);

    const wasm_webapp_crop_export_bench_cmd = b.addSystemCommand(&.{"node"});
    wasm_webapp_crop_export_bench_cmd.addFileArg(b.path("test/wasm/webapp_crop_export_bench.mjs"));
    wasm_webapp_crop_export_bench_cmd.addFileArg(wasm_core.getEmittedBin());
    const wasm_webapp_crop_export_bench_step = b.step("bench-wasm-webapp-crop-export", "Benchmark browser rotated crop/export on local scan data when available");
    wasm_webapp_crop_export_bench_step.dependOn(&wasm_webapp_crop_export_bench_cmd.step);

    const wasm_tiff_reader_smoke_cmd = b.addSystemCommand(&.{"node"});
    wasm_tiff_reader_smoke_cmd.addFileArg(b.path("test/wasm/tiff_reader_smoke.mjs"));
    const wasm_tiff_reader_smoke_step = b.step("wasm-tiff-reader-smoke", "Verify browser-side TIFF page import against committed fixtures");
    wasm_tiff_reader_smoke_step.dependOn(&wasm_tiff_reader_smoke_cmd.step);

    const install_webapp_assets = b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .prefix,
        .install_subdir = "webapp",
    });
    const install_webapp_wasm = b.addInstallFileWithDir(
        wasm_core.getEmittedBin(),
        .prefix,
        "webapp/v600-wasm-core.wasm",
    );
    const wasm_webapp_step = b.step("wasm-webapp", "Stage the static browser WebAssembly webapp");
    wasm_webapp_step.dependOn(&install_webapp_assets.step);
    wasm_webapp_step.dependOn(&install_webapp_wasm.step);

    const wasm_webapp_static_smoke_cmd = b.addSystemCommand(&.{"node"});
    wasm_webapp_static_smoke_cmd.addFileArg(b.path("test/wasm/webapp_static_smoke.mjs"));
    wasm_webapp_static_smoke_cmd.addArg(b.getInstallPath(.prefix, "webapp"));
    wasm_webapp_static_smoke_cmd.step.dependOn(&install_webapp_assets.step);
    wasm_webapp_static_smoke_cmd.step.dependOn(&install_webapp_wasm.step);
    const wasm_webapp_static_smoke_step = b.step("wasm-webapp-static-smoke", "Serve-check the staged static browser webapp");
    wasm_webapp_static_smoke_step.dependOn(&wasm_webapp_static_smoke_cmd.step);

    const webgpu_smoke_step = b.step("webgpu-smoke", "Run optional WebGPU adapter/device smoke test");
    const webgpu_sigmoid_compare_step = b.step("webgpu-sigmoid-compare", "Compare the apply_sigmoid WGSL kernel against the CPU reference");
    const webgpu_invert_negative_compare_step = b.step("webgpu-invert-negative-compare", "Compare the invert_negative WGSL kernel against the Zig CPU oracle");
    const webgpu_sigmoid_runtime_smoke_step = b.step("webgpu-sigmoid-runtime-smoke", "Verify V600_PROCESSING_GPU selects the apply_sigmoid backend explicitly");
    const webgpu_invert_negative_runtime_smoke_step = b.step("webgpu-invert-negative-runtime-smoke", "Verify V600_PROCESSING_GPU selects the invert_negative backend explicitly");
    const bench_webgpu_sigmoid_step = b.step("bench-webgpu-sigmoid", "Benchmark apply_sigmoid CPU vs WebGPU at realistic sizes");
    const bench_webgpu_invert_negative_step = b.step("bench-webgpu-invert-negative", "Benchmark invert_negative CPU vs WebGPU at realistic sizes");
    if (enable_webgpu) {
        const webgpu_smoke = b.addExecutable(.{
            .name = "v600-webgpu-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/webgpu_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "v600", .module = root_module },
                },
            }),
        });
        const webgpu_smoke_cmd = b.addRunArtifact(webgpu_smoke);
        webgpu_smoke_step.dependOn(&webgpu_smoke_cmd.step);

        const webgpu_sigmoid_compare = b.addExecutable(.{
            .name = "v600-webgpu-sigmoid-compare",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/webgpu_sigmoid_compare.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "v600", .module = root_module },
                },
            }),
        });
        const webgpu_sigmoid_compare_cmd = b.addRunArtifact(webgpu_sigmoid_compare);
        webgpu_sigmoid_compare_step.dependOn(&webgpu_sigmoid_compare_cmd.step);

        const webgpu_invert_negative_compare = b.addExecutable(.{
            .name = "v600-webgpu-invert-negative-compare",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/webgpu_invert_negative_compare.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "v600", .module = root_module },
                },
            }),
        });
        const webgpu_invert_negative_compare_cmd = b.addRunArtifact(webgpu_invert_negative_compare);
        webgpu_invert_negative_compare_step.dependOn(&webgpu_invert_negative_compare_cmd.step);

        const webgpu_sigmoid_runtime_smoke = b.addExecutable(.{
            .name = "v600-webgpu-sigmoid-runtime-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/webgpu_sigmoid_runtime_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "v600", .module = root_module },
                },
            }),
        });
        const webgpu_sigmoid_runtime_cpu_cmd = b.addRunArtifact(webgpu_sigmoid_runtime_smoke);
        const webgpu_sigmoid_runtime_gpu_cmd = b.addRunArtifact(webgpu_sigmoid_runtime_smoke);
        webgpu_sigmoid_runtime_gpu_cmd.setEnvironmentVariable("V600_PROCESSING_GPU", "1");
        webgpu_sigmoid_runtime_smoke_step.dependOn(&webgpu_sigmoid_runtime_cpu_cmd.step);
        webgpu_sigmoid_runtime_smoke_step.dependOn(&webgpu_sigmoid_runtime_gpu_cmd.step);

        const webgpu_invert_negative_runtime_smoke = b.addExecutable(.{
            .name = "v600-webgpu-invert-negative-runtime-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/webgpu_invert_negative_runtime_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "v600", .module = root_module },
                },
            }),
        });
        const webgpu_invert_negative_runtime_cpu_cmd = b.addRunArtifact(webgpu_invert_negative_runtime_smoke);
        const webgpu_invert_negative_runtime_gpu_cmd = b.addRunArtifact(webgpu_invert_negative_runtime_smoke);
        webgpu_invert_negative_runtime_gpu_cmd.setEnvironmentVariable("V600_PROCESSING_GPU", "1");
        webgpu_invert_negative_runtime_smoke_step.dependOn(&webgpu_invert_negative_runtime_cpu_cmd.step);
        webgpu_invert_negative_runtime_smoke_step.dependOn(&webgpu_invert_negative_runtime_gpu_cmd.step);

        const bench_webgpu_sigmoid = b.addExecutable(.{
            .name = "bench-webgpu-sigmoid",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/benchmarks/webgpu_sigmoid.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "v600", .module = root_module },
                },
            }),
        });
        const bench_webgpu_sigmoid_cmd = b.addRunArtifact(bench_webgpu_sigmoid);
        bench_webgpu_sigmoid_step.dependOn(&bench_webgpu_sigmoid_cmd.step);

        const bench_webgpu_invert_negative = b.addExecutable(.{
            .name = "bench-webgpu-invert-negative",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/benchmarks/webgpu_invert_negative.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "v600", .module = root_module },
                },
            }),
        });
        const bench_webgpu_invert_negative_cmd = b.addRunArtifact(bench_webgpu_invert_negative);
        bench_webgpu_invert_negative_step.dependOn(&bench_webgpu_invert_negative_cmd.step);
    } else {
        const webgpu_smoke_missing_cmd = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'webgpu-smoke requires zig build -Dwebgpu=true webgpu-smoke' >&2; exit 1",
        });
        webgpu_smoke_step.dependOn(&webgpu_smoke_missing_cmd.step);

        const webgpu_sigmoid_compare_missing_cmd = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'webgpu-sigmoid-compare requires zig build -Dwebgpu=true webgpu-sigmoid-compare' >&2; exit 1",
        });
        webgpu_sigmoid_compare_step.dependOn(&webgpu_sigmoid_compare_missing_cmd.step);

        const webgpu_invert_negative_compare_missing_cmd = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'webgpu-invert-negative-compare requires zig build -Dwebgpu=true webgpu-invert-negative-compare' >&2; exit 1",
        });
        webgpu_invert_negative_compare_step.dependOn(&webgpu_invert_negative_compare_missing_cmd.step);

        const webgpu_sigmoid_runtime_smoke_missing_cmd = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'webgpu-sigmoid-runtime-smoke requires zig build -Dwebgpu=true webgpu-sigmoid-runtime-smoke' >&2; exit 1",
        });
        webgpu_sigmoid_runtime_smoke_step.dependOn(&webgpu_sigmoid_runtime_smoke_missing_cmd.step);

        const webgpu_invert_negative_runtime_smoke_missing_cmd = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'webgpu-invert-negative-runtime-smoke requires zig build -Dwebgpu=true webgpu-invert-negative-runtime-smoke' >&2; exit 1",
        });
        webgpu_invert_negative_runtime_smoke_step.dependOn(&webgpu_invert_negative_runtime_smoke_missing_cmd.step);

        const bench_webgpu_sigmoid_missing_cmd = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'bench-webgpu-sigmoid requires zig build -Dwebgpu=true bench-webgpu-sigmoid' >&2; exit 1",
        });
        bench_webgpu_sigmoid_step.dependOn(&bench_webgpu_sigmoid_missing_cmd.step);

        const bench_webgpu_invert_negative_missing_cmd = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'bench-webgpu-invert-negative requires zig build -Dwebgpu=true bench-webgpu-invert-negative' >&2; exit 1",
        });
        bench_webgpu_invert_negative_step.dependOn(&bench_webgpu_invert_negative_missing_cmd.step);
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

    const bench_render_curves = b.addExecutable(.{
        .name = "bench-render-curves",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks/render_curves.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "v600", .module = root_module },
            },
        }),
    });
    const bench_render_curves_cmd = b.addRunArtifact(bench_render_curves);
    if (b.args) |args| {
        bench_render_curves_cmd.addArgs(args);
    }
    const bench_render_curves_step = b.step("bench-render-curves", "Benchmark preview display curve approximations");
    bench_render_curves_step.dependOn(&bench_render_curves_cmd.step);

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
    const wasm_core_test_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_core_test_module.addOptions("build_options", wasm_build_options);
    const wasm_core_tests = b.addTest(.{
        .root_module = wasm_core_test_module,
    });
    const run_wasm_core_tests = b.addRunArtifact(wasm_core_tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_wasm_core_tests.step);
}

fn requiredEnvPath(b: *std.Build, name: []const u8) []const u8 {
    return b.graph.environ_map.get(name) orelse {
        std.debug.panic("-Dwebgpu=true requires environment variable {s}", .{name});
    };
}
