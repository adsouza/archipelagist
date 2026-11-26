// Decorates gameplay without passing the logger or I/O into the rules.
// The journal records each command before it runs; the trace records outcomes.
const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const gameplay = @import("core").gameplay;
const domain = @import("core").colony;
const journal_file = @import("journal_file.zig");

pub const Observers = struct {
    trace: ?*diagnostics.Trace = null,
    journal: ?*journal_file.Recorder = null,
};

pub fn dispatch(observers: Observers, game: *domain.Game, command: gameplay.Command) gameplay.Outcome {
    const recorder = observers.journal orelse return traced(observers.trace, game, command);
    recorder.command(game, command);
    const result = traced(observers.trace, game, command);
    if (result == .advanced and result.advanced.day != null) recorder.checkpoint(game);
    return result;
}

fn traced(active: ?*diagnostics.Trace, game: *domain.Game, command: gameplay.Command) gameplay.Outcome {
    const trace = active orelse return gameplay.apply(game, command);
    const operation = @tagName(command);
    if (command == .advance) {
        // Runs every frame, so only notable steps are recorded.
        const started = std.Io.Clock.awake.now(trace.io);
        const result = gameplay.apply(game, command);
        const elapsed = started.durationTo(std.Io.Clock.awake.now(trace.io)).toMicroseconds();
        if (elapsed > 5000) trace.note("simulation", "slow_step", .{ .day = game.day, .elapsed_us = elapsed });
        switch (result) {
            .advanced => |step| {
                for (step.arrivals.slice()) |arrival| trace.note("simulation", "arrival", .{ .day = game.day, .arrival = arrival });
                if (step.day) |day| {
                    trace.note("simulation", "day", .{
                        .day = game.day,
                        .population_before = day.population_before,
                        .population_after = day.population_after,
                        .elapsed_us = elapsed,
                    });
                    for (day.shortages, 0..) |shortage, island| {
                        if (shortage == .none) continue;
                        trace.note("simulation", "shortage", .{ .day = game.day, .island = island, .kind = shortage, .diet = game.diets[island] });
                    }
                }
            },
            else => if (result.problem()) |reason| trace.note("simulation", "invalid_interval", .{ .reason = reason }),
        }
        return result;
    }
    const span = trace.begin("gameplay", operation, .{ .command = command, .day = game.day });
    const result = gameplay.apply(game, command);
    trace.finish("gameplay", operation, span, if (result == .denied) "denied" else "ok", .{
        .day = game.day,
        .population = game.people,
        .fleet_size = game.fleet.count,
        .reason = result.problem(),
    });
    return result;
}

test "command diagnostics preserve outcomes and record accepted and denied actions" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var trace = try diagnostics.Trace.open(std.testing.io, temp.dir, "trace");
    defer trace.deinit();
    var observed = domain.Game.init();
    var unobserved = observed;
    for (0..3) |_| {
        const command: gameplay.Command = .{ .export_grain = 0 };
        const with_trace = dispatch(.{ .trace = &trace }, &observed, command);
        const without_trace = dispatch(.{}, &unobserved, command);
        try std.testing.expectEqualDeep(without_trace.problem(), with_trace.problem());
    }
    try std.testing.expectEqualDeep(unobserved.stockpiles, observed.stockpiles);
    try std.testing.expectEqual(unobserved.coins, observed.coins);
    var buffer: [4096]u8 = undefined;
    const data = try temp.dir.readFile(std.testing.io, "trace/trace.jsonl", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"event\":\"export_grain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"status\":\"denied\"") != null);
}

test "the journal and trace observe the clock without changing it" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    var trace = try diagnostics.Trace.open(io, temp.dir, "trace");
    defer trace.deinit();
    var recorder = try journal_file.Recorder.open(io, temp.dir, "trace");
    defer recorder.deinit();
    var observed = domain.Game.init();
    var unobserved = observed;
    for (0..30) |_| {
        const command: gameplay.Command = .{ .advance = 0.75 };
        _ = dispatch(.{ .trace = &trace, .journal = &recorder }, &observed, command);
        _ = dispatch(.{}, &unobserved, command);
    }
    try std.testing.expectEqualDeep(unobserved, observed);
    try std.testing.expectEqual(@as(u64, 30), recorder.commands);
    var buffer: [16384]u8 = undefined;
    const data = try temp.dir.readFile(io, "trace/trace.jsonl", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"event\":\"day\"") != null);
}
