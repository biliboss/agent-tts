// agent-tts v0.6 — Pt-BR TTS via macOS `say`, with persistent daemon.
//
// Entry point. Routes argv:
//   agent-tts daemon                       → daemon mode
//   agent-tts piper-test "<text>" <out>    → (experimental) libpiper synth one-shot
//   agent-tts -h | --help                  → help
//   agent-tts -V | --version               → version
//   agent-tts ...                          → client mode (enqueue to running daemon)
//
// v0.6 scope locked by docs/roadmap.md:
//   - libpiper FFI baseline (struct PiperEngine, voice loaded at daemon boot
//     when AGENT_TTS_PIPER=1; otherwise skipped)
//   - hidden `piper-test` subcommand bypasses daemon for cold-cost measurement
//   - Routing through the engine for normal playback is v0.7 (not here)
//
// KPI = time-to-first-audio (TTFA). v0.6 target: piper synth + write WAV <1s on M4.

const std = @import("std");

const client = @import("client.zig");
const daemon = @import("daemon.zig");
const build_options = @import("build_options");

pub const VERSION = "0.6.0";

const HELP =
    \\agent-tts v{s} — Pt-BR TTS via macOS `say`
    \\
    \\Usage:
    \\  agent-tts "texto"                send to running daemon
    \\  agent-tts daemon                 run daemon (foreground)
    \\  agent-tts --voice "Felipe" "texto"
    \\  agent-tts --rate 220 "texto"
    \\
    \\Experimental (v0.6):
    \\  agent-tts piper-test "texto" out.wav   synth one WAV via libpiper, exit
    \\                                         (requires zig build -Dwith-piper=true)
    \\                                         daemon opt-in: AGENT_TTS_PIPER=1
    \\
    \\Options:
    \\  --voice NAME   say voice (default: Luciana)
    \\  --rate WPM     words per minute (default: 330)
    \\  -h, --help     this help
    \\  -V, --version  print version
    \\
    \\v0.6 needs `agent-tts daemon` running in another terminal.
    \\Auto-start arrives in v0.4 (launchd).
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse "/tmp";

    if (args.len > 1) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "daemon")) {
            return daemon.run(arena, io, home);
        }
        if (std.mem.eql(u8, cmd, "piper-test")) {
            return runPiperTest(arena, io, home, args);
        }
        if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
            std.debug.print(HELP, .{VERSION});
            return;
        }
        if (std.mem.eql(u8, cmd, "-V") or std.mem.eql(u8, cmd, "--version")) {
            std.debug.print("agent-tts {s}\n", .{VERSION});
            return;
        }
    }
    return client.run(arena, io, home, args);
}

fn runPiperTest(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    args: []const []const u8,
) !void {
    if (!build_options.enabled) {
        std.debug.print(
            "error: piper-test requires `zig build -Dwith-piper=true` and a built libpiper.dylib (see vendor/README.md)\n",
            .{},
        );
        std.process.exit(2);
    }
    if (args.len < 4) {
        std.debug.print("usage: agent-tts piper-test \"<text>\" <out.wav>\n", .{});
        std.process.exit(2);
    }
    const text = args[2];
    const out_path = args[3];

    const piper = @import("piper.zig");

    const voice_path = try std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/pt_BR-faber-medium.onnx",
        .{home},
    );
    // espeak-ng-data ships under the vendored libpiper dist tree. Hardcoded for
    // dev. v0.7+ will resolve via XDG_DATA_DIRS or a bundled location.
    const espeak_data = "vendor/piper1-gpl/libpiper/dist/share/espeak-ng-data";

    const t_init0 = std.Io.Clock.now(.awake, io);
    var engine = piper.PiperEngine.init(arena, voice_path, espeak_data) catch |e| {
        std.debug.print("error: PiperEngine.init failed: {s}\n", .{@errorName(e)});
        std.debug.print("  voice: {s}\n", .{voice_path});
        std.debug.print("  espeak: {s}\n", .{espeak_data});
        std.process.exit(1);
    };
    defer engine.deinit();
    const t_init1 = std.Io.Clock.now(.awake, io);
    const init_ms = @as(f64, @floatFromInt(t_init1.nanoseconds - t_init0.nanoseconds)) / 1_000_000.0;

    const t_synth0 = std.Io.Clock.now(.awake, io);
    engine.synthToWav(io, text, out_path) catch |e| {
        std.debug.print("error: synthToWav failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    const t_synth1 = std.Io.Clock.now(.awake, io);
    const synth_ms = @as(f64, @floatFromInt(t_synth1.nanoseconds - t_synth0.nanoseconds)) / 1_000_000.0;

    std.debug.print(
        "[piper-test] init={d:.1}ms synth+wav={d:.1}ms out={s}\n",
        .{ init_ms, synth_ms, out_path },
    );
}
