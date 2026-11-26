// The harbor ferry: short crossings between nearby harbors.
//
// The ferry is moored at one harbor at a time. It can sail to, or survey,
// any harbor within its range of the one it is moored at. The range is the
// width of the Bali Strait, the crossing it was built for.
const std = @import("std");
const colony = @import("colony.zig");
const charter = @import("charter.zig");
const Game = colony.Game;
const Stores = colony.Stores;
const dailyUse = colony.dailyUse;
const day_seconds = colony.day_seconds;
const dock_capacity = colony.dock_capacity;
const food_fields = colony.food_fields;
const geography = colony.geography;
const ocean = colony.ocean;
const settlement_count = colony.settlement_count;
const region = @import("region.zig");

/// Game seconds to cross the Bali Strait between Java and Bali. Every other
/// leg is scaled from this one by the distance between the two harbors.
pub const crossing_seconds: f32 = 9;

/// The longest leg the ferry will sail.
pub const range_seconds: f32 = crossing_seconds;

pub const ferry_capacity: u16 = 4;

pub const ferry_hold: u16 = 32;

pub const camp_capacity: u16 = 4;

pub const survey_cost: u16 = 20;

fn harborDistance(a: usize, b: usize) f32 {
    const p = colony.worldTile(colony.quay(a), a);
    const q = colony.worldTile(colony.quay(b), b);
    const dx = p[0] - q[0];
    const dy = p[1] - q[1];
    return @sqrt(dx * dx + dy * dy);
}

/// Ferry legs between every pair of harbors, to the nearest half second.
const legs: [settlement_count][settlement_count]f32 = blk: {
    @setEvalBranchQuota(200_000);
    const strait = harborDistance(0, 1);
    var table: [settlement_count][settlement_count]f32 = undefined;
    for (0..settlement_count) |a| {
        for (0..settlement_count) |b| table[a][b] = @round(2 * crossing_seconds * harborDistance(a, b) / strait) / 2;
    }
    break :blk table;
};

pub fn legSeconds(from: usize, to: usize) f32 {
    return legs[from][to];
}

/// Whether the ferry can sail directly between two different harbors: the
/// leg is within range, no other island lies between the quays, and one of
/// its courses stays at sea all the way.
pub fn withinRange(from: usize, to: usize) bool {
    return from < settlement_count and to < settlement_count and lane_table[from][to] != null;
}

// ---------------------------------------------------------------- courses
//
// Every course the ferry sails is worked out here, so the lane table and the
// drawn boat agree. Points are in chart units, the same space as
// `colony.worldTile` and the regional coastlines.

pub const Point = [2]f32;

/// The hand-drawn art for the first six islands was drawn at its own scale.
/// Dock offsets are given in that art's units.
const art_scales = [_]f32{ 1, 0.54, 0.72, 1.1, 0.97, 1.05 } ++ blk: {
    var additional: [geography.sites.all.len]f32 = undefined;
    for (geography.sites.all, 0..) |site, index| additional[index] = site.scale;
    break :blk additional;
};

fn artDockOffset(chart: usize) Point {
    if (chart >= geography.first_additional) return geography.sites.all[chart - geography.first_additional].berth_offset;
    return switch (chart) {
        geography.borneo => .{ 0, 45 },
        geography.sumatra => .{ -61, 23 },
        geography.palawan => .{ 75, 37 },
        else => .{ 65, 37 },
    };
}

/// How far a harbor's berth stands out to sea from its quay, in tile units.
pub fn dockOffset(chart: usize) Point {
    const offset = artDockOffset(chart);
    const ratio = art_scales[chart] / geography.tile_scale;
    return .{ offset[0] * ratio, offset[1] * ratio };
}

/// Where a ship ties up at a harbor, in chart units.
pub fn berth(chart: usize) Point {
    const shore = colony.localTile(colony.quay(chart));
    const offset = dockOffset(chart);
    const origin = geography.grids[chart].origin;
    return .{ origin[0] + (shore[0] + offset[0]) * geography.tile_scale, origin[1] + (shore[1] + offset[1]) * geography.tile_scale };
}

