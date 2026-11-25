// Read-side projections share the live aggregate and never mutate it.
const domain = @import("colony.zig");

pub const Ledger = struct {
    chart: usize,
    residents: u16,
    housing: u16,
    landing_capacity: u16,
    berths_used: usize,
    stock: domain.Stores,
    production: domain.Stores,
    daily_demand: u16,
    water_limit: u16,
    workforce: u16,
    diet: domain.Diet,
    goals: [3]?domain.Goal,
};

pub fn ledger(game: *const domain.Game, chart: usize) Ledger {
    return .{
        .chart = chart,
        .residents = game.residents(chart),
        .housing = game.housing(chart),
        .landing_capacity = game.landingCapacity(chart),
        .berths_used = game.berthsUsed(chart),
        .stock = game.stores[chart],
        .production = game.production(chart),
        .daily_demand = game.dailyDemand(chart),
        .water_limit = domain.waterCapacity(chart),
        .workforce = game.workforce(chart),
        .diet = game.diets[chart],
        .goals = game.nextGoals(),
    };
}
