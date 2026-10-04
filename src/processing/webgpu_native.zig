const std = @import("std");
const gpu_boundary = @import("gpu_boundary.zig");
const webgpu = @import("webgpu.zig");

const c = @cImport({
    @cInclude("webgpu/wgpu.h");
});

const apply_sigmoid_wgsl = @embedFile("shaders/apply_sigmoid.wgsl");
const invert_negative_wgsl = @embedFile("shaders/invert_negative.wgsl");
const sigmoid_workgroup_size: u32 = 64;
const rgb_f32_samples_per_pixel: usize = 3;
const rgb_f32_pixel_bytes: usize = rgb_f32_samples_per_pixel * @sizeOf(f32);
const invert_negative_max_chunk_bytes: usize = 64 * 1024 * 1024;

const AdapterRequestState = struct {
    completed: bool = false,
    status: c.WGPURequestAdapterStatus = c.WGPURequestAdapterStatus_Unknown,
    adapter: c.WGPUAdapter = null,
    message_buf: [512]u8 = undefined,
    message_len: usize = 0,

    fn message(self: *const AdapterRequestState) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

const DeviceRequestState = struct {
    completed: bool = false,
    status: c.WGPURequestDeviceStatus = c.WGPURequestDeviceStatus_Unknown,
    device: c.WGPUDevice = null,
    message_buf: [512]u8 = undefined,
    message_len: usize = 0,

    fn message(self: *const DeviceRequestState) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

const DeviceCallbackState = struct {
    lost: bool = false,
    lost_reason: c.WGPUDeviceLostReason = c.WGPUDeviceLostReason_Unknown,
    uncaptured_error: bool = false,
    error_type: c.WGPUErrorType = c.WGPUErrorType_NoError,
    message_buf: [512]u8 = undefined,
    message_len: usize = 0,
};

const MapState = struct {
    completed: bool = false,
    status: c.WGPUMapAsyncStatus = c.WGPUMapAsyncStatus_Unknown,
    message_buf: [512]u8 = undefined,
    message_len: usize = 0,

    fn message(self: *const MapState) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

const QueueDoneState = struct {
    completed: bool = false,
    status: c.WGPUQueueWorkDoneStatus = c.WGPUQueueWorkDoneStatus_Unknown,
};

const SigmoidUniform = extern struct {
    white_target: f32,
    paper_exposure: f32,
    film_fog: f32,
    film_power: f32,
    paper_power: f32,
    count: u32,
    dispatch_width: u32,
    pad1: u32,
};

const InvertNegativeUniform = extern struct {
    dmin: [4]f32,
    coeffs: [8][4]f32,
    default_light: f32,
    pixel_count: u32,
    dispatch_width: u32,
    pad0: u32,
};

const DispatchGeometry = struct {
    groups_x: u32,
    groups_y: u32,
    dispatch_width: u32,
};

const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.swap(true, .acquire)) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

var invert_negative_runtime_cache = InvertNegativeRuntimeCache{};

const InvertNegativeRuntimeCache = struct {
    mutex: SpinLock = .{},
    ready: bool = false,
    instance: c.WGPUInstance = null,
    device: c.WGPUDevice = null,
    queue: c.WGPUQueue = null,
    bind_group_layout: c.WGPUBindGroupLayout = null,
    pipeline_layout: c.WGPUPipelineLayout = null,
    pipeline: c.WGPUComputePipeline = null,
    callback_state: DeviceCallbackState = .{},

    fn ensure(self: *InvertNegativeRuntimeCache, timeout_ns: u64) !void {
        if (self.ready) {
            if (self.callback_state.lost) return error.WebGpuDeviceLost;
            return;
        }

        const instance = c.wgpuCreateInstance(null) orelse return error.WebGpuInstanceUnavailable;
        var keep_instance = false;
        errdefer if (!keep_instance) c.wgpuInstanceRelease(instance);

        var adapter_state = AdapterRequestState{};
        var adapter_options: c.WGPURequestAdapterOptions = std.mem.zeroes(c.WGPURequestAdapterOptions);
        adapter_options.featureLevel = c.WGPUFeatureLevel_Core;
        adapter_options.powerPreference = c.WGPUPowerPreference_HighPerformance;
        adapter_options.backendType = c.WGPUBackendType_Undefined;

        const adapter_future = c.wgpuInstanceRequestAdapter(instance, &adapter_options, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = adapterRequestCallback,
            .userdata1 = &adapter_state,
            .userdata2 = null,
        });
        _ = adapter_future;
        try waitForCallback(instance, &adapter_state.completed, timeout_ns);
        if (!adapter_state.completed) return error.WebGpuAdapterCallbackMissing;
        if (adapter_state.status == c.WGPURequestAdapterStatus_Unavailable) return error.WebGpuAdapterUnavailable;
        if (adapter_state.status != c.WGPURequestAdapterStatus_Success) return error.WebGpuAdapterRequestFailed;

        const adapter = adapter_state.adapter orelse return error.WebGpuAdapterMissing;
        defer c.wgpuAdapterRelease(adapter);

        var device_state = DeviceRequestState{};
        var device_descriptor: c.WGPUDeviceDescriptor = std.mem.zeroes(c.WGPUDeviceDescriptor);
        device_descriptor.label = stringView("cerealgrain-invert-negative-runtime");
        device_descriptor.defaultQueue.label = stringView("cerealgrain-invert-negative-runtime-queue");
        device_descriptor.deviceLostCallbackInfo = .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowSpontaneous,
            .callback = deviceLostCallback,
            .userdata1 = &self.callback_state,
            .userdata2 = null,
        };
        device_descriptor.uncapturedErrorCallbackInfo = .{
            .nextInChain = null,
            .callback = uncapturedErrorCallback,
            .userdata1 = &self.callback_state,
            .userdata2 = null,
        };

        const device_future = c.wgpuAdapterRequestDevice(adapter, &device_descriptor, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = deviceRequestCallback,
            .userdata1 = &device_state,
            .userdata2 = null,
        });
        _ = device_future;
        try waitForCallback(instance, &device_state.completed, timeout_ns);
        if (!device_state.completed) return error.WebGpuDeviceCallbackMissing;
        if (device_state.status != c.WGPURequestDeviceStatus_Success) return error.WebGpuDeviceRequestFailed;

        const device = device_state.device orelse return error.WebGpuDeviceMissing;
        var keep_device = false;
        errdefer if (!keep_device) c.wgpuDeviceRelease(device);

        const queue = c.wgpuDeviceGetQueue(device) orelse return error.WebGpuQueueMissing;
        var keep_queue = false;
        errdefer if (!keep_queue) c.wgpuQueueRelease(queue);

        var shader_source = c.WGPUShaderSourceWGSL{
            .chain = .{
                .next = null,
                .sType = c.WGPUSType_ShaderSourceWGSL,
            },
            .code = stringViewFromSlice(invert_negative_wgsl),
        };
        var shader_descriptor = c.WGPUShaderModuleDescriptor{
            .nextInChain = &shader_source.chain,
            .label = stringView("cerealgrain-invert-negative-runtime-shader"),
        };
        const shader = c.wgpuDeviceCreateShaderModule(device, &shader_descriptor) orelse return error.WebGpuShaderModuleCreateFailed;
        defer c.wgpuShaderModuleRelease(shader);

        var layout_entries = [_]c.WGPUBindGroupLayoutEntry{
            bindGroupLayoutEntry(0, c.WGPUBufferBindingType_ReadOnlyStorage, 0),
            bindGroupLayoutEntry(1, c.WGPUBufferBindingType_Storage, 0),
            bindGroupLayoutEntry(2, c.WGPUBufferBindingType_Uniform, @sizeOf(InvertNegativeUniform)),
        };
        var bind_group_layout_descriptor = c.WGPUBindGroupLayoutDescriptor{
            .nextInChain = null,
            .label = stringView("cerealgrain-invert-negative-runtime-bind-group-layout"),
            .entryCount = layout_entries.len,
            .entries = &layout_entries,
        };
        const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bind_group_layout_descriptor) orelse return error.WebGpuBindGroupLayoutCreateFailed;
        var keep_bind_group_layout = false;
        errdefer if (!keep_bind_group_layout) c.wgpuBindGroupLayoutRelease(bind_group_layout);

        var bind_group_layouts = [_]c.WGPUBindGroupLayout{bind_group_layout};
        var pipeline_layout_descriptor = c.WGPUPipelineLayoutDescriptor{
            .nextInChain = null,
            .label = stringView("cerealgrain-invert-negative-runtime-pipeline-layout"),
            .bindGroupLayoutCount = bind_group_layouts.len,
            .bindGroupLayouts = &bind_group_layouts,
        };
        const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &pipeline_layout_descriptor) orelse return error.WebGpuPipelineLayoutCreateFailed;
        var keep_pipeline_layout = false;
        errdefer if (!keep_pipeline_layout) c.wgpuPipelineLayoutRelease(pipeline_layout);

        var pipeline_descriptor = c.WGPUComputePipelineDescriptor{
            .nextInChain = null,
            .label = stringView("cerealgrain-invert-negative-runtime-pipeline"),
            .layout = pipeline_layout,
            .compute = .{
                .nextInChain = null,
                .module = shader,
                .entryPoint = stringView("main"),
                .constantCount = 0,
                .constants = null,
            },
        };
        const pipeline = c.wgpuDeviceCreateComputePipeline(device, &pipeline_descriptor) orelse return error.WebGpuComputePipelineCreateFailed;
        var keep_pipeline = false;
        errdefer if (!keep_pipeline) c.wgpuComputePipelineRelease(pipeline);

        self.instance = instance;
        self.device = device;
        self.queue = queue;
        self.bind_group_layout = bind_group_layout;
        self.pipeline_layout = pipeline_layout;
        self.pipeline = pipeline;
        self.ready = true;
        keep_instance = true;
        keep_device = true;
        keep_queue = true;
        keep_bind_group_layout = true;
        keep_pipeline_layout = true;
        keep_pipeline = true;
    }
};

