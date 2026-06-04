// SPDX-License-Identifier: MIT OR Apache-2.0
//
// AppDelegate.swift — NSStatusItem host + SwiftUI popover.
//
// This is a NSApplication-based entry point because a pure SwiftUI App
// scene tree wants a Window to hang off, while a menubar-only app must
// be `LSUIElement` and dispatch from NSStatusItem. Cleanest path is the
// classic AppDelegate + NSStatusBar pattern.
//
// Lifecycle:
//   1. applicationDidFinishLaunching → create status item + popover
//   2. status button click → toggle popover
//   3. popover open → QueueModel.startPolling()
//   4. popover close → QueueModel.stopPolling() (saves IPC traffic)

import AppKit
import SwiftUI
import AgentTTSMenubarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let queueModel = QueueModel()
    private let voiceModel = VoicePickerModel()
    // v1.10.2 — floating player overlay (always-on-top NSPanel).
    private let floatingPlayer = FloatingPlayerController()
    // Lightweight client for the polling timer so we don't reach into the
    // QueueModel (which polls only while the popover is open).
    private let floatingClient = SocketClient()
    private var floatingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the dock icon / app menu. We're menubar-only.
        // (The Info.plist LSUIElement key would do the same; setting here
        // also works for `swift run` invocations without a bundle.)
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Use a speaker icon — same affordance the daemon's audio role
            // implies. Falls back to text if the SF Symbol is missing on
            // older macOS (we require 14+, so this should always succeed).
            if let image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "agent-tts") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "TTS"
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 420)
        let content = QueueView(model: queueModel, voiceModel: voiceModel)
        popover.contentViewController = NSHostingController(rootView: content)

        // v1.10.2 — start the floating-player polling loop regardless of
        // popover state. It only spawns IPC calls (no UI) until a playing
        // item appears AND the user has enabled the widget. 750 ms keeps
        // the daemon load similar to the popover's polling cadence.
        startFloatingPolling()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            queueModel.stopPolling()
        } else {
            voiceModel.reload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            queueModel.startPolling()
            // Bring focus so keyboard works inside the popover.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // v1.10.2 — floating widget polling. Tick every 750 ms, look for the
    // first "playing" row in the daemon's queue, update the floating
    // model, and show/hide the panel based on item presence × user toggle.
    private func startFloatingPolling() {
        floatingTimer?.invalidate()
        floatingTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickFloating() }
        }
    }

    private func tickFloating() {
        let playing: QueueItem?
        do {
            let items = try floatingClient.queue()
            playing = items.first(where: { $0.state == "playing" })
        } catch {
            // Daemon not running — clear UI and short-circuit.
            playing = nil
        }
        floatingPlayer.model.update(playing: playing)

        let userEnabled = FloatingPlayerController.enabled
        if let _ = playing, userEnabled {
            floatingPlayer.show()
        } else {
            floatingPlayer.hide()
        }
    }
}

// MARK: - Entry point

@main
struct AgentTTSMenubarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
