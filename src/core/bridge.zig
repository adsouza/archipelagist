// Bridges between nearby islands and the overland transfers they carry.
// A crossing joins two islands whose bridgeheads are at most
// `max_bridge_spans` apart. The Bali Strait is the charter's crossing.
const std = @import("std");
const colony = @import("colony.zig");
const terrain = @import("terrain.zig");
const roads = @import("roads.zig");
const Game = colony.Game;
const Cell = colony.Cell;
const Stores = colony.Stores;
const depth = colony.depth;
const geography = colony.geography;
const worldTile = colony.worldTile;

pub const bridge_crew: u16 = 4;

pub const max_bridge_spans: u16 = 2;

/// Each span is 48 chart units of open water.
const span_length = 48;

fn bridgeSpans(start: [2]f32, end: [2]f32) u16 {
    const dx = end[0] - start[0];
    const dy = end[1] - start[1];
    return @intFromFloat(@ceil(@sqrt(dx * dx + dy * dy) / span_length));
}

fn cells(points: [2][2]u16) [2]Cell {
    return .{ .{ .x = points[0][0], .y = points[0][1] }, .{ .x = points[1][0], .y = points[1][1] } };
}

pub const Crossing = struct {
    charts: [2]usize,
    heads: [2]Cell,
    spans: u16,
    /// Timber and stone each shore supplies.
    cost: Stores,

    fn init(a: usize, b: usize, heads: [2][2]u16) Crossing {
        const at = cells(heads);
        const spans = bridgeSpans(worldTile(at[0], a), worldTile(at[1], b));
        return .{ .charts = .{ a, b }, .heads = at, .spans = spans, .cost = .{ .timber = 2 * spans, .stone = 3 * spans } };
    }

    pub fn joins(crossing: Crossing, chart: usize) bool {
        return crossing.charts[0] == chart or crossing.charts[1] == chart;
    }

    /// The bridgehead on `chart`, which must be one end.
    pub fn headOn(crossing: Crossing, chart: usize) Cell {
        return if (crossing.charts[0] == chart) crossing.heads[0] else crossing.heads[1];
    }

    /// The island across the bridge from `chart`, which must be one end.
    pub fn across(crossing: Crossing, chart: usize) usize {
        return if (crossing.charts[0] == chart) crossing.charts[1] else crossing.charts[0];
    }

    /// Game seconds a settler takes to walk from one bridgehead to the other.
    pub fn walkSeconds(crossing: Crossing) f32 {
        return @as(f32, @floatFromInt(crossing.spans)) * walk_seconds_per_span;
    }
};

/// Game seconds to walk one span. A two-span bridge is quicker than the
/// ferry's crossing of the same strait.
pub const walk_seconds_per_span: f32 = 3;

/// Settlers out on all bridges at once.
pub const max_walkers = 8;

/// A settler on a bridge. They have left one island and are not yet
/// counted on the other, but their bed there is reserved.
pub const Walker = struct {
    crossing: usize = 0,
    destination: usize = 0,
    /// Game seconds since the settler stepped onto the bridge.
    elapsed: f32 = 0,

    pub fn walkSeconds(walker: Walker) f32 {
        return crossings[walker.crossing].walkSeconds();
    }

    /// How far along the bridge the settler is, from the first island's
    /// bridgehead (0) to the second's (1).
    pub fn position(walker: Walker) f32 {
        const walked = walker.elapsed / walker.walkSeconds();
        return if (walker.destination == crossings[walker.crossing].charts[1]) walked else 1 - walked;
    }
};

pub const Walkers = struct {
    items: [max_walkers]Walker = @splat(.{}),
    count: usize = 0,

    pub fn active(walkers: *const Walkers) []const Walker {
        return walkers.items[0..walkers.count];
    }
};

/// Settlers who reached the far side in one step.
pub const Landings = struct {
    items: [max_walkers]Walker = undefined,
    len: usize = 0,

    pub fn slice(landings: *const Landings) []const Walker {
        return landings.items[0..landings.len];
    }
};

pub const madura = geography.chartNamed("Madura").?;

