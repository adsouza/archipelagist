// Save codec. A save is "ARC1" followed by every field of `Game` in
// declaration order, little-endian, except the clock, which the session
// stores. Decoding checks every invariant the rules rely on, so a corrupt
// or hand-edited save is rejected rather than loaded.
const s = @import("colony.zig");
const std = @import("std");

const magic = "ARC1";

fn encodedSize(comptime T: type) usize {
    if (T == s.Tile) return 1;
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |info| if (T == usize) 4 else (info.bits + 7) / 8,
        .float => |info| info.bits / 8,
        .@"enum" => |info| encodedSize(info.tag_type),
        .array => |info| info.len * encodedSize(info.child),
        .@"struct" => |info| blk: {
            var total: usize = 0;
            inline for (info.field_names, info.field_types) |name, Field| {
                if (T == s.Game and std.mem.eql(u8, name, "day_time")) continue;
                total += encodedSize(Field);
            }
            break :blk total;
        },
        else => @compileError("Saves cannot store " ++ @typeName(T)),
    };
}

const size = magic.len + encodedSize(s.Game);

/// Where a field of `Game` starts in an encoded game.
fn offsetOf(comptime field: []const u8) usize {
    var at: usize = magic.len;
    inline for (@typeInfo(s.Game).@"struct".field_names, @typeInfo(s.Game).@"struct".field_types) |name, Field| {
        if (comptime std.mem.eql(u8, name, field)) return at;
        if (comptime !std.mem.eql(u8, name, "day_time")) at += encodedSize(Field);
    }
    unreachable;
}

fn Stored(comptime T: type) type {
    return if (T == usize) u32 else @Int(@typeInfo(T).int.signedness, encodedSize(T) * 8);
}

const Writer = struct {
    bytes: []u8,
    at: usize = 0,

    fn put(w: *Writer, comptime T: type, value: T) void {
        if (T == s.Tile) {
            w.bytes[w.at] = @bitCast(value);
            w.at += 1;
            return;
        }
        switch (@typeInfo(T)) {
            .bool => w.put(u8, @intFromBool(value)),
            .int => {
                const W = Stored(T);
                std.mem.writeInt(W, w.bytes[w.at..][0..@sizeOf(W)], @intCast(value), .little);
                w.at += @sizeOf(W);
            },
            .float => |info| w.put(@Int(.unsigned, info.bits), @bitCast(value)),
            .@"enum" => |info| w.put(info.tag_type, @backingInt(value)),
            .array => for (value) |item| w.put(@TypeOf(item), item),
            .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| {
                if (T == s.Game and comptime std.mem.eql(u8, name, "day_time")) continue;
                w.put(Field, @field(value, name));
            },
            else => comptime unreachable,
        }
    }
};

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(r: *Reader, comptime T: type) ?T {
        if (T == s.Tile) {
            const raw = r.bytes[r.at];
            r.at += 1;
            const kind = std.enums.fromInt(s.Kind, @as(u4, @truncate(raw))) orelse return null;
            return .{ .kind = kind, .harvest_state = @truncate(raw >> 4) };
        }
        switch (@typeInfo(T)) {
            .bool => return switch (r.take(u8) orelse return null) {
                0 => false,
                1 => true,
                else => null,
            },
            .int => {
                const W = Stored(T);
                const raw = std.mem.readInt(W, r.bytes[r.at..][0..@sizeOf(W)], .little);
                r.at += @sizeOf(W);
                return std.math.cast(T, raw);
            },
            .float => |info| return @bitCast(r.take(@Int(.unsigned, info.bits)) orelse return null),
            .@"enum" => |info| return std.enums.fromInt(T, r.take(info.tag_type) orelse return null),
            .array => |info| {
                var value: T = undefined;
                for (&value) |*item| item.* = r.take(info.child) orelse return null;
                return value;
            },
            .@"struct" => |info| {
                var value: T = .{};
                inline for (info.field_names, info.field_types) |name, Field| {
                    if (T == s.Game and comptime std.mem.eql(u8, name, "day_time")) continue;
                    @field(value, name) = r.take(Field) orelse return null;
                }
                return value;
            },
            else => comptime unreachable,
        }
    }
};

pub fn encode(g: s.Game) [size]u8 {
    var bytes: [size]u8 = undefined;
    bytes[0..magic.len].* = magic.*;
    var writer = Writer{ .bytes = &bytes, .at = magic.len };
    writer.put(s.Game, g);
    std.debug.assert(writer.at == size);
    return bytes;
}

