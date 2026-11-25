// The Bali Strait bridge and overland transfers.
const std = @import("std");
const colony = @import("colony.zig");
const terrain = @import("terrain.zig");
const Game = colony.Game;
const Cell = colony.Cell;
const Stores = colony.Stores;
const depth = colony.depth;
const geography = colony.geography;
const worldTile = colony.worldTile;

pub const bridgeheads = cells(terrain.bridgeheads);

pub const bridge_crew: u16 = 4;

pub const max_bridge_spans: u16 = 2;

fn bridgeSpans(start: [2]f32, end: [2]f32) u16 {
    const dx = end[0] - start[0];
    const dy = end[1] - start[1];
    return @intFromFloat(@ceil(@sqrt(dx * dx + dy * dy) / 48));
}

pub const bridge_spans = bridgeSpans(worldTile(bridgeheads[0], 0), worldTile(bridgeheads[1], 1));

pub const bridge_cost = Stores{ .timber = 2 * bridge_spans, .stone = 3 * bridge_spans };

// The closest land tiles on Bali and Lombok.
const bali_lombok_bridgeheads = cells(terrain.bali_lombok_bridgeheads);

fn cells(points: [2][2]u16) [2]Cell {
    return .{ .{ .x = points[0][0], .y = points[0][1] }, .{ .x = points[1][0], .y = points[1][1] } };
}

pub const bali_lombok_spans = bridgeSpans(worldTile(bali_lombok_bridgeheads[0], 1), worldTile(bali_lombok_bridgeheads[1], 2));

fn bridgeInRange(spans: u16) bool {
    return spans <= max_bridge_spans;
}

pub fn bridgeCargoLimit(g: *const Game, source: usize) Stores {
    const incoming = g.incomingCargo(1 - source);
    return g.loadingLimits(source, 1 - source, .{}, incoming);
}

pub fn sendCargo(g: *Game, source: usize, load: Stores) ?[:0]const u8 {
    if (!g.bridge) {
        if (g.mooredChart() != source) return "The ferry must be moored at the loading port.";
        return g.sendFerry(1 - source, 0, load);
    }
    if (load.empty()) return "Choose supplies to send.";
    if (!g.bridgeCargoLimit(source).includes(load)) return "There is not enough stock or room for this cargo.";
    g.stores[source].take(load);
    g.stores[1 - source].add(load);
    return null;
}

pub fn bridgeProblem(g: *const Game) ?[:0]const u8 {
    if (g.bridge) return "The bridge is already built.";
    if (!bridgeInRange(bridge_spans)) return "This crossing exceeds the bridge span limit.";
    if (!g.ferry.surveyed) return "Survey Bali before planning the crossing.";
    for (0..2) |chart| {
        if (g.residents(chart) < bridge_crew) return "Both islands need four resident settlers to build the bridge.";
        if (g.workforce(chart) == 0) return "Both islands need settlers able to work on the bridge.";
    }
    for (g.stores[0..2]) |stock| {
        if (stock.timber < bridge_cost.timber or stock.stone < bridge_cost.stone) return "Both islands must stockpile their share of timber and stone.";
    }
    return null;
}

pub fn buildBridge(g: *Game) ?[:0]const u8 {
    if (g.bridgeProblem()) |problem| return problem;
    for (g.stores[0..2]) |*stock| {
        stock.timber -= bridge_cost.timber;
        stock.stone -= bridge_cost.stone;
    }
    g.bridge = true;
    g.charter.housed_eight = true;
    return null;
}

pub fn crossBridge(g: *Game, destination_chart: usize) ?[:0]const u8 {
    if (!g.bridge) return "Build the bridge first.";
    if (g.residents(1 - destination_chart) == 0) return "No settlers are waiting to cross from that island.";
    if (g.freeLandingSpace(destination_chart) == 0) return "There is no room for more settlers at the destination.";
    if (destination_chart == 1) g.island_people[0] += 1 else g.island_people[0] -= 1;
    return null;
}

test "Java to Bali fits the bridge limit and every Bali to Lombok crossing exceeds it" {
    try std.testing.expectEqual(2, bridge_spans);
    try std.testing.expect(bridgeInRange(bridge_spans));
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
            try std.testing.expect(!bridgeInRange(bridgeSpans(worldTile(bali, 1), worldTile(lombok, 2))));
        }
    }
}