pub fn runAdapterDeviceSmoke(stdout: anytype, options: webgpu.SmokeOptions) !void {
    const version = c.wgpuGetVersion();

    const instance = c.wgpuCreateInstance(null) orelse return error.WebGpuInstanceUnavailable;
    defer c.wgpuInstanceRelease(instance);

    var adapter_state = AdapterRequestState{};
    var adapter_options: c.WGPURequestAdapterOptions = std.mem.zeroes(c.WGPURequestAdapterOptions);
    adapter_options.featureLevel = c.WGPUFeatureLevel_Core;
    adapter_options.powerPreference = c.WGPUPowerPreference_HighPerformance;
    adapter_options.backendType = c.WGPUBackendType_Undefined;

    const adapter_future = c.wgpuInstanceRequestAdapter(instance, &adapter_options, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = adapterRequestCallback,
        .userdata1 = &adapter_state,
        .userdata2 = null,
    });
    _ = adapter_future;
    try waitForCallback(instance, &adapter_state.completed, options.timeout_ns);

    if (!adapter_state.completed) return error.WebGpuAdapterCallbackMissing;
    if (adapter_state.status == c.WGPURequestAdapterStatus_Unavailable) {
        if (options.allow_no_adapter) {
            try stdout.print(
                "webgpu_smoke,status,skipped_no_adapter,version,{d},message,{s}\n",
                .{ version, adapter_state.message() },
            );
            return;
        }
        try stdout.print(
            "webgpu_smoke,status,no_adapter,version,{d},message,{s}\n",
            .{ version, adapter_state.message() },
        );
        return error.WebGpuAdapterUnavailable;
    }
    if (adapter_state.status != c.WGPURequestAdapterStatus_Success) {
        try stdout.print(
            "webgpu_smoke,status,adapter_error,code,{d},version,{d},message,{s}\n",
            .{ adapter_state.status, version, adapter_state.message() },
        );
        return error.WebGpuAdapterRequestFailed;
    }

    const adapter = adapter_state.adapter orelse return error.WebGpuAdapterMissing;
    defer c.wgpuAdapterRelease(adapter);

    var adapter_info: c.WGPUAdapterInfo = std.mem.zeroes(c.WGPUAdapterInfo);
    const info_status = c.wgpuAdapterGetInfo(adapter, &adapter_info);
    if (info_status != c.WGPUStatus_Success) return error.WebGpuAdapterInfoUnavailable;
    defer c.wgpuAdapterInfoFreeMembers(adapter_info);

    var callback_state = DeviceCallbackState{};
    var device_state = DeviceRequestState{};
    var device_descriptor: c.WGPUDeviceDescriptor = std.mem.zeroes(c.WGPUDeviceDescriptor);
    device_descriptor.label = stringView("cerealgrain-webgpu-smoke");
    device_descriptor.defaultQueue.label = stringView("cerealgrain-webgpu-smoke-queue");
    device_descriptor.deviceLostCallbackInfo = .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = deviceLostCallback,
        .userdata1 = &callback_state,
        .userdata2 = null,
    };
    device_descriptor.uncapturedErrorCallbackInfo = .{
        .nextInChain = null,
        .callback = uncapturedErrorCallback,
        .userdata1 = &callback_state,
        .userdata2 = null,
    };

    const device_future = c.wgpuAdapterRequestDevice(adapter, &device_descriptor, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = deviceRequestCallback,
        .userdata1 = &device_state,
        .userdata2 = null,
    });
    _ = device_future;
    try waitForCallback(instance, &device_state.completed, options.timeout_ns);

    if (!device_state.completed) return error.WebGpuDeviceCallbackMissing;
    if (device_state.status != c.WGPURequestDeviceStatus_Success) {
        try stdout.print(
            "webgpu_smoke,status,device_error,code,{d},backend,{s},adapter,{s},message,{s}\n",
            .{
                device_state.status,
                backendTypeName(adapter_info.backendType),
                stringViewSlice(adapter_info.description),
                device_state.message(),
            },
        );
        return error.WebGpuDeviceRequestFailed;
    }

    const device = device_state.device orelse return error.WebGpuDeviceMissing;
    defer c.wgpuDeviceRelease(device);

    try stdout.print(
        "webgpu_smoke,status,ok,backend,{s},adapter_type,{s},adapter,{s},vendor_id,{d},device_id,{d},version,{d}\n",
        .{
            backendTypeName(adapter_info.backendType),
            adapterTypeName(adapter_info.adapterType),
            stringViewSlice(adapter_info.description),
            adapter_info.vendorID,
            adapter_info.deviceID,
            version,
        },
    );
}

