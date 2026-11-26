const std = @import("std");
const r = @import("raylib");
const a = @import("art.zig");
const chart_view = @import("chart.zig");
const region = @import("region.zig");
const roads = @import("core").roads;
const s = @import("core").colony;
const gameplay = @import("core").gameplay;
const journal_file = @import("shell").journal_file;
const gameplay_trace = @import("shell").gameplay_trace;
const queries = @import("core").queries;
const diagnostics = @import("shell").diagnostics;
const audio = @import("audio.zig");
pub const panic = std.debug.FullPanic(diagnostics.crash);
pub const std_options: std.Options = .{ .logFn = diagnostics.log };
const save = @import("core").save;
const save_store = @import("shell").save_store;
const browser = @import("shell").browser;
const stock_warnings = @import("core").stock_warnings;
const window_settings = @import("window_settings.zig");
const game_title = "Archipelagist";
const new_charter_message = "The ship brought fresh water. Build a well before the reserve runs out.";
const ink = 0x233f40;
const paper = 0xf2ebd9;
const muted = 0x526960;
const gold = 0xe2b66d;
const island_field = r.Rectangle{ .x = 350, .y = 9, .width = 210, .height = 25 };
const island_row_height: f32 = 30;
const island_menu_rows = 8;
const inset = chart_view.Overview.init(.{ .x = 670, .y = 411, .width = 210, .height = 151 });
const inset_panel = r.Rectangle{ .x = 665, .y = 387, .width = 220, .height = 180 };
const inset_hide = r.Rectangle{ .x = 828, .y = 389, .width = 52, .height = 20 };
const inset_show = r.Rectangle{ .x = 731, .y = 535, .width = 154, .height = 32 };
var sans: r.Font = undefined;
var serif: r.Font = undefined;
var mouse: a.V = undefined;
var pressed: bool = false;
fn label(str: [:0]const u8, x: f32, y: f32, size: f32, col: u32, display: bool) void {
    r.drawTextEx(if (display) serif else sans, str, a.v(x, y), size, if (display) 0 else 0.45, a.c(col));
}
fn num(comptime fmt: []const u8, args: anytype, x: f32, y: f32, size: f32, col: u32) void {
    var b: [140]u8 = undefined;
    label(std.fmt.bufPrintSentinel(&b, fmt, args, 0) catch "?", x, y, size, col, false);
}
fn over(x: f32, y: f32, w: f32, h: f32) bool {
    return mouse.x >= x and mouse.x < x + w and mouse.y >= y and mouse.y < y + h;
}
fn button(str: [:0]const u8, x: f32, y: f32, w: f32, h: f32) bool {
    const hot = over(x, y, w, h);
    a.rect(x, y, w, h, if (hot) 0x496b5c else 0x31564e);
    label(str, x + 11, y + (h - 18) / 2, 17, 0xfff5df, false);
    return hot and pressed;
}
fn counter(name: [:0]const u8, value: u16, x: f32, color: u32) void {
    label(name, x, 39, 11, 0xc4d4bf, false);
    num("{d}", .{value}, x, 51, 24, color);
}

fn warningColor(pulse_elapsed: f32) u32 {
    const phase = (2 * std.math.pi / (stock_warnings.pulse_seconds / 2)) * pulse_elapsed;
    const glow = (1 - @cos(phase)) / 2;
    const green: u32 = @intFromFloat(151 + glow * 54);
    const blue: u32 = @intFromFloat(136 + glow * 55);
    return 0xff0000 | (green << 8) | blue;
}

fn compass(x: f32, y: f32, sz: f32) void {
    r.drawCircleLinesV(a.v(x, y), sz * 0.74, a.c(0xc4d5be));
    for (0..4) |i| {
        const theta = a.f(i) * std.math.pi / 2;
        const dx = @sin(theta);
        const dy = -@cos(theta);
        const tip = a.v(x + dx * sz, y + dy * sz);
        a.tri(tip, a.v(x - dy * 4, y + dx * 4), a.v(x, y), 0xf2dfae);
        a.tri(tip, a.v(x + dy * 4, y - dx * 4), a.v(x, y), 0x315c5a);
    }
}
const opts = [_]s.Kind{ .cottage, .grove, .farm, .light, .road, .quarry, .lodge, .well };
const desc = [_][:0]const u8{ "Houses 4", "Up to 3 timber", "+5 grain/day", "Bali", "Connects paths", "+3 stone/day", "Up to 3 venison", "Up to 4 water" };
const keys = [_]r.KeyboardKey{ .one, .two, .three, .four, .five, .six, .seven, .eight };
const camp_supplies = s.Stores{ .timber = 19, .stone = 4, .grain = 6, .venison = 6, .fruit = 6, .water = 6 };
const supply_names = [_][:0]const u8{ "Timber", "Stone", "Grain", "Venison", "Fruit", "Water" };
const Modal = enum { none, restart, bridge, shipyard, manifest };
const ShipyardTab = enum { ferry, expedition, build };
/// What the manifest dialog loads: the ferry bound for a harbor, an
/// expedition on a route, or a bridge transfer from an island.
const Loading = union(enum) { ferry: usize, expedition: usize, bridge: usize };
const LoadResult = enum { restored, missing, unreadable };

