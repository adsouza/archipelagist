const std = @import("std");
const r = @import("raylib");
const s = @import("core").colony;
const roads = @import("core").roads;
const region = @import("core").region;
// The hand-drawn island art was drawn for each island's first, smaller
// layout. These place and scale it on the chart.
const art_origins = [_][2]f32{
    .{ 0, 0 }, .{ 867, 200 }, .{ 1226, 155 }, .{ 570, -658.7 }, .{ -1401.5, -1003.19 }, .{ 1398, -1553 },
} ++ blk: {
    var additional: [s.geography.sites.all.len][2]f32 = undefined;
    for (s.geography.sites.all, 0..) |site, index| additional[index] = site.origin;
    break :blk additional;
};
const art_scales = [_]f32{ 1, 0.54, 0.72, 1.1, 0.97, 1.05 } ++ blk: {
    var additional: [s.geography.sites.all.len]f32 = undefined;
    for (s.geography.sites.all, 0..) |site, index| additional[index] = site.scale;
    break :blk additional;
};
pub const V = r.Vector2;

/// Quarter turns on the ground plane, preserving the isometric tile proportions.
pub const Orientation = enum(u2) {
    north,
    east,
    south,
    west,

    pub fn apply(angle: Orientation, point: V) V {
        const ratio = s.tile_width / s.tile_height;
        return switch (angle) {
            .north => point,
            .east => v(-point.y * ratio, point.x / ratio),
            .south => v(-point.x, -point.y),
            .west => v(point.y * ratio, -point.x / ratio),
        };
    }

    pub fn inverse(angle: Orientation) Orientation {
        return @fromBackingInt(0 -% @backingInt(angle));
    }
};
pub fn v(x: f32, y: f32) V {
    return .{ .x = x, .y = y };
}
pub fn f(n: anytype) f32 {
    return @floatFromInt(n);
}
pub fn c(n: u32) r.Color {
    return .{ .r = @truncate(n >> 16), .g = @truncate(n >> 8), .b = @truncate(n), .a = 255 };
}
pub fn line(a: V, b: V, w: f32, col: u32) void {
    r.drawLineEx(a, b, w, c(col));
}
pub fn rect(x: f32, y: f32, w: f32, h: f32, col: u32) void {
    r.drawRectangleRec(.{ .x = x, .y = y, .width = w, .height = h }, c(col));
}
pub fn tri(a: V, b: V, d: V, col: u32) void {
    drawTriangle(a, b, d, c(col));
}
fn drawTriangle(a: V, b: V, d: V, color: r.Color) void {
    if ((b.x - a.x) * (d.y - a.y) - (b.y - a.y) * (d.x - a.x) > 0) r.drawTriangle(a, d, b, color) else r.drawTriangle(a, b, d, color);
}
fn quad(a: V, b: V, d: V, e: V, col: u32) void {
    tri(a, b, d, col);
    tri(a, d, e, col);
}
pub fn diamond(x: f32, y: f32, w: f32, h: f32, col: u32) void {
    quad(v(x - w, y), v(x, y - h), v(x + w, y), v(x, y + h), col);
}
pub fn tileOutline(pos: V, width: f32, height: f32, thickness: f32, color: u32) void {
    const corners = [_]V{
        v(pos.x - width, pos.y), v(pos.x, pos.y - height),
        v(pos.x + width, pos.y), v(pos.x, pos.y + height),
    };
    for (corners, 0..) |point, i| line(point, corners[(i + 1) % corners.len], thickness, color);
}

/// Test the same projected geometry we draw against the hovered tile's diamond.
fn separated(axes: []const V, other: []const V) bool {
    for (axes, 0..) |point, i| {
        const next = axes[(i + 1) % axes.len];
        const normal = v(point.y - next.y, next.x - point.x);
        if (normal.x == 0 and normal.y == 0) continue;
        var lower = normal.x * axes[0].x + normal.y * axes[0].y;
        var upper = lower;
        for (axes[1..]) |vertex| {
            const projection = normal.x * vertex.x + normal.y * vertex.y;
            lower = @min(lower, projection);
            upper = @max(upper, projection);
        }
        var other_lower = normal.x * other[0].x + normal.y * other[0].y;
        var other_upper = other_lower;
        for (other[1..]) |vertex| {
            const projection = normal.x * vertex.x + normal.y * vertex.y;
            other_lower = @min(other_lower, projection);
            other_upper = @max(other_upper, projection);
        }
        if (upper <= other_lower or other_upper <= lower) return true;
    }
    return false;
}

const OccluderPaint = struct {
    // With a tile supplied, collect overlap instead of drawing.
    tile_center: ?V = null,
    covered: bool = false,
    alpha: u8 = 255,

    fn opacity(probe: OccluderPaint) u8 {
        return if (probe.covered) 72 else 255;
    }

    fn color(paint: *const OccluderPaint, rgb: u32) r.Color {
        var result = c(rgb);
        result.a = paint.alpha;
        return result;
    }

    fn overlap(paint: *OccluderPaint, vertices: []const V) void {
        if (paint.covered) return;
        const pos = paint.tile_center.?;
        const width = s.tile_width * s.geography.tile_scale;
        const height = s.tile_height * s.geography.tile_scale;
        const corners = [_]V{ v(pos.x - width, pos.y), v(pos.x, pos.y - height), v(pos.x + width, pos.y), v(pos.x, pos.y + height) };
        paint.covered = !separated(&corners, vertices) and !separated(vertices, &corners);
    }

    fn line(paint: *OccluderPaint, from: V, to: V, width: f32, rgb: u32) void {
        if (paint.tile_center == null) {
            r.drawLineEx(from, to, width, paint.color(rgb));
            return;
        }
        if (paint.covered) return;
        const x = to.x - from.x;
        const y = to.y - from.y;
        const length = @sqrt(x * x + y * y);
        if (length == 0) return;
        const dx = -y * width / (2 * length);
        const dy = x * width / (2 * length);
        paint.overlap(&.{ v(from.x + dx, from.y + dy), v(to.x + dx, to.y + dy), v(to.x - dx, to.y - dy), v(from.x - dx, from.y - dy) });
    }

    fn tri(paint: *OccluderPaint, first: V, second: V, third: V, rgb: u32) void {
        if (paint.tile_center != null) {
            paint.overlap(&.{ first, second, third });
        } else {
            drawTriangle(first, second, third, paint.color(rgb));
        }
    }

    fn quad(paint: *OccluderPaint, first: V, second: V, third: V, fourth: V, rgb: u32) void {
        paint.tri(first, second, third, rgb);
        paint.tri(first, third, fourth, rgb);
    }

    fn diamond(paint: *OccluderPaint, x: f32, y: f32, w: f32, h: f32, rgb: u32) void {
        paint.quad(v(x - w, y), v(x, y - h), v(x + w, y), v(x, y + h), rgb);
    }

    fn rect(paint: *OccluderPaint, x: f32, y: f32, w: f32, h: f32, rgb: u32) void {
        if (paint.tile_center != null) {
            paint.overlap(&.{ v(x, y), v(x + w, y), v(x + w, y + h), v(x, y + h) });
        } else {
            r.drawRectangleRec(.{ .x = x, .y = y, .width = w, .height = h }, paint.color(rgb));
        }
    }

    fn settler(paint: *OccluderPaint, pos: V, rgb: u32) void {
        paint.line(pos, v(pos.x, pos.y - 5), 3, rgb);
        if (paint.tile_center == null) r.drawCircleV(v(pos.x, pos.y - 6), 1.8, paint.color(0xe6be88));
    }
};

