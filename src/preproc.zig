// SPDX-License-Identifier: MIT OR Apache-2.0
// Pt-BR text preprocessor for `say`. v0.5.
//
// Applies, in order:
//   1. Whole-word abbreviation expansion (Sr. → Senhor, etc.)
//   2. Cardinal number-to-words (0..9999, Pt-BR)
//   3. Pause directives ([[slnc N]]) after punctuation and newlines
//
// Single pass per stage. All allocations are arena-bound, so the caller
// owns the lifetime by passing a per-utterance allocator.
//
// Rationale: TTFA budget is < 1ms per message on M-class silicon. Each
// stage is O(N) in the input length with no regex / no global state.

const std = @import("std");

pub const Pause = struct {
    pub const COMMA_MS: u32 = 150;
    pub const SENTENCE_MS: u32 = 400;
    pub const NEWLINE_MS: u32 = 600;
};

/// One unit of work for the v1.2 streaming pipeline. Bytes are sliced from
/// the caller's input (or arena-duped on edge cases); the caller's arena
/// owns the underlying memory.
pub const Chunk = struct {
    text: []const u8,
};

const Abbrev = struct {
    src: []const u8,
    dst: []const u8,
};

// Order matters only for ties; we match by exact `src` (case-sensitive
// for "Sr."/"Sra."/"Dr."/"Dra."/"Av." which are sentence-cased in the
// wild). "cf." / "etc." / "vs." / "nº" / "R$" are lower-cased.
const ABBREVS = [_]Abbrev{
    .{ .src = "Sra.", .dst = "Senhora" },
    .{ .src = "Dra.", .dst = "Doutora" },
    .{ .src = "etc.", .dst = "etcétera" },
    .{ .src = "Sr.", .dst = "Senhor" },
    .{ .src = "Dr.", .dst = "Doutor" },
    .{ .src = "cf.", .dst = "conforme" },
    .{ .src = "vs.", .dst = "versus" },
    .{ .src = "Av.", .dst = "Avenida" },
    .{ .src = "nº", .dst = "número" },
    .{ .src = "R$", .dst = "reais" },
};

/// Main entry. Returns a freshly allocated buffer (in `arena`) with the
/// transformed text. Caller does not need to free — arena owns it.
pub fn process(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return arena.alloc(u8, 0);

    const after_abbrev = try expandAbbreviations(arena, raw);
    const after_numbers = try expandNumbers(arena, after_abbrev);
    const after_pauses = try insertPauses(arena, after_numbers);
    return after_pauses;
}

// ──────────────────────────────────────────────────────────────────────
// Stage 1 — abbreviations
// ──────────────────────────────────────────────────────────────────────

/// Returns true if `c` can be part of a "word" boundary, i.e. an
/// alphanumeric ASCII char or a UTF-8 continuation byte. We treat any
/// byte ≥ 0x80 as part of a word so that accented letters in Pt-BR
/// ("ção", "número") don't accidentally break matches.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

fn matchesAt(input: []const u8, idx: usize, needle: []const u8) bool {
    if (idx + needle.len > input.len) return false;
    return std.mem.eql(u8, input[idx .. idx + needle.len], needle);
}

