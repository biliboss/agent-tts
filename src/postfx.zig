// SPDX-License-Identifier: MIT OR Apache-2.0
// v1.10.10 — audio post-processing pipeline.
//
// Goal: take the i16 PCM the synth path produces and run it through an
// ffmpeg filter chain (RNNoise + 4-band EQ + de-esser + 2:1 compressor)
// before the zaudio engine pumps it to the device. Opt-in per call via
// `Postfx` enum on the IPC message; the daemon worker calls `apply()`
// after `piper.synth*` returns and before `audio_player.streamS16le*`.
//
// Design choices:
//   - ffmpeg subprocess (s16le→s16le pipe), not a linked library. RNNoise
//     and the EQ chain need ffmpeg's filter graph plumbing; bundling
//     libavfilter would balloon the binary. The subprocess overhead is
//     ~5-10 ms per call to spawn + ~0.5 ms per audio second to filter on
//     M-series silicon — measurable but acceptable inside the TTFA budget.
//   - Pure pass-through when:
//       - postfx == .off
//       - ffmpeg binary not found (probed lazily on first call)
//   - Chain selection is hardcoded per profile so an agent can A/B without
//     stringly-typed filter graphs reaching MCP. Custom chains via env
//     var land in v1.10.11+ if anyone asks.
//
// The chain `tech` references the `arnndn` filter with a Conjoined Burgers
// 2018-08-28 RNNoise model. We probe for the model at
// `$AGENT_TTS_POSTFX_RNNN_MODEL` first, then
// `$HOME/.cache/agent-tts/rnnoise/cb.rnnn`. When neither exists we drop
// the `arnndn=…` segment from the chain and use the EQ+deesser+compressor
// subset — still a quality lift, no hard dependency.

const std = @import("std");

/// Selectable post-fx profiles. `off` is the no-op (return samples
/// unchanged, no subprocess spawn). Strings on the wire mirror the
/// tags so the IPC layer can format/parse them with `@tagName`.
pub const Postfx = enum {
    off,
    clean,
    tech,
    broadcast,

    pub fn fromStr(s: []const u8) ?Postfx {
        if (std.mem.eql(u8, s, "off")) return .off;
        if (std.mem.eql(u8, s, "clean")) return .clean;
        if (std.mem.eql(u8, s, "tech")) return .tech;
        if (std.mem.eql(u8, s, "broadcast")) return .broadcast;
        return null;
    }

    pub fn str(p: Postfx) []const u8 {
        return @tagName(p);
    }
};

pub const PostfxError = error{
    SpawnFailed,
    PipeWriteFailed,
    PipeReadFailed,
    SubprocessAbnormal,
    OutOfMemory,
};

/// Result of `apply`. `samples` lives in `arena` so callers can drop
/// everything by deinit'ing the arena. `was_processed` is false when
/// the no-op path was taken (postfx=.off OR ffmpeg unavailable) so the
/// caller knows the slice is the original PCM, not a fresh allocation.
/// `postfx_ms` is the wall-time wall-clock cost of the subprocess hop,
/// usable for the daemon's `postfx_ms=X` log line.
pub const ApplyResult = struct {
    samples: []const i16,
    was_processed: bool,
    postfx_ms: f64 = 0,
};

/// Build the ffmpeg `-af` chain string for a profile. `rnnn_path` is
/// the absolute path to the RNNoise model file when available; null
/// drops the `arnndn=…` segment from the `tech` chain. Returned string
/// is owned by `arena`.
pub fn buildChain(arena: std.mem.Allocator, profile: Postfx, rnnn_path: ?[]const u8) ![]const u8 {
    return switch (profile) {
        .off => "",
        .clean => try arena.dupe(u8, "highpass=f=80,acompressor=threshold=-18dB:ratio=2:attack=20:release=200:makeup=1dB"),
        .tech => blk: {
            // Research-anchored chain from `_qa/v1.10.9-research-prompt-output.md`
            // ("Acoustic post-processing" subsection). HPF clears rumble,
            // body shelf adds warmth, presence cut tames sibilants, air
            // shelf adds clarity, deesser catches what remains, comp
            // tightens the dynamic range to broadcast levels.
            const tail = "highpass=f=80,equalizer=f=280:width_type=o:width=2:g=2.5,equalizer=f=3500:width_type=o:width=1.5:g=-1.5,equalizer=f=10000:width_type=o:width=2:g=1.8,deesser=i=0.08:m=0.5,acompressor=threshold=-18dB:ratio=2:attack=20:release=200:makeup=2dB";
            if (rnnn_path) |p| {
                break :blk try std.fmt.allocPrint(arena, "arnndn=m={s}," ++ tail, .{p});
            }
            break :blk try arena.dupe(u8, tail);
        },
        .broadcast => try arena.dupe(u8, "highpass=f=80,equalizer=f=280:width_type=o:width=2:g=2.0,equalizer=f=3000:width_type=o:width=1.5:g=-1.0,deesser=i=0.08:m=0.4,acompressor=threshold=-14dB:ratio=3:attack=15:release=180:makeup=2.5dB"),
    };
}

