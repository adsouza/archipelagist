// Deterministic generated tests. The failing seed is printed for replay.
const std = @import("std");
const domain = @import("core").colony;
const gameplay = @import("core").gameplay;
const queries = @import("core").queries;
const save = @import("core").save;
const journal = @import("core").journal;
const journal_file = @import("journal_file.zig");
const gameplay_trace = @import("gameplay_trace.zig");

fn stock(units: u16) domain.Stores {
    return .{ .timber = units, .stone = units, .grain = units, .venison = units, .fruit = units, .water = units };
}

fn rejected(game: *domain.Game, command: gameplay.Command) !void {
    const before = save.encode(game.*);
    const receipt = gameplay.apply(game, command);
    try std.testing.expect(receipt == .denied);
    try std.testing.expectEqualSlices(u8, &before, &save.encode(game.*));
}

fn rejectionCase(seed: u64) !void {
    var random_state = std.Random.DefaultPrng.init(seed);
    const random = random_state.random();
    var game = domain.Game.init();
    game.store(0).* = stock(random.intRangeAtMost(u16, 0, 5));
    game.coins = random.intRangeAtMost(u16, 0, 19);

    const home = domain.quay(0);
    var rejected_state: domain.Game = undefined;
    const command: gameplay.Command = .{ .build = .{ .island = 0, .cell = home, .kind = .road } };
    // Give the player enough stone to isolate the occupancy invariant.
    game.store(0).stone = 20;
    const result = gameplay.transition(&game, &rejected_state, command);
    try std.testing.expect(result == .denied);
    try std.testing.expectEqual(domain.Kind.port, game.tileAt(0, home));
    try std.testing.expectEqualSlices(u8, &save.encode(game), &save.encode(rejected_state));
    try rejected(&game, .{ .export_grain = 0 });
    try rejected(&game, .{ .survey_harbor = .{ .destination = 2, .manifest = .{ .settlers = 0, .cargo = .{} } } });
    try rejected(&game, .{ .advance = switch (seed % 3) {
        0 => -random.float(f32) - 1,
        1 => std.math.nan(f32),
        else => domain.day_seconds + 0.001 + random.float(f32) * 100,
    } });
    try rejected(&game, .{ .build_bridge = domain.crossings.len + random.intRangeAtMost(usize, 0, 100) });

    game.ferry.surveyed = true;
    game.openPort(1);
    game.store(1).timber = 80;
    const inland = domain.geography.grids[1];
    for (0..inland.area()) |index| {
        const cell = inland.cell(index);
        if (domain.depth(cell, 1) < 0 or game.tileAt(1, cell) != .empty or domain.site(cell, 1) == .fruit) continue;
        try rejected(&game, .{ .build = .{ .island = 1, .cell = cell, .kind = .cottage } });
        break;
    } else return error.NoEmptyBaliLand;
}

test "property: generated rejections leave the aggregate unchanged" {
    for (1..65) |seed| rejectionCase(seed) catch |err| {
        std.debug.print("Command rejection seed={d}\n", .{seed});
        return err;
    };
}

