//! Local scanner companion server for the browser webapp: binds loopback
//! HTTP, serves the staged static webapp, and exposes the native scanner
//! stack (scanner.linux.Runtime) through the small job API recorded in
//! docs/SCANNER_COMPANION.md. Scan progress reuses the v600.scanner.event.v1
//! JSON lines; the companion adds only ready/status envelope lines.

const std = @import("std");
const builtin = @import("builtin");

const scanner = @import("scanner.zig");

pub const api_schema = "v600.companion.api.v1";
pub const event_schema = "v600.companion.event.v1";
pub const service_name = "v600-companion";
pub const api_version: u32 = 1;

pub const default_port: u16 = 8433;
const max_request_head_bytes = 16 * 1024;
const max_body_bytes = 64 * 1024;
const max_static_file_bytes = 64 * 1024 * 1024;
const max_scan_file_bytes = 2 * 1024 * 1024 * 1024;

pub const ServeOptions = struct {
    port: u16 = default_port,
    webapp_dir: []const u8 = "zig-out/webapp",
    out_dir: []const u8 = "scans",
    scanimage_command: ?[]const u8 = null,
};

pub const JobStatus = enum {
    idle,
    running,
    complete,
    failed,
    cancelled,

    pub fn name(self: JobStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .running => "running",
            .complete => "complete",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }

    pub fn terminal(self: JobStatus) bool {
        return self == .complete or self == .failed or self == .cancelled;
    }
};

const job_allocator = std.heap.page_allocator;

// Same minimal spinlock shape as events.zig ReportLock: the sink callback
// cannot take an io parameter or fail, which rules out std.Io.Mutex, and
// contention is a low-rate poll against occasional event appends.
const JobLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *JobLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *JobLock) void {
        self.locked.store(false, .release);
    }
};

const JobState = struct {
    mutex: JobLock = .{},
    id: u64 = 0,
    status: JobStatus = .idle,
    error_name: ?[]const u8 = null,
    output_path: ?[]u8 = null,
    metadata_path: ?[]u8 = null,
    cancel_path: ?[]u8 = null,
    lines: std.ArrayList([]u8) = .empty,
    thread: ?std.Thread = null,

    fn reset(self: *JobState) void {
        for (self.lines.items) |line| job_allocator.free(line);
        self.lines.clearRetainingCapacity();
        if (self.output_path) |path| job_allocator.free(path);
        if (self.metadata_path) |path| job_allocator.free(path);
        if (self.cancel_path) |path| job_allocator.free(path);
        self.output_path = null;
        self.metadata_path = null;
        self.cancel_path = null;
        self.error_name = null;
    }

    fn appendLine(self: *JobState, line: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.lines.append(job_allocator, line) catch job_allocator.free(line);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    options: ServeOptions,
    job: JobState = .{},

    fn scanRuntime(self: *Server, sink: ?scanner.events.Sink) scanner.linux.Runtime {
        return .{
            .allocator = job_allocator,
            .io = self.io,
            .environ_map = self.environ_map,
            .scanimage_command = self.options.scanimage_command,
            .event_sink = sink,
        };
    }
};

pub fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    options: ServeOptions,
    stdout: anytype,
) !void {
    var server = Server{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
        .options = options,
    };

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", options.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    try stdout.print(
        "{{\"event\":\"companion-ready\",\"schema\":\"{s}\",\"service\":\"{s}\",\"version\":{d},\"port\":{d},\"webapp_dir\":",
        .{ event_schema, service_name, api_version, options.port },
    );
    try printJsonString(stdout, options.webapp_dir);
    try stdout.print("}}\n", .{});
    try stdout.flush();

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        handleConnection(&server, stream) catch {};
    }
}

fn handleConnection(server: *Server, stream: std.Io.net.Stream) !void {
    defer stream.close(server.io);
    var read_buffer: [max_request_head_bytes]u8 = undefined;
    var write_buffer: [max_request_head_bytes]u8 = undefined;
    var stream_reader = std.Io.net.Stream.Reader.init(stream, server.io, &read_buffer);
    var stream_writer = std.Io.net.Stream.Writer.init(stream, server.io, &write_buffer);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var request = http_server.receiveHead() catch return;
    handleRequest(server, &request) catch |err| {
        respondError(&request, .internal_server_error, @errorName(err)) catch {};
    };
}

const Route = union(enum) {
    status,
    devices,
    scan_start,
    scan_events: u64,
    scan_file: u64,
    scan_metadata: u64,
    scan_cancel: u64,
    static_file: []const u8,
    not_found,
};

