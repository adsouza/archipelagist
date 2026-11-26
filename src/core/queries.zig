// Read-side projections share the live aggregate and never mutate it.
const domain = @import("colony.zig");

pub const Ledger = struct {
    chart: usize,
    residents: u16,
    housing: u16,
    landing_capacity: u16,
    berths_used: usize,
    berth_capacity: usize,
    /// The stockpile this island draws on, shared with any islands joined to it.
    stock: domain.Stores,
    /// Another island sharing that stockpile, if any.
    shared_with: ?usize,
    production: domain.Stores,
    daily_demand: u16,
    /// What every island sharing the stockpile uses in a day.
    shared_demand: u16,
    water_limit: u16,
    workforce: u16,
    diet: domain.Diet,
    goals: [3]?domain.Goal,
};

fn sharedWith(game: *const domain.Game, chart: usize) ?usize {
    for (game.group(chart), 0..) |member, island| {
        if (member and island != chart) return island;
    }
    return null;
}

pub fn ledger(game: *const domain.Game, chart: usize) Ledger {
    return .{
        .chart = chart,
        .residents = game.residents(chart),
        .housing = game.housing(chart),
        .landing_capacity = game.landingCapacity(chart),
        .berths_used = game.berthsUsed(chart),
        .berth_capacity = game.berthCapacity(chart),
        .stock = game.stockOf(chart),
        .shared_with = sharedWith(game, chart),
        .production = game.production(chart),
        .daily_demand = game.dailyDemand(chart),
        .shared_demand = game.sharedDemand(chart),
        .water_limit = domain.waterCapacity(chart),
        .workforce = game.workforce(chart),
        .diet = game.diets[chart],
        .goals = game.nextGoals(),
    };
}