fn settlementCase(seed: u64) !void {
    var random_state = std.Random.DefaultPrng.init(seed);
    const random = random_state.random();
    var game = domain.Game.init();
    try std.testing.expect(game.build(0, .{ .x = 39, .y = 39 }, .cottage) == null);
    game.people = 8;
    game.coins = 300;
    game.ferry.surveyed = true;
    game.charter.won = true;
    game.bridges[0] = true;
    game.charter.ferried_to_bali = true;
    game.ferry.origin = 1;
    game.ferry.destination = 1;
    game.openPort(1);
    const route_index = 0;
    const route = domain.ocean.routes[route_index];
    game.fleet.charted[route_index] = true;
    game.openPort(route.chart);
    game.store(0).* = stock(600);
    game.store(route.chart).* = stock(random.intRangeAtMost(u16, 0, 200));

    const hull = domain.shipCost(.brig);
    for (0..domain.dock_capacity) |id| {
        const origin = game.store(0).*;
        const coins = game.coins;
        try std.testing.expect(gameplay.apply(&game, .{ .build_ship = .{ .island = 0, .hull = .brig } }) == .applied);
        try std.testing.expectEqual(id + 1, game.fleet.count);
        try std.testing.expectEqual(origin.timber - hull.timber, game.store(0).timber);
        try std.testing.expectEqual(origin.stone - hull.stone, game.store(0).stone);
        try std.testing.expectEqual(coins - hull.coins, game.coins);
    }
    try rejected(&game, .{ .build_ship = .{ .island = 0, .hull = .brig } });

    const initial_stock = game.store(route.chart).*;
    var expected_arrival = initial_stock;
    var expected_passengers: u16 = 0;
    for (0..domain.dock_capacity) |id| {
        const passengers = random.intRangeAtMost(u16, 1, 2);
        const cargo = stock(random.intRangeAtMost(u16, 1, 6));
        const provisions = game.oceanRations(id, route_index, passengers);
        var expected_source = game.store(0).*;
        expected_source.take(provisions);
        expected_source.take(cargo);
        expected_arrival.add(cargo);
        expected_passengers += passengers;
        const receipt = gameplay.apply(&game, .{ .send_expedition = .{
            .ship = id,
            .route = route_index,
            .manifest = .{ .settlers = passengers, .cargo = cargo },
        } });
        try std.testing.expect(receipt == .applied);
        try std.testing.expectEqualDeep(expected_source, game.store(0).*);
        try std.testing.expectEqualDeep(initial_stock, game.store(route.chart).*);
        try std.testing.expectEqual(expected_passengers, game.reservedBeds(route.chart));
        try std.testing.expectEqual(id + 1, game.berthsUsed(route.chart));
        try std.testing.expectEqual(@as(u16, 8), game.people);
        try std.testing.expectEqual(game.people - expected_passengers, game.residents(0));
    }
    try std.testing.expect(gameplay.apply(&game, .{ .build_ship = .{ .island = 0, .hull = .brig } }) == .applied);
    try rejected(&game, .{ .send_expedition = .{ .ship = 2, .route = route_index, .manifest = .{ .settlers = 0, .cargo = .{ .water = 1 } } } });

    const elapsed = random.float(f32) * route.leg_seconds;
    const partial = gameplay.advanceVoyages(&game, elapsed);
    try std.testing.expectEqual(@as(usize, 0), partial.len);
    const encoded = save.encode(game);
    var restored = save.decode(&encoded) orelse return error.CouldNotRestore;
    try std.testing.expectEqualSlices(u8, &encoded, &save.encode(restored));
    const complete = gameplay.advanceVoyages(&restored, route.leg_seconds);
    try std.testing.expectEqual(@as(usize, domain.dock_capacity), complete.len);
    var reported: u16 = 0;
    for (complete.slice()) |arrival| {
        try std.testing.expectEqual(route.chart, arrival.expedition.island);
        try std.testing.expectEqual(domain.Game.ExpeditionEvent.delivered, arrival.expedition.event);
        reported += arrival.expedition.settlers;
    }
    try std.testing.expectEqual(expected_passengers, reported);
    try std.testing.expectEqual(expected_passengers, restored.residents(route.chart));
    try std.testing.expectEqualDeep(expected_arrival, restored.store(route.chart).*);
    try std.testing.expectEqual(@as(u16, 0), restored.reservedBeds(route.chart));
    const idle = gameplay.advanceVoyages(&restored, 2 * route.leg_seconds);
    try std.testing.expectEqual(@as(usize, 0), idle.len);
    try std.testing.expectEqualDeep(expected_arrival, restored.store(route.chart).*);
}

test "property: generated parallel voyages reserve capacity and conserve cargo and population across saves" {
    for (1..33) |seed| settlementCase(seed) catch |err| {
        std.debug.print("Voyage conservation seed={d}\n", .{seed});
        return err;
    };
}