pub fn tile(p: s.Cell) V {
    const point = s.localTile(p);
    return v(point[0], point[1]);
}
fn gridPoint(local: V) V {
    const dx = local.x / s.tile_width;
    const dy = local.y / s.tile_height;
    return v((dx + dy) / 2, (dy - dx) / 2);
}

pub fn pick(local: V, chart: usize) ?s.Cell {
    const p = gridPoint(local);
    const x = @round(p.x);
    const y = @round(p.y);
    const grid = s.geography.grids[chart];
    if (x < 0 or y < 0 or x >= f(grid.width) or y >= f(grid.height)) return null;
    return .{ .x = @intFromFloat(x), .y = @intFromFloat(y) };
}

const TileRange = struct { x0: usize, x1: usize, y0: usize, y1: usize };

pub fn visibleTiles(chart: usize, top: V, bottom: V) ?TileRange {
    const grid = s.geography.grids[chart];
    // Upright art near the edge can extend into the view from a culled tile.
    const margin = 120;
    const upper = gridPoint(v(top.x - margin, top.y - margin));
    const lower = gridPoint(v(bottom.x + margin, bottom.y + margin));
    const left = gridPoint(v(bottom.x + margin, top.y - margin));
    const right = gridPoint(v(top.x - margin, bottom.y + margin));
    const area = TileRange{
        .x0 = @intFromFloat(std.math.clamp(@floor(upper.x), 0, f(grid.width))),
        .x1 = @intFromFloat(std.math.clamp(@ceil(lower.x) + 1, 0, f(grid.width))),
        .y0 = @intFromFloat(std.math.clamp(@floor(left.y), 0, f(grid.height))),
        .y1 = @intFromFloat(std.math.clamp(@ceil(right.y) + 1, 0, f(grid.height))),
    };
    return if (area.x0 < area.x1 and area.y0 < area.y1) area else null;
}

fn tree(x: f32, y: f32, h: f32, light: bool) void {
    diamond(x + 3, y, 9, 3, 0x798458);
    line(v(x, y), v(x, y - h * 0.5), 2, 0x72573b);
    for (0..3) |i| {
        const top = y - h + f(i) * h * 0.17;
        const w = h * (0.17 + 0.035 * f(i));
        const base = top + h * 0.45;
        tri(v(x, top), v(x - w, base - 2), v(x + 1, base), if (light) 0x688355 else 0x416e55);
        tri(v(x, top), v(x + 1, base), v(x + w, base - 3), if (light) 0x4b704b else 0x2c594a);
    }
}
fn house(x: f32, y: f32, k: f32, port: bool) void {
    const w = 16 * k;
    const h = 14 * k;
    const d = 8 * k;
    const a = v(x - w, y - d);
    const b = v(x, y);
    const e = v(x + w, y - d);
    const at = v(a.x, a.y - h);
    const bt = v(x, y - h);
    const et = v(e.x, e.y - h);
    quad(a, b, bt, at, 0xf3dcaa);
    quad(b, e, et, bt, 0xb99d71);
    const ridge = v(at.x + w * 0.46, at.y - 11 * k);
    tri(at, bt, ridge, 0xf6e5bb);
    quad(ridge, v(ridge.x + w, ridge.y - d), et, bt, if (port) 0x496076 else 0xb55e42);
    tri(at, ridge, v(at.x + w, at.y - d), if (port) 0x678597 else 0xd98c61);
    tri(ridge, v(at.x + w, at.y - d), v(ridge.x + w, ridge.y - d), if (port) 0x678597 else 0xd98c61);
    line(at, ridge, 1.5 * k, 0x6c5844);
    line(ridge, bt, 1.5 * k, 0x6c5844);
    rect(x - w * 0.65, y - d - 5 * k, 4 * k, 8 * k, 0x665944);
    rect(x + 5 * k, y - 10 * k, 4 * k, 4 * k, 0x4d5a51);
    rect(x + 6 * k, y - h - 13 * k, 3 * k, 8 * k, 0x836755);
}

fn apartments(x: f32, y: f32, size: f32) void {
    const w = 20 * size;
    const d = 10 * size;
    const h = 35 * size;
    const left = v(x - w, y - d);
    const front = v(x, y);
    const right = v(x + w, y - d);
    quad(left, front, v(x, y - h), v(left.x, left.y - h), 0xe5c49f);
    quad(front, right, v(right.x, right.y - h), v(x, y - h), 0xbc8e70);
    diamond(x, y - d - h, w + 2 * size, d + size, 0x975d51);
    diamond(x, y - d - h - 1.5 * size, w - 2 * size, d - size, 0xc07b61);
    for (0..3) |floor| {
        const base = y - (9 + 10 * f(floor)) * size;
        for ([_]f32{ 5, 13 }) |offset| {
            const window_y = base - offset * size / 2;
            rect(x - (offset + 2) * size, window_y, 4 * size, 5 * size, 0x426364);
            rect(x + (offset - 2) * size, window_y, 4 * size, 5 * size, 0x345153);
        }
    }
    line(v(x - 6 * size, y - 9 * size), v(x - 6 * size, y - 3 * size), 4 * size, 0x784e3a);
}

