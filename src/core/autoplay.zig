// A scripted player for playability tests. It starts from a new game, reads
// the state only through the aggregate's queries, picks every tile by
// searching the map outward from a harbor, and acts only through gameplay
// commands, so it gets no free stock and no hand-picked coordinates. If a map
// or rule change makes the charter unreachable, the test fails and prints
// the player's recent decisions.
const std = @import("std");
const domain = @import("colony.zig");
const gameplay = @import("gameplay.zig");
const queries = @import("queries.zig");

const Cell = domain.Cell;
const Game = domain.Game;
const Kind = domain.Kind;
const Stores = domain.Stores;
const java = 0;
const bali = @import("charter.zig").charter_island;

/// The last decisions, printed when a playthrough fails.
pub const Log = struct {
    const capacity = 64;
    lines: [capacity][120]u8 = undefined,
    lengths: [capacity]usize = @splat(0),
    next: usize = 0,
    total: usize = 0,

    pub fn note(log: *Log, game: *const Game, comptime format: []const u8, args: anytype) void {
        const slot = log.next;
        const prefix = std.fmt.bufPrint(&log.lines[slot], "day {d}: ", .{game.day}) catch unreachable;
        const body = std.fmt.bufPrint(log.lines[slot][prefix.len..], format, args) catch log.lines[slot][prefix.len..];
        log.lengths[slot] = prefix.len + body.len;
        log.next = (slot + 1) % capacity;
        log.total += 1;
    }

    pub fn print(log: *const Log) void {
        const shown = @min(log.total, capacity);
        for (0..shown) |i| {
            const slot = (log.next + capacity - shown + i) % capacity;
            std.debug.print("  {s}\n", .{log.lines[slot][0..log.lengths[slot]]});
        }
    }
};

