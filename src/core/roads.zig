const std = @import("std");
const s = @import("colony.zig");

pub const directions = [_][2]i16{ .{ 1, 0 }, .{ 0, 1 }, .{ -1, 0 }, .{ 0, -1 } };

pub fn neighbor(cell: s.Cell, direction: [2]i16, grid: s.geography.Grid) ?s.Cell {
    const x = @as(i32, @intCast(cell.x)) + direction[0];
    const y = @as(i32, @intCast(cell.y)) + direction[1];
    if (x < 0 or y < 0 or x >= grid.width or y >= grid.height) return null;
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

const max_area = s.geography.max_grid_area;
const Index = std.math.IntFittingRange(0, max_area - 1);

pub const Walk = struct {
    grid: s.geography.Grid,
    stops: [2 * max_area]Index = undefined,
    len: usize = 0,
    seen: std.StaticBitSet(max_area) = .empty,

    pub fn fromPort(tiles: []const s.Tile, chart: usize) Walk {
        const grid = s.geography.grids[chart];
        var walk = Walk{ .grid = grid };
        const port = grid.index(s.quay(chart));
        if (tiles[port].kind != .port) return walk;
        walk.extend(tiles, chart, s.quay(chart));
        return walk;
    }

    /// Add the tiles settlers reach on foot from `start`, as when they step
    /// off a bridge there. A start already reached adds nothing.
    pub fn extend(walk: *Walk, tiles: []const s.Tile, chart: usize, start: s.Cell) void {
        const grid = walk.grid;
        const root = grid.index(start);
        if (walk.seen.isSet(root) or s.depth(start, chart) < 0) return;
        var path: [max_area]Index = undefined;
        var direction_at: [max_area]u8 = undefined;
        var depth: usize = 1;
        path[0] = @intCast(root);
        direction_at[0] = 0;
        walk.record(root);
        while (depth > 0) {
            const top = depth - 1;
            if (direction_at[top] == directions.len) {
                depth -= 1;
                if (depth > 0) walk.record(path[depth - 1]);
                continue;
            }
            const direction = directions[direction_at[top]];
            direction_at[top] += 1;
            const next = neighbor(grid.cell(path[top]), direction, grid) orelse continue;
            const next_index = grid.index(next);
            if (walk.seen.isSet(next_index) or s.depth(next, chart) < 0) continue;
            // Roads span gaps between features. Settlers continue on foot from one feature to the next.
            if (tiles[next_index].kind == .empty and s.site(next, chart) == .plain and !s.forest(next, chart)) continue;
            path[depth] = @intCast(next_index);
            direction_at[depth] = 0;
            depth += 1;
            walk.record(next_index);
        }
    }

    pub fn contains(walk: *const Walk, cell: s.Cell) bool {
        return walk.seen.isSet(walk.grid.index(cell));
    }

    pub fn stop(walk: *const Walk, i: usize) s.Cell {
        return walk.grid.cell(walk.stops[i]);
    }

    fn record(walk: *Walk, i: usize) void {
        walk.seen.set(i);
        walk.stops[walk.len] = @intCast(i);
        walk.len += 1;
    }
};

test "the port walk includes new branches and skips disconnected roads" {
    var g = s.Game.init();
    const starter = s.Cell{ .x = 44, .y = 44 };
    const branch = s.Cell{ .x = starter.x - 1, .y = starter.y };
    const isolated = s.Cell{ .x = 39, .y = 58 };
    try std.testing.expect(g.build(0, branch, .road) == null);
    try std.testing.expect(g.build(0, isolated, .road) == null);
    const port = s.quay(0);
    const walk = Walk.fromPort(g.tilesOn(0), 0);
    try std.testing.expectEqualDeep(port, walk.stop(0));
    try std.testing.expectEqualDeep(port, walk.stop(walk.len - 1));
    var visited_branch = false;
    for (0..walk.len) |i| {
        const stop = walk.stop(i);
        visited_branch = visited_branch or (stop.x == branch.x and stop.y == branch.y);
        try std.testing.expect(stop.x != isolated.x or stop.y != isolated.y);
    }
    try std.testing.expect(visited_branch);
}
