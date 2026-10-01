//
//  SceneCapture.swift
//  vr
//
//  Photo and video capture of the AR scene, saved to the user's photo library.
//

import Foundation
import OSLog
import Observation
import Photos
import RealityKit
import ReplayKit
import UIKit

/// Takes stills and records video, then hands the result to Photos.
///
/// Stills come straight from RealityKit's own renderer, so they contain the
/// camera feed and the car but none of the on-screen controls. Video uses
/// ReplayKit, which records what the screen actually shows — the controls are
/// part of the clip, the way a gameplay recording normally is.
@MainActor
@Observable
final class SceneCapture {

    enum Status: Equatable {
        case idle
        case busy(String)
        case success(String)
        case failure(String)
    }

    private(set) var status: Status = .idle
    private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            onRecordingChange?(isRecording)
        }
    }

    /// Fired on every start and stop, including the ones that come from going
    /// to the background or from ReplayKit refusing. ReplayKit starts
    /// asynchronously, so nothing can infer this from the toggle returning.
    var onRecordingChange: ((Bool) -> Void)?
    private(set) var recordingDuration: TimeInterval = 0
    /// True while a photo is being rendered, so the shutter button can disable.
    private(set) var isCapturingPhoto = false

    private let recorder = RPScreenRecorder.shared()
    private var recordingStart: Date?
    private var timerTask: Task<Void, Never>?
    private var statusResetTask: Task<Void, Never>?

    var isVideoRecordingAvailable: Bool { recorder.isAvailable }

    // MARK: - Photo

    /// `onRendered` runs as soon as the frame has been captured, before it is
    /// saved, so anything hidden for the shot can come straight back.
    /// `onCaptured` runs only when a frame was actually produced.
    func capturePhoto(from arView: ARView, onRendered: (() -> Void)? = nil, onCaptured: (() -> Void)? = nil) {
        guard !isCapturingPhoto else { onRendered?(); return }
        isCapturingPhoto = true
        report(.busy("Saving photo…"))

        arView.snapshot(saveToHDR: false) { [weak self] image in
            Task { @MainActor in
                onRendered?()
                guard let self else { return }
                self.isCapturingPhoto = false
                guard let image else {
                    self.report(.failure("Couldn't capture the scene."))
                    Haptics.failure()
                    return
                }
                onCaptured?()
                await self.savePhoto(image)
            }
        }
    }

    private func savePhoto(_ image: UIImage) async {
        guard await hasPhotoLibraryAccess() else {
            report(.failure("Allow photo access in Settings to save."))
            Haptics.failure()
            return
        }
        do {
            try await performPhotoLibraryChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            report(.success("Photo saved"))
            Haptics.success()
        } catch {
            AppLog.capture.error("Saving photo failed: \(error.localizedDescription, privacy: .public)")
            report(.failure("Couldn't save the photo."))
            Haptics.failure()
        }
    }

    // MARK: - Video

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard recorder.isAvailable else {
            report(.failure("Screen recording isn't available right now."))
            Haptics.failure()
            return
        }

        recorder.isMicrophoneEnabled = false
        report(.busy("Starting recording…"))

        recorder.startRecording { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.report(.failure(Self.describe(error)))
                    Haptics.failure()
                    return
                }
                self.isRecording = true
                self.recordingStart = Date()
                self.recordingDuration = 0
                self.report(.idle)
                Haptics.light()
                self.startDurationTimer()
            }
        }
    }

    /// Stops and saves. Safe to call when nothing is recording.
    func stopRecording() {
        guard isRecording || recorder.isRecording else { return }

        stopDurationTimer()
        isRecording = false
        recordingStart = nil
        report(.busy("Saving video…"))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ARDrive-\(UUID().uuidString).mp4")

        recorder.stopRecording(withOutput: url) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.report(.failure(Self.describe(error)))
                    Haptics.failure()
                    Self.discard(url)
                    return
                }
                await self.saveVideo(at: url)
            }
        }
    }

    private func saveVideo(at url: URL) async {
        defer { Self.discard(url) }

        guard await hasPhotoLibraryAccess() else {
            report(.failure("Allow photo access in Settings to save."))
            Haptics.failure()
            return
        }
        do {
            try await performPhotoLibraryChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .video, fileURL: url, options: nil)
            }
            report(.success("Video saved"))
            Haptics.success()
        } catch {
            AppLog.capture.error("Saving video failed: \(error.localizedDescription, privacy: .public)")
            report(.failure("Couldn't save the video."))
            Haptics.failure()
        }
    }

    private func startDurationTimer() {
        stopDurationTimer()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let start = self.recordingStart else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Photo library plumbing

    private func hasPhotoLibraryAccess() async -> Bool {
        // Add-only access: the app never needs to read the user's library.
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return granted == .authorized || granted == .limited
        default:
            return false
        }
    }

    private func performPhotoLibraryChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                }
            }
        }
    }

    private static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func describe(_ error: Error) -> String {
        switch RPRecordingErrorCode(rawValue: (error as NSError).code) {
        case .userDeclined:        return "Screen recording was declined."
        case .disabled:            return "Screen recording is turned off for this device."
        case .insufficientStorage: return "Not enough space to record."
        case .failedToSave:        return "The recording couldn't be saved."
        default:                   return "Recording failed. Try again."
        }
    }

    // MARK: - Status

    private func report(_ new: Status) {
        status = new
        statusResetTask?.cancel()

        switch new {
        case .success, .failure:
            statusResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                self?.status = .idle
            }
        case .idle, .busy:
            break
        }
    }
}
