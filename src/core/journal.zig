// Command journal codec and replay. Pure: no files, clocks, or logging.
//
// A journal is a header followed by length-prefixed records:
//   snapshot   the full session the following commands start from
//   command    one gameplay command, written before it is applied
//   checkpoint a fingerprint of the state after a day ends
// Replaying the commands from the latest snapshot reproduces the state the
// game was in, and checkpoints show where a replay first diverges.
const std = @import("std");
const domain = @import("colony.zig");
const gameplay = @import("gameplay.zig");
const save = @import("save.zig");

pub const magic = "AJNL";
/// Bump when the encoding of `gameplay.Command` or a record changes.
/// The golden-bytes test below fails when the layout changes without it.
pub const version: u16 = 8;
pub const header = magic.* ++ std.mem.toBytes(std.mem.nativeToLittle(u16, version));

pub const Kind = enum(u8) { snapshot = 1, command = 2, checkpoint = 3 };
pub const record_header_bytes = 1 + 4;
pub const max_command_bytes = 1 + @sizeOf(u64) + encoded_name_bytes;
const encoded_name_bytes = 1 + domain.town_name_bytes + 1;

pub const Checkpoint = struct { day: u32, fingerprint: u64 };

pub const Record = union(Kind) {
    snapshot: save.Session,
    command: gameplay.Command,
    checkpoint: Checkpoint,
};

/// A fingerprint of everything the rules read, including the time of day.
pub fn fingerprint(game: *const domain.Game) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&save.encode(game.*));
    hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, @bitCast(game.day_time))));
    return hasher.final();
}

// ---------------------------------------------------------------- encoding

pub const CommandBytes = struct {
    bytes: [max_command_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const CommandBytes) []const u8 {
        return self.bytes[0..self.len];
    }

    fn put(self: *CommandBytes, data: []const u8) void {
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }
};

fn Wide(comptime T: type) type {
    const info = @typeInfo(T).int;
    if (T == usize) return u64;
    return @Int(info.signedness, (info.bits + 7) / 8 * 8);
}

fn putValue(comptime T: type, value: T, out: *CommandBytes) void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => out.put(&.{@intFromBool(value)}),
        .int => {
            const W = Wide(T);
            var buffer: [@sizeOf(W)]u8 = undefined;
            std.mem.writeInt(W, &buffer, value, .little);
            out.put(&buffer);
        },
        .float => |info| {
            const Bits = @Int(.unsigned, info.bits);
            putValue(Bits, @bitCast(value), out);
        },
        .@"enum" => |info| putValue(info.tag_type, @backingInt(value), out),
        .array => for (value) |item| putValue(@TypeOf(item), item, out),
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| putValue(Field, @field(value, name), out),
        .@"union" => |info| {
            const tag = std.meta.activeTag(value);
            putValue(u8, @backingInt(tag), out);
            inline for (info.field_names, info.field_types) |name, Field| {
                if (tag == @field(info.tag_type.?, name)) putValue(Field, @field(value, name), out);
            }
        },
        else => @compileError("Journal cannot encode " ++ @typeName(T)),
    }
}

pub fn encodeCommand(command: gameplay.Command) CommandBytes {
    var out = CommandBytes{};
    putValue(gameplay.Command, command, &out);
    return out;
}

const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(cursor: *Cursor, n: usize) ![]const u8 {
        if (cursor.bytes.len - cursor.at < n) return error.Truncated;
        defer cursor.at += n;
        return cursor.bytes[cursor.at..][0..n];
    }
};

