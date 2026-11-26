const std = @import("std");
const r = @import("raylib");
const s = @import("core").colony;

const fallback_files = [_][]const u8{
    @embedFile("fonts/unifont-18.0.01.otf.deflate"),
    @embedFile("fonts/unifont_upper-18.0.01.otf.deflate"),
};

/// Only the active town name needs a glyph atlas. Keep the underlying font
/// data so switching islands or editing the name doesn't decompress it again.
pub const Renderer = struct {
    previous: [s.town_name_bytes]u8 = undefined,
    previous_len: usize = 0,
    fonts: [fallback_files.len]?r.Font = @splat(null),
    data: [fallback_files.len]?[]u8 = @splat(null),

    pub fn deinit(renderer: *Renderer) void {
        for (renderer.fonts, renderer.data) |font, blob| {
            if (font) |loaded| r.unloadFont(loaded);
            if (blob) |bytes| r.memFree(bytes.ptr);
        }
    }

    fn prepare(renderer: *Renderer, base: r.Font, name: [:0]const u8) void {
        if (std.mem.eql(u8, renderer.previous[0..renderer.previous_len], name)) return;
        renderer.previous_len = name.len;
        @memcpy(renderer.previous[0..name.len], name);

        var points: [fallback_files.len][s.town_name_limit + 1]i32 = undefined;
        var lengths: [fallback_files.len]usize = .{ 1, 1 };
        var needed: [fallback_files.len]bool = @splat(false);
        points[0][0] = '?';
        points[1][0] = 0x1f30a;
        var iter = std.unicode.Utf8View.initUnchecked(name).iterator();
        while (iter.nextCodepoint()) |point| {
            if (r.getGlyphInfo(base, point).value == point) continue;
            const plane: usize = @intFromBool(point >= 0x10000);
            needed[plane] = true;
            if (std.mem.findScalar(i32, points[plane][0..lengths[plane]], point) != null) continue;
            points[plane][lengths[plane]] = point;
            lengths[plane] += 1;
        }
        for (&renderer.fonts, &renderer.data, fallback_files, &points, lengths, needed) |*font, *data, compressed, *codepoints, len, use| {
            if (font.*) |loaded| r.unloadFont(loaded);
            font.* = null;
            if (!use) continue;
            const blob = data.* orelse b: {
                const bytes = r.decompressData(compressed, @intCast(compressed.len)) catch continue;
                data.* = bytes;
                break :b bytes;
            };
            font.* = r.loadFontFromMemory(".otf", blob, 32, codepoints[0..len]) catch null;
            if (font.*) |loaded| r.setTextureFilter(loaded.texture, .bilinear);
        }
    }

    fn fontFor(renderer: *const Renderer, base: r.Font, point: i32) r.Font {
        if (r.getGlyphInfo(base, point).value == point) return base;
        for (renderer.fonts) |font| {
            if (font) |loaded| {
                if (r.getGlyphInfo(loaded, point).value == point) return loaded;
            }
        }
        return base;
    }

    fn advance(font: r.Font, point: i32, size: f32) f32 {
        const glyph = r.getGlyphInfo(font, point);
        const advance_px: f32 = if (glyph.advanceX != 0) @floatFromInt(glyph.advanceX) else r.getGlyphAtlasRec(font, point).width;
        return advance_px * size / @as(f32, @floatFromInt(font.baseSize));
    }

    /// Draw a single-line name fitted to its field and return the caret position.
    pub fn draw(
        renderer: *Renderer,
        base: r.Font,
        name: [:0]const u8,
        position: r.Vector2,
        size: f32,
        max_width: f32,
        tint: r.Color,
        caret: usize,
    ) f32 {
        renderer.prepare(base, name);
        var width: f32 = 0;
        var iter = std.unicode.Utf8View.initUnchecked(name).iterator();
        while (iter.nextCodepoint()) |point| width += advance(renderer.fontFor(base, point), point, size);
        const fitted = if (width > max_width) size * max_width / width else size;
        var caret_x = position.x;
        var x = position.x;
        iter = std.unicode.Utf8View.initUnchecked(name).iterator();
        while (iter.nextCodepoint()) |point| {
            const font = renderer.fontFor(base, point);
            if (point != ' ') r.drawTextCodepoint(font, point, .{ .x = x, .y = position.y + (size - fitted) / 2 }, fitted, tint);
            x += advance(font, point, fitted);
            if (iter.i <= caret) caret_x = x;
        }
        return caret_x;
    }
};