pub fn decode(bytes: []const u8) ?s.Game {
    if (bytes.len != size or !std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
    var reader = Reader{ .bytes = bytes, .at = magic.len };
    const g = reader.take(s.Game) orelse return null;
    return if (valid(&g)) g else null;
}

/// The invariants the rules rely on.
fn valid(g: *const s.Game) bool {
    if (g.day == 0) return false;
    for (s.geography.grids, 0..) |grid, chart| {
        for (g.tilesOn(chart), 0..) |tile, index| {
            if (!s.validHarvestState(tile.kind, tile.harvest_state)) return false;
            if (tile.kind != .empty and s.depth(grid.cell(index), chart) < 0) return false;
        }
    }
    for (g.diets) |diet| {
        if (diet.meat_deficit > s.weakness_limit or diet.days_without_fruit > s.scurvy_days) return false;
    }
    if (g.awayFromJava() > g.people) return false;
    if (g.charter.ferried_to_bali and !g.ferry.surveyed) return false;
    for (s.crossings, g.bridges) |crossing, built| {
        if (built and !(g.islandOpen(crossing.charts[0]) and g.islandOpen(crossing.charts[1]))) return false;
    }
    for (1..s.settlement_count) |chart| {
        const open = g.islandOpen(chart);
        if (open and g.tileAt(chart, s.quay(chart)) != .port) return false;
        if (!open) {
            if (g.residents(chart) > 0 or !g.stores[chart].empty()) return false;
            for (g.tilesOn(chart)) |tile| {
                if (tile.kind != .empty) return false;
            }
        }
        if (chart >= s.geography.borneo) {
            const founded = g.founded[chart - s.geography.borneo];
            if ((founded and !open) or (g.residents(chart) > 0 and !founded)) return false;
        }
    }
    if (!validFerry(g)) return false;
    if (g.fleet.count > g.fleet.vessels.len) return false;
    for (g.vessels()) |vessel| {
        if (vessel.ship == .none) return false;
    }
    return validFleet(g);
}

fn validFerry(g: *const s.Game) bool {
    const ferry = g.ferry;
    const t = ferry.sailing_time;
    if (ferry.passengers > s.ferry_capacity or ferry.cargo.units() > s.ferry_hold) return false;
    if (!g.islandOpen(ferry.origin)) return false;
    if (ferry.moored()) |_| return t == 0 and !ferry.surveying and ferry.passengers == 0 and ferry.cargo.empty();
    if (!s.ferry.withinRange(ferry.origin, ferry.destination) or !(t >= 0 and t < ferry.legSeconds())) return false;
    return g.islandOpen(ferry.destination) != ferry.surveying;
}

fn validFleet(g: *const s.Game) bool {
    if (g.awayFromJava() > g.people) return false;
    if (g.fleet.count > 0 and !g.charterComplete()) return false;
    var barque = false;
    var surveying: [s.settlement_count]bool = @splat(false);
    if (g.ferry.surveying) surveying[g.ferry.destination] = true;
    var arriving: [s.settlement_count]s.Stores = @splat(.{});
    if (g.voyageDestination()) |chart| arriving[chart] = g.ferry.cargo;
    for (g.vessels()) |vessel| {
        barque = barque or vessel.ship == .barque;
        if (vessel.ship == .barque and !g.fleet.charted[0]) return false;
        const route = s.ocean.routeTo(vessel.chart);
        if (route) |index| {
            if (!vessel.ship.canSail(s.ocean.routes[index])) return false;
        }
        if (!std.math.isFinite(vessel.elapsed) or vessel.elapsed < 0) return false;
        if (vessel.phase != .outbound and (vessel.carryingLoad() or vessel.surveying)) return false;
        if (vessel.phase == .docked) {
            if (!g.islandOpen(vessel.chart) or vessel.elapsed != 0 or (vessel.chart <= 1 and vessel.return_provisioned)) return false;
        } else {
            if (vessel.chart == 0 or vessel.elapsed >= vessel.legSeconds()) return false;
            if (vessel.phase == .homebound) {
                if (!g.islandOpen(vessel.chart) or vessel.return_provisioned) return false;
            } else {
                if (route == null or !vessel.return_provisioned or vessel.passengers > vessel.ship.passengerCapacity()) return false;
                if (vessel.surveying == g.islandOpen(vessel.chart)) return false;
                if (!vessel.surveying and !vessel.carryingLoad()) return false;
                if (vessel.surveying) {
                    if (surveying[vessel.chart]) return false;
                    surveying[vessel.chart] = true;
                }
                const sum = &arriving[vessel.chart];
                inline for (s.store_fields) |name| {
                    if (@field(vessel.cargo, name) > std.math.maxInt(u16) - @field(sum, name)) return false;
                }
                sum.add(vessel.cargo);
            }
        }
    }
    for (s.ocean.routes, g.fleet.charted) |route, charted| {
        // The ferry can chart nearby harbors, so only barque routes need a ship.
        if (charted and !barque and route.ship == .barque) return false;
    }
    for (0..s.settlement_count) |chart| {
        if (g.berthsUsed(chart) > s.dock_capacity) return false;
        if (@as(u32, g.residents(chart)) + g.reservedBeds(chart) > g.landingCapacity(chart)) return false;
        inline for (s.store_fields) |name| {
            if (@field(arriving[chart], name) > std.math.maxInt(u16) - @field(g.stores[chart], name)) return false;
        }
    }
    return true;
}

pub const SessionBytes = [4 + size + 5]u8;

/// A saved game with the time of day and the chosen speed.
pub const Session = struct {
    game: s.Game = s.Game.init(),
    speed: u8 = 1,

    pub fn encodeSession(session: Session) SessionBytes {
        var bytes: SessionBytes = undefined;
        bytes[0..4].* = "SES1".*;
        bytes[4..][0..size].* = encode(session.game);
        std.mem.writeInt(u32, bytes[4 + size ..][0..4], @bitCast(session.game.day_time), .little);
        bytes[bytes.len - 1] = session.speed;
        return bytes;
    }

    pub fn decodeSession(bytes: []const u8) ?Session {
        if (bytes.len != @sizeOf(SessionBytes) or !std.mem.eql(u8, bytes[0..4], "SES1")) return null;
        const trailer = bytes.len - 5;
        const day_time: f32 = @bitCast(std.mem.readInt(u32, bytes[trailer..][0..4], .little));
        const speed = bytes[bytes.len - 1];
        if (!std.math.isFinite(day_time) or day_time < 0 or day_time >= s.day_seconds) return null;
        if (speed != 0 and speed != 1 and speed != 3) return null;
        var game = decode(bytes[4..trailer]) orelse return null;
        game.day_time = day_time;
        return .{ .game = game, .speed = speed };
    }
};

fn surveyFerryAndReturn(g: *s.Game) !void {
    try std.testing.expect(g.surveyByFerry(1, 0, .{}) == null);
    g.advanceShip(s.crossing_seconds);
    try std.testing.expect(g.sailFerry(0) == null);
    g.advanceShip(s.crossing_seconds);
}

fn returnExpeditionToJava(g: *s.Game) !void {
    const seconds = g.fleet.vessels[0].legSeconds();
    try std.testing.expect(g.returnExpedition(0) == null);
    try std.testing.expectEqual(s.Game.ExpeditionEvent.returned, g.advanceExpedition(0, seconds));
}

test "save round trip and corrupt tile rejection" {
    var g = s.Game.init();
    _ = g.tick();
    var b = encode(g);
    try std.testing.expectEqualDeep(g, decode(&b).?);
    b[offsetOf("tiles") + 10] = 15; // not a building kind
    try std.testing.expect(decode(&b) == null);
    b = encode(g);
    b[0] = 'X';
    try std.testing.expect(decode(&b) == null);
    try std.testing.expect(decode(b[0 .. b.len - 1]) == null);
}

test "the last settler's death ends the charter and freezes a voyage across reloads" {
    var session = Session{};
    const g = &session.game;
    g.people = 1;
    g.coins = 20;
    try surveyFerryAndReturn(g);
    try std.testing.expect(g.sendCargo(0, 0, .{ .timber = 1 }) == null);
    g.advanceShip(2);
    g.stores[0].water = 0;
    try std.testing.expectEqual(s.Game.Shortage.water, g.tick()[0]);
    try std.testing.expect(g.isOver());

    const final = session.encodeSession();
    var restored = Session.decodeSession(&final).?;
    try std.testing.expect(restored.game.isOver());
    _ = restored.game.tick();
    restored.game.advanceShip(s.crossing_seconds);
    try std.testing.expectEqual(final, restored.encodeSession());
}

test "settlers aboard keep the charter alive when every island is empty" {
    var g = s.Game.init();
    g.coins = 20;
    try surveyFerryAndReturn(&g);
    try std.testing.expect(g.sendFerry(1, 1, .{ .water = 3 }) == null);
    g.stores[0].water = 0;
    try std.testing.expectEqual(s.Game.Shortage.water, g.tick()[0]);
    for (0..s.settlement_count) |chart| try std.testing.expectEqual(@as(u16, 0), g.residents(chart));
    try std.testing.expect(!g.isOver());

    g.advanceShip(s.crossing_seconds);
    try std.testing.expectEqual(@as(u16, 1), g.residents(1));
    try std.testing.expect(!g.isOver());
}

test "resume survey and sailings from either port" {
    var g = s.Game.init();
    g.coins = 20;
    try std.testing.expect(g.surveyByFerry(1, 0, .{}) == null);
    g.advanceShip(4.5);
    try std.testing.expectEqual(@as(f32, 0.5), g.ferry.progress());
    try std.testing.expectEqual(@as(u16, 0), g.countOn(1, .port));
    g = decode(&encode(g)).?;
    g.advanceShip(4.5);
    try std.testing.expectEqual(@as(f32, 0), g.ferry.progress());
    try std.testing.expectEqual(@as(?usize, 1), g.mooredChart());
    try std.testing.expectEqual(@as(u16, 1), g.countOn(1, .port));
    g = decode(&encode(g)).?;
    g.advanceShip(100);
    try std.testing.expectEqual(@as(?usize, 1), g.mooredChart());

    try std.testing.expect(g.sailFerry(0) == null);
    g.advanceShip(s.crossing_seconds);
    try std.testing.expectEqual(@as(?usize, 0), g.mooredChart());
    for ([_]usize{ 1, 0 }) |destination| {
        if (destination == 1) {
            try std.testing.expect(g.sendCargo(0, 0, .{ .timber = 1 }) == null);
        } else {
            try std.testing.expect(g.sailFerry(0) == null);
        }
        g.advanceShip(4.5);
        try std.testing.expect(g.sailFerry(0) != null);
        g = decode(&encode(g)).?;
        try std.testing.expectEqual(@as(f32, 0.5), g.ferry.progress());
        g.advanceShip(4.5);
        try std.testing.expectEqual(@as(?usize, destination), g.mooredChart());
    }
}

test "ferry reserves housing and restores a passenger at sea" {
    var g = s.Game.init();
    g.coins = 20;
    try surveyFerryAndReturn(&g);
    g.stores[0].grain = 0;
    g.stores[0].venison = 0;
    try std.testing.expect(g.ferrySettlers(1, 1) != null);
    g.stores[0].grain = s.starting_stores.grain;
    try std.testing.expectEqual(@as(?usize, 0), g.mooredChart());
    g.stores[1] = .{ .timber = 12, .grain = 10, .water = 10 };
    try std.testing.expect(g.build(0, s.Cell{ .x = 39, .y = 44 }, .road) == null);
    try std.testing.expect(g.ferrySettlers(1, 1) == null);
    try std.testing.expectEqual(@as(u16, 1), g.residents(0));
    try std.testing.expectEqual(@as(u16, 0), g.residents(1));
    g.advanceShip(4);
    const encoded = encode(g);
    try std.testing.expectEqualDeep(g, decode(&encoded).?);
    g = decode(&encode(g)).?;
    g.advanceShip(5);
    try std.testing.expectEqual(@as(u16, 1), g.residents(1));
    try std.testing.expect(g.build(1, s.Cell{ .x = 24, .y = 24 }, .cottage) == null);
    try std.testing.expect(g.ferrySettlers(0, 1) == null);
    try std.testing.expectEqual(@as(u16, 0), g.residents(1));
    g.people = 4; // Three residents and one passenger with the last bed reserved.
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 4), g.people);
    g.advanceShip(s.crossing_seconds);
    try std.testing.expectEqual(@as(u16, 4), g.residents(0));
}

