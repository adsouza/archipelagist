const std = @import("std");
const builtin = @import("builtin");
const save = @import("core").save;
const diagnostics = @import("diagnostics.zig");

const app_dir = "Archipelagist";
const save_name = "archipelagist.sav";

pub const Store = struct {
    io: std.Io,
    dir: std.Io.Dir = .cwd(),
    path: []const u8,
    trace: ?*diagnostics.Trace = null,

    pub fn init(process: std.process.Init) !Store {
        const env = process.environ_map;
        const home = env.get("HOME") orelse "";
        const allocator = process.arena.allocator();
        const base: ?[]const u8 = switch (builtin.os.tag) {
            .macos => if (std.fs.path.isAbsolute(home)) try std.fs.path.join(allocator, &.{ home, "Library", "Application Support" }) else null,
            .linux => blk: {
                const xdg = env.get("XDG_DATA_HOME") orelse "";
                if (std.fs.path.isAbsolute(xdg)) break :blk xdg;
                if (std.fs.path.isAbsolute(home)) break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share" });
                break :blk null;
            },
            else => null,
        };
        const directory = base orelse return .{ .io = process.io, .path = save_name };
        return .{
            .io = process.io,
            .path = try std.fs.path.join(allocator, &.{ directory, app_dir, save_name }),
        };
    }

    pub fn read(self: Store, path: []const u8) !?save.Session {
        const span = if (self.trace) |trace| trace.begin("storage", "load", .{ .file = std.fs.path.basename(path) }) else null;
        const session = self.readSession(path) catch |err| {
            if (span) |operation| self.trace.?.finish("storage", "load", operation, "error", .{ .reason = @errorName(err) });
            return err;
        };
        if (span) |operation| {
            if (session) |restored| {
                self.trace.?.finish("storage", "load", operation, "ok", .{ .day = restored.game.day });
            } else self.trace.?.finish("storage", "load", operation, "missing", .{});
        }
        return session;
    }

    fn readSession(self: Store, path: []const u8) !?save.Session {
        var buffer: [@sizeOf(save.SessionBytes) + 1]u8 = undefined;
        const bytes = self.dir.readFile(self.io, path, &buffer) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return save.Session.decodeSession(bytes) orelse error.InvalidSave;
    }

    pub fn write(self: Store, bytes: *const save.SessionBytes) !void {
        return self.writeFileAtomic(self.path, bytes);
    }

    pub fn writeFileAtomic(self: Store, path: []const u8, bytes: []const u8) !void {
        const span = if (self.trace) |trace| trace.begin("storage", "commit", .{ .file = std.fs.path.basename(path), .bytes = bytes.len }) else null;
        self.commitAtomic(path, bytes) catch |err| {
            if (span) |operation| self.trace.?.finish("storage", "commit", operation, "error", .{ .reason = @errorName(err) });
            return err;
        };
        if (span) |operation| self.trace.?.finish("storage", "commit", operation, "ok", .{});
    }

    fn commitAtomic(self: Store, path: []const u8, bytes: []const u8) !void {
        var file = try self.dir.createFileAtomic(self.io, path, .{ .make_path = true, .replace = true });
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, bytes);
        try file.file.sync(self.io);
        try file.replace(self.io);
    }
};

test "atomic autosave creates the save directory and replaces the previous session" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const store = Store{ .io = std.testing.io, .dir = temp.dir, .path = "Archipelagist/archipelagist.sav" };
    try std.testing.expect((try store.read(store.path)) == null);

    var session = save.Session{};
    try store.write(&session.encodeSession());
    _ = session.game.tick();
    session.game.day_time = 2.5;
    session.speed = 0;
    try store.write(&session.encodeSession());

    const restored = (try store.read(store.path)).?;
    try std.testing.expectEqualDeep(session, restored);
}

test "a corrupt save stays intact and its load failure is recorded" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var trace = try diagnostics.Trace.open(std.testing.io, temp.dir, "diagnostics");
    defer trace.deinit();
    const store = Store{
        .io = std.testing.io,
        .dir = temp.dir,
        .path = "archipelagist.sav",
        .trace = &trace,
    };
    const corrupt = "not an Archipelagist save";
    try store.writeFileAtomic(store.path, corrupt);
    try std.testing.expectError(error.InvalidSave, store.read(store.path));

    var small: [64]u8 = undefined;
    try std.testing.expectEqualStrings(corrupt, try temp.dir.readFile(store.io, store.path, &small));
    var buffer: [4096]u8 = undefined;
    const data = try temp.dir.readFile(store.io, "diagnostics/trace.jsonl", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"event\":\"load\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"reason\":\"InvalidSave\"") != null);
}
