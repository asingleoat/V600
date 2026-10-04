const std = @import("std");

const opencv_object_command = "c++ -std=c++17 -fPIC -fno-exceptions $(pkg-config --cflags opencv4) -c \"$1\" -o \"$2\"";

const NativeObjectSpec = struct {
    command: []const u8,
    label: []const u8,
    source: []const u8,
    output: []const u8,
};

const root_native_objects = [_]NativeObjectSpec{
    .{ .command = opencv_object_command, .label = "compile-opencv-ir", .source = "src/processing/opencv_ir.cpp", .output = "opencv_ir.o" },
    .{ .command = opencv_object_command, .label = "compile-opencv-preview", .source = "src/processing/opencv_preview.cpp", .output = "opencv_preview.o" },
    .{ .command = "cc -std=c99 -fPIC $(pkg-config --cflags libjpeg) -c \"$1\" -o \"$2\"", .label = "compile-jpeg-encode", .source = "src/processing/jpeg_encode.c", .output = "jpeg_encode.o" },
    .{ .command = "cc -std=c99 -fPIC -c \"$1\" -o \"$2\"", .label = "compile-superlu-sparse", .source = "src/processing/superlu_sparse.c", .output = "superlu_sparse.o" },
};

const UiSmokeSpec = struct {
    arg: []const u8,
    name: []const u8,
    description: []const u8,
    clear_env: bool = false,
};

const ui_smoke_steps = [_]UiSmokeSpec{
    .{ .arg = "--smoke", .name = "ui-smoke", .description = "Run one native UI frame and exit" },
    .{ .arg = "--scanner-connect-smoke", .name = "native-scanner-connect-smoke", .description = "Verify native scanner startup begins in connecting state" },
    .{ .arg = "--process-worker-smoke", .name = "native-process-worker-smoke", .description = "Verify native Process worker keeps the UI responsive for a frame" },
    .{ .arg = "--roll-smoke", .name = "native-roll-smoke", .description = "Verify opening a roll points the Scan and Process views at it" },
    .{ .arg = "--roll-name-input-smoke", .name = "native-roll-name-input-smoke", .description = "Verify typing into the roll name field reaches Nuklear" },
    .{ .arg = "--scan-sweep-smoke", .name = "native-scan-sweep-smoke", .description = "Verify the scan progress line draws over the scanned selection" },
    .{ .arg = "--roll-reframe-smoke", .name = "native-roll-reframe-smoke", .description = "Verify hand-placed Process frames re-export a roll strip under the roll's names" },
    .{ .arg = "--roll-close-smoke", .name = "native-roll-close-smoke", .description = "Verify Close Roll returns while a strip exports and the export finishes after" },
    .{ .arg = "--process-dump-smoke", .name = "native-process-dump-smoke", .description = "Verify native Process selection dump diagnostics" },
    .{ .arg = "--process-export-smoke", .name = "native-process-export-smoke", .description = "Verify native Process export flow starts from the UI" },
    .{ .arg = "--preview-worker-smoke", .name = "native-preview-worker-smoke-skip", .description = "Verify native preview hardware smoke skips without V600_HARDWARE_SMOKE=1", .clear_env = true },
    .{ .arg = "--scan-worker-smoke", .name = "native-scan-worker-smoke-skip", .description = "Verify native scan hardware smoke skips without V600_HARDWARE_SMOKE=1", .clear_env = true },
    .{ .arg = "--roll-strip-smoke", .name = "native-roll-strip-smoke-skip", .description = "Verify the native Scan Strip hardware smoke skips without V600_HARDWARE_SMOKE=1", .clear_env = true },
};

const ScannerSmokeSpec = struct {
    args: []const []const u8,
    name: []const u8,
    description: []const u8,
    clear_env: bool = false,
};

const scanner_smoke_steps = [_]ScannerSmokeSpec{
    .{ .args = &.{ "scanner", "smoke" }, .name = "scanner-smoke", .description = "Run gated scanner hardware smoke test" },
    .{ .args = &.{ "scanner", "smoke" }, .name = "scanner-smoke-skip", .description = "Verify scanner hardware smoke skips without V600_HARDWARE_SMOKE=1", .clear_env = true },
    .{ .args = &.{ "scanner", "processing-smoke" }, .name = "scanner-processing-smoke-skip", .description = "Verify scanner processing smoke skips without V600_HARDWARE_SMOKE=1", .clear_env = true },
    .{ .args = &.{ "scanner", "macos-smoke" }, .name = "macos-scanner-smoke-skip", .description = "Verify future macOS scanner hardware smoke skips without V600_MACOS_HARDWARE_SMOKE=1", .clear_env = true },
};

