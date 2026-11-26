const std = @import("std");
const roads = @import("roads.zig");
const terrain = @import("terrain.zig");
pub const fleet = @import("fleet.zig");
pub const ferry = @import("ferry.zig");
pub const bridge = @import("bridge.zig");
pub const charter = @import("charter.zig");
pub const ocean = @import("expedition.zig");
pub const geography = @import("geography.zig");
pub const Kind = enum(u4) { empty, port, cottage, grove, farm, light, road, quarry, lodge, well };
pub const Tile = packed struct(u8) {
    kind: Kind = .empty,
    harvest_state: u4 = 0,
};
pub const settlement_count = geography.settlement_count;

// Types and rules that live in their own modules.
pub const dock_capacity = fleet.dock_capacity;
pub const max_expedition_ships = fleet.max_expedition_ships;
pub const Vessel = fleet.Vessel;
pub const Fleet = fleet.Fleet;
pub const shipCost = fleet.shipCost;
pub const expeditionRations = fleet.expeditionRations;
pub const crossing_seconds = ferry.crossing_seconds;
pub const ferry_capacity = ferry.ferry_capacity;
pub const ferry_hold = ferry.ferry_hold;
pub const camp_capacity = ferry.camp_capacity;
pub const ferryRations = ferry.ferryRations;
pub const Ferry = ferry.Ferry;
pub const bridgeheads = bridge.bridgeheads;
pub const Crossing = bridge.Crossing;
pub const crossings = bridge.crossings;
pub const strait = bridge.strait;
pub const bridge_crew = bridge.bridge_crew;
pub const max_bridge_spans = bridge.max_bridge_spans;
pub const bridge_spans = bridge.bridge_spans;
pub const bridge_cost = bridge.bridge_cost;
pub const bali_lombok_spans = bridge.bali_lombok_spans;
pub const charter_fleet_size = charter.charter_fleet_size;
pub const Goal = charter.Goal;
pub const Charter = charter.Charter;

pub const chart_names = geography.names[0..settlement_count];
pub const names = [_][:0]const u8{ "Meadow", "Harbor house", "Cottage", "Woodlot", "Grain farm", "Lighthouse", "Road", "Quarry", "Hunting lodge", "Well" };
pub const costs = [_]u16{ 0, 0, 6, 5, 8, 24, 1, 6, 6, 5 };
pub const quarry_yield: u16 = 3;
pub const fruit_yield: u16 = 3;
pub const weakness_limit: u8 = 6;
pub const scurvy_days: u8 = 7;
pub const well_yield: u16 = 4;
pub const well_stone: u16 = 2;
pub const Cell = geography.Cell;

pub const harvest_capacity: u4 = 12;
const harvest_yield: u16 = 3;
const HarvestStatus = struct { stock: u4, days_to_recover: u4 };

fn recoveryDays(kind: Kind) u4 {
    return switch (kind) {
        .grove => 3,
        .lodge => 2,
        else => 0,
    };
}

pub fn validHarvestState(kind: Kind, state: u4) bool {
    const days = recoveryDays(kind);
    return state == 0 or (days > 0 and state < harvest_capacity + days);
}

// Active sites store the amount harvested. Values from capacity onward track days of regrowth.
fn describeHarvest(state: u4, days: u4) HarvestStatus {
    if (state < harvest_capacity) return .{ .stock = harvest_capacity - state, .days_to_recover = 0 };
    const recovering_for = state - harvest_capacity;
    return .{ .stock = recovering_for * (harvest_capacity / days), .days_to_recover = days - recovering_for };
}

pub fn waterCapacity(chart: usize) u16 {
    return @intCast(well_yield * @min(10, 3 + geography.land_counts[chart] / 1000));
}

pub fn hash(x: usize, y: usize, chart: usize) usize {
    var n: u32 = @intCast(x * 3701 + y * 191 + chart * 3571 + 31);
    n = (n ^ (n >> 15)) *% 2246822519;
    return n ^ (n >> 13);
}
pub fn depth(p: Cell, chart: usize) f32 {
    return geography.depth(p.x, p.y, chart);
}

pub fn quay(chart: usize) Cell {
    return geography.grids[chart].quay;
}



pub const Site = enum(u2) { plain, outcrop, deer, fruit };

/// The resource site on a tile, from the baked terrain.
pub fn site(p: Cell, chart: usize) Site {
    return terrainSite(terrain.rows[chart][geography.grids[chart].index(p)]);
}

/// Whether a tile carries pine forest, from the baked terrain.
pub fn forest(p: Cell, chart: usize) bool {
    return terrain.rows[chart][geography.grids[chart].index(p)] & 4 != 0;
}

fn terrainSite(code: u8) Site {
    return @enumFromInt(@as(u2, @truncate(code)));
}




pub fn wellSite(p: Cell, chart: usize) bool {
    return depth(p, chart) >= 0.20 and !forest(p, chart) and site(p, chart) == .plain;
}

/// The most road tiles a new colony should have to lay to reach a resource
/// site from its harbor. Java's start must be cheaper still, because the
/// opening stone pays for every road until a quarry is running.
pub const site_road_budget: u16 = 6;
pub const opening_road_budget: u16 = 3;

/// The road budget that counts toward an island's resource supply.
pub fn roadBudget(chart: usize) u16 {
    return if (chart == 0) opening_road_budget else site_road_budget;
}

/// How many sites of a kind an island must offer within its road budget.
/// The starting island carries the whole early game, so it needs more.
pub fn requiredSites(chart: usize, wanted: Site) usize {
    if (chart != 0) return if (wanted == .plain) 0 else 2;
    return switch (wanted) {
        .plain => 0,
        .outcrop => 4,
        .deer => 3,
        .fruit => 2,
    };
}

/// Resource sites ranked by the road tiles needed to join them to the harbor.
pub const ResourceSites = struct {
    pub const capacity = 32;
    cells: [capacity]Cell = undefined,
    roads: [capacity]u16 = undefined,
    len: usize = 0,

    pub fn slice(sites: *const ResourceSites) []const Cell {
        return sites.cells[0..sites.len];
    }

    /// Keeps the cheapest `capacity` sites, cheapest first.
    fn offer(sites: *ResourceSites, cell: Cell, cost: u16) void {
        if (sites.len == capacity and sites.roads[capacity - 1] <= cost) return;
        var at = @min(sites.len, capacity - 1);
        while (at > 0 and sites.roads[at - 1] > cost) : (at -= 1) {
            sites.cells[at] = sites.cells[at - 1];
            sites.roads[at] = sites.roads[at - 1];
        }
        sites.cells[at] = cell;
        sites.roads[at] = cost;
        sites.len = @min(sites.len + 1, capacity);
    }
};

/// Producers that deliver only when settlers can walk to them from the harbor.
pub fn needsHarbor(k: Kind) bool {
    return k == .quarry or k == .grove or k == .lodge;
}

pub const day_seconds: f32 = 7;

pub fn dailyUse(people: u16) u16 {
    return people / 2 + people % 2;
}

