const std = @import("std");
const r = @import("raylib");
const a = @import("art.zig");
const s = @import("core").colony;
const region = @import("core").region;

const middle = a.v(447.5, 330);
const fit_zoom: f32 = 0.62;
const max_zoom: f32 = 5.5;
const regional_bounds = blk: {
    var bounds = region.islands[0].bounds;
    for (region.islands[1..]) |isle| {
        for (0..2) |axis| {
            bounds[0][axis] = @min(bounds[0][axis], isle.bounds[0][axis]);
            bounds[1][axis] = @max(bounds[1][axis], isle.bounds[1][axis]);
        }
    }
    break :blk bounds;
};
const regional_min = a.chartPoint(regional_bounds[0]);
const regional_max = a.chartPoint(regional_bounds[1]);
const regional_center = a.v((regional_min.x + regional_max.x) / 2, (regional_min.y + regional_max.y) / 2);
const regional_width = regional_max.x - regional_min.x + 460;
const regional_height = regional_max.y - regional_min.y + 460;
pub const regional_zoom: f32 = @min(895 / regional_width, 492 / regional_height);
const far_zoom = regional_zoom * 0.97;
pub const settlement_detail_zoom: f32 = 0.60;
const port_hit_radius: f32 = 9;
const port_pin_radius: f32 = 5;

