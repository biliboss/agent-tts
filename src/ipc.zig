// SPDX-License-Identifier: MIT OR Apache-2.0
// Wire protocol between agent-tts client and daemon.
//
// Transport: UNIX stream socket at $HOME/.cache/agent-tts/sock
//
// Request lines (one per connection):
//   ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<ssml>\t<text>\n → v1.8 7-field form
//   ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<text>\n         → v1.1 6-field form
//   ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>\n                 → v0.7 5-field form
//   ENQUEUE\t<voice>\t<rate>\t<text>\n                           → v0.6 4-field form
//   QUEUE\n                                                      → list items
//   SKIP\n                                                       → skip current
//   CLEAR\n                                                      → drop pending
//
// Backward compat (parseRequest):
//   1. Peek first token after ENQUEUE.
//      - Engine.fromStr matches      → new layout (v0.7+)
//      - Not an engine               → legacy v0.6 (token is the voice)
//   2. In new layout, peek the second token.
//      - Lang.fromStr matches        → v1.1+ (6-field or 7-field)
//      - Not a lang                  → v0.7 5-field (token is the voice)
//   3. In v1.1+ layout, peek the field after the rate.
//      - "0" / "1" exactly           → v1.8 7-field (token is the ssml flag)
//      - Anything else               → v1.1 6-field (rest is text)
//
// Lang defaults to `.auto` and ssml defaults to `false` when absent so
// v0.6/v0.7/v1.1 clients keep working unchanged.
//
// Response lines:
//   OK\t<id>\n                           → enqueue/skip/clear ack
//   ERR\t<message>\n                     → error on any op
//   ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>\n  → QUEUE: one per item
//   END\n                                → QUEUE: end of list
//
// Text MUST NOT contain '\n' or '\t'. Client replaces them with ' '.

const std = @import("std");

pub const Op = enum { enqueue, queue, skip, clear, pause, resume_play, replay, history };

pub const Engine = enum {
    say,
    piper,
    cloned,

    pub fn fromStr(s: []const u8) ?Engine {
        if (std.mem.eql(u8, s, "say")) return .say;
        if (std.mem.eql(u8, s, "piper")) return .piper;
        if (std.mem.eql(u8, s, "cloned")) return .cloned;
        return null;
    }

    pub fn str(e: Engine) []const u8 {
        return @tagName(e);
    }
};

// v1.1 — Lang on Message. `auto` defers detection to the daemon (per-chunk
// via preproc.splitByLang). `pt` / `en` force a single voice end-to-end and
// skip detection. Kept distinct from `detect.Lang` because the IPC enum has
// exactly three callable values; the detector has four including `mixed`
// and `unknown`, which are daemon-internal.
pub const Lang = enum {
    auto,
    pt,
    en,

    pub fn fromStr(s: []const u8) ?Lang {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "pt")) return .pt;
        if (std.mem.eql(u8, s, "en")) return .en;
        return null;
    }

    pub fn str(l: Lang) []const u8 {
        return @tagName(l);
    }
};

pub const Message = struct {
    engine: Engine = .say,
    lang: Lang = .auto,
    voice: []const u8,
    rate: u32,
    /// v1.8 — input contains W3C SSML 1.1 subset markup. When `false`,
    /// the daemon runs the v0.5 Pt-BR preprocessor as before. When
    /// `true`, the daemon parses SSML, applies engine-specific transpile
    /// (say → [[…]] directives, piper → prosody scaling), then routes.
    ssml: bool = false,
    text: []const u8,
};

pub const Request = union(Op) {
    enqueue: Message,
    queue: void,
    skip: void,
    clear: void,
    /// v1.10.2 — pause/resume the actively playing item. Both return
    /// `OK\t<id>` on success or `ERR\t<reason>` when there's nothing to act
    /// on. No payload on the wire — the daemon reads `current_playing_id`.
    pause: void,
    resume_play: void,
    /// v1.10.2 — replay a prior item by id. Wire shape: `REPLAY\t<id>\n`.
    /// Daemon copies the source row's engine/voice/rate/ssml/text into a
    /// new pending row and acks `OK\t<new_id>`.
    replay: u64,
    /// v1.10.2 — list the last N items (any state). Wire shape:
    /// `HISTORY\t<limit>\n`. Daemon emits `ITEM\t…` lines (same shape as
    /// QUEUE but with extra finished_at field) followed by `END`. Limit is
    /// clamped to 100 in the daemon for buffer hygiene.
    history: u32,
};