pub const food_fields = .{ "grain", "venison", "fruit" };
pub const store_fields = .{ "timber", "stone", "grain", "venison", "fruit", "water" };
pub const Stores = struct {
    timber: u16 = 0,
    stone: u16 = 0,
    grain: u16 = 0,
    venison: u16 = 0,
    fruit: u16 = 0,
    water: u16 = 0,

    pub fn units(stores: Stores) u32 {
        var total: u32 = 0;
        inline for (store_fields) |field| total += @field(stores, field);
        return total;
    }

    pub fn empty(stores: Stores) bool {
        return stores.units() == 0;
    }

    pub fn includes(stores: Stores, load: Stores) bool {
        inline for (store_fields) |field| {
            if (@field(stores, field) < @field(load, field)) return false;
        }
        return true;
    }

    pub fn take(stores: *Stores, load: Stores) void {
        inline for (store_fields) |field| @field(stores, field) -= @field(load, field);
    }

    pub fn add(stores: *Stores, load: Stores) void {
        inline for (store_fields) |field| @field(stores, field) += @field(load, field);
    }
};
pub const starting_stores = Stores{ .timber = 22, .stone = 8, .grain = 12, .venison = 10, .fruit = 10, .water = 20 };

pub const Diet = struct {
    missed_grain: bool = false,
    meat_deficit: u8 = 0,
    days_without_fruit: u8 = 0,
};
pub const tile_width: f32 = 31;
pub const tile_height: f32 = 16;
pub fn localTile(p: Cell) [2]f32 {
    const x: f32 = @floatFromInt(p.x);
    const y: f32 = @floatFromInt(p.y);
    return .{ (x - y) * tile_width, (x + y) * tile_height };
}

/// The tile of a chart under a world point, if the point is on its grid.
pub fn cellAt(chart: usize, world: [2]f32) ?Cell {
    const grid = geography.grids[chart];
    const scale = geography.tile_scale;
    const dx = (world[0] - grid.origin[0]) / scale / tile_width;
    const dy = (world[1] - grid.origin[1]) / scale / tile_height;
    const x = @round((dx + dy) / 2);
    const y = @round((dy - dx) / 2);
    if (!(x >= 0 and y >= 0 and x < @as(f32, @floatFromInt(grid.width)) and y < @as(f32, @floatFromInt(grid.height)))) return null;
    return .{ .x = @intFromFloat(x), .y = @intFromFloat(y) };
}

pub fn worldTile(p: Cell, chart: usize) [2]f32 {
    const pt = localTile(p);
    const origin = geography.grids[chart].origin;
    const scale = geography.tile_scale;
    return .{ origin[0] + pt[0] * scale, origin[1] + pt[1] * scale };
}

// The closest land tiles on Bali and Lombok.