pub fn applySigmoidKernel(
    allocator: std.mem.Allocator,
    input: []const f64,
    params: webgpu.SigmoidKernelParams,
    options: webgpu.ComputeOptions,
) ![]f64 {
    if (input.len == 0) return allocator.alloc(f64, 0);
    if (input.len % 3 != 0) return error.InvalidColorBuffer;
    const count_u32 = std.math.cast(u32, input.len) orelse return error.WebGpuInputTooLarge;

    const pixel_count = input.len / 3;
    const download_plan = try gpu_boundary.TransferPlan.download(.{
        .width = pixel_count,
        .height = 1,
        .format = .rgb_f32,
        .role = .gpu_parity_download,
    });
    const byte_len = try std.math.mul(usize, download_plan.row_stride_bytes, download_plan.height);
    const byte_len_u64: u64 = @intCast(byte_len);

    const staged = try allocator.alloc(f32, input.len);
    defer allocator.free(staged);
    try gpu_boundary.sceneLinearF64ToF32Staging(input, staged);
    if (std.mem.sliceAsBytes(staged).len != byte_len) return error.InvalidGpuStagingBuffer;

    const output_f32 = try allocator.alloc(f32, input.len);
    defer allocator.free(output_f32);
    const dispatch = try dispatchGeometry(count_u32);

    const instance = c.wgpuCreateInstance(null) orelse return error.WebGpuInstanceUnavailable;
    defer c.wgpuInstanceRelease(instance);

    var adapter_state = AdapterRequestState{};
    var adapter_options: c.WGPURequestAdapterOptions = std.mem.zeroes(c.WGPURequestAdapterOptions);
    adapter_options.featureLevel = c.WGPUFeatureLevel_Core;
    adapter_options.powerPreference = c.WGPUPowerPreference_HighPerformance;
    adapter_options.backendType = c.WGPUBackendType_Undefined;

    const adapter_future = c.wgpuInstanceRequestAdapter(instance, &adapter_options, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = adapterRequestCallback,
        .userdata1 = &adapter_state,
        .userdata2 = null,
    });
    _ = adapter_future;
    try waitForCallback(instance, &adapter_state.completed, options.timeout_ns);
    if (!adapter_state.completed) return error.WebGpuAdapterCallbackMissing;
    if (adapter_state.status == c.WGPURequestAdapterStatus_Unavailable) return error.WebGpuAdapterUnavailable;
    if (adapter_state.status != c.WGPURequestAdapterStatus_Success) return error.WebGpuAdapterRequestFailed;

    const adapter = adapter_state.adapter orelse return error.WebGpuAdapterMissing;
    defer c.wgpuAdapterRelease(adapter);

    var callback_state = DeviceCallbackState{};
    var device_state = DeviceRequestState{};
    var device_descriptor: c.WGPUDeviceDescriptor = std.mem.zeroes(c.WGPUDeviceDescriptor);
    device_descriptor.label = stringView("cerealgrain-apply-sigmoid");
    device_descriptor.defaultQueue.label = stringView("cerealgrain-apply-sigmoid-queue");
    device_descriptor.deviceLostCallbackInfo = .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = deviceLostCallback,
        .userdata1 = &callback_state,
        .userdata2 = null,
    };
    device_descriptor.uncapturedErrorCallbackInfo = .{
        .nextInChain = null,
        .callback = uncapturedErrorCallback,
        .userdata1 = &callback_state,
        .userdata2 = null,
    };

    const device_future = c.wgpuAdapterRequestDevice(adapter, &device_descriptor, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = deviceRequestCallback,
        .userdata1 = &device_state,
        .userdata2 = null,
    });
    _ = device_future;
    try waitForCallback(instance, &device_state.completed, options.timeout_ns);
    if (!device_state.completed) return error.WebGpuDeviceCallbackMissing;
    if (device_state.status != c.WGPURequestDeviceStatus_Success) return error.WebGpuDeviceRequestFailed;

    const device = device_state.device orelse return error.WebGpuDeviceMissing;
    defer c.wgpuDeviceRelease(device);

    const queue = c.wgpuDeviceGetQueue(device) orelse return error.WebGpuQueueMissing;
    defer c.wgpuQueueRelease(queue);

    const input_buffer = try createBuffer(
        device,
        "cerealgrain-apply-sigmoid-input",
        c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(input_buffer);

    const output_buffer = try createBuffer(
        device,
        "cerealgrain-apply-sigmoid-output",
        c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopySrc,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(output_buffer);

    const readback_buffer = try createBuffer(
        device,
        "cerealgrain-apply-sigmoid-readback",
        c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(readback_buffer);

    const uniform = SigmoidUniform{
        .white_target = @floatCast(params.white_target),
        .paper_exposure = @floatCast(params.paper_exposure),
        .film_fog = @floatCast(params.film_fog),
        .film_power = @floatCast(params.film_power),
        .paper_power = @floatCast(params.paper_power),
        .count = count_u32,
        .dispatch_width = dispatch.dispatch_width,
        .pad1 = 0,
    };
    const uniform_bytes = std.mem.asBytes(&uniform);
    const uniform_buffer = try createBuffer(
        device,
        "cerealgrain-apply-sigmoid-params",
        c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
        uniform_bytes.len,
    );
    defer c.wgpuBufferRelease(uniform_buffer);

    const staged_bytes = std.mem.sliceAsBytes(staged);
    c.wgpuQueueWriteBuffer(queue, input_buffer, 0, staged_bytes.ptr, staged_bytes.len);
    c.wgpuQueueWriteBuffer(queue, uniform_buffer, 0, uniform_bytes.ptr, uniform_bytes.len);

    var shader_source = c.WGPUShaderSourceWGSL{
        .chain = .{
            .next = null,
            .sType = c.WGPUSType_ShaderSourceWGSL,
        },
        .code = stringViewFromSlice(apply_sigmoid_wgsl),
    };
    var shader_descriptor = c.WGPUShaderModuleDescriptor{
        .nextInChain = &shader_source.chain,
        .label = stringView("cerealgrain-apply-sigmoid-shader"),
    };
    const shader = c.wgpuDeviceCreateShaderModule(device, &shader_descriptor) orelse return error.WebGpuShaderModuleCreateFailed;
    defer c.wgpuShaderModuleRelease(shader);

    var layout_entries = [_]c.WGPUBindGroupLayoutEntry{
        bindGroupLayoutEntry(0, c.WGPUBufferBindingType_ReadOnlyStorage, byte_len_u64),
        bindGroupLayoutEntry(1, c.WGPUBufferBindingType_Storage, byte_len_u64),
        bindGroupLayoutEntry(2, c.WGPUBufferBindingType_Uniform, uniform_bytes.len),
    };
    var bind_group_layout_descriptor = c.WGPUBindGroupLayoutDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-bind-group-layout"),
        .entryCount = layout_entries.len,
        .entries = &layout_entries,
    };
    const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bind_group_layout_descriptor) orelse return error.WebGpuBindGroupLayoutCreateFailed;
    defer c.wgpuBindGroupLayoutRelease(bind_group_layout);

    var bind_group_layouts = [_]c.WGPUBindGroupLayout{bind_group_layout};
    var pipeline_layout_descriptor = c.WGPUPipelineLayoutDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-pipeline-layout"),
        .bindGroupLayoutCount = bind_group_layouts.len,
        .bindGroupLayouts = &bind_group_layouts,
    };
    const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &pipeline_layout_descriptor) orelse return error.WebGpuPipelineLayoutCreateFailed;
    defer c.wgpuPipelineLayoutRelease(pipeline_layout);

    var pipeline_descriptor = c.WGPUComputePipelineDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-pipeline"),
        .layout = pipeline_layout,
        .compute = .{
            .nextInChain = null,
            .module = shader,
            .entryPoint = stringView("main"),
            .constantCount = 0,
            .constants = null,
        },
    };
    const pipeline = c.wgpuDeviceCreateComputePipeline(device, &pipeline_descriptor) orelse return error.WebGpuComputePipelineCreateFailed;
    defer c.wgpuComputePipelineRelease(pipeline);

    var bind_entries = [_]c.WGPUBindGroupEntry{
        bindGroupEntry(0, input_buffer, byte_len_u64),
        bindGroupEntry(1, output_buffer, byte_len_u64),
        bindGroupEntry(2, uniform_buffer, uniform_bytes.len),
    };
    var bind_group_descriptor = c.WGPUBindGroupDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-bind-group"),
        .layout = bind_group_layout,
        .entryCount = bind_entries.len,
        .entries = &bind_entries,
    };
    const bind_group = c.wgpuDeviceCreateBindGroup(device, &bind_group_descriptor) orelse return error.WebGpuBindGroupCreateFailed;
    defer c.wgpuBindGroupRelease(bind_group);

    var encoder_descriptor = c.WGPUCommandEncoderDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-encoder"),
    };
    const encoder = c.wgpuDeviceCreateCommandEncoder(device, &encoder_descriptor) orelse return error.WebGpuCommandEncoderCreateFailed;
    defer c.wgpuCommandEncoderRelease(encoder);

    var pass_descriptor = c.WGPUComputePassDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-pass"),
        .timestampWrites = null,
    };
    const pass = c.wgpuCommandEncoderBeginComputePass(encoder, &pass_descriptor) orelse return error.WebGpuComputePassCreateFailed;
    c.wgpuComputePassEncoderSetPipeline(pass, pipeline);
    c.wgpuComputePassEncoderSetBindGroup(pass, 0, bind_group, 0, null);
    c.wgpuComputePassEncoderDispatchWorkgroups(pass, dispatch.groups_x, dispatch.groups_y, 1);
    c.wgpuComputePassEncoderEnd(pass);
    c.wgpuComputePassEncoderRelease(pass);

    c.wgpuCommandEncoderCopyBufferToBuffer(encoder, output_buffer, 0, readback_buffer, 0, byte_len_u64);

    var command_descriptor = c.WGPUCommandBufferDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-command"),
    };
    const command = c.wgpuCommandEncoderFinish(encoder, &command_descriptor) orelse return error.WebGpuCommandBufferCreateFailed;
    defer c.wgpuCommandBufferRelease(command);

    var commands = [_]c.WGPUCommandBuffer{command};
    c.wgpuQueueSubmit(queue, commands.len, &commands);

    var map_state = MapState{};
    const map_future = c.wgpuBufferMapAsync(readback_buffer, c.WGPUMapMode_Read, 0, byte_len, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = bufferMapCallback,
        .userdata1 = &map_state,
        .userdata2 = null,
    });
    _ = map_future;
    try waitForDeviceCallback(instance, device, &map_state.completed, options.timeout_ns);
    if (!map_state.completed) return error.WebGpuMapCallbackMissing;
    if (map_state.status != c.WGPUMapAsyncStatus_Success) return error.WebGpuBufferMapFailed;
    if (callback_state.lost) return error.WebGpuDeviceLost;
    if (callback_state.uncaptured_error) return error.WebGpuUncapturedError;

    const mapped = c.wgpuBufferGetConstMappedRange(readback_buffer, 0, byte_len) orelse return error.WebGpuMapRangeUnavailable;
    defer c.wgpuBufferUnmap(readback_buffer);
    const mapped_bytes_ptr: [*]const u8 = @ptrCast(mapped);
    const mapped_bytes = mapped_bytes_ptr[0..byte_len];
    @memcpy(std.mem.sliceAsBytes(output_f32), mapped_bytes);

    const result = try allocator.alloc(f64, input.len);
    errdefer allocator.free(result);
    try gpu_boundary.sceneLinearF32DownloadToF64(output_f32, result);
    return result;
}