pub const crossings = [_]Crossing{
    Crossing.init(0, 1, terrain.bridgeheads),
    Crossing.init(0, madura, terrain.java_madura_bridgeheads),
};

/// The Bali Strait bridge the island charter asks for.
pub const strait = 0;

pub const bridgeheads = crossings[strait].heads;
pub const bridge_spans = crossings[strait].spans;
pub const bridge_cost = crossings[strait].cost;

// The closest land tiles on Bali and Lombok.
const bali_lombok_bridgeheads = cells(terrain.bali_lombok_bridgeheads);

pub const bali_lombok_spans = bridgeSpans(worldTile(bali_lombok_bridgeheads[0], 1), worldTile(bali_lombok_bridgeheads[1], 2));

/// Bridges built, by crossing.
pub const Bridges = [crossings.len]bool;

/// A built bridge reaches `chart`.
pub fn hasBridge(g: *const Game, chart: usize) bool {
    for (crossings, g.bridges) |crossing, built| {
        if (built and crossing.joins(chart)) return true;
    }
    return false;
}

/// The tiles settlers reach on foot on `chart`: everything its harbor's roads
/// reach, and everything reached from the end of a bridge whose other end the
/// far island's harbor roads reach. Settlers walk over a bridge in either
/// direction once a road leads to it.
pub fn footWalk(g: *const Game, chart: usize) roads.Walk {
    const tiles = g.tilesOn(chart);
    var walk = roads.Walk.fromPort(tiles, chart);
    for (crossings, g.bridges) |crossing, built| {
        if (!built or !crossing.joins(chart)) continue;
        const far = crossing.across(chart);
        if (!harborReaches(g, far, crossing.headOn(far))) continue;
        walk.extend(tiles, chart, crossing.headOn(chart));
    }
    return walk;
}

fn harborReaches(g: *const Game, chart: usize, cell: Cell) bool {
    return roads.Walk.fromPort(g.tilesOn(chart), chart).contains(cell);
}

/// Why settlers cannot walk between the two harbors over a bridge, if they cannot.
pub fn footpathProblem(g: *const Game, crossing: usize) ?[:0]const u8 {
    if (crossing >= crossings.len) return "Choose a bridge.";
    if (!g.bridges[crossing]) return "Build the bridge first.";
    const plan = crossings[crossing];
    for (plan.charts, plan.heads) |chart, head| {
        if (!harborReaches(g, chart, head)) return "Lay roads from both harbors to the bridge.";
    }
    return null;
}

/// Whether a road from each harbor reaches the bridge.
pub fn bridgeRoadReaches(g: *const Game, crossing: usize, chart: usize) bool {
    return harborReaches(g, chart, crossings[crossing].headOn(chart));
}

fn endProblem(crossing: usize, chart: usize) ?[:0]const u8 {
    if (crossing >= crossings.len) return "Choose a bridge.";
    if (!crossings[crossing].joins(chart)) return "Choose an island on that bridge.";
    return null;
}

pub fn bridgeCargoLimit(g: *const Game, crossing: usize, source: usize) Stores {
    if (endProblem(crossing, source) != null) return .{};
    const target = crossings[crossing].across(source);
    return g.loadingLimits(source, target, .{}, g.incomingCargo(target));
}

pub fn sendCargo(g: *Game, crossing: usize, source: usize, load: Stores) ?[:0]const u8 {
    if (endProblem(crossing, source)) |problem| return problem;
    const target = crossings[crossing].across(source);
    if (!g.bridges[crossing]) {
        if (g.mooredChart() != source) return "The ferry must be moored at the loading port.";
        return g.sendFerry(target, 0, load);
    }
    if (g.footpathProblem(crossing)) |problem| return problem;
    if (load.empty()) return "Choose supplies to send.";
    if (!g.bridgeCargoLimit(crossing, source).includes(load)) return "There is not enough stock or room for this cargo.";
    g.stores[source].take(load);
    g.stores[target].add(load);
    return null;
}