const WasmNodeSpec = struct {
    script: []const u8,
    name: []const u8,
    description: []const u8,
    artifact: enum { none, wasm64, wasm32 } = .none,
};

const wasm_node_steps = [_]WasmNodeSpec{
    .{ .script = "test/wasm/wasm_core_smoke.mjs", .name = "wasm32-core-smoke", .description = "Load and execute the optional wasm32 compatibility processing core with Node", .artifact = .wasm32 },
    .{ .script = "test/wasm/wasm_core_smoke.mjs", .name = "wasm-core-smoke", .description = "Load and execute the browser WebAssembly processing core with Node", .artifact = .wasm64 },
    .{ .script = "test/wasm/worker_protocol_smoke.mjs", .name = "wasm-worker-protocol-smoke", .description = "Verify the browser worker protocol and cache-key boundary" },
    .{ .script = "test/wasm/worker_runtime_smoke.mjs", .name = "wasm-worker-runtime-smoke", .description = "Run the browser worker runtime against the Wasm preview core", .artifact = .wasm64 },
    .{ .script = "test/wasm/webapp_shell_smoke.mjs", .name = "wasm-webapp-shell-smoke", .description = "Run the browser processing shell orchestration against the Wasm worker", .artifact = .wasm64 },
    .{ .script = "test/wasm/webapp_crop_export_bench.mjs", .name = "bench-wasm-webapp-crop-export", .description = "Benchmark browser rotated crop/export on local scan data when available", .artifact = .wasm64 },
    .{ .script = "test/wasm/tiff_reader_smoke.mjs", .name = "wasm-tiff-reader-smoke", .description = "Verify browser-side TIFF page import against committed fixtures" },
};

const WebgpuProgramSpec = struct {
    step_name: []const u8,
    description: []const u8,
    exe_name: []const u8,
    source: []const u8,
    gpu_env_pair: bool = false,
};