test "a group can ferry both ways and resume mid-crossing" {
    var g = s.Game.init();
    try std.testing.expect(g.build(0, s.Cell{ .x = 39, .y = 39 }, .cottage) == null);
    g.people = 8;
    g.coins = 20;
    try surveyFerryAndReturn(&g);
    g.stores[1] = .{ .timber = 12, .grain = 10, .water = 10 };
    try std.testing.expectEqual(@as(u16, 4), g.ferryLimit(1));
    try std.testing.expect(g.ferrySettlers(1, 5) != null);
    try std.testing.expect(g.ferrySettlers(1, 4) == null);
    g.advanceShip(4);
    g = decode(&encode(g)).?;
    try std.testing.expectEqual(@as(u16, 4), g.ferry.passengers);
    try std.testing.expectEqual(@as(u16, 4), g.residents(0));
    try std.testing.expectEqual(@as(u16, 0), g.residents(1));
    g.advanceShip(5);
    try std.testing.expectEqual(@as(u16, 4), g.residents(1));
    try std.testing.expect(g.build(1, s.Cell{ .x = 24, .y = 24 }, .cottage) == null);
    try std.testing.expect(g.build(1, s.Cell{ .x = 27, .y = 26 }, .cottage) == null);
    try std.testing.expect(g.ferrySettlers(0, 4) == null);
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 8), g.people);
    g.advanceShip(s.crossing_seconds);
    try std.testing.expectEqual(@as(u16, 8), g.residents(0));
    try std.testing.expectEqual(@as(u16, 0), g.ferry.passengers);
}

test "session restores game timing and rejects bare game bytes" {
    var session = Session{ .speed = 3 };
    session.game.day_time = 6.75;
    session.game.coins = 20;
    try std.testing.expect(session.game.surveyByFerry(1, 0, .{}) == null);
    session.game.advanceShip(3);
    var bytes = session.encodeSession();
    try std.testing.expectEqualDeep(session, Session.decodeSession(&bytes).?);
    try std.testing.expect(Session.decodeSession(&encode(session.game)) == null);
    bytes[bytes.len - 1] = 2;
    try std.testing.expect(Session.decodeSession(&bytes) == null);
}