fn expandAbbreviations(arena: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, input.len);

    var i: usize = 0;
    while (i < input.len) {
        // Only attempt match at word starts: either at index 0, or after
        // a non-word byte. This stops "Sr." from matching mid-word.
        const at_word_start = (i == 0) or !isWordByte(input[i - 1]);

        var matched: ?Abbrev = null;
        if (at_word_start) {
            for (ABBREVS) |ab| {
                if (matchesAt(input, i, ab.src)) {
                    matched = ab;
                    break;
                }
            }
        }

        if (matched) |ab| {
            try out.appendSlice(arena, ab.dst);
            i += ab.src.len;
        } else {
            try out.append(arena, input[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(arena);
}

// ──────────────────────────────────────────────────────────────────────
// Stage 2 — cardinal numbers (Pt-BR, 0..9999)
// ──────────────────────────────────────────────────────────────────────

const UNITS = [_][]const u8{
    "zero",   "um",     "dois",  "três",
    "quatro", "cinco",  "seis",  "sete",
    "oito",   "nove",   "dez",   "onze",
    "doze",   "treze",  "catorze", "quinze",
    "dezesseis", "dezessete", "dezoito", "dezenove",
};

const TENS = [_][]const u8{
    "", "", "vinte", "trinta", "quarenta",
    "cinquenta", "sessenta", "setenta", "oitenta", "noventa",
};

// "cento" is used in compounds (cento e dez); "cem" is the bare 100.
const HUNDREDS = [_][]const u8{
    "",           "cento",       "duzentos",  "trezentos",
    "quatrocentos", "quinhentos", "seiscentos", "setecentos",
    "oitocentos", "novecentos",
};

fn appendUnder100(out: *std.ArrayList(u8), arena: std.mem.Allocator, n: u16) !void {
    std.debug.assert(n < 100);
    if (n < 20) {
        try out.appendSlice(arena, UNITS[n]);
        return;
    }
    const t = n / 10;
    const u = n % 10;
    try out.appendSlice(arena, TENS[t]);
    if (u != 0) {
        try out.appendSlice(arena, " e ");
        try out.appendSlice(arena, UNITS[u]);
    }
}

fn appendUnder1000(out: *std.ArrayList(u8), arena: std.mem.Allocator, n: u16) !void {
    std.debug.assert(n < 1000);
    if (n < 100) {
        try appendUnder100(out, arena, n);
        return;
    }
    const h = n / 100;
    const rem: u16 = n % 100;
    if (rem == 0 and h == 1) {
        try out.appendSlice(arena, "cem");
        return;
    }
    try out.appendSlice(arena, HUNDREDS[h]);
    if (rem != 0) {
        try out.appendSlice(arena, " e ");
        try appendUnder100(out, arena, rem);
    }
}

/// Render `n` (0..9999) as Pt-BR cardinal words into `out`.
pub fn renderCardinal(out: *std.ArrayList(u8), arena: std.mem.Allocator, n: u16) !void {
    if (n > 9999) return error.OutOfRange;
    if (n < 1000) {
        try appendUnder1000(out, arena, n);
        return;
    }
    const thousands = n / 1000;
    const rem = n % 1000;
    if (thousands == 1) {
        try out.appendSlice(arena, "mil");
    } else {
        try appendUnder1000(out, arena, thousands);
        try out.appendSlice(arena, " mil");
    }
    if (rem == 0) return;
    // Pt-BR connector is " e " when rem < 100 or rem is a round
    // hundred (200, 300, …). Otherwise ", " is closer to natural
    // speech ("mil, duzentos e trinta e quatro"). We pick " e " when
    // rem < 100 or rem % 100 == 0; otherwise " ".
    if (rem < 100 or rem % 100 == 0) {
        try out.appendSlice(arena, " e ");
    } else {
        try out.appendSlice(arena, " ");
    }
    try appendUnder1000(out, arena, rem);
}

fn expandNumbers(arena: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];

        // Negative number: `-` followed directly by digits, at a word
        // boundary (start of string or after non-word byte).
        if (c == '-' and i + 1 < input.len and std.ascii.isDigit(input[i + 1])) {
            const at_word_start = (i == 0) or !isWordByte(input[i - 1]);
            if (at_word_start) {
                // Look ahead at digit run.
                var j = i + 1;
                while (j < input.len and std.ascii.isDigit(input[j])) : (j += 1) {}
                // Skip if the digit run is followed by a letter or `%`.
                const followed_by_letter = j < input.len and isWordByte(input[j]);
                const followed_by_pct = j < input.len and input[j] == '%';
                if (!followed_by_letter and !followed_by_pct) {
                    const value = std.fmt.parseInt(u16, input[i + 1 .. j], 10) catch {
                        try out.append(arena, c);
                        i += 1;
                        continue;
                    };
                    try out.appendSlice(arena, "menos ");
                    try renderCardinal(&out, arena, value);
                    i = j;
                    continue;
                }
            }
        }

        if (std.ascii.isDigit(c)) {
            const at_word_start = (i == 0) or !isWordByte(input[i - 1]);
            if (at_word_start) {
                var j = i;
                while (j < input.len and std.ascii.isDigit(input[j])) : (j += 1) {}
                const followed_by_letter = j < input.len and isWordByte(input[j]);
                const followed_by_pct = j < input.len and input[j] == '%';
                if (!followed_by_letter and !followed_by_pct) {
                    const value = std.fmt.parseInt(u16, input[i..j], 10) catch {
                        // Out of range (>65535 or >9999). Leave raw.
                        try out.appendSlice(arena, input[i..j]);
                        i = j;
                        continue;
                    };
                    if (value > 9999) {
                        try out.appendSlice(arena, input[i..j]);
                    } else {
                        try renderCardinal(&out, arena, value);
                    }
                    i = j;
                    continue;
                }
            }
        }

        try out.append(arena, c);
        i += 1;
    }

    return out.toOwnedSlice(arena);
}

// ──────────────────────────────────────────────────────────────────────
// Stage 3 — pause directives
// ──────────────────────────────────────────────────────────────────────
//
// `[[slnc N]]` is a literal directive `say` accepts (milliseconds).
//
// Rules:
//   - `,`          → `, [[slnc 150]]`
//   - `.` `!` `?`  → `<punct> [[slnc 400]]`
//   - `\n`         → `[[slnc 600]]` (newline itself eaten)
//   - Multiple consecutive punctuation collapses to one pause, taking
//     the longest of the group, emitted after the last printable
//     punctuation char in the run.
//
// We scan in one pass, accumulating "pause-bearing" runs. A run is any
// maximal sequence of {',' '.' '!' '?' '\n' ' ' '\t'} that contains at
// least one pause-bearing char. We strip leading/trailing whitespace
// from the run on emit, keep the punctuation chars in order (except
// '\n' is dropped — only its pause survives), and append a single
// `[[slnc N]]` with N = max pause across all chars.

fn pauseMsFor(c: u8) ?u32 {
    return switch (c) {
        ',' => Pause.COMMA_MS,
        '.', '!', '?' => Pause.SENTENCE_MS,
        '\n' => Pause.NEWLINE_MS,
        else => null,
    };
}

fn isRunByte(c: u8) bool {
    return c == ',' or c == '.' or c == '!' or c == '?' or
        c == '\n' or c == ' ' or c == '\t';
}

fn insertPauses(arena: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    // Worst case: every char becomes "X [[slnc 600]]". ~12 byte overhead.
    try out.ensureTotalCapacity(arena, input.len * 2);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];

        // Detect start of a run that contains a pause-bearing char.
        if (isRunByte(c)) {
            // Find end of run.
            var j = i;
            while (j < input.len and isRunByte(input[j])) : (j += 1) {}
            const run = input[i..j];

            // Compute max pause + collect printable punctuation chars.
            var max_pause: u32 = 0;
            for (run) |ch| {
                if (pauseMsFor(ch)) |p| {
                    if (p > max_pause) max_pause = p;
                }
            }

            if (max_pause == 0) {
                // Pure whitespace (spaces/tabs only). Pass through as
                // a single space to avoid collapsing intentional
                // formatting too aggressively.
                try out.append(arena, ' ');
                i = j;
                continue;
            }

            // Emit printable punctuation, in order, dropping spaces/
            // tabs/newlines.
            for (run) |ch| {
                switch (ch) {
                    ',', '.', '!', '?' => try out.append(arena, ch),
                    else => {},
                }
            }
            try out.appendSlice(arena, " [[slnc ");
            try out.print(arena, "{d}", .{max_pause});
            try out.appendSlice(arena, "]]");
            // Trailing space so the next word doesn't glue to the
            // directive in the rendered text. If the run is at end of
            // input we still emit it — harmless to `say`.
            try out.append(arena, ' ');
            i = j;
            continue;
        }

        try out.append(arena, c);
        i += 1;
    }

    return out.toOwnedSlice(arena);
}