pub const Hit = struct { chart: usize, cell: s.Cell };
pub const View = struct {
    center: a.V = a.v(680, 350),
    zoom: f32 = fit_zoom,
    angle: a.Orientation = .north,
    drag_start: ?a.V = null,
    start_center: a.V = undefined,
    dragged: bool = false,

    fn worldOffset(self: View, delta: a.V) a.V {
        return self.angle.inverse().apply(a.v(delta.x / self.zoom, delta.y / self.zoom));
    }

    pub fn world(self: View, p: a.V) a.V {
        const offset = self.worldOffset(a.v(p.x - middle.x, p.y - middle.y));
        return a.v(self.center.x + offset.x, self.center.y + offset.y);
    }

    pub fn project(self: View, p: a.V) a.V {
        const offset = self.angle.apply(a.v(p.x - self.center.x, p.y - self.center.y));
        return a.v(middle.x + offset.x * self.zoom, middle.y + offset.y * self.zoom);
    }

    fn worldBounds(self: View) struct { min: a.V, max: a.V } {
        // A quarter turn keeps opposite viewport corners opposite on the chart.
        const first = self.world(a.v(0, 84));
        const last = self.world(a.v(895, 576));
        return .{ .min = a.v(@min(first.x, last.x), @min(first.y, last.y)), .max = a.v(@max(first.x, last.x), @max(first.y, last.y)) };
    }

    pub fn rotate(self: *View, clockwise: bool) void {
        self.angle = @fromBackingInt(@backingInt(self.angle) +% @as(u2, if (clockwise) 1 else 3));
        self.drag_start = null;
    }

    /// The visible top tile of the square can be a different corner after a turn.
    pub fn plazaAnchor(self: View, top: s.Cell) ?s.Cell {
        const x: usize = @intFromBool(self.angle == .south or self.angle == .west);
        const y: usize = @intFromBool(self.angle == .east or self.angle == .south);
        if (top.x < x or top.y < y) return null;
        return .{ .x = top.x - x, .y = top.y - y };
    }

    pub fn pick(self: View, p: a.V, g: *const s.Game) ?Hit {
        if (self.zoom < settlement_detail_zoom) return null;
        const pos = self.world(p);
        var water: ?Hit = null;
        var land: ?Hit = null;
        var nearest: f32 = std.math.inf(f32);
        for (0..s.settlement_count) |chart| {
            if (chart >= 2 and !g.islandOpen(chart)) continue;
            const cell = a.pick(a.localPoint(chart, pos), chart) orelse continue;
            const hit = Hit{ .chart = chart, .cell = cell };
            if (s.depth(cell, chart) >= 0) {
                const distance = r.math.vector2Distance(pos, a.worldPoint(chart, a.tile(cell)));
                if (distance < nearest) {
                    nearest = distance;
                    land = hit;
                }
            } else if (water == null) water = hit;
        }
        return land orelse water;
    }

    pub fn placementHit(self: View, picked: ?Hit, tool: s.Kind) ?Hit {
        var hit = picked orelse return null;
        if (tool == .plaza) hit.cell = self.plazaAnchor(hit.cell) orelse return null;
        return hit;
    }

    pub fn input(self: *View, mouse: a.V, inside: bool, dt: f32) bool {
        var click = false;
        if (inside) {
            const wheel = r.getMouseWheelMove();
            if (wheel != 0) {
                const before = self.world(mouse);
                self.zoom = std.math.clamp(self.zoom * std.math.pow(f32, 1.17, wheel), far_zoom, max_zoom);
                const after = self.world(mouse);
                self.center.x += before.x - after.x;
                self.center.y += before.y - after.y;
            }
            if (r.isMouseButtonPressed(.left)) {
                self.drag_start = mouse;
                self.start_center = self.center;
                self.dragged = false;
            }
        }
        if (self.drag_start) |start| {
            const dx = mouse.x - start.x;
            const dy = mouse.y - start.y;
            self.dragged = self.dragged or dx * dx + dy * dy > 16;
            if (self.dragged) {
                const delta = self.worldOffset(a.v(dx, dy));
                self.center = a.v(self.start_center.x - delta.x, self.start_center.y - delta.y);
            }
            if (!r.isMouseButtonDown(.left)) {
                click = inside and !self.dragged and r.isMouseButtonReleased(.left);
                self.drag_start = null;
            }
        }
        const east: f32 = if (r.isKeyDown(.right)) 410 * dt else 0;
        const west: f32 = if (r.isKeyDown(.left)) 410 * dt else 0;
        const south: f32 = if (r.isKeyDown(.down)) 410 * dt else 0;
        const north: f32 = if (r.isKeyDown(.up)) 410 * dt else 0;
        const pan = self.worldOffset(a.v(east - west, south - north));
        const extents = self.worldOffset(a.v(middle.x, 246));
        const half_w = @min(@abs(extents.x), a.sea_width / 2);
        const half_h = @min(@abs(extents.y), a.sea_height / 2);
        self.center.x = std.math.clamp(self.center.x + pan.x, a.sea_left + half_w, a.sea_left + a.sea_width - half_w);
        self.center.y = std.math.clamp(self.center.y + pan.y, a.sea_top + half_h, a.sea_top + a.sea_height - half_h);
        if (r.isKeyPressed(.home)) self.* = .{};
        return click;
    }

    pub fn showRegion(self: *View) void {
        self.* = .{ .center = regional_center, .zoom = regional_zoom };
    }

    pub fn showExpedition(self: *View, index: usize) void {
        const chart = s.ocean.routes[index].chart;
        if (chart >= s.geography.first_additional) return self.showRegion();
        self.* = switch (chart) {
            2 => .{ .center = a.v(880, 370), .zoom = 0.48 },
            s.geography.borneo => .{ .center = a.v(930, 225), .zoom = 0.52 },
            s.geography.sumatra => .{ .center = a.v(-305, -15), .zoom = 0.34 },
            else => .{ .center = a.v(1200, -390), .zoom = 0.205 },
        };
    }

    pub fn showPassage(self: *View, vessel: s.Vessel) void {
        const origin_chart = vessel.origin;
        const chart = vessel.chart;
        if (origin_chart == 0 or chart == 0) {
            if (s.ocean.routeTo(@max(origin_chart, chart))) |route| return self.showExpedition(route);
            self.* = .{};
            return;
        }
        const course = s.ocean.directCourse(origin_chart, chart) orelse return self.showRegion();
        const depart = s.ferry.berth(origin_chart);
        const arrive = s.ferry.berth(chart);
        var low = a.v(@min(depart[0], arrive[0]), @min(depart[1], arrive[1]));
        var high = a.v(@max(depart[0], arrive[0]), @max(depart[1], arrive[1]));
        for (course.waypoints) |point| {
            low = a.v(@min(low.x, point[0]), @min(low.y, point[1]));
            high = a.v(@max(high.x, point[0]), @max(high.y, point[1]));
        }
        self.* = .{
            .center = a.v((low.x + high.x) / 2, (low.y + high.y) / 2),
            .zoom = @min(1.2, 895 / (high.x - low.x + 240), 492 / (high.y - low.y + 240)),
        };
    }

    pub fn showIsland(self: *View, chart: usize) void {
        const inland = a.artWorldPoint(chart, a.v(450, 325));
        self.* = .{ .center = r.math.vector2Lerp(portPosition(chart), inland, 0.55), .zoom = 3.4, .angle = self.angle };
    }

    pub fn draw(self: View, g: *const s.Game, picked: ?Hit, time: f32, tool: s.Kind, preview_bridge: bool) void {
        const hover = self.placementHit(picked, tool);
        const hovered_tile = if (picked) |hit| self.angle.apply(a.worldPoint(hit.chart, a.tile(hit.cell))) else null;
        r.gl.rlPushMatrix();
        defer r.gl.rlPopMatrix();
        r.gl.rlTranslatef(middle.x, middle.y, 0);
        r.gl.rlScalef(self.zoom, self.zoom, 1);
        const center = self.angle.apply(self.center);
        r.gl.rlTranslatef(-center.x, -center.y, 0);
        const bounds = self.worldBounds();
        a.sea(time, bounds.min, bounds.max, self.angle);
        a.regionalLand(bounds.min, bounds.max, self.angle);
        if (preview_bridge and !g.bridges[s.strait]) _ = a.drawBridge(s.strait, false, self.angle, null);
        const show_settlements = self.zoom >= settlement_detail_zoom;
        for (0..s.settlement_count) |chart| {
            if (!show_settlements) break;
            if (chart >= 2 and !g.islandOpen(chart)) continue;
            const area = a.visibleTiles(chart, a.localPoint(chart, bounds.min), a.localPoint(chart, bounds.max)) orelse continue;
            r.gl.rlPushMatrix();
            const o = self.angle.apply(a.origin(chart));
            r.gl.rlTranslatef(o.x, o.y, 0);
            const scale = s.geography.tile_scale;
            r.gl.rlScalef(scale, scale, 1);
            const h = if (hover) |hit| if (hit.chart == chart) hit.cell else null else null;
            a.island(g, chart, area, h, time, if (g.constructionProblem(chart) == null) tool else .empty, self.zoom >= 1.15, self.angle);
            r.gl.rlPopMatrix();
        }
        var bridge_opacity: [s.crossings.len]u8 = @splat(255);
        for (g.bridges, 0..) |built, crossing| {
            if (!built) continue;
            bridge_opacity[crossing] = a.drawBridge(crossing, true, self.angle, hovered_tile);
            a.bridgeTraffic(g, crossing, time, self.angle, bridge_opacity[crossing]);
        }
        a.bridgeWalkers(g, time, self.angle, bridge_opacity);
        a.ship(g, time, self.angle, hovered_tile);
        for (g.vessels(), 0..) |_, id| a.explorationShip(g, id, time, self.angle, hovered_tile);

        if (picked) |hit| {
            if (tool != .plaza and s.depth(hit.cell, hit.chart) >= 0) {
                const scale = s.geography.tile_scale;
                a.tileOutline(hovered_tile.?, s.tile_width * scale, s.tile_height * scale, 1 / self.zoom, 0xffdc95);
            }
        }
    }
};

