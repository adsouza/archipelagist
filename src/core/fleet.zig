// Expedition ships: building, provisioning, sailing, and charting.
// These rules run on the Game aggregate because a voyage reserves berths,
// beds, and cargo space across islands in one step.
const std = @import("std");
const colony = @import("colony.zig");
const Game = colony.Game;
const Stores = colony.Stores;
const crossing_seconds = colony.crossing_seconds;
const dailyUse = colony.dailyUse;
const day_seconds = colony.day_seconds;
const geography = colony.geography;
const ocean = colony.ocean;
const quay = colony.quay;
const settlement_count = colony.settlement_count;

pub const ShipCost = struct { timber: u16, stone: u16, coins: u16 };

pub fn shipCost(ship: ocean.Ship) ShipCost {
    return switch (ship) {
        .none => .{ .timber = 0, .stone = 0, .coins = 0 },
        .brig => .{ .timber = 32, .stone = 6, .coins = 24 },
        .barque => .{ .timber = 48, .stone = 10, .coins = 35 },
    };
}

fn voyageRations(route: ocean.Route, crew: u16, passengers: u16) Stores {
    const crew_days: u16 = @intFromFloat(@ceil(route.provisionTime() / day_seconds));
    const passage_days: u16 = @intFromFloat(@ceil(route.leg_seconds / day_seconds));
    const amount = crew_days * dailyUse(crew) + passage_days * dailyUse(passengers) + route.reserve_per_supply;
    return .{ .grain = amount, .venison = amount, .fruit = amount, .water = amount };
}

pub fn expeditionRations(route: ocean.Route) u16 {
    return voyageRations(route, route.ship.crew(), 0).grain;
}

pub const dock_capacity = 2;

pub const max_expedition_ships = dock_capacity * settlement_count - 1;

pub const Vessel = struct {
    pub const Phase = enum(u8) { docked, outbound, homebound };

    ship: ocean.Ship = .none,
    chart: usize = 0,
    phase: Phase = .docked,
    elapsed: f32 = 0,
    passengers: u16 = 0,
    cargo: Stores = .{},
    return_provisioned: bool = false,

    pub fn berthChart(vessel: Vessel) usize {
        return if (vessel.phase == .homebound) 0 else vessel.chart;
    }

    pub fn carryingLoad(vessel: Vessel) bool {
        return vessel.passengers != 0 or !vessel.cargo.empty();
    }

    pub fn legSeconds(vessel: Vessel) f32 {
        return if (vessel.chart <= 1) crossing_seconds else ocean.routes[ocean.routeTo(vessel.chart).?].leg_seconds;
    }

    pub fn progress(vessel: Vessel) f32 {
        return switch (vessel.phase) {
            .docked => if (vessel.chart == 0) 0 else 1,
            .outbound => vessel.elapsed / vessel.legSeconds(),
            .homebound => 1 - vessel.elapsed / vessel.legSeconds(),
        };
    }
};

/// Expedition ships and the routes they have charted.
pub const Fleet = struct {
    vessels: [max_expedition_ships]Vessel = @splat(.{}),
    count: usize = 0,
    charted: [ocean.routes.len]bool = @splat(false),

    pub fn active(fleet: *const Fleet) []const Vessel {
        return fleet.vessels[0..fleet.count];
    }
};

pub fn vessels(g: *const Game) []const Vessel {
    return g.fleet.vessels[0..g.fleet.count];
}

pub fn hasBarque(g: *const Game) bool {
    for (g.vessels()) |vessel| {
        if (vessel.ship == .barque) return true;
    }
    return false;
}

pub fn berthsUsed(g: *const Game, chart: usize) usize {
    var occupied: usize = @intFromBool(g.ferryBerthChart() == chart);
    for (g.vessels()) |vessel| occupied += @intFromBool(vessel.berthChart() == chart);
    return occupied;
}