fn townSquare(x: f32, y: f32, size: f32) void {
    const center_y = y - 4 * size;
    diamond(x, center_y, 28 * size, 14 * size, 0x8d8773);
    diamond(x, center_y - size, 25 * size, 12 * size, 0xdad0b0);
    line(v(x - 25 * size, center_y - size), v(x, center_y + 11 * size), size, 0xb6a78a);
    line(v(x + 25 * size, center_y - size), v(x, center_y + 11 * size), size, 0xb6a78a);
    for ([_]f32{ -16, 16 }) |offset| {
        const planter_x = x + offset * size;
        diamond(planter_x, center_y, 5 * size, 2.5 * size, 0xa7866a);
        r.drawCircleV(v(planter_x, center_y - 3 * size), 3.5 * size, c(0x577755));
    }
    diamond(x, center_y + size, 10 * size, 5 * size, 0x8f8f7d);
    diamond(x, center_y - 2 * size, 9 * size, 4.5 * size, 0xf1e4c6);
    diamond(x, center_y - 2 * size, 6.5 * size, 3 * size, 0x5c999b);
    line(v(x, center_y - 2 * size), v(x, center_y - 10 * size), 2 * size, 0xcee4db);
}

fn fruitTree(x: f32, y: f32) void {
    diamond(x + 2, y + 1, 13, 5, 0x84925e);
    line(v(x, y), v(x, y - 22), 4, 0x806445);
    line(v(x, y - 12), v(x - 8, y - 19), 2, 0x806445);
    r.drawCircleV(v(x - 8, y - 21), 10, c(0x586f49));
    r.drawCircleV(v(x + 7, y - 20), 10, c(0x60805a));
    r.drawCircleV(v(x, y - 28), 11, c(0x73945e));
    for ([_]V{ v(-10, -22), v(-2, -30), v(7, -24), v(11, -17), v(-1, -18) }) |fruit| {
        r.drawCircleV(v(x + fruit.x, y + fruit.y), 2.8, c(0xd76c42));
        r.drawCircleV(v(x + fruit.x - 0.6, y + fruit.y - 0.8), 1, c(0xf6ad65));
    }
}

fn rocks(x: f32, y: f32, size: f32) void {
    diamond(x, y + 1, 24 * size, 10 * size, 0x849080);
    quad(v(x - 16 * size, y), v(x - 11 * size, y - 18 * size), v(x + 4 * size, y - 21 * size), v(x + 11 * size, y - 5 * size), 0xa8aca3);
    quad(v(x - 16 * size, y), v(x + 11 * size, y - 5 * size), v(x + 4 * size, y - 21 * size), v(x + 10 * size, y), 0x737d7a);
    diamond(x + 15 * size, y - 4 * size, 8 * size, 5 * size, 0xbcc0ae);
}

fn deer(x: f32, y: f32, size: f32, antlers: bool) void {
    const brown = 0x8e5132;
    diamond(x, y, 8 * size, 3 * size, 0x7e8e65);
    line(v(x - 5 * size, y - 8 * size), v(x - 6 * size, y), 1.6 * size, brown);
    line(v(x + 4 * size, y - 8 * size), v(x + 3 * size, y), 1.6 * size, brown);
    line(v(x - 7 * size, y - 9 * size), v(x + 5 * size, y - 10 * size), 5 * size, 0xbb8150);
    line(v(x + 4 * size, y - 8 * size), v(x + 8 * size, y - 16 * size), 2.8 * size, brown);
    line(v(x + 7 * size, y - 16 * size), v(x + 11 * size, y - 15 * size), 2.8 * size, 0xc79464);
    if (antlers) {
        line(v(x + 8 * size, y - 16 * size), v(x + 5 * size, y - 23 * size), size, brown);
        line(v(x + 7 * size, y - 19 * size), v(x + 10 * size, y - 22 * size), size, brown);
    } else {
        line(v(x + 8 * size, y - 16 * size), v(x + 6 * size, y - 19 * size), 1.4 * size, brown);
    }
}

pub fn building(k: s.Kind, x: f32, y: f32, size: f32) void {
    buildingWithStock(k, x, y, size, s.harvest_capacity);
}