pub fn applyInvertNegativeKernel(
    allocator: std.mem.Allocator,
    input: []const f64,
    params: webgpu.InvertNegativeKernelParams,
    options: webgpu.ComputeOptions,
) ![]f64 {
    if (input.len == 0) return allocator.alloc(f64, 0);
    if (input.len % 3 != 0) return error.InvalidColorBuffer;
    const pixel_count = input.len / 3;
    const max_chunk_pixels = invertNegativeChunkPixelLimit(invert_negative_max_chunk_bytes);
    if (max_chunk_pixels == 0) return error.WebGpuInputTooLarge;
    if (pixel_count <= max_chunk_pixels) {
        return applyInvertNegativeKernelChunk(allocator, input, params, options);
    }

    const result = try allocator.alloc(f64, input.len);
    errdefer allocator.free(result);

    var pixel_offset: usize = 0;
    while (pixel_offset < pixel_count) {
        const range = try invertNegativeChunkRange(pixel_count, pixel_offset, max_chunk_pixels);
        const chunk = try applyInvertNegativeKernelChunk(allocator, input[range.sample_start..range.sample_end], params, options);
        @memcpy(result[range.sample_start..range.sample_end], chunk);
        allocator.free(chunk);
        pixel_offset = range.next_pixel_offset;
    }

    return result;
}

const InvertNegativeChunkRange = struct {
    sample_start: usize,
    sample_end: usize,
    next_pixel_offset: usize,
};

fn invertNegativeChunkPixelLimit(byte_limit: usize) usize {
    return byte_limit / rgb_f32_pixel_bytes;
}

fn invertNegativeChunkRange(pixel_count: usize, pixel_offset: usize, max_chunk_pixels: usize) !InvertNegativeChunkRange {
    if (max_chunk_pixels == 0) return error.WebGpuInputTooLarge;
    if (pixel_offset >= pixel_count) return error.WebGpuInputTooLarge;
    const chunk_pixels = @min(max_chunk_pixels, pixel_count - pixel_offset);
    const sample_start = pixel_offset * rgb_f32_samples_per_pixel;
    const chunk_samples = chunk_pixels * rgb_f32_samples_per_pixel;
    const sample_end = sample_start + chunk_samples;
    return .{
        .sample_start = sample_start,
        .sample_end = sample_end,
        .next_pixel_offset = pixel_offset + chunk_pixels,
    };
}