pub fn socketPath(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(arena, "{s}/.cache/agent-tts", .{home});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return try std.fmt.allocPrint(arena, "{s}/sock", .{dir});
}

pub fn queueDbPath(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(arena, "{s}/.cache/agent-tts", .{home});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return try std.fmt.allocPrint(arena, "{s}/queue.db", .{dir});
}

pub fn sanitizeText(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    const buf = try arena.alloc(u8, raw.len);
    for (raw, 0..) |ch, i| {
        buf[i] = switch (ch) {
            '\n', '\t', '\r' => ' ',
            else => ch,
        };
    }
    return buf;
}

pub fn encodeEnqueue(arena: std.mem.Allocator, msg: Message) ![]u8 {
    // v1.8 wire format: 7 fields. Daemon parser recognises the ssml flag
    // by exact "0"/"1" match between rate and text — anything else (e.g.
    // a v1.1 client's text starting with a digit followed by a tab) falls
    // back to v1.1 6-field parsing.
    const ssml_str: []const u8 = if (msg.ssml) "1" else "0";
    return try std.fmt.allocPrint(
        arena,
        "ENQUEUE\t{s}\t{s}\t{s}\t{d}\t{s}\t{s}\n",
        .{ msg.engine.str(), msg.lang.str(), msg.voice, msg.rate, ssml_str, msg.text },
    );
}

pub const ParseError = error{ Malformed, UnknownOp, InvalidRate };

pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) ParseError!Request {
    var it = std.mem.splitScalar(u8, line, '\t');
    const op = it.next() orelse return error.Malformed;

    if (std.mem.eql(u8, op, "ENQUEUE")) {
        const first = it.next() orelse return error.Malformed;
        if (Engine.fromStr(first)) |engine| {
            // New layout (v0.7 or v1.1+). Peek the next field for Lang.
            const second = it.next() orelse return error.Malformed;
            if (Lang.fromStr(second)) |lang| {
                // v1.1 6-field or v1.8 7-field. Both share the prefix
                // ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>; the
                // disambiguator sits between rate and text.
                const voice = it.next() orelse return error.Malformed;
                const rate_str = it.next() orelse return error.Malformed;
                const after_rate = it.next() orelse return error.Malformed;
                const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
                const voice_dup = arena.dupe(u8, voice) catch return error.Malformed;

                // v1.8: a bare "0" or "1" between rate and text marks the
                // ssml flag. Old clients send text directly — anything
                // longer than one byte or not in {'0','1'} keeps the
                // v1.1 6-field shape (after_rate IS the text).
                if (after_rate.len == 1 and (after_rate[0] == '0' or after_rate[0] == '1')) {
                    const text = it.rest();
                    if (text.len == 0) return error.Malformed;
                    const text_dup = arena.dupe(u8, text) catch return error.Malformed;
                    return .{ .enqueue = .{
                        .engine = engine,
                        .lang = lang,
                        .voice = voice_dup,
                        .rate = rate,
                        .ssml = after_rate[0] == '1',
                        .text = text_dup,
                    } };
                }

                // v1.1 6-field — after_rate is the first text field; we
                // need to splice it back together with whatever the
                // iterator still has.
                const rest = it.rest();
                const text_dup = blk: {
                    if (rest.len == 0) {
                        const dup = arena.dupe(u8, after_rate) catch return error.Malformed;
                        break :blk dup;
                    }
                    const total = arena.alloc(u8, after_rate.len + 1 + rest.len) catch return error.Malformed;
                    @memcpy(total[0..after_rate.len], after_rate);
                    total[after_rate.len] = '\t';
                    @memcpy(total[after_rate.len + 1 ..], rest);
                    break :blk total;
                };
                if (text_dup.len == 0) return error.Malformed;
                return .{ .enqueue = .{
                    .engine = engine,
                    .lang = lang,
                    .voice = voice_dup,
                    .rate = rate,
                    .ssml = false,
                    .text = text_dup,
                } };
            }
            // v0.7 5-field: `second` is the voice, lang defaults to .auto.
            const rate_str = it.next() orelse return error.Malformed;
            const text = it.rest();
            if (text.len == 0) return error.Malformed;
            const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
            const voice_dup = arena.dupe(u8, second) catch return error.Malformed;
            const text_dup = arena.dupe(u8, text) catch return error.Malformed;
            return .{ .enqueue = .{
                .engine = engine,
                .lang = .auto,
                .voice = voice_dup,
                .rate = rate,
                .text = text_dup,
            } };
        } else {
            // Legacy v0.6 4-field. `first` is the voice.
            const rate_str = it.next() orelse return error.Malformed;
            const text = it.rest();
            if (text.len == 0) return error.Malformed;
            const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
            const voice_dup = arena.dupe(u8, first) catch return error.Malformed;
            const text_dup = arena.dupe(u8, text) catch return error.Malformed;
            return .{ .enqueue = .{
                .engine = .say,
                .lang = .auto,
                .voice = voice_dup,
                .rate = rate,
                .text = text_dup,
            } };
        }
    }
    if (std.mem.eql(u8, op, "QUEUE")) return .queue;
    if (std.mem.eql(u8, op, "SKIP")) return .skip;
    if (std.mem.eql(u8, op, "CLEAR")) return .clear;
    // v1.10.2 — pause / resume / replay / history. PAUSE and RESUME take
    // no payload. REPLAY takes a single u64 id. HISTORY takes a single
    // u32 limit (clamped to 100 here).
    if (std.mem.eql(u8, op, "PAUSE")) return .pause;
    if (std.mem.eql(u8, op, "RESUME")) return .resume_play;
    if (std.mem.eql(u8, op, "REPLAY")) {
        const id_str = it.next() orelse return error.Malformed;
        const id = std.fmt.parseInt(u64, id_str, 10) catch return error.Malformed;
        return .{ .replay = id };
    }
    if (std.mem.eql(u8, op, "HISTORY")) {
        const limit_str = it.next() orelse return error.Malformed;
        const raw = std.fmt.parseInt(u32, limit_str, 10) catch return error.Malformed;
        const limit: u32 = if (raw == 0) 20 else @min(raw, 100);
        return .{ .history = limit };
    }
    return error.UnknownOp;
}