const webgpu_programs = [_]WebgpuProgramSpec{
    .{ .step_name = "webgpu-smoke", .description = "Run optional WebGPU adapter/device smoke test", .exe_name = "v600-webgpu-smoke", .source = "src/tools/webgpu_smoke.zig" },
    .{ .step_name = "webgpu-sigmoid-compare", .description = "Compare the apply_sigmoid WGSL kernel against the CPU reference", .exe_name = "v600-webgpu-sigmoid-compare", .source = "src/tools/webgpu_sigmoid_compare.zig" },
    .{ .step_name = "webgpu-invert-negative-compare", .description = "Compare the invert_negative WGSL kernel against the Zig CPU oracle", .exe_name = "v600-webgpu-invert-negative-compare", .source = "src/tools/webgpu_invert_negative_compare.zig" },
    .{ .step_name = "webgpu-sigmoid-runtime-smoke", .description = "Verify V600_PROCESSING_GPU selects the apply_sigmoid backend explicitly", .exe_name = "v600-webgpu-sigmoid-runtime-smoke", .source = "src/tools/webgpu_sigmoid_runtime_smoke.zig", .gpu_env_pair = true },
    .{ .step_name = "webgpu-invert-negative-runtime-smoke", .description = "Verify V600_PROCESSING_GPU selects the invert_negative backend explicitly", .exe_name = "v600-webgpu-invert-negative-runtime-smoke", .source = "src/tools/webgpu_invert_negative_runtime_smoke.zig", .gpu_env_pair = true },
    .{ .step_name = "bench-webgpu-sigmoid", .description = "Benchmark apply_sigmoid CPU vs WebGPU at realistic sizes", .exe_name = "bench-webgpu-sigmoid", .source = "src/benchmarks/webgpu_sigmoid.zig" },
    .{ .step_name = "bench-webgpu-invert-negative", .description = "Benchmark invert_negative CPU vs WebGPU at realistic sizes", .exe_name = "bench-webgpu-invert-negative", .source = "src/benchmarks/webgpu_invert_negative.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_ui = b.option(bool, "ui", "Build the SDL3/Nuklear native UI") orelse false;
    const enable_webgpu = b.option(bool, "webgpu", "Build the optional WebGPU processing backend") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "webgpu", enable_webgpu);
    build_options.addOption(bool, "native_libs", true);

    const root_module = addRootModule(b, target, optimize, build_options, enable_webgpu, null);

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
        const ui_exe = addUiExecutable(b, target, optimize, root_module, null);
        b.installArtifact(ui_exe);

        const ui_run_cmd = b.addRunArtifact(ui_exe);
        if (b.args) |args| {
            ui_run_cmd.addArgs(args);
        }
        const ui_run_step = b.step("run-ui", "Run the SDL3/Nuklear native UI");
        ui_run_step.dependOn(&ui_run_cmd.step);

        for (ui_smoke_steps) |spec| {
            const cmd = b.addRunArtifact(ui_exe);
            if (spec.clear_env) cmd.clearEnvironment();
            cmd.addArg(spec.arg);
            const step = b.step(spec.name, spec.description);
            step.dependOn(&cmd.step);
        }
    }

    if (b.graph.host.result.os.tag == .macos) {
        // Its own release build whatever the other options: the oldest
        // Apple Silicon CPU, and the newest macOS the Nix libraries require.
        const bundle_target = b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
            .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_m1 },
        });
        const bundle_options = b.addOptions();
        bundle_options.addOption(bool, "webgpu", false);
        bundle_options.addOption(bool, "native_libs", true);
        const bundle_root = addRootModule(b, bundle_target, .ReleaseFast, bundle_options, false, true);
        const bundle_ui = addUiExecutable(b, bundle_target, .ReleaseFast, bundle_root, true);
        const bundle_cmd = b.addSystemCommand(&.{ "sh", "scripts/macos_app_bundle.sh" });
        bundle_cmd.addArtifactArg(bundle_ui);
        bundle_cmd.addArg(b.getInstallPath(.prefix, ""));
        bundle_cmd.has_side_effects = true;
        const bundle_step = b.step("app-bundle", "Build zig-out/V600.app and a zip of it to share (macOS, Apple Silicon)");
        bundle_step.dependOn(&bundle_cmd.step);
    }

    const wasm_build_options = b.addOptions();
    wasm_build_options.addOption(bool, "webgpu", false);
    wasm_build_options.addOption(bool, "native_libs", false);
    const wasm_optimize: std.builtin.OptimizeMode = switch (optimize) {
        .Debug => .ReleaseFast,
        else => optimize,
    };
    const wasm_core = addWasmCore(b, .{
        .name = "v600-wasm-core",
        .cpu_arch = .wasm64,
        .optimize = wasm_optimize,
        .options = wasm_build_options,
        .step_name = "wasm-core",
        .step_description = "Build the dependency-free browser WebAssembly processing core",
    });
    const wasm32_core = addWasmCore(b, .{
        .name = "v600-wasm-core32",
        .cpu_arch = .wasm32,
        .optimize = wasm_optimize,
        .options = wasm_build_options,
        .step_name = "wasm32-core",
        .step_description = "Build the optional wasm32 compatibility processing core",
    });

    for (wasm_node_steps) |spec| {
        const cmd = b.addSystemCommand(&.{"node"});
        cmd.addFileArg(b.path(spec.script));
        switch (spec.artifact) {
            .none => {},
            .wasm64 => cmd.addFileArg(wasm_core.getEmittedBin()),
            .wasm32 => cmd.addFileArg(wasm32_core.getEmittedBin()),
        }
        const step = b.step(spec.name, spec.description);
        step.dependOn(&cmd.step);
    }

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
    const install_webapp_wasm32 = b.addInstallFileWithDir(
        wasm32_core.getEmittedBin(),
        .prefix,
        "webapp/v600-wasm-core32.wasm",
    );
    const wasm_webapp_step = b.step("wasm-webapp", "Stage the static browser WebAssembly webapp");
    wasm_webapp_step.dependOn(&install_webapp_assets.step);
    wasm_webapp_step.dependOn(&install_webapp_wasm.step);
    wasm_webapp_step.dependOn(&install_webapp_wasm32.step);

    const companion_smoke_cmd = b.addSystemCommand(&.{"node"});
    companion_smoke_cmd.addFileArg(b.path("test/wasm/companion_smoke.mjs"));
    companion_smoke_cmd.addArtifactArg(exe);
    companion_smoke_cmd.addArg(b.getInstallPath(.prefix, "webapp"));
    companion_smoke_cmd.step.dependOn(&install_webapp_assets.step);
    companion_smoke_cmd.step.dependOn(&install_webapp_wasm.step);
    companion_smoke_cmd.step.dependOn(&install_webapp_wasm32.step);
    const companion_smoke_step = b.step("companion-smoke", "Run the local scanner companion server against a fake scanimage");
    companion_smoke_step.dependOn(&companion_smoke_cmd.step);

    const wasm_webapp_static_smoke_cmd = b.addSystemCommand(&.{"node"});
    wasm_webapp_static_smoke_cmd.addFileArg(b.path("test/wasm/webapp_static_smoke.mjs"));
    wasm_webapp_static_smoke_cmd.addArg(b.getInstallPath(.prefix, "webapp"));
    wasm_webapp_static_smoke_cmd.step.dependOn(&install_webapp_assets.step);
    wasm_webapp_static_smoke_cmd.step.dependOn(&install_webapp_wasm.step);
    wasm_webapp_static_smoke_cmd.step.dependOn(&install_webapp_wasm32.step);
    const wasm_webapp_static_smoke_step = b.step("wasm-webapp-static-smoke", "Serve-check the staged static browser webapp");
    wasm_webapp_static_smoke_step.dependOn(&wasm_webapp_static_smoke_cmd.step);

    var webgpu_steps: [webgpu_programs.len]*std.Build.Step = undefined;
    for (webgpu_programs, 0..) |spec, index| {
        webgpu_steps[index] = b.step(spec.step_name, spec.description);
    }
    if (enable_webgpu) {
        for (webgpu_programs, 0..) |spec, index| {
            const program = addV600Program(b, root_module, target, optimize, spec.exe_name, spec.source);
            if (spec.gpu_env_pair) {
                const cpu_cmd = b.addRunArtifact(program);
                const gpu_cmd = b.addRunArtifact(program);
                gpu_cmd.setEnvironmentVariable("V600_PROCESSING_GPU", "1");
                webgpu_steps[index].dependOn(&cpu_cmd.step);
                webgpu_steps[index].dependOn(&gpu_cmd.step);
            } else {
                const run_cmd = b.addRunArtifact(program);
                webgpu_steps[index].dependOn(&run_cmd.step);
            }
        }
    } else {
        for (webgpu_programs, 0..) |spec, index| {
            const missing_cmd = b.addSystemCommand(&.{
                "sh",
                "-c",
                b.fmt("echo '{s} requires zig build -Dwebgpu=true {s}' >&2; exit 1", .{ spec.step_name, spec.step_name }),
            });
            webgpu_steps[index].dependOn(&missing_cmd.step);
        }
    }

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the V600 Zig CLI");
    run_step.dependOn(&run_cmd.step);

    for (scanner_smoke_steps) |spec| {
        const cmd = b.addRunArtifact(exe);
        if (spec.clear_env) cmd.clearEnvironment();
        cmd.addArgs(spec.args);
        const step = b.step(spec.name, spec.description);
        step.dependOn(&cmd.step);
    }

    const bench_color = addV600Program(b, root_module, target, optimize, "bench-color-paths", "src/benchmarks/color_paths.zig");
    const bench_color_cmd = b.addRunArtifact(bench_color);
    const bench_color_step = b.step("bench-color", "Run headless processing color-path benchmarks");
    bench_color_step.dependOn(&bench_color_cmd.step);


    const bench_gpu_readiness_cmd = b.addRunArtifact(bench_color);
    bench_gpu_readiness_cmd.addArg("--gpu-readiness-gate");
    const bench_gpu_readiness_step = b.step("bench-gpu-readiness", "Run CPU benchmark coverage gate before GPU backend work");
    bench_gpu_readiness_step.dependOn(&bench_gpu_readiness_cmd.step);

    const bench_ir_inpaint = addV600Program(b, root_module, target, optimize, "bench-ir-inpaint", "src/benchmarks/ir_inpaint.zig");
    const bench_ir_inpaint_cmd = b.addRunArtifact(bench_ir_inpaint);
    const bench_ir_inpaint_step = b.step("bench-ir-inpaint", "Run headless IR biharmonic inpaint benchmark");
    bench_ir_inpaint_step.dependOn(&bench_ir_inpaint_cmd.step);

    const bench_processing_commands = addV600Program(b, root_module, target, optimize, "bench-processing-commands", "src/benchmarks/processing_commands.zig");
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

