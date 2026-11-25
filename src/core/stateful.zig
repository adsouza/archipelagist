// Stateful property tests. Generates random command sequences, runs them
// through the real decorator and journal, checks conservation and capacity
// invariants after every step, and shrinks any failing sequence to a minimal
// reproduction, printed as one JSON command per line.
const std = @import("std");
const domain = @import("colony.zig");
const gameplay = @import("gameplay.zig");
const save = @import("save.zig");
const journal = @import("journal.zig");

const Command = gameplay.Command;
const Stores = domain.Stores;

// ---------------------------------------------------------------- scenarios

pub const Scenario = enum {
    /// The opening charter, as a new game starts.
    fresh,
    /// The opening charter complete, so ships, surveys, and expeditions are open.
    chartered,

    pub fn start(scenario: Scenario, seed: u64) domain.Game {
        var random_state = std.Random.DefaultPrng.init(seed);
        const random = random_state.random();
        var game = domain.Game.init();
        game.coins = random.intRangeAtMost(u16, 0, 400);
        game.stores[0] = uniform(random.intRangeAtMost(u16, 0, 300));
        if (scenario == .chartered) {
            game.stores[0] = uniform(random.intRangeAtMost(u16, 100, 600));
            game.stores[1] = uniform(random.intRangeAtMost(u16, 0, 80));
            // A second cottage on the first open ground near the harbor.
            const grid = domain.geography.grids[0];
            for (0..grid.area()) |index| {
                if (game.build(0, grid.cell(index), .cottage) == null) break;
            }
            game.people = 8;
            game.ferry.surveyed = true;
            game.charter.won = true;
            game.bridge = true;
            game.charter.ferried_to_bali = true;
            game.openPort(1);
        }
        return game;
    }
};

fn uniform(units: u16) Stores {
    return .{ .timber = units, .stone = units, .grain = units, .venison = units, .fruit = units, .water = units };
}

// ---------------------------------------------------------------- generation

/// Java, or a harbor within the ferry's range of Bali.
fn ferryHarbor(random: std.Random) usize {
    const near = domain.ferry.neighbors(1);
    const pick = random.uintLessThan(usize, near.len + 2);
    return if (pick == 0) 0 else if (pick == 1) 1 else near.items[pick - 2];
}

/// Commands are generated without looking at the state, so any subsequence
/// of a failing sequence is still a meaningful sequence to shrink to.
pub fn randomCommand(random: std.Random) Command {
    const ships = 4;
    const routes = 6;
    return switch (random.intRangeAtMost(u8, 0, 17)) {
        0, 1 => blk: {
            const island = random.uintLessThan(usize, 3);
            const grid = domain.geography.grids[island];
            const kinds = [_]domain.Kind{ .cottage, .grove, .farm, .road, .quarry, .lodge, .well, .light };
            break :blk .{ .build = .{
                .island = island,
                .cell = grid.cell(random.uintLessThan(usize, grid.area())),
                .kind = kinds[random.uintLessThan(usize, kinds.len)],
            } };
        },
        2 => .build_bridge,
        3 => .{ .cross_bridge = random.uintLessThan(usize, 3) },
        4 => .{ .transfer_stores = .{ .source = random.uintLessThan(usize, 3), .cargo = uniform(random.intRangeAtMost(u16, 0, 6)) } },
        5 => .{ .survey_harbor = ferryHarbor(random) },
        6 => .{ .send_ferry = .{ .destination = ferryHarbor(random), .manifest = .{
            .settlers = random.intRangeAtMost(u16, 0, 5),
            .cargo = uniform(random.intRangeAtMost(u16, 0, 5)),
        } } },
        7 => .{ .sail_ferry = ferryHarbor(random) },
        8 => .{ .build_ship = .{ .island = random.uintLessThan(usize, 2), .hull = if (random.boolean()) .brig else .barque } },
        9 => .{ .survey_island = .{ .ship = random.uintLessThan(usize, ships), .route = random.uintLessThan(usize, routes) } },
        10 => .{ .send_expedition = .{
            .ship = random.uintLessThan(usize, ships),
            .route = random.uintLessThan(usize, routes),
            .manifest = .{ .settlers = random.intRangeAtMost(u16, 0, 4), .cargo = uniform(random.intRangeAtMost(u16, 0, 4)) },
        } },
        11 => .{ .return_expedition = random.uintLessThan(usize, ships) },
        12 => .{ .export_grain = random.uintLessThan(usize, domain.settlement_count + 2) },
        13 => .{ .advance = domain.day_seconds },
        14 => .{ .advance = 3.0 / 60.0 },
        else => .{ .advance = random.float(f32) * domain.day_seconds },
    };
}