// ---- tests (v0.7 + v1.1) ----

test "parseRequest legacy v0.6 4-field ENQUEUE defaults engine=say lang=auto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tLuciana\t330\tOlá mundo");
    try std.testing.expect(req == .enqueue);
    try std.testing.expectEqual(Engine.say, req.enqueue.engine);
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
    try std.testing.expectEqualStrings("Luciana", req.enqueue.voice);
    try std.testing.expectEqual(@as(u32, 330), req.enqueue.rate);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "parseRequest v0.7 5-field ENQUEUE with explicit say + default lang=auto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tsay\tLuciana\t330\tOlá");
    try std.testing.expectEqual(Engine.say, req.enqueue.engine);
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
    try std.testing.expectEqualStrings("Luciana", req.enqueue.voice);
    try std.testing.expectEqualStrings("Olá", req.enqueue.text);
}

test "parseRequest v0.7 5-field ENQUEUE with piper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpiper\tfaber\t330\tOlá");
    try std.testing.expectEqual(Engine.piper, req.enqueue.engine);
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
    try std.testing.expectEqualStrings("faber", req.enqueue.voice);
}

test "parseRequest v1.1 6-field ENQUEUE with explicit lang=pt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpiper\tpt\tfaber\t330\tOlá mundo");
    try std.testing.expectEqual(Engine.piper, req.enqueue.engine);
    try std.testing.expectEqual(Lang.pt, req.enqueue.lang);
    try std.testing.expectEqualStrings("faber", req.enqueue.voice);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "parseRequest v1.1 6-field ENQUEUE with lang=en" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpiper\ten\tamy\t330\tHello world");
    try std.testing.expectEqual(Lang.en, req.enqueue.lang);
    try std.testing.expectEqualStrings("amy", req.enqueue.voice);
}

test "parseRequest v1.1 6-field ENQUEUE with lang=auto explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpiper\tauto\tfaber\t330\tOlá");
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
}

test "encodeEnqueue v1.1 round-trips through parseRequest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .piper,
        .lang = .en,
        .voice = "amy",
        .rate = 220,
        .text = "Hello, how are you?",
    };
    const wire = try encodeEnqueue(a, original);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(Engine.piper, req.enqueue.engine);
    try std.testing.expectEqual(Lang.en, req.enqueue.lang);
    try std.testing.expectEqualStrings("amy", req.enqueue.voice);
    try std.testing.expectEqual(@as(u32, 220), req.enqueue.rate);
    try std.testing.expectEqualStrings("Hello, how are you?", req.enqueue.text);
}

test "Engine.fromStr accepts known engines only" {
    try std.testing.expectEqual(Engine.say, Engine.fromStr("say").?);
    try std.testing.expectEqual(Engine.piper, Engine.fromStr("piper").?);
    try std.testing.expectEqual(Engine.cloned, Engine.fromStr("cloned").?);
    try std.testing.expect(Engine.fromStr("Luciana") == null);
    try std.testing.expect(Engine.fromStr("xtts") == null);
}

