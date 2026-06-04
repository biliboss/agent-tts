// SPDX-License-Identifier: MIT OR Apache-2.0
//
// VoiceRecorder.swift — thin AVAudioRecorder wrapper for the v1.10.3 Clone
// my voice window. macOS-only.
//
// We capture mono 22 050 Hz, 16-bit signed little-endian PCM in a RIFF/WAVE
// container — the exact shape `src/voice.zig::sniffWav` validates and the
// XTTS-v2 sidecar consumes natively. Mono saves bandwidth + the sidecar
// converts internally anyway. 22 050 Hz matches Faber's training rate so the
// resulting clone aligns with the rest of the catalog.
//
// Threading: AVAudioRecorder calls back on its own queue, but the recorder
// object itself is owned by @MainActor SwiftUI views. We expose a `peakLevel()`
// helper that updateMeters() + averagePower() on the foreground — SwiftUI
// polls it from a timer in CloneVoiceWindow.
//
// Permissions: AVCaptureDevice.authorizationStatus(for: .audio) gates the
// first-launch prompt. Denied → we surface an actionable error pointing the
// user at System Settings → Privacy → Microphone. We avoid AVAudioSession
// (iOS-only) — macOS lets AVAudioRecorder grab the default input directly.

import Foundation
import AVFoundation

/// Result of a recording session. Returned by `stop()`.
public struct VoiceRecordingResult: Sendable {
    public let url: URL
    public let duration: TimeInterval
}

public enum VoiceRecorderError: Error, LocalizedError {
    case permissionDenied
    case recorderUnavailable(String)
    case alreadyRecording
    case notRecording
    case fileMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied. Grant it in System Settings → Privacy & Security → Microphone, then reopen this window."
        case .recorderUnavailable(let m):
            return "Recorder unavailable: \(m)"
        case .alreadyRecording:
            return "Already recording."
        case .notRecording:
            return "Nothing to stop — recording hasn't started."
        case .fileMissing(let u):
            return "Recording file missing at \(u.path)."
        }
    }
}

@MainActor
public final class VoiceRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var outputURL: URL?

    public override init() {
        super.init()
    }

    /// Are we currently recording?
    public var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    /// Elapsed recording time in seconds (0 when idle).
    public func duration() -> TimeInterval {
        guard let started = startedAt else { return 0 }
        return Date().timeIntervalSince(started)
    }

    /// Linear 0…1 peak amplitude for the VU meter. Calls `updateMeters()` so
    /// the underlying recorder refreshes its sample window first. Returns 0
    /// when not recording so the UI collapses cleanly.
    public func peakLevel() -> Float {
        guard let rec = recorder, rec.isRecording else { return 0 }
        rec.updateMeters()
        // averagePower(forChannel:) is in dB, with 0 = full-scale and –160 = silence.
        // Map –50 … 0 dB → 0 … 1 so the meter has useful resolution for speech
        // (which lives around –30 dB).
        let db = rec.averagePower(forChannel: 0)
        let normalized = max(0, min(1, (db + 50) / 50))
        return normalized
    }

    /// Request microphone permission. Calls completion on the main actor with
    /// the resolved boolean. Safe to invoke repeatedly — Apple caches.
    public static func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        @unknown default:
            completion(false)
        }
    }

    /// Synchronous permission probe — useful for the UI to colour the Record
    /// button before the user clicks anything.
    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Begin recording into a fresh tmp file. Returns the URL the WAV will
    /// land at on `stop()`.
    @discardableResult
    public func start() throws -> URL {
        if isRecording { throw VoiceRecorderError.alreadyRecording }
        guard Self.hasPermission else { throw VoiceRecorderError.permissionDenied }

        // The output path is stable for the session so the caller can also
        // listen to the produced WAV if they want a "preview before save"
        // affordance in a later milestone.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-tts-clone-\(UUID().uuidString).wav")

        // 22 050 Hz mono PCM s16le — matches Faber + what voice.zig::sniffWav expects.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            let rec = try AVAudioRecorder(url: tmp, settings: settings)
            rec.isMeteringEnabled = true
            rec.delegate = self
            if !rec.prepareToRecord() {
                throw VoiceRecorderError.recorderUnavailable("prepareToRecord() returned false")
            }
            if !rec.record() {
                throw VoiceRecorderError.recorderUnavailable("record() returned false")
            }
            recorder = rec
            outputURL = tmp
            startedAt = Date()
            return tmp
        } catch let e as VoiceRecorderError {
            throw e
        } catch {
            throw VoiceRecorderError.recorderUnavailable(String(describing: error))
        }
    }

    /// Stop the active recording. Returns the produced file URL + measured
    /// duration. Throws if the recorder is idle or the file went missing.
    @discardableResult
    public func stop() throws -> VoiceRecordingResult {
        guard let rec = recorder, rec.isRecording else { throw VoiceRecorderError.notRecording }
        let elapsed = duration()
        rec.stop()
        guard let url = outputURL, FileManager.default.fileExists(atPath: url.path) else {
            throw VoiceRecorderError.fileMissing(outputURL ?? URL(fileURLWithPath: "/dev/null"))
        }
        recorder = nil
        startedAt = nil
        // Keep outputURL around for the caller to read until they discard us.
        return VoiceRecordingResult(url: url, duration: elapsed)
    }

    /// Abandon the current recording, deleting the partial file. Safe to call
    /// when idle.
    public func cancel() {
        if let rec = recorder, rec.isRecording { rec.stop() }
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        startedAt = nil
        outputURL = nil
    }
}

extension VoiceRecorder: AVAudioRecorderDelegate {
    // AVAudioRecorder may finish unexpectedly (interruption, encoder error).
    // We don't expose a public callback yet — the SwiftUI poll-based timer
    // catches it when `isRecording` flips false. Hook stays in place so the
    // delegate is non-nil (some AVF builds expect a delegate to be set when
    // metering is enabled).
    nonisolated public func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        // no-op
        _ = flag
    }
}
