// Daemon: accept loop on UNIX socket, worker thread drains SQLite queue via
// `say`. v0.3 swaps in-memory queue for SQLite WAL — items survive daemon
// crash / reboot. Adds QUEUE/SKIP/CLEAR ops to the wire protocol.
//
// Auto-detach (fork+exec to background) lands in v0.4 with launchd.

const std = @import("std");
const ipc = @import("ipc.zig");
const tts = @import("tts.zig");
const Queue = @import("queue.zig").Queue;
const queue_mod = @import("queue.zig");

const READ_BUF = 16 * 1024;
const WRITE_BUF = 64 * 1024;
const DEFAULT_VOICE = "Luciana";

pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const sock_path = try ipc.socketPath(arena, io, home);
    const db_path = try ipc.queueDbPath(arena, io, home);

    // Remove orphan socket if any. Cheap; ignored if not present.
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    var addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    std.debug.print("[daemon] listening on {s}\n", .{sock_path});
    std.debug.print("[daemon] queue db {s}\n", .{db_path});

    var queue: Queue = .{ .arena = arena };
    try queue.init(db_path);
    defer queue.deinit();

    // Crash recovery already ran in queue.init (any 'playing' → 'pending').
    const pend_on_boot = queue.pending(io);
    if (pend_on_boot > 0) {
        std.debug.print("[daemon] recovered {d} pending items from previous run\n", .{pend_on_boot});
    }

    // Pre-warm the voice. Best-effort.
    const t_warm0 = std.Io.Clock.now(.awake, io);
    tts.preWarm(arena, io, DEFAULT_VOICE) catch |e| {
        std.debug.print("[daemon] pre-warm failed: {s}\n", .{@errorName(e)});
    };
    const t_warm1 = std.Io.Clock.now(.awake, io);
    const warm_ms = @as(f64, @floatFromInt(t_warm1.nanoseconds - t_warm0.nanoseconds)) / 1_000_000.0;
    std.debug.print("[daemon] pre-warm done in {d:.1}ms\n", .{warm_ms});

    const worker = try std.Thread.spawn(.{}, workerLoop, .{ &queue, io });
    worker.detach();

    while (true) {
        var stream = server.accept(io) catch |e| {
            std.debug.print("[daemon] accept failed: {s}\n", .{@errorName(e)});
            continue;
        };
        handleClient(arena, io, &stream, &queue) catch |e| {
            std.debug.print("[daemon] handle failed: {s}\n", .{@errorName(e)});
        };
        stream.close(io);
    }
}

fn workerLoop(queue: *Queue, io: std.Io) void {
    // GPA for per-play scratch allocations (spawn argv strings, popped item
    // buffers). Each iteration owns its allocations and frees at the end.
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    while (queue.pop(io, gpa)) |item| {
        defer gpa.free(item.voice);
        defer gpa.free(item.text);
        runOne(queue, io, gpa, item) catch |e| {
            std.debug.print("[worker] play id={d} failed: {s}\n", .{ item.id, @errorName(e) });
        };
    }
}

fn runOne(queue: *Queue, io: std.Io, gpa: std.mem.Allocator, item: queue_mod.PoppedItem) !void {
    var spawn_arena = std.heap.ArenaAllocator.init(gpa);
    defer spawn_arena.deinit();
    const sa = spawn_arena.allocator();

    var spawned = try tts.spawnSay(sa, io, item.voice, item.rate, item.text);

    // Register PID with the queue so SKIP can SIGTERM it. If wait() returned
    // before we got here (race window: spawn already exited before we set),
    // we'll still mark done in finishPlaying since state is still 'playing'.
    const pid = spawned.child.id orelse return error.SpawnNoPid;
    queue.setPlaying(io, item.id, pid);

    // wait() blocks until say exits. If SKIP fired, SIGTERM lands and wait
    // returns Term.signal. finishPlaying checks state='playing' before
    // overwriting, so a skip flagged in the DB is preserved.
    _ = spawned.child.wait(io) catch |e| {
        queue.finishPlaying(io, item.id);
        return e;
    };
    queue.finishPlaying(io, item.id);
}

fn handleClient(arena: std.mem.Allocator, io: std.Io, stream: *std.Io.net.Stream, queue: *Queue) !void {
    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [WRITE_BUF]u8 = undefined;

    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    const line = sr.interface.takeDelimiterExclusive('\n') catch |e| {
        try writeErr(&sw.interface, @errorName(e));
        return;
    };

    const req = ipc.parseRequest(arena, line) catch |e| {
        try writeErr(&sw.interface, @errorName(e));
        return;
    };

    switch (req) {
        .enqueue => |msg| {
            const id = queue.push(io, msg) catch |e| {
                try writeErr(&sw.interface, @errorName(e));
                return;
            };
            try sw.interface.print("OK\t{d}\n", .{id});
            try sw.interface.flush();
        },
        .queue => {
            const items = queue.list(io, arena) catch |e| {
                try writeErr(&sw.interface, @errorName(e));
                return;
            };
            for (items) |it| {
                try sw.interface.print("ITEM\t{d}\t{s}\t{s}\t{d}\t{s}\n", .{
                    it.id, it.state.str(), it.voice, it.rate, it.text,
                });
            }
            try sw.interface.writeAll("END\n");
            try sw.interface.flush();
        },
        .skip => {
            const id = queue.skipCurrent(io);
            try sw.interface.print("OK\t{d}\n", .{id});
            try sw.interface.flush();
        },
        .clear => {
            const n = queue.clearPending(io);
            try sw.interface.print("OK\t{d}\n", .{n});
            try sw.interface.flush();
        },
    }
}

fn writeErr(w: *std.Io.Writer, msg: []const u8) !void {
    try w.print("ERR\t{s}\n", .{msg});
    try w.flush();
}