pub fn bridgeProblem(g: *const Game, crossing: usize) ?[:0]const u8 {
    if (crossing >= crossings.len) return "Choose a bridge.";
    if (g.bridges[crossing]) return "The bridge is already built.";
    const plan = crossings[crossing];
    if (plan.spans > max_bridge_spans) return "This crossing exceeds the bridge span limit.";
    for (plan.charts) |chart| {
        if (!g.islandOpen(chart)) return if (chart == 1) "Survey Bali before planning the crossing." else "Survey both islands before planning the crossing.";
    }
    for (plan.charts) |chart| {
        if (g.residents(chart) < bridge_crew) return "Both islands need four resident settlers to build the bridge.";
        if (g.workforce(chart) == 0) return "Both islands need settlers able to work on the bridge.";
    }
    for (plan.charts) |chart| {
        const stock = g.stores[chart];
        if (stock.timber < plan.cost.timber or stock.stone < plan.cost.stone) return "Both islands must stockpile their share of timber and stone.";
    }
    return null;
}

pub fn buildBridge(g: *Game, crossing: usize) ?[:0]const u8 {
    if (g.bridgeProblem(crossing)) |problem| return problem;
    const plan = crossings[crossing];
    for (plan.charts) |chart| {
        g.stores[chart].timber -= plan.cost.timber;
        g.stores[chart].stone -= plan.cost.stone;
    }
    g.bridges[crossing] = true;
    // Eight crew have worked both shores by the time the strait is bridged.
    if (crossing == strait) g.charter.housed_eight = true;
    return null;
}

/// Walk one settler across a bridge to `destination`.
pub fn crossBridge(g: *Game, crossing: usize, destination: usize) ?[:0]const u8 {
    if (endProblem(crossing, destination)) |problem| return problem;
    if (g.footpathProblem(crossing)) |problem| return problem;
    const source = crossings[crossing].across(destination);
    if (g.residents(source) == 0) return "No settlers are waiting to cross from that island.";
    if (g.freeLandingSpace(destination) == 0) return "There is no room for more settlers at the destination.";
    if (g.walkers.count == max_walkers) return "The bridges are crowded. Wait for a settler to reach the far side.";
    // Java's residents are everyone not counted elsewhere, walkers included.
    if (source != 0) g.island_people[source - 1] -= 1;
    g.walkers.items[g.walkers.count] = .{ .crossing = crossing, .destination = destination };
    g.walkers.count += 1;
    return null;
}

/// Settlers on a bridge heading for `chart`.
pub fn walkingTo(g: *const Game, chart: usize) u16 {
    var total: u16 = 0;
    for (g.walkers.active()) |walker| total += @intFromBool(walker.destination == chart);
    return total;
}

/// Walk every settler on a bridge forward and put arrivals ashore.
pub fn advanceWalkers(g: *Game, seconds: f32) Landings {
    var landed = Landings{};
    if (g.isOver()) return landed;
    var kept: usize = 0;
    for (0..g.walkers.count) |index| {
        var walker = g.walkers.items[index];
        walker.elapsed += seconds;
        if (walker.elapsed >= walker.walkSeconds()) {
            g.land(walker.destination, 1, .{});
            landed.items[landed.len] = walker;
            landed.len += 1;
        } else {
            g.walkers.items[kept] = walker;
            kept += 1;
        }
    }
    // Unused slots stay at their defaults so equal games encode alike.
    for (g.walkers.items[kept..g.walkers.count]) |*slot| slot.* = .{};
    g.walkers.count = kept;
    return landed;
}

test "a road to one end of a bridge lets settlers walk on from the other end" {
    var g = Game.init();
    g.fleet.charted[colony.ocean.routeTo(madura).?] = true;
    g.openPort(madura);
    const c = crossings[1];
    const madura_head = c.headOn(madura);
    // Madura's harbor roads don't reach the bridgehead yet.
    try std.testing.expect(!g.connected(madura, madura_head));
    try std.testing.expect(!g.footWalk(madura).contains(madura_head));
    // Java's walk already reaches its bridgehead, so once the bridge stands
    // its settlers walk over and on into Madura.
    try std.testing.expect(g.bridgeRoadReaches(1, 0));
    g.bridges[1] = true;
    try std.testing.expect(g.footWalk(madura).contains(madura_head));
    // Moving residents needs a road from Madura's harbor too.
    try std.testing.expectEqualStrings("Lay roads from both harbors to the bridge.", g.footpathProblem(1).?);
    g.paveBridge(1);
    try std.testing.expect(g.footpathProblem(1) == null);
    // Without the bridge the walk stops at the shore again.
    g.bridges[1] = false;
    try std.testing.expectEqual(roads.Walk.fromPort(g.tilesOn(0), 0).len, g.footWalk(0).len);
}

