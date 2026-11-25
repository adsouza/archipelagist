// Headless replay of a command journal, for reproducing crashes and bugs.
//
//   archipelagist-replay JOURNAL [--until N] [--verbose] [--save OUT.sav]
//
// Replays the journal with the game's own reducer and reports the commands,
// days, denials, and the first checkpoint that disagrees. --until stops
// after N commands, --verbose prints each command and its outcome as JSON
// lines, and --save writes the resulting state as a save file the game loads.
const std = @import("std");
const Io = std.Io;
const gameplay = @import("core").gameplay;
const journal = @import("core").journal;

const usage = "usage: archipelagist-replay JOURNAL [--until N] [--verbose] [--save OUT.sav]\n";

const Options = struct {
    path: []const u8,
    until: ?u64 = null,
    verbose: bool = false,
    save_path: ?[]const u8 = null,
};

fn parse(args: []const [:0]const u8) !Options {
    var options: ?Options = null;
    var until: ?u64 = null;
    var verbose = false;
    var save_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--until") or std.mem.eql(u8, arg, "--save")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            if (arg[2] == 'u') until = try std.fmt.parseInt(u64, args[i], 10) else save_path = args[i];
        } else if (options == null and !std.mem.startsWith(u8, arg, "--")) {
            options = .{ .path = arg };
        } else return error.UnknownArgument;
    }
    var result = options orelse return error.MissingJournal;
    result.until = until;
    result.verbose = verbose;
    result.save_path = save_path;
    return result;
}

pub fn main(process: std.process.Init) !u8 {
    const io = process.io;
    const allocator = process.arena.allocator();
    var out_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const args = try process.minimal.args.toSlice(allocator);
    const options = parse(args) catch {
        try out.writeAll(usage);
        return 2;
    };
    const bytes = Io.Dir.cwd().readFileAlloc(io, options.path, allocator, .unlimited) catch |err| {
        try out.print("Could not read {s}: {s}\n", .{ options.path, @errorName(err) });
        return 1;
    };
    if (options.verbose) try printSteps(out, bytes, options.until);
    const report = journal.replay(bytes, .{ .until = options.until }) catch |err| {
        try out.print("Could not replay {s}: {s}\n", .{ options.path, @errorName(err) });
        return 1;
    };
    try summarize(out, report);
    if (options.save_path) |path| {
        const session = report.session.encodeSession();
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &session }) catch |err| {
            try out.print("Could not write {s}: {s}\n", .{ path, @errorName(err) });
            return 1;
        };
        try out.print("saved state to {s}\n", .{path});
    }
    return if (report.divergence != null) 3 else 0;
}

fn printSteps(out: *Io.Writer, bytes: []const u8, until: ?u64) !void {
    var reader = try journal.Reader.init(bytes);
    var game: ?@import("core").colony.Game = null;
    var index: u64 = 0;
    while (try reader.next()) |record| switch (record) {
        .snapshot => |session| {
            game = session.game;
            try out.print("{f}\n", .{std.json.fmt(.{ .snapshot = .{ .day = session.game.day, .population = session.game.people } }, .{})});
        },
        .command => |command| {
            if (until) |limit| if (index >= limit) return;
            const state = if (game) |*g| g else return error.MissingSnapshot;
            const outcome = gameplay.apply(state, command);
            try out.print("{f}\n", .{std.json.fmt(.{
                .index = index,
                .command = command,
                .status = @tagName(outcome),
                .reason = outcome.problem(),
                .day = state.day,
            }, .{})});
            index += 1;
        },
        .checkpoint => |checkpoint| {
            const state = if (game) |*g| g else return error.MissingSnapshot;
            try out.print("{f}\n", .{std.json.fmt(.{ .checkpoint = checkpoint.day, .matches = journal.fingerprint(state) == checkpoint.fingerprint }, .{})});
        },
    };
}

fn summarize(out: *Io.Writer, report: journal.Report) !void {
    const g = &report.session.game;
    try out.print(
        \\snapshots   {d}
        \\commands    {d} ({d} denied)
        \\days ended  {d}
        \\checkpoints {d}
        \\final state day {d}, {d} settlers, {d} coins, {d} ships
        \\
    , .{ report.snapshots, report.commands, report.denied, report.days, report.checkpoints, g.day, g.people, g.coins, g.fleet.count });
    if (report.last_command) |command| try out.print("last command {f}\n", .{std.json.fmt(command, .{})});
    if (report.truncated) try out.writeAll("the journal ends partway through a record, as after a crash\n");
    if (report.divergence) |d| {
        try out.print("DIVERGED after command {d}: day {d} vs recorded day {d}, fingerprint {x} vs recorded {x}\n", .{
            d.command_index, d.day, d.expected_day, d.actual, d.expected,
        });
    } else try out.writeAll("all checkpoints match\n");
}

test "replay arguments" {
    const parsed = try parse(&.{ "replay", "j.bin", "--until", "40", "--verbose", "--save", "out.sav" });
    try std.testing.expectEqualStrings("j.bin", parsed.path);
    try std.testing.expectEqual(@as(?u64, 40), parsed.until);
    try std.testing.expect(parsed.verbose);
    try std.testing.expectEqualStrings("out.sav", parsed.save_path.?);
    try std.testing.expectError(error.MissingJournal, parse(&.{"replay"}));
    try std.testing.expectError(error.UnknownArgument, parse(&.{ "replay", "a", "b" }));
}