fn takeValue(comptime T: type, cursor: *Cursor) !T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return switch ((try cursor.take(1))[0]) {
            0 => false,
            1 => true,
            else => error.InvalidRecord,
        },
        .int => {
            const W = Wide(T);
            const wide = std.mem.readInt(W, (try cursor.take(@sizeOf(W)))[0..@sizeOf(W)], .little);
            return std.math.cast(T, wide) orelse error.InvalidRecord;
        },
        .float => |info| {
            const Bits = @Int(.unsigned, info.bits);
            return @bitCast(try takeValue(Bits, cursor));
        },
        .@"enum" => |info| return std.enums.fromInt(T, try takeValue(info.tag_type, cursor)) orelse error.InvalidRecord,
        .array => |info| {
            var value: T = undefined;
            for (&value) |*item| item.* = try takeValue(info.child, cursor);
            return value;
        },
        .@"struct" => |info| {
            var value: T = undefined;
            inline for (info.field_names, info.field_types) |name, Field| @field(value, name) = try takeValue(Field, cursor);
            return value;
        },
        .@"union" => |info| {
            const raw = try takeValue(u8, cursor);
            const tag = std.enums.fromInt(info.tag_type.?, raw) orelse return error.InvalidRecord;
            inline for (info.field_names, info.field_types) |name, Field| {
                if (tag == @field(info.tag_type.?, name)) return @unionInit(T, name, try takeValue(Field, cursor));
            }
            unreachable;
        },
        else => @compileError("Journal cannot decode " ++ @typeName(T)),
    }
}

pub fn decodeCommand(bytes: []const u8) !gameplay.Command {
    var cursor = Cursor{ .bytes = bytes };
    const command = try takeValue(gameplay.Command, &cursor);
    if (cursor.at != bytes.len) return error.InvalidRecord;
    return command;
}

fn recordHeader(kind: Kind, len: usize) [record_header_bytes]u8 {
    var out: [record_header_bytes]u8 = undefined;
    out[0] = @backingInt(kind);
    std.mem.writeInt(u32, out[1..5], @intCast(len), .little);
    return out;
}