fn compileNativeObject(b: *std.Build, spec: NativeObjectSpec) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        spec.command,
        spec.label,
    });
    cmd.addFileArg(b.path(spec.source));
    return cmd.addOutputFileArg(spec.output);
}

const WasmCoreSpec = struct {
    name: []const u8,
    cpu_arch: std.Target.Cpu.Arch,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    step_name: []const u8,
    step_description: []const u8,
};

fn addWasmCore(b: *std.Build, spec: WasmCoreSpec) *std.Build.Step.Compile {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = spec.cpu_arch,
        .os_tag = .freestanding,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/wasm_core.zig"),
        .target = wasm_target,
        .optimize = spec.optimize,
        .single_threaded = true,
    });
    module.addOptions("build_options", spec.options);
    const core = b.addExecutable(.{
        .name = spec.name,
        .root_module = module,
    });
    core.entry = .disabled;
    core.rdynamic = true;
    core.export_memory = true;
    const install = b.addInstallArtifact(core, .{});
    const step = b.step(spec.step_name, spec.step_description);
    step.dependOn(&install.step);
    return core;
}

fn addV600Program(
    b: *std.Build,
    root_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "v600", .module = root_module },
            },
        }),
    });
}

fn addRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
    enable_webgpu: bool,
    strip: ?bool,
) *std.Build.Module {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    root_module.addOptions("build_options", build_options);
    root_module.linkSystemLibrary("c", .{});
    root_module.linkSystemLibrary("libtiff-4", .{});
    root_module.linkSystemLibrary("zlib", .{ .use_pkg_config = .force });
    root_module.linkSystemLibrary("libdeflate", .{ .use_pkg_config = .force });
    root_module.linkSystemLibrary("libjpeg", .{ .use_pkg_config = .force });
    // The C++ helpers use these three modules only; all of opencv4 would
    // also load its video, codec, and network dependencies (225 dylibs on
    // macOS against 28).
    for ([_][]const u8{ "opencv_core", "opencv_imgproc", "opencv_imgcodecs" }) |name| {
        root_module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }
    root_module.linkSystemLibrary("superlu", .{ .use_pkg_config = .no });
    if (!target.query.isNativeOs()) addNixLibraryPaths(b, root_module);
    if (target.result.os.tag.isDarwin()) {
        // The OpenCV objects need libc++ named directly under the two-level
        // namespace; OpenCV itself links the system /usr/lib/libc++.
        root_module.linkSystemLibrary("c++", .{ .use_pkg_config = .no });
    }
    if (target.result.os.tag == .macos) {
        // USB transport for the Epson interpreter scanner backend.
        root_module.linkSystemLibrary("libusb-1.0", .{ .use_pkg_config = .force });
    }

    if (enable_webgpu) {
        const include_dir = requiredEnvPath(b, "WGPU_NATIVE_INCLUDE_DIR");
        const library_dir = requiredEnvPath(b, "WGPU_NATIVE_LIBRARY_DIR");
        root_module.addSystemIncludePath(.{ .cwd_relative = include_dir });
        root_module.addLibraryPath(.{ .cwd_relative = library_dir });
        root_module.addRPath(.{ .cwd_relative = library_dir });
        root_module.linkSystemLibrary("wgpu_native", .{ .use_pkg_config = .no });
    }

    for (root_native_objects) |spec| {
        root_module.addObjectFile(compileNativeObject(b, spec));
    }
    return root_module;
}

