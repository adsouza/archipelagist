// Bridges between nearby islands and the overland transfers they carry.
// A crossing joins two islands whose bridgeheads are at most
// `max_bridge_spans` apart. The Bali Strait is the charter's crossing.
const std = @import("std");
const colony = @import("colony.zig");
const terrain = @import("terrain.zig");
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

    /// The island across the bridge from `chart`, which must be one end.
    pub fn across(crossing: Crossing, chart: usize) usize {
        return if (crossing.charts[0] == chart) crossing.charts[1] else crossing.charts[0];
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
    if (!g.bridges[crossing]) return "Build the bridge first.";
    const source = crossings[crossing].across(destination);
    if (g.residents(source) == 0) return "No settlers are waiting to cross from that island.";
    if (g.freeLandingSpace(destination) == 0) return "There is no room for more settlers at the destination.";
    // Java's residents are everyone not counted elsewhere.
    if (source != 0) g.island_people[source - 1] -= 1;
    if (destination != 0) g.island_people[destination - 1] += 1;
    return null;
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
    try std.testing.expect(g.crossBridge(1, 0) == null);
    try std.testing.expectEqual(@as(u16, 5), g.residents(0));
    try std.testing.expectEqual(@as(u16, 3), g.residents(madura));
    try std.testing.expect(g.crossBridge(1, madura) == null);
    try std.testing.expectEqual(@as(u16, 4), g.residents(madura));
    try std.testing.expect(g.sendCargo(1, 0, .{ .grain = 4 }) == null);
    try std.testing.expectEqual(@as(u16, 4), g.stores[madura].grain);
    try std.testing.expect(g.sendCargo(1, madura, .{ .grain = 1 }) == null);
    try std.testing.expectEqual(@as(u16, 7), g.stores[0].grain);
    try std.testing.expectEqualStrings("Choose an island on that bridge.", g.sendCargo(1, 1, .{ .grain = 1 }).?);
}