// ---------------------------------------------------------------- invariants

pub const Violation = struct {
    invariant: []const u8,
    detail: [96]u8 = @splat(0),

    fn init(invariant: []const u8, comptime format: []const u8, args: anytype) Violation {
        var v = Violation{ .invariant = invariant };
        _ = std.fmt.bufPrint(&v.detail, format, args) catch {};
        return v;
    }

    pub fn text(v: *const Violation) []const u8 {
        return std.mem.sliceTo(&v.detail, 0);
    }
};

/// Goods in the world: island stores plus cargo aboard the ferry and ships.
/// Voyage rations are debited at departure, so they are not in transit.
pub const Totals = struct {
    goods: [6]u64 = @splat(0),
    coins: u16,
    people: u16,

    pub fn of(game: *const domain.Game) Totals {
        var totals = Totals{ .coins = game.coins, .people = game.people };
        for (game.stores) |stock| totals.addStores(stock);
        totals.addStores(game.ferry.cargo);
        for (game.vessels()) |vessel| totals.addStores(vessel.cargo);
        return totals;
    }

    fn addStores(totals: *Totals, stock: Stores) void {
        inline for (domain.store_fields, 0..) |name, i| totals.goods[i] += @field(stock, name);
    }
};

fn resourceName(i: usize) []const u8 {
    inline for (domain.store_fields, 0..) |name, index| if (i == index) return name;
    unreachable;
}

/// Checks every invariant for one step. `before` is the state the command ran on.
pub fn check(before: *const domain.Game, after: *const domain.Game, command: Command, outcome: gameplay.Outcome) ?Violation {
    const was = Totals.of(before);
    const now = Totals.of(after);

    // Atomicity: a denied command changes nothing.
    if (outcome == .denied) {
        if (!std.mem.eql(u8, &save.encode(before.*), &save.encode(after.*)) or before.day_time != after.day_time)
            return .init("denied commands leave the state unchanged", "{s} was denied but changed the state", .{@tagName(command)});
        return null;
    }

    // Conservation of goods, coins, and settlers.
    const ended_day = outcome == .advanced and outcome.advanced.day != null;
    if (!ended_day) {
        if (now.people != was.people)
            return .init("settlers are conserved between days", "{s}: {d} -> {d}", .{ @tagName(command), was.people, now.people });
        for (was.goods, now.goods, 0..) |a, b, i| {
            const exact = command == .advance;
            if ((exact and a != b) or b > a)
                return .init(if (exact) "goods in transit are conserved" else "commands never create goods", "{s}: {s} {d} -> {d}", .{ @tagName(command), resourceName(i), a, b });
        }
        const earned: u16 = if (command == .export_grain) 10 else 0;
        if (now.coins > was.coins +| earned)
            return .init("only exports earn coins", "{s}: {d} -> {d}", .{ @tagName(command), was.coins, now.coins });
    } else if (now.people > was.people + 1) {
        return .init("at most one settler is born per day", "{d} -> {d}", .{ was.people, now.people });
    }

    // Calendar.
    if (!(after.day_time >= 0 and after.day_time < domain.day_seconds))
        return .init("the time of day stays within a day", "day_time {d}", .{after.day_time});
    if (after.day != before.day + @intFromBool(ended_day))
        return .init("each ended day advances the calendar once", "day {d} -> {d}", .{ before.day, after.day });

    // Capacity.
    if (after.awayFromJava() > after.people)
        return .init("settlers away from Java are counted in the population", "{d} away of {d}", .{ after.awayFromJava(), after.people });
    if (after.fleet.count > after.fleet.vessels.len)
        return .init("the fleet fits its roster", "{d} ships", .{after.fleet.count});
    if (after.ferry.cargo.units() > domain.ferry_hold)
        return .init("ferry cargo fits the hold", "{d} units", .{after.ferry.cargo.units()});
    if (after.ferry.passengers > domain.ferry_capacity)
        return .init("ferry passengers fit the ferry", "{d} passengers", .{after.ferry.passengers});
    const ferry = after.ferry;
    if (!after.islandOpen(ferry.origin))
        return .init("the ferry sails from an open harbor", "origin {d}", .{ferry.origin});
    if (ferry.moored() == null) {
        if (!domain.ferry.withinRange(ferry.origin, ferry.destination))
            return .init("the ferry sails within range", "{d} to {d}", .{ ferry.origin, ferry.destination });
        if (!(ferry.sailing_time >= 0 and ferry.sailing_time < ferry.legSeconds()))
            return .init("the ferry is part way across", "{d} of {d} seconds", .{ ferry.sailing_time, ferry.legSeconds() });
        if (ferry.surveying == after.islandOpen(ferry.destination))
            return .init("the ferry surveys only uncharted harbors and sails only to charted ones", "destination {d}", .{ferry.destination});
        if (ferry.surveying and (ferry.passengers != 0 or !ferry.cargo.empty()))
            return .init("a survey carries no load", "{d} passengers", .{ferry.passengers});
    } else if (ferry.sailing_time != 0 or ferry.surveying or ferry.passengers != 0 or !ferry.cargo.empty())
        return .init("a moored ferry is unloaded", "at {d}", .{ferry.origin});
    for (after.vessels(), 0..) |vessel, id| {
        if (vessel.cargo.units() > vessel.ship.hold())
            return .init("ship cargo fits the hold", "ship {d}: {d} units", .{ id, vessel.cargo.units() });
        if (vessel.passengers > vessel.ship.passengerCapacity())
            return .init("ship passengers fit the ship", "ship {d}: {d} passengers", .{ id, vessel.passengers });
    }
    for (0..domain.settlement_count) |chart| {
        if (after.berthsUsed(chart) > domain.dock_capacity)
            return .init("docks never exceed their berths", "chart {d}: {d} berths", .{ chart, after.berthsUsed(chart) });
        if (chart != 0 and after.residents(chart) +| after.reservedBeds(chart) > @max(after.landingCapacity(chart), before.residents(chart) +| before.reservedBeds(chart)))
            return .init("arrivals never exceed landing space", "chart {d}: {d} + {d} booked, room {d}", .{ chart, after.residents(chart), after.reservedBeds(chart), after.landingCapacity(chart) });
    }

    // Persistence: every reachable state survives a save.
    const encoded = save.encode(after.*);
    const decoded = save.decode(&encoded) orelse return .init("every state can be saved", "{s} produced an unsaveable state", .{@tagName(command)});
    if (!std.mem.eql(u8, &encoded, &save.encode(decoded)))
        return .init("saves round-trip exactly", "{s} produced a state that changes on reload", .{@tagName(command)});
    return null;
}