/// The aggregate root. Islands, the ferry, the fleet, and the charter share
/// one consistency boundary so a departure can reserve berths, beds, and
/// cargo and debit supplies in one operation.
pub const Game = struct {
    tiles: [geography.tile_count]Tile = @splat(.{}),
    stores: [settlement_count]Stores = .{starting_stores} ++ @as([settlement_count - 1]Stores, @splat(.{})),
    diets: [settlement_count]Diet = @splat(.{}),
    bridges: bridge.Bridges = @splat(false),
    /// Settlers out on a bridge, between islands.
    walkers: bridge.Walkers = .{},
    coins: u16 = 8,
    people: u16 = 2,
    island_people: [settlement_count - 1]u16 = @splat(0),
    founded: [settlement_count - geography.borneo]bool = @splat(false),
    day: u32 = 1,
    /// Game seconds elapsed in the current day, always in [0, day_seconds).
    day_time: f32 = 0,
    ferry: Ferry = .{},
    fleet: Fleet = .{},
    charter: Charter = .{},

    // fleet.zig
    pub const vessels = fleet.vessels;
    pub const hasBarque = fleet.hasBarque;
    pub const berthsUsed = fleet.berthsUsed;
    pub const buildShip = fleet.buildShip;
    pub const oceanRations = fleet.oceanRations;
    pub const surveyProblem = fleet.surveyProblem;
    pub const launchExpedition = fleet.launchExpedition;
    pub const oceanSettlerLimit = fleet.oceanSettlerLimit;
    pub const surveySettlerLimit = fleet.surveySettlerLimit;
    pub const oceanCargoLimit = fleet.oceanCargoLimit;
    pub const sendExpedition = fleet.sendExpedition;
    pub const returnExpedition = fleet.returnExpedition;
    pub const ExpeditionEvent = fleet.ExpeditionEvent;
    pub const advanceExpedition = fleet.advanceExpedition;
    // ferry.zig
    pub const ferryBerthChart = ferry.ferryBerthChart;
    pub const advanceShip = ferry.advanceShip;
    pub const mooredChart = ferry.mooredChart;
    pub const ferryRouteProblem = ferry.ferryRouteProblem;
    pub const ferryLimit = ferry.ferryLimit;
    pub const ferrySurveyLimit = ferry.ferrySurveyLimit;
    pub const ferryBoardingLimit = ferry.ferryBoardingLimit;
    pub const ferryProvisions = ferry.ferryProvisions;
    pub const ferryCampSupplies = ferry.ferryCampSupplies;
    pub const ferrySettlers = ferry.ferrySettlers;
    pub const sendFerry = ferry.sendFerry;
    pub const sailFerry = ferry.sailFerry;
    pub const ferryCargoLimit = ferry.ferryCargoLimit;
    pub const ferrySurveyProblem = ferry.ferrySurveyProblem;
    pub const surveyByFerry = ferry.surveyByFerry;
    // bridge.zig
    pub const bridgeCargoLimit = bridge.bridgeCargoLimit;
    pub const sendCargo = bridge.sendCargo;
    pub const bridgeProblem = bridge.bridgeProblem;
    pub const buildBridge = bridge.buildBridge;
    pub const crossBridge = bridge.crossBridge;
    pub const walkingTo = bridge.walkingTo;
    pub const advanceWalkers = bridge.advanceWalkers;
    pub const hasBridge = bridge.hasBridge;
    pub const footWalk = bridge.footWalk;
    pub const footpathProblem = bridge.footpathProblem;
    pub const bridgeRoadReaches = bridge.bridgeRoadReaches;
    // charter.zig
    pub const charterComplete = charter.charterComplete;
    pub const hasFounded = charter.hasFounded;
    pub const nextGoals = charter.nextGoals;

    pub fn init() Game {
        var g = Game{};
        g.place(0, &terrain.starting_layout);
        return g;
    }

    /// Lay out baked buildings and roads. Roads only go on open tiles.
    fn place(g: *Game, chart: usize, layout: []const terrain.Placement) void {
        for (layout) |item| {
            const cell = Cell{ .x = item.x, .y = item.y };
            const kind = std.enums.fromInt(Kind, item.kind).?;
            if (kind == .road and g.tileAt(chart, cell) != .empty) continue;
            g.setTile(chart, cell, kind);
        }
    }

    pub fn tilesOn(g: *const Game, chart: usize) []const Tile {
        const grid = geography.grids[chart];
        return g.tiles[grid.offset..][0..grid.area()];
    }

    pub fn tileAt(g: *const Game, chart: usize, p: Cell) Kind {
        return g.tiles[tileIndex(chart, p)].kind;
    }

    pub fn setTile(g: *Game, chart: usize, p: Cell, kind: Kind) void {
        const index = tileIndex(chart, p);
        if (g.tiles[index].kind != kind) g.tiles[index] = .{ .kind = kind };
    }

    pub fn harvestStatus(g: *const Game, chart: usize, p: Cell) ?HarvestStatus {
        const tile = g.tiles[tileIndex(chart, p)];
        const days = recoveryDays(tile.kind);
        return if (days > 0) describeHarvest(tile.harvest_state, days) else null;
    }

    fn tileIndex(chart: usize, p: Cell) usize {
        const grid = geography.grids[chart];
        return grid.offset + grid.index(p);
    }

    pub fn countOn(g: *const Game, chart: usize, k: Kind) u16 {
        var total: u16 = 0;
        for (g.tilesOn(chart)) |tile| {
            if (tile.kind == k) total += 1;
        }
        return total;
    }

    /// Buildings of a kind that settlers can reach from the harbor.
    pub fn connectedCount(g: *const Game, chart: usize, k: Kind, walk: *const roads.Walk) u16 {
        var total: u16 = 0;
        for (g.tilesOn(chart), 0..) |tile, i| {
            if (tile.kind == k and walk.seen.isSet(i)) total += 1;
        }
        return total;
    }

    /// Whether settlers can walk from the harbor to this tile.
    pub fn connected(g: *const Game, chart: usize, p: Cell) bool {
        return g.footWalk(chart).contains(p);
    }

    /// The shortest run of empty tiles a road must cover so that a building on
    /// `target` joins the tiles settlers already reach from the harbor, listed
    /// from the harbor side. Null when no land path exists or `out` is too short.
    pub fn roadPath(g: *const Game, chart: usize, target: Cell, out: []Cell) ?[]Cell {
        const walk = g.footWalk(chart);
        return g.roadPathFrom(chart, &walk, target, out);
    }

    /// The road tiles that would join a bridge's end on `chart` to that
    /// island's own harbor, the bridgehead included when settlers can't
    /// already stand on it. Empty once the harbor's roads reach the bridge.
    pub fn bridgeRoadPath(g: *const Game, crossing: usize, chart: usize, out: []Cell) ?[]Cell {
        const head = bridge.crossings[crossing].headOn(chart);
        const walk = roads.Walk.fromPort(g.tilesOn(chart), chart);
        if (walk.contains(head)) return out[0..0];
        const path = g.roadPathFrom(chart, &walk, head, out) orelse return null;
        // Settlers stand on features and roads, so plain ground needs paving.
        if (g.tileAt(chart, head) != .empty or site(head, chart) != .plain or forest(head, chart)) return path;
        if (path.len == out.len) return null;
        out[path.len] = head;
        return out[0 .. path.len + 1];
    }

    fn roadPathFrom(g: *const Game, chart: usize, walk: *const roads.Walk, target: Cell, out: []Cell) ?[]Cell {
        const grid = geography.grids[chart];
        if (!grid.contains(target) or depth(target, chart) < 0) return null;
        const tiles = g.tilesOn(chart);
        if (walk.contains(target)) return out[0..0];
        const none = std.math.maxInt(u32);
        var from: [geography.max_grid_area]u32 = undefined;
        var queue: [geography.max_grid_area]u32 = undefined;
        @memset(from[0..grid.area()], none);
        var head: usize = 0;
        var tail: usize = 0;
        const start = grid.index(target);
        from[start] = @intCast(start);
        queue[tail] = @intCast(start);
        tail += 1;
        while (head < tail) : (head += 1) {
            const at = queue[head];
            if (walk.seen.isSet(at)) {
                var len: usize = 0;
                var step = from[at];
                while (step != start) : (step = from[step]) {
                    if (len == out.len) return null;
                    out[len] = grid.cell(step);
                    len += 1;
                }
                return out[0..len];
            }
            for (roads.directions) |direction| {
                const next = roads.neighbor(grid.cell(at), direction, grid) orelse continue;
                const i = grid.index(next);
                if (from[i] != none or depth(next, chart) < 0) continue;
                // Roads can't replace buildings or fruit trees the walk hasn't reached.
                if (!walk.seen.isSet(i) and (tiles[i].kind != .empty or site(next, chart) == .fruit)) continue;
                from[i] = at;
                queue[tail] = @intCast(i);
                tail += 1;
            }
        }
        return null;
    }

    /// Road tiles needed to join each tile of an island to the tiles settlers
    /// already reach from the harbor, by the same rules as `roadPath`: zero
    /// for reached tiles, null where no road can go.
    pub fn roadCosts(g: *const Game, chart: usize, costs_out: *[geography.max_grid_area]?u16) void {
        const grid = geography.grids[chart];
        const tiles = g.tilesOn(chart);
        const walk = g.footWalk(chart);
        var queue: [geography.max_grid_area]u32 = undefined;
        var head: usize = 0;
        var tail: usize = 0;
        for (0..grid.area()) |i| {
            costs_out[i] = null;
            if (!walk.seen.isSet(i)) continue;
            costs_out[i] = 0;
            queue[tail] = @intCast(i);
            tail += 1;
        }
        while (head < tail) : (head += 1) {
            const at = queue[head];
            for (roads.directions) |direction| {
                const next = roads.neighbor(grid.cell(at), direction, grid) orelse continue;
                const i = grid.index(next);
                if (costs_out[i] != null or depth(next, chart) < 0) continue;
                if (tiles[i].kind != .empty or site(next, chart) == .fruit) continue;
                costs_out[i] = costs_out[at].? + 1;
                queue[tail] = @intCast(i);
                tail += 1;
            }
        }
    }

    /// The empty sites of a kind whose roads to the harbor fit within `budget`.
    /// A site's cost is the road up to, but not on, the site itself.
    pub fn resourceSites(g: *const Game, chart: usize, wanted: Site, budget: u16) ResourceSites {
        var road_costs: [geography.max_grid_area]?u16 = undefined;
        g.roadCosts(chart, &road_costs);
        const grid = geography.grids[chart];
        const tiles = g.tilesOn(chart);
        var sites = ResourceSites{};
        for (0..grid.area()) |i| {
            const cell = grid.cell(i);
            if (tiles[i].kind != .empty or depth(cell, chart) < 0 or site(cell, chart) != wanted) continue;
            var cost: ?u16 = if (road_costs[i] == 0) 0 else null;
            for (roads.directions) |direction| {
                const next = roads.neighbor(cell, direction, grid) orelse continue;
                const reach = road_costs[grid.index(next)] orelse continue;
                cost = if (cost) |known| @min(known, reach) else reach;
            }
            if (cost) |roads_needed| {
                if (roads_needed <= budget) sites.offer(cell, roads_needed);
            }
        }
        return sites;
    }

    /// Test support: lays free road so a building on `target` joins the harbor.
    pub fn paveTo(g: *Game, chart: usize, target: Cell) void {
        var buffer: [geography.max_grid_area]Cell = undefined;
        const path = g.roadPath(chart, target, &buffer) orelse unreachable;
        for (path) |cell| g.tiles[tileIndex(chart, cell)] = .{ .kind = .road };
    }

    /// Test support: lays free road from both harbors onto a bridge's ends.
    pub fn paveBridge(g: *Game, crossing: usize) void {
        var buffer: [geography.max_grid_area]Cell = undefined;
        for (bridge.crossings[crossing].charts) |chart| {
            const path = g.bridgeRoadPath(crossing, chart, &buffer) orelse unreachable;
            for (path) |cell| g.tiles[tileIndex(chart, cell)] = .{ .kind = .road };
        }
    }

    pub fn count(g: *const Game, k: Kind) u16 {
        var total: u16 = 0;
        for (0..settlement_count) |chart| total += g.countOn(chart, k);
        return total;
    }



    pub fn residents(g: *const Game, chart: usize) u16 {
        if (chart != 0) return g.island_people[chart - 1];
        return g.people - @as(u16, @intCast(g.awayFromJava()));
    }

    pub fn awayFromJava(g: *const Game) u32 {
        var away: u32 = g.ferry.passengers;
        for (g.vessels()) |vessel| away += vessel.passengers;
        away += @intCast(g.walkers.count);
        for (g.island_people) |population| away += population;
        return away;
    }

    pub fn housing(g: *const Game, chart: usize) u16 {
        var space: u16 = 0;
        for (g.tilesOn(chart)) |tile| {
            if (tile.kind == .cottage) space +|= 4;
        }
        return space;
    }

    /// Where the ferry is carrying settlers and cargo, if it is under way.
    pub fn voyageDestination(g: *const Game) ?usize {
        if (g.ferry.moored() != null) return null;
        return g.ferry.destination;
    }

    /// A survey is under way to this uncharted harbor.
    pub fn beingSurveyed(g: *const Game, chart: usize) bool {
        if (g.ferry.surveying and g.ferry.destination == chart) return true;
        for (g.vessels()) |vessel| {
            if (vessel.phase == .outbound and vessel.surveying and vessel.chart == chart) return true;
        }
        return false;
    }

    /// Put arriving settlers and cargo ashore.
    pub fn land(g: *Game, chart: usize, settlers: u16, cargo: Stores) void {
        if (chart != 0) g.island_people[chart - 1] += settlers;
        if (settlers > 0 and chart >= geography.borneo) g.founded[chart - geography.borneo] = true;
        g.stores[chart].add(cargo);
    }

    /// Record a surveyed harbor on the chart and open its port.
    pub fn chartHarbor(g: *Game, chart: usize) void {
        if (chart == 1) g.ferry.surveyed = true else g.fleet.charted[ocean.routeTo(chart).?] = true;
        g.openPort(chart);
    }

    pub fn islandOpen(g: *const Game, chart: usize) bool {
        if (chart == 0) return true;
        if (chart == 1) return g.ferry.surveyed;
        if (chart >= settlement_count) return false;
        return g.fleet.charted[ocean.routeTo(chart).?];
    }

    pub fn openPort(g: *Game, chart: usize) void {
        g.place(chart, terrain.port_layouts[chart]);
    }

    pub fn landingCapacity(g: *const Game, chart: usize) u16 {
        const camp = if (chart != 0 and (g.islandOpen(chart) or g.beingSurveyed(chart))) camp_capacity else 0;
        return @max(camp, g.housing(chart));
    }

    pub fn reservedBeds(g: *const Game, chart: usize) u16 {
        var total = if (g.voyageDestination() == chart) g.ferry.passengers else 0;
        for (g.vessels()) |vessel| {
            if (vessel.phase == .outbound and vessel.chart == chart) total +|= vessel.passengers;
        }
        return total +| g.walkingTo(chart);
    }

    pub fn incomingCargo(g: *const Game, chart: usize) Stores {
        var stock = if (g.voyageDestination() == chart) g.ferry.cargo else Stores{};
        for (g.vessels()) |vessel| {
            if (vessel.phase != .outbound or vessel.chart != chart) continue;
            inline for (store_fields) |name| @field(stock, name) +|= @field(vessel.cargo, name);
        }
        return stock;
    }

    pub fn freeBeds(g: *const Game, chart: usize) u16 {
        return g.housing(chart) -| (g.residents(chart) +| g.reservedBeds(chart));
    }

    pub fn freeLandingSpace(g: *const Game, chart: usize) u16 {
        return g.landingCapacity(chart) -| (g.residents(chart) +| g.reservedBeds(chart));
    }

    pub fn dailyDemand(g: *const Game, chart: usize) u16 {
        return dailyUse(g.residents(chart));
    }

    pub fn isOver(g: *const Game) bool {
        return g.people == 0;
    }

    pub fn workforce(g: *const Game, chart: usize) u16 {
        const diet = g.diets[chart];
        if (g.residents(chart) == 0 or diet.missed_grain) return 0;
        return weakness_limit - diet.meat_deficit;
    }

    fn connectedFruitTrees(g: *const Game, chart: usize, walk: *const roads.Walk) u16 {
        const tiles = g.tilesOn(chart);
        var fruit: u16 = 0;
        var visited = walk.seen.iterator(.{});
        while (visited.next()) |i| {
            if (tiles[i].kind == .empty and site(geography.grids[chart].cell(i), chart) == .fruit) fruit += 1;
        }
        return fruit;
    }

    fn workerOutput(base: u32, strength: u16) u16 {
        const output = (base * strength + weakness_limit - 1) / weakness_limit;
        return @intCast(@min(output, std.math.maxInt(u16)));
    }

    pub fn production(g: *const Game, chart: usize) Stores {
        const max_stock = std.math.maxInt(u16);
        return g.productionForDay(chart, .{ .timber = max_stock, .venison = max_stock }, null);
    }

    fn productionForDay(g: *const Game, chart: usize, room: Stores, update: ?[]Tile) Stores {
        const harbor: u16 = @intFromBool(g.islandOpen(chart));
        const strength = g.workforce(chart);
        // Producers deliver only when settlers can walk to them from a harbor,
        // over a bridge if need be.
        const walk = g.footWalk(chart);
        const harvested = if (harbor > 0 and (strength > 0 or update != null))
            g.harvest(chart, strength, .{ .timber = room.timber -| harbor, .venison = room.venison }, &walk, update)
        else
            Stores{};
        if (strength == 0) return .{ .timber = harbor, .grain = harbor };
        return .{
            .timber = harbor +| harvested.timber,
            .stone = workerOutput(quarry_yield * @as(u32, g.connectedCount(chart, .quarry, &walk)), strength),
            .grain = harbor +| workerOutput(5 * @as(u32, g.countOn(chart, .farm)), strength),
            .venison = harvested.venison,
            .fruit = workerOutput(fruit_yield * @as(u32, g.connectedFruitTrees(chart, &walk)), strength),
            .water = workerOutput(@min(waterCapacity(chart), well_yield * @as(u32, g.countOn(chart, .well))), strength),
        };
    }

    fn harvest(g: *const Game, chart: usize, strength: u16, room: Stores, walk: *const roads.Walk, update: ?[]Tile) Stores {
        var timber_potential: u32 = 0;
        var venison_potential: u32 = 0;
        var output = Stores{};
        for (g.tilesOn(chart), 0..) |tile, i| {
            const kind = tile.kind;
            const state = tile.harvest_state;
            const days = recoveryDays(kind);
            if (days == 0) continue;
            const status = describeHarvest(state, days);
            if (status.days_to_recover > 0) {
                if (update) |states| states[i].harvest_state = if (status.days_to_recover == 1) 0 else state + 1;
                continue;
            }
            const potential = if (kind == .grove) &timber_potential else &venison_potential;
            const stock = if (kind == .grove) &output.timber else &output.venison;
            const limit = if (kind == .grove) room.timber else room.venison;
            const previous = workerOutput(potential.*, strength);
            // An unconnected woodlot or lodge sits idle and its stock recovers.
            if (walk.seen.isSet(i)) potential.* += @min(harvest_yield, status.stock);
            const amount = @min(limit - stock.*, workerOutput(potential.*, strength) - previous);
            stock.* += amount;
            if (update) |states| {
                states[i].harvest_state = if (amount > 0) state + @as(u4, @intCast(amount)) else state -| (harvest_capacity / days);
            }
        }
        return output;
    }

    pub fn constructionProblem(g: *const Game, chart: usize) ?[:0]const u8 {
        if (!g.islandOpen(chart)) return "Survey this island before building.";
        if (g.residents(chart) == 0) return "Bring at least one settler to this island before building.";
        return null;
    }

    pub fn build(g: *Game, chart: usize, p: Cell, k: Kind) ?[:0]const u8 {
        if (g.constructionProblem(chart)) |problem| return problem;
        if (!geography.grids[chart].contains(p) or depth(p, chart) < 0) return "Choose a tile on the island.";
        const tile = &g.tiles[tileIndex(chart, p)];
        if (tile.kind != .empty) return "There is already a building here.";
        if (site(p, chart) == .fruit) return "Keep the fruit tree. Connect nearby land features to the harbor to gather fruit.";
        if (k == .empty or k == .port) return "Choose a building.";
        if (k == .grove and !forest(p, chart)) return "Woodlots need a forest tile.";
        if (k == .farm and forest(p, chart)) return "Grain farms need open ground.";
        if (k == .light and chart != 1) return "Build the lighthouse on Bali.";
        if (k == .light and (g.coins < 30 or g.people < 8)) return "Requires 30 coins and 8 settlers.";
        if (k == .quarry and site(p, chart) != .outcrop) return "Choose a rocky outcrop for the quarry.";
        if (k == .lodge and site(p, chart) != .deer) return "Choose a tile where deer graze.";
        if (k == .well and !wellSite(p, chart)) return "Wells need open ground inland.";
        const cost = costs[@backingInt(k)];
        const local = &g.stores[chart];
        if (k == .road) {
            if (local.stone < cost) return "This island needs more stone for roads.";
            local.stone -= cost;
        } else {
            if (local.timber < cost) return "This island needs more timber.";
            if (k == .well and local.stone < well_stone) return "A well needs 2 local stone as well as timber.";
            local.timber -= cost;
            if (k == .well) local.stone -= well_stone;
        }
        tile.* = .{ .kind = k };
        if (k == .light) {
            g.coins -= 30;
            g.charter.won = true;
            g.charter.housed_eight = true;
        }
        return null;
    }
    pub const Shortage = enum { none, diet, water, scurvy };

    fn consume(g: *Game, chart: usize) Shortage {
        const diet = &g.diets[chart];
        const demand = g.dailyDemand(chart);
        if (demand == 0) {
            diet.* = .{};
            return .none;
        }
        const local = &g.stores[chart];
        const enough_grain = local.grain >= demand;
        const enough_meat = local.venison >= demand;
        const enough_fruit = local.fruit >= demand;
        const enough_water = local.water >= demand;
        inline for (food_fields ++ .{"water"}) |name| @field(local, name) -|= demand;

        diet.missed_grain = !enough_grain;
        diet.meat_deficit = if (enough_meat) diet.meat_deficit -| 1 else @min(weakness_limit, diet.meat_deficit + 1);
        diet.days_without_fruit = if (enough_fruit) 0 else @min(scurvy_days, diet.days_without_fruit + 1);
        if (enough_water and diet.days_without_fruit < scurvy_days) {
            return if (enough_grain and enough_meat and enough_fruit) .none else .diet;
        }

        if (chart != 0) g.island_people[chart - 1] -= 1;
        g.people -= 1;
        return if (!enough_water) .water else .scurvy;
    }

    pub fn tick(g: *Game) [settlement_count]Shortage {
        if (g.isOver()) return @splat(.none);
        g.day +|= 1;
        g.charter.housed_eight = g.charter.housed_eight or g.people >= 8;
        var shortages: [settlement_count]Shortage = undefined;
        for (0..settlement_count) |chart| {
            const local = &g.stores[chart];
            const incoming = g.incomingCargo(chart);
            const max_stock = std.math.maxInt(u16);
            const room = Stores{
                .timber = max_stock -| incoming.timber -| local.timber,
                .venison = max_stock -| incoming.venison -| local.venison,
            };
            const grid = geography.grids[chart];
            const supply = g.productionForDay(chart, room, g.tiles[grid.offset..][0..grid.area()]);
            inline for (store_fields) |name| {
                const reserved = @field(incoming, name);
                const limit = std.math.maxInt(u16) - reserved;
                @field(local, name) = @min(limit, @field(local, name) +| @field(supply, name));
            }
            shortages[chart] = g.consume(chart);
        }

        // Rotate eligible settlements so growth is shared as the fleet expands.
        var open: [settlement_count]usize = undefined;
        var count_open: usize = 0;
        for (0..settlement_count) |chart| {
            if (!g.islandOpen(chart)) continue;
            open[count_open] = chart;
            count_open += 1;
        }
        const first = g.day % count_open;
        for (0..count_open) |i| {
            const chart = open[(first + i) % count_open];
            const local = g.stores[chart];
            if (shortages[chart] != .none or g.residents(chart) < 2 or g.freeBeds(chart) == 0 or local.grain +| local.venison +| local.fruit < 3) continue;
            if (g.people == std.math.maxInt(u16)) break;
            g.people += 1;
            if (chart != 0) g.island_people[chart - 1] += 1;
            break;
        }
        if (std.mem.allEqual(Shortage, &shortages, .none)) g.coins +|= g.people / 4;
        g.charter.housed_eight = g.charter.housed_eight or g.people >= 8;
        return shortages;
    }

    pub fn loadingLimits(g: *const Game, source: usize, target: usize, rations: Stores, incoming: Stores) Stores {
        var limits: Stores = undefined;
        inline for (store_fields) |name| {
            const space = std.math.maxInt(u16) -| @field(g.stores[target], name) -| @field(incoming, name);
            @field(limits, name) = @min(@field(g.stores[source], name) -| @field(rations, name), space);
        }
        return limits;
    }

    pub fn sell(g: *Game, chart: usize) bool {
        const local = &g.stores[chart];
        if (local.grain < 6) return false;
        local.grain -= 6;
        g.coins +|= 10;
        return true;
    }
};