fn waterCase(seed: u64) !void {
    var random_state = std.Random.DefaultPrng.init(seed);
    const random = random_state.random();
    var game = domain.Game.init();
    game.people = 1;
    game.store(0).* = stock(200);
    game.store(0).water = 0;
    game.diets[0].meat_deficit = random.intRangeAtMost(u8, 0, domain.weakness_limit);
    const cap = domain.waterCapacity(0);
    const count = cap / domain.well_yield + random.intRangeAtMost(u16, 1, 6);
    const grid = domain.geography.grids[0];
    var built: u16 = 0;
    var saturated: ?u16 = null;
    for (0..grid.area()) |index| {
        const cell = grid.cell(index);
        if (!domain.wellSite(cell, 0) or game.build(0, cell, .well) != null) continue;
        built += 1;
        const view = queries.ledger(&game, 0);
        try std.testing.expect(view.production.water <= view.water_limit);
        if (saturated) |limit| try std.testing.expectEqual(limit, view.production.water);
        if (built == cap / domain.well_yield) saturated = view.production.water;
        if (built == count) break;
    } else return error.NotEnoughWellSites;
    const before = queries.ledger(&game, 0);
    _ = gameplay.apply(&game, .{ .advance = gameplay.untilNextDay(&game) });
    try std.testing.expectEqual(before.production.water -| before.daily_demand, game.store(0).water);
}

test "property: extra wells respect the cap at every generated workforce size" {
    for (1..33) |seed| waterCase(seed) catch |err| {
        std.debug.print("Water capacity seed={d}\n", .{seed});
        return err;
    };
}

fn openIsland(game: *domain.Game, chart: usize) void {
    if (chart == 0) return;
    game.chartHarbor(chart);
    game.land(chart, 1, .{ .timber = 30, .grain = 10, .water = 10 });
}

fn producerFor(wanted: domain.Site) domain.Kind {
    return switch (wanted) {
        .outcrop => .quarry,
        .deer => .lodge,
        else => unreachable,
    };
}

fn resourceCase(seed: u64) !void {
    var random_state = std.Random.DefaultPrng.init(seed);
    const random = random_state.random();
    // Half the cases open on Java, as every new game does.
    const chart = if (random.boolean()) 0 else random.uintLessThan(usize, domain.settlement_count);
    const wanted: domain.Site = if (random.boolean()) .outcrop else .deer;
    const kind = producerFor(wanted);
    var game = domain.Game.init();
    openIsland(&game, chart);
    const budget = domain.roadBudget(chart);
    const sites = game.resourceSites(chart, wanted, budget);
    try std.testing.expect(sites.len >= domain.requiredSites(chart, wanted));

    // Every listed site accepts its producer through the command path, which
    // sits idle until the listed number of road tiles joins it to the harbor.
    const pick = random.uintLessThan(usize, sites.len);
    const cell = sites.slice()[pick];
    const cost = sites.roads[pick];
    try std.testing.expect(cost <= budget);
    try std.testing.expect(gameplay.apply(&game, .{ .build = .{ .island = chart, .cell = cell, .kind = kind } }) == .applied);
    const reached = game.connected(chart, cell);
    const output = struct {
        fn of(g: *const domain.Game, c: usize, k: domain.Kind) u16 {
            const made = queries.ledger(g, c).production;
            return if (k == .quarry) made.stone else made.venison;
        }
    }.of;
    try std.testing.expectEqual(reached, output(&game, chart, kind) > 0);
    var buffer: [64]domain.Cell = undefined;
    const path = game.roadPath(chart, cell, &buffer) orelse return error.TestUnexpectedResult;
    try std.testing.expect(path.len <= cost);
    try std.testing.expect(reached == (path.len == 0));
    game.store(chart).stone = @intCast(path.len);
    for (path) |step| try std.testing.expect(gameplay.apply(&game, .{ .build = .{ .island = chart, .cell = step, .kind = .road } }) == .applied);
    try std.testing.expect(game.connected(chart, cell));
    try std.testing.expect(output(&game, chart, kind) > 0);

    // Any other land tile near the harbor refuses the producer and leaves the game unchanged.
    const grid = domain.geography.grids[chart];
    const home = domain.quay(chart);
    const other = domain.Cell{
        .x = @min(grid.width - 1, (home.x -| 12) + random.uintLessThan(usize, 25)),
        .y = @min(grid.height - 1, (home.y -| 12) + random.uintLessThan(usize, 25)),
    };
    if (domain.site(other, chart) != wanted and game.tileAt(chart, other) == .empty)
        try rejected(&game, .{ .build = .{ .island = chart, .cell = other, .kind = kind } });
}

