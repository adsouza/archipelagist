// Points <prefix>/bin at <prefix>/<os>-<arch>/bin after a native build.
//   link-bin PREFIX OS-ARCH/bin
// build.zig runs this; it replaces an existing bin link or an old bin folder.
const std = @import("std");

pub fn main(process: std.process.Init) !u8 {
    const io = process.io;
    const args = try process.minimal.args.toSlice(process.arena.allocator());
    if (args.len != 3) {
        std.log.err("usage: link-bin PREFIX OS-ARCH/bin", .{});
        return 2;
    }
    var prefix = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer prefix.close(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (prefix.readLink(io, "bin", &buffer)) |len| {
        if (std.mem.eql(u8, buffer[0..len], args[2])) return 0;
        try prefix.deleteFile(io, "bin");
    } else |err| switch (err) {
        error.FileNotFound => {},
        // An install from before per-target folders left a real bin folder.
        error.NotLink => try prefix.deleteTree(io, "bin"),
        else => |e| return e,
    }
    try prefix.symLink(io, args[2], "bin", .{ .is_directory = true });
    return 0;
}
