//! The imperative shell: save files, the journal file, tracing and crash
//! diagnostics around the core. It imports the core and never the app.
pub const diagnostics = @import("diagnostics.zig");
pub const save_store = @import("save_store.zig");
pub const journal_file = @import("journal_file.zig");
pub const gameplay_trace = @import("gameplay_trace.zig");
pub const browser = @import("browser.zig");

test {
    _ = diagnostics;
    _ = save_store;
    _ = journal_file;
    _ = gameplay_trace;
    _ = browser;
    _ = @import("properties.zig");
}
