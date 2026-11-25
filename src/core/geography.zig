// Coastline samples derived from Natural Earth's public-domain 1:10m land polygons.
// Each island is rescaled to fit the isometric settlement grid. Values below 7 are water.
const std = @import("std");
const island_grids = @import("island_grids.zig");
pub const sites = @import("settlement_sites.zig");
pub const Cell = sites.Cell;
pub const tile_scale_percent = 22;
pub const tile_scale: f32 = @as(f32, tile_scale_percent) / 100;
pub const borneo = 3;
pub const sumatra = 4;
pub const palawan = 5;
pub const first_additional = palawan + 1;
pub const settlement_count = first_additional + sites.all.len;
pub const names = [_][:0]const u8{ "Java", "Bali", "Lombok", "Borneo", "Sumatra", "Palawan" } ++ blk: {
    var additional: [sites.all.len][:0]const u8 = undefined;
    for (sites.all, 0..) |site, index| additional[index] = site.name;
    break :blk additional;
};

pub fn chartNamed(name: []const u8) ?usize {
    for (names, 0..) |candidate, chart| {
        if (std.mem.eql(u8, candidate, name)) return chart;
    }
    return null;
}

pub const Grid = struct {
    width: usize,
    height: usize,
    offset: usize,
    origin: [2]f32,
    quay: Cell,

    pub fn area(g: Grid) usize {
        return g.width * g.height;
    }

    pub fn contains(g: Grid, p: Cell) bool {
        return p.x < g.width and p.y < g.height;
    }

    pub fn index(g: Grid, p: Cell) usize {
        return p.y * g.width + p.x;
    }

    pub fn cell(g: Grid, i: usize) Cell {
        return .{ .x = i % g.width, .y = i / g.width };
    }
};

pub const grids: [settlement_count]Grid = blk: {
    var result: [settlement_count]Grid = undefined;
    var offset: usize = 0;
    for (island_grids.all, 0..) |data, chart| {
        const grid = Grid{
            .width = data.rows[0].len,
            .height = data.rows.len,
            .offset = offset,
            .origin = data.origin,
            .quay = .{ .x = data.quay[0], .y = data.quay[1] },
        };
        result[chart] = grid;
        offset += grid.area();
    }
    break :blk result;
};
pub const tile_count = grids[settlement_count - 1].offset + grids[settlement_count - 1].area();
pub const land_counts = blk: {
    @setEvalBranchQuota(1_000_000);
    var counts: [settlement_count]u32 = @splat(0);
    for (island_grids.all, 0..) |data, chart| {
        for (data.rows) |row| {
            for (row) |sample| counts[chart] += @intFromBool(sample >= '7');
        }
    }
    break :blk counts;
};
pub const max_grid_area = blk: {
    var largest: usize = 0;
    for (grids) |grid| largest = @max(largest, grid.area());
    break :blk largest;
};


pub fn sampleDepth(sample: u8) f32 {
    const grade: i8 = if (sample <= '9') @intCast(sample - '0') else @intCast(sample - 'A' + 10);
    return @as(f32, @floatFromInt(grade - 7)) * 0.16;
}

pub fn depth(x: usize, y: usize, chart: usize) f32 {
    return sampleDepth(island_grids.all[chart].rows[y][x]);
}