const UI = struct {
    effects: audio.Effects,
    trace: ?*diagnostics.Trace = null,
    journal: ?*journal_file.Recorder = null,
    store: save_store.Store,
    g: s.Game = s.Game.init(),
    stock_alerts: stock_warnings.Tracker = undefined,
    last_saved: ?save.SessionBytes = null,
    autosave_time: f32 = 0,
    preserve_unreadable_save: bool = false,
    modal: Modal = .none,
    modal_note: ?[:0]const u8 = null,
    store_chart: usize = 0,
    island_menu_open: bool = false,
    island_offset: usize = 0,
    island_cursor: usize = 0,
    inset_collapsed: bool = false,
    shipyard_tab: ShipyardTab = .ferry,
    shipyard_page: usize = 0,
    ship_id: usize = 0,
    loading: Loading = .{ .ferry = 0 },
    cargo_manifest: s.Stores = .{},
    boarding: u16 = 0,
    slider_focus: ?usize = null,
    slider_drag: ?usize = null,
    restart_failed: bool = false,
    quit_requested: bool = false,
    view: chart_view.View = .{},
    tool: s.Kind = .empty,
    msg: [:0]const u8 = new_charter_message,
    elapsed: f32 = 0,
    speed: u8 = 1,
    message_text: [144]u8 = undefined,
    fn dispatch(u: *UI, command: gameplay.Command) gameplay.Outcome {
        return gameplay_trace.dispatch(.{ .trace = u.trace, .journal = u.journal }, &u.g, command);
    }

    fn playCue(u: *const UI, cue: audio.Cue) void {
        const accepted = u.effects.play(cue);
        if (u.trace) |trace| trace.note("audio", "cue", .{ .cue = cue, .accepted = accepted });
    }

    fn session(u: *const UI) save.Session {
        return .{ .game = u.g, .speed = u.speed };
    }

    fn restore(u: *UI, saved: save.Session) void {
        u.g = saved.game;
        // State replaced outside the command boundary starts a new replay segment.
        if (u.journal) |recorder| recorder.snapshot(saved);
        if (u.trace) |trace| trace.note("session", "restored", .{ .day = u.g.day, .fleet_size = u.g.fleet.count, .population = u.g.people, .speed = saved.speed });
        u.stock_alerts = .init(u.g.stores);
        u.island_menu_open = false;
        u.cargo_manifest = .{};
        u.speed = saved.speed;
        u.view = .{};
        u.ship_id = 0;
        if (u.g.fleet.count > 0 and u.g.fleet.vessels[0].chart != 0) {
            const vessel = u.g.fleet.vessels[0];
            if (vessel.phase == .docked) u.selectIsland(vessel.chart, true) else u.watchExpedition(vessel.chart);
        } else if (u.g.mooredChart()) |chart| {
            u.selectIsland(if (chart == 0 and u.g.islandOpen(u.store_chart)) u.store_chart else chart, true);
        }
        u.tool = .empty;
        u.shipyard_tab = if (u.g.charterComplete()) .expedition else .ferry;
        u.shipyard_page = 0;
        u.last_saved = null;
        u.autosave_time = 0;
        u.elapsed = 0;
    }

    fn saveNow(u: *UI, force: bool) !void {
        if (u.preserve_unreadable_save) return error.UnreadableSave;
        const bytes = u.session().encodeSession();
        if (!force) {
            if (u.last_saved) |last| {
                if (std.mem.eql(u8, &last, &bytes)) return;
            }
        }
        try u.store.write(&bytes);
        u.last_saved = bytes;
        u.autosave_time = 0;
    }

    fn load(u: *UI, startup: bool) LoadResult {
        const saved = u.store.read(u.store.path) catch {
            u.preserve_unreadable_save = true;
            u.msg = "The saved charter could not be read. Restart to replace it with a new charter.";
            return .unreadable;
        };
        if (saved) |existing| {
            u.restore(existing);
            u.preserve_unreadable_save = false;
            u.msg = "Harbor ledger restored.";
            return .restored;
        }
        if (!startup) u.msg = "No saved charter found.";
        return .missing;
    }

    fn restartDialog(u: *UI) void {
        const over_charter = u.g.isOver();
        a.rect(310, 246, 580, 256, paper);
        a.rect(310, 246, 580, 6, gold);
        if (over_charter) {
            label("Game over", 340, 280, 36, ink, true);
            num("The last settler died on day {d}.", .{u.g.day}, 340, 340, 19, ink);
            if (button("Quit", 578, 428, 110, 40)) u.quit_requested = true;
        } else {
            label("Restart charter?", 340, 280, 36, ink, true);
            label("A fresh settlement will replace your current saved charter.", 340, 340, 19, ink, false);
        }
        if (u.restart_failed) label("Could not save the new charter. Try again.", 340, 375, 17, 0x8b4235, false);
        if (!over_charter and (button("Cancel", 578, 428, 110, 40) or r.isKeyPressed(.escape))) {
            u.modal = .none;
            u.restart_failed = false;
        }
        if (button("Start over", 707, 428, 150, 40)) {
            const fresh = save.Session{};
            const bytes = fresh.encodeSession();
            u.store.write(&bytes) catch {
                u.restart_failed = true;
                return;
            };
            u.restore(fresh);
            u.store_chart = 0;
            u.last_saved = bytes;
            u.preserve_unreadable_save = false;
            u.modal = .none;
            u.restart_failed = false;
            u.msg = new_charter_message;
            u.playCue(.anchor_drop);
        }
    }

    fn closeModal(u: *UI) void {
        u.modal = .none;
        u.modal_note = null;
    }

    fn bridgeDialog(u: *UI) void {
        const top: f32 = 182;
        const footer_y: f32 = if (u.g.bridge) 544 else 513;
        a.rect(280, top, 640, footer_y + 63 - top, paper);
        a.rect(280, top, 640, 6, gold);
        label(if (u.g.bridge) "Island bridge" else "Bridge the islands", 309, 215, 36, ink, true);
        if (u.g.bridge) {
            label("Move a settler to a free bed on the other island.", 309, 276, 19, ink, false);
            for (s.chart_names[0..2], 0..) |name, chart| {
                num("{s}   {d} resident{s}   /   {d} places available", .{
                    name, u.g.residents(chart), if (u.g.residents(chart) == 1) "" else "s", u.g.freeLandingSpace(chart),
                }, 309, 310 + a.f(chart) * 30, 19, ink);
            }
            if (button("Move 1 to Java", 309, 376, 278, 36)) {
                u.modal_note = u.dispatch(.{ .cross_bridge = 0 }).problem() orelse "A settler crossed to Java.";
            }
            if (button("Move 1 to Bali", 607, 376, 278, 36)) {
                u.modal_note = u.dispatch(.{ .cross_bridge = 1 }).problem() orelse "A settler crossed to Bali.";
            }
            if (button("Transfer stores from Java", 309, 424, 278, 36)) u.openManifest(.{ .bridge = 0 });
            if (button("Transfer stores from Bali", 607, 424, 278, 36)) u.openManifest(.{ .bridge = 1 });
        } else {
            num("{d} spans of {d} allowed. Both islands supply materials and crew.", .{ s.bridge_spans, s.max_bridge_spans }, 309, 276, 19, ink);
            label("Timber", 537, 333, 16, muted, false);
            label("Stone", 657, 333, 16, muted, false);
            label("Crew", 779, 333, 16, muted, false);
            for (s.chart_names[0..2], 0..) |name, chart| {
                const local = u.g.stores[chart];
                const y = 368 + a.f(chart) * 37;
                label(name, 309, y, 20, ink, true);
                num("{d} / {d}", .{ local.timber, s.bridge_cost.timber }, 537, y, 19, ink);
                num("{d} / {d}", .{ local.stone, s.bridge_cost.stone }, 657, y, 19, ink);
                num("{d} / {d}", .{ u.g.residents(chart), s.bridge_crew }, 779, y, 19, ink);
            }
            if (button("Build bridge", 708, footer_y, 177, 36)) {
                if (u.dispatch(.build_bridge).problem()) |failure| {
                    u.playCue(.denied);
                    u.modal_note = failure;
                } else {
                    u.playCue(if (u.g.charterComplete()) .beacon else .build);
                    u.view = .{};
                    u.msg = if (u.g.charterComplete()) "Bridge open. The shipyard is ready to build exploration ships." else "The bridge is open to settlers and supplies.";
                    u.closeModal();
                }
            }
        }
        if (u.g.islandOpen(2)) {
            num("Bali to Lombok needs {d} spans. The bridge limit is {d}.", .{ s.bali_lombok_spans, s.max_bridge_spans }, 309, footer_y - 69, 17, muted);
        }
        if (u.modal_note) |note| label(note, 309, footer_y - 37, 17, ink, false);
        if (button("Close", 309, footer_y, 88, 36) or r.isKeyPressed(.escape)) u.closeModal();
    }

    fn setMessage(u: *UI, comptime fmt: []const u8, args: anytype) void {
        u.msg = std.fmt.bufPrintSentinel(&u.message_text, fmt, args, 0) catch unreachable;
    }

    fn openManifest(u: *UI, passage: Loading) void {
        u.modal = .manifest;
        u.modal_note = null;
        u.loading = passage;
        u.slider_focus = null;
        u.slider_drag = null;
        u.cargo_manifest = .{};
        u.boarding = switch (passage) {
            .ferry => |destination| u.g.ferryLimit(destination),
            .expedition => |index| @min(2, u.g.oceanSettlerLimit(u.ship_id, index)),
            .bridge => 0,
        };
        switch (passage) {
            .ferry => |destination| u.cargo_manifest = u.g.ferryCampSupplies(destination, u.boarding),
            .expedition => |index| {
                const chart = s.ocean.routes[index].chart;
                if (u.boarding > 0 and u.g.residents(chart) == 0) u.cargo_manifest = camp_supplies;
            },
            .bridge => {},
        }
    }

    fn slider(u: *UI, id: usize, y: f32, amount: *u16, limit: u16) void {
        const x = 469;
        const width = 352;
        if (limit != 0 and pressed and over(x - 10, y - 13, width + 20, 26)) {
            u.slider_focus = id;
            u.slider_drag = id;
        }
        if (u.slider_drag == id) {
            const fraction = std.math.clamp((mouse.x - x) / width, 0, 1);
            amount.* = @intFromFloat(@round(fraction * a.f(limit)));
            u.modal_note = null;
            if (!r.isMouseButtonDown(.left)) u.slider_drag = null;
        }
        if (limit != 0 and u.slider_focus == id) {
            if (r.isKeyPressed(.left) or r.isKeyPressedRepeat(.left)) amount.* -|= 1;
            if (r.isKeyPressed(.right) or r.isKeyPressedRepeat(.right)) amount.* = @min(limit, amount.* +| 1);
        }
        const thumb = x + if (limit == 0) 0 else width * a.f(amount.*) / a.f(limit);
        a.rect(x, y - 3, width, 6, 0xceccb7);
        a.rect(x, y - 3, thumb - x, 6, 0x638170);
        r.drawCircleV(a.v(thumb, y), 7, a.c(if (limit == 0) muted else 0x31564e));
        if (u.slider_focus == id) r.drawCircleLinesV(a.v(thumb, y), 10, a.c(0x31564e));
        num("{d} / {d}", .{ amount.*, limit }, 850, y - 10, 17, ink);
    }

    fn manifestDialog(u: *UI) void {
        const loading = u.loading;
        const source = switch (loading) {
            .ferry => u.g.mooredChart() orelse u.g.ferry.origin,
            .bridge => |port| port,
            .expedition => 0,
        };
        const target = switch (loading) {
            .ferry => |destination| destination,
            .bridge => 1 - source,
            .expedition => |index| s.ocean.routes[index].chart,
        };
        const hold: u32 = switch (loading) {
            .ferry => s.ferry_hold,
            .expedition => u.g.fleet.vessels[u.ship_id].ship.hold(),
            .bridge => std.math.maxInt(u32),
        };

        a.rect(194, 76, 812, 608, paper);
        a.rect(194, 76, 812, 6, gold);
        label(if (loading == .bridge) "Bridge stores" else "Load and board", 226, 102, 35, ink, true);
        num("{s} to {s}   /   {s}", .{
            s.chart_names[source], s.chart_names[target],
            switch (loading) {
                .ferry => "Harbor ferry",
                .expedition => u.g.fleet.vessels[u.ship_id].ship.name(),
                .bridge => "Overland transfer",
            },
        }, 226, 153, 21, ink);
        if (loading != .bridge) {
            const limit = switch (loading) {
                .ferry => u.g.ferryLimit(target),
                .expedition => |index| u.g.oceanSettlerLimit(u.ship_id, index),
                .bridge => unreachable,
            };
            label("Settlers aboard", 226, 192, 20, ink, false);
            u.slider(0, 203, &u.boarding, limit);
        }
        const rations: s.Stores = switch (loading) {
            .ferry => u.g.ferryProvisions(source, target, u.boarding),
            .expedition => |index| u.g.oceanRations(u.ship_id, index, u.boarding),
            .bridge => .{},
        };
        const limits = switch (loading) {
            .ferry => u.g.ferryCargoLimit(target, u.boarding),
            .expedition => |index| u.g.oceanCargoLimit(u.ship_id, index, u.boarding),
            .bridge => u.g.bridgeCargoLimit(source),
        };
        const room = hold -| rations.units();
        var remaining = room;
        // Preserve landing rations first when boarding more settlers reduces space for cargo.
        inline for (.{ "water", "grain", "venison", "fruit", "stone", "timber" }) |field| {
            const amount = &@field(u.cargo_manifest, field);
            amount.* = @intCast(@min(amount.*, @field(limits, field), remaining));
            remaining -= amount.*;
        }
        a.rect(226, 283, 747, 1, 0xcac9b4);
        if (loading == .bridge) {
            label("Choose supplies to carry across the bridge.", 226, 225, 18, muted, false);
        } else if (loading == .expedition) {
            num("Voyage rations   {d} each of grain, venison, fruit, and water", .{rations.grain}, 226, 226, 17, muted);
        } else {
            num("Voyage rations   {d} grain or venison", .{rations.units()}, 226, 226, 17, muted);
        }
        inline for (s.store_fields, supply_names, 0..) |field, name, i| {
            const y = 312 + a.f(i) * 44;
            const amount = &@field(u.cargo_manifest, field);
            const unloaded_space = room - (u.cargo_manifest.units() - amount.*);
            const limit: u16 = @intCast(@min(@field(limits, field), unloaded_space));
            label(name, 226, y - 12, 20, ink, false);
            u.slider(i + 1, y, amount, limit);
            a.rect(226, y + 22, 747, 1, 0xd9d4c1);
        }
        if (loading != .bridge) {
            num("Hold   {d} / {d} units   /   {d} cargo + {d} rations", .{
                u.cargo_manifest.units() + rations.units(), hold, u.cargo_manifest.units(), rations.units(),
            }, 226, 253, 18, ink);
        }
        if (u.modal_note) |note| label(note, 226, 573, 17, 0x8b4235, false);
        if (button("Back", 226, 623, 114, 37) or r.isKeyPressed(.escape)) {
            u.modal = if (loading == .bridge) .bridge else .shipyard;
            u.modal_note = null;
            return;
        }
        const caption = if (loading == .bridge) "Transfer stores" else "Launch voyage";
        if (button(caption, 808, 623, 165, 37)) {
            const failure = switch (loading) {
                .ferry => u.dispatch(.{ .send_ferry = .{ .destination = target, .manifest = .{ .settlers = u.boarding, .cargo = u.cargo_manifest } } }).problem(),
                .expedition => |index| u.dispatch(.{ .send_expedition = .{ .ship = u.ship_id, .route = index, .manifest = .{ .settlers = u.boarding, .cargo = u.cargo_manifest } } }).problem(),
                .bridge => u.dispatch(.{ .transfer_stores = .{ .source = source, .cargo = u.cargo_manifest } }).problem(),
            };
            if (failure) |problem| {
                u.playCue(.denied);
                u.modal_note = problem;
                return;
            }
            u.closeModal();
            switch (loading) {
                .ferry => u.view = .{},
                .expedition => |index| u.view.showExpedition(index),
                .bridge => {},
            }
            u.playCue(if (loading == .bridge) .trade else .sail);
            if (loading == .bridge) {
                u.setMessage("Supplies crossed the bridge to {s}.", .{s.chart_names[target]});
            } else {
                u.setMessage("The {s} has set sail for {s}.", .{ if (loading == .ferry) "ferry" else "expedition ship", s.chart_names[target] });
            }
        }
    }

    fn shipyardDialog(u: *UI) void {
        a.rect(177, 83, 846, 591, paper);
        a.rect(177, 83, 846, 6, gold);
        label("Shipyard", 211, 105, 39, ink, true);
        if (button("Close", 882, 110, 108, 35) or r.isKeyPressed(.escape)) {
            u.closeModal();
            return;
        }
        const tabs = [_][:0]const u8{ "Harbor ferry", "Expedition ships", "Build ships" };
        for (tabs, 0..) |name, index| {
            const tab: ShipyardTab = @fromBackingInt(@intCast(index));
            const x = 211 + a.f(index) * 188;
            if (u.shipyard_tab == tab) {
                a.rect(x, 165, 178, 34, 0xdfdcc8);
                a.rect(x, 197, 178, 2, 0x31564e);
                label(name, x + 11, 173, 17, ink, false);
            } else if (button(name, x, 165, 178, 34)) {
                u.shipyard_tab = tab;
                u.modal_note = null;
            }
        }
        a.rect(211, 208, 779, 1, 0xcac9b4);
        switch (u.shipyard_tab) {
            .ferry => u.shipyardFerry(),
            .expedition => u.shipyardExpedition(),
            .build => u.shipyardBuild(),
        }
        if (u.modal_note) |note| label(note, 211, 574, 17, 0x8b4235, false);
        a.rect(211, 609, 779, 1, 0xcac9b4);
        num("Ferry {d} units", .{s.ferry_hold}, 211, 622, 17, ink);
        num("Brig {d} units", .{s.ocean.Ship.brig.hold()}, 471, 622, 17, ink);
        num("Barque {d} units", .{s.ocean.Ship.barque.hold()}, 731, 622, 17, ink);
        label("Harbors in range", 211, 645, 14, muted, false);
        label("Nearby islands", 471, 645, 14, muted, false);
        label("All expedition destinations", 731, 645, 14, muted, false);
    }

    fn shipyardFerry(u: *UI) void {
        label("Harbor ferry", 211, 225, 27, ink, true);
        num("Up to {d} settlers   /   {d} units for cargo and provisions", .{ s.ferry_capacity, s.ferry_hold }, 211, 268, 18, muted);
        const source = u.g.mooredChart() orelse {
            num("{s} {s}", .{ if (u.g.ferry.surveying) "Ferry surveying" else "Under sail to", s.chart_names[u.g.ferry.destination] }, 211, 333, 24, ink);
            num("{d} settlers aboard   /   {d} units of cargo", .{ u.g.ferry.passengers, u.g.ferry.cargo.units() }, 211, 375, 17, muted);
            if (button("Watch voyage", 798, 341, 192, 39)) {
                u.view = .{};
                u.closeModal();
            }
            return;
        };
        num("Moored at {s}   /   {d} settlers ashore   /   harbors in range", .{ s.chart_names[source], u.g.residents(source) }, 211, 305, 18, ink);
        const near = s.ferry.neighbors(source);
        const rows = @min(near.len, 5);
        for (near.slice()[0..rows], 0..) |target, row| {
            const y = 335 + a.f(row) * 46;
            a.rect(211, y - 4, 779, 1, 0xd9d4c1);
            num("{s}", .{s.chart_names[target]}, 211, y + 4, 20, ink);
            const leg = s.ferry.legSeconds(source, target);
            if (u.g.islandOpen(target)) {
                num("{d:.1} s   /   {d} places   /   {d} free berths", .{
                    leg, u.g.freeLandingSpace(target), s.dock_capacity - @min(s.dock_capacity, u.g.berthsUsed(target)),
                }, 371, y + 7, 15, muted);
                if (button("Sail empty", 676, y, 110, 34)) {
                    if (u.dispatch(.{ .sail_ferry = target }).problem()) |reason| {
                        u.playCue(.denied);
                        u.modal_note = reason;
                        return;
                    }
                    u.view = .{};
                    u.playCue(.sail);
                    u.setMessage("The crew is taking the ferry to {s}.", .{s.chart_names[target]});
                    u.closeModal();
                    return;
                }
                if (button("Load and board", 798, y, 192, 34)) {
                    u.openManifest(.{ .ferry = target });
                    return;
                }
            } else {
                num("{d:.1} s   /   not yet charted", .{leg}, 371, y + 7, 15, muted);
                if (button("Survey   /   20 coins", 798, y, 192, 34)) {
                    if (u.dispatch(.{ .survey_harbor = target }).problem()) |reason| {
                        u.playCue(.denied);
                        u.modal_note = reason;
                        return;
                    }
                    u.view = .{};
                    u.playCue(.sail);
                    u.setMessage("The ferry is sailing to survey {s}.", .{s.chart_names[target]});
                    u.closeModal();
                    return;
                }
            }
        }
    }

    fn watchExpedition(u: *UI, chart: usize) void {
        if (s.ocean.routeTo(chart)) |index| u.view.showExpedition(index) else u.view = .{};
    }

    fn shipyardBuild(u: *UI) void {
        const chart = u.store_chart;
        num("Ship construction at {s}", .{s.chart_names[chart]}, 211, 220, 25, ink);
        num("Dock berths   {d} / {d} occupied or reserved", .{ u.g.berthsUsed(chart), s.dock_capacity }, 211, 256, 18, muted);
        if (!u.g.charterComplete()) {
            label("Complete the Bali landing, lighthouse, and bridge to unlock ship construction.", 211, 300, 18, muted, false);
            return;
        }
        const stock = u.g.stores[chart];
        const full = u.g.berthsUsed(chart) >= s.dock_capacity;
        num("On hand   {d} timber   /   {d} stone   /   {d} coins", .{ stock.timber, stock.stone, u.g.coins }, 211, 284, 16, muted);
        for ([_]s.ocean.Ship{ .brig, .barque }, 0..) |ship, row| {
            const cost = s.shipCost(ship);
            const y = 323 + a.f(row) * 90;
            a.rect(211, y, 779, 1, 0xcac9b4);
            label(ship.name(), 211, y + 9, 23, ink, true);
            num("{d} timber   /   {d} stone   /   {d} coins   /   {d} crew", .{ cost.timber, cost.stone, cost.coins, ship.crew() }, 211, y + 39, 16, muted);
            if (full) {
                label("Dock full", 798, y + 25, 17, muted, false);
            } else if (button(if (ship == .brig) "Build survey brig" else "Build ocean barque", 798, y + 15, 192, 37)) {
                u.modal_note = u.dispatch(.{ .build_ship = .{ .island = chart, .hull = ship } }).problem();
                if (u.modal_note != null) {
                    u.playCue(.denied);
                } else {
                    u.playCue(.build);
                    u.ship_id = u.g.fleet.count - 1;
                    u.shipyard_tab = .expedition;
                }
                return;
            }
        }
    }

    fn shipyardExpedition(u: *UI) void {
        if (u.g.fleet.count == 0) {
            label("No expedition ships", 211, 222, 27, ink, true);
            if (button("Build ships", 822, 231, 168, 37)) {
                u.shipyard_tab = .build;
                u.modal_note = null;
            }
            return;
        }
        if (u.ship_id > 0 and button("Previous ship", 719, 214, 126, 29)) {
            u.ship_id -= 1;
            u.modal_note = null;
        }
        if (u.ship_id + 1 < u.g.fleet.count and button("Next ship", 865, 214, 125, 29)) {
            u.ship_id += 1;
            u.modal_note = null;
        }
        const vessel = u.g.fleet.vessels[u.ship_id];
        const ship = vessel.ship;
        num("{s} #{d}   /   {d} ships", .{ ship.name(), u.ship_id + 1, u.g.fleet.count }, 211, 220, 23, ink);
        const at_java = vessel.phase == .docked and vessel.chart == 0;
        if (vessel.phase == .docked) {
            num("Moored at {s}", .{s.chart_names[vessel.chart]}, 211, 256, 18, muted);
            if (vessel.chart != 0 and button("Return to Java", 822, 249, 168, 34)) {
                u.modal_note = u.dispatch(.{ .return_expedition = u.ship_id }).problem();
                if (u.modal_note == null) {
                    u.watchExpedition(vessel.chart);
                    u.playCue(.sail);
                    u.msg = "The expedition ship is sailing back to Java.";
                    u.closeModal();
                } else u.playCue(.denied);
                return;
            }
            if (button("View port", 683, 249, 120, 34)) {
                u.selectIsland(vessel.chart, true);
                u.closeModal();
                return;
            }
        } else {
            num("{s}   /   {s}", .{ s.chart_names[vessel.chart], if (vessel.phase == .homebound) "Returning to Java" else "Under way" }, 211, 256, 18, muted);
            if (button("Watch voyage", 822, 249, 168, 34)) {
                u.watchExpedition(vessel.chart);
                u.closeModal();
                return;
            }
        }

        const rows_per_page = 4;
        const last_page = (s.ocean.routes.len - 1) / rows_per_page;
        const wheel = if (over(211, 287, 779, 276)) r.getMouseWheelMove() else 0;
        if (wheel > 0) u.shipyard_page -|= 1;
        if (wheel < 0) u.shipyard_page = @min(last_page, u.shipyard_page + 1);
        if (u.shipyard_page > 0 and button("Previous", 732, 570, 92, 29)) u.shipyard_page -= 1;
        if (u.shipyard_page < last_page and button("Next", 917, 570, 73, 29)) u.shipyard_page += 1;
        num("{d} / {d}", .{ u.shipyard_page + 1, last_page + 1 }, 850, 576, 16, ink);
        const first = u.shipyard_page * rows_per_page;
        const first_destinations = [_]usize{ 0, 2, 3, 1 };
        for (first..@min(first + rows_per_page, s.ocean.routes.len), 0..) |entry, row| {
            const index = if (entry < first_destinations.len) first_destinations[entry] else entry;
            const route = s.ocean.routes[index];
            const y = 287 + a.f(row) * 69;
            a.rect(211, y, 779, 1, 0xcac9b4);
            label(route.name(), 211, y + 9, 23, ink, true);
            if (u.g.fleet.charted[index]) {
                num("{d} residents   /   {d} landing places   /   {d} free berths", .{
                    u.g.residents(route.chart), u.g.freeLandingSpace(route.chart), s.dock_capacity - u.g.berthsUsed(route.chart),
                }, 211, y + 36, 16, muted);
                if (at_java and button("Load and board", 822, y + 15, 168, 34)) {
                    if (u.g.berthsUsed(route.chart) >= s.dock_capacity) {
                        u.modal_note = "The destination dock has no free berth.";
                    } else u.openManifest(.{ .expedition = index });
                    return;
                }
                if (button("View island", 683, y + 15, 120, 34)) {
                    u.view.showIsland(route.chart);
                    u.store_chart = route.chart;
                    u.closeModal();
                    return;
                }
            } else {
                if (ship.canSail(route)) {
                    const rations = u.g.oceanRations(u.ship_id, index, 0);
                    num("Survey provisions   {d} / {d} hold units", .{ rations.units(), ship.hold() }, 211, y + 36, 16, muted);
                } else {
                    num("Requires the {s}   /   {d} units of provisions", .{
                        route.ship.name(), s.expeditionRations(route) * 4,
                    }, 211, y + 36, 16, muted);
                }
                if (at_java and ship.canSail(route) and button("Launch survey", 822, y + 15, 168, 34)) {
                    if (u.dispatch(.{ .survey_island = .{ .ship = u.ship_id, .route = index } }).problem()) |failure| {
                        u.playCue(.denied);
                        u.modal_note = failure;
                    } else {
                        u.view.showExpedition(index);
                        u.playCue(.sail);
                        u.setMessage("The survey has set sail for {s}.", .{route.name()});
                        u.closeModal();
                    }
                    return;
                }
            }
        }
    }

    fn select(u: *UI, tool: s.Kind) void {
        if (tool != u.tool) u.playCue(.select);
        u.tool = tool;
        u.msg = switch (tool) {
            .road => "Lay roads for 1 stone per tile. Connect them to the harbor for foot traffic.",
            .quarry => "Place a quarry on a rocky outcrop to produce stone.",
            .well => "Place a well on open ground inland for 4 fresh water per day.",
            .lodge => "Place a hunting lodge where deer graze to bring in venison.",
            .grove => "Choose a pine forest tile for the woodlot.",
            .cottage => "Choose a land tile to house four settlers.",
            .farm => "Choose open ground for a grain farm.",
            .light => "Bali needs 8 settlers, 24 timber and 30 coins.",
            else => "Click a tile to inspect it.",
        };
    }

    fn selectIsland(u: *UI, chart: usize, focus: bool) void {
        if (u.trace) |trace| trace.note("presentation", "select_island", .{ .island = chart, .focused = focus });
        u.store_chart = chart;
        if (focus) u.view.showIsland(chart);
    }

    fn handleIslandMenu(u: *UI, options: []const usize) bool {
        const selected = std.mem.indexOfScalar(usize, options, u.store_chart) orelse 0;
        u.store_chart = options[selected];
        const field_hit = r.checkCollisionPointRec(mouse, island_field);
        if (r.isKeyPressed(.tab)) {
            u.selectIsland(options[(selected + 1) % options.len], false);
            u.island_menu_open = false;
            return true;
        }
        const max_offset = options.len -| island_menu_rows;
        if (!u.island_menu_open) {
            if (!pressed or !field_hit) return false;
            u.island_menu_open = true;
            u.island_cursor = selected;
            u.island_offset = @min(selected, max_offset);
            u.view.drag_start = null;
            pressed = false;
            return true;
        }
        const top = island_field.y + island_field.height + 2;
        const height = a.f(@min(island_menu_rows, options.len)) * island_row_height;
        const in_menu = over(island_field.x, top, island_field.width, height);
        u.island_offset = @min(u.island_offset, max_offset);
        u.island_cursor = @min(u.island_cursor, options.len - 1);
        const up = r.isKeyPressed(.up) or r.isKeyPressedRepeat(.up);
        const down = r.isKeyPressed(.down) or r.isKeyPressedRepeat(.down);
        if (up or down) {
            u.island_cursor = if (up) u.island_cursor -| 1 else @min(u.island_cursor + 1, options.len - 1);
            u.island_offset = std.math.clamp(u.island_offset, u.island_cursor -| (island_menu_rows - 1), u.island_cursor);
        }
        if (in_menu) {
            const wheel = r.getMouseWheelMove();
            if (wheel > 0) u.island_offset -|= 1;
            if (wheel < 0) u.island_offset = @min(u.island_offset + 1, max_offset);
        }
        if (pressed) {
            if (in_menu) {
                const row: usize = @intFromFloat((mouse.y - top) / island_row_height);
                u.selectIsland(options[u.island_offset + row], false);
            }
            // A click that dismisses the list must not reach the chart or the ledger.
            pressed = false;
            u.island_menu_open = false;
        } else if (r.isKeyPressed(.enter)) {
            u.selectIsland(options[u.island_cursor], false);
            u.island_menu_open = false;
        } else if (r.isKeyPressed(.escape)) {
            u.island_menu_open = false;
        }
        return true;
    }

    fn drawIslandMenu(u: *const UI, options: []const usize) void {
        const x = island_field.x;
        const y = island_field.y + island_field.height + 2;
        const visible = options[u.island_offset..][0..@min(island_menu_rows, options.len - u.island_offset)];
        const height = a.f(visible.len) * island_row_height;
        a.rect(x - 1, y - 1, island_field.width + 2, height + 2, 0x31564e);
        for (visible, 0..) |chart, row| {
            const at = y + a.f(row) * island_row_height;
            const hot = over(x, at, island_field.width, island_row_height);
            const highlighted = row + u.island_offset == u.island_cursor;
            const selected = chart == u.store_chart;
            a.rect(x, at, island_field.width, island_row_height, if (hot or highlighted) 0xd4dfc8 else paper);
            if (selected) a.rect(x, at, 3, island_row_height, gold);
            label(s.chart_names[chart], x + 11, at + 5, 17, ink, false);
        }
        if (options.len > visible.len) {
            const thumb = height * a.f(visible.len) / a.f(options.len);
            const scroll = height * a.f(u.island_offset) / a.f(options.len);
            a.rect(x + island_field.width - 4, y + scroll, 3, thumb, muted);
        }
    }

    fn drawHeader(u: *UI, ledger: *const queries.Ledger) void {
        a.rect(0, 0, 1200, 84, ink);
        compass(40, 42, 23);
        label(game_title, 75, 17, 38, paper, true);

        a.rect(237, 6, 452, 72, 0x2d4b49);
        label("ISLAND STORES", 250, 15, 11, 0xc4d4bf, false);
        const field = island_field;
        const hot = r.checkCollisionPointRec(mouse, field);
        a.rect(field.x, field.y, field.width, field.height, if (hot or u.island_menu_open) 0xd4dfc8 else paper);
        label(s.chart_names[ledger.chart], field.x + 10, field.y + 3, 17, ink, false);
        const cx = field.x + field.width - 15;
        const cy = field.y + field.height / 2;
        const slope: f32 = if (u.island_menu_open) -2.5 else 2.5;
        a.line(a.v(cx - 4, cy - slope), a.v(cx, cy + slope), 1.5, ink);
        a.line(a.v(cx, cy + slope), a.v(cx + 4, cy - slope), 1.5, ink);

        const resources = [_][:0]const u8{ "TIMBER", "STONE", "GRAIN", "VENISON", "FRUIT", "WATER" };
        const local = ledger.stock;
        const demand = ledger.daily_demand;
        inline for (resources, s.store_fields, 0..) |name, resource, i| {
            const x = 250 + a.f(i) * 73;
            if (i > 0) a.rect(x - 11, 39, 1, 33, 0x49645e);
            const value = @field(local, resource);
            const warning = u.stock_alerts.islands[u.store_chart][i];
            const color: u32 = if (warning.active) warningColor(warning.pulse_elapsed) else if (i >= 2 and value < demand) gold else paper;
            counter(name, value, x, color);
        }

        label("CHARTER TOTALS", 713, 15, 11, 0xc4d4bf, false);
        counter("COINS", u.g.coins, 713, paper);
        counter("SETTLERS", u.g.people, 807, paper);
        a.rect(894, 14, 1, 56, 0x49645e);
        num("Day {d}", .{u.g.day}, 916, 28, 22, paper);
        if (button(if (u.speed == 0) "Paused" else if (u.speed == 1) "1x  Play" else "3x  Play", 1059, 23, 108, 38)) {
            u.speed = if (u.speed == 0) 1 else if (u.speed == 1) 3 else 0;
            if (u.trace) |trace| trace.note("presentation", "speed", .{ .speed = u.speed });
        }
    }

    fn announceArrival(u: *UI, arrival: gameplay.Arrival) void {
        switch (arrival) {
            .ferry => |event| {
                const port = s.chart_names[event.island];
                if (event.survey) {
                    u.playCue(.foghorn);
                    u.setMessage("The ferry opened the dock at {s}. Use Shipyard to send it on.", .{port});
                } else if (event.unlocked_shipyard) {
                    u.playCue(.beacon);
                    u.setMessage("Settlers landed at {s}. Ship construction is unlocked.", .{port});
                } else if (event.settlers > 0) {
                    if (u.g.housing(event.island) == 0 and event.island != 0)
                        u.setMessage("Settlers landed at the {s} camp. Build a cottage for permanent housing.", .{port})
                    else
                        u.setMessage("Ferry passengers settled in {s}.", .{port});
                } else if (!event.cargo.empty()) {
                    u.setMessage("The ferry unloaded supplies at {s}.", .{port});
                } else u.setMessage("The crew brought the ferry to {s}.", .{port});
            },
            .expedition => |event| switch (event.event) {
                .charted => {
                    u.playCue(.foghorn);
                    u.setMessage("{s} is charted. Expedition ship #{d} is moored there.", .{ s.chart_names[event.island], event.ship + 1 });
                },
                .delivered => {
                    u.playCue(.foghorn);
                    if (event.settlers > 0) u.store_chart = event.island;
                    u.setMessage("{s} landed on {s}. Expedition ship #{d} is moored there.", .{
                        if (event.settlers > 0) "Settlers" else "Supplies", s.chart_names[event.island], event.ship + 1,
                    });
                },
                .returned => u.setMessage("Expedition ship #{d} is back at Java.", .{event.ship + 1}),
                .none => {},
            },
        }
    }

    fn frame(u: *UI, dt: f32, offset: a.V, scale: f32) void {
        if (u.g.isOver()) return u.restartDialog();
        switch (u.modal) {
            .restart => return u.restartDialog(),
            .bridge => return u.bridgeDialog(),
            .manifest => return u.manifestDialog(),
            .shipyard => return u.shipyardDialog(),
            .none => {},
        }
        const game_seconds = dt * a.f(u.speed);
        u.elapsed += game_seconds;
        // The core owns the calendar. The shell only feeds it game time, in
        // steps of at most one day so a long frame cannot skip upkeep.
        var remaining = game_seconds;
        while (remaining > 0) {
            const step = @min(remaining, s.day_seconds);
            remaining -= step;
            const outcome = u.dispatch(.{ .advance = step });
            if (outcome != .advanced) break;
            for (outcome.advanced.arrivals.slice()) |arrival| u.announceArrival(arrival);
            const day = outcome.advanced.day orelse continue;
            const shortages = day.shortages;
            if (u.g.isOver()) {
                pressed = false;
                return u.restartDialog();
            }
            for (shortages, 0..) |shortage, chart| {
                switch (shortage) {
                    .scurvy => u.setMessage("Scurvy claimed a settler on {s}. Supply fruit.", .{s.chart_names[chart]}),
                    .water => u.setMessage("{s} lost a settler to water shortage.", .{s.chart_names[chart]}),
                    else => continue,
                }
                break;
            } else if (shortages[u.store_chart] == .diet) {
                const diet = u.g.diets[u.store_chart];
                if (diet.missed_grain) {
                    u.msg = "Grain ran short. Settlers are too lethargic to work.";
                } else if (diet.meat_deficit > 0) {
                    u.msg = "Venison ran short. Settlers need meat to regain their strength.";
                } else if (diet.days_without_fruit > 0) {
                    u.msg = "Fruit ran short. Reach more fruit trees or ship in fruit.";
                }
            }
        }
        if (r.isKeyPressed(.space)) u.speed = if (u.speed == 0) 1 else 0;
        for (keys, opts) |key, opt| if (r.isKeyPressed(key)) {
            u.select(opt);
        };
        if (r.isMouseButtonPressed(.right)) u.select(.empty);
        if (r.isKeyPressed(.f5)) {
            if (u.saveNow(true)) {
                u.msg = "Harbor ledger saved.";
            } else |_| {
                u.msg = "Could not write the harbor ledger.";
            }
        }
        if (r.isKeyPressed(.f9)) {
            _ = u.load(false);
            if (u.g.isOver()) {
                pressed = false;
                return u.restartDialog();
            }
        }
        var available: [s.settlement_count]usize = undefined;
        var available_count: usize = 0;
        for (0..s.settlement_count) |chart| {
            if (!u.g.islandOpen(chart)) continue;
            available[available_count] = chart;
            available_count += 1;
        }
        const options = available[0..available_count];
        const menu_handled = u.handleIslandMenu(options);
        const inset_available = u.view.zoom > chart_view.regional_zoom;
        const over_inset = inset_available and r.checkCollisionPointRec(mouse, if (u.inset_collapsed) inset_show else inset_panel);
        const over_inset_toggle = inset_available and r.checkCollisionPointRec(mouse, if (u.inset_collapsed) inset_show else inset_hide);
        if (pressed and !menu_handled and over_inset_toggle) u.inset_collapsed = !u.inset_collapsed;
        const inset_hit = if (over_inset and !menu_handled and !u.inset_collapsed and !over_inset_toggle) inset.pick(mouse, &u.g) else null;
        if (inset_hit) |chart| {
            if (pressed) u.selectIsland(chart, true);
        }
        const region_button_x: f32 = if (u.g.bridge) 158 else 23;
        const inside = !menu_handled and !over_inset and over(0, 84, 895, 492) and !over(region_button_x, 101, 127, 32) and
            !(u.g.bridge and over(23, 101, 123, 32));
        const click = !menu_handled and u.view.input(mouse, inside, dt);
        const choosing_region = u.view.zoom < chart_view.settlement_detail_zoom;
        const regional_hit = if (inside and choosing_region) chart_view.pickIsland(u.view.world(mouse), u.view.zoom, &u.g) else null;
        if (click) {
            if (regional_hit) |chart| u.selectIsland(chart, true);
        }
        const regional = u.view.zoom <= chart_view.regional_zoom;
        const hover = if (inside and !choosing_region) u.view.pick(mouse, &u.g) else null;
        if (hover) |hit| if (click) {
            const p = hit.cell;
            const chart = hit.chart;
            if (u.tool != .empty) {
                const failure = u.dispatch(.{ .build = .{ .island = chart, .cell = p, .kind = u.tool } }).problem();
                u.playCue(if (failure != null) .denied else if (u.tool == .light) .beacon else .build);
                u.msg = failure orelse if (u.tool == .light) if (u.g.charterComplete()) "The beacon is lit. Ship construction is unlocked." else "The beacon is lit on Bali." else "Construction complete.";
                if (failure == null and u.tool == .well and u.g.countOn(chart, .well) > s.waterCapacity(chart) / s.well_yield) {
                    u.msg = "Well built. The island already has enough wells to reach its daily water limit.";
                }
            } else if (s.depth(p, chart) >= 0) {
                const k = u.g.tileAt(chart, p);
                if (u.g.harvestStatus(chart, p)) |harvest| {
                    const name = s.names[@backingInt(k)];
                    const resource = if (k == .grove) "timber" else "venison";
                    if (harvest.days_to_recover > 0) {
                        u.setMessage("{s} is recovering. {d}/{d} {s} has replenished. Harvest resumes in {d}d.", .{ name, harvest.stock, s.harvest_capacity, resource, harvest.days_to_recover });
                    } else {
                        u.setMessage("{s} has {d}/{d} {s} available to harvest.", .{ name, harvest.stock, s.harvest_capacity, resource });
                    }
                } else u.msg = if (k != .empty) s.names[@backingInt(k)] else switch (s.site(p, chart)) {
                    .outcrop => "Rocky outcrop - suitable for a quarry.",
                    .deer => "Deer herd - suitable for a hunting lodge.",
                    .fruit => if (roads.Walk.fromPort(u.g.tilesOn(chart), chart).contains(p))
                        "Workers can reach this fruit tree from the harbor."
                    else
                        "Fruit tree. Link a nearby tree or building to the harbor to gather fruit.",
                    .plain => if (s.forest(p, chart)) "Pine forest - suitable for a woodlot." else s.names[0],
                };
            }
        };
        const ledger = queries.ledger(&u.g, u.store_chart);
        const goals = ledger.goals;
        var preview_bridge = false;
        for (goals, 0..) |goal, i| {
            if (goal == .bridge) preview_bridge = over(1100, 226 + a.f(i) * 32, 78, 27);
        }
        r.beginScissorMode(@intFromFloat(offset.x), @intFromFloat(offset.y + 84 * scale), @intFromFloat(@ceil(895 * scale)), @intFromFloat(@ceil(492 * scale)));
        u.view.draw(&u.g, hover, u.elapsed, u.tool, preview_bridge);
        for (region.islands) |isle| {
            if (isle.label_size == .minor and u.view.zoom < 0.44) continue;
            const at = u.view.project(a.chartPoint(isle.label));
            if (at.x < 0 or at.x > 895 or at.y < 84 or at.y > 576) continue;
            const size: f32 = if (isle.label_size == .major) 20 else 16;
            const width = r.measureTextEx(serif, isle.name, size, 0).x;
            label(isle.name, at.x - width / 2, at.y - size / 2, size, 0x183732, true);
        }
        if (u.view.zoom < chart_view.settlement_detail_zoom) {
            for (0..s.settlement_count) |chart| {
                if (!u.g.islandOpen(chart)) continue;
                const port = u.view.project(chart_view.portPosition(chart));
                chart_view.drawPortPin(port, chart == u.store_chart, chart == regional_hit);
            }
        }
        r.endScissorMode();
        if (!regional) {
            if (u.inset_collapsed) {
                _ = button("Show island map", inset_show.x, inset_show.y, inset_show.width, inset_show.height);
            } else {
                a.rect(inset_panel.x, inset_panel.y, inset_panel.width, inset_panel.height, ink);
                label("Island map", 675, 392, 14, paper, false);
                const inset_name = s.chart_names[inset_hit orelse u.store_chart];
                const inset_name_width = r.measureTextEx(sans, inset_name, 14, 0.45).x;
                label(inset_name, inset_hide.x - 9 - inset_name_width, 392, 14, gold, false);
                _ = button("Hide", inset_hide.x, inset_hide.y, inset_hide.width, inset_hide.height);
                inset.draw(u.view, &u.g, u.store_chart, inset_hit);
            }
        }
        u.stock_alerts.observe(&u.g, u.elapsed, dt);
        u.drawHeader(&ledger);
        const supply = ledger.production;
        const demand = ledger.daily_demand;
        if (u.g.bridge and button("Cross bridge", 23, 101, 123, 32)) {
            u.modal = .bridge;
            u.modal_note = null;
        }
        if (button(if (regional) "Local map" else "Regional map", region_button_x, 101, 127, 32)) {
            if (regional) u.view = .{} else u.view.showRegion();
        }
        compass(842, 146, 23);
        label("N", 837, 106, 14, paper, false);
        a.rect(0, 576, 897, 42, 0x40787a);
        label(u.msg, 26, 588, 17, 0xfff3d9, false);
        a.rect(895, 84, 305, 534, paper);
        label("HARBOR LEDGER", 916, 108, 14, muted, false);
        if (button("Shipyard", 1080, 101, 98, 30)) {
            u.modal = .shipyard;
            u.modal_note = null;
        }
        label(if (goals[0] == null) "Charter complete" else "The island charter", 915, 131, 31, ink, true);
        if (goals[0] != null) label(if (u.g.charterComplete()) "Explore and settle farther shores." else "Settle and link the islands.", 916, 180, 17, ink, false);
        const diet = ledger.diet;
        const strength = ledger.workforce * 100 / s.weakness_limit;
        num("{s} {d}%   Meat deficit {d}d   Fruit deficit {d}d", .{
            if (diet.missed_grain) "Lethargic" else "Work", strength, diet.meat_deficit, diet.days_without_fruit,
        }, 916, 200, 13, muted);
        a.rect(916, 218, 261, 1, 0xc5c6ae);
        for (goals, 0..) |entry, i| {
            const goal = entry orelse break;
            const y = 231 + a.f(i) * 32;
            r.drawCircleLinesV(a.v(924, y + 8), 5, a.c(muted));
            label(goal.title(), 943, y, 16, ink, false);
            if (goal == .build_fleet) num("{d}/{d}", .{ u.g.fleet.count, s.charter_fleet_size }, 1142, y, 15, muted);
            if (goal == .bridge and button("Plan", 1100, y - 5, 78, 27)) {
                u.modal = .bridge;
                u.modal_note = null;
            }
        }
        a.rect(916, 338, 261, 1, 0xc5c6ae);
        label(s.chart_names[u.store_chart], 915, 353, 27, ink, true);
        if (u.g.islandOpen(u.store_chart) and button("View port", 1091, 349, 87, 35)) u.view.showIsland(u.store_chart);
        var export_text: [64]u8 = undefined;
        const export_caption = std.fmt.bufPrintSentinel(&export_text, "Export {s} grain", .{s.chart_names[u.store_chart]}, 0) catch unreachable;
        if (button(export_caption, 916, 393, 262, 35)) {
            const sold = u.dispatch(.{ .export_grain = u.store_chart }).problem() == null;
            u.playCue(if (sold) .trade else .denied);
            u.msg = if (sold) "Cargo sold for 10 coins." else "The merchant needs 6 grain from the selected island.";
        }
        label("6 for 10 coins", 1084, 403, 13, 0xc4d4bf, false);
        var ferry_text: [64]u8 = undefined;
        const ferry_status = if (u.g.mooredChart()) |port|
            std.fmt.bufPrintSentinel(&ferry_text, "Ferry moored at {s}", .{s.chart_names[port]}, 0) catch unreachable
        else
            std.fmt.bufPrintSentinel(&ferry_text, "Ferry {s} {s}", .{ if (u.g.ferry.surveying) "surveying" else "under sail to", s.chart_names[u.g.ferry.destination] }, 0) catch unreachable;
        label(ferry_status, 916, 451, 16, muted, false);
        num("Dock berths   {d} / {d} occupied or reserved", .{ ledger.berths_used, s.dock_capacity }, 916, 476, 16, muted);
        const camp = u.store_chart != 0 and u.g.islandOpen(u.store_chart) and ledger.housing == 0;
        num("{s}   {d} / {d}", .{ if (camp) "Camp" else "Housing", ledger.residents, ledger.landing_capacity }, 916, 535, 17, ink);
        num("Food  +{d} grain   +{d} meat   +{d} fruit", .{ supply.grain, supply.venison, supply.fruit }, 916, 578, 15, muted);
        num("Water +{d}/{d} max   /   {d} of each used", .{ supply.water, ledger.water_limit, demand }, 916, 598, 15, muted);
        a.rect(0, 618, 1200, 142, 0xe5dfce);
        label("Construction", 23, 632, 26, ink, true);
        label("1-8   Select     Right-click   Deselect", 226, 639, 15, muted, false);
        label("Scroll   Zoom     Drag   Pan     Home   Fit", 524, 639, 15, muted, false);
        label("Space   Pause      F5   Save      F9   Load", 802, 640, 15, muted, false);
        if (button("Restart", 1076, 629, 102, 35)) u.modal = .restart;
        for (opts, 0..) |k, i| {
            const x = 23 + a.f(i) * 145;
            const hot = over(x, 677, 137, 69);
            const active = u.tool == k;
            a.rect(x, 677, 137, 68, if (active) ink else if (hot) 0xfff7e1 else paper);
            a.building(k, x + 22, 721, 0.64);
            label(s.names[@backingInt(k)], x + 42, 684, 18, if (active) paper else ink, true);
            if (k == .well) {
                num("{d} wood, {d} stone", .{ s.costs[@backingInt(k)], s.well_stone }, x + 42, 705, 13, if (active) gold else muted);
            } else {
                num("{d} {s}", .{ s.costs[@backingInt(k)], if (k == .road) "stone" else "timber" }, x + 42, 705, 14, if (active) gold else muted);
            }
            label(desc[i], x + 42, 723, 14, if (active) paper else muted, false);
            if (hot and pressed) u.select(if (active) .empty else k);
        }
        if (u.island_menu_open) u.drawIslandMenu(options);
    }
};
pub fn main(process: std.process.Init) !void {
    const env = process.environ_map;
    const capture = env.get("ARCHIPELAGIST_CAPTURE");
    var store = try save_store.Store.init(process);
    const trace_override = env.get("ARCHIPELAGIST_TRACE_DIR");
    var trace_storage: ?diagnostics.Trace = null;
    var journal_storage: ?journal_file.Recorder = null;
    if (capture == null or trace_override != null) {
        // In the browser, traces stay in memory and print to the console, so
        // they don't fill the IndexedDB storage that holds the save.
        const directory = trace_override orelse if (browser.enabled) "/tmp/archipelagist/diagnostics" else try std.fs.path.join(process.arena.allocator(), &.{
            std.fs.path.dirname(store.path) orelse ".", "diagnostics",
        });
        trace_storage = diagnostics.Trace.open(process.io, store.dir, directory) catch |err| trace: {
            std.log.warn("Could not open diagnostics: {s}", .{@errorName(err)});
            break :trace null;
        };
        // Only the process holding the trace lock writes the journal beside it.
        if (trace_storage != null) journal_storage = journal_file.Recorder.open(process.io, store.dir, directory) catch |err| journal: {
            std.log.warn("Could not open the command journal: {s}", .{@errorName(err)});
            break :journal null;
        };
    }
    const trace = if (trace_storage) |*active| active else null;
    const journal = if (journal_storage) |*active| active else null;
    if (trace) |active| {
        active.attachPanic();
        active.note("process", "start", .{ .schema = 1, .capture = capture != null, .platform = @import("builtin").os.tag, .arch = @import("builtin").cpu.arch, .journal = journal != null });
    }
    defer if (trace) |active| active.deinit();
    defer if (journal) |active| active.deinit();
    store.trace = trace;
    run(process, store, trace, journal, capture) catch |err| {
        if (trace) |active| active.note("process", "failed", .{ .reason = @errorName(err) });
        return err;
    };
}