test "settlement can feed settlers, trade, survey, and commission its lighthouse" {
    var g = Game.init();
    try std.testing.expect(g.build(0, .{ .x = 8, .y = 8 }, .farm) != null);
    try std.testing.expect(g.build(0, .{ .x = 39, .y = 39 }, .farm) == null);
    try std.testing.expect(g.build(0, .{ .x = 39, .y = 39 }, .farm) != null);
    try std.testing.expect(g.build(0, .{ .x = 39, .y = 44 }, .cottage) == null);
    try std.testing.expect(g.build(0, .{ .x = 44, .y = 35 }, .well) == null);
    try std.testing.expect(g.build(0, .{ .x = 39, .y = 49 }, .road) == null);
    for (0..3) |_| _ = g.tick();
    try std.testing.expect(g.build(0, .{ .x = 30, .y = 35 }, .lodge) == null);
    g.paveTo(0, .{ .x = 30, .y = 35 });
    for (0..6) |_| _ = g.tick();
    try std.testing.expect(g.build(0, .{ .x = 58, .y = 35 }, .lodge) == null);
    g.paveTo(0, .{ .x = 58, .y = 35 });
    for (0..10) |_| _ = g.tick();
    try std.testing.expect(g.build(0, .{ .x = 35, .y = 53 }, .quarry) == null);
    g.paveTo(0, .{ .x = 35, .y = 53 });
    for (0..4) |_| _ = g.tick();
    const cottage = Cell{ .x = 39, .y = 44 };
    const starter = Cell{ .x = 44, .y = 44 };
    const orchard = Cell{ .x = 39, .y = 53 };
    for (cottage.x + 1..starter.x) |x| {
        const cell = Cell{ .x = x, .y = cottage.y };
        if (g.tileAt(0, cell) == .empty) try std.testing.expect(g.build(0, cell, .road) == null);
    }
    for (cottage.y + 1..orchard.y) |y| {
        const cell = Cell{ .x = cottage.x, .y = y };
        if (g.tileAt(0, cell) == .empty) try std.testing.expect(g.build(0, cell, .road) == null);
    }
    try std.testing.expect(g.sell(0));
    try std.testing.expect(g.surveyByFerry(1, 0, .{}) == null);
    try std.testing.expect(g.surveyByFerry(1, 0, .{}) != null);
    g.advanceShip(crossing_seconds);
    try std.testing.expect(g.sailFerry(0) == null);
    g.advanceShip(crossing_seconds);
    for (0..35) |_| _ = g.tick();
    try std.testing.expect(g.sendFerry(1, 1, .{ .timber = costs[@backingInt(Kind.light)] }) == null);
    g.advanceShip(crossing_seconds);
    if (g.build(1, .{ .x = 24, .y = 24 }, .light)) |problem| {
        std.debug.print("Population {d}, coins {d}: {s}\n", .{ g.people, g.coins, problem });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(g.charter.won and g.people == 8);
}

test "roads spend stone and deer feed settlers while grain remains tradable" {
    var g = Game.init();
    g.stores[0].stone = 0;
    const road = Cell{ .x = 39, .y = 44 };
    try std.testing.expect(g.build(0, road, .road) != null);
    try std.testing.expect(g.build(0, road, .quarry) != null);
    try std.testing.expect(g.build(0, road, .lodge) != null);
    try std.testing.expect(g.build(0, .{ .x = 35, .y = 53 }, .quarry) == null);
    try std.testing.expect(g.build(0, .{ .x = 30, .y = 35 }, .lodge) == null);
    g.paveTo(0, .{ .x = 35, .y = 53 });
    g.paveTo(0, .{ .x = 30, .y = 35 });
    g.stores[0].grain = 6;
    g.stores[0].venison = 0;
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 3), g.stores[0].stone);
    try std.testing.expectEqual(@as(u16, 2), g.stores[0].venison);
    try std.testing.expect(g.sell(0));
    const timber = g.stores[0].timber;
    try std.testing.expect(g.build(0, road, .road) == null);
    try std.testing.expectEqual(timber, g.stores[0].timber);
    try std.testing.expectEqual(@as(u16, 2), g.stores[0].stone);
}