// ---------------------------------------------------------------- running

pub const Failure = struct {
    step: usize,
    violation: Violation,
};

pub const Checker = *const fn (*const domain.Game, *const domain.Game, Command, gameplay.Outcome) ?Violation;

/// Run a sequence from a scenario and return the first violation, if any.
/// A replay of the recorded journal must also reproduce the final state.
pub fn run(gpa: std.mem.Allocator, scenario: Scenario, seed: u64, commands: []const Command, checker: Checker) !?Failure {
    var game = scenario.start(seed);
    var builder = try journal.Builder.init(gpa, .{ .game = game });
    defer builder.deinit();
    for (commands, 0..) |command, step| {
        const before = game;
        const outcome = try builder.dispatch(&game, command);
        if (checker(&before, &game, command, outcome)) |violation| return .{ .step = step, .violation = violation };
    }
    const report = try journal.replay(builder.list.items, .{});
    if (report.divergence != null or !std.meta.eql(report.session.game, game))
        return .{ .step = commands.len, .violation = .init("the journal replays to the same state", "replay diverged", .{}) };
    return null;
}

// ---------------------------------------------------------------- shrinking

/// Reports whether a candidate sequence still fails the same way.
pub fn Oracle(comptime Context: type) type {
    return *const fn (Context, []const Command) bool;
}