test "cargo resumes at sea and local stock pays for the bridge on both shores" {
    var g = s.Game.init();
    try std.testing.expect(g.buildBridge(0) != null);
    g.coins = 20;
    try surveyFerryAndReturn(&g);
    try std.testing.expect(g.build(1, s.Cell{ .x = 24, .y = 24 }, .cottage) != null);

    var load = s.Stores{ .timber = 12, .stone = 4, .grain = 7, .fruit = 4, .water = 10 };
    const before_load = encode(g);
    try std.testing.expect(g.sendCargo(0, 0, load) != null);
    try std.testing.expectEqual(before_load, encode(g));
    load.grain = 2;
    try std.testing.expectEqual(s.ferry_hold, load.units());
    try std.testing.expect(g.sendCargo(0, 0, load) == null);
    try std.testing.expectEqual(@as(u16, 10), g.stores[0].water);
    try std.testing.expect(g.stores[1].empty());
    g.advanceShip(4);
    g = decode(&encode(g)).?;
    try std.testing.expectEqualDeep(load, g.ferry.cargo);
    g.advanceShip(5);
    try std.testing.expect(g.ferry.cargo.empty());
    try std.testing.expectEqualDeep(load, g.stores[1]);

    const cottage = s.Cell{ .x = 24, .y = 24 };
    try std.testing.expectEqualStrings("Bring at least one settler to this island before building.", g.build(1, cottage, .cottage).?);
    try std.testing.expectEqualDeep(load, g.stores[1]);
    try std.testing.expectEqual(s.Kind.empty, g.tileAt(1, cottage));
    try std.testing.expect(g.build(0, s.Cell{ .x = 39, .y = 39 }, .cottage) == null);
    try std.testing.expect(g.sailFerry(0) == null);
    g.advanceShip(s.crossing_seconds);
    g.people = 8;
    g.stores[0] = s.bridge_cost;
    g.stores[1] = .{};
    try std.testing.expect(g.buildBridge(0) != null);
    g.stores[0].grain = s.ferryRations(0, 1, 4);
    try std.testing.expect(g.ferrySettlers(1, 4) == null);
    try std.testing.expectEqualStrings("Bring at least one settler to this island before building.", g.build(1, cottage, .cottage).?);
    g.advanceShip(s.crossing_seconds);
    try std.testing.expect(g.buildBridge(0) != null);
    try std.testing.expectEqualDeep(s.bridge_cost, g.stores[0]);
    g.stores[1] = s.bridge_cost;
    try std.testing.expect(g.buildBridge(0) == null);
    try std.testing.expect(g.stores[0].empty() and g.stores[1].empty());
    g = decode(&encode(g)).?;
    try std.testing.expect(g.bridges[0]);
    try std.testing.expect(g.crossBridge(0, 0) == null);
    try std.testing.expectEqual(@as(u16, 5), g.residents(0));
    g.stores[1].timber = 3;
    try std.testing.expect(g.sendCargo(0, 1, .{ .timber = 2 }) == null);
    try std.testing.expectEqual(@as(u16, 2), g.stores[0].timber);
    try std.testing.expectEqual(@as(u16, 1), g.stores[1].timber);
}

test "charter credits a provisioned ferry landing at the camp" {
    var g = s.Game.init();
    g.coins = 20;
    try surveyFerryAndReturn(&g);
    try std.testing.expect(!g.charter.ferried_to_bali);
    try std.testing.expect(g.sailFerry(0) != null);
    try std.testing.expect(g.sendCargo(0, 0, .{ .timber = 1 }) == null);
    g.advanceShip(s.crossing_seconds);
    try std.testing.expect(!g.charter.ferried_to_bali);
    try std.testing.expect(g.sailFerry(0) == null);
    g.advanceShip(s.crossing_seconds);

    g.stores[0].grain = 0;
    g.stores[0].venison = 1;
    try std.testing.expect(g.ferrySettlers(1, 2) != null);
    try std.testing.expectEqual(@as(u16, 1), g.stores[0].venison);
    try std.testing.expectEqual(@as(?usize, 0), g.mooredChart());

    g.stores[0].grain = 4;
    try std.testing.expect(g.ferrySettlers(1, 2) == null);
    try std.testing.expectEqual(@as(u16, 0), g.stores[0].venison);
    try std.testing.expectEqual(@as(u16, 0), g.stores[0].grain);
    try std.testing.expectEqual(@as(u16, 3), g.ferry.cargo.grain);
    try std.testing.expectEqual(@as(u16, 3), g.ferry.cargo.water);
    try std.testing.expectEqual(@as(u16, 0), g.housing(1));
    try std.testing.expect(!g.charter.ferried_to_bali);
    g = decode(&encode(g)).?;
    g.advanceShip(s.crossing_seconds);
    try std.testing.expect(g.charter.ferried_to_bali);
    try std.testing.expectEqual(@as(u16, 2), g.residents(1));
    try std.testing.expectEqual(@as(u16, 3), g.stores[1].water);
    try std.testing.expectEqualDeep(g, decode(&encode(g)).?);

    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 2), g.residents(1));
    try std.testing.expectEqual(@as(u16, 2), g.people);
}

test "diet counters and fruit survive saves" {
    var g = s.Game.init();
    g.stores[0].fruit = 0;
    g.diets[0].missed_grain = true;
    _ = g.tick();
    try std.testing.expectEqual(@as(u8, 1), g.diets[0].days_without_fruit);
    const encoded = encode(g);
    try std.testing.expectEqualDeep(g, decode(&encoded).?);
    var corrupt = encoded;
    corrupt[offsetOf("diets") + 2] = s.scurvy_days + 1;
    try std.testing.expect(decode(&corrupt) == null);
}