/// A point along a cubic course from `start` to `end`.
pub fn seaRoute(start: Point, leave: Point, approach: Point, end: Point, progress: f32) Point {
    const t = progress;
    const u = 1 - t;
    var out: Point = undefined;
    inline for (0..2) |i| out[i] = u * u * u * start[i] + 3 * u * u * t * leave[i] + 3 * u * t * t * approach[i] + t * t * t * end[i];
    return out;
}

/// The harbor boat's crossing of the Bali Strait rounds the southern shores.
pub fn straitCourse(progress: f32) Point {
    const start = berth(0);
    const end = berth(1);
    return seaRoute(start, .{ start[0] + 190, start[1] + 210 }, .{ end[0] + 92, end[1] + 200 }, end, progress);
}

/// How far a course stands out along each harbor's approach, and how far it
/// bends sideways, as fractions of the leg's length.
pub const Bend = struct { reach: f32, side: f32 };

/// Courses tried in order for every leg but the Bali Strait.
pub const course_bends = [_]Bend{
    .{ .reach = 0.3, .side = 0 },     .{ .reach = 0.3, .side = 0.25 }, .{ .reach = 0.3, .side = -0.25 },
    .{ .reach = 0.15, .side = 0 },    .{ .reach = 0, .side = 0 },      .{ .reach = 0.3, .side = 0.5 },
    .{ .reach = 0.3, .side = -0.5 },  .{ .reach = 0.1, .side = 0.15 }, .{ .reach = 0.1, .side = -0.15 },
    .{ .reach = 0.3, .side = 0.8 },   .{ .reach = 0.3, .side = -0.8 },  .{ .reach = 0.5, .side = 0.4 },
    .{ .reach = 0.5, .side = -0.4 },  .{ .reach = 0.6, .side = 0 },
};

/// The course for a bend: out along the departure harbor's approach, in
/// along the arrival harbor's.
pub fn bentCourse(from: usize, to: usize, bend: Bend, progress: f32) Point {
    const start = berth(from);
    const end = berth(to);
    const length = @sqrt((end[0] - start[0]) * (end[0] - start[0]) + (end[1] - start[1]) * (end[1] - start[1]));
    const out = unit(dockOffset(from));
    const in = unit(dockOffset(to));
    const across = Point{ (start[1] - end[1]) / length, (end[0] - start[0]) / length };
    const reach = bend.reach * length;
    const side = bend.side * length;
    return seaRoute(
        start,
        .{ start[0] + out[0] * reach + across[0] * side, start[1] + out[1] * reach + across[1] * side },
        .{ end[0] + in[0] * reach + across[0] * side, end[1] + in[1] * reach + across[1] * side },
        end,
        progress,
    );
}

fn unit(p: Point) Point {
    const length = @sqrt(p[0] * p[0] + p[1] * p[1]);
    return .{ p[0] / length, p[1] / length };
}

/// The point the ferry has reached on a leg, `progress` from 0 to 1.
pub fn coursePosition(from: usize, to: usize, progress: f32) Point {
    if (from == to) return berth(from);
    if (from == 0 and to == 1) return straitCourse(progress);
    if (from == 1 and to == 0) return straitCourse(1 - progress);
    const lane = lane_table[from][to] orelse return bentCourse(from, to, course_bends[0], progress);
    return laneCourse(from, to, lane.bend, lane.waypoints, progress);
}

/// A baked or freshly planned lane's course. Lanes are stored from the lower
/// harbor; the reverse leg mirrors the bend or walks the waypoints backward,
/// which retraces the same curve.
pub fn laneCourse(from: usize, to: usize, bend: u8, waypoints: []const Point, progress: f32) Point {
    if ((from == 0 and to == 1) or (from == 1 and to == 0)) return if (from == 0) straitCourse(progress) else straitCourse(1 - progress);
    if (waypoints.len == 0) {
        const chosen = course_bends[bend];
        return bentCourse(from, to, if (from < to) chosen else mirror(chosen), progress);
    }
    const forward = from < to;
    return detourCourse(berth(@min(from, to)), waypoints, berth(@max(from, to)), if (forward) progress else 1 - progress);
}