pub fn portPosition(chart: usize) a.V {
    return a.worldPoint(chart, a.tile(s.quay(chart)));
}

pub fn pickIsland(world: a.V, zoom: f32, game: *const s.Game) ?usize {
    const ports = chartedPorts(game);
    return pickMappedIsland(world, zoom, &ports);
}

const Ports = [s.settlement_count]bool;

fn chartedPorts(game: *const s.Game) Ports {
    var ports: Ports = undefined;
    for (&ports, 0..) |*visible, chart| visible.* = game.islandOpen(chart);
    return ports;
}

fn pickMappedIsland(world: a.V, zoom: f32, ports: *const Ports) ?usize {
    var nearest: ?usize = null;
    var distance = port_hit_radius / zoom;
    for (0..s.settlement_count) |chart| {
        if (!ports[chart]) continue;
        const gap = r.math.vector2Distance(portPosition(chart), world);
        if (gap < distance) {
            nearest = chart;
            distance = gap;
        }
    }
    if (distance <= port_pin_radius / zoom) return nearest;

    for (region.islands) |island| {
        const chart = island.settlement();
        if (!ports[chart]) continue;
        const min = a.chartPoint(island.bounds[0]);
        const max = a.chartPoint(island.bounds[1]);
        if (world.x < min.x or world.y < min.y or world.x > max.x or world.y > max.y) continue;
        for (island.triangles) |t| {
            if (r.checkCollisionPointTriangle(world, a.chartPoint(island.coast[t[0]]), a.chartPoint(island.coast[t[1]]), a.chartPoint(island.coast[t[2]]))) return chart;
        }
    }
    return nearest;
}