// ──────────────────────────────────────────────────────────────────────
// v1.2 — sentence chunking for streaming
// ──────────────────────────────────────────────────────────────────────
//
// `chunkSentences` splits raw input into Chunks on `.`, `!`, `?`, `\n`.
// Punctuation stays attached to the preceding chunk; newline is dropped
// (its semantic pause comes back when `process` runs on the chunk).
//
// Abbreviation guard: a `.` that closes an entry in ABBREVS (e.g. `Sr.`,
// `Dr.`, `Sra.`, `Av.`) does NOT terminate. Mirrors the same list used by
// `expandAbbreviations`, so the streaming path can't introduce a split
// the non-streaming path wouldn't honor. Lower-case-only abbreviations
// like `cf.`, `etc.`, `vs.` are also guarded.
//
// Leading/trailing whitespace per chunk is trimmed. Empty chunks dropped.
//
// Returns a slice of Chunks owned by `arena`. Each chunk's `text` field
// is a subslice of `text` (no copy) — caller must keep `text` alive for
// the chunks' lifetime.
//
// Known v1.2 corner cases (documented in whats-next.md for v1.2.1):
//   - Decimals like "3.14" — the `.` is treated as a terminator. Acceptable
//     because preproc's number stage doesn't handle decimals either.
//   - Ellipsis "..." — collapses to a single chunk break (multiple `.`s
//     in a row yield one split, not three).