fn buildingWithStock(k: s.Kind, x: f32, y: f32, size: f32, stock: u4) void {
    switch (k) {
        .empty, .plaza_paving => {},
        .road => {
            line(v(x - 19 * size, y + 9 * size), v(x + 19 * size, y - 9 * size), 8 * size, 0x717d78);
            line(v(x - 19 * size, y + 9 * size), v(x + 19 * size, y - 9 * size), 5 * size, 0xc2c6b9);
        },
        .well => {
            diamond(x, y, 15 * size, 7 * size, 0x81867a);
            diamond(x, y - 4 * size, 14 * size, 7 * size, 0xc6c4ab);
            diamond(x, y - 4 * size, 10 * size, 4 * size, 0x3d747c);
            line(v(x - 9 * size, y - 6 * size), v(x - 9 * size, y - 25 * size), 2.5 * size, 0x775538);
            line(v(x + 9 * size, y - 6 * size), v(x + 9 * size, y - 25 * size), 2.5 * size, 0x775538);
            line(v(x - 11 * size, y - 25 * size), v(x + 11 * size, y - 25 * size), 3 * size, 0xaf7650);
            line(v(x, y - 24 * size), v(x, y - 10 * size), 1.4 * size, 0xd6c290);
            rect(x - 3 * size, y - 13 * size, 6 * size, 5 * size, 0x66583f);
        },
        .quarry => {
            rocks(x - 5 * size, y, size);
            house(x + 12 * size, y + 2 * size, size * 0.48, true);
        },
        .lodge => {
            house(x - 5 * size, y, size * 0.8, false);
            if (stock != 0) deer(x + 11 * size, y + 4 * size, size * 0.62, true);
        },
        .cottage => house(x, y, size, false),
        .apartment => apartments(x, y, size),
        .plaza => townSquare(x, y, size),
        .port => {
            house(x, y, size * 1.3, true);
            line(v(x - 18 * size, y - 16 * size), v(x - 18 * size, y - 44 * size), 1.5, 0x64523d);
            tri(v(x - 18 * size, y - 44 * size), v(x - 6 * size, y - 41 * size), v(x - 18 * size, y - 38 * size), 0xca704b);
        },
        .grove => {
            if (stock == 0) {
                diamond(x - 8 * size, y - 3 * size, 5 * size, 2.5 * size, 0x91693f);
            } else {
                const height = 14 + 17 * f(stock) / f(s.harvest_capacity);
                tree(x - 8 * size, y - 3 * size, height * size, false);
            }
            house(x + 4 * size, y + 3 * size, size * 0.72, false);
            for (0..3) |i| line(v(x + 7 * size, y + f(i) * 2 * size), v(x + 19 * size, y - 6 * size + f(i) * 2 * size), 3 * size, 0x91693f);
        },
        .farm => {
            diamond(x, y, 26 * size, 12 * size, 0x9f7948);
            for (0..7) |i| {
                const t = f(i) / 7;
                line(v(x + (t - 1) * 24 * size, y - t * 11 * size), v(x + t * 24 * size, y + (1 - t) * 11 * size), 2.5 * size, 0xe4bc69);
            }
            house(x - 7 * size, y - 3 * size, size * 0.64, false);
        },
        .light => {
            diamond(x, y, 12 * size, 5 * size, 0x95876c);
            quad(v(x - 7 * size, y), v(x + 7 * size, y), v(x + 4 * size, y - 35 * size), v(x - 4 * size, y - 35 * size), 0xf3dab1);
            rect(x - 5.4 * size, y - 24 * size, 11 * size, 7 * size, 0xad5d46);
            rect(x - 5 * size, y - 38 * size, 10 * size, 6 * size, 0xe9b657);
            tri(v(x - 8 * size, y - 38 * size), v(x, y - 44 * size), v(x + 8 * size, y - 38 * size), 0x354d50);
        },
    }
}
fn boat(paint: *OccluderPaint, pos: V, time: f32, heading: f32, passengers: u16, underway: bool) void {
    const x = pos.x;
    const y = pos.y + @sin(time * 1.6) * 1.3;
    // Reflect vertices before paint.tri() orders them for raylib's backface culling.
    paint.diamond(x, y + 2, 30, 6, 0x3a777a);
    paint.quad(v(x - 25 * heading, y - 6), v(x + 28 * heading, y - 10), v(x + 15 * heading, y + 2), v(x - 12 * heading, y + 4), 0x78523d);
    paint.line(v(x - 24 * heading, y - 6), v(x + 26 * heading, y - 10), 3, 0xc29864);
    paint.line(v(x, y - 8), v(x, y - 54), 2, 0x594f3f);
    paint.tri(v(x - 3 * heading, y - 49), v(x - 21 * heading, y - 13), v(x - 3 * heading, y - 16), 0xffe4af);
    paint.tri(v(x + 2 * heading, y - 45), v(x + 20 * heading, y - 16), v(x + 2 * heading, y - 13), 0xe7c58e);
    if (underway) paint.settler(v(x + 18 * heading, y - 8), 0x31565a);
    for (0..@min(s.ferry_capacity, passengers)) |i| {
        paint.settler(v(x + (-14 + f(i) * 9) * heading, y - 6), if (i % 2 == 0) 0x456870 else 0x855a46);
    }
    paint.tri(v(x, y - 55), v(x + 12 * heading, y - 52), v(x, y - 50), 0xc26b4c);
}
pub fn origin(chart: usize) V {
    const o = s.geography.grids[chart].origin;
    return v(o[0], o[1]);
}

pub fn worldPoint(chart: usize, point: V) V {
    const o = origin(chart);
    const scale = s.geography.tile_scale;
    return v(o.x + point.x * scale, o.y + point.y * scale);
}

pub fn artWorldPoint(chart: usize, point: V) V {
    const origin_point = art_origins[chart];
    const scale = art_scales[chart];
    return v(origin_point[0] + point.x * scale, origin_point[1] + point.y * scale);
}

pub fn localPoint(chart: usize, point: V) V {
    const o = origin(chart);
    const scale = s.geography.tile_scale;
    return v((point.x - o.x) / scale, (point.y - o.y) / scale);
}

pub const sea_left: f32 = -2550;
pub const sea_top: f32 = -3350;
pub const sea_width: f32 = 9400;
pub const sea_height: f32 = 5100;

pub fn sea(t: f32, upper_left: V, lower_right: V, angle: Orientation) void {
    const first = angle.apply(upper_left);
    const last = angle.apply(lower_right);
    rect(@min(first.x, last.x), @min(first.y, last.y), @abs(last.x - first.x), @abs(last.y - first.y), 0x549296);
    for (0..@as(usize, @intFromFloat(@ceil(sea_width / 48)))) |i| line(angle.apply(v(sea_left + f(i) * 48, sea_top)), angle.apply(v(sea_left + f(i) * 48, sea_top + sea_height)), 0.8, 0x609b9c);
    for (0..@as(usize, @intFromFloat(@ceil(sea_height / 48)))) |i| line(angle.apply(v(sea_left, sea_top + f(i) * 48)), angle.apply(v(sea_left + sea_width, sea_top + f(i) * 48)), 0.8, 0x609b9c);
    for (0..2440) |i| {
        const x = f(s.hash(i, 1, 0) % @as(usize, @intFromFloat(sea_width))) + sea_left + @sin(t * 0.6 + f(i)) * 2;
        if (x < upper_left.x - 12 or x > lower_right.x) continue;
        const y = f(s.hash(i, 3, 0) % @as(usize, @intFromFloat(sea_height))) + sea_top;
        if (y < upper_left.y - 2 or y > lower_right.y + 2) continue;
        line(angle.apply(v(x, y)), angle.apply(v(x + 6, y + 1)), 1.4, 0x87b7b1);
        line(angle.apply(v(x + 6, y + 1)), angle.apply(v(x + 11, y - 1)), 1.4, 0x87b7b1);
    }
}

pub fn chartPoint(p: region.Point) V {
    return v(f(p[0]), f(p[1]));
}

pub fn regionalLand(upper_left: V, lower_right: V, angle: Orientation) void {
    for (region.islands) |isle| {
        const min = chartPoint(isle.bounds[0]);
        const max = chartPoint(isle.bounds[1]);
        if (max.x < upper_left.x or max.y < upper_left.y or min.x > lower_right.x or min.y > lower_right.y) continue;
        for (isle.triangles) |t| {
            tri(angle.apply(chartPoint(isle.coast[t[0]])), angle.apply(chartPoint(isle.coast[t[1]])), angle.apply(chartPoint(isle.coast[t[2]])), 0x97b18b);
        }
        var prev = angle.apply(chartPoint(isle.coast[isle.coast.len - 1]));
        for (isle.coast) |point| {
            const next = angle.apply(chartPoint(point));
            line(prev, next, 5, 0xc9c6a0);
            prev = next;
        }
    }
}

fn toV(p: s.ferry.Point) V {
    return v(p[0], p[1]);
}

fn dockOffset(chart: usize) V {
    return toV(s.ferry.dockOffset(chart));
}

fn berth(chart: usize) V {
    return toV(s.ferry.berth(chart));
}

