// SPDX-License-Identifier: MIT OR Apache-2.0
//
// QueueView.swift — live pending/playing list + Skip + Clear.
//
// Polls `SocketClient.queue()` every 750 ms while the popover is open.
// Click-to-skip is wired to `SocketClient.skip()` — v1.10 only the head
// of the queue can be killed (matches daemon SKIP semantics; see
// `src/daemon.zig`). The row UI affords per-id skip for v1.10.1.

import SwiftUI
import AgentTTSMenubarCore

@MainActor
public final class QueueModel: ObservableObject {
    @Published public var items: [QueueItem] = []
    @Published public var error: String? = nil
    @Published public var lastPollMs: Double = 0

    private let client: SocketClient
    private var timer: Timer?

    public init(client: SocketClient = SocketClient()) {
        self.client = client
    }

    public func startPolling() {
        stopPolling()
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    public func refreshNow() {
        let t0 = Date()
        do {
            let next = try client.queue()
            self.items = next
            self.error = nil
        } catch {
            self.items = []
            self.error = String(describing: error)
        }
        self.lastPollMs = Date().timeIntervalSince(t0) * 1000
    }

    public func skip() {
        do {
            _ = try client.skip()
            refreshNow()
        } catch {
            self.error = String(describing: error)
        }
    }

    public func clear() {
        do {
            _ = try client.clear()
            refreshNow()
        } catch {
            self.error = String(describing: error)
        }
    }
}

public struct QueueView: View {
    @ObservedObject var model: QueueModel
    @ObservedObject var voiceModel: VoicePickerModel

    public init(model: QueueModel, voiceModel: VoicePickerModel) {
        self.model = model
        self.voiceModel = voiceModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VoicePicker(model: voiceModel)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 320, height: 420)
    }

    // MARK: header

    private var header: some View {
        HStack {
            Text("agent-tts")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if let err = model.error {
            VStack(alignment: .leading, spacing: 6) {
                Text("Daemon offline")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Start it with `agent-tts daemon` or `agent-tts daemon install`.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.items.isEmpty {
            VStack {
                Spacer()
                Text("queue empty")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { item in
                        QueueRow(item: item) {
                            // v1.10: clicking only the playing row works; pending
                            // rows show the chrome for v1.10.1.
                            if item.state == "playing" {
                                model.skip()
                            }
                        }
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button(action: model.skip) {
                Label("Skip", systemImage: "forward.fill")
            }
            Button(action: model.clear) {
                Label("Clear", systemImage: "trash")
            }
            Spacer()
            Text(String(format: "%.1f ms", model.lastPollMs))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(alignment: .top, spacing: 8) {
                stateBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(item.engine) · \(item.voice) · \(item.rate) wpm")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("#\(item.id)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var stateBadge: some View {
        Circle()
            .fill(item.state == "playing" ? Color.green : Color.gray)
            .frame(width: 8, height: 8)
            .padding(.top, 4)
    }
}