fn isAbbrevDotAt(input: []const u8, dot_idx: usize) bool {
    // Check whether input[dot_idx] == '.' is the terminating dot of any
    // entry in ABBREVS. Boundary rule mirrors expandAbbreviations: the
    // entry must start at a word boundary.
    if (dot_idx >= input.len or input[dot_idx] != '.') return false;
    for (ABBREVS) |ab| {
        if (ab.src.len == 0 or ab.src[ab.src.len - 1] != '.') continue;
        if (ab.src.len > dot_idx + 1) continue;
        const start = dot_idx + 1 - ab.src.len;
        if (!std.mem.eql(u8, input[start .. dot_idx + 1], ab.src)) continue;
        const at_word_start = (start == 0) or !isWordByte(input[start - 1]);
        if (at_word_start) return true;
    }
    return false;
}

fn isTerminator(c: u8) bool {
    return c == '.' or c == '!' or c == '?' or c == '\n';
}

/// Returns a freshly allocated slice of Chunks (in `arena`). Single
/// sentence with no terminator → one chunk. Empty input → empty slice.
/// Punctuation attaches to the preceding chunk; newlines are dropped.
pub fn chunkSentences(arena: std.mem.Allocator, text: []const u8) ![]Chunk {
    var out: std.ArrayList(Chunk) = .empty;
    if (text.len == 0) return out.toOwnedSlice(arena);

    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (!isTerminator(c)) continue;
        // Abbreviation-aware: skip `.` that closes Sr./Dr./etc.
        if (c == '.' and isAbbrevDotAt(text, i)) continue;

        // Extend the run over any consecutive trailing terminators so an
        // ellipsis "..." or a "?!" combo emits a single chunk break.
        var j = i + 1;
        while (j < text.len and isTerminator(text[j])) : (j += 1) {}

        // `end_attached` = end of the chunk INCLUDING the run of
        // non-newline punctuation, EXCLUDING any '\n' bytes (we drop
        // newlines on emit — the pause stage will reinsert their slnc).
        var end_attached = i;
        var k = i;
        while (k < j) : (k += 1) {
            if (text[k] != '\n') end_attached = k;
        }
        // If the run was newline-only, the chunk closes at i-1 (i.e.
        // strip the newline entirely). Otherwise include up to the last
        // non-newline terminator.
        const run_has_punct = blk: {
            var m = i;
            while (m < j) : (m += 1) if (text[m] != '\n') break :blk true;
            break :blk false;
        };

        const slice_end: usize = if (run_has_punct) end_attached + 1 else i;
        const raw = trimChunk(text[start..slice_end]);
        if (raw.len != 0) try out.append(arena, .{ .text = raw });

        start = j;
        i = j - 1; // loop will i+=1 → j
    }

    if (start < text.len) {
        const raw = trimChunk(text[start..]);
        if (raw.len != 0) try out.append(arena, .{ .text = raw });
    }

    return out.toOwnedSlice(arena);
}

fn trimChunk(s: []const u8) []const u8 {
    var lo: usize = 0;
    var hi: usize = s.len;
    while (lo < hi and (s[lo] == ' ' or s[lo] == '\t' or s[lo] == '\n' or s[lo] == '\r')) lo += 1;
    while (hi > lo and (s[hi - 1] == ' ' or s[hi - 1] == '\t' or s[hi - 1] == '\n' or s[hi - 1] == '\r')) hi -= 1;
    return s[lo..hi];
}

// ──────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn runProcess(input: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try process(arena, input);
    testing.expectEqualStrings(expected, got) catch |e| {
        std.debug.print("\ninput:    {s}\nexpected: {s}\ngot:      {s}\n", .{ input, expected, got });
        return e;
    };
}

test "empty string returns empty" {
    try runProcess("", "");
}

test "abbreviation Sr." {
    // The period in "Sr." is consumed as part of the abbrev — it's
    // semantically an abbreviation marker, not a sentence terminator.
    try runProcess("Sr. Silva", "Senhor Silva");
}

test "abbreviation does not match mid-word" {
    // "aSr." should NOT expand: Sr. must be at a word start.
    try runProcess("aSr. teste", "aSr. [[slnc 400]] teste");
}

test "abbreviation chain: Dr. + Sra. + R$" {
    try runProcess(
        "Dr. e Sra. devem R$",
        "Doutor e Senhora devem reais",
    );
}

test "number under 100" {
    try runProcess(
        "tenho 42 maçãs",
        "tenho quarenta e dois maçãs",
    );
}

test "number under 1000 (cem)" {
    try runProcess("100", "cem");
}

test "number under 1000 (cento e ...)" {
    try runProcess("123", "cento e vinte e três");
}

test "number 2026" {
    try runProcess("2026", "dois mil e vinte e seis");
}

test "number zero" {
    try runProcess("0", "zero");
}

test "negative number" {
    try runProcess("temperatura -5 graus", "temperatura menos cinco graus");
}

