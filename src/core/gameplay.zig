// Use cases for the settlement, fleet, and charter. This module has no I/O.
const std = @import("std");
const domain = @import("colony.zig");

pub const Manifest = struct {
    settlers: u16,
    cargo: domain.Stores,
};

pub const Command = union(enum) {
    build: struct { island: usize, cell: domain.Cell, kind: domain.Kind },
    /// Bridge a crossing in `domain.crossings`.
    build_bridge: usize,
    /// Send the ferry's crew to chart a harbor in range of its mooring.
    /// Settlers and cargo aboard found a camp there on arrival.
    survey_harbor: struct { destination: usize, manifest: Manifest },
    send_ferry: struct { destination: usize, manifest: Manifest },
    /// Sail the ferry without a load to another harbor.
    sail_ferry: usize,
    build_ship: struct { island: usize, hull: domain.ocean.Ship },
    /// Survey an uncharted route. Settlers and cargo aboard found a camp on arrival.
    survey_island: struct { ship: usize, route: usize, manifest: Manifest },
    send_expedition: struct { ship: usize, route: usize, manifest: Manifest },
    return_expedition: usize,
    export_grain: usize,
    /// Advance the simulation clock by up to one day of game seconds.
    /// Voyages move first. Crossing the end of a day runs the daily upkeep.
    advance: f32,
    rename_town: struct { island: usize, name: domain.TownName },
};

pub const Arrival = union(enum) {
    ferry: struct {
        island: usize,
        survey: bool,
        settlers: u16,
        cargo: domain.Stores,
        unlocked_shipyard: bool,
    },
    expedition: struct {
        ship: usize,
        island: usize,
        event: domain.Game.ExpeditionEvent,
        settlers: u16,
        cargo: domain.Stores,
    },
    /// A settler stepped off a bridge onto `island`.
    walker: struct {
        crossing: usize,
        island: usize,
    },
};

pub const Arrivals = struct {
    items: [domain.max_expedition_ships + 1 + domain.bridge.max_walkers]Arrival = undefined,
    len: usize = 0,

    pub fn slice(arrivals: *const Arrivals) []const Arrival {
        return arrivals.items[0..arrivals.len];
    }

    fn append(arrivals: *Arrivals, event: Arrival) void {
        arrivals.items[arrivals.len] = event;
        arrivals.len += 1;
    }
};

pub const Day = struct {
    shortages: [domain.settlement_count]domain.Game.Shortage,
    population_before: u16,
    population_after: u16,
};

pub const Advance = struct {
    arrivals: Arrivals,
    /// Set when this step ended a day.
    day: ?Day,
};

pub const Outcome = union(enum) {
    applied,
    denied: [:0]const u8,
    advanced: Advance,

    pub fn problem(outcome: *const Outcome) ?[:0]const u8 {
        return switch (outcome.*) {
            .denied => |reason| reason,
            else => null,
        };
    }
};

/// Write the next state to caller-owned storage. The input, including its
/// clock and random state (if any), is entirely supplied by the caller.
pub fn transition(current: *const domain.Game, next: *domain.Game, command: Command) Outcome {
    next.* = current.*;
    return apply(next, command);
}

