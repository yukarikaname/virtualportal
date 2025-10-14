//
//  SpeechRecognition.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import Combine
import Foundation

#if os(iOS)
    @preconcurrency import Speech
    import AVFoundation

    public final class SpeechRecognitionManager: NSObject, ObservableObject {
        public static let shared = SpeechRecognitionManager()

        @Published public private(set) var recognizedText: String = ""
        @Published public private(set) var isRecording: Bool = false
        @Published public private(set) var isAuthorized: Bool = false

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

        // Public method to check current permission status
        public func checkPermissions() -> (microphone: Bool, speechRecognition: Bool) {
            let micGranted = AVAudioApplication.shared.recordPermission == .granted
            let speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
            return (micGranted, speechGranted)
        }

        private override init() {
            super.init()
            speechRecognizer = SFSpeechRecognizer(
                locale: Locale(identifier: Locale.preferredLanguages.first ?? "en-US"))
            requestAuthorizationIfNeeded()
        }

        private func requestAuthorizationIfNeeded() {
            // First check/request microphone permission
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                checkSpeechRecognitionPermission()
            case .denied:
                print("Microphone permission denied")
                DispatchQueue.main.async { self.isAuthorized = false }
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.checkSpeechRecognitionPermission()
                        } else {
                            print("Microphone permission denied by user")
                            self?.isAuthorized = false
                        }
                    }
                }
            @unknown default:
                DispatchQueue.main.async { self.isAuthorized = false }
            }
        }

        private func checkSpeechRecognitionPermission() {
            let status = SFSpeechRecognizer.authorizationStatus()

            switch status {
            case .authorized:
                self.isAuthorized = true
                print("Speech recognition authorized")
            case .notDetermined:
                // Request authorization
                SFSpeechRecognizer.requestAuthorization { [weak self] status in
                    DispatchQueue.main.async {
                        let isAuth = (status == .authorized)
                        self?.isAuthorized = isAuth
                        if isAuth {
                            print("Speech recognition authorized")
                        } else {
                            print("Speech recognition denied")
                        }
                    }
                }
            default:
                self.isAuthorized = false
                print("Speech recognition not authorized")
            }
        }

        public func start() { startRecording() }

        public func startRecording() {
            // Check basic conditions synchronously
            guard !isRecording else { return }

            // Check authorization status
            let authStatus = SFSpeechRecognizer.authorizationStatus()
            if authStatus == .notDetermined {
                print("Speech recognition permission not determined - requesting...")
                requestAuthorizationIfNeeded()
                return
            }

            guard isAuthorized else {
                print("Speech recognition not authorized. Please grant permissions in Settings.")
                return
            }

            // Do the heavy setup work asynchronously to not block the caller
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.performStartRecordingAsync()
            }
        }

        private func performStartRecordingAsync() async {
            // Double-check on main actor
            let shouldStart = await MainActor.run { [weak self] in
                guard let self else { return false }
                guard !self.isRecording else { return false }
                guard self.isAuthorized else { return false }

                // Set flag immediately to prevent race conditions
                self.isRecording = true
                return true
            }

            guard shouldStart else { return }

            performStartRecording()
        }

        private func performStartRecording() {
            // Don't start if already recording
            guard !isRecording else {
                print("[SpeechRecognition] Already recording, skipping")
                return
            }

            // Check authorization
            guard isAuthorized else {
                print("[SpeechRecognition] Not authorized, cannot start")
                return
            }

            // Check recognizer availability
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                print("[SpeechRecognition] Speech recognizer not available")
                return
            }

            // Immediately set flag to prevent double-start
            let wasRecording = isRecording
            isRecording = true

            // Do ALL the heavy lifting in background to avoid blocking main thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    DispatchQueue.main.async {
                        if let self = self {
                            self.isRecording = wasRecording
                        }
                    }
                    return
                }

                // Configure audio session - use playAndRecord to allow TTS to work simultaneously
                let audioSession = AVAudioSession.sharedInstance()
                do {
                    try audioSession.setCategory(
                        .playAndRecord, mode: .default,
                        options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
                    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                } catch {
                    print("Audio session error: \(error.localizedDescription)")
                    DispatchQueue.main.async { [weak self] in
                        self?.isRecording = wasRecording
                    }
                    return
                }

                // Create recognition request
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                request.requiresOnDeviceRecognition = false

                // Setup audio engine
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

                // Install tap
                input.installTap(onBus: 0, bufferSize: 1024, format: format) {
                    [weak request] buf, _ in
                    request?.append(buf)
                }

                // Prepare and start engine
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

                // Capture recognizer outside of @Sendable closure
                nonisolated(unsafe) let unsafeRecognizer = recognizer

                // Create recognition task
                let task = unsafeRecognizer.recognitionTask(with: request) {
                    [weak self] result, error in
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

                        if isFinal {
                            shouldStop = true
                        }
                    }

                    if let error = error as NSError? {
                        if error.domain != "kAFAssistantErrorDomain" || error.code != 216 {
                            print("Recognition error: \(error.localizedDescription)")
                        }
                        shouldStop = true
                    }

                    if shouldStop {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                            self?.handleRecognitionStop()
                        }
                    }
                }

                // Update state on main thread - ONLY after everything is ready
                // Use low priority to not block UI
                DispatchQueue.main.async(qos: .utility) { [weak self] in
                    guard let self = self else { return }

                    // Clean up old resources first
                    self.recognitionTask?.cancel()
                    if let oldEngine = self.audioEngine {
                        if oldEngine.isRunning {
                            oldEngine.stop()
                        }
                        if oldEngine.inputNode.numberOfInputs > 0 {
                            oldEngine.inputNode.removeTap(onBus: 0)
                        }
                    }

                    // Set new resources
                    self.recognitionTask = task
                    self.audioEngine = engine
                    self.recognitionRequest = request

                    print("Speech recognition started")
                }
            }
        }

        private func handleRecognitionStop() {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in
                    self?.handleRecognitionStop()
                }
                return
            }

            guard isRecording else {
                print("[SpeechRecognition] Already stopped in handleRecognitionStop")
                return
            }

            print("[SpeechRecognition] Recognition stopped, cleaning up")

            // Set flag immediately to prevent concurrent calls
            isRecording = false
            lastStopTime = Date()

            // Stop audio engine
            if let engine = audioEngine {
                engine.stop()
                if engine.inputNode.numberOfInputs > 0 {
                    engine.inputNode.removeTap(onBus: 0)
                }
            }

            // Clean up
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            recognitionTask = nil
            audioEngine = nil

            // Auto-restart after delay if authorized
            if isAuthorized {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { return }

                    // Check cooldown period to prevent rapid restart loops
                    if let lastStop = self.lastStopTime,
                        Date().timeIntervalSince(lastStop) < self.minimumRestartInterval
                    {
                        print("[SpeechRecognition] Skipping auto-restart - too soon after stop")
                        return
                    }

                    // Double-check we're not already recording (from another restart)
                    guard !self.isRecording, self.isAuthorized else {
                        print("[SpeechRecognition] Skipping auto-restart - already recording")
                        return
                    }
                    print("Auto-restarting recognition")
                    self.startRecording()
                }
            }
        }

        public func stopRecording() {
            // stopRecording called

            // CRITICAL: Must be on main queue according to Apple docs
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in
                    self?.stopRecording()
                }
                return
            }

            guard isRecording else {
                print("[SpeechRecognition] Already stopped, returning")
                return
            }

            print("Stopping audio engine")
            // Stop and clean up audio engine safely
            if let engine = audioEngine {
                engine.stop()
                if engine.inputNode.numberOfInputs > 0 {
                    engine.inputNode.removeTap(onBus: 0)
                }
            }

            print("Ending recognition request")
            // End recognition request
            recognitionRequest?.endAudio()
            recognitionRequest = nil

            print("Canceling recognition task")
            // Cancel recognition task
            recognitionTask?.cancel()
            recognitionTask = nil

            print("Cleaning up and setting isRecording = false")
            // Clean up
            audioEngine = nil
            isRecording = false
            sentenceWorkItem?.cancel()
            sentenceWorkItem = nil

            print("Speech recognition stopped")
        }

        private func maybeEmitSentence(from text: String, isFinal: Bool) {
            // maybeEmitSentence called
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ended = [".", "?", "!"].contains { trimmed.hasSuffix($0) }

            // Cancel any pending work item
            sentenceWorkItem?.cancel()

            // If final or has punctuation, emit immediately
            if isFinal || ended {
                print(
                    "🔍 [SpeechRecognition] Sentence ready to emit immediately (isFinal or punctuation)"
                )
                let workItem = DispatchWorkItem { [weak self] in
                    // work item executing
                    guard let self else {
                        // self is nil in work item
                        return
                    }
                    let current = self.recognizedText.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    guard !current.isEmpty, current != self.lastEmittedSentence else {
                        // Skipping - empty or duplicate sentence
                        return
                    }
                    self.lastEmittedSentence = current
                    // calling onSentenceRecognized callback
                    self.onSentenceRecognized?(current)
                    // callback returned, clearing recognizedText
                    self.recognizedText = ""
                }
                sentenceWorkItem = workItem
                // scheduling work item for 0.5s
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
            } else {
                // If not final and no punctuation, wait 2 seconds of silence before emitting
                // scheduling delayed emit after 2s
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let current = self.recognizedText.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    guard !current.isEmpty, current != self.lastEmittedSentence else {
                        return
                    }
                    // Emitting sentence after pause
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
#else
    // Stub for non-iOS platforms to avoid API differences during cross-platform builds.
    public final class SpeechRecognitionManager: NSObject, ObservableObject {
        public static let shared = SpeechRecognitionManager()
        @Published public private(set) var recognizedText: String = ""
        @Published public private(set) var isRecording: Bool = false
        @Published public private(set) var isAuthorized: Bool = false
    }
#endif