fn applyInvertNegativeKernelChunk(
    allocator: std.mem.Allocator,
    input: []const f64,
    params: webgpu.InvertNegativeKernelParams,
    options: webgpu.ComputeOptions,
) ![]f64 {
    if (input.len == 0) return allocator.alloc(f64, 0);
    if (input.len % 3 != 0) return error.InvalidColorBuffer;
    const pixel_count = input.len / 3;
    const pixel_count_u32 = std.math.cast(u32, pixel_count) orelse return error.WebGpuInputTooLarge;

    const download_plan = try gpu_boundary.TransferPlan.download(.{
        .width = pixel_count,
        .height = 1,
        .format = .rgb_f32,
        .role = .gpu_parity_download,
    });
    const byte_len = try std.math.mul(usize, download_plan.row_stride_bytes, download_plan.height);
    const byte_len_u64: u64 = @intCast(byte_len);

    const staged = try allocator.alloc(f32, input.len);
    defer allocator.free(staged);
    try gpu_boundary.sceneLinearF64ToF32Staging(input, staged);
    if (std.mem.sliceAsBytes(staged).len != byte_len) return error.InvalidGpuStagingBuffer;

    const output_f32 = try allocator.alloc(f32, input.len);
    defer allocator.free(output_f32);
    const dispatch = try dispatchGeometry(pixel_count_u32);

    invert_negative_runtime_cache.mutex.lock();
    defer invert_negative_runtime_cache.mutex.unlock();
    try invert_negative_runtime_cache.ensure(options.timeout_ns);
    const instance = invert_negative_runtime_cache.instance orelse return error.WebGpuInstanceUnavailable;
    const device = invert_negative_runtime_cache.device orelse return error.WebGpuDeviceMissing;
    const queue = invert_negative_runtime_cache.queue orelse return error.WebGpuQueueMissing;
    const bind_group_layout = invert_negative_runtime_cache.bind_group_layout orelse return error.WebGpuBindGroupLayoutCreateFailed;
    const pipeline = invert_negative_runtime_cache.pipeline orelse return error.WebGpuComputePipelineCreateFailed;
    const callback_state = &invert_negative_runtime_cache.callback_state;
    if (callback_state.lost) return error.WebGpuDeviceLost;
    callback_state.uncaptured_error = false;
    callback_state.message_len = 0;

    const input_buffer = try createBuffer(
        device,
        "cerealgrain-invert-negative-input",
        c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(input_buffer);

    const output_buffer = try createBuffer(
        device,
        "cerealgrain-invert-negative-output",
        c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopySrc,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(output_buffer);

    const readback_buffer = try createBuffer(
        device,
        "cerealgrain-invert-negative-readback",
        c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(readback_buffer);

    const uniform = invertNegativeUniform(params, pixel_count_u32, dispatch.dispatch_width);
    const uniform_bytes = std.mem.asBytes(&uniform);
    const uniform_buffer = try createBuffer(
        device,
        "cerealgrain-invert-negative-params",
        c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
        uniform_bytes.len,
    );
    defer c.wgpuBufferRelease(uniform_buffer);

    const staged_bytes = std.mem.sliceAsBytes(staged);
    c.wgpuQueueWriteBuffer(queue, input_buffer, 0, staged_bytes.ptr, staged_bytes.len);
    c.wgpuQueueWriteBuffer(queue, uniform_buffer, 0, uniform_bytes.ptr, uniform_bytes.len);

    var bind_entries = [_]c.WGPUBindGroupEntry{
        bindGroupEntry(0, input_buffer, byte_len_u64),
        bindGroupEntry(1, output_buffer, byte_len_u64),
        bindGroupEntry(2, uniform_buffer, uniform_bytes.len),
    };
    var bind_group_descriptor = c.WGPUBindGroupDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-invert-negative-bind-group"),
        .layout = bind_group_layout,
        .entryCount = bind_entries.len,
        .entries = &bind_entries,
    };
    const bind_group = c.wgpuDeviceCreateBindGroup(device, &bind_group_descriptor) orelse return error.WebGpuBindGroupCreateFailed;
    defer c.wgpuBindGroupRelease(bind_group);

    try submitInvertNegativeCommand(device, queue, pipeline, bind_group, output_buffer, readback_buffer, byte_len_u64, dispatch, true);

    var map_state = MapState{};
    const map_future = c.wgpuBufferMapAsync(readback_buffer, c.WGPUMapMode_Read, 0, byte_len, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = bufferMapCallback,
        .userdata1 = &map_state,
        .userdata2 = null,
    });
    _ = map_future;
    try waitForDeviceCallback(instance, device, &map_state.completed, options.timeout_ns);
    if (!map_state.completed) return error.WebGpuMapCallbackMissing;
    if (map_state.status != c.WGPUMapAsyncStatus_Success) return error.WebGpuBufferMapFailed;
    if (callback_state.lost) return error.WebGpuDeviceLost;
    if (callback_state.uncaptured_error) return error.WebGpuUncapturedError;

    const mapped = c.wgpuBufferGetConstMappedRange(readback_buffer, 0, byte_len) orelse return error.WebGpuMapRangeUnavailable;
    defer c.wgpuBufferUnmap(readback_buffer);
    const mapped_bytes_ptr: [*]const u8 = @ptrCast(mapped);
    const mapped_bytes = mapped_bytes_ptr[0..byte_len];
    @memcpy(std.mem.sliceAsBytes(output_f32), mapped_bytes);

    const result = try allocator.alloc(f64, input.len);
    errdefer allocator.free(result);
    try gpu_boundary.sceneLinearF32DownloadToF64(output_f32, result);
    return result;
}

pub fn benchmarkApplySigmoidKernel(
    allocator: std.mem.Allocator,
    input: []const f64,
    params: webgpu.SigmoidKernelParams,
    options: webgpu.SigmoidBenchmarkOptions,
) !webgpu.SigmoidBenchmarkResult {
    if (options.e2e_iterations == 0 or options.resident_iterations == 0) return error.InvalidBenchmarkIterations;
    if (input.len == 0) return error.InvalidColorBuffer;
    if (input.len % 3 != 0) return error.InvalidColorBuffer;
    const count_u32 = std.math.cast(u32, input.len) orelse return error.WebGpuInputTooLarge;

    const pixel_count = input.len / 3;
    const download_plan = try gpu_boundary.TransferPlan.download(.{
        .width = pixel_count,
        .height = 1,
        .format = .rgb_f32,
        .role = .gpu_parity_download,
    });
    const byte_len = try std.math.mul(usize, download_plan.row_stride_bytes, download_plan.height);
    const byte_len_u64: u64 = @intCast(byte_len);

    const staged = try allocator.alloc(f32, input.len);
    defer allocator.free(staged);
    try gpu_boundary.sceneLinearF64ToF32Staging(input, staged);
    if (std.mem.sliceAsBytes(staged).len != byte_len) return error.InvalidGpuStagingBuffer;
    const dispatch = try dispatchGeometry(count_u32);

    const instance = c.wgpuCreateInstance(null) orelse return error.WebGpuInstanceUnavailable;
    defer c.wgpuInstanceRelease(instance);

    var adapter_state = AdapterRequestState{};
    var adapter_options: c.WGPURequestAdapterOptions = std.mem.zeroes(c.WGPURequestAdapterOptions);
    adapter_options.featureLevel = c.WGPUFeatureLevel_Core;
    adapter_options.powerPreference = c.WGPUPowerPreference_HighPerformance;
    adapter_options.backendType = c.WGPUBackendType_Undefined;

    const adapter_future = c.wgpuInstanceRequestAdapter(instance, &adapter_options, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = adapterRequestCallback,
        .userdata1 = &adapter_state,
        .userdata2 = null,
    });
    _ = adapter_future;
    try waitForCallback(instance, &adapter_state.completed, options.timeout_ns);
    if (!adapter_state.completed) return error.WebGpuAdapterCallbackMissing;
    if (adapter_state.status == c.WGPURequestAdapterStatus_Unavailable) return error.WebGpuAdapterUnavailable;
    if (adapter_state.status != c.WGPURequestAdapterStatus_Success) return error.WebGpuAdapterRequestFailed;

    const adapter = adapter_state.adapter orelse return error.WebGpuAdapterMissing;
    defer c.wgpuAdapterRelease(adapter);

    var adapter_info: c.WGPUAdapterInfo = std.mem.zeroes(c.WGPUAdapterInfo);
    const info_status = c.wgpuAdapterGetInfo(adapter, &adapter_info);
    if (info_status != c.WGPUStatus_Success) return error.WebGpuAdapterInfoUnavailable;
    defer c.wgpuAdapterInfoFreeMembers(adapter_info);
    const adapter_name = try allocator.dupe(u8, stringViewSlice(adapter_info.description));
    errdefer allocator.free(adapter_name);

    var callback_state = DeviceCallbackState{};
    var device_state = DeviceRequestState{};
    var device_descriptor: c.WGPUDeviceDescriptor = std.mem.zeroes(c.WGPUDeviceDescriptor);
    device_descriptor.label = stringView("cerealgrain-apply-sigmoid-bench");
    device_descriptor.defaultQueue.label = stringView("cerealgrain-apply-sigmoid-bench-queue");
    device_descriptor.deviceLostCallbackInfo = .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = deviceLostCallback,
        .userdata1 = &callback_state,
        .userdata2 = null,
    };
    device_descriptor.uncapturedErrorCallbackInfo = .{
        .nextInChain = null,
        .callback = uncapturedErrorCallback,
        .userdata1 = &callback_state,
        .userdata2 = null,
    };

    const device_future = c.wgpuAdapterRequestDevice(adapter, &device_descriptor, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = deviceRequestCallback,
        .userdata1 = &device_state,
        .userdata2 = null,
    });
    _ = device_future;
    try waitForCallback(instance, &device_state.completed, options.timeout_ns);
    if (!device_state.completed) return error.WebGpuDeviceCallbackMissing;
    if (device_state.status != c.WGPURequestDeviceStatus_Success) return error.WebGpuDeviceRequestFailed;

    const device = device_state.device orelse return error.WebGpuDeviceMissing;
    defer c.wgpuDeviceRelease(device);

    const queue = c.wgpuDeviceGetQueue(device) orelse return error.WebGpuQueueMissing;
    defer c.wgpuQueueRelease(queue);

    const input_buffer = try createBuffer(
        device,
        "cerealgrain-apply-sigmoid-bench-input",
        c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(input_buffer);

    const output_buffer = try createBuffer(
        device,
        "cerealgrain-apply-sigmoid-bench-output",
        c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopySrc,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(output_buffer);

    const readback_buffer = try createBuffer(
        device,
        "cerealgrain-apply-sigmoid-bench-readback",
        c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(readback_buffer);

    const uniform = SigmoidUniform{
        .white_target = @floatCast(params.white_target),
        .paper_exposure = @floatCast(params.paper_exposure),
        .film_fog = @floatCast(params.film_fog),
        .film_power = @floatCast(params.film_power),
        .paper_power = @floatCast(params.paper_power),
        .count = count_u32,
        .dispatch_width = dispatch.dispatch_width,
        .pad1 = 0,
    };
    const uniform_bytes = std.mem.asBytes(&uniform);
    const uniform_buffer = try createBuffer(
        device,
        "cerealgrain-apply-sigmoid-bench-params",
        c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
        uniform_bytes.len,
    );
    defer c.wgpuBufferRelease(uniform_buffer);

    var shader_source = c.WGPUShaderSourceWGSL{
        .chain = .{
            .next = null,
            .sType = c.WGPUSType_ShaderSourceWGSL,
        },
        .code = stringViewFromSlice(apply_sigmoid_wgsl),
    };
    var shader_descriptor = c.WGPUShaderModuleDescriptor{
        .nextInChain = &shader_source.chain,
        .label = stringView("cerealgrain-apply-sigmoid-bench-shader"),
    };
    const shader = c.wgpuDeviceCreateShaderModule(device, &shader_descriptor) orelse return error.WebGpuShaderModuleCreateFailed;
    defer c.wgpuShaderModuleRelease(shader);

    var layout_entries = [_]c.WGPUBindGroupLayoutEntry{
        bindGroupLayoutEntry(0, c.WGPUBufferBindingType_ReadOnlyStorage, byte_len_u64),
        bindGroupLayoutEntry(1, c.WGPUBufferBindingType_Storage, byte_len_u64),
        bindGroupLayoutEntry(2, c.WGPUBufferBindingType_Uniform, uniform_bytes.len),
    };
    var bind_group_layout_descriptor = c.WGPUBindGroupLayoutDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-bench-bind-group-layout"),
        .entryCount = layout_entries.len,
        .entries = &layout_entries,
    };
    const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bind_group_layout_descriptor) orelse return error.WebGpuBindGroupLayoutCreateFailed;
    defer c.wgpuBindGroupLayoutRelease(bind_group_layout);

    var bind_group_layouts = [_]c.WGPUBindGroupLayout{bind_group_layout};
    var pipeline_layout_descriptor = c.WGPUPipelineLayoutDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-bench-pipeline-layout"),
        .bindGroupLayoutCount = bind_group_layouts.len,
        .bindGroupLayouts = &bind_group_layouts,
    };
    const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &pipeline_layout_descriptor) orelse return error.WebGpuPipelineLayoutCreateFailed;
    defer c.wgpuPipelineLayoutRelease(pipeline_layout);

    var pipeline_descriptor = c.WGPUComputePipelineDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-bench-pipeline"),
        .layout = pipeline_layout,
        .compute = .{
            .nextInChain = null,
            .module = shader,
            .entryPoint = stringView("main"),
            .constantCount = 0,
            .constants = null,
        },
    };
    const pipeline = c.wgpuDeviceCreateComputePipeline(device, &pipeline_descriptor) orelse return error.WebGpuComputePipelineCreateFailed;
    defer c.wgpuComputePipelineRelease(pipeline);

    var bind_entries = [_]c.WGPUBindGroupEntry{
        bindGroupEntry(0, input_buffer, byte_len_u64),
        bindGroupEntry(1, output_buffer, byte_len_u64),
        bindGroupEntry(2, uniform_buffer, uniform_bytes.len),
    };
    var bind_group_descriptor = c.WGPUBindGroupDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-bench-bind-group"),
        .layout = bind_group_layout,
        .entryCount = bind_entries.len,
        .entries = &bind_entries,
    };
    const bind_group = c.wgpuDeviceCreateBindGroup(device, &bind_group_descriptor) orelse return error.WebGpuBindGroupCreateFailed;
    defer c.wgpuBindGroupRelease(bind_group);

    const staged_bytes = std.mem.sliceAsBytes(staged);
    const e2e_start = monotonicNowNs();
    for (0..options.e2e_iterations) |_| {
        c.wgpuQueueWriteBuffer(queue, input_buffer, 0, staged_bytes.ptr, staged_bytes.len);
        c.wgpuQueueWriteBuffer(queue, uniform_buffer, 0, uniform_bytes.ptr, uniform_bytes.len);
        try submitSigmoidCommand(device, queue, pipeline, bind_group, output_buffer, readback_buffer, byte_len_u64, dispatch, true);
        try waitForReadback(instance, device, readback_buffer, byte_len, options.timeout_ns);
    }
    const gpu_e2e_ns = monotonicNowNs() - e2e_start;

    c.wgpuQueueWriteBuffer(queue, input_buffer, 0, staged_bytes.ptr, staged_bytes.len);
    c.wgpuQueueWriteBuffer(queue, uniform_buffer, 0, uniform_bytes.ptr, uniform_bytes.len);
    const resident_start = monotonicNowNs();
    for (0..options.resident_iterations) |_| {
        try submitSigmoidCommand(device, queue, pipeline, bind_group, output_buffer, readback_buffer, byte_len_u64, dispatch, false);
    }
    try waitForQueueDone(instance, device, queue, options.timeout_ns);
    const gpu_resident_ns = monotonicNowNs() - resident_start;

    if (callback_state.lost) return error.WebGpuDeviceLost;
    if (callback_state.uncaptured_error) return error.WebGpuUncapturedError;

    return .{
        .bytes_uploaded = staged_bytes.len + uniform_bytes.len,
        .bytes_downloaded = byte_len,
        .gpu_e2e_ns = gpu_e2e_ns,
        .gpu_resident_ns = gpu_resident_ns,
        .backend = backendTypeName(adapter_info.backendType),
        .adapter = adapter_name,
    };
}