test "every crossing fits the span limit from land to land" {
    try std.testing.expectEqual(2, bridge_spans);
    try std.testing.expectEqual(1, crossings[1].spans);
    for (crossings) |crossing| {
        try std.testing.expect(crossing.spans <= max_bridge_spans);
        try std.testing.expect(crossing.charts[0] != crossing.charts[1]);
        for (crossing.heads, crossing.charts) |head, chart| try std.testing.expect(depth(head, chart) >= 0);
    }
}

test "Java to Bali fits the bridge limit and every Bali to Lombok crossing exceeds it" {
    try std.testing.expect(bridge_spans <= max_bridge_spans);
    try std.testing.expectEqual(3, bali_lombok_spans);
    for (bali_lombok_bridgeheads, 1..) |cell, chart| {
        try std.testing.expect(depth(cell, chart) >= 0);
    }
    const west = geography.grids[1];
    const east = geography.grids[2];
    for (0..west.area()) |bali_index| {
        const bali = west.cell(bali_index);
        if (depth(bali, 1) < 0) continue;
        for (0..east.area()) |lombok_index| {
            const lombok = east.cell(lombok_index);
            if (depth(lombok, 2) < 0) continue;
            try std.testing.expect(bridgeSpans(worldTile(bali, 1), worldTile(lombok, 2)) > max_bridge_spans);
        }
    }
}

test "a Java to Madura bridge carries settlers and stores both ways" {
    var g = Game.init();
    g.fleet.charted[colony.ocean.routeTo(madura).?] = true;
    g.openPort(madura);
    // A second cottage leaves Java room for a settler to walk back.
    g.setTile(0, .{ .x = 39, .y = 39 }, .cottage);
    g.island_people[madura - 1] = 4;
    g.people = 4 + 3;
    const c = crossings[1];
    g.stores[0] = .{ .timber = 10, .stone = 10, .grain = 10 };
    g.stores[madura] = c.cost;
    try std.testing.expectEqualStrings("Both islands need four resident settlers to build the bridge.", g.bridgeProblem(1).?);
    g.people += 1;
    try std.testing.expectEqualStrings("Choose an island on that bridge.", g.crossBridge(1, 1).?);
    try std.testing.expectEqualStrings("Build the bridge first.", g.crossBridge(1, 0).?);
    try std.testing.expect(g.buildBridge(1) == null);
    try std.testing.expect(g.bridges[1] and !g.bridges[strait]);
    try std.testing.expect(g.hasBridge(madura) and g.hasBridge(0) and !g.hasBridge(1));
    try std.testing.expectEqual(@as(u16, 10) - c.cost.timber, g.stores[0].timber);
    try std.testing.expect(g.stores[madura].empty());
    try std.testing.expectEqualStrings("Lay roads from both harbors to the bridge.", g.crossBridge(1, 0).?);
    g.paveBridge(1);
    try std.testing.expect(g.crossBridge(1, 0) == null);
    _ = g.advanceWalkers(c.walkSeconds());
    try std.testing.expectEqual(@as(u16, 5), g.residents(0));
    try std.testing.expectEqual(@as(u16, 3), g.residents(madura));
    try std.testing.expect(g.crossBridge(1, madura) == null);
    _ = g.advanceWalkers(c.walkSeconds());
    try std.testing.expectEqual(@as(u16, 4), g.residents(madura));
    try std.testing.expect(g.sendCargo(1, 0, .{ .grain = 4 }) == null);
    try std.testing.expectEqual(@as(u16, 4), g.stores[madura].grain);
    try std.testing.expect(g.sendCargo(1, madura, .{ .grain = 1 }) == null);
    try std.testing.expectEqual(@as(u16, 7), g.stores[0].grain);
    try std.testing.expectEqualStrings("Choose an island on that bridge.", g.sendCargo(1, 1, .{ .grain = 1 }).?);
}