test "property: every generated island lets its first settlers quarry stone and hunt deer near the harbor" {
    for (1..129) |seed| resourceCase(seed) catch |err| {
        std.debug.print("Resource site seed={d}\n", .{seed});
        return err;
    };
}

test "property: generated invalid session clocks and speed tags are rejected" {
    var random_state = std.Random.DefaultPrng.init(0x5649534c4553);
    const random = random_state.random();
    const original = (save.Session{}).encodeSession();
    const time_index = original.len - 5;
    for (0..48) |_| {
        var bytes = original;
        bytes[bytes.len - 1] = random.intRangeAtMost(u8, 4, 255);
        try std.testing.expect(save.Session.decodeSession(&bytes) == null);
        bytes[bytes.len - 1] = 1;
        const time = domain.day_seconds + random.float(f32) * 900;
        std.mem.writeInt(u32, bytes[time_index..][0..4], @bitCast(time), .little);
        try std.testing.expect(save.Session.decodeSession(&bytes) == null);
    }
}

fn clockCase(seed: u64) !void {
    var random_state = std.Random.DefaultPrng.init(seed);
    const random = random_state.random();
    var game = domain.Game.init();
    game.store(0).* = stock(500);
    var total: f64 = 0;
    var days: u32 = 0;
    for (0..random.intRangeAtMost(usize, 20, 120)) |_| {
        const step = switch (random.intRangeAtMost(u8, 0, 3)) {
            0 => 0,
            1 => domain.day_seconds,
            2 => gameplay.untilNextDay(&game),
            else => random.float(f32) * domain.day_seconds,
        };
        const result = gameplay.apply(&game, .{ .advance = step });
        try std.testing.expect(result == .advanced);
        if (result.advanced.day != null) days += 1;
        total += step;
        try std.testing.expect(game.day_time >= 0 and game.day_time < domain.day_seconds);
        try std.testing.expectEqual(1 + days, game.day);
    }
    // Days follow the summed game time, give or take float rounding at a boundary.
    const expected = total / domain.day_seconds;
    try std.testing.expect(@abs(@as(f64, @floatFromInt(days)) - expected) < 1.0);
    const restored = save.Session.decodeSession(&(save.Session{ .game = game }).encodeSession()).?;
    try std.testing.expectEqual(game.day_time, restored.game.day_time);
}

test "property: the core clock keeps time within a day and ends each day exactly once" {
    for (1..33) |seed| clockCase(seed) catch |err| {
        std.debug.print("Clock seed={d}\n", .{seed});
        return err;
    };
}

