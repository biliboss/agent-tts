// Daemon: accept loop on UNIX socket, worker thread drains queue via `say`.
//
// v0.2 scope: foreground daemon (no detach), single-threaded accept, one
// worker thread for playback. SIGINT cleans up the socket file.
//
// Auto-detach (fork+exec to background) lands in v0.4 with launchd.
//
// v0.6 add: optional PiperEngine boot when AGENT_TTS_PIPER=1 (env). Engine
// is loaded but NOT used for playback yet — that wiring lands in v0.7 along
// with zaudio streaming and the --engine flag. Here we just prove the cold
// load fits in the daemon boot budget.

const std = @import("std");
const ipc = @import("ipc.zig");
const tts = @import("tts.zig");
const Queue = @import("queue.zig").Queue;
const build_options = @import("build_options");

const READ_BUF = 16 * 1024;
const WRITE_BUF = 256;
const DEFAULT_VOICE = "Luciana";

pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const sock_path = try ipc.socketPath(arena, io, home);

    // Remove orphan socket if any. Cheap; ignored if not present.
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    var addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    std.debug.print("[daemon] listening on {s}\n", .{sock_path});

    var queue = Queue{ .arena = arena };

    // Pre-warm the voice. Best-effort.
    const t_warm0 = std.Io.Clock.now(.awake, io);
    tts.preWarm(arena, io, DEFAULT_VOICE) catch |e| {
        std.debug.print("[daemon] pre-warm failed: {s}\n", .{@errorName(e)});
    };
    const t_warm1 = std.Io.Clock.now(.awake, io);
    const warm_ms = @as(f64, @floatFromInt(t_warm1.nanoseconds - t_warm0.nanoseconds)) / 1_000_000.0;
    std.debug.print("[daemon] pre-warm done in {d:.1}ms\n", .{warm_ms});

    // Optional libpiper engine. Off by default; opt in via AGENT_TTS_PIPER=1.
    // We hold the engine for the daemon lifetime so v0.7 can swap routing in
    // without touching this boot path. For v0.6 it's load-only.
    if (build_options.enabled) {
        // run() doesn't take env_map; daemon reads via libc getenv. Imported
        // lazily inside the branch so plain (no-piper) build stays clean.
        const c = @cImport({
            @cInclude("stdlib.h");
        });
        const env_ptr = c.getenv("AGENT_TTS_PIPER");
        if (env_ptr != null and std.mem.eql(u8, std.mem.span(env_ptr), "1")) {
            tryBootPiper(arena, io, home);
        }
    }

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
    // GPA for per-play scratch allocations.
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    while (queue.pop(io)) |msg| {
        tts.play(gpa, io, msg) catch |e| {
            std.debug.print("[worker] play failed: {s}\n", .{@errorName(e)});
        };
    }
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

    const msg = ipc.parseRequest(arena, line) catch |e| {
        try writeErr(&sw.interface, @errorName(e));
        return;
    };

    const id = queue.push(io, msg) catch |e| {
        try writeErr(&sw.interface, @errorName(e));
        return;
    };

    try sw.interface.print("OK\t{d}\n", .{id});
    try sw.interface.flush();
}

fn writeErr(w: *std.Io.Writer, msg: []const u8) !void {
    try w.print("ERR\t{s}\n", .{msg});
    try w.flush();
}

// Boot the PiperEngine and leak it intentionally — it lives for the daemon's
// lifetime. v0.7 will keep the handle in a daemon-scoped struct that the
// worker can route to; for now we just verify cold load time.
fn tryBootPiper(arena: std.mem.Allocator, io: std.Io, home: []const u8) void {
    const piper = @import("piper.zig");

    const voice_path = std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/pt_BR-faber-medium.onnx",
        .{home},
    ) catch return;
    const espeak_data = "vendor/piper1-gpl/libpiper/dist/share/espeak-ng-data";

    const t0 = std.Io.Clock.now(.awake, io);
    var engine = piper.PiperEngine.init(arena, voice_path, espeak_data) catch |e| {
        std.debug.print("[daemon] piper engine load failed: {s}\n", .{@errorName(e)});
        std.debug.print("  voice: {s}\n", .{voice_path});
        std.debug.print("  espeak: {s}\n", .{espeak_data});
        return;
    };
    const t1 = std.Io.Clock.now(.awake, io);
    const load_ns: f64 = @floatFromInt(t1.nanoseconds - t0.nanoseconds);
    const load_ms = load_ns / 1_000_000.0;
    std.debug.print("[daemon] piper engine loaded in {d:.1}ms (v0.6 baseline; not routed yet)\n", .{load_ms});

    // Intentionally not calling engine.deinit() — daemon holds it until exit.
    _ = &engine;
}
