// Best-effort observability for the imperative adapters. Game rules never import this module.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const trace_name = "trace.jsonl";
const previous_name = "trace.previous.jsonl";
const max_bytes = 1024 * 1024;
const record_bytes = 4096;

// Only the emergency panic path needs a process-global handle.
var panic_fd = std.atomic.Value(c_int).init(-1);
threadlocal var log_trace: ?*Trace = null;

pub const Span = struct { id: u64, started: Io.Timestamp };

pub const Trace = struct {
    io: Io,
    dir: Io.Dir,
    lock: Io.File,
    file: Io.File,
    started: Io.Timestamp,
    sequence: u64 = 0,
    written: usize = 0,
    limit: usize = max_bytes,
    failed: bool = false,
    panic_attached: bool = false,

    pub fn open(io: Io, root: Io.Dir, path: []const u8) !Trace {
        const dir = try root.createDirPathOpen(io, path, .{});
        errdefer dir.close(io);
        const lock = try dir.createFile(io, "trace.lock", .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        errdefer lock.close(io);
        const file = try openNext(dir, io);
        return .{ .io = io, .dir = dir, .lock = lock, .file = file, .started = Io.Clock.awake.now(io) };
    }

    fn openNext(dir: Io.Dir, io: Io) !Io.File {
        dir.rename(trace_name, dir, previous_name, io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return dir.createFile(io, trace_name, .{ .exclusive = true });
    }

    pub fn attachPanic(trace: *Trace) void {
        trace.panic_attached = true;
        panic_fd.store(trace.file.handle, .release);
        log_trace = trace;
    }

    pub fn deinit(trace: *Trace) void {
        if (trace.panic_attached) {
            log_trace = null;
            panic_fd.store(-1, .release);
        }
        trace.file.sync(trace.io) catch {};
        trace.file.close(trace.io);
        trace.lock.close(trace.io);
        trace.dir.close(trace.io);
    }

    pub fn begin(trace: *Trace, area: []const u8, operation: []const u8, details: anytype) Span {
        const span = Span{ .id = trace.sequence + 1, .started = Io.Clock.awake.now(trace.io) };
        trace.note(area, operation, .{ .phase = "begin", .span = span.id, .input = details });
        return span;
    }

    pub fn finish(trace: *Trace, area: []const u8, operation: []const u8, span: Span, status: []const u8, details: anytype) void {
        const elapsed = span.started.durationTo(Io.Clock.awake.now(trace.io));
        trace.note(area, operation, .{
            .phase = "end",
            .span = span.id,
            .status = status,
            .elapsed_us = elapsed.toMicroseconds(),
            .result = details,
        });
    }

    pub fn note(trace: *Trace, area: []const u8, event: []const u8, details: anytype) void {
        if (trace.failed) return;
        trace.sequence += 1;
        var buffer: [record_bytes]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        const now = Io.Clock.awake.now(trace.io);
        const header = .{
            .ms = Io.Clock.real.now(trace.io).toMilliseconds(),
            .elapsed_us = trace.started.durationTo(now).toMicroseconds(),
            .seq = trace.sequence,
            .area = area,
            .event = event,
        };
        // Drop only the oversized payload. Keep the event and correlation fields.
        if (!formatRecord(&writer, header, details)) {
            writer = Io.Writer.fixed(&buffer);
            if (!formatRecord(&writer, header, .{ .payload_truncated = true })) return;
        }
        const line = writer.buffered();
        if (trace.written + line.len > trace.limit) {
            const file = openNext(trace.dir, trace.io) catch |err| {
                trace.disable(err);
                return;
            };
            if (trace.panic_attached) panic_fd.store(file.handle, .release);
            trace.file.close(trace.io);
            trace.file = file;
            trace.written = 0;
        }
        trace.file.writeStreamingAll(trace.io, line) catch |err| {
            trace.disable(err);
            return;
        };
        trace.written += line.len;
    }

    fn disable(trace: *Trace, err: anyerror) void {
        trace.failed = true;
        std.log.warn("Diagnostics file unavailable: {s}", .{@errorName(err)});
    }
};

fn formatRecord(writer: *Io.Writer, header: anytype, details: anytype) bool {
    std.json.Stringify.value(.{ .at = header, .data = details }, .{}, writer) catch return false;
    writer.writeByte('\n') catch return false;
    return true;
}

pub fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (log_trace) |trace| {
        var buffer: [1024]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, format, args) catch "Message exceeded the diagnostic buffer.";
        trace.note("zig", @tagName(scope), .{ .level = level, .message = message });
    }
    std.log.defaultLog(level, scope, format, args);
}

pub fn crash(message: []const u8, address: ?usize) noreturn {
    if (comptime builtin.link_libc and (builtin.os.tag == .macos or builtin.os.tag == .linux)) {
        const fd = panic_fd.load(.acquire);
        if (fd >= 0) {
            var buffer: [1024]u8 = undefined;
            var writer = Io.Writer.fixed(&buffer);
            const header = .{ .area = "process", .event = "panic" };
            if (formatRecord(&writer, header, .{ .message = message[0..@min(message.len, 192)] })) {
                const bytes = writer.buffered();
                _ = std.c.write(fd, bytes.ptr, bytes.len);
            }
        }
    }
    std.debug.defaultPanic(message, address);
}

test "diagnostics retain the previous trace on restart and emit parseable correlated records" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    var first = try Trace.open(io, temp.dir, "diagnostics");
    const span = first.begin("save", "write", .{ .reason = "test\ncase" });
    first.finish("save", "write", span, "ok", .{});
    first.deinit();

    var next = try Trace.open(io, temp.dir, "diagnostics");
    defer next.deinit();
    next.note("process", "start", .{});
    var buffer: [2048]u8 = undefined;
    const record = try temp.dir.readFile(io, "diagnostics/trace.previous.jsonl", &buffer);
    var lines = std.mem.tokenizeScalar(u8, record, '\n');
    for ([_][]const u8{ "begin", "end" }) |phase| {
        const line = lines.next() orelse return error.MissingDiagnostic;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const data = parsed.value.object.get("data").?.object;
        try std.testing.expectEqualStrings(phase, data.get("phase").?.string);
        try std.testing.expectEqual(@as(i64, 1), data.get("span").?.integer);
    }
    try std.testing.expect(lines.next() == null);
}

test "long traces roll over without truncating the current record" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    var trace = try Trace.open(io, temp.dir, "diagnostics");
    defer trace.deinit();
    trace.limit = 260;
    trace.note("test", "first", .{ .body = "abcdefghijabcdefghijabcdefghij" });
    trace.note("test", "second", .{ .body = "abcdefghijabcdefghijabcdefghij" });
    var buffer: [512]u8 = undefined;
    const record = try temp.dir.readFile(io, "diagnostics/trace.jsonl", &buffer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, record, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("second", parsed.value.object.get("at").?.object.get("event").?.string);
}
