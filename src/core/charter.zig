// Charter goals and milestones.
const std = @import("std");
const colony = @import("colony.zig");
const Game = colony.Game;
const geography = colony.geography;

pub const charter_fleet_size = 4;

/// The island the opening charter settles. The ferry may survey it before
/// the charter is complete.
pub const charter_island = 1;

pub const Goal = enum {
    house_settlers,
    ferry_settlers,
    lighthouse,
    bridge,
    build_brig,
    chart_lombok,
    build_barque,
    chart_palawan,
    settle_borneo,
    settle_sumatra,
    build_fleet,
    settle_sulawesi,
    settle_luzon,
    settle_new_guinea,

    pub fn title(goal: Goal) [:0]const u8 {
        return switch (goal) {
            .house_settlers => "House and feed 8 settlers",
            .ferry_settlers => "Ferry settlers to Bali",
            .lighthouse => "Raise the lighthouse",
            .bridge => "Bridge the islands",
            .build_brig => "Build a survey brig",
            .chart_lombok => "Chart Lombok",
            .build_barque => "Build an ocean barque",
            .chart_palawan => "Chart Palawan",
            .settle_borneo => "Settle Borneo",
            .settle_sumatra => "Settle Sumatra",
            .build_fleet => std.fmt.comptimePrint("Build {d} expedition ships", .{charter_fleet_size}),
            .settle_sulawesi => "Settle Sulawesi",
            .settle_luzon => "Settle Luzon",
            .settle_new_guinea => "Settle New Guinea",
        };
    }
};

/// Milestones of the opening charter that are not derivable from the map.
pub const Charter = struct {
    ferried_to_bali: bool = false,
    /// The lighthouse on Bali has been raised.
    won: bool = false,
    housed_eight: bool = false,
};

pub fn charterComplete(g: *const Game) bool {
    return g.charter.won and g.bridge and g.charter.ferried_to_bali;
}

pub fn hasFounded(g: *const Game, chart: usize) bool {
    return g.founded[chart - geography.borneo];
}

pub fn nextGoals(g: *const Game) [3]?Goal {
    const order = [_]Goal{
        .house_settlers, .ferry_settlers,  .lighthouse,    .bridge,            .build_brig,
        .chart_lombok,   .build_barque,    .settle_borneo, .settle_sumatra,    .chart_palawan,
        .build_fleet,    .settle_sulawesi, .settle_luzon,  .settle_new_guinea,
    };
    var next: [3]?Goal = @splat(null);
    var count_goals: usize = 0;
    for (order) |goal| {
        const accomplished = switch (goal) {
            .house_settlers => g.charter.housed_eight or g.people >= 8,
            .ferry_settlers => g.charter.ferried_to_bali,
            .lighthouse => g.charter.won,
            .bridge => g.bridge,
            .build_brig => g.fleet.count != 0,
            .chart_lombok => g.fleet.charted[0],
            .build_barque => g.hasBarque(),
            .chart_palawan => g.fleet.charted[1],
            .settle_borneo => g.hasFounded(geography.borneo),
            .settle_sumatra => g.hasFounded(geography.sumatra),
            .build_fleet => g.fleet.count >= charter_fleet_size,
            .settle_sulawesi => g.hasFounded(comptime geography.chartNamed("Sulawesi").?),
            .settle_luzon => g.hasFounded(comptime geography.chartNamed("Luzon").?),
            .settle_new_guinea => g.hasFounded(comptime geography.chartNamed("New Guinea").?),
        };
        if (accomplished) continue;
        next[count_goals] = goal;
        count_goals += 1;
        if (count_goals == next.len) break;
    }
    return next;
}

test "housing eight settlers is remembered after the population falls" {
    var g = Game.init();
    g.people = 7;
    try std.testing.expectEqual(@as(?Goal, .house_settlers), nextGoals(&g)[0]);
    g.people = 8;
    try std.testing.expect(nextGoals(&g)[0] != .house_settlers);
    g.stores[0] = .{ .grain = 200, .venison = 200, .fruit = 200, .water = 200 };
    _ = g.tick();
    try std.testing.expect(g.charter.housed_eight);
    g.people = 2;
    try std.testing.expect(nextGoals(&g)[0] != .house_settlers);
}