fn addUiExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_module: *std.Build.Module,
    strip: ?bool,
) *std.Build.Step.Compile {
    const nuklear_obj = compileNativeObject(b, .{
        .command = "cc -std=c99 -fPIC $(pkg-config --cflags nuklear) -c \"$1\" -o \"$2\"",
        .label = "compile-nuklear",
        .source = "src/ui/nuklear_impl.c",
        .output = "nuklear_impl.o",
    });

    const ui_module = b.createModule(.{
        .root_source_file = b.path("src/ui/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "v600", .module = root_module },
        },
    });
    ui_module.linkSystemLibrary("c", .{});
    ui_module.linkSystemLibrary("m", .{});
    ui_module.linkSystemLibrary("sdl3", .{ .use_pkg_config = .force });
    ui_module.linkSystemLibrary("nuklear", .{ .use_pkg_config = .force });
    ui_module.addObjectFile(nuklear_obj);

    return b.addExecutable(.{
        .name = "v600-ui",
        .root_module = ui_module,
    });
}

/// Zig takes the Nix dev shell's library paths only when building for the
/// native OS. A target with an explicit OS version (the app bundle's macOS
/// minimum) needs them for the libraries linked without pkg-config.
fn addNixLibraryPaths(b: *std.Build, module: *std.Build.Module) void {
    const flags = b.graph.environ_map.get("NIX_LDFLAGS") orelse return;
    var words = std.mem.tokenizeAny(u8, flags, " \t\n");
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, "-L") and word.len > 2) {
            module.addLibraryPath(.{ .cwd_relative = word[2..] });
        }
    }
}

fn requiredEnvPath(b: *std.Build, name: []const u8) []const u8 {
    return b.graph.environ_map.get(name) orelse {
        std.debug.panic("-Dwebgpu=true requires environment variable {s}", .{name});
    };
}
