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
    if ((b.x - a.x) * (d.y - a.y) - (b.y - a.y) * (d.x - a.x) > 0) r.drawTriangle(a, d, b, c(col)) else r.drawTriangle(a, b, d, c(col));
}
fn quad(a: V, b: V, d: V, e: V, col: u32) void {
    tri(a, b, d, col);
    tri(a, d, e, col);
}
pub fn diamond(x: f32, y: f32, w: f32, h: f32, col: u32) void {
    quad(v(x - w, y), v(x, y - h), v(x + w, y), v(x, y + h), col);
}
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
    const upper = gridPoint(v(top.x - 80, top.y - 45));
    const lower = gridPoint(v(bottom.x + 80, bottom.y + 90));
    const left = gridPoint(v(bottom.x + 80, top.y - 45));
    const right = gridPoint(v(top.x - 80, bottom.y + 90));
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
        .empty => {},
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
fn boat(pos: V, time: f32, heading: f32, passengers: u16, underway: bool) void {
    const x = pos.x;
    const y = pos.y + @sin(time * 1.6) * 1.3;
    // Reflect vertices before tri() orders them for raylib's backface culling.
    diamond(x, y + 2, 30, 6, 0x3a777a);
    quad(v(x - 25 * heading, y - 6), v(x + 28 * heading, y - 10), v(x + 15 * heading, y + 2), v(x - 12 * heading, y + 4), 0x78523d);
    line(v(x - 24 * heading, y - 6), v(x + 26 * heading, y - 10), 3, 0xc29864);
    line(v(x, y - 8), v(x, y - 54), 2, 0x594f3f);
    tri(v(x - 3 * heading, y - 49), v(x - 21 * heading, y - 13), v(x - 3 * heading, y - 16), 0xffe4af);
    tri(v(x + 2 * heading, y - 45), v(x + 20 * heading, y - 16), v(x + 2 * heading, y - 13), 0xe7c58e);
    if (underway) settler(v(x + 18 * heading, y - 8), 0x31565a);
    for (0..@min(s.ferry_capacity, passengers)) |i| {
        settler(v(x + (-14 + f(i) * 9) * heading, y - 6), if (i % 2 == 0) 0x456870 else 0x855a46);
    }
    tri(v(x, y - 55), v(x + 12 * heading, y - 52), v(x, y - 50), 0xc26b4c);
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

pub fn sea(t: f32, upper_left: V, lower_right: V) void {
    rect(upper_left.x, upper_left.y, lower_right.x - upper_left.x, lower_right.y - upper_left.y, 0x549296);
    for (0..@as(usize, @intFromFloat(@ceil(sea_width / 48)))) |i| line(v(sea_left + f(i) * 48, sea_top), v(sea_left + f(i) * 48, sea_top + sea_height), 0.8, 0x609b9c);
    for (0..@as(usize, @intFromFloat(@ceil(sea_height / 48)))) |i| line(v(sea_left, sea_top + f(i) * 48), v(sea_left + sea_width, sea_top + f(i) * 48), 0.8, 0x609b9c);
    for (0..2440) |i| {
        const x = f(s.hash(i, 1, 0) % @as(usize, @intFromFloat(sea_width))) + sea_left + @sin(t * 0.6 + f(i)) * 2;
        if (x < upper_left.x - 12 or x > lower_right.x) continue;
        const y = f(s.hash(i, 3, 0) % @as(usize, @intFromFloat(sea_height))) + sea_top;
        if (y < upper_left.y - 2 or y > lower_right.y + 2) continue;
        line(v(x, y), v(x + 6, y + 1), 1.4, 0x87b7b1);
        line(v(x + 6, y + 1), v(x + 11, y - 1), 1.4, 0x87b7b1);
    }
}

pub fn chartPoint(p: region.Point) V {
    return v(f(p[0]), f(p[1]));
}

pub fn regionalLand(upper_left: V, lower_right: V) void {
    for (region.islands) |isle| {
        const min = chartPoint(isle.bounds[0]);
        const max = chartPoint(isle.bounds[1]);
        if (max.x < upper_left.x or max.y < upper_left.y or min.x > lower_right.x or min.y > lower_right.y) continue;
        for (isle.triangles) |t| {
            tri(chartPoint(isle.coast[t[0]]), chartPoint(isle.coast[t[1]]), chartPoint(isle.coast[t[2]]), 0x97b18b);
        }
        var prev = chartPoint(isle.coast[isle.coast.len - 1]);
        for (isle.coast) |point| {
            const next = chartPoint(point);
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

fn bridgePoint(crossing: usize, progress: f32, y_offset: f32) V {
    const plan = s.crossings[crossing];
    const start = worldPoint(plan.charts[0], tile(plan.heads[0]));
    const end = worldPoint(plan.charts[1], tile(plan.heads[1]));
    return v(std.math.lerp(start.x, end.x, progress), std.math.lerp(start.y, end.y, progress) + y_offset);
}

pub fn drawBridge(crossing: usize, built: bool) void {
    const spans = s.crossings[crossing].spans;
    if (!built) {
        const marks = spans * 4;
        for (0..marks) |i| {
            line(bridgePoint(crossing, f(i) / f(marks), -3), bridgePoint(crossing, (f(i) + 0.6) / f(marks), -3), 2, 0xe1d5a5);
        }
        return;
    }
    line(bridgePoint(crossing, 0, 15), bridgePoint(crossing, 1, 15), 17, 0x487f80);
    for (1..spans) |i| {
        const p = bridgePoint(crossing, f(i) / f(spans), 0);
        diamond(p.x, p.y + 18, 12, 6, 0x386c73);
        quad(v(p.x - 7, p.y - 6), v(p.x + 7, p.y - 6), v(p.x + 9, p.y + 14), v(p.x - 9, p.y + 14), 0x8a9690);
        line(v(p.x - 9, p.y + 13), v(p.x + 9, p.y + 13), 3, 0xaeb6a5);
    }
    line(bridgePoint(crossing, 0, 0), bridgePoint(crossing, 1, 0), 16, 0x644d3b);
    line(bridgePoint(crossing, 0, -3), bridgePoint(crossing, 1, -3), 12, 0xc59b68);
    const planks = spans * 9;
    for (0..planks + 1) |i| {
        const t = f(i) / f(planks);
        line(bridgePoint(crossing, t, -8), bridgePoint(crossing, t, 2), 1, 0x9b7955);
    }
    line(bridgePoint(crossing, 0, -8), bridgePoint(crossing, 1, -8), 2, 0xefd8a0);
    line(bridgePoint(crossing, 0, 3), bridgePoint(crossing, 1, 3), 2, 0x876448);
}

pub fn bridgeTraffic(g: *const s.Game, crossing: usize, t: f32) void {
    for (s.crossings[crossing].charts, 0..) |chart, side| {
        if (g.residents(chart) == 0) continue;
        const progress = 0.5 - 0.46 * @cos(t * 0.22 + f(side) * 2.3 + f(crossing));
        settler(bridgePoint(crossing, progress, if (side == 0) -4 else 0), if (side == 0) 0x855a46 else 0x456870);
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

pub fn ship(g: *const s.Game, time: f32) void {
    const ferry = g.ferry;
    const t = ferry.progress();
    const pos = ferryPosition(ferry.origin, ferry.destination, t);
    const ahead = ferryPosition(ferry.origin, ferry.destination, @min(1, t + 0.001));
    const behind = ferryPosition(ferry.origin, ferry.destination, @max(0, t - 0.001));
    const heading: f32 = if (ahead.x < behind.x) -1 else 1;
    if (t > 0 and t < 1) {
        const length = (46 + 3 * @sin(time * 2)) * heading;
        line(v(pos.x - 15 * heading, pos.y + 1), v(pos.x - length, pos.y - 3), 2, 0xb6d4c4);
        line(v(pos.x - 11 * heading, pos.y + 5), v(pos.x - length + 6 * heading, pos.y + 9), 2, 0x9ec7bb);
    }
    boat(pos, time, heading, g.ferry.passengers, g.mooredChart() == null);
    if (!g.ferry.cargo.empty()) {
        const x = pos.x - 22 * heading;
        const y = pos.y + @sin(time * 1.6) * 1.3;
        rect(x - 3, y - 13, 8, 6, 0xc7a173);
        line(v(x - 2, y - 11), v(x + 4, y - 11), 1, 0x72543d);
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

fn vesselCourse(chart: usize, fraction: f32) V {
    if (s.ocean.routeTo(chart)) |index| return expeditionPosition(index, fraction);
    const java = expeditionPosition(0, 0);
    if (chart == 0) return java;
    const position = shipPosition(fraction);
    const blend = @max(0, 1 - 8 * fraction);
    const ferry_start = berth(0);
    return v(position.x + (java.x - ferry_start.x) * blend, position.y + (java.y - ferry_start.y) * blend);
}

pub fn explorationShip(g: *const s.Game, id: usize, time: f32) void {
    const voyage = g.fleet.vessels[id];
    const fraction = voyage.progress();
    var p = vesselCourse(voyage.chart, fraction);
    const earlier = vesselCourse(voyage.chart, @max(0, fraction - 0.001));
    const heading: f32 = if ((p.x < earlier.x) != (voyage.phase == .homebound)) -1 else 1;
    const chart = voyage.berthChart();
    var slot: usize = @intFromBool(chart != 0 and g.ferryBerthChart() == chart);
    for (g.vessels()[0..id]) |other| slot += @intFromBool(other.berthChart() == chart);
    const near_berth = if (chart == 0) 1 - fraction else fraction;
    const seaward = if (chart == 0) v(0.65, 0.76) else r.math.vector2Normalize(dockOffset(chart));
    const spacing = f(slot) * 67 * @max(0, 1 - 10 * (1 - near_berth));
    p = v(p.x + seaward.x * spacing, p.y + seaward.y * spacing);
    const scale: f32 = if (voyage.ship == .barque) 1.32 else 1.0;
    const x = p.x;
    const y = p.y + @sin(time * 1.35) * 1.6;
    if (fraction > 0 and fraction < 1) {
        line(v(x - 40 * heading, y + 2), v(x - 83 * heading, y + 9), 2.4, 0xb5d4c3);
        line(v(x - 37 * heading, y + 7), v(x - 72 * heading, y + 15), 1.6, 0x95c0ba);
    }
    diamond(x, y + 9, 49 * scale, 9, 0x3a777a);
    quad(v(x - 44 * scale * heading, y - 10), v(x + 46 * scale * heading, y - 13), v(x + 27 * scale * heading, y + 8), v(x - 31 * scale * heading, y + 9), 0x433f35);
    line(v(x - 43 * scale * heading, y - 10), v(x + 44 * scale * heading, y - 13), 4, 0xb78a58);
    for ([_]f32{ -23, 10, 32 }, 0..) |mast, i| {
        if (i == 2 and voyage.ship == .brig) break;
        const mx = x + mast * scale * heading;
        const top = y - (if (i == 1) @as(f32, 73) else 57) * scale;
        line(v(mx, y - 13), v(mx, top), 2.4, 0x534a3b);
        const sail = if (i == 0) @as(u32, 0xd4c09b) else 0xf4e2b8;
        quad(v(mx - 13 * scale * heading, top + 8), v(mx + 11 * scale * heading, top + 10), v(mx + 14 * scale * heading, y - 22), v(mx - 16 * scale * heading, y - 27), sail);
        line(v(mx - 14 * scale * heading, top + 8), v(mx + 12 * scale * heading, top + 10), 2, 0xa48c64);
        if (i == 1) tri(v(mx, top), v(mx + 17 * heading, top + 4), v(mx, top + 9), 0xb95036);
    }
    if (voyage.chart != 0) settler(v(x + 34 * heading, y - 11), 0x456870);
    if (!voyage.cargo.empty()) rect(x - 39 * heading - 4, y - 13, 9, 7, 0xc7a173);
    for (0..voyage.passengers) |i| {
        settler(v(x + (-29 + f(i) * 10) * heading, y - 9), if (i % 2 == 0) 0x855a46 else 0x456870);
    }
}

fn settler(pos: V, color: u32) void {
    line(pos, v(pos.x, pos.y - 5), 3, color);
    r.drawCircleV(v(pos.x, pos.y - 6), 1.8, c(0xe6be88));
}

fn roadTiles(tiles: []const s.Tile, chart: usize, area: TileRange) void {
    const grid = s.geography.grids[chart];
    for (area.y0..area.y1) |y| for (area.x0..area.x1) |x| {
        const cell = s.Cell{ .x = x, .y = y };
        if (tiles[grid.index(cell)].kind != .road) continue;
        const center = tile(cell);
        diamond(center.x, center.y, 7, 4, 0xc2c6b9);
        for (roads.directions) |direction| {
            const next = roads.neighbor(cell, direction, grid) orelse continue;
            const adjacent = tiles[grid.index(next)].kind;
            if (adjacent == .empty and s.site(next, chart) != .fruit) continue;
            const end = tile(next);
            const reach: f32 = if (adjacent == .road) 0.51 else 1;
            line(center, r.math.vector2Lerp(center, end, reach), 5, 0xc2c6b9);
        }
    };
}

fn walkers(g: *const s.Game, chart: usize, time: f32) void {
    const residents = @min(8, g.residents(chart));
    if (g.workforce(chart) == 0) return;
    const walk = roads.Walk.fromPort(g.tilesOn(chart), chart);
    if (walk.len < 2) return;
    const length = f(walk.len - 1);
    for (0..residents) |i| {
        const progress = @mod(time * 0.65 + f(i) * length / f(residents), length);
        const step: usize = @intFromFloat(progress);
        const start = tile(walk.stop(step));
        const end = tile(walk.stop(step + 1));
        const fraction = progress - f(step);
        settler(r.math.vector2Lerp(start, end, fraction), if (i % 2 == 0) 0x855a46 else 0x456870);
    }
}

fn terrain(chart: usize, tiles: []const s.Tile, area: TileRange, detail: bool) void {
    const grid = s.geography.grids[chart];
    for (area.y0..area.y1) |y| for (area.x0..area.x1) |x| {
        const p = s.Cell{ .x = x, .y = y };
        const z = s.depth(p, chart);
        const limits = [_]f32{ 0, -0.07, -0.22, -0.43, -0.66, -0.92 };
        const tints = [_]u32{ 0xc5a775, 0xc1d7b8, 0x9ac7b6, 0x83b8af, 0x72aaaa, 0x649fa0 };
        for (limits, tints) |limit, tint| {
            if (z < limit) continue;
            const pos = tile(p);
            diamond(pos.x, pos.y + 8, 31.2, 16.2, tint);
            break;
        }
    };
    for (area.y0..area.y1) |y| for (area.x0..area.x1) |x| {
        const p = s.Cell{ .x = x, .y = y };
        const z = s.depth(p, chart);
        if (z < 0) continue;
        const pos = tile(p);
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

pub fn island(g: *const s.Game, chart: usize, area: TileRange, hover: ?s.Cell, t: f32, tool: s.Kind, detail: bool) void {
    terrain(chart, g.tilesOn(chart), area, detail);
    roadTiles(g.tilesOn(chart), chart, area);
    for (area.y0..area.y1) |y| for (area.x0..area.x1) |x| {
        const p = s.Cell{ .x = x, .y = y };
        const z = s.depth(p, chart);
        if (z < 0) continue;
        const pos = tile(p);
        const n = s.hash(x, y, chart);
        const k = g.tileAt(chart, p);
        const hot = if (hover) |h| h.x == x and h.y == y else false;
        const site = s.site(p, chart);
        const resource_target = k == .empty and ((tool == .quarry and site == .outcrop) or (tool == .lodge and site == .deer));
        if ((hot and k != .road) or resource_target) {
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
        } else if (k != .empty and k != .road) {
            const stock = if (g.harvestStatus(chart, p)) |harvest| harvest.stock else s.harvest_capacity;
            buildingWithStock(k, pos.x, pos.y + 5, 1, stock);
        }
        if (hot and k == .empty and tool != .empty and site != .fruit) building(tool, pos.x, pos.y + 5, 0.9);
    };

    if (!g.islandOpen(chart)) return;
    if (detail) walkers(g, chart, t);
    const port = tile(s.quay(chart));
    if (chart != 0 and g.residents(chart) > 0 and g.housing(chart) == 0) {
        const x = port.x - 16;
        const y = port.y + 9;
        diamond(x, y + 1, 11, 4, 0x9e8b61);
        tri(v(x - 11, y), v(x, y - 14), v(x + 10, y), 0xead8aa);
        tri(v(x - 4, y), v(x, y - 9), v(x + 4, y), 0x806648);
    }
    const offset = dockOffset(chart);
    const side = r.math.vector2Normalize(v(-offset.y, offset.x));
    const pier = v(offset.x * 0.636, offset.y * 0.588);
    const planks: usize = @intFromFloat(@ceil(r.math.vector2Length(pier) / 3.4));
    for (0..planks + 1) |i| {
        const progress = f(i) / f(planks);
        const pos = v(port.x + progress * pier.x, port.y + 4 + progress * pier.y);
        line(v(pos.x - side.x * 6, pos.y - side.y * 6), v(pos.x + side.x * 6, pos.y + side.y * 6), 3.6, if (i % 2 == 0) 0x9f8055 else 0xb19363);
    }
}