pub fn drawPortPin(at: a.V, selected: bool, hovered: bool) void {
    const size: f32 = if (selected or hovered) 5 else 3.5;
    r.drawCircleV(at, size + 1.5, a.c(0x233f40));
    r.drawCircleV(at, size, a.c(if (selected) 0xe2b66d else 0xfff0cd));
    if (hovered) r.drawCircleLinesV(at, 8, a.c(0xfff0cd));
}

pub const ExpeditionPin = enum { departure, charted, survey, return_only };

pub fn expeditionPin(game: *const s.Game, ship_id: usize, target: usize) ?ExpeditionPin {
    if (ship_id >= game.fleet.count) return null;
    const vessel = game.fleet.vessels[ship_id];
    if (vessel.phase != .docked) return null;
    if (target == vessel.chart) return .departure;
    const survey = !game.islandOpen(target);
    const route = s.ocean.destinationIndex(target);
    if (game.expeditionProblem(ship_id, route, survey) == null) return if (survey) .survey else .charted;
    if (target == vessel.origin and game.returnExpeditionProblem(ship_id) == null) return .return_only;
    return null;
}

pub fn drawExpeditionPin(at: a.V, pin: ExpeditionPin, hovered: bool) void {
    if (hovered) r.drawCircleLinesV(at, 10, a.c(0xfff0cd));
    switch (pin) {
        .departure => {
            a.diamond(at.x, at.y, 8, 8, 0x233f40);
            a.diamond(at.x, at.y, 5.5, 5.5, 0xe2b66d);
        },
        .charted => {
            r.drawCircleV(at, 6.5, a.c(0x233f40));
            r.drawCircleV(at, 4.5, a.c(0xfff0cd));
        },
        .survey => {
            r.drawCircleV(at, 6.5, a.c(0x233f40));
            r.drawCircleV(at, 4.5, a.c(0xfff0cd));
            r.drawCircleV(at, 2.75, a.c(0x233f40));
        },
        .return_only => {
            r.drawCircleV(at, 6.5, a.c(0x233f40));
            r.drawCircleV(at, 4.5, a.c(0xa6e0dd));
            a.line(a.v(at.x - 2.5, at.y), a.v(at.x + 2.5, at.y), 1.8, 0x233f40);
        },
    }
}