fn randomCommand(random: std.Random, game: *const domain.Game) gameplay.Command {
    const islands = domain.settlement_count + 2; // include out-of-range islands
    return switch (random.intRangeAtMost(u8, 0, 15)) {
        0, 1 => blk: {
            const island = random.uintLessThan(usize, 3);
            const grid = domain.geography.grids[island];
            const cell = grid.cell(random.uintLessThan(usize, grid.area()));
            const kinds = [_]domain.Kind{ .cottage, .grove, .farm, .road, .quarry, .lodge, .well, .light };
            break :blk .{ .build = .{ .island = island, .cell = cell, .kind = kinds[random.uintLessThan(usize, kinds.len)] } };
        },
        2 => .{ .build_bridge = random.uintLessThan(usize, domain.crossings.len + 1) },
        3, 4 => blk: {
            // A road beside a bridgehead, so random play joins bridges.
            const crossing = domain.crossings[random.uintLessThan(usize, domain.crossings.len)];
            const side = random.uintLessThan(usize, 2);
            const head = crossing.heads[side];
            const cell = domain.Cell{ .x = (head.x + random.uintLessThan(usize, 7)) -| 3, .y = (head.y + random.uintLessThan(usize, 7)) -| 3 };
            break :blk .{ .build = .{ .island = crossing.charts[side], .cell = cell, .kind = .road } };
        },
        5 => .{ .survey_harbor = .{ .destination = random.uintLessThan(usize, 3), .manifest = .{
            .settlers = random.intRangeAtMost(u16, 0, 5),
            .cargo = stock(random.intRangeAtMost(u16, 0, 4)),
        } } },
        6 => .{ .send_ferry = .{ .destination = random.uintLessThan(usize, 3), .manifest = .{
            .settlers = random.intRangeAtMost(u16, 0, 4),
            .cargo = stock(random.intRangeAtMost(u16, 0, 4)),
        } } },
        7 => .{ .sail_ferry = random.uintLessThan(usize, 3) },
        8 => .{ .build_ship = .{ .island = random.uintLessThan(usize, 2), .hull = if (random.boolean()) .brig else .barque } },
        9 => .{ .survey_island = .{
            .ship = random.uintLessThan(usize, game.fleet.count + 1),
            .route = random.uintLessThan(usize, domain.ocean.routes.len),
            .manifest = .{ .settlers = random.intRangeAtMost(u16, 0, 5), .cargo = stock(random.intRangeAtMost(u16, 0, 3)) },
        } },
        10 => .{ .send_expedition = .{
            .ship = random.uintLessThan(usize, game.fleet.count + 1),
            .route = random.uintLessThan(usize, domain.ocean.routes.len),
            .manifest = .{ .settlers = random.intRangeAtMost(u16, 0, 3), .cargo = stock(random.intRangeAtMost(u16, 0, 3)) },
        } },
        11 => .{ .return_expedition = random.uintLessThan(usize, game.fleet.count + 1) },
        12 => .{ .export_grain = random.uintLessThan(usize, islands) },
        else => .{ .advance = random.float(f32) * domain.day_seconds },
    };
}

