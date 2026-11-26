// Expedition ships: building, provisioning, sailing, and charting.
// These rules run on the Game aggregate because a voyage reserves berths,
// beds, and cargo space across islands in one step.
const std = @import("std");
const colony = @import("colony.zig");
const Game = colony.Game;
const Stores = colony.Stores;
const dailyUse = colony.dailyUse;
const day_seconds = colony.day_seconds;
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

fn voyageRations(route: ocean.Route, crew: u16, passengers: u16) u16 {
    const crew_days: u16 = @intFromFloat(@ceil(route.provisionTime() / day_seconds));
    const passage_days: u16 = @intFromFloat(@ceil(route.leg_seconds / day_seconds));
    return crew_days * dailyUse(crew) + passage_days * dailyUse(passengers) + route.reserve_per_supply;
}

fn rations(amount: u16) Stores {
    return .{ .grain = amount, .venison = amount, .fruit = amount, .water = amount };
}

fn returnRations(seconds: f32, ship: ocean.Ship) u16 {
    const days: u16 = @intFromFloat(@ceil(seconds / day_seconds));
    return days * dailyUse(ship.crew());
}

pub fn expeditionRations(route: ocean.Route) u16 {
    return voyageRations(route, route.ship.crew(), 0);
}

pub const max_dock_capacity = 2;

pub const max_expedition_ships = max_dock_capacity * settlement_count - 1;