pub const Overview = struct {
    bounds: r.Rectangle,
    zoom: f32,
    map_center: a.V = regional_center,
    drag: ?struct { pointer: a.V, map_center: a.V, moved: bool = false } = null,

    pub fn init(bounds: r.Rectangle) Overview {
        return .{ .bounds = bounds, .zoom = @min(bounds.width / regional_width, bounds.height / regional_height) };
    }

    pub fn center(self: Overview) a.V {
        return a.v(self.bounds.x + self.bounds.width / 2, self.bounds.y + self.bounds.height / 2);
    }

    pub fn project(self: Overview, position: a.V) a.V {
        const mid = self.center();
        return a.v(mid.x + (position.x - self.map_center.x) * self.zoom, mid.y + (position.y - self.map_center.y) * self.zoom);
    }

    fn world(self: Overview, screen: a.V) a.V {
        const mid = self.center();
        return a.v(self.map_center.x + (screen.x - mid.x) / self.zoom, self.map_center.y + (screen.y - mid.y) / self.zoom);
    }

    pub fn pick(self: Overview, screen: a.V, game: *const s.Game) ?usize {
        const ports = chartedPorts(game);
        return self.pickPorts(screen, &ports);
    }

    pub fn pickPorts(self: Overview, screen: a.V, ports: *const Ports) ?usize {
        if (!r.checkCollisionPointRec(screen, self.bounds)) return null;
        return pickMappedIsland(self.world(screen), self.zoom, ports);
    }

    fn clampCenter(self: *Overview) void {
        const x = @max(0, (regional_width - self.bounds.width / self.zoom) / 2);
        const y = @max(0, (regional_height - self.bounds.height / self.zoom) / 2);
        self.map_center.x = std.math.clamp(self.map_center.x, regional_center.x - x, regional_center.x + x);
        self.map_center.y = std.math.clamp(self.map_center.y, regional_center.y - y, regional_center.y + y);
    }

    pub fn zoomAt(self: *Overview, anchor: a.V, factor: f32) void {
        const fit = init(self.bounds).zoom;
        const before = self.world(anchor);
        self.zoom = std.math.clamp(self.zoom * factor, fit, fit * 12);
        const after = self.world(anchor);
        self.map_center.x += before.x - after.x;
        self.map_center.y += before.y - after.y;
        self.clampCenter();
    }

    pub fn input(self: *Overview, mouse: a.V) bool {
        const inside = r.checkCollisionPointRec(mouse, self.bounds);
        if (inside) {
            const wheel = r.getMouseWheelMove();
            if (wheel != 0) self.zoomAt(mouse, std.math.pow(f32, 1.24, wheel));
            if (r.isMouseButtonPressed(.left)) self.drag = .{ .pointer = mouse, .map_center = self.map_center };
        }
        if (self.drag) |*drag| {
            const dx = mouse.x - drag.pointer.x;
            const dy = mouse.y - drag.pointer.y;
            drag.moved = drag.moved or dx * dx + dy * dy > 16;
            if (drag.moved) {
                self.map_center = a.v(drag.map_center.x - dx / self.zoom, drag.map_center.y - dy / self.zoom);
                self.clampCenter();
            }
            if (!r.isMouseButtonDown(.left)) {
                const clicked = inside and !drag.moved and r.isMouseButtonReleased(.left);
                self.drag = null;
                return clicked;
            }
        }
        return false;
    }

    pub fn drawLand(self: Overview) void {
        const bounds = self.bounds;
        a.rect(bounds.x, bounds.y, bounds.width, bounds.height, 0x40787a);
        r.gl.rlPushMatrix();
        defer r.gl.rlPopMatrix();
        const mid = self.center();
        r.gl.rlTranslatef(mid.x, mid.y, 0);
        r.gl.rlScalef(self.zoom, self.zoom, 1);
        r.gl.rlTranslatef(-self.map_center.x, -self.map_center.y, 0);
        a.regionalLand(self.world(a.v(bounds.x, bounds.y)), self.world(a.v(bounds.x + bounds.width, bounds.y + bounds.height)), .north);
    }

    pub fn draw(self: Overview, view: View, game: *const s.Game, selected: usize, hovered: ?usize) void {
        self.drawLand();
        const bounds = self.bounds;
        const viewport = view.worldBounds();
        const top = self.project(viewport.min);
        const bottom = self.project(viewport.max);
        const x1 = @max(bounds.x + 1, top.x);
        const y1 = @max(bounds.y + 1, top.y);
        const x2 = @min(bounds.x + bounds.width - 1, bottom.x);
        const y2 = @min(bounds.y + bounds.height - 1, bottom.y);
        if (x1 < x2 and y1 < y2) r.drawRectangleLinesEx(.{ .x = x1, .y = y1, .width = x2 - x1, .height = y2 - y1 }, 1, a.c(0xacc9bd));

        for (0..s.settlement_count) |chart| {
            if (!game.islandOpen(chart)) continue;
            drawPortPin(self.project(portPosition(chart)), chart == selected, chart == hovered);
        }
    }
};

