//
//  SpeechRecognition.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import Combine
import Foundation
@preconcurrency import Speech
import AVFoundation

@MainActor
public final class SpeechRecognitionManager: NSObject, ObservableObject {
    public static let shared = SpeechRecognitionManager()

    @Published public private(set) var recognizedText: String = ""
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var isAuthorized: Bool = false
    @Published public private(set) var statusMessage: String = ""
    @Published public private(set) var lastError: String? = nil

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    public var onSentenceRecognized: ((String) -> Void)?

    private var lastEmittedSentence: String = ""
    private var sentenceWorkItem: DispatchWorkItem?

    // Prevent rapid restart loops
    private var lastStopTime: Date?
    private let minimumRestartInterval: TimeInterval = 1.0

    private override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(
            locale: Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
        )

        Task { @MainActor [weak self] in
            let perms = PermissionManager.checkPermissions()
            self?.isAuthorized = perms.speechRecognition && perms.microphone
        }
    }

    public func start() {
        startRecording()
    }

    public func startRecording() {
        guard !isRecording else { return }

        // Perform all permission checks on MainActor to avoid concurrency issues
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            let currentPerms = PermissionManager.checkPermissions()
            let hasFullAccess = currentPerms.microphone && currentPerms.speechRecognition
            
            // Update state immediately
            if self.isAuthorized != hasFullAccess {
                self.isAuthorized = hasFullAccess
            }

            // Check authorization status for "Not Determined" specifically
            let authStatus = SFSpeechRecognizer.authorizationStatus()
            if authStatus == .notDetermined {
                print("Speech recognition permission not determined - requesting...")
                PermissionManager.requestSpeechRecognitionPermission { [weak self] granted in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.isAuthorized = granted
                        if granted {
                            self.startRecording()
                        }
                    }
                }
                return
            }

            guard hasFullAccess else {
                print("Speech recognition not authorized. Mic: \(currentPerms.microphone), Speech: \(currentPerms.speechRecognition)")
                return
            }

            await self.performStartRecordingAsync()
        }
    }

    @MainActor
    private func performStartRecordingAsync() async {
        guard !isRecording else { return }
        guard isAuthorized else { return }
        isRecording = true
        performStartRecording()
    }

    private func performStartRecording() {
        guard !isRecording else {
            print("[SpeechRecognition] Already recording, skipping")
            return
        }
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("[SpeechRecognition] Speech recognizer not available")
            return
        }

        let wasRecording = isRecording
        isRecording = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { [weak self] in
                    if let self = self { self.isRecording = wasRecording }
                }
                return
            }

            // Configure audio session
            let audioSession = AVAudioSession.sharedInstance()
            do {
                // Important: Use .mixWithOthers so we don't kill background audio,
                // but we also need to be careful about volume ducking.
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .measurement, // 'measurement' often works better for recognition than 'default'
                    options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker]
                )
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                print("Audio session error: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.isRecording = wasRecording
                }
                return
            }

            // Recognition request
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.taskHint = .dictation
            request.shouldReportPartialResults = true
            
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            // Audio engine
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)

            guard format.sampleRate > 0 else {
                print("Invalid audio format")
                DispatchQueue.main.async { [weak self] in
                    self?.isRecording = wasRecording
                }
                return
            }

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buf, _ in
                request?.append(buf)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.recognitionRequest = request
                self.audioEngine = engine
                self.statusMessage = "Audio engine prepared"
            }

            // Start engine
            engine.prepare()
            do {
                try engine.start()
            } catch {
                print("Audio engine start failed: \(error.localizedDescription)")
                input.removeTap(onBus: 0)
                DispatchQueue.main.async { [weak self] in
                    self?.isRecording = wasRecording
                }
                return
            }

            let unsafeRecognizer = recognizer

            // Recognition task
            let task = unsafeRecognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                var shouldStop = false

                if let result = result {
                    let text = result.bestTranscription.formattedString
                    let isFinal = result.isFinal
                    DispatchQueue.main.async { [weak self, text, isFinal] in
                        guard let self = self else { return }
                        self.recognizedText = text
                        self.maybeEmitSentence(from: text, isFinal: isFinal)
                    }
                    if isFinal { shouldStop = true }
                }

                if let error = error as NSError? {
                    DispatchQueue.main.async { [weak self] in
                        // Ignore "No speech detected" errors often thrown when stopping manually
                        if error.domain == "kAFAssistantErrorDomain" && error.code == 1110 {
                            // No speech detected, not critical
                        } else {
                            self?.lastError = error.localizedDescription
                            self?.statusMessage = "Recognition error: \(error.localizedDescription)"
                        }
                    }
                    
                    // Handle common "recognition canceled" error (216) gracefully
                    if error.domain != "kAFAssistantErrorDomain" || error.code != 216 {
                        print("Recognition error detail: \(error)")
                    }
                    shouldStop = true
                }

                if shouldStop {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.handleRecognitionStop()
                    }
                }
            }

            DispatchQueue.main.async(qos: .utility) { [weak self] in
                guard let self = self else { return }
                self.recognitionTask?.cancel()
                if let oldEngine = self.audioEngine {
                    if oldEngine.isRunning { oldEngine.stop() }
                    if oldEngine.inputNode.numberOfInputs > 0 {
                        oldEngine.inputNode.removeTap(onBus: 0)
                    }
                }
                self.recognitionTask = task
                self.statusMessage = "Recognition task running"
                print("Speech recognition started")
            }
        }
    }

    private func handleRecognitionStop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleRecognitionStop() }
            return
        }

        // Check if we were actually recording to avoid double-stop logic
        if !isRecording { return }

        print("[SpeechRecognition] Recognition stopped, cleaning up")
        isRecording = false
        lastStopTime = Date()

        if let engine = audioEngine {
            engine.stop()
            if engine.inputNode.numberOfInputs > 0 {
                engine.inputNode.removeTap(onBus: 0)
            }
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil

        // Auto-restart if authorized
        if isAuthorized {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }

                if let lastStop = self.lastStopTime,
                   Date().timeIntervalSince(lastStop) < self.minimumRestartInterval
                {
                    print("[SpeechRecognition] Skipping auto-restart - too soon after stop")
                    return
                }

                guard !self.isRecording, self.isAuthorized else {
                    print("[SpeechRecognition] Skipping auto-restart - already recording or not authorized")
                    return
                }
                print("Auto-restarting recognition")
                self.startRecording()
            }
        }
    }

    public func stopRecording() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopRecording() }
            return
        }

        guard isRecording else { return }

        print("Stopping audio engine")
        if let engine = audioEngine {
            engine.stop()
            if engine.inputNode.numberOfInputs > 0 {
                engine.inputNode.removeTap(onBus: 0)
            }
        }

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        audioEngine = nil
        isRecording = false
        sentenceWorkItem?.cancel()
        sentenceWorkItem = nil

        statusMessage = "Stopped"
        print("Speech recognition stopped")
    }

    private func maybeEmitSentence(from text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = [".", "?", "!"].contains { trimmed.hasSuffix($0) }

        sentenceWorkItem?.cancel()

        if isFinal || ended {
            // Emit faster if we detect punctuation or finality
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let current = self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !current.isEmpty, current != self.lastEmittedSentence else { return }
                self.lastEmittedSentence = current
                self.onSentenceRecognized?(current)
                self.recognizedText = ""
            }
            sentenceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        } else {
            // Emit eventually if the user pauses for a long time
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let current = self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !current.isEmpty, current != self.lastEmittedSentence else { return }
                self.lastEmittedSentence = current
                self.onSentenceRecognized?(current)
                self.recognizedText = ""
            }
            sentenceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
        }
    }

    public func reset() {
        stopRecording()
        DispatchQueue.main.async {
            self.recognizedText = ""
            self.lastEmittedSentence = ""
        }
    }
}