pub fn benchmarkInvertNegativeKernel(
    allocator: std.mem.Allocator,
    input: []const f64,
    params: webgpu.InvertNegativeKernelParams,
    options: webgpu.InvertNegativeBenchmarkOptions,
) !webgpu.InvertNegativeBenchmarkResult {
    if (options.e2e_iterations == 0 or options.resident_iterations == 0) return error.InvalidBenchmarkIterations;
    if (input.len == 0) return error.InvalidColorBuffer;
    if (input.len % 3 != 0) return error.InvalidColorBuffer;
    const pixel_count = input.len / 3;
    const pixel_count_u32 = std.math.cast(u32, pixel_count) orelse return error.WebGpuInputTooLarge;

    const download_plan = try gpu_boundary.TransferPlan.download(.{
        .width = pixel_count,
        .height = 1,
        .format = .rgb_f32,
        .role = .gpu_parity_download,
    });
    const byte_len = try std.math.mul(usize, download_plan.row_stride_bytes, download_plan.height);
    const byte_len_u64: u64 = @intCast(byte_len);

    const staged = try allocator.alloc(f32, input.len);
    defer allocator.free(staged);
    try gpu_boundary.sceneLinearF64ToF32Staging(input, staged);
    if (std.mem.sliceAsBytes(staged).len != byte_len) return error.InvalidGpuStagingBuffer;
    const dispatch = try dispatchGeometry(pixel_count_u32);

    const instance = c.wgpuCreateInstance(null) orelse return error.WebGpuInstanceUnavailable;
    defer c.wgpuInstanceRelease(instance);

    var adapter_state = AdapterRequestState{};
    var adapter_options: c.WGPURequestAdapterOptions = std.mem.zeroes(c.WGPURequestAdapterOptions);
    adapter_options.featureLevel = c.WGPUFeatureLevel_Core;
    adapter_options.powerPreference = c.WGPUPowerPreference_HighPerformance;
    adapter_options.backendType = c.WGPUBackendType_Undefined;

    const adapter_future = c.wgpuInstanceRequestAdapter(instance, &adapter_options, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = adapterRequestCallback,
        .userdata1 = &adapter_state,
        .userdata2 = null,
    });
    _ = adapter_future;
    try waitForCallback(instance, &adapter_state.completed, options.timeout_ns);
    if (!adapter_state.completed) return error.WebGpuAdapterCallbackMissing;
    if (adapter_state.status == c.WGPURequestAdapterStatus_Unavailable) return error.WebGpuAdapterUnavailable;
    if (adapter_state.status != c.WGPURequestAdapterStatus_Success) return error.WebGpuAdapterRequestFailed;

    const adapter = adapter_state.adapter orelse return error.WebGpuAdapterMissing;
    defer c.wgpuAdapterRelease(adapter);

    var adapter_info: c.WGPUAdapterInfo = std.mem.zeroes(c.WGPUAdapterInfo);
    const info_status = c.wgpuAdapterGetInfo(adapter, &adapter_info);
    if (info_status != c.WGPUStatus_Success) return error.WebGpuAdapterInfoUnavailable;
    defer c.wgpuAdapterInfoFreeMembers(adapter_info);
    const adapter_name = try allocator.dupe(u8, stringViewSlice(adapter_info.description));
    errdefer allocator.free(adapter_name);

    var callback_state = DeviceCallbackState{};
    var device_state = DeviceRequestState{};
    var device_descriptor: c.WGPUDeviceDescriptor = std.mem.zeroes(c.WGPUDeviceDescriptor);
    device_descriptor.label = stringView("cerealgrain-invert-negative-bench");
    device_descriptor.defaultQueue.label = stringView("cerealgrain-invert-negative-bench-queue");
    device_descriptor.deviceLostCallbackInfo = .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = deviceLostCallback,
        .userdata1 = &callback_state,
        .userdata2 = null,
    };
    device_descriptor.uncapturedErrorCallbackInfo = .{
        .nextInChain = null,
        .callback = uncapturedErrorCallback,
        .userdata1 = &callback_state,
        .userdata2 = null,
    };

    const device_future = c.wgpuAdapterRequestDevice(adapter, &device_descriptor, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = deviceRequestCallback,
        .userdata1 = &device_state,
        .userdata2 = null,
    });
    _ = device_future;
    try waitForCallback(instance, &device_state.completed, options.timeout_ns);
    if (!device_state.completed) return error.WebGpuDeviceCallbackMissing;
    if (device_state.status != c.WGPURequestDeviceStatus_Success) return error.WebGpuDeviceRequestFailed;

    const device = device_state.device orelse return error.WebGpuDeviceMissing;
    defer c.wgpuDeviceRelease(device);

    const queue = c.wgpuDeviceGetQueue(device) orelse return error.WebGpuQueueMissing;
    defer c.wgpuQueueRelease(queue);

    const input_buffer = try createBuffer(
        device,
        "cerealgrain-invert-negative-bench-input",
        c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(input_buffer);

    const output_buffer = try createBuffer(
        device,
        "cerealgrain-invert-negative-bench-output",
        c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopySrc,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(output_buffer);

    const readback_buffer = try createBuffer(
        device,
        "cerealgrain-invert-negative-bench-readback",
        c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst,
        byte_len_u64,
    );
    defer c.wgpuBufferRelease(readback_buffer);

    const uniform = invertNegativeUniform(params, pixel_count_u32, dispatch.dispatch_width);
    const uniform_bytes = std.mem.asBytes(&uniform);
    const uniform_buffer = try createBuffer(
        device,
        "cerealgrain-invert-negative-bench-params",
        c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
        uniform_bytes.len,
    );
    defer c.wgpuBufferRelease(uniform_buffer);

    var shader_source = c.WGPUShaderSourceWGSL{
        .chain = .{
            .next = null,
            .sType = c.WGPUSType_ShaderSourceWGSL,
        },
        .code = stringViewFromSlice(invert_negative_wgsl),
    };
    var shader_descriptor = c.WGPUShaderModuleDescriptor{
        .nextInChain = &shader_source.chain,
        .label = stringView("cerealgrain-invert-negative-bench-shader"),
    };
    const shader = c.wgpuDeviceCreateShaderModule(device, &shader_descriptor) orelse return error.WebGpuShaderModuleCreateFailed;
    defer c.wgpuShaderModuleRelease(shader);

    var layout_entries = [_]c.WGPUBindGroupLayoutEntry{
        bindGroupLayoutEntry(0, c.WGPUBufferBindingType_ReadOnlyStorage, byte_len_u64),
        bindGroupLayoutEntry(1, c.WGPUBufferBindingType_Storage, byte_len_u64),
        bindGroupLayoutEntry(2, c.WGPUBufferBindingType_Uniform, uniform_bytes.len),
    };
    var bind_group_layout_descriptor = c.WGPUBindGroupLayoutDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-invert-negative-bench-bind-group-layout"),
        .entryCount = layout_entries.len,
        .entries = &layout_entries,
    };
    const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bind_group_layout_descriptor) orelse return error.WebGpuBindGroupLayoutCreateFailed;
    defer c.wgpuBindGroupLayoutRelease(bind_group_layout);

    var bind_group_layouts = [_]c.WGPUBindGroupLayout{bind_group_layout};
    var pipeline_layout_descriptor = c.WGPUPipelineLayoutDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-invert-negative-bench-pipeline-layout"),
        .bindGroupLayoutCount = bind_group_layouts.len,
        .bindGroupLayouts = &bind_group_layouts,
    };
    const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &pipeline_layout_descriptor) orelse return error.WebGpuPipelineLayoutCreateFailed;
    defer c.wgpuPipelineLayoutRelease(pipeline_layout);

    var pipeline_descriptor = c.WGPUComputePipelineDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-invert-negative-bench-pipeline"),
        .layout = pipeline_layout,
        .compute = .{
            .nextInChain = null,
            .module = shader,
            .entryPoint = stringView("main"),
            .constantCount = 0,
            .constants = null,
        },
    };
    const pipeline = c.wgpuDeviceCreateComputePipeline(device, &pipeline_descriptor) orelse return error.WebGpuComputePipelineCreateFailed;
    defer c.wgpuComputePipelineRelease(pipeline);

    var bind_entries = [_]c.WGPUBindGroupEntry{
        bindGroupEntry(0, input_buffer, byte_len_u64),
        bindGroupEntry(1, output_buffer, byte_len_u64),
        bindGroupEntry(2, uniform_buffer, uniform_bytes.len),
    };
    var bind_group_descriptor = c.WGPUBindGroupDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-invert-negative-bench-bind-group"),
        .layout = bind_group_layout,
        .entryCount = bind_entries.len,
        .entries = &bind_entries,
    };
    const bind_group = c.wgpuDeviceCreateBindGroup(device, &bind_group_descriptor) orelse return error.WebGpuBindGroupCreateFailed;
    defer c.wgpuBindGroupRelease(bind_group);

    const staged_bytes = std.mem.sliceAsBytes(staged);
    const e2e_start = monotonicNowNs();
    for (0..options.e2e_iterations) |_| {
        c.wgpuQueueWriteBuffer(queue, input_buffer, 0, staged_bytes.ptr, staged_bytes.len);
        c.wgpuQueueWriteBuffer(queue, uniform_buffer, 0, uniform_bytes.ptr, uniform_bytes.len);
        try submitInvertNegativeCommand(device, queue, pipeline, bind_group, output_buffer, readback_buffer, byte_len_u64, dispatch, true);
        try waitForReadback(instance, device, readback_buffer, byte_len, options.timeout_ns);
    }
    const gpu_e2e_ns = monotonicNowNs() - e2e_start;

    c.wgpuQueueWriteBuffer(queue, input_buffer, 0, staged_bytes.ptr, staged_bytes.len);
    c.wgpuQueueWriteBuffer(queue, uniform_buffer, 0, uniform_bytes.ptr, uniform_bytes.len);
    const resident_start = monotonicNowNs();
    for (0..options.resident_iterations) |_| {
        try submitInvertNegativeCommand(device, queue, pipeline, bind_group, output_buffer, readback_buffer, byte_len_u64, dispatch, false);
    }
    try waitForQueueDone(instance, device, queue, options.timeout_ns);
    const gpu_resident_ns = monotonicNowNs() - resident_start;

    if (callback_state.lost) return error.WebGpuDeviceLost;
    if (callback_state.uncaptured_error) return error.WebGpuUncapturedError;

    return .{
        .bytes_uploaded = staged_bytes.len + uniform_bytes.len,
        .bytes_downloaded = byte_len,
        .gpu_e2e_ns = gpu_e2e_ns,
        .gpu_resident_ns = gpu_resident_ns,
        .backend = backendTypeName(adapter_info.backendType),
        .adapter = adapter_name,
    };
}

