const std = @import("std");
const s = @import("colony.zig");

pub const pulse_seconds: f32 = 1.6;

pub const Warning = struct {
    last_drop: ?f32 = null,
    active: bool = false,
    pulse_elapsed: f32 = 0,

    fn observe(warning: *Warning, previous: u16, amount: u16, threshold: u16, elapsed: f32, dt: f32) void {
        if (amount < previous) warning.last_drop = elapsed;
        if (amount > previous) warning.last_drop = null;
        const recent_drop = if (warning.last_drop) |drop| elapsed - drop < s.day_seconds else false;
        const active = recent_drop and amount < threshold;
        warning.pulse_elapsed = if (active and warning.active) @min(pulse_seconds, warning.pulse_elapsed + dt) else 0;
        warning.active = active;
    }
};

/// The stock each island draws on.
fn pooled(g: *const s.Game) [s.settlement_count]s.Stores {
    var stocks: [s.settlement_count]s.Stores = undefined;
    for (&stocks, 0..) |*stock, chart| stock.* = g.stockOf(chart);
    return stocks;
}

pub const Tracker = struct {
    previous: [s.settlement_count]s.Stores,
    islands: [s.settlement_count][s.store_fields.len]Warning = @splat(@splat(.{})),

    pub fn init(g: *const s.Game) Tracker {
        return .{ .previous = pooled(g) };
    }

    pub fn observe(tracker: *Tracker, g: *const s.Game, elapsed: f32, dt: f32) void {
        for (0..s.settlement_count) |chart| {
            // Islands joined over a bridge watch their shared stockpile.
            const local = g.stockOf(chart);
            const meals = 3 *| g.sharedDemand(chart);
            const thresholds = s.Stores{ .timber = 12, .stone = 6, .grain = meals, .venison = meals, .fruit = meals, .water = meals };
            inline for (s.store_fields, 0..) |field, index| {
                tracker.islands[chart][index].observe(@field(tracker.previous[chart], field), @field(local, field), @field(thresholds, field), elapsed, dt);
            }
        }
        tracker.previous = pooled(g);
    }
};

test "warnings track falling stock and recover independently for each island and material" {
    var g = s.Game.init();
    g.store(0).* = .{ .timber = 12, .stone = 5, .grain = 10, .venison = 3, .fruit = 3, .water = 3 };
    g.store(1).* = .{ .timber = 5, .stone = 6 };
    var warnings = Tracker.init(&g);
    warnings.observe(&g, 0, 0);
    try std.testing.expect(!warnings.islands[0][1].active);
    try std.testing.expect(!warnings.islands[1][0].active);

    g.store(0).timber -= 1;
    g.store(0).grain -= 1;
    g.store(0).venison -= 1;
    g.store(0).fruit -= 1;
    g.store(0).water -= 1;
    g.store(1).stone -= 1;
    warnings.observe(&g, 1, 0.1);
    try std.testing.expect(warnings.islands[0][0].active);
    try std.testing.expect(!warnings.islands[0][1].active);
    try std.testing.expect(!warnings.islands[0][2].active);
    for (warnings.islands[0][3..]) |warning| try std.testing.expect(warning.active);
    try std.testing.expect(!warnings.islands[1][0].active);
    try std.testing.expect(warnings.islands[1][1].active);

    g.store(0).timber = 0;
    warnings.observe(&g, 2, 0.2);
    try std.testing.expectEqual(@as(f32, 0.2), warnings.islands[0][0].pulse_elapsed);
    g.store(0).water += 1;
    warnings.observe(&g, 8, 0.5);
    try std.testing.expect(warnings.islands[0][0].active);
    try std.testing.expect(!warnings.islands[0][5].active);
    try std.testing.expect(!warnings.islands[1][1].active);
    warnings.observe(&g, 9, 0.5);
    try std.testing.expect(!warnings.islands[0][0].active);
}

test "the ration warning scales with the local population" {
    var g = s.Game.init();
    g.people = 6;
    g.island_people[0] = 4;
    g.ferry.surveyed = true;
    g.store(0).grain = 6;
    g.store(1).grain = 6;
    var warnings = Tracker.init(&g);
    g.store(0).grain -= 1;
    g.store(1).grain -= 1;
    warnings.observe(&g, 1, 0.1);
    try std.testing.expect(!warnings.islands[0][2].active);
    try std.testing.expect(warnings.islands[1][2].active);
}