test "wells spend both materials and cover a growing settlement's daily water need" {
    var g = Game.init();
    const inland = Cell{ .x = 44, .y = 35 };
    try std.testing.expect(g.build(0, .{ .x = 35, .y = 53 }, .well) != null);
    g.stores[0].stone = 1;
    try std.testing.expect(g.build(0, inland, .well) != null);
    try std.testing.expectEqual(Game.init().stores[0].timber, g.stores[0].timber);
    try std.testing.expectEqual(@as(u16, 1), g.stores[0].stone);
    g.stores[0].stone = 2;
    try std.testing.expect(g.build(0, inland, .well) == null);
    try std.testing.expectEqual(@as(u16, 17), g.stores[0].timber);
    try std.testing.expectEqual(@as(u16, 0), g.stores[0].stone);
    g.people = 8;
    g.stores[0].water = 0;
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 8), g.people);
    try std.testing.expectEqual(@as(u16, 0), g.stores[0].water);
}

test "water shortage draws down supply and costs only one settler even without food" {
    var g = Game.init();
    g.people = 5;
    g.stores[0].water = 0;
    g.stores[0].grain = 0;
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 4), g.people);
    try std.testing.expectEqual(@as(u16, 0), g.stores[0].water);
    try std.testing.expectEqual(@as(u16, 0), g.stores[0].grain);
}