pub const Player = struct {
    game: Game = Game.init(),
    log: Log = .{},

    fn act(p: *Player, command: gameplay.Command) bool {
        return switch (gameplay.apply(&p.game, command)) {
            .applied => true,
            .denied => false,
            .advanced => unreachable,
        };
    }

    fn build(p: *Player, chart: usize, cell: Cell, kind: Kind) bool {
        if (!p.act(.{ .build = .{ .island = chart, .cell = cell, .kind = kind } })) return false;
        p.log.note(&p.game, "{s} at ({d},{d}) on {s}", .{ domain.names[@backingInt(kind)], cell.x, cell.y, domain.chart_names[chart] });
        return true;
    }

    /// Lays the roads that join `cell` to the harbor, if the island can pay for them.
    fn affordablePath(p: *const Player, chart: usize, cell: Cell, buffer: []Cell) ?[]Cell {
        const path = p.game.roadPath(chart, cell, buffer) orelse return null;
        if (path.len * domain.costs[@backingInt(Kind.road)] > p.game.stores[chart].stone) return null;
        return path;
    }

    fn pave(p: *Player, chart: usize, path: []const Cell) void {
        for (path) |cell| std.debug.assert(p.act(.{ .build = .{ .island = chart, .cell = cell, .kind = .road } }));
        if (path.len > 0) p.log.note(&p.game, "{d} road tiles on {s}", .{ path.len, domain.chart_names[chart] });
    }

    /// The nearest tile to the harbor, by rings, that `fits` accepts.
    fn nearest(p: *const Player, chart: usize, comptime fits: fn (*const Player, usize, Cell) bool) ?Cell {
        const grid = domain.geography.grids[chart];
        const home = grid.quay;
        const widest = @max(grid.width, grid.height);
        for (0..widest) |radius| {
            const left = home.x -| radius;
            const top = home.y -| radius;
            const right = @min(grid.width - 1, home.x + radius);
            const bottom = @min(grid.height - 1, home.y + radius);
            for (top..bottom + 1) |y| {
                for (left..right + 1) |x| {
                    const ring = @max(@max(x, home.x) - @min(x, home.x), @max(y, home.y) - @min(y, home.y));
                    if (ring != radius) continue;
                    const cell = Cell{ .x = x, .y = y };
                    if (domain.depth(cell, chart) >= 0 and p.game.tileAt(chart, cell) == .empty and fits(p, chart, cell)) return cell;
                }
            }
        }
        return null;
    }

    fn openGround(p: *const Player, chart: usize, cell: Cell) bool {
        _ = p;
        return domain.site(cell, chart) == .plain and !domain.forest(cell, chart) and !domain.wellSite(cell, chart);
    }

    fn anyOpenGround(p: *const Player, chart: usize, cell: Cell) bool {
        _ = p;
        return domain.site(cell, chart) == .plain and !domain.forest(cell, chart);
    }

    fn wellGround(p: *const Player, chart: usize, cell: Cell) bool {
        _ = p;
        return domain.wellSite(cell, chart);
    }

    /// Places a building on open ground, keeping well sites free when it can.
    fn placeOnOpenGround(p: *Player, chart: usize, kind: Kind) bool {
        const cell = p.nearest(chart, openGround) orelse p.nearest(chart, anyOpenGround) orelse return false;
        return p.build(chart, cell, kind);
    }

    fn reachableSite(comptime wanted: domain.Site, comptime woods: bool) fn (*const Player, usize, Cell) bool {
        return struct {
            fn fits(p: *const Player, chart: usize, cell: Cell) bool {
                if (domain.site(cell, chart) != wanted) return false;
                if (woods and !domain.forest(cell, chart)) return false;
                var buffer: [256]Cell = undefined;
                return p.affordablePath(chart, cell, &buffer) != null;
            }
        }.fits;
    }

    /// Builds a producer on its nearest affordable site and roads it to the harbor.
    fn placeProducer(p: *Player, chart: usize, kind: Kind) bool {
        const cell = switch (kind) {
            .quarry => p.nearest(chart, reachableSite(.outcrop, false)),
            .lodge => p.nearest(chart, reachableSite(.deer, false)),
            .grove => p.nearest(chart, reachableSite(.plain, true)),
            else => unreachable,
        } orelse return false;
        var buffer: [256]Cell = undefined;
        const path = p.affordablePath(chart, cell, &buffer).?;
        const roads_needed = path.len;
        if (p.game.stores[chart].timber < domain.costs[@backingInt(kind)]) return false;
        if (!p.build(chart, cell, kind)) return false;
        // Building the producer may already join it to a neighbor.
        const rest = p.game.roadPath(chart, cell, &buffer) orelse return true;
        std.debug.assert(rest.len <= roads_needed);
        p.pave(chart, rest);
        return true;
    }

    /// Joins the nearest unreached fruit tree to the harbor.
    fn gatherFruit(p: *Player, chart: usize) bool {
        const tree = p.nearest(chart, struct {
            fn fits(q: *const Player, c: usize, cell: Cell) bool {
                if (domain.site(cell, c) != .fruit or q.game.connected(c, cell)) return false;
                var buffer: [256]Cell = undefined;
                const path = q.affordablePath(c, cell, &buffer) orelse return false;
                return path.len > 0;
            }
        }.fits) orelse return false;
        var buffer: [256]Cell = undefined;
        p.pave(chart, p.affordablePath(chart, tree, &buffer).?);
        return true;
    }

    fn timber(p: *const Player, chart: usize) u16 {
        return p.game.stores[chart].timber;
    }

    /// One improvement for an island's food, water and materials, most urgent first.
    fn improve(p: *Player, chart: usize) bool {
        const g = &p.game;
        if (g.residents(chart) == 0 or g.constructionProblem(chart) != null) return false;
        const ledger = queries.ledger(g, chart);
        // Plan for the next settler too, so growth never starts a shortage.
        const need = domain.dailyUse(ledger.residents + 1);
        const make = ledger.production;
        const stock = ledger.stock;
        // Bali saves for the lighthouse once the colony is big enough to raise it.
        const saving: u16 = if (chart == bali and !g.charter.won and g.people >= 8) domain.costs[@backingInt(Kind.light)] else 0;
        const t = p.timber(chart) -| saving;
        if (make.water < need and stock.water < 4 * need and make.water < ledger.water_limit and t >= domain.costs[@backingInt(Kind.well)] and stock.stone >= domain.well_stone) {
            if (p.nearest(chart, wellGround)) |cell| if (p.build(chart, cell, .well)) return true;
        }
        if (make.grain < need + 1 and t >= domain.costs[@backingInt(Kind.farm)]) {
            if (p.placeOnOpenGround(chart, .farm)) return true;
        }
        if (make.fruit < need and p.gatherFruit(chart)) return true;
        if (make.venison < need and t >= domain.costs[@backingInt(Kind.lodge)] and p.placeProducer(chart, .lodge)) return true;
        if (make.stone == 0 and t >= domain.costs[@backingInt(Kind.quarry)] and p.placeProducer(chart, .quarry)) return true;
        if (make.timber < 2 + need and t >= domain.costs[@backingInt(Kind.grove)] and p.placeProducer(chart, .grove)) return true;
        // House more settlers only while every food and water already covers them.
        const surplus = make.grain >= need and make.venison >= need and make.fruit >= need and make.water >= need;
        if (surplus and ledger.housing <= ledger.residents and t >= domain.costs[@backingInt(Kind.cottage)] + 4) {
            if (p.placeOnOpenGround(chart, .cottage)) return true;
        }
        return false;
    }

    /// Sells grain beyond a few days' reserve to fund surveys and the lighthouse.
    fn trade(p: *Player, chart: usize) void {
        const reserve = 6 + 4 * p.game.dailyDemand(chart);
        while (p.game.stores[chart].grain >= reserve + 6 and p.game.coins < 60) {
            if (!p.act(.{ .export_grain = chart })) break;
            p.log.note(&p.game, "sold grain on {s}, {d} coins", .{ domain.chart_names[chart], p.game.coins });
        }
    }

    /// Supplies Bali still needs from Java: six days of whatever food and
    /// water it can't yet make, then materials for the lighthouse and bridge.
    fn baliWants(p: *const Player, arriving: u16) Stores {
        const g = &p.game;
        const ledger = queries.ledger(g, bali);
        const need = domain.dailyUse(ledger.residents + arriving);
        var wants = Stores{};
        inline for (domain.food_fields ++ .{"water"}) |name| {
            const shortfall = need -| @field(ledger.production, name);
            @field(wants, name) = (6 * shortfall) -| @field(ledger.stock, name);
        }
        const lighthouse: u16 = if (g.charter.won) 0 else domain.costs[@backingInt(Kind.light)];
        const bridge = if (g.bridge) Stores{} else domain.bridge_cost;
        const building: u16 = 16;
        wants.timber = (lighthouse + bridge.timber + building) -| g.stores[bali].timber;
        wants.stone = (bridge.stone + domain.well_stone) -| g.stores[bali].stone;
        return wants;
    }

    /// Timber a survey must carry before the player lands settlers with it:
    /// enough for Bali's first well and farm.
    const settle_timber: u16 = 8;

    /// Moves the ferry, settlers and supplies toward the opening charter.
    /// The survey of Bali already carries its first settlers.
    fn ferry(p: *Player) void {
        const g = &p.game;
        const moored = g.mooredChart() orelse return;
        const survey = !g.islandOpen(bali);
        if (survey) {
            if (moored != java or g.coins < 20 or g.people < 4) return;
        } else {
            if (g.bridge) return p.overland();
            if (moored == bali) {
                if (p.act(.{ .sail_ferry = java })) p.log.note(g, "ferry returns to Java", .{});
                return;
            }
        }
        // Keep two settlers working Java; move the rest until Bali has its bridge crew.
        const spare = g.residents(java) -| 2;
        const crew = domain.bridge_crew -| g.residents(bali);
        const settlers = @min(spare, crew, g.ferryBoardingLimit(bali, survey));
        const camp = if (settlers > 0) g.ferryCampSupplies(bali, settlers, survey) else Stores{};
        var load = camp;
        const rations = g.ferryProvisions(java, bali, settlers);
        var room = domain.ferry_hold -| (load.units() + rations.units());
        const wants = p.baliWants(settlers);
        const limits = g.ferryCargoLimit(bali, settlers);
        const keep = p.javaKeeps();
        inline for (domain.food_fields ++ .{ "water", "stone", "timber" }) |name| {
            const spare_goods = @field(limits, name) -| @field(load, name) -| @field(keep, name);
            const amount: u16 = @intCast(@min(room, @field(wants, name), spare_goods));
            @field(load, name) += amount;
            room -= amount;
        }
        // Settle Bali on the survey only when Java can also send the timber to build there.
        const settle = !survey or load.timber >= settle_timber;
        const manifest: gameplay.Manifest = if (settle) .{ .settlers = settlers, .cargo = load } else .{ .settlers = 0, .cargo = .{} };
        if (survey) {
            if (p.act(.{ .survey_harbor = .{ .destination = bali, .manifest = manifest } }))
                p.log.note(g, "ferry surveys Bali with {d} settlers, cargo {any}", .{ manifest.settlers, manifest.cargo });
            return;
        }
        if (settlers == 0 and load.units() < 8) return;
        p.log.note(g, "ferry to Bali: {d} settlers, cargo {any}", .{ settlers, load });
        std.debug.assert(p.act(.{ .send_ferry = .{ .destination = bali, .manifest = manifest } }));
    }

    /// What Java holds back for its own settlers and buildings.
    fn javaKeeps(p: *const Player) Stores {
        const need = p.game.dailyDemand(java);
        return .{ .timber = 14, .stone = 6, .grain = 4 * need + 2, .venison = 4 * need, .fruit = 4 * need, .water = 4 * need };
    }

    /// Once the bridge stands, settlers and supplies cross overland.
    fn overland(p: *Player) void {
        const g = &p.game;
        const wants = p.baliWants(0);
        const keep = p.javaKeeps();
        const limits = g.bridgeCargoLimit(java);
        var load = Stores{};
        inline for (domain.store_fields) |name| {
            @field(load, name) = @min(@field(wants, name), @field(limits, name) -| @field(keep, name));
        }
        if (!load.empty() and p.act(.{ .transfer_stores = .{ .source = java, .cargo = load } }))
            p.log.note(g, "carried {any} over the bridge", .{load});
    }

    fn charter(p: *Player) void {
        const g = &p.game;
        if (!g.bridge and g.bridgeProblem() == null and p.act(.build_bridge)) p.log.note(g, "bridge built", .{});
        if (!g.charter.won and g.coins >= 30 and g.people >= 8 and p.timber(bali) >= domain.costs[@backingInt(Kind.light)]) {
            _ = p.placeOnOpenGround(bali, .light);
        }
    }

    /// Plays one day: every affordable improvement, then the clock.
    pub fn day(p: *Player) void {
        p.charter();
        for ([_]usize{ java, bali }) |chart| {
            var steps: usize = 0;
            while (steps < 8 and p.improve(chart)) : (steps += 1) {}
            p.trade(chart);
        }
        p.ferry();
        const outcome = gameplay.apply(&p.game, .{ .advance = gameplay.untilNextDay(&p.game) });
        std.debug.assert(outcome == .advanced);
        if (outcome.advanced.day) |report| {
            for (report.shortages, 0..) |shortage, chart| {
                if (shortage != .none) p.log.note(&p.game, "{s} shortage on {s}", .{ @tagName(shortage), domain.chart_names[chart] });
            }
        }
    }
};