const BridgeDeck = struct {
    start: V,
    end: V,
    across: V,

    fn init(crossing: usize, angle: Orientation) BridgeDeck {
        const plan = s.crossings[crossing];
        const start = angle.apply(worldPoint(plan.charts[0], tile(plan.heads[0])));
        const end = angle.apply(worldPoint(plan.charts[1], tile(plan.heads[1])));
        return .{ .start = start, .end = end, .across = r.math.vector2Normalize(v(start.y - end.y, end.x - start.x)) };
    }

    fn point(deck: BridgeDeck, progress: f32, offset: f32, height: f32) V {
        const base = r.math.vector2Lerp(deck.start, deck.end, progress);
        return v(base.x + deck.across.x * offset, base.y + deck.across.y * offset - height);
    }
};

fn paintBridge(paint: *OccluderPaint, deck: BridgeDeck, spans: usize, built: bool) void {
    if (!built) {
        const marks = spans * 4;
        for (0..marks) |i| {
            paint.line(deck.point(f(i) / f(marks), 0, 3), deck.point((f(i) + 0.6) / f(marks), 0, 3), 2, 0xe1d5a5);
        }
        return;
    }
    paint.line(deck.point(0, 0, -15), deck.point(1, 0, -15), 17, 0x487f80);
    for (1..spans) |i| {
        const p = deck.point(f(i) / f(spans), 0, 0);
        paint.diamond(p.x, p.y + 18, 12, 6, 0x386c73);
        paint.quad(v(p.x - 7, p.y - 6), v(p.x + 7, p.y - 6), v(p.x + 9, p.y + 14), v(p.x - 9, p.y + 14), 0x8a9690);
        paint.line(v(p.x - 9, p.y + 13), v(p.x + 9, p.y + 13), 3, 0xaeb6a5);
    }
    paint.line(deck.point(0, 0, 0), deck.point(1, 0, 0), 16, 0x644d3b);
    paint.line(deck.point(0, 0, 3), deck.point(1, 0, 3), 12, 0xc59b68);
    const planks = spans * 9;
    for (0..planks + 1) |i| {
        const t = f(i) / f(planks);
        paint.line(deck.point(t, -5, 3), deck.point(t, 5, 3), 1, 0x9b7955);
    }
    const far_side: f32 = if (deck.across.y < 0) 5.5 else -5.5;
    paint.line(deck.point(0, far_side, 3), deck.point(1, far_side, 3), 2, 0xefd8a0);
    paint.line(deck.point(0, -far_side, 3), deck.point(1, -far_side, 3), 2, 0x876448);
}

pub fn drawBridge(crossing: usize, built: bool, angle: Orientation, hover: ?V) u8 {
    const deck = BridgeDeck.init(crossing, angle);
    const spans = s.crossings[crossing].spans;
    var probe = OccluderPaint{ .tile_center = hover };
    if (hover != null) paintBridge(&probe, deck, spans, built);
    var paint = OccluderPaint{ .alpha = probe.opacity() };
    paintBridge(&paint, deck, spans, built);
    return paint.alpha;
}

/// Residents stroll from each connected shore out onto the bridge and back.
pub fn bridgeTraffic(g: *const s.Game, crossing: usize, t: f32, angle: Orientation, alpha: u8) void {
    if (g.footpathProblem(crossing) != null) return;
    const deck = BridgeDeck.init(crossing, angle);
    var paint = OccluderPaint{ .alpha = alpha };
    for (s.crossings[crossing].charts, 0..) |chart, side| {
        if (g.residents(chart) == 0) continue;
        const reach = 0.46 - 0.46 * @cos(t * 0.22 + f(side) * 2.3 + f(crossing));
        const progress = if (side == 0) reach else 1 - reach;
        paint.settler(deck.point(progress, if (side == 0) -2 else 2, 3), if (side == 0) 0x855a46 else 0x456870);
    }
}

/// Settlers walking a bridge, keeping to the rail for their direction.
pub fn bridgeWalkers(g: *const s.Game, t: f32, angle: Orientation, opacity: [s.crossings.len]u8) void {
    for (g.walkers.active(), 0..) |walker, i| {
        var paint = OccluderPaint{ .alpha = opacity[walker.crossing] };
        const deck = BridgeDeck.init(walker.crossing, angle);
        const outbound = walker.destination == s.crossings[walker.crossing].charts[1];
        const stride = @abs(@sin(t * 9 + f(i) * 1.7)) * 1.2;
        paint.settler(deck.point(walker.position(), if (outbound) -2 else 2, 3 + stride), if (outbound) 0x855a46 else 0x456870);
    }
}

fn seaRoute(start: V, depart: V, approach: V, end: V, progress: f32) V {
    return toV(s.ferry.seaRoute(.{ start.x, start.y }, .{ depart.x, depart.y }, .{ approach.x, approach.y }, .{ end.x, end.y }, progress));
}

// The harbor boat rounds the southern shores before approaching Bali.
pub fn shipPosition(progress: f32) V {
    return toV(s.ferry.straitCourse(progress));
}

/// The ferry's course between two harbors in range of each other, as the
/// core plans it, so the boat never sails over land the lanes avoid.
pub fn ferryPosition(from: usize, to: usize, progress: f32) V {
    return toV(s.ferry.coursePosition(from, to, progress));
}

pub fn ship(g: *const s.Game, time: f32, angle: Orientation, hover: ?V) void {
    const ferry = g.ferry;
    const t = ferry.progress();
    const pos = angle.apply(ferryPosition(ferry.origin, ferry.destination, t));
    const ahead = angle.apply(ferryPosition(ferry.origin, ferry.destination, @min(1, t + 0.001)));
    const behind = angle.apply(ferryPosition(ferry.origin, ferry.destination, @max(0, t - 0.001)));
    const heading: f32 = if (ahead.x < behind.x) -1 else 1;
    var probe = OccluderPaint{ .tile_center = hover };
    if (hover != null) paintFerry(&probe, g, time, t, pos, heading);
    var paint = OccluderPaint{ .alpha = probe.opacity() };
    paintFerry(&paint, g, time, t, pos, heading);
}