test "shipyard provisions both voyages and saves expeditions in progress" {
    var g = s.Game.init();
    try std.testing.expect(g.buildShip(0, .brig) != null);
    try std.testing.expect(g.build(0, s.Cell{ .x = 39, .y = 39 }, .cottage) == null);
    g.people = 6;
    g.coins = 150;
    try surveyFerryAndReturn(&g);
    g.charter.won = true;
    g.bridges[0] = true;
    g.charter.ferried_to_bali = true;
    g.charter.housed_eight = true;
    g.stores[0] = .{ .timber = 100, .stone = 20, .grain = 60, .venison = 60, .fruit = 60, .water = 0 };

    const before_exploration = encode(g);
    g = decode(&before_exploration).?;
    try std.testing.expectEqualDeep([3]?s.Goal{ .build_brig, .chart_lombok, .build_barque }, g.nextGoals());
    try std.testing.expect(g.buildShip(0, .barque) != null);
    const brig = s.shipCost(.brig);
    try std.testing.expect(g.buildShip(0, .brig) == null);
    try std.testing.expectEqual(@as(u16, 100) - brig.timber, g.stores[0].timber);
    try std.testing.expectEqual(@as(u16, 130) - brig.coins, g.coins);
    try std.testing.expect(g.launchExpedition(0, 1, 0, .{}) != null);
    try std.testing.expect(g.launchExpedition(0, 0, 0, .{}) != null);
    g.stores[0].water = 60;
    try std.testing.expect(g.launchExpedition(0, 0, 0, .{}) == null);
    const outward = s.ocean.routes[0];
    try std.testing.expectEqual(@as(u16, 60) - s.expeditionRations(outward), g.stores[0].fruit);
    try std.testing.expectEqual(s.Game.ExpeditionEvent.none, g.advanceExpedition(0, 3));
    g = decode(&encode(g)).?;
    try std.testing.expectEqual(@as(f32, 3), g.fleet.vessels[0].elapsed);
    try std.testing.expect(!g.fleet.charted[0]);
    try std.testing.expectEqual(s.Game.ExpeditionEvent.charted, g.advanceExpedition(0, outward.leg_seconds - 3));
    try std.testing.expect(g.launchExpedition(0, 1, 0, .{}) != null);
    try std.testing.expectEqual(s.Game.ExpeditionEvent.none, g.advanceExpedition(0, 100));
    try std.testing.expectEqual(@as(?usize, 0), s.ocean.routeTo(g.fleet.vessels[0].chart));
    try std.testing.expectEqual(@as(f32, 1), g.fleet.vessels[0].progress());
    try std.testing.expectEqualDeep(g, decode(&encode(g)).?);

    const stores_at_departure = g.stores;
    try std.testing.expect(g.returnExpedition(0) == null);
    try std.testing.expect(g.returnExpedition(0) != null);
    try std.testing.expectEqual(s.Game.ExpeditionEvent.none, g.advanceExpedition(0, outward.leg_seconds / 2));
    g = decode(&encode(g)).?;
    try std.testing.expectEqual(@as(f32, 0.5), g.fleet.vessels[0].progress());
    try std.testing.expectEqual(s.Game.ExpeditionEvent.returned, g.advanceExpedition(0, outward.leg_seconds / 2));
    try std.testing.expectEqualDeep(stores_at_departure, g.stores);
    try std.testing.expect(g.buildShip(0, .barque) != null);
    try std.testing.expect(g.sendFerry(1, 0, .{ .timber = 1 }) == null);
    g.advanceShip(s.crossing_seconds);
    try std.testing.expect(g.buildShip(0, .barque) == null);
    try std.testing.expect(g.launchExpedition(1, 1, 0, .{}) == null);
    const farther = s.ocean.routes[1];
    try std.testing.expectEqual(s.Game.ExpeditionEvent.charted, g.advanceExpedition(1, farther.leg_seconds));
    try std.testing.expect(g.returnExpedition(1) == null);
    try std.testing.expectEqual(s.Game.ExpeditionEvent.returned, g.advanceExpedition(1, farther.leg_seconds));
    try std.testing.expectEqualDeep(g, decode(&encode(g)).?);
    try std.testing.expectEqualDeep([3]?s.Goal{ .settle_borneo, .settle_sumatra, .build_fleet }, g.nextGoals());
}

test "a survey ship lands settlers and supplies on the island it charts" {
    var g = s.Game.init();
    g.people = 6;
    g.coins = 120;
    try surveyFerryAndReturn(&g);
    g.charter = .{ .ferried_to_bali = true, .won = true, .housed_eight = true };
    g.bridges[0] = true;
    g.stores[0] = .{ .timber = 100, .stone = 60, .grain = 100, .venison = 100, .fruit = 100, .water = 100 };
    try std.testing.expect(g.buildShip(0, .brig) == null);
    const route = s.ocean.routes[0];
    const limit = g.surveySettlerLimit(0, 0);
    try std.testing.expectEqual(s.camp_capacity, limit);
    try std.testing.expectEqualStrings("A new camp has room for four settlers.", g.launchExpedition(0, 0, limit + 1, .{}).?);
    const camp = s.Stores{ .grain = 6, .water = 6, .timber = 4 };
    try std.testing.expect(g.launchExpedition(0, 0, limit, camp) == null);
    try std.testing.expectEqual(limit, g.reservedBeds(route.chart));
    try std.testing.expectEqualDeep(camp, g.incomingCargo(route.chart));
    // A second survey of the same island is refused while the first is at sea.
    try std.testing.expect(g.surveyProblem(0, 0) != null);
    g = decode(&encode(g)).?;
    try std.testing.expect(g.fleet.vessels[0].surveying);
    try std.testing.expectEqual(s.Game.ExpeditionEvent.charted, g.advanceExpedition(0, route.leg_seconds));
    try std.testing.expect(g.fleet.charted[0]);
    try std.testing.expectEqual(limit, g.residents(route.chart));
    try std.testing.expectEqualDeep(camp, g.stores[route.chart]);
    try std.testing.expect(!g.fleet.vessels[0].carryingLoad() and !g.fleet.vessels[0].surveying);
    try std.testing.expectEqualDeep(g, decode(&encode(g)).?);
}

test "a save with a loaded survey bound for a charted harbor is rejected" {
    var g = s.Game.init();
    g.people = 6;
    g.coins = 40;
    try std.testing.expect(g.surveyByFerry(1, 2, .{ .water = 3 }) == null);
    try std.testing.expectEqual(@as(u16, 2), g.reservedBeds(1));
    var bytes = encode(g);
    try std.testing.expect(decode(&bytes) != null);
    g.ferry.surveyed = true;
    g.openPort(1);
    bytes = encode(g);
    try std.testing.expect(decode(&bytes) == null);
}

test "Lombok keeps settlers and cargo after a saved passage" {
    var g = s.Game.init();
    g.people = 4;
    g.coins = 120;
    try surveyFerryAndReturn(&g);
    g.charter.won = true;
    g.bridges[0] = true;
    g.charter.ferried_to_bali = true;
    g.charter.housed_eight = true;
    g.stores[0] = .{ .timber = 100, .stone = 60, .grain = 100, .venison = 100, .fruit = 100, .water = 100 };
    try std.testing.expect(g.buildShip(0, .brig) == null);
    try std.testing.expect(g.sendExpedition(0, 0, 1, .{}) != null);
    try std.testing.expect(g.launchExpedition(0, 0, 0, .{}) == null);
    const route = s.ocean.routes[0];
    try std.testing.expectEqual(s.Game.ExpeditionEvent.charted, g.advanceExpedition(0, route.leg_seconds));
    try returnExpeditionToJava(&g);

    g = decode(&encode(g)).?;
    try std.testing.expectEqual(@as(u16, 1), g.countOn(2, .port));

    const stock = s.Stores{ .timber = 19, .stone = 4, .grain = 6, .venison = 6, .fruit = 6, .water = 6 };
    const water = g.stores[0].water;
    const rations = g.oceanRations(0, 0, 1).water;
    try std.testing.expectEqual(@as(u16, 0), g.housing(2));
    try std.testing.expect(g.sendExpedition(0, 0, 5, stock) != null);
    try std.testing.expect(g.sendExpedition(0, 0, 1, stock) == null);
    try std.testing.expectEqual(water - rations - stock.water, g.stores[0].water);
    try std.testing.expectEqual(@as(u16, 3), g.residents(0));
    try std.testing.expectEqual(@as(u16, 0), g.residents(2));
    _ = g.advanceExpedition(0, 5);
    g = decode(&encode(g)).?;
    try std.testing.expectEqual(@as(u16, 1), g.fleet.vessels[0].passengers);
    try std.testing.expectEqualDeep(stock, g.fleet.vessels[0].cargo);

    try std.testing.expectEqual(s.Game.ExpeditionEvent.delivered, g.advanceExpedition(0, route.leg_seconds - 5));
    try std.testing.expectEqual(@as(u16, 1), g.residents(2));
    try std.testing.expectEqualDeep(stock, g.stores[2]);
    try std.testing.expectEqual(s.Game.ExpeditionEvent.none, g.advanceExpedition(0, 100));
    try std.testing.expectEqualDeep(stock, g.stores[2]);
    try std.testing.expectEqual(@as(?usize, 0), s.ocean.routeTo(g.fleet.vessels[0].chart));
    try std.testing.expectEqualDeep(g, decode(&encode(g)).?);
    try std.testing.expect(g.build(2, s.Cell{ .x = 26, .y = 30 }, .well) == null);
    try std.testing.expectEqual(@as(u16, 2), g.stores[2].stone);
    try returnExpeditionToJava(&g);
    try std.testing.expectEqual(@as(u16, 1), g.residents(2));
    try std.testing.expectEqual(@as(u16, 4), g.people);
}

