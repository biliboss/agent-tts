// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SocketClient.swift — wire-protocol bridge to the agent-tts daemon.
//
// The daemon listens on `~/.cache/agent-tts/sock` (UNIX stream socket).
// Wire is line-delimited TSV — see `src/ipc.zig` for the canonical spec.
// Implemented ops:
//   ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<text>\n  (v1.1 6-field)
//   QUEUE\n         → ITEM lines + END
//   SKIP\n          → OK\t<id>
//   CLEAR\n         → OK\t<count>
//
// We use raw POSIX sockets (Darwin module). Network.framework's
// NWConnection does AF_UNIX, but its callback model is awkward for the
// synchronous request/response pattern the daemon uses, and adds latency
// on the warm path the CLI publishes as 0.2-0.4 ms.

import Foundation
import Darwin

/// One row returned by `queue()`. Mirrors `client.zig` `QueueItem`.
public struct QueueItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let state: String
    public let engine: String
    public let voice: String
    public let rate: String
    public let text: String

    public init(id: String, state: String, engine: String, voice: String, rate: String, text: String) {
        self.id = id
        self.state = state
        self.engine = engine
        self.voice = voice
        self.rate = rate
        self.text = text
    }
}

public enum SocketError: Error, LocalizedError {
    case daemonUnreachable(String)
    case daemonError(String)
    case unexpected(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .daemonUnreachable(let m): return "daemon unreachable: \(m)"
        case .daemonError(let m):       return "daemon error: \(m)"
        case .unexpected(let m):        return "unexpected: \(m)"
        case .malformed(let m):         return "malformed: \(m)"
        }
    }
}

/// Stateless client. Each call opens, talks, closes — same connection
/// shape the CLI uses (per `src/client.zig`).
public struct SocketClient {
    public let socketPath: String

    public init(socketPath: String? = nil) {
        if let p = socketPath {
            self.socketPath = p
        } else {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
            self.socketPath = "\(home)/.cache/agent-tts/sock"
        }
    }

    // MARK: - Public ops

    @discardableResult
    public func enqueue(text: String, engine: String = "piper", lang: String = "auto",
                        voice: String = "faber", rate: UInt32 = 330) throws -> String {
        let cleaned = Self.sanitize(text)
        let line = "ENQUEUE\t\(engine)\t\(lang)\t\(voice)\t\(rate)\t\(cleaned)\n"
        let reply = try roundTrip(line)
        return try Self.parseOk(reply)
    }

    public func queue() throws -> [QueueItem] {
        let lines = try roundTripMulti("QUEUE\n")
        var out: [QueueItem] = []
        for line in lines {
            if line == "END" { break }
            if line.hasPrefix("ERR\t") {
                throw SocketError.daemonError(String(line.dropFirst(4)))
            }
            if let item = Self.parseItem(line) {
                out.append(item)
            }
        }
        return out
    }

    @discardableResult
    public func skip() throws -> UInt64 {
        let reply = try roundTrip("SKIP\n")
        let idStr = try Self.parseOk(reply)
        return UInt64(idStr) ?? 0
    }

    @discardableResult
    public func clear() throws -> UInt64 {
        let reply = try roundTrip("CLEAR\n")
        let idStr = try Self.parseOk(reply)
        return UInt64(idStr) ?? 0
    }

    // MARK: - Parsing (visible for tests)

    /// Replace \n / \t / \r with space — daemon refuses them mid-text.
    /// Matches `ipc.sanitizeText` in `src/ipc.zig`.
    public static func sanitize(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            switch ch {
            case "\n", "\t", "\r": out.append(" ")
            default: out.append(ch)
            }
        }
        return out
    }

    /// Parse `OK\t<payload>` → payload. Throws on `ERR\t...` or anything else.
    public static func parseOk(_ line: String) throws -> String {
        if line.hasPrefix("OK\t") {
            return String(line.dropFirst(3))
        }
        if line.hasPrefix("ERR\t") {
            throw SocketError.daemonError(String(line.dropFirst(4)))
        }
        throw SocketError.unexpected(line)
    }

    /// Parse one `ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>` line.
    /// Falls back to legacy v0.6 layout (no engine) when the third field
    /// doesn't look like a known engine — same trick as `client.zig`.
    public static func parseItem(_ line: String) -> QueueItem? {
        guard line.hasPrefix("ITEM\t") else { return nil }
        let rest = String(line.dropFirst(5))
        let parts = rest.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 5 else { return nil }
        let id = String(parts[0])
        let state = String(parts[1])
        let third = String(parts[2])
        if third == "say" || third == "piper" || third == "cloned" {
            guard parts.count >= 6 else { return nil }
            let voice = String(parts[3])
            let rate = String(parts[4])
            let text = parts[5...].joined(separator: "\t")
            return QueueItem(id: id, state: state, engine: third, voice: voice, rate: rate, text: text)
        } else {
            // legacy: third field is the voice
            let voice = third
            let rate = String(parts[3])
            let text = parts[4...].joined(separator: "\t")
            return QueueItem(id: id, state: state, engine: "say", voice: voice, rate: rate, text: text)
        }
    }

    // MARK: - Socket I/O

    private func roundTrip(_ request: String) throws -> String {
        let fd = try connect()
        defer { Darwin.close(fd) }
        try writeAll(fd, request)
        return try readLine(fd)
    }

    private func roundTripMulti(_ request: String) throws -> [String] {
        let fd = try connect()
        defer { Darwin.close(fd) }
        try writeAll(fd, request)

        var buffer = ""
        var out: [String] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { buf -> Int in
                Darwin.read(fd, buf.baseAddress, buf.count)
            }
            if n < 0 {
                throw SocketError.daemonUnreachable("read errno=\(errno)")
            }
            if n == 0 { break } // EOF
            if let s = String(bytes: chunk.prefix(n), encoding: .utf8) {
                buffer.append(s)
            }
            // Drain whole lines
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl])
                buffer.removeSubrange(...nl)
                out.append(line)
                if line == "END" { return out }
            }
        }
        // Final flush if daemon closed without trailing \n
        if !buffer.isEmpty { out.append(buffer) }
        return out
    }

    private func connect() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw SocketError.daemonUnreachable("socket() errno=\(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // 104-byte path budget on macOS. Daemon writes to
        // ~/.cache/agent-tts/sock so this fits comfortably.
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw SocketError.daemonUnreachable("socket path too long: \(socketPath)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cstr in
                for (i, b) in pathBytes.enumerated() {
                    cstr[i] = CChar(bitPattern: b)
                }
                cstr[pathBytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        if rc != 0 {
            let e = errno
            Darwin.close(fd)
            throw SocketError.daemonUnreachable("connect() errno=\(e) at \(socketPath)")
        }
        return fd
    }

    private func writeAll(_ fd: Int32, _ s: String) throws {
        let bytes = Array(s.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf -> Int in
                Darwin.write(fd, buf.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.daemonUnreachable("write errno=\(errno)")
            }
            written += n
        }
    }

    /// Read a single \n-delimited line.
    private func readLine(_ fd: Int32) throws -> String {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.daemonUnreachable("read errno=\(errno)")
            }
            if n == 0 {
                throw SocketError.unexpected("daemon closed before sending a line")
            }
            if byte == 0x0A { break } // \n
            buffer.append(byte)
        }
        return String(bytes: buffer, encoding: .utf8) ?? ""
    }
}