test "expedition overview offers only destinations the selected ship can sail to" {
    var game = s.Game.init();
    game.chartHarbor(1);
    game.chartHarbor(2);
    game.chartHarbor(27);
    game.bridges[0] = true;
    game.charter = .{ .won = true, .ferried_to_bali = true, .housed_eight = true };
    game.people = 10;
    game.island_people[0] = 6;
    game.store(1).* = .{ .grain = 90, .venison = 90, .fruit = 90, .water = 90 };
    game.fleet.count = 1;
    game.fleet.vessels[0] = .{ .ship = .brig, .chart = 1 };
    try std.testing.expectEqual(@as(?ExpeditionPin, .departure), expeditionPin(&game, 0, 1));
    try std.testing.expectEqual(@as(?ExpeditionPin, .survey), expeditionPin(&game, 0, 25));
    try std.testing.expectEqual(@as(?ExpeditionPin, .charted), expeditionPin(&game, 0, 27));
    try std.testing.expect(expeditionPin(&game, 0, 0) == null); // The ferry occupies Java's berth.
    try std.testing.expect(expeditionPin(&game, 0, s.geography.sumatra) == null);
    game.fleet.vessels[0].ship = .barque;
    try std.testing.expectEqual(@as(?ExpeditionPin, .survey), expeditionPin(&game, 0, s.geography.sumatra));
    game.fleet.vessels[0].ship = .brig;
    game.store(1).water = 0;
    try std.testing.expect(expeditionPin(&game, 0, 27) == null);
    game.store(1).water = 90;

    var map = Overview.init(.{ .x = 211, .y = 319, .width = 779, .height = 318 });
    var available: Ports = undefined;
    for (&available, 0..) |*port, island| port.* = expeditionPin(&game, 0, island) != null;
    for (available, 0..) |visible, island| {
        if (visible) try std.testing.expectEqual(@as(?usize, island), map.pickPorts(map.project(portPosition(island)), &available));
    }
    const sumatra = map.project(portPosition(s.geography.sumatra));
    try std.testing.expect(map.pickPorts(sumatra, &available) == null);
    const survey_pin = map.project(portPosition(25));
    try std.testing.expect(map.pick(survey_pin, &game) == null);
    for (region.islands) |island| {
        if (island.settlement() != s.geography.borneo) continue;
        const triangle = island.triangles[0];
        const p = a.chartPoint(island.coast[triangle[0]]);
        const q = a.chartPoint(island.coast[triangle[1]]);
        const r0 = a.chartPoint(island.coast[triangle[2]]);
        const inland = map.project(a.v((p.x + q.x + r0.x) / 3, (p.y + q.y + r0.y) / 3));
        try std.testing.expectEqual(@as(?usize, s.geography.borneo), map.pickPorts(inland, &available));
    }
    map.zoomAt(survey_pin, 3);
    try std.testing.expectEqual(@as(?usize, 25), map.pickPorts(survey_pin, &available));
    try std.testing.expect(map.pickPorts(a.v(210, survey_pin.y), &available) == null);

    // A brig without enough reserves for a new voyage can still use a stocked port to return.
    game.chartHarbor(25);
    game.fleet.vessels[0] = .{ .ship = .brig, .chart = 25 };
    game.store(25).* = .{ .grain = 8, .venison = 8, .fruit = 8, .water = 8 };
    try std.testing.expect(expeditionPin(&game, 0, 0) == null);
    game.ferry = .{ .origin = 1, .destination = 1, .surveyed = true };
    try std.testing.expectEqual(@as(?ExpeditionPin, .return_only), expeditionPin(&game, 0, 0));
    game.fleet.vessels[0].provisions = 8;
    game.store(25).* = .{};
    try std.testing.expectEqual(@as(?ExpeditionPin, .charted), expeditionPin(&game, 0, 0));
    try std.testing.expectEqual(@as(?ExpeditionPin, .survey), expeditionPin(&game, 0, s.geography.sumatra));
}

