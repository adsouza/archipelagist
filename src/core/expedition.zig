const geography = @import("geography.zig");
const baked = @import("expedition_routes.zig");

pub const Ship = enum(u8) {
    none,
    brig,
    barque,

    pub fn name(ship: Ship) [:0]const u8 {
        return switch (ship) {
            .none => "No expedition ship",
            .brig => "Survey brig",
            .barque => "Ocean barque",
        };
    }

    pub fn passengerCapacity(ship: Ship) u16 {
        return ship.crew();
    }

    pub fn crew(ship: Ship) u16 {
        return switch (ship) {
            .none => 0,
            .brig => 4,
            .barque => 6,
        };
    }

    pub fn hold(ship: Ship) u16 {
        return switch (ship) {
            .none => 0,
            .brig => 120,
            .barque => 288,
        };
    }

    pub fn canSail(ship: Ship, route: Route) bool {
        return @backingInt(ship) >= @backingInt(route.ship);
    }
};

/// Game seconds a crew spends ashore before turning for home.
pub const landing_seconds = 2;

pub const Route = struct {
    chart: usize,
    leg_seconds: f32,
    ship: Ship,
    reserve_per_supply: u16 = 0,

    /// Outbound leg, the landing, and the homeward leg.
    pub fn provisionTime(route: Route) f32 {
        return 2 * route.leg_seconds + landing_seconds;
    }

    pub fn name(route: Route) [:0]const u8 {
        return geography.names[route.chart];
    }
};

pub const routes = [_]Route{
    .{ .chart = 2, .leg_seconds = 15, .ship = .brig },
    .{ .chart = geography.palawan, .leg_seconds = 27, .ship = .barque, .reserve_per_supply = 15 },
    .{ .chart = geography.borneo, .leg_seconds = 23, .ship = .brig },
    .{ .chart = geography.sumatra, .leg_seconds = 54, .ship = .barque },
} ++ blk: {
    var additional: [geography.sites.all.len]Route = undefined;
    for (geography.sites.all, 0..) |site, index| {
        additional[index] = .{
            .chart = geography.first_additional + index,
            .leg_seconds = site.leg_seconds,
            .ship = if (site.reserve_per_supply == 0) .brig else .barque,
            .reserve_per_supply = site.reserve_per_supply,
        };
    }
    break :blk additional;
};

pub fn routeTo(chart: usize) ?usize {
    for (routes, 0..) |route, index| {
        if (route.chart == chart) return index;
    }
    return null;
}

/// Keep the original destination indices used by existing commands and saves.
pub const destination_count = routes.len + 2;
pub const brig_leg_limit: u8 = 30;
pub const direct_speed: f32 = 80;
pub const barque_leg_limit: u8 = 60;

pub fn destinationChart(index: usize) usize {
    return if (index < routes.len) routes[index].chart else index - routes.len;
}

pub fn destinationIndex(chart: usize) usize {
    return routeTo(chart) orelse routes.len + chart;
}

const direct_table: [geography.settlement_count][geography.settlement_count]?u16 = blk: {
    var table: [geography.settlement_count][geography.settlement_count]?u16 = @splat(@splat(null));
    for (baked.passages, 0..) |course, i| {
        table[course.from][course.to] = @intCast(i);
        table[course.to][course.from] = @intCast(i);
    }
    break :blk table;
};

pub fn directCourse(from: usize, to: usize) ?baked.Passage {
    if (from >= geography.settlement_count or to >= geography.settlement_count) return null;
    const index = direct_table[from][to] orelse return null;
    return baked.passages[index];
}

/// Java's established passages keep their existing timing, range, and rations.
/// Other crossings use the length of their direct open-water course.
pub fn passage(from: usize, to: usize) ?Route {
    if (from == 0 or to == 0) {
        const other = @max(from, to);
        if (other == 1) return .{ .chart = to, .leg_seconds = 9, .ship = .brig };
        var route = routes[routeTo(other) orelse return null];
        route.chart = to;
        return route;
    }
    const course = directCourse(from, to) orelse return null;
    return .{
        .chart = to,
        .leg_seconds = @floatFromInt(course.seconds),
        .ship = if (course.seconds <= brig_leg_limit) .brig else .barque,
    };
}

test "an expedition is provisioned for both legs and the landing" {
    const std = @import("std");
    try std.testing.expectEqual(@as(f32, 2 * 15 + landing_seconds), routes[0].provisionTime());
}
