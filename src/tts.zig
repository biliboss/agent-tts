// Drives macOS `say`. v0.3 splits spawn from wait so the daemon worker can
// register the child PID with the queue (for SKIP → SIGTERM) before blocking
// on wait().

const std = @import("std");
const ipc = @import("ipc.zig");

pub const SAY_PATH = "/usr/bin/say";

pub const Spawned = struct {
    child: std.process.Child,
    rate_str: []const u8, // owned by arena passed to spawnSay
};

pub fn spawnSay(arena: std.mem.Allocator, io: std.Io, voice: []const u8, rate: u32, text: []const u8) !Spawned {
    const rate_str = try std.fmt.allocPrint(arena, "{d}", .{rate});
    const argv = [_][]const u8{
        SAY_PATH,
        "-v",
        voice,
        "-r",
        rate_str,
        text,
    };
    const child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    return .{ .child = child, .rate_str = rate_str };
}

// Pre-warm the Speech Synthesis Manager: empty utterance loads the voice
// model into the Neural Engine so the next real play hits the cache.
pub fn preWarm(arena: std.mem.Allocator, io: std.Io, voice: []const u8) !void {
    const argv = [_][]const u8{ SAY_PATH, "-v", voice, " " };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(io);
    _ = arena;
}