test "the starting ship supply runs out without a well" {
    var g = Game.init();
    g.people = 4;
    const days = g.stores[0].water / g.dailyDemand(0);
    g.stores[0].fruit = 30;
    try std.testing.expectEqual(@as(u16, 0), g.production(0).water);
    for (0..days) |_| _ = g.tick();
    try std.testing.expectEqual(@as(u16, 0), g.stores[0].water);
    try std.testing.expectEqual(@as(u16, 4), g.people);
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 3), g.people);
}

test "either island needs two residents and Bali keeps ferry beds free" {
    var lone_settler = Game.init();
    lone_settler.people = 1;
    _ = lone_settler.tick();
    try std.testing.expectEqual(@as(u16, 1), lone_settler.people);

    var g = Game.init();
    try std.testing.expect(g.build(0, .{ .x = 39, .y = 39 }, .farm) == null);
    g.people = 4;
    g.coins = 20;
    try std.testing.expect(g.surveyByFerry(1, 0, .{}) == null);
    g.advanceShip(crossing_seconds);
    try std.testing.expect(g.sailFerry(0) == null);
    g.advanceShip(crossing_seconds);
    g.stores[0].venison = 40;
    g.stores[0].fruit = 40;
    g.stores[1] = .{ .timber = 6, .grain = 20, .venison = 20, .fruit = 20, .water = 20 };
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 0), g.residents(1));

    try std.testing.expect(g.ferrySettlers(1, 1) == null);
    g.advanceShip(crossing_seconds);
    try std.testing.expect(g.build(1, .{ .x = 24, .y = 24 }, .cottage) == null);
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 1), g.residents(1));

    try std.testing.expect(g.sailFerry(0) == null);
    g.advanceShip(crossing_seconds);
    try std.testing.expect(g.ferrySettlers(1, 1) == null);
    g.advanceShip(crossing_seconds);
    _ = g.tick();
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 3), g.residents(1));

    try std.testing.expect(g.sailFerry(0) == null);
    g.advanceShip(crossing_seconds);
    try std.testing.expect(g.ferrySettlers(1, 1) == null);
    _ = g.tick();
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 3), g.residents(1));
    g.advanceShip(crossing_seconds);
    try std.testing.expectEqual(@as(u16, 4), g.residents(1));
}