/// A command record, ready to append.
pub const CommandRecord = struct {
    bytes: [record_header_bytes + max_command_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const CommandRecord) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn commandRecord(command: gameplay.Command) CommandRecord {
    const body = encodeCommand(command);
    var out = CommandRecord{};
    out.bytes[0..record_header_bytes].* = recordHeader(.command, body.len);
    @memcpy(out.bytes[record_header_bytes..][0..body.len], body.slice());
    out.len = record_header_bytes + body.len;
    return out;
}

pub const SnapshotRecord = [record_header_bytes + @sizeOf(save.SessionBytes)]u8;

pub fn snapshotRecord(session: save.Session) SnapshotRecord {
    var out: SnapshotRecord = undefined;
    out[0..record_header_bytes].* = recordHeader(.snapshot, @sizeOf(save.SessionBytes));
    out[record_header_bytes..].* = session.encodeSession();
    return out;
}

pub const CheckpointRecord = [record_header_bytes + 12]u8;

pub fn checkpointRecord(game: *const domain.Game) CheckpointRecord {
    var out: CheckpointRecord = undefined;
    out[0..record_header_bytes].* = recordHeader(.checkpoint, 12);
    std.mem.writeInt(u32, out[record_header_bytes..][0..4], game.day, .little);
    std.mem.writeInt(u64, out[record_header_bytes + 4 ..][0..8], fingerprint(game), .little);
    return out;
}

// ---------------------------------------------------------------- reading

pub const Reader = struct {
    bytes: []const u8,
    at: usize = header.len,
    /// Set when the file ends partway through a record, as after a crash.
    truncated: bool = false,

    pub fn init(bytes: []const u8) !Reader {
        if (bytes.len < header.len or !std.mem.eql(u8, bytes[0..4], magic)) return error.NotAJournal;
        const found = std.mem.readInt(u16, bytes[4..6], .little);
        if (found != version) return error.UnsupportedVersion;
        return .{ .bytes = bytes };
    }

    /// The next complete record, or null at the end. A record cut short by a
    /// crash ends the journal. A complete record that fails to decode is an error.
    pub fn next(reader: *Reader) !?Record {
        const rest = reader.bytes[reader.at..];
        if (rest.len == 0) return null;
        if (rest.len < record_header_bytes) return reader.cut();
        const len = std.mem.readInt(u32, rest[1..5], .little);
        if (rest.len - record_header_bytes < len) return reader.cut();
        const body = rest[record_header_bytes..][0..len];
        const kind = std.enums.fromInt(Kind, rest[0]) orelse return error.InvalidRecord;
        reader.at += record_header_bytes + len;
        return switch (kind) {
            .command => .{ .command = try decodeCommand(body) },
            .snapshot => .{ .snapshot = save.Session.decodeSession(body) orelse return error.InvalidSnapshot },
            .checkpoint => blk: {
                if (len != 12) return error.InvalidRecord;
                break :blk .{ .checkpoint = .{
                    .day = std.mem.readInt(u32, body[0..4], .little),
                    .fingerprint = std.mem.readInt(u64, body[4..12], .little),
                } };
            },
        };
    }

    fn cut(reader: *Reader) ?Record {
        reader.truncated = true;
        reader.at = reader.bytes.len;
        return null;
    }
};

// ---------------------------------------------------------------- replay

pub const Divergence = struct {
    /// Commands applied since the start of the journal.
    command_index: u64,
    day: u32,
    expected: u64,
    actual: u64,
    expected_day: u32,
};

pub const Report = struct {
    snapshots: u32 = 0,
    commands: u64 = 0,
    denied: u64 = 0,
    days: u64 = 0,
    checkpoints: u64 = 0,
    truncated: bool = false,
    divergence: ?Divergence = null,
    last_command: ?gameplay.Command = null,
    session: save.Session = .{},
};

pub const Options = struct {
    /// Stop after applying this many commands.
    until: ?u64 = null,
};

/// Replay a journal. Each snapshot replaces the state, each command is applied
/// with the same reducer the game uses, and each checkpoint is compared.
/// Replay continues past a divergence so the final state is still produced;
/// the report keeps the first one.
pub fn replay(bytes: []const u8, options: Options) !Report {
    var reader = try Reader.init(bytes);
    var report = Report{};
    var started = false;
    while (try reader.next()) |record| {
        switch (record) {
            .snapshot => |session| {
                report.session = session;
                report.snapshots += 1;
                started = true;
            },
            .command => |command| {
                if (!started) return error.MissingSnapshot;
                if (options.until) |limit| if (report.commands >= limit) break;
                const outcome = gameplay.apply(&report.session.game, command);
                report.commands += 1;
                report.last_command = command;
                switch (outcome) {
                    .denied => report.denied += 1,
                    .advanced => |step| if (step.day != null) {
                        report.days += 1;
                    },
                    .applied => {},
                }
            },
            .checkpoint => |expected| {
                if (!started) return error.MissingSnapshot;
                report.checkpoints += 1;
                const actual = fingerprint(&report.session.game);
                if (report.divergence == null and (actual != expected.fingerprint or report.session.game.day != expected.day)) {
                    report.divergence = .{
                        .command_index = report.commands,
                        .day = report.session.game.day,
                        .expected = expected.fingerprint,
                        .actual = actual,
                        .expected_day = expected.day,
                    };
                }
            },
        }
    }
    report.truncated = reader.truncated;
    return report;
}

// ---------------------------------------------------------------- tests

/// Builds a journal in memory the same way the file recorder does.
pub const Builder = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, start: save.Session) !Builder {
        var builder = Builder{ .gpa = gpa };
        try builder.list.appendSlice(gpa, &header);
        try builder.list.appendSlice(gpa, &snapshotRecord(start));
        return builder;
    }

    pub fn deinit(builder: *Builder) void {
        builder.list.deinit(builder.gpa);
    }

    /// Record and apply a command, adding a checkpoint when a day ends.
    pub fn dispatch(builder: *Builder, game: *domain.Game, command: gameplay.Command) !gameplay.Outcome {
        try builder.list.appendSlice(builder.gpa, commandRecord(command).slice());
        const outcome = gameplay.apply(game, command);
        if (outcome == .advanced and outcome.advanced.day != null) {
            try builder.list.appendSlice(builder.gpa, &checkpointRecord(game));
        }
        return outcome;
    }
};