pub fn routeForTarget(target: []const u8) Route {
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |index| target[0..index] else target;
    if (std.mem.eql(u8, path, "/api/status")) return .status;
    if (std.mem.eql(u8, path, "/api/devices")) return .devices;
    if (std.mem.eql(u8, path, "/api/scan")) return .scan_start;
    if (std.mem.startsWith(u8, path, "/api/scan/")) {
        const remainder = path["/api/scan/".len..];
        const slash = std.mem.indexOfScalar(u8, remainder, '/') orelse return .not_found;
        const id = std.fmt.parseInt(u64, remainder[0..slash], 10) catch return .not_found;
        const action = remainder[slash + 1 ..];
        if (std.mem.eql(u8, action, "events")) return .{ .scan_events = id };
        if (std.mem.eql(u8, action, "file")) return .{ .scan_file = id };
        if (std.mem.eql(u8, action, "metadata")) return .{ .scan_metadata = id };
        if (std.mem.eql(u8, action, "cancel")) return .{ .scan_cancel = id };
        return .not_found;
    }
    if (std.mem.startsWith(u8, path, "/api/")) return .not_found;
    return .{ .static_file = path };
}

fn handleRequest(server: *Server, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const method = request.head.method;
    switch (routeForTarget(target)) {
        .status => try respondStatus(server, request),
        .devices => try respondDevices(server, request),
        .scan_start => {
            if (method != .POST) return respondError(request, .method_not_allowed, "scan start requires POST");
            try startScan(server, request);
        },
        .scan_events => |id| try respondEvents(server, request, id, eventsFromIndex(target)),
        .scan_file => |id| try respondJobFile(server, request, id, .output),
        .scan_metadata => |id| try respondJobFile(server, request, id, .metadata),
        .scan_cancel => |id| {
            if (method != .POST) return respondError(request, .method_not_allowed, "cancel requires POST");
            try cancelScan(server, request, id);
        },
        .static_file => |path| try respondStatic(server, request, path),
        .not_found => try respondError(request, .not_found, "unknown API path"),
    }
}

pub fn eventsFromIndex(target: []const u8) usize {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return 0;
    var it = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "from=")) {
            return std.fmt.parseInt(usize, pair["from=".len..], 10) catch 0;
        }
    }
    return 0;
}

fn respondStatus(server: *Server, request: *std.http.Server.Request) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(server.allocator);
    const writer = JsonBuffer{ .allocator = server.allocator, .list = &body };

    server.job.mutex.lock();
    const id = server.job.id;
    const status = server.job.status;
    const error_name = server.job.error_name;
    server.job.mutex.unlock();

    try writer.print(
        "{{\"schema\":\"{s}\",\"service\":\"{s}\",\"version\":{d},\"job\":",
        .{ api_schema, service_name, api_version },
    );
    if (id == 0) {
        try writer.print("null", .{});
    } else {
        try writer.print("{{\"id\":{d},\"status\":\"{s}\"", .{ id, status.name() });
        if (error_name) |name| {
            try writer.print(",\"error\":\"{s}\"", .{name});
        }
        try writer.print("}}", .{});
    }
    try writer.print("}}", .{});
    try respondJson(request, .ok, body.items);
}

fn respondDevices(server: *Server, request: *std.http.Server.Request) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(server.allocator);
    const writer = JsonBuffer{ .allocator = server.allocator, .list = &body };

    try writer.print("{{\"schema\":\"{s}\",\"devices\":[", .{api_schema});
    const runtime = server.scanRuntime(null);
    if (runtime.discoverDevices()) |devices| {
        defer scanner.linux.freeDevices(job_allocator, devices);
        for (devices, 0..) |device, index| {
            if (index != 0) try writer.print(",", .{});
            try writer.print("{{\"name\":", .{});
            try writer.printString(device.name);
            try writer.print(",\"vendor\":", .{});
            try writer.printString(device.vendor);
            try writer.print(",\"model\":", .{});
            try writer.printString(device.model);
            try writer.print(",\"kind\":", .{});
            try writer.printString(device.kind);
            try writer.print("}}", .{});
        }
        try writer.print("]}}", .{});
    } else |err| {
        try writer.print("],\"error\":\"{s}\"}}", .{@errorName(err)});
    }
    try respondJson(request, .ok, body.items);
}