fn run(process: std.process.Init, store: save_store.Store, trace: ?*diagnostics.Trace, journal: ?*journal_file.Recorder, capture: ?[]const u8) !void {
    var window = try window_settings.Settings.init(process.arena.allocator(), store, capture == null);
    const window_span = if (trace) |active| active.begin("window", "open", .{}) else null;
    window.open(game_title ++ " | Island settlements");
    const window_ready = r.isWindowReady();
    if (window_span) |span| trace.?.finish("window", "open", span, if (window_ready) "ok" else "error", .{});
    if (!window_ready) return error.WindowInitializationFailed;
    defer r.closeWindow();
    r.setTargetFPS(60);
    r.setExitKey(.null);
    sans = try r.loadFontFromMemory(".ttf", @embedFile("fonts/AtkinsonHyperlegible-Regular.ttf"), 48, null);
    defer r.unloadFont(sans);
    serif = try r.loadFontFromMemory(".ttf", @embedFile("fonts/DMSerifDisplay-Regular.ttf"), 64, null);
    defer r.unloadFont(serif);
    r.setTextureFilter(sans.texture, .bilinear);
    r.setTextureFilter(serif.texture, .bilinear);
    if (trace) |active| active.note("presentation", "assets_ready", .{ .fonts = 2 });
    var u = UI{ .effects = .init(), .store = store, .trace = trace, .journal = journal };
    u.stock_alerts = .init(u.g.stores);
    u.view.showIsland(0);
    defer u.effects.deinit();
    if (trace) |active| {
        var available: usize = 0;
        for (u.effects.sounds) |sound| available += @intFromBool(sound != null);
        active.note("audio", "ready", .{ .device = r.isAudioDeviceReady(), .available_cues = available, .expected_cues = u.effects.sounds.len });
    }
    if (capture == null) {
        const launch = u.load(true);
        if (trace) |active| active.note("session", "launch", .{ .status = launch, .day = u.g.day, .home_quarry_sites = s.quarrySites(0).len });
        if (!u.preserve_unreadable_save) u.saveNow(false) catch {
            u.msg = "Could not write the harbor ledger.";
        };
        if (launch == .missing) u.playCue(.anchor_drop);
    }
    var frames: usize = 0;
    var last_heartbeat = if (trace != null) std.Io.Clock.awake.now(process.io) else null;
    while (!u.quit_requested and !r.windowShouldClose()) {
        if (r.isKeyPressed(.escape) and (u.g.isOver() or (u.modal == .none and !u.island_menu_open))) break;
        const dt = @min(r.getFrameTime(), 0.25);
        const w = a.f(r.getScreenWidth());
        const h = a.f(r.getScreenHeight());
        const scale = @min(w / 1200, h / 760);
        const offset = a.v((w - 1200 * scale) / 2, (h - 760 * scale) / 2);
        const m = r.getMousePosition();
        mouse = a.v((m.x - offset.x) / scale, (m.y - offset.y) / scale);
        pressed = r.isMouseButtonPressed(.left);
        const was_over = u.g.isOver();
        const frame_started = if (trace != null) std.Io.Clock.awake.now(process.io) else null;
        r.beginDrawing();
        r.clearBackground(a.c(ink));
        r.beginMode2D(.{ .target = a.v(0, 0), .offset = offset, .rotation = 0, .zoom = scale });
        u.frame(dt, offset, scale);
        r.endMode2D();
        r.endDrawing();
        frames += 1;
        if (trace) |active| {
            const now = std.Io.Clock.awake.now(process.io);
            const elapsed = frame_started.?.durationTo(now).toMilliseconds();
            if (elapsed >= 100 or last_heartbeat.?.durationTo(now).toSeconds() >= 5) {
                active.note("presentation", if (elapsed >= 100) "slow_frame" else "heartbeat", .{
                    .frame = frames,
                    .frame_ms = elapsed,
                    .day = u.g.day,
                    .island = u.store_chart,
                    .population = u.g.people,
                    .modal = u.modal,
                    .speed = u.speed,
                    .zoom = u.view.zoom,
                });
                last_heartbeat = now;
            }
        }
        if (capture == null) {
            window.observe();
            u.autosave_time += dt;
            if (u.autosave_time >= 3 or (!was_over and u.g.isOver())) {
                u.autosave_time = 0;
                if (!u.preserve_unreadable_save) u.saveNow(false) catch {
                    u.msg = "Could not autosave the harbor ledger.";
                };
                window.save(store) catch |err| {
                    std.log.warn("Could not save window placement: {s}", .{@errorName(err)});
                };
            }
        }
        if (frames == 4) if (capture) |path| {
            var name: [std.fs.max_path_bytes]u8 = undefined;
            r.takeScreenshot(try std.fmt.bufPrintSentinel(&name, "{s}", .{path}, 0));
            break;
        };
    }
    if (capture == null) {
        window.observe();
        window.save(store) catch |err| {
            std.log.warn("Could not save window placement on exit: {s}", .{@errorName(err)});
        };
        if (!u.preserve_unreadable_save) u.saveNow(false) catch |err| {
            std.log.warn("Could not save the harbor ledger on exit: {s}", .{@errorName(err)});
        };
    }
    if (trace) |active| active.note("process", "shutdown", .{ .frames = frames, .day = u.g.day });
}