fn paintFerry(paint: *OccluderPaint, g: *const s.Game, time: f32, t: f32, pos: V, heading: f32) void {
    if (t > 0 and t < 1) {
        const length = (46 + 3 * @sin(time * 2)) * heading;
        paint.line(v(pos.x - 15 * heading, pos.y + 1), v(pos.x - length, pos.y - 3), 2, 0xb6d4c4);
        paint.line(v(pos.x - 11 * heading, pos.y + 5), v(pos.x - length + 6 * heading, pos.y + 9), 2, 0x9ec7bb);
    }
    boat(paint, pos, time, heading, g.ferry.passengers, g.mooredChart() == null);
    if (!g.ferry.cargo.empty()) {
        const x = pos.x - 22 * heading;
        const y = pos.y + @sin(time * 1.6) * 1.3;
        paint.rect(x - 3, y - 13, 8, 6, 0xc7a173);
        paint.line(v(x - 2, y - 11), v(x + 4, y - 11), 1, 0x72543d);
    }
}

fn waypointPosition(points: []const [2]f32, fraction: f32) V {
    var total: f32 = 0;
    for (points[0 .. points.len - 1], points[1..]) |p, q| total += r.math.vector2Distance(v(p[0], p[1]), v(q[0], q[1]));
    var remaining = total * fraction;
    for (points[0 .. points.len - 1], points[1..]) |p, q| {
        const start = v(p[0], p[1]);
        const end = v(q[0], q[1]);
        const distance = r.math.vector2Distance(start, end);
        if (remaining < distance) return r.math.vector2Lerp(start, end, remaining / distance);
        remaining -= distance;
    }
    const end = points[points.len - 1];
    return v(end[0], end[1]);
}

pub fn expeditionPosition(index: usize, fraction: f32) V {
    const harbor = berth(0);
    const start = v(harbor.x - 50, harbor.y + 75);
    const chart = s.ocean.routes[index].chart;
    if (chart >= s.geography.first_additional) return waypointPosition(s.geography.sites.all[chart - s.geography.first_additional].waypoints, fraction);
    switch (chart) {
        2 => {
            const end = berth(2);
            return seaRoute(start, v(start.x + 220, start.y + 170), v(end.x + 104, end.y + 145), end, fraction);
        },
        s.geography.borneo => {
            const approach = v(1365, 486);
            const strait = v(1367, 195);
            if (fraction < 0.55) return seaRoute(start, v(895, 655), v(1325, 685), approach, fraction / 0.55);
            if (fraction < 0.73) return seaRoute(approach, v(1385, 390), v(1352, 284), strait, (fraction - 0.55) / 0.18);
            return seaRoute(strait, v(1399, 5), v(1237, -93), berth(s.geography.borneo), (fraction - 0.73) / 0.27);
        },
        s.geography.sumatra => {
            const java_southwest = v(-240, 481);
            const sumatra_approach = v(-1175, -560);
            if (fraction < 0.33) return seaRoute(start, v(344, 633), v(30, 619), java_southwest, fraction / 0.33);
            if (fraction < 0.93) return seaRoute(java_southwest, v(-610, 292), v(-1290, -355), sumatra_approach, (fraction - 0.33) / 0.6);
            return seaRoute(sumatra_approach, v(-1139, -626), v(-1100, -623), berth(s.geography.sumatra), (fraction - 0.93) / 0.07);
        },
        else => {},
    }
    // Reach Palawan through the straits east of Lombok and Borneo.
    const alas_strait_approach = v(1740, 478);
    const makassar_strait_exit = v(1600, -520);
    if (fraction < 0.4)
        return seaRoute(start, v(1040, 655), v(1734, 750), alas_strait_approach, fraction / 0.4);
    if (fraction < 0.73)
        return seaRoute(alas_strait_approach, v(1746, 206), v(1514, -280), makassar_strait_exit, (fraction - 0.4) / 0.33);
    return seaRoute(makassar_strait_exit, v(1686, -760), v(2050, -1120), berth(s.geography.palawan), (fraction - 0.73) / 0.27);
}

fn javaCourse(chart: usize, fraction: f32) V {
    if (s.ocean.routeTo(chart)) |index| return expeditionPosition(index, fraction);
    const java = expeditionPosition(0, 0);
    if (chart == 0) return java;
    const position = shipPosition(fraction);
    const blend = @max(0, 1 - 8 * fraction);
    const ferry_start = berth(0);
    return v(position.x + (java.x - ferry_start.x) * blend, position.y + (java.y - ferry_start.y) * blend);
}

fn vesselCourse(origin_chart: usize, chart: usize, fraction: f32) V {
    if (origin_chart == 0) return javaCourse(chart, fraction);
    if (chart == 0) return javaCourse(origin_chart, 1 - fraction);
    const course = s.ocean.directCourse(origin_chart, chart).?;
    const progress = if (origin_chart < chart) fraction else 1 - fraction;
    return toV(s.ferry.detourCourse(s.ferry.berth(course.from), course.waypoints, s.ferry.berth(course.to), progress));
}

pub fn explorationShip(g: *const s.Game, id: usize, time: f32, angle: Orientation, hover: ?V) void {
    const voyage = g.fleet.vessels[id];
    const fraction = voyage.progress();
    const course = if (voyage.phase == .docked)
        if (voyage.chart == 0) javaCourse(0, 0) else berth(voyage.chart)
    else
        vesselCourse(voyage.origin, voyage.chart, fraction);
    const earlier = if (voyage.phase == .docked) course else vesselCourse(voyage.origin, voyage.chart, @max(0, fraction - 0.001));
    const heading: f32 = if ((angle.apply(course).x < angle.apply(earlier).x) != (voyage.phase == .homebound)) -1 else 1;
    const chart = voyage.berthChart();
    var slot: usize = @intFromBool(chart != 0 and g.ferryBerthChart() == chart);
    for (g.vessels()[0..id]) |other| slot += @intFromBool(other.berthChart() == chart);
    const near_berth: f32 = switch (voyage.phase) {
        .docked => 1,
        .outbound => fraction,
        .homebound => 1 - fraction,
    };
    const seaward = if (chart == 0) v(0.65, 0.76) else r.math.vector2Normalize(dockOffset(chart));
    const spacing = f(slot) * 67 * @max(0, 1 - 10 * (1 - near_berth));
    const p = angle.apply(v(course.x + seaward.x * spacing, course.y + seaward.y * spacing));
    var probe = OccluderPaint{ .tile_center = hover };
    if (hover != null) paintExpedition(&probe, voyage, fraction, time, p, heading);
    var paint = OccluderPaint{ .alpha = probe.opacity() };
    paintExpedition(&paint, voyage, fraction, time, p, heading);
}