test "islands consume and produce supplies locally" {
    var g = Game.init();
    g.coins = 20;
    try std.testing.expect(g.surveyByFerry(1, 0, .{}) == null);
    g.advanceShip(crossing_seconds);
    try std.testing.expect(g.sailFerry(0) == null);
    g.advanceShip(crossing_seconds);
    g.stores[1] = .{ .timber = 12, .grain = 10 };
    try std.testing.expect(g.ferrySettlers(1, 2) == null);
    try std.testing.expectEqual(@as(u16, 0), g.residents(0));
    try std.testing.expect(g.build(0, .{ .x = 39, .y = 44 }, .road) != null);
    g.advanceShip(crossing_seconds);
    try std.testing.expect(g.build(1, .{ .x = 24, .y = 24 }, .cottage) == null);
    try std.testing.expect(g.build(1, .{ .x = 24, .y = 33 }, .quarry) == null);
    g.paveTo(1, .{ .x = 24, .y = 33 });
    const alder_water = g.stores[0].water;
    g.stores[1].water = 0;
    const shortages = g.tick();
    try std.testing.expectEqual(Game.Shortage.water, shortages[1]);
    try std.testing.expectEqual(alder_water, g.stores[0].water);
    try std.testing.expectEqual(@as(u16, 1), g.residents(1));
    try std.testing.expectEqual(quarry_yield, g.stores[1].stone);
    try std.testing.expectEqual(starting_stores.stone, g.stores[0].stone);
}

test "fruit gathering spreads through harbor roads and neighboring features" {
    var g = Game.init();
    const forest_tree = Cell{ .x = 53, .y = 35 };
    const meadow_tree = Cell{ .x = 39, .y = 53 };
    const deer_site = Cell{ .x = 35, .y = 49 };

    const initial = roads.Walk.fromPort(g.tilesOn(0), 0);
    try std.testing.expect(initial.contains(forest_tree));
    const forest_tile = Cell{ .x = 53, .y = 39 };
    try std.testing.expect(forest(forest_tile, 0));
    try std.testing.expectEqual(Kind.empty, g.tileAt(0, forest_tile));
    try std.testing.expect(!initial.contains(meadow_tree));
    try std.testing.expect(!initial.contains(deer_site));
    const initial_fruit = g.production(0).fruit;
    try std.testing.expect(initial_fruit > 0);

    try std.testing.expect(g.build(0, meadow_tree, .road) != null);
    try std.testing.expect(g.build(0, .{ .x = 39, .y = 58 }, .road) == null);
    try std.testing.expectEqual(initial_fruit, g.production(0).fruit);
    const branch = Cell{ .x = 39, .y = 44 };
    const starter = Cell{ .x = 44, .y = 44 };
    g.stores[0].stone = 40;
    for (branch.x..starter.x) |x| {
        try std.testing.expect(g.build(0, .{ .x = x, .y = branch.y }, .road) == null);
    }
    for (branch.y + 1..meadow_tree.y) |y| {
        const cell = Cell{ .x = branch.x, .y = y };
        if (g.tileAt(0, cell) == .empty) try std.testing.expect(g.build(0, cell, .road) == null);
    }
    const expanded = roads.Walk.fromPort(g.tilesOn(0), 0);
    try std.testing.expect(expanded.contains(meadow_tree));
    const daily_fruit = g.production(0).fruit;
    try std.testing.expect(daily_fruit > initial_fruit);

    const fruit = g.stores[0].fruit;
    const meat = g.stores[0].venison;
    const grain = g.stores[0].grain;
    _ = g.tick();
    try std.testing.expectEqual(fruit + daily_fruit - 1, g.stores[0].fruit);
    try std.testing.expectEqual(meat - 1, g.stores[0].venison);
    try std.testing.expectEqual(grain, g.stores[0].grain);
}

test "grain restarts work and venison prevents gradual weakness" {
    var g = Game.init();
    g.people = 4;
    g.stores[0].grain = 0;
    g.stores[0].fruit = 40;
    try std.testing.expect(g.build(0, .{ .x = 44, .y = 35 }, .well) == null);
    _ = g.tick();
    try std.testing.expect(g.diets[0].missed_grain);
    try std.testing.expectEqual(@as(u16, 0), g.production(0).water);
    g.stores[0].grain = 30;
    _ = g.tick();
    try std.testing.expect(!g.diets[0].missed_grain);
    try std.testing.expectEqual(well_yield, g.production(0).water);
    g.stores[0].venison = 0;
    for (1..@as(usize, weakness_limit) + 1) |day| {
        _ = g.tick();
        try std.testing.expectEqual(@as(u16, weakness_limit) - @as(u16, @intCast(day)), g.workforce(0));
    }
    try std.testing.expectEqual(@as(u16, 0), g.production(0).water);
    g.stores[0].venison = 2;
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 1), g.workforce(0));
}

test "prolonged fruit shortage causes scurvy and fruit stops it" {
    var g = Game.init();
    g.people = 4;
    // Simulate a charter where earlier construction occupied the fruit sites.
    const grid = geography.grids[0];
    for (0..grid.area()) |i| {
        const cell = grid.cell(i);
        if (site(cell, 0) == .fruit) g.setTile(0, cell, .grove);
    }
    g.stores[0].fruit = 0;
    g.stores[0].venison = 30;
    for (0..scurvy_days - 1) |_| {
        try std.testing.expectEqual(Game.Shortage.diet, g.tick()[0]);
        try std.testing.expectEqual(@as(u16, 4), g.people);
    }
    try std.testing.expectEqual(Game.Shortage.scurvy, g.tick()[0]);
    try std.testing.expectEqual(@as(u16, 3), g.people);
    g.stores[0].fruit = 2;
    try std.testing.expectEqual(Game.Shortage.none, g.tick()[0]);
    try std.testing.expectEqual(@as(u8, 0), g.diets[0].days_without_fruit);
}

test "charter reports the next three goals and remembers past population" {
    var g = Game.init();
    try std.testing.expectEqualDeep([3]?Goal{ .house_settlers, .ferry_settlers, .lighthouse }, g.nextGoals());
    g.charter.ferried_to_bali = true;
    try std.testing.expectEqualDeep([3]?Goal{ .house_settlers, .lighthouse, .bridge }, g.nextGoals());
    g.charter.housed_eight = true;
    g.charter.won = true;
    g.bridges[0] = true;
    try std.testing.expectEqualDeep([3]?Goal{ .build_brig, .chart_lombok, .build_barque }, g.nextGoals());
    g.fleet.vessels[0].ship = .barque;
    g.fleet.count = 1;
    g.fleet.charted = @splat(true);
    try std.testing.expectEqualDeep([3]?Goal{ .settle_borneo, .settle_sumatra, .build_fleet }, g.nextGoals());
    g.founded[0] = true;
    g.founded[1] = true;
    try std.testing.expectEqualDeep([3]?Goal{ .build_fleet, .settle_sulawesi, .settle_luzon }, g.nextGoals());
    g.fleet.vessels[1..charter_fleet_size].* = @splat(.{ .ship = .brig });
    g.fleet.count = charter_fleet_size - 1;
    try std.testing.expectEqualDeep([3]?Goal{ .build_fleet, .settle_sulawesi, .settle_luzon }, g.nextGoals());
    g.fleet.count = charter_fleet_size;
    try std.testing.expectEqualDeep([3]?Goal{ .settle_sulawesi, .settle_luzon, .settle_new_guinea }, g.nextGoals());
    g.founded[geography.chartNamed("Luzon").? - geography.borneo] = true;
    try std.testing.expectEqualDeep([3]?Goal{ .settle_sulawesi, .settle_new_guinea, null }, g.nextGoals());
    g.founded = @splat(true);
    try std.testing.expectEqualDeep([3]?Goal{ null, null, null }, g.nextGoals());
}