/// Java and Bali with the strait bridged, roads to both ends, and settlers on both shores.
fn bridgedStrait() Game {
    var g = Game.init();
    g.ferry.surveyed = true;
    g.openPort(1);
    g.bridges[strait] = true;
    g.island_people[0] = 2;
    g.people = 2 + 2;
    g.paveBridge(strait);
    return g;
}

test "a settler walks the bridge: away from both shores until the far bridgehead" {
    var g = bridgedStrait();
    const walk = crossings[strait].walkSeconds();
    try std.testing.expectEqual(@as(f32, 2 * walk_seconds_per_span), walk);
    const beds = g.freeLandingSpace(1);
    try std.testing.expect(g.crossBridge(strait, 1) == null);
    // Left Java at once, and is not yet on Bali, but holds a bed there.
    try std.testing.expectEqual(@as(u16, 1), g.residents(0));
    try std.testing.expectEqual(@as(u16, 2), g.residents(1));
    try std.testing.expectEqual(@as(u16, 1), g.walkingTo(1));
    try std.testing.expectEqual(beds - 1, g.freeLandingSpace(1));
    try std.testing.expectEqual(@as(u32, 3), g.awayFromJava());

    try std.testing.expectEqual(@as(usize, 0), g.advanceWalkers(walk / 2).len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), g.walkers.active()[0].position(), 1e-6);
    const landed = g.advanceWalkers(walk / 2);
    try std.testing.expectEqual(@as(usize, 1), landed.len);
    try std.testing.expectEqual(@as(usize, 1), landed.slice()[0].destination);
    try std.testing.expectEqual(@as(u16, 3), g.residents(1));
    try std.testing.expectEqual(@as(usize, 0), g.walkers.count);
    try std.testing.expectEqualDeep(Walker{}, g.walkers.items[0]);
}

test "walkers heading west move from the far bridgehead back toward the first" {
    var g = bridgedStrait();
    try std.testing.expect(g.crossBridge(strait, 0) == null);
    try std.testing.expectEqual(@as(u16, 1), g.residents(1));
    _ = g.advanceWalkers(crossings[strait].walkSeconds() / 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), g.walkers.active()[0].position(), 1e-6);
}

test "settlers set out only once roads reach both ends of the bridge" {
    var g = bridgedStrait();
    g.bridges[strait] = false;
    try std.testing.expectEqualStrings("Build the bridge first.", g.crossBridge(strait, 1).?);
    var unpaved = Game.init();
    unpaved.ferry.surveyed = true;
    unpaved.openPort(1);
    unpaved.bridges[strait] = true;
    unpaved.island_people[0] = 2;
    unpaved.people = 4;
    try std.testing.expectEqualStrings("Lay roads from both harbors to the bridge.", unpaved.crossBridge(strait, 1).?);
    try std.testing.expectEqual(@as(usize, 0), unpaved.walkers.count);
}

test "a full bridge turns settlers away and every walker lands exactly once" {
    var g = bridgedStrait();
    // Room on Bali for every walker at once.
    for (0..3) |i| g.setTile(1, .{ .x = 20 + 2 * i, .y = 20 }, .cottage);
    g.people += max_walkers;
    try std.testing.expect(g.freeLandingSpace(1) >= max_walkers + 1);
    for (0..max_walkers) |_| try std.testing.expect(g.crossBridge(strait, 1) == null);
    try std.testing.expectEqualStrings("The bridges are crowded. Wait for a settler to reach the far side.", g.crossBridge(strait, 1).?);
    const people = g.people;
    var landed: usize = 0;
    var steps: usize = 0;
    while (g.walkers.count > 0) : (steps += 1) {
        landed += g.advanceWalkers(0.7).len;
        try std.testing.expectEqual(people, g.people);
    }
    try std.testing.expectEqual(@as(usize, max_walkers), landed);
    try std.testing.expectEqual(@as(u16, 2 + max_walkers), g.residents(1));
    try std.testing.expect(steps > 1);
}
