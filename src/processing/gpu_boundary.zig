const std = @import("std");

pub const ScalarType = enum {
    u8,
    u16,
    f64,

    pub fn byteSize(self: ScalarType) usize {
        return switch (self) {
            .u8 => 1,
            .u16 => 2,
            .f64 => 8,
        };
    }
};

pub const PixelFormat = enum {
    gray_u8,
    rgb_u8,
    gray_u16,
    rgb_u16,
    gray_f64,
    rgb_f64,
    mask_u8,

    pub fn channels(self: PixelFormat) usize {
        return switch (self) {
            .gray_u8, .gray_u16, .gray_f64, .mask_u8 => 1,
            .rgb_u8, .rgb_u16, .rgb_f64 => 3,
        };
    }

    pub fn scalar(self: PixelFormat) ScalarType {
        return switch (self) {
            .gray_u8, .rgb_u8, .mask_u8 => .u8,
            .gray_u16, .rgb_u16 => .u16,
            .gray_f64, .rgb_f64 => .f64,
        };
    }

    pub fn bytesPerPixel(self: PixelFormat) usize {
        return self.channels() * self.scalar().byteSize();
    }
};

pub const BufferRole = enum {
    scanner_raw,
    tiff_page,
    quick_preview_raw,
    quick_preview_display,
    net_density,
    scene_linear,
    display_output,
    defect_mask,
    ui_texture_upload,
    gpu_parity_download,
};

pub const MemoryDomain = enum {
    cpu,
    gpu,
};

pub const Ownership = enum {
    borrowed,
    owned,
    cached,
};

pub const CpuImageView = struct {
    width: usize,
    height: usize,
    format: PixelFormat,
    row_stride_bytes: usize,
    data: []const u8,
    role: BufferRole,
    ownership: Ownership = .borrowed,

    pub fn tight(
        width: usize,
        height: usize,
        format: PixelFormat,
        data: []const u8,
        role: BufferRole,
    ) !CpuImageView {
        return CpuImageView.strided(width, height, format, try tightRowStride(width, format), data, role);
    }

    pub fn strided(
        width: usize,
        height: usize,
        format: PixelFormat,
        row_stride_bytes: usize,
        data: []const u8,
        role: BufferRole,
    ) !CpuImageView {
        const view = CpuImageView{
            .width = width,
            .height = height,
            .format = format,
            .row_stride_bytes = row_stride_bytes,
            .data = data,
            .role = role,
        };
        try view.validate();
        return view;
    }

    pub fn validate(self: CpuImageView) !void {
        _ = try requiredBytes(self.width, self.height, self.format, self.row_stride_bytes);
        if (self.data.len < try self.requiredByteLen()) return error.InvalidBufferLength;
    }

    pub fn rowBytes(self: CpuImageView) !usize {
        return tightRowStride(self.width, self.format);
    }

    pub fn requiredByteLen(self: CpuImageView) !usize {
        return requiredBytes(self.width, self.height, self.format, self.row_stride_bytes);
    }

    pub fn isTightlyPacked(self: CpuImageView) bool {
        const row_stride = tightRowStride(self.width, self.format) catch return false;
        return self.row_stride_bytes == row_stride;
    }
};

pub const GpuImageDescriptor = struct {
    width: usize,
    height: usize,
    format: PixelFormat,
    role: BufferRole,
    ownership: Ownership = .cached,
};

pub const TransferDirection = enum {
    upload,
    download,
};

pub const TransferPlan = struct {
    direction: TransferDirection,
    source: MemoryDomain,
    destination: MemoryDomain,
    width: usize,
    height: usize,
    format: PixelFormat,
    row_stride_bytes: usize,
    role: BufferRole,

    pub fn upload(view: CpuImageView) !TransferPlan {
        try view.validate();
        return .{
            .direction = .upload,
            .source = .cpu,
            .destination = .gpu,
            .width = view.width,
            .height = view.height,
            .format = view.format,
            .row_stride_bytes = view.row_stride_bytes,
            .role = view.role,
        };
    }

    pub fn download(descriptor: GpuImageDescriptor) !TransferPlan {
        return .{
            .direction = .download,
            .source = .gpu,
            .destination = .cpu,
            .width = descriptor.width,
            .height = descriptor.height,
            .format = descriptor.format,
            .row_stride_bytes = try tightRowStride(descriptor.width, descriptor.format),
            .role = descriptor.role,
        };
    }

    pub fn requiresCpuParityBuffer(self: TransferPlan) bool {
        return self.direction == .download;
    }
};

pub const KernelPriority = enum {
    p0,
    p1,
    p2,
    deferred,
};

pub const KernelCandidate = struct {
    name: []const u8,
    priority: KernelPriority,
    python_contract: []const u8,
    cpu_symbol: []const u8,
    input_role: BufferRole,
    output_role: BufferRole,
    input_format: PixelFormat,
    output_format: PixelFormat,
    requires_cpu_fallback: bool = true,
    requires_download_compare: bool = true,
};