test "Borneo and Sumatra can be surveyed, settled, and restored at sea and on shore" {
    const borneo = s.geography.borneo;
    const sumatra = s.geography.sumatra;
    const borneo_route = s.ocean.routeTo(borneo).?;
    const sumatra_route = s.ocean.routeTo(sumatra).?;
    var g = s.Game.init();
    try std.testing.expect(g.build(0, s.Cell{ .x = 39, .y = 39 }, .cottage) == null);
    g.people = 8;
    g.coins = 180;
    try surveyFerryAndReturn(&g);
    g.charter.won = true;
    g.bridges[0] = true;
    g.charter.ferried_to_bali = true;
    g.charter.housed_eight = true;
    g.stores[0] = .{ .timber = 400, .stone = 100, .grain = 800, .venison = 800, .fruit = 800, .water = 800 };

    try std.testing.expect(g.buildShip(0, .brig) == null);
    try std.testing.expect(g.oceanRations(0, sumatra_route, 0).units() > g.fleet.vessels[0].ship.hold());
    try std.testing.expect(g.oceanRations(0, s.ocean.routeTo(s.geography.palawan).?, 0).units() > g.fleet.vessels[0].ship.hold());
    try std.testing.expect(g.launchExpedition(0, sumatra_route, 0, .{}) != null);
    try std.testing.expect(g.sendExpedition(0, borneo_route, 2, .{}) != null);
    try std.testing.expect(g.launchExpedition(0, borneo_route, 0, .{}) == null);
    const borneo_trip = s.ocean.routes[borneo_route];
    _ = g.advanceExpedition(0, 2);
    g = decode(&encode(g)).?;
    try std.testing.expectEqual(s.Game.ExpeditionEvent.charted, g.advanceExpedition(0, borneo_trip.leg_seconds - 2));
    try std.testing.expectEqual(@as(u16, 1), g.countOn(borneo, .port));
    try std.testing.expect(!g.islandOpen(sumatra));
    try returnExpeditionToJava(&g);

    const camp = s.Stores{ .timber = 19, .stone = 4, .grain = 6, .venison = 6, .fruit = 6, .water = 6 };
    const before_load = encode(g);
    try std.testing.expect(g.sendExpedition(0, borneo_route, 2, .{ .timber = 49 }) != null);
    try std.testing.expectEqual(before_load, encode(g));
    const reserves = g.stores[0].water;
    const rations = g.oceanRations(0, borneo_route, 2).water;
    try std.testing.expect(g.sendExpedition(0, borneo_route, 2, camp) == null);
    try std.testing.expectEqual(reserves - rations - camp.water, g.stores[0].water);
    try std.testing.expectEqual(@as(u16, 2), g.reservedBeds(borneo));
    try std.testing.expectEqual(@as(u16, 0), g.reservedBeds(sumatra));
    _ = g.advanceExpedition(0, 2);
    g = decode(&encode(g)).?;
    const borneo_stores = g.stores[borneo];
    try std.testing.expectEqual(s.Game.ExpeditionEvent.delivered, g.advanceExpedition(0, borneo_trip.leg_seconds - 2));
    try std.testing.expectEqual(@as(u16, 2), g.residents(borneo));
    try std.testing.expect(g.founded[0]);
    var borneo_after = borneo_stores;
    borneo_after.add(camp);
    try std.testing.expectEqualDeep(borneo_after, g.stores[borneo]);
    try std.testing.expect(g.build(borneo, s.Cell{ .x = 140, .y = 172 }, .well) == null);
    try std.testing.expect(g.build(borneo, s.Cell{ .x = 140, .y = 177 }, .lodge) == null);
    try std.testing.expect(g.build(borneo, s.Cell{ .x = 145, .y = 187 }, .road) == null);
    try std.testing.expect(g.production(borneo).fruit > 0);
    g = decode(&encode(g)).?;
    const settled_borneo = g.stores[borneo];
    try returnExpeditionToJava(&g);
    try std.testing.expectEqualDeep(settled_borneo, g.stores[borneo]);

    try std.testing.expect(g.launchExpedition(0, 0, 0, .{}) == null);
    try std.testing.expectEqual(s.Game.ExpeditionEvent.charted, g.advanceExpedition(0, s.ocean.routes[0].leg_seconds));
    try std.testing.expect(g.buildShip(0, .barque) == null);
    try std.testing.expect(g.launchExpedition(1, sumatra_route, 0, .{}) == null);
    const sumatra_trip = s.ocean.routes[sumatra_route];
    try std.testing.expectEqual(s.Game.ExpeditionEvent.charted, g.advanceExpedition(1, sumatra_trip.leg_seconds));
    try std.testing.expect(g.returnExpedition(1) == null);
    _ = g.advanceExpedition(1, sumatra_trip.leg_seconds);
    try std.testing.expect(g.sendExpedition(1, sumatra_route, 2, camp) == null);
    g = decode(&encode(g)).?;
    try std.testing.expectEqual(@as(u16, 2), g.reservedBeds(sumatra));
    try std.testing.expectEqual(@as(u16, 0), g.reservedBeds(borneo));
    try std.testing.expectEqual(s.Game.ExpeditionEvent.delivered, g.advanceExpedition(1, sumatra_trip.leg_seconds));
    try std.testing.expectEqualDeep(camp, g.stores[sumatra]);
    try std.testing.expectEqualDeep(settled_borneo, g.stores[borneo]);
    try std.testing.expect(g.build(sumatra, s.Cell{ .x = 76, .y = 34 }, .well) == null);
    try std.testing.expect(g.build(sumatra, s.Cell{ .x = 72, .y = 39 }, .lodge) == null);
    try std.testing.expect(g.production(sumatra).fruit > 0);
    try std.testing.expectEqualDeep(g, decode(&encode(g)).?);
    try std.testing.expectEqual(@as(u16, 8), g.people);
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 2), g.residents(borneo));
    try std.testing.expectEqual(@as(u16, 2), g.residents(sumatra));
    try std.testing.expectEqual(@as(u16, 9), g.people);
}