test "number followed by letter is skipped" {
    try runProcess("MP3", "MP3");
}

test "number followed by percent is skipped" {
    try runProcess("50%", "50%");
}

test "comma pause" {
    try runProcess("um, dois", "um, [[slnc 150]] dois");
}

test "sentence pause" {
    try runProcess("vai. agora", "vai. [[slnc 400]] agora");
}

test "trailing punctuation emits pause" {
    try runProcess("acabou.", "acabou. [[slnc 400]] ");
}

test "newline pause" {
    try runProcess("linha 1\nlinha 2", "linha um [[slnc 600]] linha dois");
}

test "multiple punctuation collapses to longest" {
    // ".!" → longest is sentence-ms (400), both chars kept.
    try runProcess("vai!. agora", "vai!. [[slnc 400]] agora");
}

test "ellipsis collapses to single sentence pause" {
    try runProcess("hmm... ok", "hmm... [[slnc 400]] ok");
}

test "comma plus newline keeps newline pause" {
    try runProcess("uma,\ndois", "uma, [[slnc 600]] dois");
}

test "only punctuation" {
    try runProcess("...", "... [[slnc 400]] ");
}

test "mixed abbreviation, number and punctuation" {
    try runProcess(
        "Sr. Silva tem 25 anos, certo?",
        "Senhor Silva tem vinte e cinco anos, [[slnc 150]] certo? [[slnc 400]] ",
    );
}

test "Av. nº and large number" {
    // 1578 = "mil quinhentos e setenta e oito" — Pt-BR uses no "e"
    // between thousands and a non-round hundreds part.
    try runProcess(
        "Av. Paulista, nº 1578.",
        "Avenida Paulista, [[slnc 150]] número mil quinhentos e setenta e oito. [[slnc 400]] ",
    );
}

test "round thousand" {
    try runProcess("3000", "três mil");
}

test "round hundreds inside thousand" {
    try runProcess("1200", "mil e duzentos");
}

test "out of range 0..9999 leaves raw" {
    try runProcess("12345", "12345");
}

test "leading number" {
    try runProcess("7 anões", "sete anões");
}

// ──────────────────────────────────────────────────────────────────────
// v1.2 chunking tests
// ──────────────────────────────────────────────────────────────────────

fn expectChunks(input: []const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try chunkSentences(arena, input);
    testing.expectEqual(expected.len, got.len) catch |e| {
        std.debug.print("\ninput: '{s}'\nexpected {d} chunks, got {d}:\n", .{ input, expected.len, got.len });
        for (got) |ch| std.debug.print("  '{s}'\n", .{ch.text});
        return e;
    };
    for (expected, got) |want, have| {
        testing.expectEqualStrings(want, have.text) catch |e| {
            std.debug.print("\ninput: '{s}'\n", .{input});
            return e;
        };
    }
}

test "chunk single sentence no terminator" {
    try expectChunks("Olá mundo", &.{"Olá mundo"});
}

test "chunk single sentence with period" {
    try expectChunks("Olá mundo.", &.{"Olá mundo."});
}

test "chunk multi sentence" {
    try expectChunks("Um. Dois. Três.", &.{ "Um.", "Dois.", "Três." });
}

test "chunk multi sentence mixed terminators" {
    try expectChunks("Vai? Vai! Vai.", &.{ "Vai?", "Vai!", "Vai." });
}

test "chunk trailing whitespace" {
    try expectChunks("Um.   Dois.  ", &.{ "Um.", "Dois." });
}

test "chunk newlines split" {
    try expectChunks("linha 1\nlinha 2", &.{ "linha 1", "linha 2" });
}

test "chunk only newlines yields empty" {
    try expectChunks("\n\n\n", &.{});
}

test "chunk empty input yields empty" {
    try expectChunks("", &.{});
}

test "chunk abbreviation Sr. does not split" {
    try expectChunks("Sr. Silva chegou. Boa tarde.", &.{ "Sr. Silva chegou.", "Boa tarde." });
}

test "chunk abbreviation Dr. Sra. Av. do not split" {
    try expectChunks(
        "Dr. Souza encontrou Sra. Lima na Av. Paulista.",
        &.{"Dr. Souza encontrou Sra. Lima na Av. Paulista."},
    );
}

test "chunk ellipsis collapses to one split" {
    try expectChunks("hmm... ok.", &.{ "hmm...", "ok." });
}

test "chunk newline after punctuation drops the newline" {
    try expectChunks("Um.\nDois.", &.{ "Um.", "Dois." });
}

test "chunk preserves combined punctuation" {
    try expectChunks("Sério?! Mesmo!?", &.{ "Sério?!", "Mesmo!?" });
}