pub const Editor = struct {
    draft: s.TownName = .{},
    caret: usize = 0,
    select_all: bool = false,

    pub fn init(name: s.TownName) Editor {
        return .{ .draft = name, .caret = name.len, .select_all = name.len != 0 };
    }

    pub fn count(editor: *const Editor) usize {
        return std.unicode.utf8CountCodepoints(editor.draft.text()) catch unreachable;
    }

    fn previous(editor: *const Editor) usize {
        var index = editor.caret;
        if (index == 0) return index;
        index -= 1;
        while (editor.draft.utf8[index] & 0xc0 == 0x80) index -= 1;
        return index;
    }

    fn next(editor: *const Editor) usize {
        if (editor.caret == editor.draft.len) return editor.caret;
        return editor.caret + (std.unicode.utf8ByteSequenceLength(editor.draft.utf8[editor.caret]) catch unreachable);
    }

    fn remove(editor: *Editor, first: usize, end: usize) void {
        const len = editor.draft.len;
        std.mem.copyForwards(u8, editor.draft.utf8[first..], editor.draft.utf8[end..len]);
        editor.draft.len -= @intCast(end - first);
        @memset(editor.draft.utf8[editor.draft.len..len], 0);
        editor.caret = first;
        editor.select_all = false;
    }

    fn insert(editor: *Editor, point: u21) void {
        if (!s.TownName.isSingleLine(point)) return;
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(point, &encoded) catch return;
        if (editor.select_all) editor.remove(0, editor.draft.len);
        if (editor.count() == s.town_name_limit) return;
        const end = editor.draft.len;
        const start = editor.caret;
        std.mem.copyBackwards(u8, editor.draft.utf8[start + len ..], editor.draft.utf8[start..end]);
        @memcpy(editor.draft.utf8[start..][0..len], encoded[0..len]);
        editor.draft.len += len;
        editor.caret += len;
    }

    pub fn replaceText(editor: *Editor, text: []const u8) void {
        if (std.mem.eql(u8, editor.draft.text(), text)) return;
        const view = std.unicode.Utf8View.init(text) catch return;
        editor.* = .{};
        var iter = view.iterator();
        while (iter.nextCodepoint()) |point| editor.insert(point);
    }

    fn pressed(key: r.KeyboardKey) bool {
        return r.isKeyPressed(key) or r.isKeyPressedRepeat(key);
    }

    pub fn keyboard(editor: *Editor) void {
        const shortcut = r.isKeyDown(.left_control) or r.isKeyDown(.right_control) or
            r.isKeyDown(.left_super) or r.isKeyDown(.right_super);
        if (shortcut and r.isKeyPressed(.a)) {
            editor.select_all = editor.draft.len != 0;
        } else if (shortcut and r.isKeyPressed(.v)) {
            const clipboard = r.cdef.GetClipboardText();
            if (clipboard != null) {
                if (std.unicode.Utf8View.init(std.mem.span(clipboard))) |view| {
                    var iter = view.iterator();
                    while (iter.nextCodepoint()) |point| {
                        editor.insert(point);
                        if (!editor.select_all and editor.count() == s.town_name_limit) break;
                    }
                } else |_| {}
            }
        } else if (pressed(.backspace)) {
            editor.remove(if (editor.select_all) 0 else editor.previous(), if (editor.select_all) editor.draft.len else editor.caret);
        } else if (pressed(.delete)) {
            editor.remove(if (editor.select_all) 0 else editor.caret, if (editor.select_all) editor.draft.len else editor.next());
        } else if (pressed(.left) or r.isKeyPressed(.home)) {
            editor.caret = if (editor.select_all or r.isKeyPressed(.home)) 0 else editor.previous();
            editor.select_all = false;
        } else if (pressed(.right) or r.isKeyPressed(.end)) {
            editor.caret = if (editor.select_all or r.isKeyPressed(.end)) editor.draft.len else editor.next();
            editor.select_all = false;
        }

        while (true) {
            const raw = r.getCharPressed();
            if (raw == 0) break;
            if (!shortcut) editor.insert(std.math.cast(u21, raw) orelse continue);
        }
    }
};

test "town name editing keeps the caret between Unicode characters" {
    var editor = Editor.init(s.TownName.parse("港🌊").?);
    editor.select_all = false;
    editor.caret = editor.previous();
    editor.insert('é');
    try std.testing.expectEqualStrings("港é🌊", editor.draft.text());
    try std.testing.expectEqual(@as(usize, 3), editor.count());
    editor.remove(editor.previous(), editor.caret);
    editor.remove(editor.caret, editor.next());
    try std.testing.expectEqualStrings("港", editor.draft.text());
    try std.testing.expect(editor.draft.valid());
}
