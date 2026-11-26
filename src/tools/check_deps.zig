// Checks that every @import in src/ points down the layers.
//
//   zig build check-deps        (also runs as part of zig build test)
//
// build.zig already makes each folder a module that can only reach the
// modules it is given. This check adds the rules the compiler can't see:
// which named modules each folder may import, and the order of the files
// inside a folder. A file may import files from lower layers of its own
// folder only. The one exception is the Game aggregate: colony.zig and the
// parts it owns sit in one layer that may import itself.
//
// Every .zig file must be listed below, so a new file gets a deliberate place.
const std = @import("std");

pub const Layer = struct {
    files: []const []const u8,
    /// Files in this layer may import each other.
    mutual: bool = false,
};

pub const Folder = struct {
    name: []const u8,
    /// Named modules this folder may import, besides std.
    modules: []const []const u8,
    /// Lowest first.
    layers: []const Layer,
};

pub const policy = [_]Folder{
    .{
        .name = "core",
        .modules = &.{},
        .layers = &.{
            .{ .files = &.{ "terrain.zig", "island_grids.zig", "settlement_sites.zig", "ferry_lanes.zig" } },
            .{ .files = &.{"geography.zig"} },
            .{ .files = &.{"expedition.zig"} },
            .{ .files = &.{ "colony.zig", "fleet.zig", "ferry.zig", "bridge.zig", "charter.zig", "roads.zig" }, .mutual = true },
            .{ .files = &.{ "gameplay.zig", "queries.zig", "stock_warnings.zig", "save.zig" } },
            .{ .files = &.{"journal.zig"} },
            .{ .files = &.{ "stateful.zig", "autoplay.zig" } },
            .{ .files = &.{"root.zig"} },
        },
    },
    .{
        .name = "shell",
        .modules = &.{ "builtin", "core" },
        .layers = &.{
            .{ .files = &.{ "diagnostics.zig", "journal_file.zig", "browser.zig" } },
            .{ .files = &.{"save_store.zig"} },
            .{ .files = &.{"gameplay_trace.zig"} },
            .{ .files = &.{"properties.zig"} },
            .{ .files = &.{"root.zig"} },
        },
    },
    .{
        .name = "app",
        .modules = &.{ "builtin", "core", "shell", "raylib" },
        .layers = &.{
            .{ .files = &.{ "region.zig", "audio.zig", "window_settings.zig" } },
            .{ .files = &.{"art.zig"} },
            .{ .files = &.{"chart.zig"} },
            .{ .files = &.{ "main.zig", "presentation_tests.zig" } },
        },
    },
    .{
        .name = "tools",
        .modules = &.{ "builtin", "core" },
        .layers = &.{
            .{ .files = &.{ "replay.zig", "bake_lanes.zig", "check_deps.zig", "link_bin.zig" } },
        },
    },
};

pub const Source = struct {
    /// Relative to src/, with forward slashes, such as "core/ferry.zig".
    path: []const u8,
    text: []const u8,
};

pub const Import = struct {
    line: usize,
    target: []const u8,
};

/// The @import targets in `text`, skipping ones after a // comment marker.
pub fn imports(text: []const u8, out: []Import) []Import {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        const code = if (std.mem.indexOf(u8, line, "//")) |c| line[0..c] else line;
        var rest = code;
        while (std.mem.indexOf(u8, rest, "@import(\"")) |at| {
            const start = at + "@import(\"".len;
            const len = std.mem.indexOfScalar(u8, rest[start..], '"') orelse break;
            if (count == out.len) return out;
            out[count] = .{ .line = number, .target = rest[start..][0..len] };
            count += 1;
            rest = rest[start + len ..];
        }
    }
    return out[0..count];
}

const Place = struct { folder: *const Folder, layer: usize };