fn journalCase(seed: u64) !void {
    var random_state = std.Random.DefaultPrng.init(seed);
    const random = random_state.random();
    var game = domain.Game.init();
    game.coins = random.intRangeAtMost(u16, 0, 400);
    game.store(0).* = stock(random.intRangeAtMost(u16, 0, 300));
    if (seed % 2 == 0) {
        // Start half the cases with the opening charter complete so the
        // shipyard, surveys, and expeditions are reachable.
        game.store(0).* = stock(random.intRangeAtMost(u16, 100, 600));
        try std.testing.expect(game.build(0, .{ .x = 39, .y = 39 }, .cottage) == null);
        game.people = 8;
        game.ferry.surveyed = true;
        game.charter.won = true;
        game.bridges[0] = true;
        game.charter.ferried_to_bali = true;
        game.openPort(1);
    }
    // Record through the same decorator and file adapter the game uses.
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var recorder = try journal_file.Recorder.open(std.testing.io, temp.dir, "diagnostics");
    var closed = false;
    defer if (!closed) recorder.deinit();
    recorder.snapshot(.{ .game = game });
    var checkpoints: u64 = 0;
    for (0..random.intRangeAtMost(usize, 40, 400)) |_| {
        const command = randomCommand(random, &game);
        const before = save.encode(game);
        const before_time = game.day_time;
        const outcome = gameplay_trace.dispatch(.{ .journal = &recorder }, &game, command);
        if (outcome == .advanced and outcome.advanced.day != null) checkpoints += 1;
        // Invariants that hold after any command.
        try std.testing.expect(game.day_time >= 0 and game.day_time < domain.day_seconds);
        if (outcome == .denied) {
            try std.testing.expectEqualSlices(u8, &before, &save.encode(game));
            try std.testing.expectEqual(before_time, game.day_time);
        }
        const encoded = save.encode(game);
        try std.testing.expectEqualSlices(u8, &encoded, &save.encode(save.decode(&encoded) orelse return error.CouldNotRestore));
    }
    recorder.deinit();
    closed = true;
    const bytes = try temp.dir.readFileAlloc(std.testing.io, "diagnostics/" ++ journal_file.current_name, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    // Replaying the journal from its snapshot reproduces the live state exactly.
    const report = try journal.replay(bytes, .{});
    try std.testing.expect(report.divergence == null);
    try std.testing.expectEqual(checkpoints, report.checkpoints);
    try std.testing.expectEqualDeep(game, report.session.game);
    // Corrupting any recorded checkpoint is reported as a divergence.
    if (checkpoints == 0) return;
    const target = random.uintLessThan(u64, checkpoints);
    var at: usize = journal.header.len;
    var seen: u64 = 0;
    while (at < bytes.len) {
        const len = std.mem.readInt(u32, bytes[at + 1 ..][0..4], .little);
        if (bytes[at] == @backingInt(journal.Kind.checkpoint)) {
            if (seen == target) {
                bytes[at + journal.record_header_bytes + 4 + random.uintLessThan(usize, 8)] ^= @as(u8, 1) << random.int(u3);
                break;
            }
            seen += 1;
        }
        at += journal.record_header_bytes + len;
    }
    try std.testing.expect((try journal.replay(bytes, .{})).divergence != null);
}

test "property: generated command sequences keep invariants and replay exactly from the journal" {
    for (1..41) |seed| journalCase(seed) catch |err| {
        std.debug.print("Journal replay seed={d}\n", .{seed});
        return err;
    };
}

fn harvestCase(seed: u64) !void {
    var random_state = std.Random.DefaultPrng.init(seed);
    const random = random_state.random();
    var game = domain.Game.init();
    game.people = 1;
    game.store(0).* = stock(random.intRangeAtMost(u16, 72, 200));
    const woods = domain.Cell{ .x = 30, .y = 30 };
    const herd = domain.Cell{ .x = 30, .y = 35 };
    try std.testing.expect(gameplay.apply(&game, .{ .build = .{ .island = 0, .cell = woods, .kind = .grove } }) == .applied);
    try std.testing.expect(gameplay.apply(&game, .{ .build = .{ .island = 0, .cell = herd, .kind = .lodge } }) == .applied);
    game.paveTo(0, woods);
    game.paveTo(0, herd);
    var next: domain.Game = undefined;
    var observed_rest = false;
    const days = random.intRangeAtMost(u32, 7, 18);
    for (0..days) |_| {
        const before = save.encode(game);
        const ledger = queries.ledger(&game, 0);
        const result = gameplay.transition(&game, &next, .{ .advance = gameplay.untilNextDay(&game) });
        try std.testing.expect(result == .advanced and result.advanced.day != null);
        try std.testing.expectEqual(game.day + 1, next.day);
        try std.testing.expectEqualSlices(u8, &before, &save.encode(game));
        try std.testing.expectEqual(game.store(0).timber + ledger.production.timber, next.store(0).timber);
        try std.testing.expectEqual(game.store(0).venison + ledger.production.venison - ledger.daily_demand, next.store(0).venison);
        const wood = next.harvestStatus(0, woods).?;
        const deer = next.harvestStatus(0, herd).?;
        try std.testing.expect(wood.stock <= domain.harvest_capacity and deer.stock <= domain.harvest_capacity);
        if (wood.days_to_recover > 0) {
            try std.testing.expectEqual(@as(u16, 1), next.production(0).timber);
            observed_rest = true;
        }
        if (deer.days_to_recover > 0) try std.testing.expectEqual(@as(u16, 0), next.production(0).venison);
        game = next;
    }
    try std.testing.expect(observed_rest);
}

test "property: generated harvest schedules stay finite and commute with pure state transitions" {
    for (1..17) |seed| harvestCase(seed) catch |err| {
        std.debug.print("Harvest schedule seed={d}\n", .{seed});
        return err;
    };
}