/// Shrink a failing sequence: cut everything after the failure, delete
/// ever smaller chunks, then simplify the commands that remain. Returns a
/// sequence that still fails but where no single step of these kinds helps.
pub fn shrink(comptime Context: type, gpa: std.mem.Allocator, context: Context, failing: []const Command, fails: Oracle(Context)) ![]Command {
    var current: std.ArrayList(Command) = .empty;
    errdefer current.deinit(gpa);
    try current.appendSlice(gpa, failing);
    std.debug.assert(fails(context, current.items));

    var progress = true;
    while (progress) {
        progress = false;
        // Delete chunks, from half the sequence down to single commands.
        var chunk = @max(current.items.len / 2, 1);
        while (chunk >= 1) : (chunk /= 2) {
            var start: usize = 0;
            while (start < current.items.len) {
                const end = @min(start + chunk, current.items.len);
                var candidate: std.ArrayList(Command) = .empty;
                defer candidate.deinit(gpa);
                try candidate.appendSlice(gpa, current.items[0..start]);
                try candidate.appendSlice(gpa, current.items[end..]);
                if (candidate.items.len < current.items.len and fails(context, candidate.items)) {
                    std.mem.swap(std.ArrayList(Command), &current, &candidate);
                    progress = true;
                } else start += chunk;
            }
            if (chunk == 1) break;
        }
        // Merge neighbouring advances that fit in one step.
        var i: usize = 0;
        while (i + 1 < current.items.len) {
            const a = current.items[i];
            const b = current.items[i + 1];
            if (a == .advance and b == .advance) {
                const total = a.advance + b.advance;
                const merged = total <= domain.day_seconds;
                // Otherwise keep the total time but make the first step a whole day.
                const rebalanced = !merged and a.advance != domain.day_seconds;
                if (merged or rebalanced) {
                    var candidate: std.ArrayList(Command) = .empty;
                    defer candidate.deinit(gpa);
                    try candidate.appendSlice(gpa, current.items[0..i]);
                    if (merged) {
                        try candidate.append(gpa, .{ .advance = total });
                    } else {
                        try candidate.append(gpa, .{ .advance = domain.day_seconds });
                        try candidate.append(gpa, .{ .advance = total - domain.day_seconds });
                    }
                    try candidate.appendSlice(gpa, current.items[i + 2 ..]);
                    if (fails(context, candidate.items)) {
                        std.mem.swap(std.ArrayList(Command), &current, &candidate);
                        progress = true;
                        if (merged) continue;
                    }
                }
            }
            i += 1;
        }
        // Simplify each command's fields toward zero.
        for (current.items) |*slot| {
            for (simpler(slot.*).slice()) |option| {
                const kept = slot.*;
                slot.* = option;
                if (fails(context, current.items)) {
                    progress = true;
                    break;
                }
                slot.* = kept;
            }
        }
    }
    return current.toOwnedSlice(gpa);
}

const Options = struct {
    items: [16]Command = undefined,
    len: usize = 0,

    fn slice(o: *const Options) []const Command {
        return o.items[0..o.len];
    }

    fn add(o: *Options, command: Command) void {
        if (o.len < o.items.len) {
            o.items[o.len] = command;
            o.len += 1;
        }
    }
};

/// Strictly simpler variants of a command, simplest first.
fn simpler(command: Command) Options {
    var out = Options{};
    switch (command) {
        .advance => |seconds| {
            // Round values are simpler than arbitrary ones, and smaller round
            // values are simpler than larger ones.
            const round = [_]f32{ 0, 1, domain.day_seconds / 2, domain.day_seconds };
            const is_round = std.mem.indexOfScalar(f32, &round, seconds) != null;
            for (round) |simple| {
                if (simple != seconds and (!is_round or simple < seconds)) out.add(.{ .advance = simple });
            }
        },
        inline else => |payload, tag| {
            const P = @TypeOf(payload);
            if (P != void) {
                var reduced: [8]P = undefined;
                const count = reduceValue(P, payload, &reduced);
                for (reduced[0..count]) |value| out.add(@unionInit(Command, @tagName(tag), value));
            }
        },
    }
    return out;
}

/// Writes up to `out.len` simpler values of `value`, lowering one field at a time.
fn reduceValue(comptime T: type, value: T, out: []T) usize {
    var count: usize = 0;
    switch (@typeInfo(T)) {
        .int => {
            if (value != 0 and count < out.len) {
                out[count] = 0;
                count += 1;
            }
            if (value > 1 and count < out.len) {
                out[count] = value / 2;
                count += 1;
            }
        },
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| {
            var options: [4]Field = undefined;
            const n = reduceValue(Field, @field(value, name), &options);
            for (options[0..n]) |option| {
                if (count == out.len) break;
                out[count] = value;
                @field(out[count], name) = option;
                count += 1;
            }
        },
        else => {},
    }
    return count;
}

// ---------------------------------------------------------------- reporting

/// Print a minimal failing sequence, one JSON command per line.
pub fn printFailure(scenario: Scenario, seed: u64, commands: []const Command, failure: Failure) void {
    std.debug.print(
        "\nStateful property failed: {s}\n  {s}\n  scenario .{s}, seed {d}, step {d} of {d} after shrinking:\n",
        .{ failure.violation.invariant, failure.violation.text(), @tagName(scenario), seed, failure.step + 1, commands.len },
    );
    for (commands) |command| std.debug.print("    {f},\n", .{std.json.fmt(command, .{})});
}