pub const gpu_kernel_candidates = [_]KernelCandidate{
    .{
        .name = "render_to_display",
        .priority = .p0,
        .python_contract = "scratchndent/processing/negative/render.py:90 render_to_display",
        .cpu_symbol = "src/processing/render.zig renderToDisplay",
        .input_role = .scene_linear,
        .output_role = .display_output,
        .input_format = .rgb_f64,
        .output_format = .rgb_u16,
    },
    .{
        .name = "negadoctor",
        .priority = .p1,
        .python_contract = "scratchndent/processing/negative/color_transforms.py:48 _negadoctor_kernel; :355 negadoctor",
        .cpu_symbol = "src/processing/color.zig negadoctor",
        .input_role = .tiff_page,
        .output_role = .scene_linear,
        .input_format = .rgb_f64,
        .output_format = .rgb_f64,
    },
    .{
        .name = "apply_sigmoid",
        .priority = .p1,
        .python_contract = "scratchndent/processing/negative/color_transforms.py:96 _sigmoid_kernel; :333 apply_sigmoid",
        .cpu_symbol = "src/processing/color.zig applySigmoid",
        .input_role = .scene_linear,
        .output_role = .scene_linear,
        .input_format = .rgb_f64,
        .output_format = .rgb_f64,
    },
    .{
        .name = "srgb_to_linear",
        .priority = .p2,
        .python_contract = "scratchndent/processing/negative/color_transforms.py:114 _srgb_to_linear_kernel; :172 srgb_to_linear",
        .cpu_symbol = "src/processing/color.zig srgbToLinear",
        .input_role = .scene_linear,
        .output_role = .scene_linear,
        .input_format = .rgb_f64,
        .output_format = .rgb_f64,
    },
    .{
        .name = "linear_to_srgb",
        .priority = .p2,
        .python_contract = "scratchndent/processing/negative/color_transforms.py:126 _linear_to_srgb_kernel; :181 linear_to_srgb",
        .cpu_symbol = "src/processing/color.zig linearToSrgb",
        .input_role = .scene_linear,
        .output_role = .scene_linear,
        .input_format = .rgb_f64,
        .output_format = .rgb_f64,
    },
    .{
        .name = "apply_color_matrix",
        .priority = .p2,
        .python_contract = "scratchndent/processing/negative/color_transforms.py:140 _color_matrix_kernel; :167 apply_color_matrix",
        .cpu_symbol = "src/processing/color.zig applyColorMatrix",
        .input_role = .scene_linear,
        .output_role = .scene_linear,
        .input_format = .rgb_f64,
        .output_format = .rgb_f64,
    },
    .{
        .name = "apply_density_transform",
        .priority = .p2,
        .python_contract = "scratchndent/calibration/film_stocks.py polynomial density transform",
        .cpu_symbol = "src/processing/film_stocks.zig applyDensityTransform",
        .input_role = .net_density,
        .output_role = .scene_linear,
        .input_format = .rgb_f64,
        .output_format = .rgb_f64,
    },
    .{
        .name = "sigmoid_tonemap",
        .priority = .deferred,
        .python_contract = "scratchndent/processing/negative/render.py:13 _sigmoid_tonemap_kernel; :50 sigmoid_tonemap",
        .cpu_symbol = "src/processing/render.zig sigmoidTonemap",
        .input_role = .scene_linear,
        .output_role = .scene_linear,
        .input_format = .rgb_f64,
        .output_format = .rgb_f64,
    },
};