pub const Vessel = struct {
    pub const Phase = enum(u8) { docked, outbound, homebound };

    /// A commissioned ship keeps its hull's crew aboard, separate from passengers and residents.
    ship: ocean.Ship = .none,
    chart: usize = 0,
    phase: Phase = .docked,
    elapsed: f32 = 0,
    passengers: u16 = 0,
    cargo: Stores = .{},
    /// Units of each supply still aboard after any passage now under way is paid for.
    provisions: u8 = 0,
    /// The outbound passage charts `chart`. Any settlers and cargo aboard
    /// land once the harbor is charted.
    surveying: bool = false,
    /// The port that supplied the outward voyage and receives its return.
    origin: u8 = 0,

    pub fn berthChart(vessel: Vessel) usize {
        return if (vessel.phase == .homebound) vessel.origin else vessel.chart;
    }

    pub fn carryingLoad(vessel: Vessel) bool {
        return vessel.passengers != 0 or !vessel.cargo.empty();
    }

    pub fn legSeconds(vessel: Vessel) f32 {
        const route = ocean.passage(vessel.origin, vessel.chart) orelse return 0;
        return route.leg_seconds;
    }

    pub fn returnProvisions(vessel: Vessel) u16 {
        return returnRations(vessel.legSeconds(), vessel.ship);
    }

    pub fn outwardProvisions(vessel: Vessel) u16 {
        const route = ocean.passage(vessel.origin, vessel.chart) orelse return 0;
        return voyageRations(route, vessel.ship.crew(), vessel.passengers) - vessel.returnProvisions();
    }

    pub fn progress(vessel: Vessel) f32 {
        return switch (vessel.phase) {
            .docked => if (vessel.chart == 0 and vessel.origin == 0) 0 else 1,
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

/// Uncharted harbors can reserve their first berth for a survey.
pub fn berthCapacity(g: *const Game, chart: usize) usize {
    return if (g.hasLighthouse(chart)) max_dock_capacity else 1;
}

pub fn freeBerths(g: *const Game, chart: usize) usize {
    return g.berthCapacity(chart) -| g.berthsUsed(chart);
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
    if (g.freeBerths(chart) == 0 or g.fleet.count == g.fleet.vessels.len) return "The local dock has no free berth.";
    if (g.residents(chart) < ship.crew() or g.workforce(chart) == 0) return "The island needs enough healthy settlers to build this ship.";
    const cost = shipCost(ship);
    const local = g.store(chart);
    if (local.timber < cost.timber or local.stone < cost.stone or g.coins < cost.coins)
        return "Building this ship needs more local timber or stone, or more coins.";
    local.timber -= cost.timber;
    local.stone -= cost.stone;
    g.coins -= cost.coins;
    g.fleet.vessels[g.fleet.count] = .{ .ship = ship, .chart = chart };
    g.fleet.count += 1;
    return null;
}

pub fn expeditionPassage(g: *const Game, id: usize, index: usize) ?ocean.Route {
    if (id >= g.fleet.count or index >= ocean.destination_count) return null;
    const vessel = g.fleet.vessels[id];
    if (vessel.phase != .docked) return null;
    return ocean.passage(vessel.chart, ocean.destinationChart(index));
}

/// Full round-trip requirement before accounting for existing supplies.
pub fn oceanRations(g: *const Game, id: usize, index: usize, passengers: u16) Stores {
    const route = g.expeditionPassage(id, index) orelse return .{};
    return rations(voyageRations(route, g.fleet.vessels[id].ship.crew(), passengers));
}

pub const ExpeditionProvisions = struct {
    aboard: u16 = 0,
    required: u16 = 0,
    outward: u16 = 0,
    one_way: bool = false,

    pub fn fromPort(plan: ExpeditionProvisions) u16 {
        return plan.required -| plan.aboard;
    }

    pub fn loaded(plan: ExpeditionProvisions) u16 {
        return @max(plan.aboard, plan.required);
    }

    pub fn holdUnits(plan: ExpeditionProvisions) u32 {
        return rations(plan.loaded()).units();
    }
};

fn provisionPlan(vessel: Vessel, route: ocean.Route, passengers: u16, stock: Stores) ExpeditionProvisions {
    const round_trip = voyageRations(route, vessel.ship.crew(), passengers);
    const outward = round_trip - returnRations(route.leg_seconds, vessel.ship);
    var plan = ExpeditionProvisions{ .aboard = vessel.provisions, .required = round_trip, .outward = outward };
    // A ship carrying reserves can make an onward crossing even when the
    // departure harbor cannot outfit it for both legs.
    if (plan.aboard != 0 and (plan.holdUnits() > vessel.ship.hold() or !stock.includes(rations(plan.fromPort())))) {
        plan.required = outward;
        plan.one_way = true;
    }
    return plan;
}

pub fn oceanProvisioning(g: *const Game, id: usize, index: usize, passengers: u16) ExpeditionProvisions {
    const route = g.expeditionPassage(id, index) orelse return .{};
    const vessel = g.fleet.vessels[id];
    return provisionPlan(vessel, route, passengers, g.stockOf(vessel.chart));
}

/// Check the departure, range, berth, and local provisions before opening the manifest.
pub fn expeditionProblem(g: *const Game, id: usize, index: usize, survey: bool) ?[:0]const u8 {
    if (!g.charterComplete()) return "Complete the island charter to explore farther.";
    if (id >= g.fleet.count or index >= ocean.destination_count) return "Choose a ship and destination.";
    const vessel = g.fleet.vessels[id];
    if (vessel.phase != .docked) return "Wait until the expedition ship is moored.";
    const source = vessel.chart;
    const target = ocean.destinationChart(index);
    if (source == target) return "Choose another harbor.";
    if (survey and g.islandOpen(target)) return "This island is already on the chart.";
    if (!survey and !g.islandOpen(target)) return "Survey the destination before loading the ship.";
    if (survey and g.beingSurveyed(target)) return "A ship is already surveying this island.";
    const route = g.expeditionPassage(id, index) orelse return "The destination is beyond this voyage's range.";
    if (!vessel.ship.canSail(route)) return "Build a ship that can make this crossing.";
    if (g.freeBerths(target) == 0) return "The destination dock has no free berth.";
    const stock = g.stockOf(source);
    const plan = provisionPlan(vessel, route, 0, stock);
    if (plan.holdUnits() > vessel.ship.hold()) return "The ship cannot hold enough provisions for this voyage.";
    if (!stock.includes(rations(plan.fromPort()))) return "Stock more local grain, venison, fruit, and water before sailing.";
    return null;
}

pub fn surveyProblem(g: *const Game, id: usize, index: usize) ?[:0]const u8 {
    return g.expeditionProblem(id, index, true);
}

fn settlerLimit(g: *const Game, id: usize, index: usize, beds: u16) u16 {
    const route = g.expeditionPassage(id, index) orelse return 0;
    const vessel = g.fleet.vessels[id];
    const ship = vessel.ship;
    var limit = @min(ship.passengerCapacity(), g.residents(vessel.chart), beds);
    const stock = g.stockOf(vessel.chart);
    while (limit > 0) : (limit -= 1) {
        const plan = provisionPlan(vessel, route, limit, stock);
        if (plan.holdUnits() <= ship.hold() and stock.includes(rations(plan.fromPort()))) break;
    }
    return limit;
}

pub fn surveySettlerLimit(g: *const Game, id: usize, index: usize) u16 {
    if (g.surveyProblem(id, index) != null) return 0;
    return settlerLimit(g, id, index, colony.camp_capacity);
}

pub fn oceanSettlerLimit(g: *const Game, id: usize, index: usize) u16 {
    if (index >= ocean.destination_count) return 0;
    const chart = ocean.destinationChart(index);
    if (!g.islandOpen(chart)) return 0;
    return settlerLimit(g, id, index, g.freeLandingSpace(chart));
}

pub fn oceanCargoLimit(g: *const Game, id: usize, index: usize, passengers: u16) Stores {
    const route = g.expeditionPassage(id, index) orelse return .{};
    const vessel = g.fleet.vessels[id];
    const plan = provisionPlan(vessel, route, passengers, g.stockOf(vessel.chart));
    return g.loadingLimits(vessel.chart, route.chart, rations(plan.fromPort()), g.incomingCargo(route.chart));
}

pub fn launchExpedition(g: *Game, id: usize, index: usize, passengers: u16, load: Stores) ?[:0]const u8 {
    if (g.surveyProblem(id, index)) |problem| return problem;
    if (passengers > colony.camp_capacity) return "A new camp has room for four settlers.";
    return depart(g, id, index, passengers, load, true);
}

pub fn sendExpedition(g: *Game, id: usize, index: usize, passengers: u16, load: Stores) ?[:0]const u8 {
    if (g.expeditionProblem(id, index, false)) |problem| return problem;
    return depart(g, id, index, passengers, load, false);
}

fn depart(g: *Game, id: usize, index: usize, passengers: u16, load: Stores, survey: bool) ?[:0]const u8 {
    const route = g.expeditionPassage(id, index).?;
    const vessel = &g.fleet.vessels[id];
    const source = vessel.chart;
    const ship = vessel.ship;
    const beds = if (survey) colony.camp_capacity else g.freeLandingSpace(route.chart);
    if (passengers > @min(ship.passengerCapacity(), g.residents(source), beds))
        return "Choose a passenger count that fits this crossing.";
    const stock = g.stockOf(source);
    const plan = provisionPlan(vessel.*, route, passengers, stock);
    if (plan.holdUnits() + load.units() > ship.hold()) return "Cargo and provisions exceed the ship's hold.";
    const top_up = rations(plan.fromPort());
    if (!stock.includes(top_up)) return "Stock more local grain, venison, fruit, and water for the passage.";
    if (!g.oceanCargoLimit(id, index, passengers).includes(load)) return "There is not enough stock or room for this cargo.";

    const local = g.store(source);
    local.take(top_up);
    local.take(load);
    if (source != 0) g.island_people[source - 1] -= passengers;
    vessel.origin = @intCast(source);
    vessel.chart = route.chart;
    vessel.phase = .outbound;
    vessel.provisions = @intCast(plan.loaded() - plan.outward);
    vessel.passengers = passengers;
    vessel.cargo = load;
    vessel.surveying = survey;
    return null;
}

pub fn returnExpeditionProblem(g: *const Game, id: usize) ?[:0]const u8 {
    if (g.isOver() or id >= g.fleet.count) return "Choose a moored expedition ship.";
    const vessel = g.fleet.vessels[id];
    if (vessel.phase != .docked or vessel.chart == vessel.origin) return "Choose a moored ship away from its departure harbor.";
    const route = ocean.passage(vessel.chart, vessel.origin) orelse return "The return harbor is beyond this ship's range.";
    if (!vessel.ship.canSail(route)) return "The return harbor is beyond this ship's range.";
    if (g.freeBerths(vessel.origin) == 0)
        return if (vessel.origin == 0) "Java's dock has no free berth." else "The return harbor has no free berth.";
    const top_up = returnRations(route.leg_seconds, vessel.ship) -| vessel.provisions;
    if (!g.stockOf(vessel.chart).includes(rations(top_up))) return "Stock more local grain, venison, fruit, and water for the crossing.";
    return null;
}

pub fn returnExpedition(g: *Game, id: usize) ?[:0]const u8 {
    if (g.returnExpeditionProblem(id)) |problem| return problem;
    const vessel = &g.fleet.vessels[id];
    const required = vessel.returnProvisions();
    g.store(vessel.chart).take(rations(required -| vessel.provisions));
    vessel.provisions = @intCast(vessel.provisions -| required);
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
        vessel.chart = vessel.origin;
        vessel.origin = 0;
        return .returned;
    }
    const chart = vessel.chart;
    const surveyed = vessel.surveying;
    if (surveyed) g.chartHarbor(chart);
    g.land(chart, vessel.passengers, vessel.cargo);
    vessel.passengers = 0;
    vessel.cargo = .{};
    vessel.surveying = false;
    return if (surveyed) .charted else .delivered;
}