test "zoom and pan preserve picking for every buildable island tile" {
    var g = s.Game.init();
    g.fleet.charted = @splat(true);
    for ([_]f32{ settlement_detail_zoom, 1.1, 3.4 }) |zoom| {
        for (0..s.settlement_count) |chart| {
            const view = View{ .center = portPosition(chart), .zoom = zoom };
            const grid = s.geography.grids[chart];
            for (0..grid.height) |y| for (0..grid.width) |x| {
                const cell = s.Cell{ .x = x, .y = y };
                if (s.depth(cell, chart) < 0) continue;
                const screen = view.project(a.worldPoint(chart, a.tile(cell)));
                try std.testing.expectEqualDeep(Hit{ .chart = chart, .cell = cell }, view.pick(screen, &g).?);
            };
        }
    }
}

test "quarter turns keep the focus and pick the same tiles from each side" {
    var game = s.Game.init();
    game.ferry.surveyed = true;
    game.fleet.charted = @splat(true);
    const turns = [_]a.Orientation{ .north, .east, .south, .west };
    const step_x = [_]f32{ 1, -1, -1, 1 };
    const step_y = [_]f32{ 1, 1, -1, -1 };

    for (0..s.settlement_count) |chart| {
        const center = portPosition(chart);
        var view = View{ .center = center, .zoom = 3.4 };
        const quay = s.quay(chart);
        const grid = s.geography.grids[chart];
        for (turns, step_x, step_y) |turn, dx, dy| {
            try std.testing.expectEqual(turn, view.angle);
            try std.testing.expectEqualDeep(center, view.center);
            try std.testing.expectEqualDeep(middle, view.project(center));
            const next = view.project(a.worldPoint(chart, a.tile(.{ .x = quay.x + 1, .y = quay.y })));
            const scale = view.zoom * s.geography.tile_scale;
            try std.testing.expectApproxEqAbs(middle.x + dx * s.tile_width * scale, next.x, 0.002);
            try std.testing.expectApproxEqAbs(middle.y + dy * s.tile_height * scale, next.y, 0.002);

            for (quay.y -| 2..@min(quay.y + 3, grid.height)) |y| {
                for (quay.x -| 2..@min(quay.x + 3, grid.width)) |x| {
                    const cell = s.Cell{ .x = x, .y = y };
                    if (s.depth(cell, chart) < 0) continue;
                    const screen = view.project(a.worldPoint(chart, a.tile(cell)));
                    try std.testing.expectEqualDeep(Hit{ .chart = chart, .cell = cell }, view.pick(screen, &game).?);
                }
            }
            view.rotate(true);
        }
        try std.testing.expectEqual(a.Orientation.north, view.angle);
        view.rotate(false);
        try std.testing.expectEqual(a.Orientation.west, view.angle);
    }
}

test "the top tile places the same four plaza tiles from every angle" {
    const anchor = s.Cell{ .x = 45, .y = 42 };
    const cells = s.plazaCells(anchor);
    var view = View{};
    for (0..4) |_| {
        var top = cells[0];
        for (cells[1..]) |cell| {
            const screen = view.project(a.worldPoint(0, a.tile(cell)));
            if (screen.y < view.project(a.worldPoint(0, a.tile(top))).y) top = cell;
        }
        try std.testing.expectEqualDeep(anchor, view.plazaAnchor(top).?);
        view.rotate(true);
    }
}

test "all islands use the same tile size and port zoom" {
    const width = s.tile_width * s.geography.tile_scale;
    const height = s.tile_height * s.geography.tile_scale;
    var view = View{};
    for (0..s.settlement_count) |chart| {
        view.showIsland(chart);
        const port = s.quay(chart);
        const first = s.worldTile(port, chart);
        const next = s.worldTile(.{ .x = port.x + 1, .y = port.y }, chart);
        try std.testing.expectApproxEqAbs(width, next[0] - first[0], 0.001);
        try std.testing.expectApproxEqAbs(height, next[1] - first[1], 0.001);
        try std.testing.expectEqual(@as(f32, 3.4), view.zoom);
    }
}

test "ship stays on water between the two quays" {
    for (0..201) |step| {
        const pos = a.shipPosition(a.f(step) / 200);
        for (0..s.geography.names.len) |chart| {
            if (a.pick(a.localPoint(chart, pos), chart)) |cell| try std.testing.expect(s.depth(cell, chart) < 0);
        }
        for (region.islands) |isle| for (isle.triangles) |t| {
            try std.testing.expect(!r.checkCollisionPointTriangle(pos, a.chartPoint(isle.coast[t[0]]), a.chartPoint(isle.coast[t[1]]), a.chartPoint(isle.coast[t[2]])));
        };
    }
}