const ScanBody = struct {
    dpi: ?u32 = null,
    source: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    depth: ?u32 = null,
    device: ?[]const u8 = null,
    x: ?f64 = null,
    y: ?f64 = null,
    width: ?f64 = null,
    height: ?f64 = null,
};

pub fn scanRequestFromBody(body: ScanBody) !scanner.contracts.ScanRequest {
    var request = scanner.contracts.ScanRequest{
        .dpi = body.dpi orelse 400,
        .source = .tpu,
        .kind = .rgb,
        .depth = .sixteen,
    };
    if (body.source) |value| request.source = try parseSourceName(value);
    if (body.kind) |value| request.kind = try parseKindName(value);
    if (body.depth) |value| {
        request.depth = switch (value) {
            8 => .eight,
            16 => .sixteen,
            else => return error.InvalidScanDepth,
        };
    }
    if (body.x) |value| request.area.x = value;
    if (body.y) |value| request.area.y = value;
    if (body.width) |value| request.area.width = value;
    if (body.height) |value| request.area.height = value;
    return request;
}

pub fn parseSourceName(value: []const u8) !scanner.contracts.Source {
    if (std.mem.eql(u8, value, "flatbed")) return .flatbed;
    if (std.mem.eql(u8, value, "tpu")) return .tpu;
    return error.InvalidScanSource;
}

pub fn parseKindName(value: []const u8) !scanner.contracts.ScanKind {
    if (std.mem.eql(u8, value, "rgb")) return .rgb;
    if (std.mem.eql(u8, value, "gray")) return .gray;
    if (std.mem.eql(u8, value, "ir")) return .ir;
    if (std.mem.eql(u8, value, "rgb+ir") or std.mem.eql(u8, value, "rgb_ir")) return .rgb_ir;
    return error.InvalidScanKind;
}

const ScanJobContext = struct {
    server: *Server,
    request: scanner.contracts.ScanRequest,
    device: ?[]u8,
};

fn startScan(server: *Server, request: *std.http.Server.Request) !void {
    var body_buffer: [max_body_bytes]u8 = undefined;
    const reader = request.readerExpectNone(&body_buffer);
    const body_bytes = try reader.allocRemaining(server.allocator, .limited(max_body_bytes));
    defer server.allocator.free(body_bytes);

    const parsed = std.json.parseFromSlice(ScanBody, server.allocator, if (body_bytes.len == 0) "{}" else body_bytes, .{
        .ignore_unknown_fields = true,
    }) catch {
        return respondError(request, .bad_request, "invalid scan request JSON");
    };
    defer parsed.deinit();
    const scan_request = scanRequestFromBody(parsed.value) catch |err| {
        return respondError(request, .bad_request, @errorName(err));
    };

    server.job.mutex.lock();
    if (server.job.status == .running) {
        server.job.mutex.unlock();
        return respondError(request, .conflict, "a scan job is already running");
    }
    if (server.job.thread) |thread| {
        thread.join();
        server.job.thread = null;
    }
    server.job.reset();
    server.job.id += 1;
    server.job.status = .running;
    const job_id = server.job.id;

    try std.Io.Dir.cwd().createDirPath(server.io, server.options.out_dir);
    const output_path = try std.fmt.allocPrint(job_allocator, "{s}/companion_scan_{d:0>4}.tiff", .{ server.options.out_dir, job_id });
    const metadata_path = try std.fmt.allocPrint(job_allocator, "{s}.json", .{output_path});
    const cancel_path = try std.fmt.allocPrint(job_allocator, "{s}.cancel", .{output_path});
    server.job.output_path = output_path;
    server.job.metadata_path = metadata_path;
    server.job.cancel_path = cancel_path;
    server.job.mutex.unlock();

    std.Io.Dir.cwd().deleteFile(server.io, cancel_path) catch {};

    appendCompanionStatusLine(server, job_id, .running, null);

    const context = try job_allocator.create(ScanJobContext);
    context.* = .{
        .server = server,
        .request = scan_request,
        .device = if (parsed.value.device) |device| try job_allocator.dupe(u8, device) else null,
    };
    const thread = std.Thread.spawn(.{}, runScanJob, .{context}) catch |err| {
        job_allocator.destroy(context);
        server.job.mutex.lock();
        server.job.status = .failed;
        server.job.error_name = @errorName(err);
        server.job.mutex.unlock();
        return respondError(request, .internal_server_error, @errorName(err));
    };
    server.job.mutex.lock();
    server.job.thread = thread;
    server.job.mutex.unlock();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(server.allocator);
    const writer = JsonBuffer{ .allocator = server.allocator, .list = &body };
    try writer.print("{{\"schema\":\"{s}\",\"job\":{d},\"status\":\"running\",\"output\":", .{ api_schema, job_id });
    try writer.printString(output_path);
    try writer.print("}}", .{});
    try respondJson(request, .ok, body.items);
}

