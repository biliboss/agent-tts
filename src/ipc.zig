// Wire protocol between agent-tts client and daemon.
//
// Transport: UNIX stream socket at $HOME/.cache/agent-tts/sock
//
// Request lines (one per connection):
//   ENQUEUE\t<voice>\t<rate>\t<text>\n   → enqueue a TTS item
//   QUEUE\n                              → list pending+playing items
//   SKIP\n                               → skip current playing item
//   CLEAR\n                              → mark all pending as skipped
//
// Response lines:
//   OK\t<id>\n                           → enqueue/skip/clear ack
//   ERR\t<message>\n                     → error on any op
//   ITEM\t<id>\t<state>\t<voice>\t<rate>\t<text>\n  → QUEUE: one per item
//   END\n                                → QUEUE: end of list
//
// Text MUST NOT contain '\n' or '\t'. Client replaces them with ' '.

const std = @import("std");

pub const Op = enum { enqueue, queue, skip, clear };

pub const Message = struct {
    voice: []const u8,
    rate: u32,
    text: []const u8,
};

pub const Request = union(Op) {
    enqueue: Message,
    queue: void,
    skip: void,
    clear: void,
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
    return try std.fmt.allocPrint(arena, "ENQUEUE\t{s}\t{d}\t{s}\n", .{ msg.voice, msg.rate, msg.text });
}

pub const ParseError = error{ Malformed, UnknownOp, InvalidRate };

pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) ParseError!Request {
    var it = std.mem.splitScalar(u8, line, '\t');
    const op = it.next() orelse return error.Malformed;

    if (std.mem.eql(u8, op, "ENQUEUE")) {
        const voice = it.next() orelse return error.Malformed;
        const rate_str = it.next() orelse return error.Malformed;
        const text = it.rest();
        if (text.len == 0) return error.Malformed;
        const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
        const voice_dup = arena.dupe(u8, voice) catch return error.Malformed;
        const text_dup = arena.dupe(u8, text) catch return error.Malformed;
        return .{ .enqueue = .{ .voice = voice_dup, .rate = rate, .text = text_dup } };
    }
    if (std.mem.eql(u8, op, "QUEUE")) return .queue;
    if (std.mem.eql(u8, op, "SKIP")) return .skip;
    if (std.mem.eql(u8, op, "CLEAR")) return .clear;
    return error.UnknownOp;
}