/// A course through waypoints, the stops joined by straight runs and the
/// boat moving at an even pace along them.
pub fn detourCourse(start: Point, waypoints: []const Point, end: Point, progress: f32) Point {
    var stops: [max_waypoints + 2]Point = undefined;
    stops[0] = start;
    @memcpy(stops[1..][0..waypoints.len], waypoints);
    stops[waypoints.len + 1] = end;
    const route = stops[0 .. waypoints.len + 2];
    var total: f32 = 0;
    for (route[1..], route[0 .. route.len - 1]) |b, a| total += distance(a, b);
    var left = std.math.clamp(progress, 0, 1) * total;
    for (route[1..], route[0 .. route.len - 1]) |b, a| {
        const run = distance(a, b);
        if (left <= run and run > 0) {
            const t = left / run;
            return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
        }
        left -= run;
    }
    return end;
}

fn distance(a: Point, b: Point) f32 {
    return @sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
}

/// Tiles of its own island a course may cross beside a harbor's quay, and
/// the chart distance from a berth inside which the regional coastline of
/// its own island is ignored: the ferry has to reach its dock.
pub const harbor_shallows: usize = 2;
pub const berth_clearance: f32 = 24;

/// Whether a point lies on land a course between two harbors may not cross:
/// any settlement tile or regional coastline of another island, or of the
/// two harbors' own islands away from their docks.
pub fn onLand(point: Point, from: usize, to: usize) bool {
    for (0..settlement_count) |chart| {
        const cell = colony.cellAt(chart, point) orelse continue;
        if (colony.depth(cell, chart) < 0) continue;
        if (chart != from and chart != to) return true;
        const home = colony.quay(chart);
        const dx = @max(cell.x, home.x) - @min(cell.x, home.x);
        const dy = @max(cell.y, home.y) - @min(cell.y, home.y);
        if (@max(dx, dy) > harbor_shallows) return true;
    }
    for (region.islands) |isle| {
        if (point[0] < @as(f32, @floatFromInt(isle.bounds[0][0])) or point[0] > @as(f32, @floatFromInt(isle.bounds[1][0])) or
            point[1] < @as(f32, @floatFromInt(isle.bounds[0][1])) or point[1] > @as(f32, @floatFromInt(isle.bounds[1][1]))) continue;
        const chart = isle.settlement();
        if ((chart == from and near(point, berth(from))) or (chart == to and near(point, berth(to)))) continue;
        for (isle.triangles) |t| {
            if (inTriangle(point, corner(isle, t[0]), corner(isle, t[1]), corner(isle, t[2]))) return true;
        }
    }
    return false;
}

fn near(a: Point, b: Point) bool {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return dx * dx + dy * dy <= berth_clearance * berth_clearance;
}

fn corner(isle: region.Island, index: u8) Point {
    const p = isle.coast[index];
    return .{ @floatFromInt(p[0]), @floatFromInt(p[1]) };
}