test "additional wells cannot push an island past its daily water capacity" {
    var g = Game.init();
    g.people = 1;
    g.stores[0] = .{ .timber = 100, .stone = 100, .grain = 100, .venison = 100, .fruit = 100 };
    const limit = waterCapacity(0);
    try std.testing.expect(waterCapacity(geography.borneo) > limit);
    const grid = geography.grids[0];
    var wells: u16 = 0;
    for (0..grid.area()) |i| {
        const cell = grid.cell(i);
        if (!wellSite(cell, 0) or g.build(0, cell, .well) != null) continue;
        wells += 1;
        try std.testing.expectEqual(@min(well_yield * wells, limit), g.production(0).water);
        if (wells == limit / well_yield + 2) break;
    } else return error.NotEnoughWellSites;
    _ = g.tick();
    try std.testing.expectEqual(limit - 1, g.stores[0].water);
}

/// Each island as its first settlers find it: Java as a new game starts,
/// every other island with its harbor just opened.
fn freshIsland(chart: usize) Game {
    var g = Game.init();
    if (chart != 0) g.chartHarbor(chart);
    return g;
}

test "every island offers enough stone, deer and fruit within a short road of its harbor" {
    var failures: usize = 0;
    for (0..settlement_count) |chart| {
        const g = freshIsland(chart);
        for ([_]Site{ .outcrop, .deer, .fruit }) |wanted| {
            const sites = g.resourceSites(chart, wanted, roadBudget(chart));
            if (sites.len >= requiredSites(chart, wanted)) continue;
            std.debug.print("{s} has {d} {s} sites within {d} road tiles of its harbor, needs {d}\n", .{ geography.names[chart], sites.len, @tagName(wanted), roadBudget(chart), requiredSites(chart, wanted) });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "resource site costs match the roads a player would actually lay" {
    var buffer: [256]Cell = undefined;
    for ([_]usize{ 0, 1, 2, geography.borneo }) |chart| {
        const g = freshIsland(chart);
        for ([_]Site{ .outcrop, .deer, .fruit }) |wanted| {
            const sites = g.resourceSites(chart, wanted, site_road_budget);
            for (sites.slice(), sites.roads[0..sites.len], 0..) |cell, cost, i| {
                try std.testing.expectEqual(wanted, site(cell, chart));
                if (i > 0) try std.testing.expect(sites.roads[i - 1] <= cost);
                const path = g.roadPath(chart, cell, &buffer).?;
                try std.testing.expectEqual(@as(usize, cost), path.len);
            }
        }
    }
}

test "far sites cost more road than the budget allows" {
    // Java's outcrop on the southern plain is many road tiles from the start.
    const g = Game.init();
    const sites = g.resourceSites(0, .outcrop, opening_road_budget);
    for (sites.slice()) |cell| try std.testing.expect(!(cell.x == 35 and cell.y == 53));
    try std.testing.expect(site(.{ .x = 35, .y = 53 }, 0) == .outcrop);
}

test "the opening settlers can connect a hunting lodge and fruit with the starting stone" {
    var g = Game.init();
    var buffer: [64]Cell = undefined;
    const herd = g.resourceSites(0, .deer, opening_road_budget).slice()[0];
    const path = g.roadPath(0, herd, &buffer).?;
    try std.testing.expect(g.build(0, herd, .lodge) == null);
    for (path) |step| try std.testing.expect(g.build(0, step, .road) == null);
    try std.testing.expect(g.connected(0, herd));
    try std.testing.expect(g.production(0).venison > 0);
    const trees = g.resourceSites(0, .fruit, opening_road_budget);
    for (trees.slice()[0..2]) |tree| {
        const trail = g.roadPath(0, tree, &buffer).?;
        for (trail) |step| try std.testing.expect(g.build(0, step, .road) == null);
    }
    try std.testing.expect(g.production(0).fruit >= 2 * fruit_yield);
}

test "the opening settlers can quarry and connect two quarries near Java's harbor with starting stores" {
    var g = Game.init();
    var connected_quarries: usize = 0;
    var buffer: [64]Cell = undefined;
    const sites = g.resourceSites(0, .outcrop, opening_road_budget);
    for (sites.slice()) |cell| {
        if (connected_quarries == 2) break;
        const path = g.roadPath(0, cell, &buffer) orelse continue;
        if (path.len * costs[@backingInt(Kind.road)] > g.stores[0].stone) continue;
        try std.testing.expect(g.build(0, cell, .quarry) == null);
        try std.testing.expect(!g.connected(0, cell) or path.len == 0);
        for (path) |step| try std.testing.expect(g.build(0, step, .road) == null);
        try std.testing.expect(g.connected(0, cell));
        connected_quarries += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), connected_quarries);
    const before = g.stores[0].stone;
    _ = g.tick();
    try std.testing.expect(g.stores[0].stone > before);
}

test "quarries, woodlots and lodges produce only once settlers can reach them" {
    var g = Game.init();
    g.stores[0] = .{ .timber = 100, .stone = 0, .grain = 100, .venison = 100, .fruit = 100, .water = 100 };
    const quarry = Cell{ .x = 35, .y = 53 };
    const herd = Cell{ .x = 30, .y = 35 };
    try std.testing.expect(g.build(0, quarry, .quarry) == null);
    try std.testing.expect(g.build(0, herd, .lodge) == null);
    try std.testing.expect(!g.connected(0, quarry) and !g.connected(0, herd));
    const idle = g.production(0);
    try std.testing.expectEqual(@as(u16, 0), idle.stone);
    try std.testing.expectEqual(@as(u16, 0), idle.venison);
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 0), g.stores[0].stone);
    try std.testing.expectEqual(@as(u4, harvest_capacity), g.harvestStatus(0, herd).?.stock);
    g.paveTo(0, quarry);
    g.paveTo(0, herd);
    try std.testing.expect(g.connected(0, quarry) and g.connected(0, herd));
    try std.testing.expectEqual(quarry_yield, g.production(0).stone);
    try std.testing.expect(g.production(0).venison > 0);
    try std.testing.expect(needsHarbor(.quarry) and needsHarbor(.grove) and needsHarbor(.lodge));
    try std.testing.expect(!needsHarbor(.farm) and !needsHarbor(.well) and !needsHarbor(.road));
}