fn paintExpedition(paint: *OccluderPaint, voyage: s.Vessel, fraction: f32, time: f32, p: V, heading: f32) void {
    const scale: f32 = if (voyage.ship == .barque) 1.32 else 1.0;
    const x = p.x;
    const y = p.y + @sin(time * 1.35) * 1.6;
    if (fraction > 0 and fraction < 1) {
        paint.line(v(x - 40 * heading, y + 2), v(x - 83 * heading, y + 9), 2.4, 0xb5d4c3);
        paint.line(v(x - 37 * heading, y + 7), v(x - 72 * heading, y + 15), 1.6, 0x95c0ba);
    }
    paint.diamond(x, y + 9, 49 * scale, 9, 0x3a777a);
    paint.quad(v(x - 44 * scale * heading, y - 10), v(x + 46 * scale * heading, y - 13), v(x + 27 * scale * heading, y + 8), v(x - 31 * scale * heading, y + 9), 0x433f35);
    paint.line(v(x - 43 * scale * heading, y - 10), v(x + 44 * scale * heading, y - 13), 4, 0xb78a58);
    for ([_]f32{ -23, 10, 32 }, 0..) |mast, i| {
        if (i == 2 and voyage.ship == .brig) break;
        const mx = x + mast * scale * heading;
        const top = y - (if (i == 1) @as(f32, 73) else 57) * scale;
        paint.line(v(mx, y - 13), v(mx, top), 2.4, 0x534a3b);
        const sail = if (i == 0) @as(u32, 0xd4c09b) else 0xf4e2b8;
        paint.quad(v(mx - 13 * scale * heading, top + 8), v(mx + 11 * scale * heading, top + 10), v(mx + 14 * scale * heading, y - 22), v(mx - 16 * scale * heading, y - 27), sail);
        paint.line(v(mx - 14 * scale * heading, top + 8), v(mx + 12 * scale * heading, top + 10), 2, 0xa48c64);
        if (i == 1) paint.tri(v(mx, top), v(mx + 17 * heading, top + 4), v(mx, top + 9), 0xb95036);
    }
    if (voyage.chart != 0) paint.settler(v(x + 34 * heading, y - 11), 0x456870);
    if (!voyage.cargo.empty()) paint.rect(x - 39 * heading - 4, y - 13, 9, 7, 0xc7a173);
    for (0..voyage.passengers) |i| {
        paint.settler(v(x + (-29 + f(i) * 10) * heading, y - 9), if (i % 2 == 0) 0x855a46 else 0x456870);
    }
}

fn settler(pos: V, color: u32) void {
    var paint = OccluderPaint{};
    paint.settler(pos, color);
}

fn roadTiles(tiles: []const s.Tile, chart: usize, area: TileRange, angle: Orientation) void {
    const grid = s.geography.grids[chart];
    for (area.y0..area.y1) |y| for (area.x0..area.x1) |x| {
        const cell = s.Cell{ .x = x, .y = y };
        if (tiles[grid.index(cell)].kind != .road) continue;
        const center = angle.apply(tile(cell));
        diamond(center.x, center.y, 7, 4, 0xc2c6b9);
        for (roads.directions) |direction| {
            const next = roads.neighbor(cell, direction, grid) orelse continue;
            const adjacent = tiles[grid.index(next)].kind;
            if (adjacent == .empty and s.site(next, chart) != .fruit) continue;
            const end = angle.apply(tile(next));
            const reach: f32 = if (adjacent == .road or s.isPlaza(adjacent)) 0.51 else 1;
            line(center, r.math.vector2Lerp(center, end, reach), 5, 0xc2c6b9);
        }
    };
}

fn walkers(g: *const s.Game, chart: usize, time: f32, angle: Orientation) void {
    const residents = @min(8, g.residents(chart));
    if (g.workforce(chart) == 0) return;
    const walk = g.footWalk(chart);
    if (walk.len < 2) return;
    const length = f(walk.len - 1);
    for (0..residents) |i| {
        const progress = @mod(time * 0.65 + f(i) * length / f(residents), length);
        const step: usize = @intFromFloat(progress);
        const start = angle.apply(tile(walk.stop(step)));
        const end = angle.apply(tile(walk.stop(step + 1)));
        const fraction = progress - f(step);
        settler(r.math.vector2Lerp(start, end, fraction), if (i % 2 == 0) 0x855a46 else 0x456870);
    }
}

fn terrain(chart: usize, tiles: []const s.Tile, area: TileRange, detail: bool, angle: Orientation) void {
    const grid = s.geography.grids[chart];
    for (area.y0..area.y1) |y| for (area.x0..area.x1) |x| {
        const p = s.Cell{ .x = x, .y = y };
        const z = s.depth(p, chart);
        const limits = [_]f32{ 0, -0.07, -0.22, -0.43, -0.66, -0.92 };
        const tints = [_]u32{ 0xc5a775, 0xc1d7b8, 0x9ac7b6, 0x83b8af, 0x72aaaa, 0x649fa0 };
        for (limits, tints) |limit, tint| {
            if (z < limit) continue;
            const pos = angle.apply(tile(p));
            diamond(pos.x, pos.y + 8, 31.2, 16.2, tint);
            break;
        }
    };
    for (area.y0..area.y1) |y| for (area.x0..area.x1) |x| {
        const p = s.Cell{ .x = x, .y = y };
        const z = s.depth(p, chart);
        if (z < 0) continue;
        const pos = angle.apply(tile(p));
        const n = s.hash(x, y, chart);
        const grass = [_]u32{ 0xa6b780, 0xa8b982, 0xb0be88, 0xa5b67d };
        diamond(pos.x, pos.y, 31.2, 16.2, if (z < 0.13) 0xe0cc99 else grass[n % 4]);
        if (detail and z > 0.14 and tiles[grid.index(p)].kind == .empty) {
            for (0..3) |i| {
                const gx = pos.x + f(s.hash(x + i, y, chart) % 23) - 11;
                const gy = pos.y + f(s.hash(y + i, x, chart) % 9) - 4;
                line(v(gx, gy), v(gx - 1, gy - 2), 1, 0x889e69);
            }
        }
    };
}

fn squareCenter(anchor: s.Cell, angle: Orientation) V {
    const top = tile(anchor);
    return angle.apply(v(top.x, top.y + s.tile_height));
}

fn townSquares(g: *const s.Game, chart: usize, area: TileRange, hover: ?s.Cell, tool: s.Kind, angle: Orientation) void {
    for (area.y0..area.y1) |y| for (area.x0..area.x1) |x| {
        const anchor = s.Cell{ .x = x, .y = y };
        if (g.tileAt(chart, anchor) != .plaza) continue;
        const pos = squareCenter(anchor, angle);
        townSquare(pos.x, pos.y + 8, 2);
    };
    const cell = hover orelse return;
    const placing = tool == .plaza;
    const anchor = if (placing) cell else g.plazaAnchor(chart, cell) orelse return;
    const valid = !placing or g.plazaSite(chart, anchor);
    const pos = squareCenter(anchor, angle);
    if (placing and valid) townSquare(pos.x, pos.y + 8, 2);
    tileOutline(pos, 2 * s.tile_width, 2 * s.tile_height, 2, if (valid) 0xf2cf7f else 0xbf6753);
}