fn waitForCallback(instance: c.WGPUInstance, completed: *const bool, timeout_ns: u64) !void {
    const sleep_ns = std.time.ns_per_ms;
    const iterations = @max(@as(u64, 1), timeout_ns / sleep_ns);
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        if (completed.*) return;
        c.wgpuInstanceProcessEvents(instance);
        if (completed.*) return;
        sleepOneMillisecond();
    }
    c.wgpuInstanceProcessEvents(instance);
    if (!completed.*) return error.WebGpuFutureTimedOut;
}

fn waitForDeviceCallback(
    instance: c.WGPUInstance,
    device: c.WGPUDevice,
    completed: *const bool,
    timeout_ns: u64,
) !void {
    const sleep_ns = std.time.ns_per_ms;
    const iterations = @max(@as(u64, 1), timeout_ns / sleep_ns);
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        if (completed.*) return;
        c.wgpuInstanceProcessEvents(instance);
        _ = c.wgpuDevicePoll(device, 0, null);
        if (completed.*) return;
        sleepOneMillisecond();
    }
    c.wgpuInstanceProcessEvents(instance);
    _ = c.wgpuDevicePoll(device, 0, null);
    if (!completed.*) return error.WebGpuFutureTimedOut;
}

fn waitForReadback(
    instance: c.WGPUInstance,
    device: c.WGPUDevice,
    buffer: c.WGPUBuffer,
    byte_len: usize,
    timeout_ns: u64,
) !void {
    var map_state = MapState{};
    const map_future = c.wgpuBufferMapAsync(buffer, c.WGPUMapMode_Read, 0, byte_len, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = bufferMapCallback,
        .userdata1 = &map_state,
        .userdata2 = null,
    });
    _ = map_future;
    try waitForDeviceCallback(instance, device, &map_state.completed, timeout_ns);
    if (!map_state.completed) return error.WebGpuMapCallbackMissing;
    if (map_state.status != c.WGPUMapAsyncStatus_Success) return error.WebGpuBufferMapFailed;
    const mapped = c.wgpuBufferGetConstMappedRange(buffer, 0, byte_len) orelse return error.WebGpuMapRangeUnavailable;
    _ = mapped;
    c.wgpuBufferUnmap(buffer);
}

fn waitForQueueDone(
    instance: c.WGPUInstance,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    timeout_ns: u64,
) !void {
    var state = QueueDoneState{};
    const future = c.wgpuQueueOnSubmittedWorkDone(queue, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = queueWorkDoneCallback,
        .userdata1 = &state,
        .userdata2 = null,
    });
    _ = future;
    try waitForDeviceCallback(instance, device, &state.completed, timeout_ns);
    if (!state.completed) return error.WebGpuQueueDoneCallbackMissing;
    if (state.status != c.WGPUQueueWorkDoneStatus_Success) return error.WebGpuQueueWorkFailed;
}

fn sleepOneMillisecond() void {
    var request = std.c.timespec{
        .sec = 0,
        .nsec = std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&request, null);
}

fn adapterRequestCallback(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const state: *AdapterRequestState = @ptrCast(@alignCast(userdata1.?));
    state.completed = true;
    state.status = status;
    state.adapter = adapter;
    captureMessage(&state.message_buf, &state.message_len, message);
}

fn deviceRequestCallback(
    status: c.WGPURequestDeviceStatus,
    device: c.WGPUDevice,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const state: *DeviceRequestState = @ptrCast(@alignCast(userdata1.?));
    state.completed = true;
    state.status = status;
    state.device = device;
    captureMessage(&state.message_buf, &state.message_len, message);
}

fn deviceLostCallback(
    device: ?*const c.WGPUDevice,
    reason: c.WGPUDeviceLostReason,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = device;
    _ = userdata2;
    const state: *DeviceCallbackState = @ptrCast(@alignCast(userdata1.?));
    state.lost = true;
    state.lost_reason = reason;
    captureMessage(&state.message_buf, &state.message_len, message);
}

fn uncapturedErrorCallback(
    device: ?*const c.WGPUDevice,
    error_type: c.WGPUErrorType,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = device;
    _ = userdata2;
    const state: *DeviceCallbackState = @ptrCast(@alignCast(userdata1.?));
    state.uncaptured_error = true;
    state.error_type = error_type;
    captureMessage(&state.message_buf, &state.message_len, message);
}

fn bufferMapCallback(
    status: c.WGPUMapAsyncStatus,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const state: *MapState = @ptrCast(@alignCast(userdata1.?));
    state.completed = true;
    state.status = status;
    captureMessage(&state.message_buf, &state.message_len, message);
}

fn queueWorkDoneCallback(
    status: c.WGPUQueueWorkDoneStatus,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const state: *QueueDoneState = @ptrCast(@alignCast(userdata1.?));
    state.completed = true;
    state.status = status;
}

fn captureMessage(buffer: *[512]u8, len: *usize, message: c.WGPUStringView) void {
    const slice = stringViewSlice(message);
    const copy_len = @min(buffer.len, slice.len);
    @memcpy(buffer[0..copy_len], slice[0..copy_len]);
    len.* = copy_len;
}

fn stringView(value: [:0]const u8) c.WGPUStringView {
    return .{
        .data = value.ptr,
        .length = c.WGPU_STRLEN,
    };
}

fn stringViewFromSlice(value: []const u8) c.WGPUStringView {
    return .{
        .data = value.ptr,
        .length = value.len,
    };
}

fn stringViewSlice(view: c.WGPUStringView) []const u8 {
    const data = view.data orelse return "";
    if (view.length == c.WGPU_STRLEN) {
        const sentinel: [*:0]const u8 = @ptrCast(data);
        return std.mem.span(sentinel);
    }
    const many: [*]const u8 = @ptrCast(data);
    return many[0..view.length];
}

fn backendTypeName(backend: c.WGPUBackendType) []const u8 {
    return switch (backend) {
        c.WGPUBackendType_Null => "null",
        c.WGPUBackendType_WebGPU => "webgpu",
        c.WGPUBackendType_D3D11 => "d3d11",
        c.WGPUBackendType_D3D12 => "d3d12",
        c.WGPUBackendType_Metal => "metal",
        c.WGPUBackendType_Vulkan => "vulkan",
        c.WGPUBackendType_OpenGL => "opengl",
        c.WGPUBackendType_OpenGLES => "opengles",
        else => "unknown",
    };
}

