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
/// leg is within range and the straight course passes no other island.
pub fn withinRange(from: usize, to: usize) bool {
    return from < settlement_count and to < settlement_count and lanes[from][to];
}

/// Whether a leg is short enough and clear of other islands. Slow; the
/// results are baked into ferry_lanes.zig by `zig build bake-lanes`.
pub fn computeLane(from: usize, to: usize) bool {
    if (from == to or legs[from][to] > range_seconds) return false;
    const p = colony.worldTile(colony.quay(from), from);
    const q = colony.worldTile(colony.quay(to), to);
    const samples = 200;
    for (1..samples) |step| {
        const t = @as(f32, @floatFromInt(step)) / samples;
        const point = [2]f32{ p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t };
        for (0..settlement_count) |chart| {
            if (chart == from or chart == to) continue;
            const cell = colony.cellAt(chart, point) orelse continue;
            if (colony.depth(cell, chart) >= 0) return false;
        }
    }
    return true;
}

const lanes: [settlement_count][settlement_count]bool = blk: {
    var table: [settlement_count][settlement_count]bool = @splat(@splat(false));
    for (baked_lanes.lanes) |pair| {
        table[pair[0]][pair[1]] = true;
        table[pair[1]][pair[0]] = true;
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

test "the baked ferry lanes match the geography" {
    for (0..settlement_count) |from| {
        for (0..settlement_count) |to| try std.testing.expectEqual(computeLane(from, to), lanes[from][to]);
    }
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