test "every expedition destination supports a survey and a saved settlement voyage" {
    for (s.ocean.routes, 0..) |route, index| {
        var g = s.Game.init();
        try std.testing.expect(g.build(0, s.Cell{ .x = 39, .y = 39 }, .cottage) == null);
        g.people = 8;
        g.ferry.surveyed = true;
        g.charter.won = true;
        g.bridges[0] = true;
        g.charter.ferried_to_bali = true;
        g.openPort(1);
        g.fleet.vessels[0].ship = route.ship;
        g.fleet.count = 1;
        if (route.ship == .barque) {
            g.fleet.charted[0] = true;
            g.openPort(2);
        }
        g.stores[0] = .{ .timber = 100, .stone = 100, .grain = 200, .venison = 200, .fruit = 200, .water = 200 };
        try std.testing.expect(g.launchExpedition(0, index, 0, .{}) == null);
        try std.testing.expectEqual(s.Game.ExpeditionEvent.charted, g.advanceExpedition(0, route.leg_seconds));
        try std.testing.expectEqual(@as(u16, 1), g.countOn(route.chart, .port));
        if (route.chart >= s.geography.borneo) try std.testing.expect(!g.founded[route.chart - s.geography.borneo]);
        try returnExpeditionToJava(&g);

        const load = s.Stores{ .timber = 11, .stone = 4, .grain = 4, .venison = 4, .fruit = 4, .water = 4 };
        if (g.sendExpedition(0, index, 2, load)) |problem| {
            std.debug.print("{s}: {s}\n", .{ route.name(), problem });
            return error.TestUnexpectedResult;
        }
        _ = g.advanceExpedition(0, 1);
        g = decode(&encode(g)).?;
        try std.testing.expectEqual(@as(u16, 2), g.reservedBeds(route.chart));
        try std.testing.expectEqual(s.Game.ExpeditionEvent.delivered, g.advanceExpedition(0, route.leg_seconds - 1));
        try std.testing.expectEqual(@as(u16, 2), g.residents(route.chart));
        if (route.chart >= s.geography.borneo) try std.testing.expect(g.founded[route.chart - s.geography.borneo]);
        try std.testing.expectEqualDeep(load, g.stores[route.chart]);

        const grid = s.geography.grids[route.chart];
        for (0..grid.area()) |tile| {
            const site = grid.cell(tile);
            if (s.wellSite(site, route.chart) and g.build(route.chart, site, .well) == null) break;
        } else {
            std.debug.print("No well site for {s}\n", .{route.name()});
            return error.TestUnexpectedResult;
        }
        for (0..grid.area()) |tile| {
            const site = grid.cell(tile);
            if (s.site(site, route.chart) == .deer and g.build(route.chart, site, .lodge) == null) break;
        } else {
            std.debug.print("No hunting site for {s}\n", .{route.name()});
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualDeep(g, decode(&encode(g)).?);

        try returnExpeditionToJava(&g);
        try std.testing.expect(g.sendExpedition(0, index, 0, .{ .timber = 6 }) == null);
        try std.testing.expectEqual(s.Game.ExpeditionEvent.delivered, g.advanceExpedition(0, route.leg_seconds));
        try std.testing.expectEqual(@as(u16, 2), g.residents(route.chart));
        try std.testing.expectEqual(@as(u16, 6), g.stores[route.chart].timber);
    }
}

test "shipyards charge local stores and reserve berths for incoming ships across reloads" {
    var g = s.Game.init();
    try std.testing.expect(g.build(0, s.Cell{ .x = 39, .y = 39 }, .cottage) == null);
    g.people = 12;
    g.island_people[0] = 4;
    g.ferry.surveyed = true;
    g.charter.won = true;
    g.bridges[0] = true;
    g.charter.ferried_to_bali = true;
    g.ferry.origin = 1;
    g.ferry.destination = 1;
    g.openPort(1);
    g.coins = 200;
    g.stores[0] = .{ .timber = 200, .stone = 50, .grain = 100, .venison = 100, .fruit = 100, .water = 100 };
    g.stores[1] = g.stores[0];

    const java_stores = g.stores[0];
    try std.testing.expect(g.buildShip(1, .brig) == null);
    try std.testing.expectEqualDeep(java_stores, g.stores[0]);
    try std.testing.expectEqual(@as(u16, 168), g.stores[1].timber);
    try std.testing.expectEqual(@as(usize, 2), g.berthsUsed(1));
    const bali_full = encode(g);
    try std.testing.expect(g.buildShip(1, .brig) != null);
    try std.testing.expectEqual(bali_full, encode(g));

    try std.testing.expect(g.returnExpedition(0) == null);
    try std.testing.expectEqual(@as(usize, 1), g.berthsUsed(0));
    try std.testing.expectEqual(@as(usize, 1), g.berthsUsed(1));
    try std.testing.expect(g.buildShip(0, .brig) == null);
    try std.testing.expect(g.sailFerry(0) != null);
    try std.testing.expect(g.buildShip(0, .brig) != null);
    g = decode(&encode(g)).?;
    try std.testing.expectEqual(s.Game.ExpeditionEvent.returned, g.advanceExpedition(0, s.crossing_seconds));
    try std.testing.expect(g.sailFerry(0) != null);

    const borneo_route = s.ocean.routeTo(s.geography.borneo).?;
    try std.testing.expect(g.launchExpedition(0, 0, 0, .{}) == null);
    try std.testing.expect(g.launchExpedition(1, 0, 0, .{}) != null);
    try std.testing.expect(g.launchExpedition(1, borneo_route, 0, .{}) == null);
    try std.testing.expect(g.sailFerry(0) == null);
    g = decode(&encode(g)).?;
    g.advanceShip(s.crossing_seconds);
    try std.testing.expectEqual(s.Game.ExpeditionEvent.charted, g.advanceExpedition(0, s.ocean.routes[0].leg_seconds));
    try std.testing.expectEqual(s.Game.ExpeditionEvent.charted, g.advanceExpedition(1, s.ocean.routes[borneo_route].leg_seconds));
    try std.testing.expectEqual(@as(usize, 2), g.fleet.count);
    try std.testing.expectEqual(@as(usize, 1), g.berthsUsed(2));
    try std.testing.expectEqual(@as(usize, 1), g.berthsUsed(s.geography.borneo));
    try std.testing.expect(g.returnExpedition(0) == null);
    try std.testing.expect(g.returnExpedition(1) != null);
    try std.testing.expectEqualDeep(g, decode(&encode(g)).?);
}

test "concurrent cargo voyages reserve landing space and unload exactly once" {
    var g = s.Game.init();
    try std.testing.expect(g.build(0, s.Cell{ .x = 39, .y = 39 }, .cottage) == null);
    g.people = 8;
    g.ferry.surveyed = true;
    g.charter.won = true;
    g.bridges[0] = true;
    g.charter.ferried_to_bali = true;
    g.ferry.origin = 1;
    g.ferry.destination = 1;
    g.openPort(1);
    g.coins = 100;
    g.stores[0] = .{ .timber = 200, .stone = 50, .grain = 100, .venison = 100, .fruit = 100, .water = 100 };
    try std.testing.expect(g.buildShip(0, .brig) == null);
    try std.testing.expect(g.buildShip(0, .brig) == null);
    g.fleet.charted[0] = true;
    g.openPort(2);
    g.stores[2].timber = std.math.maxInt(u16) - 10;
    try std.testing.expect(g.sendExpedition(0, 0, 2, .{ .timber = 6 }) == null);
    try std.testing.expect(g.sendExpedition(1, 0, 3, .{}) != null);
    try std.testing.expect(g.sendExpedition(1, 0, 2, .{ .timber = 5 }) != null);
    try std.testing.expect(g.sendExpedition(1, 0, 2, .{ .timber = 4 }) == null);
    try std.testing.expectEqual(@as(u16, 4), g.reservedBeds(2));
    try std.testing.expectEqual(@as(usize, 2), g.berthsUsed(2));
    g = decode(&encode(g)).?;
    for (0..g.fleet.count) |id| {
        try std.testing.expectEqual(s.Game.ExpeditionEvent.delivered, g.advanceExpedition(id, s.ocean.routes[0].leg_seconds));
        try std.testing.expectEqual(s.Game.ExpeditionEvent.none, g.advanceExpedition(id, 100));
    }
    try std.testing.expectEqual(@as(u16, 4), g.residents(2));
    try std.testing.expectEqual(std.math.maxInt(u16), g.stores[2].timber);
    try std.testing.expectEqualDeep(g, decode(&encode(g)).?);
}

test "woodlots and hunting lodges resume their recovery after reload" {
    var g = s.Game.init();
    g.people = 1;
    g.stores[0] = .{ .timber = 100, .grain = 100, .venison = 100, .fruit = 100, .water = 100 };
    const woods = s.Cell{ .x = 30, .y = 30 };
    const herd = s.Cell{ .x = 30, .y = 35 };
    try std.testing.expect(g.build(0, woods, .grove) == null);
    try std.testing.expect(g.build(0, herd, .lodge) == null);
    g.paveTo(0, woods);
    g.paveTo(0, herd);

    g = decode(&encode(g)).?;
    for (0..4) |day| {
        try std.testing.expectEqual(@as(u16, 4), g.production(0).timber);
        try std.testing.expectEqual(@as(u16, 3), g.production(0).venison);
        const before = g.stores[0];
        _ = g.tick();
        try std.testing.expectEqual(before.timber + 4, g.stores[0].timber);
        try std.testing.expectEqual(before.venison + 2, g.stores[0].venison);
        try std.testing.expectEqual(@as(u4, @intCast(9 - 3 * day)), g.harvestStatus(0, woods).?.stock);
    }

    try std.testing.expectEqual(@as(u4, 0), g.harvestStatus(0, herd).?.stock);
    try std.testing.expectEqual(@as(u16, 1), g.production(0).timber);
    try std.testing.expectEqual(@as(u16, 0), g.production(0).venison);
    _ = g.tick();
    var session = Session{ .game = g };
    const snapshot = session.encodeSession();
    session = Session.decodeSession(&snapshot).?;
    try std.testing.expectEqual(snapshot, session.encodeSession());
    g = session.game;
    try std.testing.expectEqual(@as(u4, 4), g.harvestStatus(0, woods).?.stock);
    try std.testing.expectEqual(@as(u4, 6), g.harvestStatus(0, herd).?.stock);
    try std.testing.expectEqual(@as(u16, 0), g.production(0).venison);
    _ = g.tick();
    try std.testing.expectEqual(@as(u4, 8), g.harvestStatus(0, woods).?.stock);
    try std.testing.expectEqual(@as(u16, 3), g.production(0).venison);
    _ = g.tick();
    try std.testing.expectEqual(@as(u16, 4), g.production(0).timber);

    g.stores[0].timber = std.math.maxInt(u16);
    g.stores[0].venison = std.math.maxInt(u16);
    _ = g.tick();
    try std.testing.expectEqual(s.harvest_capacity, g.harvestStatus(0, woods).?.stock);
    try std.testing.expectEqual(s.harvest_capacity, g.harvestStatus(0, herd).?.stock);
}

test "a ferry passage to Lombok survives a reload and a corrupt route is rejected" {
    var g = s.Game.init();
    g.coins = 2 * s.ferry.survey_cost;
    g.charter = .{ .ferried_to_bali = true, .won = true, .housed_eight = true };
    g.bridges[0] = true;
    try std.testing.expect(g.surveyByFerry(1, 0, .{}) == null);
    g.advanceShip(s.crossing_seconds);
    try std.testing.expect(g.surveyByFerry(2, 0, .{}) == null);
    g.advanceShip(1);
    try std.testing.expectEqualDeep(g, decode(&encode(g)).?);
    g.advanceShip(s.ferry.legSeconds(1, 2));
    try std.testing.expect(g.islandOpen(2) and g.fleet.count == 0);
    g = decode(&encode(g)).?;
    try std.testing.expectEqual(@as(?usize, 2), g.mooredChart());
    try std.testing.expect(g.sailFerry(1) == null);
    g.advanceShip(2);
    try std.testing.expectEqualDeep(g, decode(&encode(g)).?);

    // A corrupt route is rejected.
    var bytes = encode(g);
    const destination = offsetOf("ferry") + encodedSize(s.Stores) + 2 + 4;
    try std.testing.expectEqual(@as(u8, 1), bytes[destination]);
    bytes[destination] = 0;
    try std.testing.expect(decode(&bytes) == null);
    bytes[destination] = s.settlement_count;
    try std.testing.expect(decode(&bytes) == null);

}