/// In-place form for a uniquely owned aggregate in the frame loop.
pub fn apply(game: *domain.Game, command: Command) Outcome {
    if (game.isOver() and command != .advance) {
        return .{ .denied = "The charter has ended." };
    }
    const denial: ?[:0]const u8 = switch (command) {
        .build => |c| if (c.island < domain.settlement_count)
            game.build(c.island, c.cell, c.kind)
        else
            "Choose an island on the chart.",
        .rename_town => |c| if (c.island < domain.settlement_count)
            game.renameTown(c.island, c.name)
        else
            "Choose an island on the chart.",
        .build_bridge => |crossing| game.buildBridge(crossing),
        .survey_harbor => |c| game.surveyByFerry(c.destination, c.manifest.settlers, c.manifest.cargo),
        .send_ferry => |c| game.sendFerry(c.destination, c.manifest.settlers, c.manifest.cargo),
        .sail_ferry => |chart| game.sailFerry(chart),
        .build_ship => |c| if (c.island < domain.settlement_count)
            game.buildShip(c.island, c.hull)
        else
            "Choose an island on the chart.",
        .survey_island => |c| game.launchExpedition(c.ship, c.route, c.manifest.settlers, c.manifest.cargo),
        .send_expedition => |c| game.sendExpedition(c.ship, c.route, c.manifest.settlers, c.manifest.cargo),
        .return_expedition => |id| game.returnExpedition(id),
        .export_grain => |island| if (island >= domain.settlement_count)
            "Choose an island on the chart."
        else if (!game.sell(island))
            "The merchant needs 6 grain from the selected island."
        else
            null,
        .advance => |seconds| {
            if (!std.math.isFinite(seconds) or seconds < 0 or seconds > domain.day_seconds) {
                return .{ .denied = "Invalid simulation interval." };
            }
            return .{ .advanced = advance(game, seconds) };
        },
    };
    return if (denial) |reason| .{ .denied = reason } else .applied;
}

/// Seconds left before the current day ends.
pub fn untilNextDay(game: *const domain.Game) f32 {
    return domain.day_seconds - game.day_time;
}

fn advance(game: *domain.Game, seconds: f32) Advance {
    // Once the last settler is gone the world stands still, calendar included.
    if (game.isOver()) return .{ .arrivals = .{}, .day = null };
    const arrivals = advanceVoyages(game, seconds);
    game.day_time += seconds;
    if (game.day_time < domain.day_seconds) return .{ .arrivals = arrivals, .day = null };
    game.day_time -= domain.day_seconds;
    // A step is at most one day long, so one subtraction suffices unless
    // rounding lands exactly on the boundary.
    if (!(game.day_time < domain.day_seconds)) game.day_time = 0;
    const before = game.people;
    const shortages = game.tick();
    return .{ .arrivals = arrivals, .day = .{
        .shortages = shortages,
        .population_before = before,
        .population_after = game.people,
    } };
}

/// The voyage half of `advance`, without the calendar. Properties use it to
/// isolate sailing from daily upkeep. The game itself only issues `advance`.
pub fn advanceVoyages(game: *domain.Game, seconds: f32) Arrivals {
    var report = Arrivals{};
    const before = game.ferry;
    const unlocked = game.charterComplete();
    game.advanceShip(seconds);
    if (before.moored() == null and game.ferry.moored() != null) {
        report.append(.{ .ferry = .{
            .island = game.mooredChart().?,
            .survey = before.surveying,
            .settlers = before.passengers,
            .cargo = before.cargo,
            .unlocked_shipyard = !unlocked and game.charterComplete(),
        } });
    }
    for (0..game.fleet.count) |id| {
        const vessel = game.fleet.vessels[id];
        const event = game.advanceExpedition(id, seconds);
        if (event == .none) continue;
        report.append(.{ .expedition = .{
            .ship = id,
            .island = game.fleet.vessels[id].chart,
            .event = event,
            .settlers = vessel.passengers,
            .cargo = vessel.cargo,
        } });
    }
    const landed = game.advanceWalkers(seconds);
    for (landed.slice()) |walker| report.append(.{ .walker = .{ .crossing = walker.crossing, .island = walker.destination } });
    return report;
}