/// Probe `AGENT_TTS_FFMPEG_PATH` env, then `/opt/homebrew/bin/ffmpeg`,
/// then `/usr/local/bin/ffmpeg`, then bare `ffmpeg`. Returns the first
/// path that opens (or `ffmpeg` as last-resort which std.process resolves
/// against PATH). Caller does NOT free; strings are static literals or
/// env-owned. The env pointer is borrowed via `std.mem.span` which keeps
/// it valid for the process lifetime.
pub fn resolveFfmpeg() ?[]const u8 {
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const env_ptr = c.getenv("AGENT_TTS_FFMPEG_PATH");
    if (env_ptr != null) {
        const env_str = std.mem.span(env_ptr);
        if (env_str.len > 0 and pathExecutable(env_str)) return env_str;
    }
    const candidates = [_][]const u8{
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    };
    for (candidates) |p| {
        if (pathExecutable(p)) return p;
    }
    // Last resort: bare "ffmpeg" so std.process.spawn resolves it
    // against PATH. If PATH doesn't have it the spawn will fail and
    // the caller logs + falls back to pass-through.
    return "ffmpeg";
}

/// Probe `AGENT_TTS_POSTFX_RNNN_MODEL`, then
/// `$HOME/.cache/agent-tts/rnnoise/cb.rnnn`. Returns null when neither
/// exists. Caller owns the returned string (allocated from `arena`).
pub fn resolveRnnoiseModel(arena: std.mem.Allocator, home: []const u8) ?[]const u8 {
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const env_ptr = c.getenv("AGENT_TTS_POSTFX_RNNN_MODEL");
    if (env_ptr != null) {
        const env_str = std.mem.span(env_ptr);
        if (env_str.len > 0 and pathReadable(env_str)) {
            return arena.dupe(u8, env_str) catch return null;
        }
    }
    const default_path = std.fmt.allocPrint(arena, "{s}/.cache/agent-tts/rnnoise/cb.rnnn", .{home}) catch return null;
    if (pathReadable(default_path)) return default_path;
    return null;
}

fn pathExecutable(path: []const u8) bool {
    const c = @cImport({
        @cInclude("unistd.h");
    });
    const buf = std.heap.smp_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.smp_allocator.free(buf);
    // X_OK = 1
    return c.access(buf.ptr, 1) == 0;
}

fn pathReadable(path: []const u8) bool {
    const buf = std.heap.smp_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.smp_allocator.free(buf);
    const fd = std.c.open(buf.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return false;
    _ = std.c.close(fd);
    return true;
}

/// Apply the postfx chain to s16le mono PCM at `sample_rate`. When
/// `profile == .off` or ffmpeg isn't available, returns `samples`
/// unchanged with `was_processed=false`. Otherwise spawns ffmpeg, pipes
/// the PCM through, and returns the filtered output (lives in `arena`).
///
/// `home` is forwarded to `resolveRnnoiseModel` for the `tech` profile.
/// Pass the daemon's resolved `$HOME` so the user-cache fallback works
/// even when the daemon is launched by launchd (cwd != $HOME).
pub fn apply(
    arena: std.mem.Allocator,
    io: std.Io,
    samples: []const i16,
    sample_rate: u32,
    profile: Postfx,
    home: []const u8,
) PostfxError!ApplyResult {
    if (profile == .off or samples.len == 0) {
        return .{ .samples = samples, .was_processed = false };
    }

    const ffmpeg = resolveFfmpeg() orelse {
        return .{ .samples = samples, .was_processed = false };
    };

    // RNNoise model is best-effort. `null` drops the `arnndn=…` prefix
    // for the `tech` chain — the rest of the EQ+deesser+comp still runs.
    const rnnn_path: ?[]const u8 = if (profile == .tech) resolveRnnoiseModel(arena, home) else null;
    const chain = buildChain(arena, profile, rnnn_path) catch return error.OutOfMemory;
    if (chain.len == 0) {
        return .{ .samples = samples, .was_processed = false };
    }

    const rate_str = std.fmt.allocPrint(arena, "{d}", .{sample_rate}) catch return error.OutOfMemory;

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "s16le",
        "-ar",
        rate_str,
        "-ac",
        "1",
        "-i",
        "-",
        "-af",
        chain,
        "-f",
        "s16le",
        "-ar",
        rate_str,
        "-ac",
        "1",
        "-",
    }) catch return error.OutOfMemory;

    const t0 = std.Io.Clock.now(.awake, io);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch {
        // Subprocess didn't start — fall back to pass-through. Common
        // root causes: ffmpeg missing despite earlier probe (PATH
        // race), bad permissions, or a filter the ffmpeg build doesn't
        // ship. Silent pass-through keeps audio flowing.
        return .{ .samples = samples, .was_processed = false };
    };

    // PCM bytes view over the i16 buffer.
    const pcm_bytes: []const u8 = blk: {
        const p: [*]const u8 = @ptrCast(samples.ptr);
        break :blk p[0 .. samples.len * @sizeOf(i16)];
    };

    // Write all PCM to stdin and close it so ffmpeg can flush.
    if (child.stdin) |*stdin| {
        stdin.writeStreamingAll(io, pcm_bytes) catch {
            stdin.close(io);
            child.stdin = null;
            _ = child.wait(io) catch {};
            return .{ .samples = samples, .was_processed = false };
        };
        stdin.close(io);
        child.stdin = null;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    // Separate stream buffer + read scratch — Reader.readSliceShort
    // panics with "@memcpy arguments alias" when the destination
    // overlaps the stream's own buffer (Zig 0.16 strict aliasing).
    var stream_buf: [16 * 1024]u8 = undefined;
    var scratch: [16 * 1024]u8 = undefined;
    if (child.stdout) |*stdout| {
        var sr = stdout.readerStreaming(io, &stream_buf);
        while (true) {
            const n = sr.interface.readSliceShort(scratch[0..]) catch {
                _ = child.wait(io) catch {};
                return .{ .samples = samples, .was_processed = false };
            };
            if (n == 0) break;
            buf.appendSlice(arena, scratch[0..n]) catch return error.OutOfMemory;
        }
    }

    const term = child.wait(io) catch {
        return .{ .samples = samples, .was_processed = false };
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            return .{ .samples = samples, .was_processed = false };
        },
        else => return .{ .samples = samples, .was_processed = false },
    }

    const t1 = std.Io.Clock.now(.awake, io);
    const postfx_ms = @as(f64, @floatFromInt(t1.nanoseconds - t0.nanoseconds)) / 1_000_000.0;

    // Reinterpret the byte buffer as s16le. Drop a trailing odd byte
    // defensively — ffmpeg emits aligned frames in practice.
    const byte_len = buf.items.len & ~@as(usize, 1);
    if (byte_len == 0) {
        // Filter produced nothing (unlikely for a non-empty input but
        // possible with broken chains). Fall back to pass-through.
        return .{ .samples = samples, .was_processed = false };
    }
    const out_samples = arena.alloc(i16, byte_len / 2) catch return error.OutOfMemory;
    @memcpy(std.mem.sliceAsBytes(out_samples), buf.items[0..byte_len]);
    return .{ .samples = out_samples, .was_processed = true, .postfx_ms = postfx_ms };
}

