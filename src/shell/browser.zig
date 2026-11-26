//! The browser side of the shell, for the WebAssembly build. Elsewhere every
//! function here does nothing.
const builtin = @import("builtin");
const std = @import("std");

pub const enabled = builtin.os.tag == .emscripten;

/// Where saves live in the browser: an IndexedDB-backed folder that
/// src/app/web/shell.html mounts before the game starts.
pub const save_root = "/persist";

extern fn emscripten_run_script(script: [*:0]const u8) void;

/// Copies the in-memory files under `save_root` to IndexedDB, so a save
/// survives reloading the page. Runs in the background.
pub fn persist() void {
    if (!enabled) return;
    emscripten_run_script(
        \\FS.syncfs(false, (error) => { if (error) console.warn("Could not store the save:", error); });
    );
}

extern fn emscripten_run_script_string(script: [*:0]const u8) ?[*:0]const u8;
extern fn emscripten_run_script_int(script: [*:0]const u8) c_int;

pub const TextAction = enum { editing, submit, cancel };

pub fn openTownName(text: [:0]const u8, limit: usize, x: f32, y: f32, width: f32, height: f32) void {
    if (!enabled) return;
    var script: [160]u8 = undefined;
    emscripten_run_script(std.fmt.bufPrintSentinel(
        &script,
        "Module.openTownName(UTF8ToString({d}),{d},{d},{d},{d},{d})",
        .{ @intFromPtr(text.ptr), limit, x, y, width, height },
        0,
    ) catch unreachable);
}

pub fn townNameText() []const u8 {
    if (!enabled) return "";
    const value = emscripten_run_script_string("Module.townNameInput.value") orelse return "";
    return std.mem.span(value);
}

pub fn townNameAction() TextAction {
    if (!enabled) return .editing;
    return switch (emscripten_run_script_int("Module.takeTownNameAction()")) {
        1 => .submit,
        2 => .cancel,
        else => .editing,
    };
}

pub fn closeTownName() void {
    if (enabled) emscripten_run_script("Module.closeTownName()");
}

test "persist does nothing outside the browser" {
    persist();
}