const ShrinkContext = struct {
    gpa: std.mem.Allocator,
    scenario: Scenario,
    seed: u64,
    invariant: []const u8,
    checker: Checker,
};

fn stillFails(context: ShrinkContext, commands: []const Command) bool {
    const failure = (run(context.gpa, context.scenario, context.seed, commands, context.checker) catch return false) orelse return false;
    return std.mem.eql(u8, failure.violation.invariant, context.invariant);
}

/// Generate, run, and on failure shrink and report. Returns the failure.
pub fn explore(gpa: std.mem.Allocator, scenario: Scenario, seed: u64, length: usize, checker: Checker, verbose: bool) !?Failure {
    var random_state = std.Random.DefaultPrng.init(seed ^ 0x9e3779b97f4a7c15);
    const random = random_state.random();
    const commands = try gpa.alloc(Command, length);
    defer gpa.free(commands);
    for (commands) |*command| command.* = randomCommand(random);
    const failure = (try run(gpa, scenario, seed, commands, checker)) orelse return null;
    const context = ShrinkContext{ .gpa = gpa, .scenario = scenario, .seed = seed, .invariant = failure.violation.invariant, .checker = checker };
    const minimal = try shrink(ShrinkContext, gpa, context, commands[0..@min(failure.step + 1, commands.len)], stillFails);
    defer gpa.free(minimal);
    const shrunk = (try run(gpa, scenario, seed, minimal, checker)) orelse failure;
    if (verbose) printFailure(scenario, seed, minimal, shrunk);
    return shrunk;
}

// ---------------------------------------------------------------- tests

test "property: random command sequences conserve goods and settlers and respect capacity" {
    const gpa = std.testing.allocator;
    for ([_]Scenario{ .fresh, .chartered }) |scenario| {
        for (1..25) |seed| {
            if (try explore(gpa, scenario, seed, 300, check, true)) |_| return error.StatefulPropertyFailed;
        }
    }
}

/// A planted failure: two grain exports and a day that has ended.
fn plantedOracle(_: void, commands: []const Command) bool {
    var game = domain.Game.init();
    game.coins = 0;
    game.stores[0].grain = 100;
    for (commands) |command| {
        _ = gameplay.apply(&game, command);
        if (game.day > 1 and game.coins >= 20) return true;
    }
    return false;
}

test "shrinking reduces a failing sequence to its essential commands" {
    const gpa = std.testing.allocator;
    var random_state = std.Random.DefaultPrng.init(7);
    const random = random_state.random();
    var noisy: std.ArrayList(Command) = .empty;
    defer noisy.deinit(gpa);
    for (0..60) |i| {
        try noisy.append(gpa, randomCommand(random));
        if (i % 20 == 0) try noisy.append(gpa, .{ .export_grain = 0 });
    }
    try noisy.append(gpa, .{ .advance = domain.day_seconds });
    try std.testing.expect(plantedOracle({}, noisy.items));
    const minimal = try shrink(void, gpa, {}, noisy.items, plantedOracle);
    defer gpa.free(minimal);
    // Two exports and one advance that ends the day are all that matter.
    try std.testing.expectEqual(@as(usize, 3), minimal.len);
    var exports: usize = 0;
    for (minimal) |command| switch (command) {
        .export_grain => |island| {
            try std.testing.expectEqual(@as(usize, 0), island);
            exports += 1;
        },
        .advance => |seconds| try std.testing.expectEqual(domain.day_seconds, seconds),
        else => return error.UnexpectedCommand,
    };
    try std.testing.expectEqual(@as(usize, 2), exports);
}

test "a planted conservation bug is caught and shrunk" {
    const gpa = std.testing.allocator;
    const failure = (try explore(gpa, .fresh, 3, 200, leakyCheck, false)) orelse return error.PlantedBugMissed;
    try std.testing.expectEqualStrings("planted leak", failure.violation.invariant);
}

/// Wraps the real checker and flags every applied export, standing in for a rule bug.
fn leakyCheck(before: *const domain.Game, after: *const domain.Game, command: Command, outcome: gameplay.Outcome) ?Violation {
    if (command == .export_grain and outcome == .applied) return .init("planted leak", "", .{});
    return check(before, after, command, outcome);
}
