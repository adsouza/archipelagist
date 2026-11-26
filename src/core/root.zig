//! The functional core: the island colony's rules, its read models and the
//! pure save and journal codecs. Nothing here touches files, clocks, logging,
//! audio or graphics; the shell and the app wrap it. build.zig gives this
//! module no imports besides std, and `zig build check-deps` checks the
//! layers inside it.
pub const colony = @import("colony.zig");
pub const gameplay = @import("gameplay.zig");
pub const queries = @import("queries.zig");
pub const stock_warnings = @import("stock_warnings.zig");
pub const save = @import("save.zig");
pub const journal = @import("journal.zig");
pub const roads = @import("roads.zig");
pub const geography = @import("geography.zig");

test {
    _ = colony;
    _ = @import("fleet.zig");
    _ = @import("ferry.zig");
    _ = @import("bridge.zig");
    _ = @import("charter.zig");
    _ = @import("expedition.zig");
    _ = roads;
    _ = gameplay;
    _ = queries;
    _ = stock_warnings;
    _ = save;
    _ = journal;
    _ = @import("stateful.zig");
    _ = @import("autoplay.zig");
}
