const std = @import("std");
const r = @import("raylib");
const Store = @import("shell").save_store.Store;

pub const default_width = 1200;
pub const default_height = 760;
pub const min_width = 720;
pub const min_height = 456;
const max_dimension = 16384;
const bytes_len = 21;

const Placement = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    maximized: bool = false,

    fn validSize(self: Placement) bool {
        return self.width >= min_width and self.height >= min_height and
            self.width <= max_dimension and self.height <= max_dimension;
    }

    fn encode(self: Placement) [bytes_len]u8 {
        var bytes: [bytes_len]u8 = undefined;
        bytes[0..4].* = "WIN1".*;
        inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| {
            std.mem.writeInt(i32, bytes[4 + 4 * i ..][0..4], @field(self, field), .little);
        }
        bytes[20] = @intFromBool(self.maximized);
        return bytes;
    }

    fn decode(bytes: []const u8) ?Placement {
        if (bytes.len != bytes_len or !std.mem.eql(u8, bytes[0..4], "WIN1") or bytes[20] > 1) return null;
        var placement: Placement = undefined;
        inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| {
            @field(placement, field) = std.mem.readInt(i32, bytes[4 + 4 * i ..][0..4], .little);
        }
        placement.maximized = bytes[20] == 1;
        return if (placement.validSize()) placement else null;
    }

    fn visibleOn(self: Placement, x: i32, y: i32, width: i32, height: i32) bool {
        const right = @min(@as(i64, self.x) + self.width, @as(i64, x) + width);
        const left = @max(self.x, x);
        return right - left >= 160 and self.y >= y and @as(i64, self.y) + 64 <= @as(i64, y) + height;
    }

    fn visible(self: Placement) bool {
        const count = r.getMonitorCount();
        var monitor: i32 = 0;
        while (monitor < count) : (monitor += 1) {
            const origin = r.getMonitorPosition(monitor);
            if (self.visibleOn(@intFromFloat(origin.x), @intFromFloat(origin.y), r.getMonitorWidth(monitor), r.getMonitorHeight(monitor))) {
                return true;
            }
        }
        return false;
    }
};

pub const Settings = struct {
    path: []const u8,
    last_saved: ?Placement = null,
    current: ?Placement = null,

    pub fn init(allocator: std.mem.Allocator, store: Store, enabled: bool) !Settings {
        const directory = std.fs.path.dirname(store.path) orelse ".";
        const path = try std.fs.path.join(allocator, &.{ directory, "window.bin" });
        var settings = Settings{ .path = path };
        if (enabled) {
            var buffer: [bytes_len + 1]u8 = undefined;
            const data = store.dir.readFile(store.io, path, &buffer) catch |err| {
                if (store.trace) |trace| trace.note("window", "placement_read", .{ .reason = @errorName(err) });
                return settings;
            };
            settings.last_saved = Placement.decode(data);
            if (store.trace) |trace| trace.note("window", "placement_read", .{ .valid = settings.last_saved != null });
        }
        return settings;
    }

    pub fn open(self: *Settings, title: [:0]const u8) void {
        r.setConfigFlags(.{
            .window_resizable = true,
            .msaa_4x_hint = true,
            .vsync_hint = true,
            .window_hidden = self.last_saved != null,
        });
        r.initWindow(default_width, default_height, title);
        r.setWindowMinSize(min_width, min_height);
        if (self.last_saved) |placement| {
            if (placement.visible()) {
                r.setWindowSize(placement.width, placement.height);
                r.setWindowPosition(placement.x, placement.y);
                self.current = placement;
            }
            r.clearWindowState(.{ .window_hidden = true });
            if (self.current != null and placement.maximized) r.maximizeWindow();
        }
        self.observe();
    }

    pub fn observe(self: *Settings) void {
        // Keep the normal window bounds while iconified or in fullscreen.
        if (r.isWindowMinimized() or r.isWindowFullscreen()) return;
        if (r.isWindowMaximized()) {
            if (self.current) |*current| current.maximized = true;
            return;
        }
        const position = r.getWindowPosition();
        const placement = Placement{
            .x = @intFromFloat(position.x),
            .y = @intFromFloat(position.y),
            .width = r.getScreenWidth(),
            .height = r.getScreenHeight(),
        };
        if (placement.validSize()) self.current = placement;
    }

    pub fn save(self: *Settings, store: Store) !void {
        const current = self.current orelse return;
        if (self.last_saved) |previous| {
            if (std.meta.eql(previous, current)) return;
        }
        try store.writeFileAtomic(self.path, &current.encode());
        self.last_saved = current;
    }
};

test "window bounds round trip on a monitor left of the primary display" {
    const placement = Placement{ .x = -1230, .y = 175, .width = 900, .height = 620, .maximized = true };
    const encoded = placement.encode();
    try std.testing.expectEqualDeep(placement, Placement.decode(&encoded).?);
    try std.testing.expect(placement.visibleOn(-1600, 0, 1600, 900));
    try std.testing.expect(!placement.visibleOn(0, 0, 1920, 1080));
    const invalid = Placement{ .x = 25, .y = 25, .width = 0, .height = 0 };
    try std.testing.expect(Placement.decode(&invalid.encode()) == null);
}
