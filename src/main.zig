// agent-tts — Pt-BR TTS via macOS `say` + (experimental) libpiper.
//
// Single binary, modes:
//   agent-tts daemon                       → daemon (foreground)
//   agent-tts daemon install               → write LaunchAgent plist + bootstrap
//   agent-tts daemon uninstall             → bootout + delete plist
//   agent-tts daemon status                → loaded?/last exit
//   agent-tts queue                        → client: list pending+playing items
//   agent-tts skip                         → client: skip current playing item
//   agent-tts clear                        → client: drop all pending items
//   agent-tts piper-test "<text>" <out>    → (experimental) libpiper one-shot synth
//   agent-tts -h | --help                  → help
//   agent-tts -V | --version               → version
//   agent-tts ...                          → client: enqueue text on running daemon
//
// v0.3: SQLite WAL queue at ~/.cache/agent-tts/queue.db.
// v0.4: launchd LaunchAgent (~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist).
// v0.5: Pt-BR text preprocessor (abbreviations, cardinals 0..9999, [[slnc N]] pauses).
// v0.6: libpiper FFI baseline (PiperEngine; engine loaded but not routed yet — v0.7).
//
// KPI = time-to-first-audio (TTFA).

const std = @import("std");

const client = @import("client.zig");
const daemon = @import("daemon.zig");
const launchd = @import("launchd.zig");
const build_options = @import("build_options");

pub const VERSION = "0.6.0";

const HELP =
    \\agent-tts v{s} — Pt-BR TTS via macOS `say`
    \\
    \\Usage:
    \\  agent-tts "texto"                send to running daemon
    \\  agent-tts queue                  list pending + playing items
    \\  agent-tts skip                   skip current playing item
    \\  agent-tts clear                  drop all pending items
    \\  agent-tts daemon                 run daemon (foreground)
    \\  agent-tts daemon install         install launchd LaunchAgent (auto-start)
    \\  agent-tts daemon uninstall       remove launchd LaunchAgent
    \\  agent-tts daemon status          print launchd load state
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
    \\v0.5 ships the Pt-BR text preprocessor: abbreviations (Sr./Dr./Av./R$/…),
    \\cardinal numbers 0..9999 (e.g. 2026 → "dois mil e vinte e seis"), and
    \\[[slnc N]] pauses for commas, sentences and newlines. Cadência humana.
    \\
    \\launchd plist lives at ~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist
    \\(override label via AGENT_TTS_LAUNCHD_LABEL env var — used by tests).
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse "/tmp";

    const label_override = init.environ_map.get(launchd.LABEL_ENV);

    if (args.len > 1) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "daemon")) {
            if (args.len > 2) {
                const sub = args[2];
                if (std.mem.eql(u8, sub, "install")) {
                    return launchd.install(arena, io, home, label_override, null);
                }
                if (std.mem.eql(u8, sub, "uninstall")) {
                    return launchd.uninstall(arena, io, home, label_override);
                }
                if (std.mem.eql(u8, sub, "status")) {
                    return launchd.status(arena, io, home, label_override);
                }
                std.debug.print("error: unknown daemon subcommand '{s}'\n", .{sub});
                std.process.exit(2);
            }
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

    std.debug.print("[piper-test] init={d:.1}ms synth={d:.1}ms total={d:.1}ms out={s}\n", .{
        init_ms, synth_ms, init_ms + synth_ms, out_path,
    });
}