test "every command kind round-trips through the journal encoding" {
    const commands = [_]gameplay.Command{
        .{ .build = .{ .island = 3, .cell = .{ .x = 12, .y = 40 }, .kind = .well } },
        .{ .build_bridge = 1 },
        .{ .survey_harbor = .{ .destination = 2, .manifest = .{ .settlers = 3, .cargo = .{ .water = 4 } } } },
        .{ .send_ferry = .{ .destination = 1, .manifest = .{ .settlers = 2, .cargo = .{ .grain = 6 } } } },
        .{ .sail_ferry = 0 },
        .{ .build_ship = .{ .island = 0, .hull = .barque } },
        .{ .survey_island = .{ .ship = 1, .route = 7, .manifest = .{ .settlers = 0, .cargo = .{} } } },
        .{ .send_expedition = .{ .ship = 2, .route = 3, .manifest = .{ .settlers = 5, .cargo = .{ .fruit = 1 } } } },
        .{ .return_expedition = 2 },
        .{ .export_grain = 4 },
        .{ .advance = 0.016666668 },
        .{ .rename_town = .{ .island = 0, .name = domain.TownName.parse("Port Sélène").? } },
    };
    // Every variant is covered so new commands cannot be left out of the journal.
    try std.testing.expectEqual(@typeInfo(gameplay.Command).@"union".field_names.len, commands.len);
    for (commands) |command| {
        try std.testing.expectEqualDeep(command, try decodeCommand(encodeCommand(command).slice()));
    }
}

test "the journal layout is pinned so a format change bumps the version" {
    // If this fails, the command encoding changed: bump `version`, then update these bytes.
    const bytes = encodeCommand(.{ .send_expedition = .{ .ship = 1, .route = 2, .manifest = .{ .settlers = 3, .cargo = .{ .timber = 4 } } } });
    const expected = [_]u8{7} ++ [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 2, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 3, 0 } ++
        [_]u8{ 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &expected, bytes.slice());
    const ferry = encodeCommand(.{ .send_ferry = .{ .destination = 2, .manifest = .{ .settlers = 1, .cargo = .{} } } });
    const expected_ferry = [_]u8{3} ++ [_]u8{ 2, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 1, 0 } ++ @as([12]u8, @splat(0));
    try std.testing.expectEqualSlices(u8, &expected_ferry, ferry.slice());
    try std.testing.expectEqual(@as(u16, 8), version);
}

test "malformed command bytes are rejected rather than misread" {
    try std.testing.expectError(error.InvalidRecord, decodeCommand(&.{250}));
    try std.testing.expectError(error.Truncated, decodeCommand(&.{0}));
    var bytes = encodeCommand(.{ .build = .{ .island = 0, .cell = .{ .x = 1, .y = 1 }, .kind = .road } });
    bytes.bytes[bytes.len - 1] = 15; // not a building kind
    try std.testing.expectError(error.InvalidRecord, decodeCommand(bytes.slice()));
    var trailing = encodeCommand(.{ .sail_ferry = 0 });
    trailing.bytes[trailing.len] = 0;
    try std.testing.expectError(error.InvalidRecord, decodeCommand(trailing.bytes[0 .. trailing.len + 1]));
}

test "a journal cut off mid-record replays the complete prefix" {
    const gpa = std.testing.allocator;
    var game = domain.Game.init();
    var builder = try Builder.init(gpa, .{ .game = game });
    defer builder.deinit();
    _ = try builder.dispatch(&game, .{ .export_grain = 0 });
    _ = try builder.dispatch(&game, .{ .advance = 1.5 });
    const full = builder.list.items;
    const report = try replay(full[0 .. full.len - 2], .{});
    try std.testing.expect(report.truncated);
    try std.testing.expectEqual(@as(u64, 1), report.commands);
    try std.testing.expectError(error.NotAJournal, replay("nope", .{}));
}

