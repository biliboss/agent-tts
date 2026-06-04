// SPDX-License-Identifier: MIT OR Apache-2.0
//
// FloatingPlayer.swift — always-on-top compact NSPanel that shows the
// currently playing item plus pause / resume / skip / replay controls.
//
// Lifecycle:
//   1. AppDelegate polls `agent-tts queue` every 750 ms.
//   2. When a "playing" item appears AND the user has the floating widget
//      enabled (Settings toggle persisted to UserDefaults), AppDelegate
//      asks FloatingPlayerController to show().
//   3. When the queue empties, AppDelegate calls hide().
//   4. The panel's pause/resume button toggles its label by querying the
//      daemon — the FloatingPlayer doesn't keep its own paused state.
//
// Why NSPanel and not NSWindow:
//   - NSPanel sits on top across spaces with `level = .floating`.
//   - `styleMask = [.hudWindow, .titled, .closable, .nonactivatingPanel]`
//     gives the dark HUD look (small font, semi-transparent) without
//     stealing focus from the app the user is typing in.
//
// Position persists to UserDefaults under `AgentTTSMenubar.floatingFrame`
// (NSStringFromRect) so the user's preferred screen corner is sticky.

import AppKit
import SwiftUI
import AgentTTSMenubarCore

@MainActor
public final class FloatingPlayerModel: ObservableObject {
    @Published public var currentItem: QueueItem?
    @Published public var isPaused: Bool = false
    @Published public var lastError: String?

    private let client: SocketClient

    public init(client: SocketClient = SocketClient()) {
        self.client = client
    }

    /// Called by AppDelegate's polling loop. We swap the published item so
    /// SwiftUI redraws; pause flag is reset whenever the playing item id
    /// changes (the daemon clears its pause state per playback).
    public func update(playing: QueueItem?) {
        if let previous = currentItem, let next = playing, previous.id != next.id {
            isPaused = false
        } else if playing == nil {
            isPaused = false
        }
        currentItem = playing
    }

    public func togglePause() {
        do {
            if isPaused {
                let id = try client.resumePlayback()
                if id == 0 {
                    isPaused = false
                } else {
                    isPaused = false
                }
            } else {
                let id = try client.pause()
                if id != 0 {
                    isPaused = true
                }
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    public func skip() {
        do {
            _ = try client.skip()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Replay re-enqueues the currently playing item by id so the same
    /// utterance plays again after the in-flight one wraps. Falls back to
    /// no-op when there's no current item (button disabled in that case).
    public func replayCurrent() {
        guard let item = currentItem, let id = UInt64(item.id) else { return }
        do {
            _ = try client.replay(id: id)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }
}

public struct FloatingPlayerView: View {
    @ObservedObject var model: FloatingPlayerModel

    public init(model: FloatingPlayerModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentItem?.text ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let item = model.currentItem {
                    Text("\(item.engine) · \(item.voice) · \(item.rate) wpm")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("idle")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Pause / Resume.
            Button(action: model.togglePause) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .disabled(model.currentItem == nil)
            .help(model.isPaused ? "Resume" : "Pause")

            // Skip.
            Button(action: model.skip) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.borderless)
            .disabled(model.currentItem == nil)
            .help("Skip")

            // Replay (re-enqueues the active item).
            Button(action: model.replayCurrent) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.currentItem == nil)
            .help("Replay this item")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 320, height: 60)
    }
}

@MainActor
public final class FloatingPlayerController {
    private static let kFrame = "AgentTTSMenubar.floatingFrame"
    private static let kEnabled = "AgentTTSMenubar.floatingPlayerEnabled"

    public let model = FloatingPlayerModel()
    private var panel: NSPanel?

    public init() {}

    /// User-toggled enable flag, persisted to UserDefaults. Default OFF so
    /// upgrading from v1.10.1 doesn't surprise anyone with a new window.
    public static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: kEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: kEnabled) }
    }

    public func show() {
        if let p = panel {
            if !p.isVisible {
                p.orderFrontRegardless()
            }
            return
        }
        let initialFrame = Self.persistedFrame() ?? NSRect(x: 80, y: 80, width: 320, height: 60)
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .hudWindow, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "agent-tts"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentViewController = NSHostingController(rootView: FloatingPlayerView(model: model))
        panel.setFrame(initialFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        // Persist frame on move/resize. NSPanel doesn't expose a clean
        // delegate hook for "frame changed by user" outside the window
        // delegate, but observing the notification works and avoids
        // wiring an NSWindowDelegate stub.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelMoved(_:)),
            name: NSWindow.didMoveNotification,
            object: panel
        )
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    @objc private func panelMoved(_ note: Notification) {
        guard let p = panel else { return }
        let frame = NSStringFromRect(p.frame)
        UserDefaults.standard.set(frame, forKey: Self.kFrame)
    }

    private static func persistedFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: kFrame) else { return nil }
        let r = NSRectFromString(s)
        if r.size.width <= 0 || r.size.height <= 0 { return nil }
        return r
    }
}
