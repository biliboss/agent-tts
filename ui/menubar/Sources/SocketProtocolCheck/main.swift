// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SocketProtocolCheck — standalone smoke executable that runs the same
// parser assertions as `Tests/AgentTTSMenubarTests/SocketClientTests.swift`
// without depending on XCTest (Xcode-only on macOS Command Line Tools).
//
// Usage:
//   swift run -c release SocketProtocolCheck
//
// Exits 0 on success, non-zero on first failure.

import Foundation
import AgentTTSMenubarCore

func check(_ cond: Bool, _ label: String) {
    if !cond {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
    } else {
        print("ok  \(label)")
    }
}

func checkThrows(_ label: String, _ block: () throws -> Void) {
    do {
        try block()
        fputs("FAIL: \(label) — expected throw\n", stderr)
        exit(1)
    } catch {
        print("ok  \(label) (threw \(type(of: error)))")
    }
}

// MARK: - sanitize

check(SocketClient.sanitize("olá\nmundo\ttab\rcr") == "olá mundo tab cr",
      "sanitize replaces control chars")
check(SocketClient.sanitize("ç ã é ñ 你好") == "ç ã é ñ 你好",
      "sanitize preserves utf-8")

// MARK: - parseOk

do {
    let payload = try SocketClient.parseOk("OK\t42")
    check(payload == "42", "parseOk extracts payload")
} catch {
    fputs("FAIL: parseOk OK should not throw: \(error)\n", stderr)
    exit(1)
}

checkThrows("parseOk throws on ERR\\tboom") {
    _ = try SocketClient.parseOk("ERR\tboom")
}

checkThrows("parseOk throws on WAT\\tweird") {
    _ = try SocketClient.parseOk("WAT\tweird")
}

// MARK: - parseItem v1.1 piper row

if let item = SocketClient.parseItem("ITEM\t7\tpending\tpiper\tfaber\t330\tOlá mundo") {
    check(item.id == "7" && item.state == "pending" && item.engine == "piper"
          && item.voice == "faber" && item.rate == "330" && item.text == "Olá mundo",
          "parseItem v1.1 piper row")
} else {
    fputs("FAIL: parseItem v1.1 piper row returned nil\n", stderr)
    exit(1)
}

// MARK: - parseItem legacy v0.6

if let item = SocketClient.parseItem("ITEM\t3\tplaying\tLuciana\t330\tum dois três") {
    check(item.engine == "say" && item.voice == "Luciana" && item.text == "um dois três",
          "parseItem legacy v0.6 row")
} else {
    fputs("FAIL: parseItem legacy returned nil\n", stderr)
    exit(1)
}

// MARK: - parseItem embedded tabs

if let item = SocketClient.parseItem("ITEM\t9\tpending\tpiper\tfaber\t330\thello\textra") {
    check(item.text == "hello\textra", "parseItem keeps embedded tabs in text")
} else {
    fputs("FAIL: parseItem embedded tabs returned nil\n", stderr)
    exit(1)
}

// MARK: - parseItem invalid rows

check(SocketClient.parseItem("ITEM\t1\tpending\tpiper") == nil,
      "parseItem rejects short row")
check(SocketClient.parseItem("ITEM\t1") == nil,
      "parseItem rejects very short row")
check(SocketClient.parseItem("NOTITEM\t1\tpending\tpiper\tfaber\t330\ttext") == nil,
      "parseItem rejects non-ITEM prefix")

// MARK: - VoiceCatalog

let engines = Set(VoiceCatalog.builtIn.map { $0.engine })
check(engines.contains("say") && engines.contains("piper"),
      "VoiceCatalog built-ins cover say + piper")

let empty = VoiceCatalog.clonedVoices(home: "/tmp/agent-tts-test-nonexistent-\(UUID().uuidString)")
check(empty.isEmpty, "VoiceCatalog clonedVoices returns [] on fake home")

print("---")
print("All SocketProtocolCheck assertions passed.")