test "a lighthouse needs a coastal tile near its harbor and opens a second berth outside Bali" {
    var game = domain.Game.init();
    game.people = 8;
    game.coins = 60;
    game.store(0).timber = 48;
    const light = Command{ .build = .{ .island = 0, .cell = .{ .x = 55, .y = 42 }, .kind = .light } };

    try std.testing.expectEqual(@as(usize, 1), game.berthCapacity(0));
    try std.testing.expectEqual(@as(usize, 0), game.freeBerths(0));
    const stock = game.stockOf(0);
    const inland = Command{ .build = .{ .island = 0, .cell = .{ .x = 52, .y = 43 }, .kind = .light } };
    const distant_coast = Command{ .build = .{ .island = 0, .cell = .{ .x = 50, .y = 46 }, .kind = .light } };
    for ([_]Command{ inland, distant_coast }) |command| {
        try std.testing.expectEqualStrings("Choose a coastal tile within 4 tiles of the harbor.", apply(&game, command).problem().?);
        try std.testing.expectEqual(domain.Kind.empty, game.tileAt(0, command.build.cell));
    }
    try std.testing.expectEqualDeep(stock, game.stockOf(0));
    try std.testing.expectEqual(@as(u16, 60), game.coins);
    try std.testing.expect(apply(&game, light) == .applied);
    try std.testing.expectEqual(@as(usize, 2), game.berthCapacity(0));
    try std.testing.expectEqual(@as(usize, 1), game.freeBerths(0));
    try std.testing.expectEqual(@as(usize, 1), game.berthCapacity(1));
    try std.testing.expectEqual(@as(u16, 24), game.stockOf(0).timber);
    try std.testing.expectEqual(@as(u16, 30), game.coins);
    try std.testing.expect(!game.charter.won);
    try std.testing.expect(!game.charterComplete());

    const second = apply(&game, .{ .build = .{ .island = 0, .cell = .{ .x = 55, .y = 43 }, .kind = .light } });
    try std.testing.expectEqualStrings("This island already has a lighthouse.", second.problem().?);
    try std.testing.expectEqual(@as(u16, 24), game.stockOf(0).timber);
    try std.testing.expectEqual(@as(u16, 30), game.coins);
}

test "a bridge crossing lands its settler as an arrival once the walk is done" {
    var game = domain.Game.init();
    game.ferry.surveyed = true;
    game.openPort(1);
    game.bridges[0] = true;
    game.paveBridge(0);
    try std.testing.expect(game.crossBridge(0, 1) == null);
    const walk = domain.crossings[0].walkSeconds();
    try std.testing.expectEqual(@as(usize, 0), apply(&game, .{ .advance = walk / 3 }).advanced.arrivals.len);
    // The rest of the walk, ending before the day does, so Bali's empty stores go untested.
    const outcome = apply(&game, .{ .advance = walk - walk / 3 });
    try std.testing.expect(outcome.advanced.day == null);
    const arrivals = outcome.advanced.arrivals.slice();
    try std.testing.expectEqual(@as(usize, 1), arrivals.len);
    try std.testing.expectEqual(@as(usize, 1), arrivals[0].walker.island);
    try std.testing.expectEqual(@as(u16, 1), game.residents(1));
}

test "after the charter ends only the clock may be advanced" {
    var game = domain.Game.init();
    game.people = 0;
    try std.testing.expectEqualStrings("The charter has ended.", apply(&game, .{ .export_grain = 0 }).problem().?);
    try std.testing.expect(apply(&game, .{ .advance = 1 }) == .advanced);
}

test "the road that reaches a bridge pools both islands' stores" {
    var game = domain.Game.init();
    game.bridges[0] = true;
    game.ferry.surveyed = true;
    game.openPort(1);
    game.store(0).stone = 5;
    game.store(1).timber = 3;
    var buffer: [domain.geography.max_grid_area]domain.Cell = undefined;
    for (game.bridgeRoadPath(0, 1, &buffer).?) |cell| game.setTile(1, cell, .road);
    const java_road = game.bridgeRoadPath(0, 0, &buffer).?;
    try std.testing.expectEqual(@as(usize, 1), java_road.len);
    const timber = game.stockOf(0).timber;
    try std.testing.expect(!game.linked(0, 1));
    try std.testing.expect(apply(&game, .{ .build = .{ .island = 0, .cell = java_road[0], .kind = .road } }) == .applied);
    try std.testing.expect(game.linked(0, 1));
    try std.testing.expectEqual(timber + 3, game.stockOf(1).timber);
}
