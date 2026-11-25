// Appends the command journal to disk. Best effort: a failure disables the
// journal and leaves the game running, like the trace.
const std = @import("std");
const Io = std.Io;
const domain = @import("core").colony;
const gameplay = @import("core").gameplay;
const journal = @import("core").journal;
const save = @import("core").save;

pub const current_name = "journal.bin";
pub const previous_name = "journal.previous.bin";
const max_bytes = 8 * 1024 * 1024;

pub const Recorder = struct {
    io: Io,
    dir: Io.Dir,
    file: Io.File,
    written: usize = 0,
    limit: usize = max_bytes,
    has_snapshot: bool = false,
    failed: bool = false,
    commands: u64 = 0,

    /// Opens `path/journal.bin`, keeping the last run's journal as
    /// `journal.previous.bin`. Call this only from the process that holds the
    /// trace lock for the same directory.
    pub fn open(io: Io, root: Io.Dir, path: []const u8) !Recorder {
        const dir = try root.createDirPathOpen(io, path, .{});
        errdefer dir.close(io);
        var recorder = Recorder{ .io = io, .dir = dir, .file = undefined };
        recorder.file = try recorder.openNext();
        return recorder;
    }

    fn openNext(recorder: *Recorder) !Io.File {
        recorder.dir.rename(current_name, recorder.dir, previous_name, recorder.io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const file = try recorder.dir.createFile(recorder.io, current_name, .{ .exclusive = true });
        errdefer file.close(recorder.io);
        try file.writeStreamingAll(recorder.io, &journal.header);
        recorder.written = journal.header.len;
        recorder.has_snapshot = false;
        return file;
    }

    pub fn deinit(recorder: *Recorder) void {
        recorder.file.sync(recorder.io) catch {};
        recorder.file.close(recorder.io);
        recorder.dir.close(recorder.io);
    }

    /// Start a new replay segment from this state, as after loading a save.
    pub fn snapshot(recorder: *Recorder, session: save.Session) void {
        recorder.append(&journal.snapshotRecord(session));
        if (!recorder.failed) recorder.has_snapshot = true;
    }

    /// Write-ahead: record the command before it is applied, so a crash
    /// inside the rules still leaves the offending command in the journal.
    pub fn command(recorder: *Recorder, before: *const domain.Game, next: gameplay.Command) void {
        if (recorder.failed) return;
        const record = journal.commandRecord(next);
        if (recorder.written + record.len > recorder.limit) recorder.rotate();
        if (!recorder.has_snapshot) recorder.snapshot(.{ .game = before.* });
        recorder.append(record.slice());
        recorder.commands += 1;
    }

    /// Record a fingerprint of the state after a day ends.
    pub fn checkpoint(recorder: *Recorder, game: *const domain.Game) void {
        recorder.append(&journal.checkpointRecord(game));
    }

    /// Start a fresh file whose first record will be a snapshot.
    fn rotate(recorder: *Recorder) void {
        const file = recorder.openNext() catch |err| return recorder.disable(err);
        recorder.file.close(recorder.io);
        recorder.file = file;
    }

    fn append(recorder: *Recorder, bytes: []const u8) void {
        if (recorder.failed) return;
        recorder.file.writeStreamingAll(recorder.io, bytes) catch |err| return recorder.disable(err);
        recorder.written += bytes.len;
    }

    fn disable(recorder: *Recorder, err: anyerror) void {
        recorder.failed = true;
        std.log.warn("Command journal unavailable: {s}", .{@errorName(err)});
    }
};

fn readJournal(dir: Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .unlimited);
}

test "a recorded session replays to the same state with matching checkpoints" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var game = domain.Game.init();
    game.stores[0].grain = 40;
    {
        var recorder = try Recorder.open(std.testing.io, temp.dir, "diagnostics");
        defer recorder.deinit();
        recorder.snapshot(.{ .game = game });
        const commands = [_]gameplay.Command{ .{ .export_grain = 0 }, .{ .advance = 5 }, .{ .advance = 5 }, .{ .export_grain = 9 }, .{ .advance = 7 } };
        for (commands) |next| {
            recorder.command(&game, next);
            const outcome = gameplay.apply(&game, next);
            if (outcome == .advanced and outcome.advanced.day != null) recorder.checkpoint(&game);
        }
    }
    const bytes = try readJournal(temp.dir, "diagnostics/" ++ current_name);
    defer std.testing.allocator.free(bytes);
    const report = try journal.replay(bytes, .{});
    try std.testing.expectEqual(@as(u64, 5), report.commands);
    try std.testing.expectEqual(@as(u64, 1), report.denied);
    try std.testing.expectEqual(@as(u64, 2), report.checkpoints);
    try std.testing.expect(report.divergence == null);
    try std.testing.expect(!report.truncated);
    try std.testing.expectEqualDeep(game, report.session.game);
}

test "a full journal rotates into a new file that starts with a snapshot" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var game = domain.Game.init();
    var recorder = try Recorder.open(std.testing.io, temp.dir, "diagnostics");
    defer recorder.deinit();
    recorder.limit = @sizeOf(journal.SnapshotRecord) + journal.header.len + 64;
    recorder.snapshot(.{ .game = game });
    for (0..12) |_| {
        recorder.command(&game, .{ .advance = 0.5 });
        _ = gameplay.apply(&game, .{ .advance = 0.5 });
    }
    const bytes = try readJournal(temp.dir, "diagnostics/" ++ current_name);
    defer std.testing.allocator.free(bytes);
    const report = try journal.replay(bytes, .{});
    try std.testing.expectEqual(@as(u32, 1), report.snapshots);
    try std.testing.expect(report.commands > 0 and report.commands < 12);
    try std.testing.expectEqualDeep(game, report.session.game);
    const previous = try readJournal(temp.dir, "diagnostics/" ++ previous_name);
    defer std.testing.allocator.free(previous);
    try std.testing.expect((try journal.replay(previous, .{})).commands > 0);
}