fn place(folders: []const Folder, path: []const u8) ?Place {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    for (folders) |*folder| {
        if (!std.mem.eql(u8, folder.name, path[0..slash])) continue;
        for (folder.layers, 0..) |layer, i| {
            for (layer.files) |file| if (std.mem.eql(u8, file, path[slash + 1 ..])) return .{ .folder = folder, .layer = i };
        }
        return null;
    }
    return null;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Writes one line per violation and returns how many there were.
pub fn check(folders: []const Folder, sources: []const Source, w: *std.Io.Writer) !usize {
    var problems: usize = 0;
    for (sources) |source| {
        const here = place(folders, source.path) orelse {
            try w.print("src/{s}: not listed in src/tools/check_deps.zig; add it to a folder layer\n", .{source.path});
            problems += 1;
            continue;
        };
        var buffer: [128]Import = undefined;
        for (imports(source.text, &buffer)) |import| {
            const target = import.target;
            if (!std.mem.endsWith(u8, target, ".zig")) {
                if (std.mem.eql(u8, target, "std") or contains(here.folder.modules, target)) continue;
                try w.print("src/{s}:{d}: {s} may not import the \"{s}\" module\n", .{ source.path, import.line, here.folder.name, target });
                problems += 1;
                continue;
            }
            if (std.mem.indexOfAny(u8, target, "/\\") != null) {
                try w.print("src/{s}:{d}: imports \"{s}\" by path; import another folder through its module\n", .{ source.path, import.line, target });
                problems += 1;
                continue;
            }
            var path_buffer: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ here.folder.name, target });
            const there = place(folders, path) orelse {
                try w.print("src/{s}:{d}: imports {s}, which is not listed in src/tools/check_deps.zig\n", .{ source.path, import.line, target });
                problems += 1;
                continue;
            };
            if (there.layer < here.layer) continue;
            if (there.layer == here.layer and here.folder.layers[here.layer].mutual) continue;
            try w.print("src/{s}:{d}: imports {s}, which is {s} it in {s}'s layers; imports must point down\n", .{
                source.path,
                import.line,
                target,
                if (there.layer == here.layer) "level with" else "above",
                here.folder.name,
            });
            problems += 1;
        }
    }
    for (folders) |folder| for (folder.layers) |layer| for (layer.files) |file| {
        for (sources) |source| {
            const slash = std.mem.indexOfScalar(u8, source.path, '/') orelse continue;
            if (std.mem.eql(u8, source.path[0..slash], folder.name) and std.mem.eql(u8, source.path[slash + 1 ..], file)) break;
        } else {
            try w.print("src/tools/check_deps.zig: lists {s}/{s}, which does not exist\n", .{ folder.name, file });
            problems += 1;
        }
    };
    return problems;
}

pub fn main(process: std.process.Init) !u8 {
    const io = process.io;
    const arena = process.arena.allocator();
    const args = try process.minimal.args.toSlice(arena);
    const root_path = if (args.len > 1) args[1] else "src";

    var sources: std.ArrayList(Source) = .empty;
    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try arena.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const text = try root.readFileAlloc(io, entry.path, arena, .limited(16 << 20));
        try sources.append(arena, .{ .path = path, .text = text });
    }

    var buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    const w = &stderr.interface;
    defer w.flush() catch {};
    const problems = try check(&policy, sources.items, w);
    if (problems == 0) return 0;
    try w.print("{d} dependency problem(s). Layers are listed in src/tools/check_deps.zig.\n", .{problems});
    return 1;
}

fn report(sources: []const Source) ![]const u8 {
    const S = struct {
        var buffer: [4096]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buffer);
    _ = try check(&test_policy, sources, &w);
    return w.buffered();
}

const test_policy = [_]Folder{
    .{ .name = "core", .modules = &.{}, .layers = &.{
        .{ .files = &.{"low.zig"} },
        .{ .files = &.{ "a.zig", "b.zig" }, .mutual = true },
        .{ .files = &.{ "high.zig", "peer.zig" } },
    } },
    .{ .name = "app", .modules = &.{"core"}, .layers = &.{.{ .files = &.{"main.zig"} }} },
};

const clean = [_]Source{
    .{ .path = "core/low.zig", .text = "const std = @import(\"std\");\n" },
    .{ .path = "core/a.zig", .text = "const b = @import(\"b.zig\");\nconst low = @import(\"low.zig\");\n" },
    .{ .path = "core/b.zig", .text = "const a = @import(\"a.zig\");\n" },
    .{ .path = "core/high.zig", .text = "const a = @import(\"a.zig\"); // @import(\"peer.zig\") in a comment\n" },
    .{ .path = "core/peer.zig", .text = "" },
    .{ .path = "app/main.zig", .text = "const core = @import(\"core\");\n" },
};

test "downward imports, the mutual layer and comments pass" {
    try std.testing.expectEqualStrings("", try report(&clean));
}

test "upward, sideways, cross-folder and unknown imports are reported with their line" {
    var sources = clean;
    sources[0].text = "const std = @import(\"std\");\nconst high = @import(\"high.zig\");\n";
    sources[3].text = "const peer = @import(\"peer.zig\");\nconst r = @import(\"raylib\");\n";
    sources[4].text = "const main = @import(\"../app/main.zig\");\n";
    try std.testing.expectEqualStrings(
        "src/core/low.zig:2: imports high.zig, which is above it in core's layers; imports must point down\n" ++
            "src/core/high.zig:1: imports peer.zig, which is level with it in core's layers; imports must point down\n" ++
            "src/core/high.zig:2: core may not import the \"raylib\" module\n" ++
            "src/core/peer.zig:1: imports \"../app/main.zig\" by path; import another folder through its module\n",
        try report(&sources),
    );
}

test "unlisted and missing files are reported" {
    const sources = [_]Source{
        clean[0], clean[1], clean[2], clean[3], clean[5],
        .{ .path = "core/new.zig", .text = "" },
    };
    try std.testing.expectEqualStrings(
        "src/core/new.zig: not listed in src/tools/check_deps.zig; add it to a folder layer\n" ++
            "src/tools/check_deps.zig: lists core/peer.zig, which does not exist\n",
        try report(&sources),
    );
}