// ---- tests --------------------------------------------------------------

test "Postfx.fromStr accepts known profiles" {
    try std.testing.expectEqual(Postfx.off, Postfx.fromStr("off").?);
    try std.testing.expectEqual(Postfx.clean, Postfx.fromStr("clean").?);
    try std.testing.expectEqual(Postfx.tech, Postfx.fromStr("tech").?);
    try std.testing.expectEqual(Postfx.broadcast, Postfx.fromStr("broadcast").?);
    try std.testing.expect(Postfx.fromStr("bogus") == null);
    try std.testing.expect(Postfx.fromStr("") == null);
}

test "Postfx.str round-trips through fromStr" {
    inline for ([_]Postfx{ .off, .clean, .tech, .broadcast }) |p| {
        try std.testing.expectEqual(p, Postfx.fromStr(p.str()).?);
    }
}

test "buildChain off returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try buildChain(arena.allocator(), .off, null);
    try std.testing.expectEqual(@as(usize, 0), chain.len);
}

test "buildChain clean returns highpass + acompressor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try buildChain(arena.allocator(), .clean, null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "highpass=f=80") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "acompressor=") != null);
    // No EQ in clean chain.
    try std.testing.expect(std.mem.indexOf(u8, chain, "equalizer=") == null);
}

test "buildChain tech without rnnn drops arnndn prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try buildChain(arena.allocator(), .tech, null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "arnndn=") == null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "highpass=f=80") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "deesser=") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "equalizer=f=280") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "equalizer=f=3500") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "equalizer=f=10000") != null);
}

test "buildChain tech with rnnn prefixes arnndn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try buildChain(arena.allocator(), .tech, "/tmp/cb.rnnn");
    try std.testing.expect(std.mem.startsWith(u8, chain, "arnndn=m=/tmp/cb.rnnn,"));
    try std.testing.expect(std.mem.indexOf(u8, chain, "deesser=") != null);
}

test "buildChain broadcast contains presence cut" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try buildChain(arena.allocator(), .broadcast, null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "equalizer=f=3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "deesser=i=0.08") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "ratio=3") != null);
}

test "apply postfx=off returns samples unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // We can't easily get a std.Io in tests without an event loop; the
    // off path returns before touching io so a zero-value is fine here.
    const io_storage: std.Io = undefined;
    const samples = [_]i16{ 0, 1, 2, 3 };
    const res = try apply(arena.allocator(), io_storage, &samples, 22050, .off, "/tmp");
    try std.testing.expectEqual(false, res.was_processed);
    try std.testing.expectEqual(@as(usize, 4), res.samples.len);
    try std.testing.expectEqual(@as(i16, 2), res.samples[2]);
}

test "apply empty samples returns unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io_storage: std.Io = undefined;
    const samples = [_]i16{};
    const res = try apply(arena.allocator(), io_storage, &samples, 22050, .tech, "/tmp");
    try std.testing.expectEqual(false, res.was_processed);
    try std.testing.expectEqual(@as(usize, 0), res.samples.len);
}