fn adapterTypeName(adapter_type: c.WGPUAdapterType) []const u8 {
    return switch (adapter_type) {
        c.WGPUAdapterType_DiscreteGPU => "discrete",
        c.WGPUAdapterType_IntegratedGPU => "integrated",
        c.WGPUAdapterType_CPU => "cpu",
        c.WGPUAdapterType_Unknown => "unknown",
        else => "unknown",
    };
}

fn createBuffer(
    device: c.WGPUDevice,
    label: [:0]const u8,
    usage: c.WGPUBufferUsage,
    size: u64,
) !c.WGPUBuffer {
    var descriptor = c.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = stringView(label),
        .usage = usage,
        .size = size,
        .mappedAtCreation = 0,
    };
    return c.wgpuDeviceCreateBuffer(device, &descriptor) orelse error.WebGpuBufferCreateFailed;
}

fn bindGroupLayoutEntry(
    binding: u32,
    binding_type: c.WGPUBufferBindingType,
    min_binding_size: u64,
) c.WGPUBindGroupLayoutEntry {
    var entry: c.WGPUBindGroupLayoutEntry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
    entry.binding = binding;
    entry.visibility = c.WGPUShaderStage_Compute;
    entry.buffer.type = binding_type;
    entry.buffer.minBindingSize = min_binding_size;
    return entry;
}

fn bindGroupEntry(binding: u32, buffer: c.WGPUBuffer, size: u64) c.WGPUBindGroupEntry {
    var entry: c.WGPUBindGroupEntry = std.mem.zeroes(c.WGPUBindGroupEntry);
    entry.binding = binding;
    entry.buffer = buffer;
    entry.offset = 0;
    entry.size = size;
    return entry;
}

fn invertNegativeUniform(
    params: webgpu.InvertNegativeKernelParams,
    pixel_count: u32,
    dispatch_width: u32,
) InvertNegativeUniform {
    var uniform = InvertNegativeUniform{
        .dmin = .{
            @floatCast(params.dmin[0]),
            @floatCast(params.dmin[1]),
            @floatCast(params.dmin[2]),
            0.0,
        },
        .coeffs = std.mem.zeroes([8][4]f32),
        .default_light = @floatCast(params.default_light),
        .pixel_count = pixel_count,
        .dispatch_width = dispatch_width,
        .pad0 = 0,
    };
    for (0..10) |row| {
        for (0..3) |channel| {
            const flat = row * 3 + channel;
            uniform.coeffs[flat / 4][flat % 4] = @floatCast(params.coeffs[row][channel]);
        }
    }
    return uniform;
}

fn submitSigmoidCommand(
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    pipeline: c.WGPUComputePipeline,
    bind_group: c.WGPUBindGroup,
    output_buffer: c.WGPUBuffer,
    readback_buffer: c.WGPUBuffer,
    byte_len: u64,
    dispatch: DispatchGeometry,
    copy_to_readback: bool,
) !void {
    var encoder_descriptor = c.WGPUCommandEncoderDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-bench-encoder"),
    };
    const encoder = c.wgpuDeviceCreateCommandEncoder(device, &encoder_descriptor) orelse return error.WebGpuCommandEncoderCreateFailed;
    defer c.wgpuCommandEncoderRelease(encoder);

    var pass_descriptor = c.WGPUComputePassDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-bench-pass"),
        .timestampWrites = null,
    };
    const pass = c.wgpuCommandEncoderBeginComputePass(encoder, &pass_descriptor) orelse return error.WebGpuComputePassCreateFailed;
    c.wgpuComputePassEncoderSetPipeline(pass, pipeline);
    c.wgpuComputePassEncoderSetBindGroup(pass, 0, bind_group, 0, null);
    c.wgpuComputePassEncoderDispatchWorkgroups(pass, dispatch.groups_x, dispatch.groups_y, 1);
    c.wgpuComputePassEncoderEnd(pass);
    c.wgpuComputePassEncoderRelease(pass);

    if (copy_to_readback) {
        c.wgpuCommandEncoderCopyBufferToBuffer(encoder, output_buffer, 0, readback_buffer, 0, byte_len);
    }

    var command_descriptor = c.WGPUCommandBufferDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-apply-sigmoid-bench-command"),
    };
    const command = c.wgpuCommandEncoderFinish(encoder, &command_descriptor) orelse return error.WebGpuCommandBufferCreateFailed;
    defer c.wgpuCommandBufferRelease(command);

    var commands = [_]c.WGPUCommandBuffer{command};
    c.wgpuQueueSubmit(queue, commands.len, &commands);
}

fn submitInvertNegativeCommand(
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    pipeline: c.WGPUComputePipeline,
    bind_group: c.WGPUBindGroup,
    output_buffer: c.WGPUBuffer,
    readback_buffer: c.WGPUBuffer,
    byte_len: u64,
    dispatch: DispatchGeometry,
    copy_to_readback: bool,
) !void {
    var encoder_descriptor = c.WGPUCommandEncoderDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-invert-negative-bench-encoder"),
    };
    const encoder = c.wgpuDeviceCreateCommandEncoder(device, &encoder_descriptor) orelse return error.WebGpuCommandEncoderCreateFailed;
    defer c.wgpuCommandEncoderRelease(encoder);

    var pass_descriptor = c.WGPUComputePassDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-invert-negative-bench-pass"),
        .timestampWrites = null,
    };
    const pass = c.wgpuCommandEncoderBeginComputePass(encoder, &pass_descriptor) orelse return error.WebGpuComputePassCreateFailed;
    c.wgpuComputePassEncoderSetPipeline(pass, pipeline);
    c.wgpuComputePassEncoderSetBindGroup(pass, 0, bind_group, 0, null);
    c.wgpuComputePassEncoderDispatchWorkgroups(pass, dispatch.groups_x, dispatch.groups_y, 1);
    c.wgpuComputePassEncoderEnd(pass);
    c.wgpuComputePassEncoderRelease(pass);

    if (copy_to_readback) {
        c.wgpuCommandEncoderCopyBufferToBuffer(encoder, output_buffer, 0, readback_buffer, 0, byte_len);
    }

    var command_descriptor = c.WGPUCommandBufferDescriptor{
        .nextInChain = null,
        .label = stringView("cerealgrain-invert-negative-bench-command"),
    };
    const command = c.wgpuCommandEncoderFinish(encoder, &command_descriptor) orelse return error.WebGpuCommandBufferCreateFailed;
    defer c.wgpuCommandBufferRelease(command);

    var commands = [_]c.WGPUCommandBuffer{command};
    c.wgpuQueueSubmit(queue, commands.len, &commands);
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn dispatchGeometry(count: u32) !DispatchGeometry {
    const max_workgroups_per_dimension: u32 = 65_535;
    const total_groups = (count + sigmoid_workgroup_size - 1) / sigmoid_workgroup_size;
    const groups_x = @min(total_groups, max_workgroups_per_dimension);
    const groups_y = (total_groups + groups_x - 1) / groups_x;
    if (groups_y > max_workgroups_per_dimension) return error.WebGpuDispatchTooLarge;
    return .{
        .groups_x = groups_x,
        .groups_y = groups_y,
        .dispatch_width = groups_x * sigmoid_workgroup_size,
    };
}

test "sigmoid dispatch geometry covers fixture and export-sized buffers" {
    const fixture = try dispatchGeometry(18);
    try std.testing.expectEqual(@as(u32, 1), fixture.groups_x);
    try std.testing.expectEqual(@as(u32, 1), fixture.groups_y);
    try std.testing.expectEqual(@as(u32, 64), fixture.dispatch_width);

    const export_frame = try dispatchGeometry(18_874_368);
    try std.testing.expectEqual(@as(u32, 65_535), export_frame.groups_x);
    try std.testing.expectEqual(@as(u32, 5), export_frame.groups_y);
    try std.testing.expect(export_frame.dispatch_width * export_frame.groups_y >= 18_874_368);
}

test "invert negative chunk ranges preserve RGB sample grouping" {
    const limit = invertNegativeChunkPixelLimit(64 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 5_592_405), limit);

    const large_preview_pixels: usize = 1_738 * 8_192;
    var offset: usize = 0;
    var chunks: usize = 0;
    var last_end: usize = 0;
    while (offset < large_preview_pixels) {
        const range = try invertNegativeChunkRange(large_preview_pixels, offset, limit);
        try std.testing.expectEqual(@as(usize, 0), (range.sample_end - range.sample_start) % rgb_f32_samples_per_pixel);
        try std.testing.expectEqual(last_end, range.sample_start);
        try std.testing.expect(range.sample_end <= large_preview_pixels * rgb_f32_samples_per_pixel);
        try std.testing.expect(range.next_pixel_offset > offset);
        last_end = range.sample_end;
        offset = range.next_pixel_offset;
        chunks += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), chunks);
    try std.testing.expectEqual(large_preview_pixels * rgb_f32_samples_per_pixel, last_end);
}
