// SPDX-License-Identifier: MIT OR Apache-2.0
//
// VoicePicker.swift — SwiftUI dropdown listing the daemon's voices.
//
// VoiceCatalog + VoiceOption live in AgentTTSMenubarCore (pure data).
// This file owns the @MainActor / UserDefaults / SwiftUI side so it
// can stay out of the test/smoke target.

import SwiftUI
import Foundation
import AgentTTSMenubarCore

/// Source of truth for the selected voice. SwiftUI views observe this.
@MainActor
public final class VoicePickerModel: ObservableObject {
    private static let kSelected = "AgentTTSMenubar.selectedVoiceId"

    @Published public var voices: [VoiceOption]
    @Published public var selectedId: String {
        didSet { UserDefaults.standard.set(selectedId, forKey: Self.kSelected) }
    }

    public init() {
        let all = VoiceCatalog.all()
        self.voices = all
        let persisted = UserDefaults.standard.string(forKey: Self.kSelected)
        if let p = persisted, all.contains(where: { $0.id == p }) {
            self.selectedId = p
        } else {
            self.selectedId = all.first?.id ?? "faber"
        }
    }

    public var selected: VoiceOption? {
        voices.first { $0.id == selectedId }
    }

    public func reload() {
        voices = VoiceCatalog.all()
        if !voices.contains(where: { $0.id == selectedId }) {
            selectedId = voices.first?.id ?? "faber"
        }
    }
}

public struct VoicePicker: View {
    @ObservedObject var model: VoicePickerModel

    public init(model: VoicePickerModel) {
        self.model = model
    }

    public var body: some View {
        HStack {
            Text("Voice")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Voice", selection: $model.selectedId) {
                ForEach(model.voices) { v in
                    Text(v.label).tag(v.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
