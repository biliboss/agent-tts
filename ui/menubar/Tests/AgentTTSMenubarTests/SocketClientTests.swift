// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SocketClientTests.swift — protocol parser unit tests.
//
// XCTest is Xcode-only on macOS; the standalone Command Line Tools
// toolchain doesn't ship it. We compile the file conditionally so
// `swift build` works in either environment. `swift test` requires
// Xcode (or a Linux toolchain with corelibs-xctest); in CI we run it
// under `xcrun --toolchain default` after installing Xcode.
//
// The same parser surface is exercised by `SocketProtocolCheck` (a
// standalone executable in `Sources/SocketProtocolCheck/`) so a smoke
// pass is available without Xcode.

#if canImport(XCTest)
import XCTest
@testable import AgentTTSMenubarCore

final class SocketClientTests: XCTestCase {

    func testSanitizeReplacesControlChars() {
        let raw = "olá\nmundo\ttab\rcr"
        XCTAssertEqual(SocketClient.sanitize(raw), "olá mundo tab cr")
    }

    func testSanitizePreservesUtf8() {
        let raw = "ç ã é ñ 你好"
        XCTAssertEqual(SocketClient.sanitize(raw), raw)
    }

    func testParseOkExtractsPayload() throws {
        XCTAssertEqual(try SocketClient.parseOk("OK\t42"), "42")
    }

    func testParseOkThrowsOnErr() {
        XCTAssertThrowsError(try SocketClient.parseOk("ERR\tboom")) { e in
            guard case SocketError.daemonError(let msg) = e else {
                return XCTFail("expected daemonError, got \(e)")
            }
            XCTAssertEqual(msg, "boom")
        }
    }

    func testParseOkThrowsOnUnknownLine() {
        XCTAssertThrowsError(try SocketClient.parseOk("WAT\tweird")) { e in
            guard case SocketError.unexpected = e else {
                return XCTFail("expected unexpected, got \(e)")
            }
        }
    }

    func testParseItemV07PiperRow() {
        let line = "ITEM\t7\tpending\tpiper\tfaber\t330\tOlá mundo"
        let item = SocketClient.parseItem(line)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.id, "7")
        XCTAssertEqual(item?.state, "pending")
        XCTAssertEqual(item?.engine, "piper")
        XCTAssertEqual(item?.voice, "faber")
        XCTAssertEqual(item?.rate, "330")
        XCTAssertEqual(item?.text, "Olá mundo")
    }

    func testParseItemLegacyV06Row() {
        let line = "ITEM\t3\tplaying\tLuciana\t330\tum dois três"
        let item = SocketClient.parseItem(line)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.engine, "say")
        XCTAssertEqual(item?.voice, "Luciana")
        XCTAssertEqual(item?.text, "um dois três")
    }

    func testParseItemTextWithEmbeddedTabsRoundTripsBoundary() {
        let line = "ITEM\t9\tpending\tpiper\tfaber\t330\thello\textra"
        let item = SocketClient.parseItem(line)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.text, "hello\textra")
    }

    func testParseItemMissingFieldsReturnsNil() {
        XCTAssertNil(SocketClient.parseItem("ITEM\t1\tpending\tpiper"))
        XCTAssertNil(SocketClient.parseItem("ITEM\t1"))
        XCTAssertNil(SocketClient.parseItem("NOTITEM\t1\tpending\tpiper\tfaber\t330\ttext"))
    }

    func testVoiceCatalogBuiltInsCoverAllEngines() {
        let engines = Set(VoiceCatalog.builtIn.map { $0.engine })
        XCTAssertTrue(engines.contains("say"))
        XCTAssertTrue(engines.contains("piper"))
    }

    func testVoiceCatalogClonedVoicesEmptyOnFakeHome() {
        let result = VoiceCatalog.clonedVoices(home: "/tmp/agent-tts-test-nonexistent-\(UUID().uuidString)")
        XCTAssertTrue(result.isEmpty)
    }

    // v1.10.2 — history ITEM row parser. Mirrors the daemon's 7-column
    // wire shape: id, state, engine, voice, rate, finished_at, text.
    func testParseHistoryItemHappyPath() {
        let line = "ITEM\t5\tdone\tpiper\tfaber\t330\t1780000000\tOlá mundo"
        let item = SocketClient.parseHistoryItem(line)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.id, "5")
        XCTAssertEqual(item?.state, "done")
        XCTAssertEqual(item?.engine, "piper")
        XCTAssertEqual(item?.voice, "faber")
        XCTAssertEqual(item?.rate, "330")
        XCTAssertEqual(item?.finishedAt, "1780000000")
        XCTAssertEqual(item?.text, "Olá mundo")
    }

    func testParseHistoryItemHandlesTabInText() {
        // Daemon sanitizes \t out of text, but parser should still
        // gracefully join the trailing fields with \t.
        let line = "ITEM\t9\tskipped\tsay\tLuciana\t330\t0\thello\textra"
        let item = SocketClient.parseHistoryItem(line)
        XCTAssertEqual(item?.text, "hello\textra")
    }

    func testParseHistoryItemRejectsShortLines() {
        // 6 columns isn't enough — finished_at missing.
        XCTAssertNil(SocketClient.parseHistoryItem("ITEM\t1\tdone\tpiper\tfaber\t330\tboo"))
        XCTAssertNil(SocketClient.parseHistoryItem("ITEM\t1"))
        XCTAssertNil(SocketClient.parseHistoryItem("NOTITEM\t1\tdone\tpiper\tfaber\t330\t0\ttext"))
    }
}
#endif