fn runScanJob(context: *ScanJobContext) void {
    const server = context.server;
    defer {
        if (context.device) |device| job_allocator.free(device);
        job_allocator.destroy(context);
    }

    const sink = scanner.events.Sink{
        .context = server,
        .emit = emitJobEvent,
    };
    const runtime = server.scanRuntime(sink);

    server.job.mutex.lock();
    const job_id = server.job.id;
    const output_path = server.job.output_path.?;
    const metadata_path = server.job.metadata_path.?;
    const cancel_path = server.job.cancel_path.?;
    server.job.mutex.unlock();

    const result = runtime.scan(.{
        .request = context.request,
        .output_path = output_path,
        .metadata_path = metadata_path,
        .device_name = context.device,
        .cancel_file = cancel_path,
    });

    server.job.mutex.lock();
    if (result) {
        server.job.status = .complete;
    } else |err| {
        server.job.status = if (err == error.ScanCancelled) .cancelled else .failed;
        server.job.error_name = @errorName(err);
    }
    const status = server.job.status;
    const error_name = server.job.error_name;
    server.job.mutex.unlock();

    appendCompanionStatusLine(server, job_id, status, error_name);
}

fn emitJobEvent(raw_context: *anyopaque, event: scanner.events.Event) void {
    const server: *Server = @ptrCast(@alignCast(raw_context));
    var line: std.ArrayList(u8) = .empty;
    const writer = JsonBuffer{ .allocator = job_allocator, .list = &line };
    scanner.events.writeEvent(writer, event) catch {
        line.deinit(job_allocator);
        return;
    };
    const owned = line.toOwnedSlice(job_allocator) catch {
        line.deinit(job_allocator);
        return;
    };
    server.job.appendLine(owned);
}

fn appendCompanionStatusLine(server: *Server, job_id: u64, status: JobStatus, error_name: ?[]const u8) void {
    var line: std.ArrayList(u8) = .empty;
    const writer = JsonBuffer{ .allocator = job_allocator, .list = &line };
    writer.print(
        "{{\"event\":\"companion-status\",\"schema\":\"{s}\",\"job\":{d},\"status\":\"{s}\"",
        .{ event_schema, job_id, status.name() },
    ) catch {
        line.deinit(job_allocator);
        return;
    };
    if (error_name) |name| {
        writer.print(",\"error\":\"{s}\"", .{name}) catch {};
    }
    writer.print("}}\n", .{}) catch {};
    const owned = line.toOwnedSlice(job_allocator) catch {
        line.deinit(job_allocator);
        return;
    };
    server.job.appendLine(owned);
}

fn respondEvents(server: *Server, request: *std.http.Server.Request, id: u64, from: usize) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(server.allocator);
    const writer = JsonBuffer{ .allocator = server.allocator, .list = &body };

    var found = false;
    {
        server.job.mutex.lock();
        defer server.job.mutex.unlock();
        if (id != 0 and id == server.job.id) {
            found = true;
            const line_count = server.job.lines.items.len;
            const start = @min(from, line_count);
            try writer.print(
                "{{\"schema\":\"{s}\",\"job\":{d},\"status\":\"{s}\",\"next\":{d},\"events\":[",
                .{ api_schema, id, server.job.status.name(), line_count },
            );
            for (server.job.lines.items[start..], 0..) |line, index| {
                if (index != 0) try writer.print(",", .{});
                try writer.print("{s}", .{std.mem.trimEnd(u8, line, "\n")});
            }
            try writer.print("]}}", .{});
        }
    }
    if (!found) return respondError(request, .not_found, "unknown scan job");
    try respondJson(request, .ok, body.items);
}