/// Days a scripted player may take to complete the opening island charter
/// (house eight settlers, ferry settlers to Bali, raise the lighthouse and
/// bridge the strait). The player finished on day 18 when this was set.
pub const charter_day_budget = 30;

fn failPlaythrough(player: *const Player, reason: []const u8) error{TestUnexpectedResult} {
    const g = &player.game;
    std.debug.print("Autoplay failed: {s} (day {d}, {d} settlers, {d} coins, goals {any})\n", .{ reason, g.day, g.people, g.coins, g.nextGoals() });
    player.log.print();
    return error.TestUnexpectedResult;
}

test "a scripted player completes the island charter from a new game within the day budget and loses no settlers" {
    const player = try std.testing.allocator.create(Player);
    defer std.testing.allocator.destroy(player);
    player.* = .{};
    var peak: u16 = player.game.people;
    while (!player.game.charterComplete()) {
        if (player.game.people < peak) return failPlaythrough(player, "a settler died");
        peak = player.game.people;
        if (player.game.day > charter_day_budget) return failPlaythrough(player, "over the day budget");
        player.day();
    }
    if (player.game.people < peak) return failPlaythrough(player, "a settler died");
    // Every opening goal is behind the player; ship construction is next.
    try std.testing.expectEqual(@as(?domain.Goal, .build_brig), player.game.nextGoals()[0]);
}