pub fn candidateByName(name: []const u8) ?KernelCandidate {
    for (gpu_kernel_candidates) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

pub fn validateGpuCandidate(candidate: KernelCandidate) !void {
    if (candidate.name.len == 0) return error.InvalidGpuCandidate;
    if (candidate.python_contract.len == 0) return error.InvalidGpuCandidate;
    if (candidate.cpu_symbol.len == 0) return error.InvalidGpuCandidate;
    if (!candidate.requires_cpu_fallback) return error.MissingCpuFallback;
    if (!candidate.requires_download_compare) return error.MissingGpuDownloadComparison;
    if (candidate.input_format.channels() != candidate.output_format.channels()) return error.InvalidGpuCandidate;
}

pub fn tightRowStride(width: usize, format: PixelFormat) !usize {
    if (width == 0) return error.InvalidImageDimensions;
    return checkedMul(width, format.bytesPerPixel());
}

pub fn tightByteLen(width: usize, height: usize, format: PixelFormat) !usize {
    return requiredBytes(width, height, format, try tightRowStride(width, format));
}

pub fn requiredBytes(
    width: usize,
    height: usize,
    format: PixelFormat,
    row_stride_bytes: usize,
) !usize {
    if (width == 0 or height == 0) return error.InvalidImageDimensions;
    const row_bytes = try tightRowStride(width, format);
    if (row_stride_bytes < row_bytes) return error.InvalidRowStride;
    const skipped_rows = try checkedMul(height - 1, row_stride_bytes);
    return checkedAdd(skipped_rows, row_bytes);
}

fn checkedMul(lhs: usize, rhs: usize) !usize {
    return std.math.mul(usize, lhs, rhs) catch error.IntegerOverflow;
}

fn checkedAdd(lhs: usize, rhs: usize) !usize {
    return std.math.add(usize, lhs, rhs) catch error.IntegerOverflow;
}

test "pixel formats define explicit CPU GPU byte geometry" {
    try std.testing.expectEqual(@as(usize, 1), PixelFormat.gray_u8.channels());
    try std.testing.expectEqual(@as(usize, 3), PixelFormat.rgb_u8.channels());
    try std.testing.expectEqual(@as(usize, 6), PixelFormat.rgb_u16.bytesPerPixel());
    try std.testing.expectEqual(@as(usize, 24), PixelFormat.rgb_f64.bytesPerPixel());
    try std.testing.expectEqual(ScalarType.u8, PixelFormat.mask_u8.scalar());
}

test "CPU image views validate tight and padded interleaved rows" {
    var tight_buffer: [12]u8 = undefined;
    const tight = try CpuImageView.tight(2, 2, .rgb_u8, tight_buffer[0..], .quick_preview_display);
    try std.testing.expectEqual(@as(usize, 6), tight.row_stride_bytes);
    try std.testing.expectEqual(@as(usize, 12), try tight.requiredByteLen());
    try std.testing.expect(tight.isTightlyPacked());

    var padded_buffer: [16]u8 = undefined;
    const padded = try CpuImageView.strided(2, 2, .rgb_u8, 8, padded_buffer[0..], .ui_texture_upload);
    try std.testing.expectEqual(@as(usize, 14), try padded.requiredByteLen());
    try std.testing.expect(!padded.isTightlyPacked());

    try std.testing.expectError(
        error.InvalidBufferLength,
        CpuImageView.strided(2, 2, .rgb_u8, 8, padded_buffer[0..13], .ui_texture_upload),
    );
    try std.testing.expectError(
        error.InvalidRowStride,
        CpuImageView.strided(2, 2, .rgb_u8, 5, padded_buffer[0..], .ui_texture_upload),
    );
}

test "transfer plans keep CPU source of truth and parity downloads explicit" {
    var buffer: [24]u8 = undefined;
    const view = try CpuImageView.tight(2, 2, .rgb_u16, buffer[0..], .scanner_raw);
    const upload_plan = try TransferPlan.upload(view);
    try std.testing.expectEqual(TransferDirection.upload, upload_plan.direction);
    try std.testing.expectEqual(MemoryDomain.cpu, upload_plan.source);
    try std.testing.expectEqual(MemoryDomain.gpu, upload_plan.destination);
    try std.testing.expect(!upload_plan.requiresCpuParityBuffer());

    const descriptor = GpuImageDescriptor{
        .width = 2,
        .height = 2,
        .format = .rgb_u16,
        .role = .gpu_parity_download,
    };
    const download_plan = try TransferPlan.download(descriptor);
    try std.testing.expectEqual(TransferDirection.download, download_plan.direction);
    try std.testing.expectEqual(MemoryDomain.gpu, download_plan.source);
    try std.testing.expectEqual(MemoryDomain.cpu, download_plan.destination);
    try std.testing.expect(download_plan.requiresCpuParityBuffer());
    try std.testing.expectEqual(@as(usize, 12), download_plan.row_stride_bytes);
}

test "every future GPU kernel candidate requires CPU fallback and download comparison" {
    try std.testing.expect(gpu_kernel_candidates.len >= 8);
    for (gpu_kernel_candidates) |candidate| {
        try validateGpuCandidate(candidate);
        try std.testing.expect(candidate.requires_cpu_fallback);
        try std.testing.expect(candidate.requires_download_compare);
    }

    const render = candidateByName("render_to_display") orelse return error.MissingGpuCandidate;
    try std.testing.expectEqual(KernelPriority.p0, render.priority);
    try std.testing.expectEqual(BufferRole.scene_linear, render.input_role);
    try std.testing.expectEqual(BufferRole.display_output, render.output_role);
    try std.testing.expectEqual(PixelFormat.rgb_f64, render.input_format);
    try std.testing.expectEqual(PixelFormat.rgb_u16, render.output_format);

    const density = candidateByName("apply_density_transform") orelse return error.MissingGpuCandidate;
    try std.testing.expectEqual(BufferRole.net_density, density.input_role);
    try std.testing.expectEqual(BufferRole.scene_linear, density.output_role);
}