pub fn island(g: *const s.Game, chart: usize, area: TileRange, hover: ?s.Cell, t: f32, tool: s.Kind, detail: bool, angle: Orientation) void {
    terrain(chart, g.tilesOn(chart), area, detail, angle);
    townSquares(g, chart, area, hover, tool, angle);
    roadTiles(g.tilesOn(chart), chart, area, angle);
    const placing_lighthouse = tool == .light and !g.hasLighthouse(chart);

    // Each diagonal has the same projected depth. Draw the far rows first.
    const width = area.x1 - area.x0;
    const height = area.y1 - area.y0;
    const reverse_x = angle == .south or angle == .west;
    const reverse_y = angle == .east or angle == .south;
    for (0..width + height - 1) |row| for (row -| (height - 1)..@min(row + 1, width)) |column| {
        const offset_y = row - column;
        const x = if (reverse_x) area.x1 - 1 - column else area.x0 + column;
        const y = if (reverse_y) area.y1 - 1 - offset_y else area.y0 + offset_y;
        const p = s.Cell{ .x = x, .y = y };
        const z = s.depth(p, chart);
        if (z < 0) continue;
        const pos = angle.apply(tile(p));
        const n = s.hash(x, y, chart);
        const k = g.tileAt(chart, p);
        const hot = if (hover) |h| h.x == x and h.y == y else false;
        const site = s.site(p, chart);
        const resource_target = k == .empty and ((tool == .quarry and site == .outcrop) or (tool == .lodge and site == .deer));
        const upgrade_target = tool == .apartment and k == .cottage;
        const lighthouse_target = placing_lighthouse and k == .empty and site != .fruit and s.lighthouseSite(p, chart);
        const hover_target = hot and tool != .plaza and tool != .light and k != .road and !s.isPlaza(k);
        if (hover_target or resource_target or upgrade_target or lighthouse_target) {
            diamond(pos.x, pos.y, 31, 16, 0xf2cf7f);
            diamond(pos.x, pos.y, 27, 13, 0xb4bd8b);
        }
        if (k == .empty and site == .fruit) {
            fruitTree(pos.x, pos.y);
        } else if (k == .empty and site == .outcrop) {
            rocks(pos.x, pos.y, 1);
        } else if (k == .empty and site == .deer) {
            const drift = @sin(t * 0.42 + f(n % 17)) * 3;
            deer(pos.x - 9 + drift, pos.y - 3, 1, true);
            deer(pos.x + 9 - drift, pos.y + 6, 0.83, false);
        } else if (detail and k == .empty and s.forest(p, chart)) {
            tree(pos.x - 8, pos.y - 2, 25 + f(n % 13), false);
            tree(pos.x + 6, pos.y + 1, 18 + f(n % 14), n % 2 == 0);
        } else if (k != .empty and k != .road and !s.isPlaza(k)) {
            const stock = if (g.harvestStatus(chart, p)) |harvest| harvest.stock else s.harvest_capacity;
            buildingWithStock(if (hot and upgrade_target) .apartment else k, pos.x, pos.y + 5, 1, stock);
        }
        if (hot and k == .empty and tool != .empty and tool != .apartment and tool != .plaza and site != .fruit and
            (tool != .light or lighthouse_target))
            building(tool, pos.x, pos.y + 5, 0.9);
    };

    if (!g.islandOpen(chart)) return;
    if (detail) walkers(g, chart, t, angle);
    const port = angle.apply(tile(s.quay(chart)));
    if (chart != 0 and g.residents(chart) > 0 and g.housing(chart) == 0) {
        const x = port.x - 16;
        const y = port.y + 9;
        diamond(x, y + 1, 11, 4, 0x9e8b61);
        tri(v(x - 11, y), v(x, y - 14), v(x + 10, y), 0xead8aa);
        tri(v(x - 4, y), v(x, y - 9), v(x + 4, y), 0x806648);
    }
    const offset = dockOffset(chart);
    const pier = angle.apply(v(offset.x * 0.636, offset.y * 0.588));
    const side = r.math.vector2Normalize(v(-pier.y, pier.x));
    const planks: usize = @intFromFloat(@ceil(r.math.vector2Length(pier) / 3.4));
    for (0..planks + 1) |i| {
        const progress = f(i) / f(planks);
        const pos = v(port.x + progress * pier.x, port.y + 4 + progress * pier.y);
        line(v(pos.x - side.x * 6, pos.y - side.y * 6), v(pos.x + side.x * 6, pos.y + side.y * 6), 3.6, if (i % 2 == 0) 0x9f8055 else 0xb19363);
    }
}

test "ferry hover fades a covered tile but ignores empty space beside the sail" {
    var covered = OccluderPaint{ .tile_center = v(-12, -29) };
    boat(&covered, v(0, 0), 0, 1, 0, false);
    try std.testing.expect(covered.opacity() < 255);

    var beside_sail = OccluderPaint{ .tile_center = v(-25, -48) };
    boat(&beside_sail, v(0, 0), 0, 1, 0, false);
    try std.testing.expectEqual(@as(u8, 255), beside_sail.opacity());
}

test "expedition ship hover includes a raised sail" {
    var probe = OccluderPaint{ .tile_center = v(-23, -42) };
    paintExpedition(&probe, .{ .ship = .brig }, 0, 0, v(0, 0), 1);
    try std.testing.expect(probe.opacity() < 255);
}

test "bridge hover follows the projected deck through every camera angle" {
    for ([_]Orientation{ .north, .east, .south, .west }) |angle| {
        const deck = BridgeDeck.init(s.strait, angle);
        var on_deck = OccluderPaint{ .tile_center = deck.point(0, 0, 0) };
        paintBridge(&on_deck, deck, s.crossings[s.strait].spans, true);
        try std.testing.expect(on_deck.opacity() < 255);

        var off_deck = OccluderPaint{ .tile_center = deck.point(0.5, 50, 0) };
        paintBridge(&off_deck, deck, s.crossings[s.strait].spans, true);
        try std.testing.expectEqual(@as(u8, 255), off_deck.opacity());
    }
}