test "Lang.fromStr accepts known langs only" {
    try std.testing.expectEqual(Lang.auto, Lang.fromStr("auto").?);
    try std.testing.expectEqual(Lang.pt, Lang.fromStr("pt").?);
    try std.testing.expectEqual(Lang.en, Lang.fromStr("en").?);
    try std.testing.expect(Lang.fromStr("fr") == null);
    try std.testing.expect(Lang.fromStr("Luciana") == null);
}

test "parseRequest v1.8 7-field ENQUEUE with ssml=1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tsay\tpt\tLuciana\t330\t1\t<emphasis>Olá</emphasis>",
    );
    try std.testing.expectEqual(Engine.say, req.enqueue.engine);
    try std.testing.expectEqual(Lang.pt, req.enqueue.lang);
    try std.testing.expectEqual(true, req.enqueue.ssml);
    try std.testing.expectEqualStrings("<emphasis>Olá</emphasis>", req.enqueue.text);
}

test "parseRequest v1.8 7-field ENQUEUE with ssml=0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tauto\tfaber\t330\t0\tOlá mundo",
    );
    try std.testing.expectEqual(false, req.enqueue.ssml);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "parseRequest v1.1 text starting with digit is not misread as ssml flag" {
    // A v1.1 client sending text "1 dois 3" must still parse as v1.1 (ssml=false).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t1 dois 3",
    );
    try std.testing.expectEqual(false, req.enqueue.ssml);
    try std.testing.expectEqualStrings("1 dois 3", req.enqueue.text);
}

test "parseRequest v1.1 6-field still works (ssml defaults false)" {
    // Backward-compat: pre-v1.8 clients omit the ssml field. Parser must
    // recognise the absence and default to ssml=false.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\tOlá mundo",
    );
    try std.testing.expectEqual(false, req.enqueue.ssml);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "encodeEnqueue v1.8 round-trips ssml flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .say,
        .lang = .pt,
        .voice = "Luciana",
        .rate = 300,
        .ssml = true,
        .text = "<emphasis>Olá</emphasis>",
    };
    const wire = try encodeEnqueue(a, original);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(true, req.enqueue.ssml);
    try std.testing.expectEqualStrings(original.text, req.enqueue.text);
}

test "parseRequest legacy 5-field ENQUEUE with cloned engine (no lang)" {
    // v0.7 5-field form still parses for cloned engine — daemon defaults
    // lang to .auto and detects per chunk.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tcloned\tgabriel\t330\tOlá");
    try std.testing.expectEqual(Engine.cloned, req.enqueue.engine);
    try std.testing.expectEqualStrings("gabriel", req.enqueue.voice);
}

// v1.10.2 — pause / resume / replay / history parser tests.

test "parseRequest PAUSE has no payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "PAUSE");
    try std.testing.expect(req == .pause);
}

test "parseRequest RESUME has no payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "RESUME");
    try std.testing.expect(req == .resume_play);
}

test "parseRequest REPLAY parses u64 id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "REPLAY\t42");
    try std.testing.expect(req == .replay);
    try std.testing.expectEqual(@as(u64, 42), req.replay);
}

test "parseRequest REPLAY without id is malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Malformed, parseRequest(arena.allocator(), "REPLAY"));
}

test "parseRequest REPLAY with non-numeric id is malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Malformed, parseRequest(arena.allocator(), "REPLAY\tabc"));
}

test "parseRequest HISTORY parses u32 limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "HISTORY\t10");
    try std.testing.expect(req == .history);
    try std.testing.expectEqual(@as(u32, 10), req.history);
}

test "parseRequest HISTORY clamps limit to 100" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "HISTORY\t999");
    try std.testing.expectEqual(@as(u32, 100), req.history);
}

test "parseRequest HISTORY with 0 defaults to 20" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "HISTORY\t0");
    try std.testing.expectEqual(@as(u32, 20), req.history);
}

test "parseRequest unknown op still errors (no false positive on PAUSE prefix)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownOp, parseRequest(arena.allocator(), "PAUSED"));
}

test "v1.10.2 backward-compat: old QUEUE/SKIP/CLEAR still parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try parseRequest(arena.allocator(), "QUEUE")) == .queue);
    try std.testing.expect((try parseRequest(arena.allocator(), "SKIP")) == .skip);
    try std.testing.expect((try parseRequest(arena.allocator(), "CLEAR")) == .clear);
}