pub fn buildShip(g: *Game, chart: usize, ship: ocean.Ship) ?[:0]const u8 {
    if (!g.charterComplete()) return "Complete the island charter to open the shipyard.";
    if (!g.islandOpen(chart) or g.tileAt(chart, quay(chart)) != .port) return "Open a local dock before building ships.";
    if (ship == .none) return "Choose a hull to build.";
    if (ship == .barque and !g.fleet.charted[0]) return "Chart Lombok before building an ocean barque.";
    if (ocean.routeTo(chart)) |route| {
        if (!ship.canSail(ocean.routes[route])) return "This hull cannot make the crossing to Java.";
    }
    if (g.berthsUsed(chart) >= dock_capacity or g.fleet.count == g.fleet.vessels.len) return "The local dock has no free berth.";
    if (g.residents(chart) < ship.crew() or g.workforce(chart) == 0) return "The island needs enough healthy settlers to build this ship.";
    const cost = shipCost(ship);
    const local = &g.stores[chart];
    if (local.timber < cost.timber or local.stone < cost.stone or g.coins < cost.coins)
        return "Building this ship needs more local timber or stone, or more coins.";
    local.timber -= cost.timber;
    local.stone -= cost.stone;
    g.coins -= cost.coins;
    g.fleet.vessels[g.fleet.count] = .{ .ship = ship, .chart = chart };
    g.fleet.count += 1;
    return null;
}

pub fn oceanRations(g: *const Game, id: usize, index: usize, passengers: u16) Stores {
    return voyageRations(ocean.routes[index], g.fleet.vessels[id].ship.crew(), passengers);
}

pub fn surveyProblem(g: *const Game, id: usize, index: usize) ?[:0]const u8 {
    if (!g.charterComplete()) return "Complete the island charter to explore farther.";
    if (id >= g.fleet.count or index >= ocean.routes.len) return "Choose a ship and destination.";
    const vessel = g.fleet.vessels[id];
    if (vessel.phase != .docked or vessel.chart != 0) return "Bring this ship back to Java first.";
    if (g.fleet.charted[index]) return "This island is already on the chart.";
    const route = ocean.routes[index];
    for (g.vessels()) |other| {
        if (other.phase == .outbound and other.chart == route.chart) return "A ship is already surveying this island.";
    }
    if (g.ferry.surveying and g.ferry.destination == route.chart) return "The ferry is already surveying this island.";
    if (g.berthsUsed(route.chart) >= dock_capacity) return "The destination dock has no free berth.";
    if (!vessel.ship.canSail(route)) return "Build a ship that can make this crossing.";
    const rations = g.oceanRations(id, index, 0);
    if (rations.units() > vessel.ship.hold()) return "The ship cannot hold enough provisions for this voyage.";
    if (g.residents(0) < vessel.ship.crew() or g.workforce(0) == 0) return "Java needs enough healthy settlers to crew the expedition.";
    if (!g.stores[0].includes(rations)) return "Stock more grain, venison, fruit, and water before sailing.";
    return null;
}

pub fn launchExpedition(g: *Game, id: usize, index: usize) ?[:0]const u8 {
    if (g.surveyProblem(id, index)) |problem| return problem;
    g.stores[0].take(g.oceanRations(id, index, 0));
    const vessel = &g.fleet.vessels[id];
    vessel.chart = ocean.routes[index].chart;
    vessel.phase = .outbound;
    vessel.return_provisioned = true;
    return null;
}

pub fn oceanSettlerLimit(g: *const Game, id: usize, index: usize) u16 {
    const route = ocean.routes[index];
    if (!g.fleet.charted[index]) return 0;
    const ship = g.fleet.vessels[id].ship;
    var limit = @min(ship.passengerCapacity(), g.residents(0), g.freeLandingSpace(route.chart));
    while (limit > 0 and g.oceanRations(id, index, limit).units() > ship.hold()) limit -= 1;
    return limit;
}

