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
    drag_start: ?a.V = null,
    start_center: a.V = undefined,
    dragged: bool = false,

    pub fn world(self: View, p: a.V) a.V {
        return a.v(self.center.x + (p.x - middle.x) / self.zoom, self.center.y + (p.y - middle.y) / self.zoom);
    }

    pub fn project(self: View, p: a.V) a.V {
        return a.v(middle.x + (p.x - self.center.x) * self.zoom, middle.y + (p.y - self.center.y) * self.zoom);
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
            if (self.dragged) self.center = a.v(self.start_center.x - dx / self.zoom, self.start_center.y - dy / self.zoom);
            if (!r.isMouseButtonDown(.left)) {
                click = inside and !self.dragged and r.isMouseButtonReleased(.left);
                self.drag_start = null;
            }
        }
        const step = 410 * dt / self.zoom;
        if (r.isKeyDown(.left)) self.center.x -= step;
        if (r.isKeyDown(.right)) self.center.x += step;
        if (r.isKeyDown(.up)) self.center.y -= step;
        if (r.isKeyDown(.down)) self.center.y += step;
        const half_w = middle.x / self.zoom;
        const half_h = 246 / self.zoom;
        self.center.x = std.math.clamp(self.center.x, a.sea_left + half_w, a.sea_left + a.sea_width - half_w);
        self.center.y = std.math.clamp(self.center.y, a.sea_top + half_h, a.sea_top + a.sea_height - half_h);
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

    pub fn showIsland(self: *View, chart: usize) void {
        const inland = a.artWorldPoint(chart, a.v(450, 325));
        self.* = .{ .center = r.math.vector2Lerp(portPosition(chart), inland, 0.55), .zoom = 3.4 };
    }

    pub fn draw(self: View, g: *const s.Game, hover: ?Hit, time: f32, tool: s.Kind, preview_bridge: bool) void {
        r.gl.rlPushMatrix();
        defer r.gl.rlPopMatrix();
        r.gl.rlTranslatef(middle.x, middle.y, 0);
        r.gl.rlScalef(self.zoom, self.zoom, 1);
        r.gl.rlTranslatef(-self.center.x, -self.center.y, 0);
        const upper_left = self.world(a.v(0, 84));
        const lower_right = self.world(a.v(895, 576));
        a.sea(time, upper_left, lower_right);
        a.regionalLand(upper_left, lower_right);
        if (preview_bridge and !g.bridge) a.drawBridge(false);
        const show_settlements = self.zoom >= settlement_detail_zoom;
        for (0..s.settlement_count) |chart| {
            if (!show_settlements) break;
            if (chart >= 2 and !g.islandOpen(chart)) continue;
            const area = a.visibleTiles(chart, a.localPoint(chart, upper_left), a.localPoint(chart, lower_right)) orelse continue;
            r.gl.rlPushMatrix();
            const o = a.origin(chart);
            r.gl.rlTranslatef(o.x, o.y, 0);
            const scale = s.geography.tile_scale;
            r.gl.rlScalef(scale, scale, 1);
            const h = if (hover) |hit| if (hit.chart == chart) hit.cell else null else null;
            a.island(g, chart, area, h, time, if (g.constructionProblem(chart) == null) tool else .empty, self.zoom >= 1.15);
            r.gl.rlPopMatrix();
        }
        if (g.bridge) {
            a.drawBridge(true);
            a.bridgeTraffic(g, time);
        }
        a.ship(g, time);
        for (g.vessels(), 0..) |_, id| a.explorationShip(g, id, time);
    }
};

pub fn portPosition(chart: usize) a.V {
    return a.worldPoint(chart, a.tile(s.quay(chart)));
}

pub fn pickIsland(world: a.V, zoom: f32, game: *const s.Game) ?usize {
    var nearest: ?usize = null;
    var distance = port_hit_radius / zoom;
    for (0..s.settlement_count) |chart| {
        if (!game.islandOpen(chart)) continue;
        const gap = r.math.vector2Distance(portPosition(chart), world);
        if (gap < distance) {
            nearest = chart;
            distance = gap;
        }
    }
    if (distance <= port_pin_radius / zoom) return nearest;

    for (region.islands) |island| {
        const chart = island.settlement();
        if (!game.islandOpen(chart)) continue;
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

pub const Overview = struct {
    bounds: r.Rectangle,
    zoom: f32,

    pub fn init(bounds: r.Rectangle) Overview {
        return .{ .bounds = bounds, .zoom = @min(bounds.width / regional_width, bounds.height / regional_height) };
    }

    fn center(self: Overview) a.V {
        return a.v(self.bounds.x + self.bounds.width / 2, self.bounds.y + self.bounds.height / 2);
    }

    pub fn project(self: Overview, position: a.V) a.V {
        const mid = self.center();
        return a.v(mid.x + (position.x - regional_center.x) * self.zoom, mid.y + (position.y - regional_center.y) * self.zoom);
    }

    fn world(self: Overview, screen: a.V) a.V {
        const mid = self.center();
        return a.v(regional_center.x + (screen.x - mid.x) / self.zoom, regional_center.y + (screen.y - mid.y) / self.zoom);
    }

    pub fn pick(self: Overview, screen: a.V, game: *const s.Game) ?usize {
        if (!r.checkCollisionPointRec(screen, self.bounds)) return null;
        return pickIsland(self.world(screen), self.zoom, game);
    }

    pub fn draw(self: Overview, view: View, game: *const s.Game, selected: usize, hovered: ?usize) void {
        const bounds = self.bounds;
        a.rect(bounds.x, bounds.y, bounds.width, bounds.height, 0x40787a);
        {
            r.gl.rlPushMatrix();
            defer r.gl.rlPopMatrix();
            const mid = self.center();
            r.gl.rlTranslatef(mid.x, mid.y, 0);
            r.gl.rlScalef(self.zoom, self.zoom, 1);
            r.gl.rlTranslatef(-regional_center.x, -regional_center.y, 0);
            a.regionalLand(self.world(a.v(bounds.x, bounds.y)), self.world(a.v(bounds.x + bounds.width, bounds.y + bounds.height)));
        }
        const top = self.project(view.world(a.v(0, 84)));
        const bottom = self.project(view.world(a.v(895, 576)));
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
