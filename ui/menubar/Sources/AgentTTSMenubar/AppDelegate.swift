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