pub fn oceanCargoLimit(g: *const Game, id: usize, index: usize, passengers: u16) Stores {
    const target = ocean.routes[index].chart;
    return g.loadingLimits(0, target, g.oceanRations(id, index, passengers), g.incomingCargo(target));
}

pub fn sendExpedition(g: *Game, id: usize, index: usize, passengers: u16, load: Stores) ?[:0]const u8 {
    if (id >= g.fleet.count or index >= ocean.routes.len) return "Choose a ship and destination.";
    const route = ocean.routes[index];
    if (!g.fleet.charted[index]) return "Survey the destination before loading the ship.";
    const vessel = &g.fleet.vessels[id];
    if (vessel.phase != .docked or vessel.chart != 0) return "Bring this ship back to Java first.";
    if (g.berthsUsed(route.chart) >= dock_capacity) return "The destination dock has no free berth.";
    const ship = vessel.ship;
    if (!ship.canSail(route)) return "Build a ship that can make this crossing.";
    if (g.residents(0) < ship.crew() or g.workforce(0) == 0) return "Java needs enough healthy settlers to crew this ship.";
    if (passengers > g.oceanSettlerLimit(id, index)) return "Choose a passenger count that fits this crossing.";
    if (passengers == 0 and load.empty()) return "Choose settlers or supplies to send.";
    const rations = g.oceanRations(id, index, passengers);
    if (rations.units() + load.units() > ship.hold()) return "Cargo and provisions exceed the ship's hold.";
    if (!g.stores[0].includes(rations)) return "Stock more grain, venison, fruit, and water for the passage.";
    if (!g.oceanCargoLimit(id, index, passengers).includes(load)) return "There is not enough stock or room for this cargo.";
    g.stores[0].take(rations);
    g.stores[0].take(load);
    vessel.chart = route.chart;
    vessel.phase = .outbound;
    vessel.return_provisioned = true;
    vessel.passengers = passengers;
    vessel.cargo = load;
    return null;
}

pub fn returnExpedition(g: *Game, id: usize) ?[:0]const u8 {
    if (g.isOver() or id >= g.fleet.count) return "Choose a ship docked away from Java.";
    const vessel = &g.fleet.vessels[id];
    if (vessel.phase != .docked or vessel.chart == 0) return "Choose a ship docked away from Java.";
    if (g.berthsUsed(0) >= dock_capacity) return "Java's dock has no free berth.";
    if (!vessel.return_provisioned) {
        const local = &g.stores[vessel.chart];
        const days: u16 = @intFromFloat(@ceil(vessel.legSeconds() / day_seconds));
        const units = days * dailyUse(vessel.ship.crew());
        const rations = Stores{ .grain = units, .venison = units, .fruit = units, .water = units };
        if (!local.includes(rations)) return "Stock more local grain, venison, fruit, and water for the crossing.";
        if (g.residents(vessel.chart) < vessel.ship.crew() or g.workforce(vessel.chart) == 0)
            return "The island needs enough healthy settlers to crew this ship.";
        local.take(rations);
    }
    vessel.return_provisioned = false;
    vessel.phase = .homebound;
    return null;
}

pub const ExpeditionEvent = enum { none, charted, delivered, returned };

pub fn advanceExpedition(g: *Game, id: usize, seconds: f32) ExpeditionEvent {
    if (g.isOver() or id >= g.fleet.count) return .none;
    const vessel = &g.fleet.vessels[id];
    if (vessel.phase == .docked) return .none;
    vessel.elapsed += seconds;
    if (vessel.elapsed < vessel.legSeconds()) return .none;
    vessel.elapsed = 0;
    const homebound = vessel.phase == .homebound;
    vessel.phase = .docked;
    if (homebound) {
        vessel.chart = 0;
        return .returned;
    }
    const chart = vessel.chart;
    if (vessel.carryingLoad()) {
        g.land(chart, vessel.passengers, vessel.cargo);
        vessel.passengers = 0;
        vessel.cargo = .{};
        return .delivered;
    }
    g.chartHarbor(chart);
    return .charted;
}