fn inTriangle(p: Point, a: Point, b: Point, c: Point) bool {
    const d1 = (p[0] - b[0]) * (a[1] - b[1]) - (a[0] - b[0]) * (p[1] - b[1]);
    const d2 = (p[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (p[1] - c[1]);
    const d3 = (p[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (p[1] - a[1]);
    const negative = d1 < 0 or d2 < 0 or d3 < 0;
    const positive = d1 > 0 or d2 > 0 or d3 > 0;
    return !(negative and positive);
}

/// Samples along a course: about one per chart unit on the longest legs,
/// fine enough to catch a single tile corner.
pub const course_samples = 4000;

/// Whether a course stays at sea at every sample along it.
pub fn courseClear(from: usize, to: usize, comptime course: anytype, args: anytype) bool {
    for (0..course_samples + 1) |step| {
        const t = @as(f32, @floatFromInt(step)) / course_samples;
        if (onLand(@call(.auto, course, args ++ .{t}), from, to)) return false;
    }
    return true;
}

pub const max_waypoints = 12;

/// A lane as planned: a bend of the smooth course, or waypoints when no bend
/// stays at sea.
pub const Plan = struct {
    bend: u8 = 0,
    points: [max_waypoints]Point = undefined,
    len: usize = 0,

    pub fn waypoints(plan: *const Plan) []const Point {
        return plan.points[0..plan.len];
    }
};

/// The course between two harbors that stays at sea, if the leg is short
/// enough and has one: the first clear bend, or else a detour found by
/// searching the open water between them. Planned from the lower harbor.
/// Slow; the results are baked into ferry_lanes.zig by `zig build bake-lanes`.
pub fn computeLane(a: usize, b: usize) ?Plan {
    const from = @min(a, b);
    const to = @max(a, b);
    if (from == to or legs[from][to] > range_seconds or !straightLineClear(from, to)) return null;
    if (from == 0 and to == 1) return if (courseClear(from, to, straitCourse, .{})) Plan{} else null;
    for (course_bends, 0..) |bend, index| {
        if (courseClear(from, to, bentCourse, .{ from, to, bend })) return .{ .bend = @intCast(index) };
    }
    return planDetour(from, to);
}

/// Open-water search grid spacing, in chart units.
const sea_step: f32 = 8;
const max_sea_side = 160;

/// A shortest path over a coarse grid of open water between two berths,
/// with its corners pulled tight while the straight runs stay at sea.
fn planDetour(from: usize, to: usize) ?Plan {
    const start = berth(from);
    const end = berth(to);
    const margin = @max(320, 0.8 * distance(start, end));
    const left = @min(start[0], end[0]) - margin;
    const top = @min(start[1], end[1]) - margin;
    const columns: usize = @min(max_sea_side, @as(usize, @intFromFloat((@abs(end[0] - start[0]) + 2 * margin) / sea_step)) + 1);
    const rows: usize = @min(max_sea_side, @as(usize, @intFromFloat((@abs(end[1] - start[1]) + 2 * margin) / sea_step)) + 1);
    const node = struct {
        fn point(l: f32, t: f32, i: usize, cols: usize) Point {
            return .{ l + @as(f32, @floatFromInt(i % cols)) * sea_step, t + @as(f32, @floatFromInt(i / cols)) * sea_step };
        }
    }.point;
    const count = columns * rows;
    var cost: [max_sea_side * max_sea_side]f32 = undefined;
    var previous: [max_sea_side * max_sea_side]u32 = undefined;
    var done: std.StaticBitSet(max_sea_side * max_sea_side) = .empty;
    const unreached = std.math.inf(f32);
    @memset(cost[0..count], unreached);
    // Seed every node the start berth can reach in a straight run.
    const none = std.math.maxInt(u32);
    for (0..count) |i| {
        const p = node(left, top, i, columns);
        if (distance(p, start) > 3 * sea_step) continue;
        if (!segmentClear(start, p, from, to)) continue;
        cost[i] = distance(p, start);
        previous[i] = none;
    }
    // Dijkstra with a linear scan: the grid is small and this runs only at bake time.
    var goal: ?usize = null;
    while (true) {
        var best: ?usize = null;
        for (0..count) |i| {
            if (done.isSet(i) or cost[i] == unreached) continue;
            if (best == null or cost[i] + distance(node(left, top, i, columns), end) < cost[best.?] + distance(node(left, top, best.?, columns), end)) best = i;
        }
        const at = best orelse break;
        done.set(at);
        const here = node(left, top, at, columns);
        if (distance(here, end) <= 3 * sea_step and segmentClear(here, end, from, to)) {
            goal = at;
            break;
        }
        const x: isize = @intCast(at % columns);
        const y: isize = @intCast(at / columns);
        var dy: isize = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: isize = -1;
            while (dx <= 1) : (dx += 1) {
                const nx = x + dx;
                const ny = y + dy;
                if ((dx == 0 and dy == 0) or nx < 0 or ny < 0 or nx >= columns or ny >= rows) continue;
                const next: usize = @intCast(ny * @as(isize, @intCast(columns)) + nx);
                if (done.isSet(next)) continue;
                const there = node(left, top, next, columns);
                const step = cost[at] + distance(here, there);
                if (step >= cost[next]) continue;
                if (!segmentClear(here, there, from, to)) continue;
                cost[next] = step;
                previous[next] = @intCast(at);
            }
        }
    }
    var trail: [max_sea_side * max_sea_side]Point = undefined;
    var len: usize = 0;
    var at: u32 = @intCast(goal orelse return null);
    while (at != none) : (at = previous[at]) {
        trail[len] = node(left, top, at, columns);
        len += 1;
    }
    std.mem.reverse(Point, trail[0..len]);
    // Pull the corners tight: keep only the stops a straight run can't skip.
    var plan = Plan{};
    var anchor = start;
    var i: usize = 0;
    while (i < len) {
        var reach = i;
        while (reach + 1 < len and segmentClear(anchor, trail[reach + 1], from, to)) reach += 1;
        if (segmentClear(anchor, end, from, to)) break;
        if (plan.len == max_waypoints) return null;
        plan.points[plan.len] = trail[reach];
        plan.len += 1;
        anchor = trail[reach];
        i = reach + 1;
    }
    if (!courseClear(from, to, detourCourse, .{ start, plan.waypoints(), end })) return null;
    return plan;
}

fn segmentClear(a: Point, b: Point, from: usize, to: usize) bool {
    const samples: usize = @max(2, @as(usize, @intFromFloat(4 * distance(a, b))));
    for (0..samples + 1) |step| {
        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(samples));
        if (onLand(.{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t }, from, to)) return false;
    }
    return true;
}

/// Whether the straight line between two quays passes no other island, so
/// the harbors face each other across open water.
fn straightLineClear(from: usize, to: usize) bool {
    const p = colony.worldTile(colony.quay(from), from);
    const q = colony.worldTile(colony.quay(to), to);
    for (1..course_samples) |step| {
        const t = @as(f32, @floatFromInt(step)) / course_samples;
        const point = Point{ p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t };
        for (0..settlement_count) |chart| {
            if (chart == from or chart == to) continue;
            const cell = colony.cellAt(chart, point) orelse continue;
            if (colony.depth(cell, chart) >= 0) return false;
        }
    }
    return true;
}

/// The same course sailed the other way bends to the other side.
fn mirror(bend: Bend) Bend {
    return .{ .reach = bend.reach, .side = -bend.side };
}

pub const Lane = baked_lanes.Lane;

const lane_table: [settlement_count][settlement_count]?Lane = blk: {
    var table: [settlement_count][settlement_count]?Lane = @splat(@splat(null));
    for (baked_lanes.lanes) |lane| {
        table[lane.from][lane.to] = lane;
        table[lane.to][lane.from] = lane;
    }
    break :blk table;
};
const baked_lanes = @import("ferry_lanes.zig");

/// Harbors within the ferry's range of `from`, nearest first.
pub const Neighbors = struct {
    items: [settlement_count]usize = undefined,
    len: usize = 0,

    pub fn slice(list: *const Neighbors) []const usize {
        return list.items[0..list.len];
    }
};

pub fn neighbors(from: usize) Neighbors {
    var result = Neighbors{};
    for (0..settlement_count) |to| {
        if (!withinRange(from, to)) continue;
        var at = result.len;
        while (at > 0 and legs[from][result.items[at - 1]] > legs[from][to]) : (at -= 1) result.items[at] = result.items[at - 1];
        result.items[at] = to;
        result.len += 1;
    }
    return result;
}

pub fn ferryRations(from: usize, to: usize, passengers: u16) u16 {
    const days: u16 = @intFromFloat(@ceil(legSeconds(from, to) / day_seconds));
    return days * dailyUse(passengers);
}

pub const Ferry = struct {
    cargo: Stores = .{},
    passengers: u16 = 0,
    /// The harbor the ferry is moored at, or the one it left.
    origin: usize = 0,
    /// The harbor it is bound for. Equal to `origin` while moored.
    destination: usize = 0,
    /// Game seconds since it left `origin`.
    sailing_time: f32 = 0,
    /// The current passage surveys `destination` instead of carrying a load.
    surveying: bool = false,
    /// Bali has been surveyed and its port opened. Other islands are
    /// recorded on the fleet's chart.
    surveyed: bool = false,

    pub fn moored(f: Ferry) ?usize {
        return if (f.origin == f.destination) f.origin else null;
    }

    pub fn legSeconds(f: Ferry) f32 {
        return legs[f.origin][f.destination];
    }

    /// The fraction of the current passage sailed, 0 while moored.
    pub fn progress(f: Ferry) f32 {
        if (f.moored() != null) return 0;
        return f.sailing_time / f.legSeconds();
    }
};

/// The dock the ferry occupies: its mooring, or the one it is bound for.
pub fn ferryBerthChart(g: *const Game) usize {
    return g.ferry.destination;
}

pub fn mooredChart(g: *const Game) ?usize {
    return g.ferry.moored();
}

pub fn advanceShip(g: *Game, seconds: f32) void {
    if (g.isOver() or g.ferry.moored() != null) return;
    g.ferry.sailing_time += seconds;
    if (g.ferry.sailing_time < g.ferry.legSeconds()) return;
    const port = g.ferry.destination;
    if (g.ferry.surveying) {
        g.chartHarbor(port);
    } else {
        if (port == 1 and g.ferry.passengers > 0) g.charter.ferried_to_bali = true;
        g.land(port, g.ferry.passengers, g.ferry.cargo);
    }
    g.ferry = .{ .origin = port, .destination = port, .surveyed = g.ferry.surveyed };
}

fn depart(g: *Game, destination: usize) void {
    g.ferry.destination = destination;
    g.ferry.sailing_time = 0;
}

/// Why the moored ferry cannot sail to `destination`, if it cannot.
pub fn ferryRouteProblem(g: *const Game, destination: usize) ?[:0]const u8 {
    const source = g.mooredChart() orelse return "Wait until the ferry is moored.";
    if (destination >= settlement_count or destination == source) return "Choose another harbor.";
    if (!withinRange(source, destination)) return "That harbor is beyond the ferry's range.";
    if (!g.islandOpen(destination)) return "Survey this island before sending the ferry.";
    if (g.berthsUsed(destination) >= dock_capacity) return "The destination dock has no free berth.";
    return null;
}

pub fn ferryLimit(g: *const Game, destination: usize) u16 {
    if (g.ferryRouteProblem(destination) != null) return 0;
    const source = g.mooredChart().?;
    return @min(ferry_capacity, g.residents(source), g.freeLandingSpace(destination));
}

pub fn ferryProvisions(g: *const Game, source: usize, destination: usize, settlers: u16) Stores {
    const amount = ferryRations(source, destination, settlers);
    const meat = @min(g.stores[source].venison, amount);
    return .{ .grain = amount - meat, .venison = meat };
}

/// Supplies for settlers founding a camp: three days of food and water,
/// as far as the departure harbor can spare them.
pub fn ferryCampSupplies(g: *const Game, destination: usize, settlers: u16) Stores {
    if (settlers == 0 or settlers > g.ferryLimit(destination) or g.residents(destination) != 0) return .{};
    const source = g.mooredChart().?;
    const rations = g.ferryProvisions(source, destination, settlers);
    const limits = g.ferryCargoLimit(destination, settlers);
    const meals = 3 * dailyUse(settlers);
    const home_reserve = 3 * dailyUse(g.residents(source) - settlers);
    var load = Stores{};
    inline for (food_fields ++ .{"water"}) |name| {
        const needed = meals -| @field(g.stores[destination], name);
        const spare = @field(g.stores[source], name) -| @field(rations, name) -| home_reserve;
        @field(load, name) = @min(needed, spare, @field(limits, name));
    }
    return load;
}

/// Ferry settlers with the camp supplies they need.
pub fn ferrySettlers(g: *Game, destination: usize, requested: u16) ?[:0]const u8 {
    if (requested == 0) return "Choose settlers to ferry.";
    return g.sendFerry(destination, requested, g.ferryCampSupplies(destination, requested));
}

pub fn sendFerry(g: *Game, destination: usize, settlers: u16, load: Stores) ?[:0]const u8 {
    if (g.ferryRouteProblem(destination)) |problem| return problem;
    const source = g.mooredChart().?;
    if (settlers > g.ferryLimit(destination)) return "Choose a passenger count that fits the available landing space.";
    if (settlers == 0 and load.empty()) return "Choose settlers or supplies to send.";
    const rations = g.ferryProvisions(source, destination, settlers);
    if (load.units() + rations.units() > ferry_hold) return "Cargo and provisions exceed the ferry's hold.";
    if (!g.stores[source].includes(rations)) return "The ferry needs more grain or venison for the journey.";
    if (!g.ferryCargoLimit(destination, settlers).includes(load)) return "There is not enough stock or room for this cargo.";
    g.stores[source].take(rations);
    g.stores[source].take(load);
    if (source != 0) g.island_people[source - 1] -= settlers;
    g.ferry.cargo = load;
    g.ferry.passengers = settlers;
    depart(g, destination);
    return null;
}

/// Sail the ferry without a load, to bring it where it is needed.
pub fn sailFerry(g: *Game, destination: usize) ?[:0]const u8 {
    if (g.ferryRouteProblem(destination)) |problem| return problem;
    depart(g, destination);
    return null;
}

pub fn ferryCargoLimit(g: *const Game, destination: usize, settlers: u16) Stores {
    const source = g.mooredChart() orelse return .{};
    if (destination >= settlement_count) return .{};
    return g.loadingLimits(source, destination, g.ferryProvisions(source, destination, settlers), g.incomingCargo(destination));
}

pub fn ferrySurveyProblem(g: *const Game, target: usize) ?[:0]const u8 {
    const source = g.mooredChart() orelse return "Wait until the ferry is moored.";
    if (target >= settlement_count or target == source) return "Choose another harbor.";
    if (g.islandOpen(target)) return "This island is already on the chart.";
    if (!withinRange(source, target)) return "That harbor is beyond the ferry's range.";
    if (target != charter.charter_island and !g.charterComplete()) return "Complete the island charter to explore farther.";
    if (ocean.routeTo(target)) |index| {
        if (ocean.routes[index].ship == .barque) return "Only an ocean barque can survey this island.";
    }
    for (g.vessels()) |vessel| {
        if (vessel.phase == .outbound and vessel.chart == target) return "A ship is already surveying this island.";
    }
    if (g.coins < survey_cost) return "The survey crew needs 20 coins.";
    if (g.berthsUsed(target) >= dock_capacity) return "The destination dock has no free berth.";
    return null;
}

/// Send the ferry's crew to chart a harbor. The port opens when it arrives.
pub fn surveyByFerry(g: *Game, target: usize) ?[:0]const u8 {
    if (g.ferrySurveyProblem(target)) |problem| return problem;
    g.coins -= survey_cost;
    g.ferry.surveying = true;
    depart(g, target);
    return null;
}

test "every baked lane's course stays at sea both ways, clear of every island's tiles and coastline" {
    for (baked_lanes.lanes) |lane| {
        for ([_][2]usize{ .{ lane.from, lane.to }, .{ lane.to, lane.from } }) |leg| {
            for (0..course_samples + 1) |step| {
                const t = @as(f32, @floatFromInt(step)) / course_samples;
                const point = coursePosition(leg[0], leg[1], t);
                if (!onLand(point, leg[0], leg[1])) continue;
                std.debug.print("{s} to {s} reaches land at {d:.3} {any}\n", .{ geography.names[leg[0]], geography.names[leg[1]], t, point });
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expect(lane.from < lane.to and lane.waypoints.len <= max_waypoints);
    }
}

test "a leg runs both ways along the same course" {
    for (baked_lanes.lanes) |lane| {
        for (0..21) |step| {
            const t = @as(f32, @floatFromInt(step)) / 20;
            const there = coursePosition(lane.from, lane.to, t);
            const back = coursePosition(lane.to, lane.from, 1 - t);
            try std.testing.expectApproxEqAbs(there[0], back[0], 0.05);
            try std.testing.expectApproxEqAbs(there[1], back[1], 0.05);
        }
        try std.testing.expectApproxEqAbs(berth(lane.from)[0], coursePosition(lane.from, lane.to, 0)[0], 0.05);
        try std.testing.expectApproxEqAbs(berth(lane.to)[1], coursePosition(lane.from, lane.to, 1)[1], 0.05);
    }
}

test "harbors with no baked lane between them have no course that stays at sea" {
    // A cheap check of the bake: every leg in range that the table leaves out
    // fails the straight-line rule or every bend. Detours are checked by the
    // bake itself, so this only proves no smooth course was missed.
    for (0..settlement_count) |from| {
        for (from + 1..settlement_count) |to| {
            if (lane_table[from][to] != null or legs[from][to] > range_seconds or !straightLineClear(from, to)) continue;
            if (from == 0 and to == 1) return error.TestUnexpectedResult;
            for (course_bends) |bend| try std.testing.expect(!courseClear(from, to, bentCourse, .{ from, to, bend }));
        }
    }
}

test "the course to Madura rounds Java instead of crossing it" {
    const madura = geography.chartNamed("Madura").?;
    try std.testing.expect(withinRange(0, madura));
    try std.testing.expect(lane_table[0][madura].?.waypoints.len > 0);
    // The straight course and every smooth bend cross Java's northern plains.
    for (course_bends) |bend| try std.testing.expect(!courseClear(0, madura, bentCourse, .{ 0, madura, bend }));
}

test "the Bali Strait sets the scale and Lombok is in range of Bali" {
    try std.testing.expectEqual(crossing_seconds, legSeconds(0, 1));
    try std.testing.expectEqual(legSeconds(1, 2), legSeconds(2, 1));
    try std.testing.expect(withinRange(0, 1));
    try std.testing.expect(withinRange(1, 2));
    try std.testing.expect(!withinRange(0, 2));
    // Sumbawa is in range of Bali, but the course crosses Lombok.
    const sumbawa = geography.chartNamed("Sumbawa").?;
    try std.testing.expect(legSeconds(1, sumbawa) <= range_seconds and !withinRange(1, sumbawa));
    try std.testing.expect(withinRange(2, sumbawa));
    try std.testing.expect(!withinRange(1, 1));
    const from_bali = neighbors(1);
    try std.testing.expectEqual(@as(usize, 2), from_bali.slice()[0]);
    for (from_bali.slice()[1..], from_bali.slice()[0 .. from_bali.len - 1]) |later, earlier| {
        try std.testing.expect(legSeconds(1, earlier) <= legSeconds(1, later));
    }
}

test "the ferry surveys Lombok from Bali and carries settlers and stores there" {
    var g = Game.init();
    g.coins = 2 * survey_cost;
    try std.testing.expect(g.surveyByFerry(2) != null);
    try std.testing.expect(g.surveyByFerry(1) == null);
    g.advanceShip(crossing_seconds);
    try std.testing.expectEqual(@as(?usize, 1), g.mooredChart());
    try std.testing.expectEqualStrings("Complete the island charter to explore farther.", g.ferrySurveyProblem(2).?);
    g.charter = .{ .ferried_to_bali = true, .won = true, .housed_eight = true };
    g.bridge = true;
    try std.testing.expect(g.surveyByFerry(2) == null);
    g.advanceShip(legSeconds(1, 2));
    try std.testing.expect(g.islandOpen(2));
    try std.testing.expect(g.fleet.charted[ocean.routeTo(2).?]);
    try std.testing.expectEqual(colony.Kind.port, g.tileAt(2, colony.quay(2)));
    try std.testing.expectEqual(@as(?usize, 2), g.mooredChart());

    try std.testing.expect(g.sailFerry(1) == null);
    g.advanceShip(legSeconds(2, 1));
    g.people = 8;
    g.island_people[0] = 3;
    g.stores[1] = .{ .grain = 20, .water = 20, .fruit = 20, .venison = 20 };
    try std.testing.expect(g.ferrySettlers(2, 2) == null);
    try std.testing.expectEqual(@as(u16, 1), g.residents(1));
    try std.testing.expectEqual(@as(u16, 2), g.reservedBeds(2));
    const cargo = g.ferry.cargo;
    try std.testing.expect(!cargo.empty());
    g.advanceShip(legSeconds(1, 2));
    try std.testing.expectEqual(@as(u16, 2), g.residents(2));
    try std.testing.expectEqualDeep(cargo, g.stores[2]);
    try std.testing.expect(g.ferry.cargo.empty() and g.ferry.passengers == 0);
}

test "the ferry cannot sail out of range or to an unsurveyed harbor" {
    var g = Game.init();
    try std.testing.expectEqualStrings("Survey this island before sending the ferry.", g.ferryRouteProblem(1).?);
    try std.testing.expectEqualStrings("That harbor is beyond the ferry's range.", g.ferryRouteProblem(2).?);
    try std.testing.expectEqualStrings("Choose another harbor.", g.ferryRouteProblem(0).?);
    try std.testing.expectEqualStrings("Choose another harbor.", g.ferryRouteProblem(settlement_count).?);
    try std.testing.expectEqual(@as(u16, 0), g.ferryLimit(1));
}