test "the drawn ferry stays at sea on every leg, its own islands included" {
    for (0..s.settlement_count) |from| {
        for (s.ferry.neighbors(from).slice()) |to| {
            for (0..401) |step| {
                const pos = a.ferryPosition(from, to, a.f(step) / 400);
                if (s.ferry.onLand(.{ pos.x, pos.y }, from, to)) {
                    std.debug.print("{s} to {s} crosses land at step {d}\n", .{ s.chart_names[from], s.chart_names[to], step });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "outer routes stay at sea and fit in the chart viewport" {
    for (0..s.ocean.routes.len) |index| {
        var view = View{};
        view.showExpedition(index);
        for (0..201) |step| {
            const pos = a.expeditionPosition(index, a.f(step) / 200);
            const projected = view.project(pos);
            const name = s.ocean.routes[index].name();
            if (projected.x < 0 or projected.x >= 895 or projected.y < 84 or projected.y >= 576) {
                std.debug.print("{s} route leaves the viewport at step {d}\n", .{ name, step });
                return error.TestUnexpectedResult;
            }
            for (0..s.geography.names.len) |chart| {
                if (a.pick(a.localPoint(chart, pos), chart)) |cell| {
                    if (s.depth(cell, chart) >= 0) {
                        std.debug.print("{s} route crosses {s} tiles at step {d}\n", .{ name, s.chart_names[chart], step });
                        return error.TestUnexpectedResult;
                    }
                }
            }
            for (region.islands) |isle| for (isle.triangles) |t| {
                if (r.checkCollisionPointTriangle(pos, a.chartPoint(isle.coast[t[0]]), a.chartPoint(isle.coast[t[1]]), a.chartPoint(isle.coast[t[2]]))) {
                    std.debug.print("{s} route crosses {s} coastline at step {d}\n", .{ name, isle.name, step });
                    return error.TestUnexpectedResult;
                }
            };
        }
    }
}

test "the overview fits the regional coastlines" {
    var view = View{};
    view.showRegion();
    var outlined: [s.settlement_count]bool = @splat(false);
    for (region.islands) |isle| {
        const chart = isle.settlement();
        try std.testing.expect(!outlined[chart]);
        outlined[chart] = true;
        for (isle.bounds) |corner| {
            const screen = view.project(a.chartPoint(corner));
            try std.testing.expect(screen.x > 0 and screen.x < 895 and screen.y > 84 and screen.y < 576);
        }
    }
    for (outlined) |present| try std.testing.expect(present);
}

test "the inset selects surveyed ports and large island interiors" {
    const inset = Overview.init(.{ .x = 670, .y = 411, .width = 210, .height = 151 });
    var g = s.Game.init();
    try std.testing.expectEqual(@as(?usize, 0), inset.pick(inset.project(portPosition(0)), &g));
    try std.testing.expectEqual(@as(?usize, null), inset.pick(inset.project(portPosition(1)), &g));
    try std.testing.expectEqual(@as(?usize, null), inset.pick(inset.project(portPosition(s.geography.borneo)), &g));
    g.ferry.surveyed = true;
    g.fleet.charted = @splat(true);
    for (0..s.settlement_count) |chart| {
        try std.testing.expectEqual(@as(?usize, chart), inset.pick(inset.project(portPosition(chart)), &g));
    }
    for (region.islands) |island| {
        const chart = island.settlement();
        if (chart >= s.geography.first_additional and !std.mem.eql(u8, island.name, "New Guinea")) continue;
        try std.testing.expectEqual(@as(?usize, chart), inset.pick(inset.project(a.chartPoint(island.label)), &g));
    }
    try std.testing.expectEqual(@as(?usize, null), inset.pick(a.v(0, 0), &g));
    try std.testing.expectEqual(@as(?usize, null), inset.pick(a.v(672, 414), &g));
}
