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
    /// Start a settler walking over a bridge to one of its islands. They
    /// arrive after the walk, as `advance` runs it.
    cross_bridge: struct { crossing: usize, destination: usize },
    transfer_stores: struct { crossing: usize, source: usize, cargo: domain.Stores },
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
        .build_bridge => |crossing| game.buildBridge(crossing),
        .cross_bridge => |c| game.crossBridge(c.crossing, c.destination),
        .transfer_stores => |c| game.sendCargo(c.crossing, c.source, c.cargo),
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
            .island = if (event == .returned) 0 else vessel.chart,
            .event = event,
            .settlers = vessel.passengers,
            .cargo = vessel.cargo,
        } });
    }
    const landed = game.advanceWalkers(seconds);
    for (landed.slice()) |walker| report.append(.{ .walker = .{ .crossing = walker.crossing, .island = walker.destination } });
    return report;
}

test "a bridge crossing lands its settler as an arrival once the walk is done" {
    var game = domain.Game.init();
    game.ferry.surveyed = true;
    game.openPort(1);
    game.bridges[0] = true;
    game.paveBridge(0);
    try std.testing.expect(apply(&game, .{ .cross_bridge = .{ .crossing = 0, .destination = 1 } }) == .applied);
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

test "overland transfers start only from an island on that bridge" {
    var game = domain.Game.init();
    game.bridges[0] = true;
    game.ferry.surveyed = true;
    game.openPort(1);
    try std.testing.expectEqualStrings("Choose an island on that bridge.", apply(&game, .{ .transfer_stores = .{ .crossing = 0, .source = 2, .cargo = .{ .timber = 1 } } }).problem().?);
    try std.testing.expectEqualStrings("Choose a bridge.", apply(&game, .{ .transfer_stores = .{ .crossing = domain.crossings.len, .source = 0, .cargo = .{ .timber = 1 } } }).problem().?);
    game.stores[1].timber = 3;
    try std.testing.expectEqualStrings("Lay roads from both harbors to the bridge.", apply(&game, .{ .transfer_stores = .{ .crossing = 0, .source = 1, .cargo = .{ .timber = 1 } } }).problem().?);
    game.paveBridge(0);
    try std.testing.expect(apply(&game, .{ .transfer_stores = .{ .crossing = 0, .source = 1, .cargo = .{ .timber = 1 } } }) == .applied);
    try std.testing.expectEqual(@as(u16, 2), game.stores[1].timber);
}
