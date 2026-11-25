//! The browser side of the shell, for the WebAssembly build. Elsewhere every
//! function here does nothing.
const builtin = @import("builtin");

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

test "persist does nothing outside the browser" {
    persist();
}
