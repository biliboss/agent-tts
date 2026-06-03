// SPDX-License-Identifier: MIT OR Apache-2.0
//
// VoiceCatalog.swift — pure data + filesystem probe for available voices.
// No AppKit / no SwiftUI here so the type is reusable from tests + smoke
// runners. The SwiftUI picker (`VoicePicker.swift` in the app target)
// observes a model that reads from this catalogue.

import Foundation

/// One row in the dropdown.
public struct VoiceOption: Hashable, Identifiable, Sendable {
    public let id: String        // slug used on the wire
    public let label: String     // human label shown to user
    public let engine: String    // "say" | "piper" | "cloned"
    public let lang: String      // "auto" | "pt" | "en"

    public init(id: String, label: String, engine: String, lang: String) {
        self.id = id
        self.label = label
        self.engine = engine
        self.lang = lang
    }
}

/// Discoverable voice catalogue. Built-ins first, cloned voices appended
/// from disk. Defensive: a missing/unreadable voices dir just means no
/// cloned voices, never an error.
public enum VoiceCatalog {
    public static let builtIn: [VoiceOption] = [
        VoiceOption(id: "Luciana",  label: "Luciana (say, pt)",  engine: "say",   lang: "pt"),
        VoiceOption(id: "Felipe",   label: "Felipe (say, pt)",   engine: "say",   lang: "pt"),
        VoiceOption(id: "faber",    label: "Faber (piper, pt)",  engine: "piper", lang: "pt"),
        VoiceOption(id: "amy",      label: "Amy (piper, en)",    engine: "piper", lang: "en"),
    ]

    /// Read `~/.cache/agent-tts/voices/<slug>/metadata.json` and emit
    /// one VoiceOption per matching directory. Same probe `client.zig`
    /// uses for engine routing.
    public static func clonedVoices(home: String? = nil) -> [VoiceOption] {
        let homeDir = home ?? (ProcessInfo.processInfo.environment["HOME"] ?? "/tmp")
        let voicesDir = "\(homeDir)/.cache/agent-tts/voices"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: voicesDir) else {
            return []
        }
        var out: [VoiceOption] = []
        for slug in entries.sorted() {
            // Skip the bundled piper voices that live as raw .onnx files —
            // those are the built-ins above; cloned voices are directories
            // with metadata.json inside.
            let meta = "\(voicesDir)/\(slug)/metadata.json"
            if fm.fileExists(atPath: meta) {
                out.append(VoiceOption(
                    id: slug,
                    label: "\(slug) (cloned)",
                    engine: "cloned",
                    lang: "auto"
                ))
            }
        }
        return out
    }

    public static func all() -> [VoiceOption] {
        return builtIn + clonedVoices()
    }
}