fn respondJobFile(server: *Server, request: *std.http.Server.Request, id: u64, which: enum { output, metadata }) !void {
    server.job.mutex.lock();
    const valid = id != 0 and id == server.job.id;
    const status = server.job.status;
    const path = switch (which) {
        .output => server.job.output_path,
        .metadata => server.job.metadata_path,
    };
    server.job.mutex.unlock();

    if (!valid or path == null) return respondError(request, .not_found, "unknown scan job");
    if (status != .complete) return respondError(request, .conflict, "scan job output is not ready");

    const bytes = std.Io.Dir.cwd().readFileAlloc(server.io, path.?, server.allocator, .limited(max_scan_file_bytes)) catch {
        return respondError(request, .not_found, "scan output missing");
    };
    defer server.allocator.free(bytes);
    const content_type = switch (which) {
        .output => "image/tiff",
        .metadata => "application/json",
    };
    try request.respond(bytes, .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = content_type }},
    });
}

fn cancelScan(server: *Server, request: *std.http.Server.Request, id: u64) !void {
    server.job.mutex.lock();
    const valid = id != 0 and id == server.job.id;
    const running = server.job.status == .running;
    const cancel_path = server.job.cancel_path;
    server.job.mutex.unlock();

    if (!valid) return respondError(request, .not_found, "unknown scan job");
    if (!running or cancel_path == null) return respondError(request, .conflict, "scan job is not running");

    var file = std.Io.Dir.cwd().createFile(server.io, cancel_path.?, .{}) catch {
        return respondError(request, .internal_server_error, "could not create cancel file");
    };
    file.close(server.io);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(server.allocator);
    const writer = JsonBuffer{ .allocator = server.allocator, .list = &body };
    try writer.print("{{\"schema\":\"{s}\",\"job\":{d},\"status\":\"cancelling\"}}", .{ api_schema, id });
    try respondJson(request, .ok, body.items);
}

pub fn sanitizeStaticPath(path: []const u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    const relative = if (std.mem.eql(u8, path, "/")) "index.html" else path[1..];
    if (relative.len == 0) return "index.html";
    var it = std.mem.splitScalar(u8, relative, '/');
    while (it.next()) |component| {
        if (component.len == 0) return null;
        if (std.mem.eql(u8, component, "..")) return null;
    }
    return relative;
}

fn respondStatic(server: *Server, request: *std.http.Server.Request, path: []const u8) !void {
    const relative = sanitizeStaticPath(path) orelse {
        return respondError(request, .bad_request, "invalid static path");
    };
    const full = try std.fmt.allocPrint(server.allocator, "{s}/{s}", .{ server.options.webapp_dir, relative });
    defer server.allocator.free(full);
    const bytes = std.Io.Dir.cwd().readFileAlloc(server.io, full, server.allocator, .limited(max_static_file_bytes)) catch {
        return respondError(request, .not_found, "not found");
    };
    defer server.allocator.free(bytes);
    try request.respond(bytes, .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = staticContentType(relative) }},
    });
}

pub fn staticContentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".mjs") or std.mem.endsWith(u8, path, ".js")) return "text/javascript";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".tiff") or std.mem.endsWith(u8, path, ".tif")) return "image/tiff";
    return "application/octet-stream";
}

fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

// Error messages are static strings or Zig error names, which never contain
// characters that need JSON escaping.
fn respondError(request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    var buffer: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buffer, "{{\"schema\":\"{s}\",\"error\":\"{s}\"}}", .{ api_schema, message }) catch {
        return respondJson(request, status, "{\"error\":\"internal\"}");
    };
    try respondJson(request, status, body);
}

const JsonBuffer = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    pub fn print(self: JsonBuffer, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.list.appendSlice(self.allocator, text);
    }

    pub fn printString(self: JsonBuffer, value: []const u8) !void {
        try self.list.append(self.allocator, '"');
        for (value) |byte| {
            switch (byte) {
                '"' => try self.list.appendSlice(self.allocator, "\\\""),
                '\\' => try self.list.appendSlice(self.allocator, "\\\\"),
                '\n' => try self.list.appendSlice(self.allocator, "\\n"),
                '\r' => try self.list.appendSlice(self.allocator, "\\r"),
                '\t' => try self.list.appendSlice(self.allocator, "\\t"),
                else => {
                    if (byte < 0x20) {
                        const text = try std.fmt.allocPrint(self.allocator, "\\u{x:0>4}", .{byte});
                        defer self.allocator.free(text);
                        try self.list.appendSlice(self.allocator, text);
                    } else {
                        try self.list.append(self.allocator, byte);
                    }
                },
            }
        }
        try self.list.append(self.allocator, '"');
    }
};

fn printJsonString(out: anytype, value: []const u8) !void {
    try out.print("\"", .{});
    for (value) |byte| {
        switch (byte) {
            '"' => try out.print("\\\"", .{}),
            '\\' => try out.print("\\\\", .{}),
            else => {
                if (byte >= 0x20) try out.print("{c}", .{byte});
            },
        }
    }
    try out.print("\"", .{});
}