test "town square and apartment construction grow housing and survive saves and replay" {
    var game = domain.Game.init();
    game.people = 4;
    game.store(0).timber = 15;
    game.store(0).stone = 24;
    const cottage = domain.Cell{ .x = 44, .y = 39 };
    const square = domain.Cell{ .x = 45, .y = 42 };
    const blocked = domain.Cell{ .x = 45, .y = 43 };
    const upgrade = gameplay.Command{ .build = .{ .island = 0, .cell = cottage, .kind = .apartment } };
    const plaza = gameplay.Command{ .build = .{ .island = 0, .cell = square, .kind = .plaza } };
    const day = gameplay.Command{ .advance = domain.day_seconds };
    const rename = gameplay.Command{ .rename_town = .{ .island = 0, .name = domain.TownName.parse("Port Sélène 港 🌊").? } };
    var builder = try Builder.init(std.testing.allocator, .{ .game = game });
    defer builder.deinit();

    try std.testing.expect(game.connected(0, cottage));
    try std.testing.expectEqual(@as(u16, 0), game.freeBeds(0));
    try std.testing.expect((try builder.dispatch(&game, upgrade)) == .denied);
    try std.testing.expect((try builder.dispatch(&game, rename)) == .denied);
    const before = game.stockOf(0);
    try std.testing.expectEqual(domain.Kind.empty, game.tileAt(0, blocked));
    try std.testing.expect((try builder.dispatch(&game, .{ .build = .{ .island = 0, .cell = blocked, .kind = .plaza } })) == .denied);
    try std.testing.expectEqualDeep(before, game.stockOf(0));
    try std.testing.expectEqual(domain.Kind.empty, game.tileAt(0, blocked));

    try std.testing.expect((try builder.dispatch(&game, plaza)) == .applied);
    try std.testing.expect((try builder.dispatch(&game, rename)) == .applied);
    try std.testing.expectEqualStrings("Port Sélène 港 🌊", game.townName(0).?);
    try std.testing.expect(game.townName(1) == null);
    const footprint = domain.plazaCells(square);
    for (footprint, 0..) |cell, i| {
        try std.testing.expectEqual(if (i == 0) domain.Kind.plaza else domain.Kind.plaza_paving, game.tileAt(0, cell));
        try std.testing.expectEqualDeep(square, game.plazaAnchor(0, cell).?);
        try std.testing.expect(game.connected(0, cell));
    }
    try std.testing.expectEqual(@as(u16, 4), game.housing(0));
    const stock = game.stockOf(0);
    try std.testing.expectEqual(@as(u16, 11), stock.timber);
    try std.testing.expectEqual(@as(u16, 8), stock.stone);
    try std.testing.expect((try builder.dispatch(&game, upgrade)) == .denied);
    try std.testing.expectEqualDeep(stock, game.stockOf(0));
    try std.testing.expectEqual(domain.Kind.cottage, game.tileAt(0, cottage));

    _ = try builder.dispatch(&game, day);
    try std.testing.expectEqual(@as(u16, 4), game.residents(0));
    try std.testing.expect((try builder.dispatch(&game, upgrade)) == .applied);
    try std.testing.expectEqual(domain.Kind.apartment, game.tileAt(0, cottage));
    try std.testing.expect(game.connected(0, cottage));
    try std.testing.expectEqual(@as(u16, 12), game.housing(0));
    try std.testing.expectEqual(@as(u16, 8), game.freeBeds(0));
    try std.testing.expectEqual(@as(u16, 0), game.stockOf(0).timber);
    try std.testing.expectEqual(@as(u16, 0), game.stockOf(0).stone);
    try std.testing.expect((try builder.dispatch(&game, upgrade)) == .denied);
    _ = try builder.dispatch(&game, day);
    try std.testing.expectEqual(@as(u16, 5), game.residents(0));

    var session = save.Session{ .game = game };
    try std.testing.expectEqualDeep(session, save.Session.decodeSession(&session.encodeSession()).?);
    const report = try replay(builder.list.items, .{});
    try std.testing.expect(report.divergence == null);
    try std.testing.expectEqualDeep(game, report.session.game);

    session.game.setTile(0, footprint[3], .empty);
    try std.testing.expect(save.Session.decodeSession(&session.encodeSession()) == null);
}

test "a checkpoint that disagrees with the replayed state is reported as a divergence" {
    const gpa = std.testing.allocator;
    var game = domain.Game.init();
    var builder = try Builder.init(gpa, .{ .game = game });
    defer builder.deinit();
    for (0..20) |_| _ = try builder.dispatch(&game, .{ .advance = 1 });
    const clean = try replay(builder.list.items, .{});
    try std.testing.expect(clean.divergence == null);
    try std.testing.expectEqual(@as(u64, 2), clean.checkpoints);
    // Flip a byte in the first checkpoint's fingerprint.
    const first = std.mem.indexOfScalarPos(u8, builder.list.items, header.len + @sizeOf(SnapshotRecord), @backingInt(Kind.checkpoint)).?;
    builder.list.items[first + record_header_bytes + 4] ^= 0xff;
    const report = try replay(builder.list.items, .{});
    const divergence = report.divergence.?;
    try std.testing.expectEqual(@as(u64, 7), divergence.command_index);
    try std.testing.expectEqual(clean.session.game, report.session.game);
}