test "routes companion API targets" {
    try std.testing.expectEqual(Route.status, routeForTarget("/api/status"));
    try std.testing.expectEqual(Route.devices, routeForTarget("/api/devices"));
    try std.testing.expectEqual(Route.scan_start, routeForTarget("/api/scan"));
    try std.testing.expectEqual(Route{ .scan_events = 3 }, routeForTarget("/api/scan/3/events?from=7"));
    try std.testing.expectEqual(Route{ .scan_file = 12 }, routeForTarget("/api/scan/12/file"));
    try std.testing.expectEqual(Route{ .scan_metadata = 1 }, routeForTarget("/api/scan/1/metadata"));
    try std.testing.expectEqual(Route{ .scan_cancel = 9 }, routeForTarget("/api/scan/9/cancel"));
    try std.testing.expectEqual(Route.not_found, routeForTarget("/api/scan/x/file"));
    try std.testing.expectEqual(Route.not_found, routeForTarget("/api/unknown"));
    switch (routeForTarget("/styles.css")) {
        .static_file => |path| try std.testing.expectEqualStrings("/styles.css", path),
        else => return error.TestUnexpectedResult,
    }
}

test "parses events from index" {
    try std.testing.expectEqual(@as(usize, 0), eventsFromIndex("/api/scan/1/events"));
    try std.testing.expectEqual(@as(usize, 7), eventsFromIndex("/api/scan/1/events?from=7"));
    try std.testing.expectEqual(@as(usize, 4), eventsFromIndex("/api/scan/1/events?other=1&from=4"));
    try std.testing.expectEqual(@as(usize, 0), eventsFromIndex("/api/scan/1/events?from=bad"));
}

test "sanitizes static paths" {
    try std.testing.expectEqualStrings("index.html", sanitizeStaticPath("/").?);
    try std.testing.expectEqualStrings("app.mjs", sanitizeStaticPath("/app.mjs").?);
    try std.testing.expectEqualStrings("worker/processor.mjs", sanitizeStaticPath("/worker/processor.mjs").?);
    try std.testing.expectEqual(@as(?[]const u8, null), sanitizeStaticPath("/../secret"));
    try std.testing.expectEqual(@as(?[]const u8, null), sanitizeStaticPath("/a//b"));
    try std.testing.expectEqual(@as(?[]const u8, null), sanitizeStaticPath("relative"));
}

test "maps scan request bodies onto scan requests" {
    const defaults = try scanRequestFromBody(.{});
    try std.testing.expectEqual(@as(u32, 400), defaults.dpi);
    try std.testing.expectEqual(scanner.contracts.Source.tpu, defaults.source);
    try std.testing.expectEqual(scanner.contracts.ScanKind.rgb, defaults.kind);
    try std.testing.expectEqual(scanner.contracts.BitDepth.sixteen, defaults.depth);

    const custom = try scanRequestFromBody(.{
        .dpi = 3200,
        .source = "flatbed",
        .kind = "rgb+ir",
        .depth = 8,
        .x = 1.5,
        .width = 4.0,
    });
    try std.testing.expectEqual(@as(u32, 3200), custom.dpi);
    try std.testing.expectEqual(scanner.contracts.Source.flatbed, custom.source);
    try std.testing.expectEqual(scanner.contracts.ScanKind.rgb_ir, custom.kind);
    try std.testing.expectEqual(scanner.contracts.BitDepth.eight, custom.depth);
    try std.testing.expectEqual(@as(f64, 1.5), custom.area.x);
    try std.testing.expectEqual(@as(?f64, 4.0), custom.area.width);

    try std.testing.expectError(error.InvalidScanKind, scanRequestFromBody(.{ .kind = "negative" }));
    try std.testing.expectError(error.InvalidScanDepth, scanRequestFromBody(.{ .depth = 12 }));
}

test "static content types" {
    try std.testing.expectEqualStrings("text/html", staticContentType("index.html"));
    try std.testing.expectEqualStrings("text/javascript", staticContentType("app_core.mjs"));
    try std.testing.expectEqualStrings("application/wasm", staticContentType("v600-wasm-core.wasm"));
    try std.testing.expectEqualStrings("image/tiff", staticContentType("scan.tiff"));
    try std.testing.expectEqualStrings("application/octet-stream", staticContentType("unknown.bin"));
}
