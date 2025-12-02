//
//  SpeechConversationManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

import Foundation
import Combine
import AVFoundation

/// Manages speech recognition, text-to-speech, and lip sync coordination
@MainActor
public final class SpeechConversationManager: ObservableObject {
    public static let shared = SpeechConversationManager()

    private let speech = SpeechRecognitionManager.shared
    private let tts = TextToSpeechManager.shared
    private let lipSync = LipSyncController.shared

    @Published public private(set) var isGenerating: Bool = false
    @Published public private(set) var lastUserSentence: String = ""

    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupSpeechInterruptionObserver()
    }

    private func setupSpeechInterruptionObserver() {
#if os(iOS)
        // Observe partial speech recognition to interrupt AI if needed
        SpeechRecognitionManager.shared.$recognizedText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                // Read user preference from UserDefaults (default true)
                let autoInterrupt = UserDefaults.standard.object(forKey: "autoInterruptEnabled") as? Bool ?? true
                if autoInterrupt {
                    // Interrupt any ongoing AI generation/speech
                    Task { @MainActor in
                        if self.isGenerating {
                            print("[SpeechConversationManager] Interrupting AI due to user speech")
                        }
                        self.stopSpeech()
                    }
                }
            }
            .store(in: &cancellables)
#endif
    }

    public func startSpeechRecognition() {
        // Check permissions status
        _ = PermissionManager.checkPermissions()

        // Check if speech recognition is authorized
        if !speech.isAuthorized {
            print("Speech recognition not authorized. Please grant permissions.")
            return
        }

        // Start continuous speech recognition handler
        speech.onSentenceRecognized = { [weak self] sentence in
            // Handle on background thread to avoid blocking UI
            Task.detached { [weak self] in
                await self?.handleUserSentence(sentence)
            }
        }

        // Start speech recognition asynchronously
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let isAuthorized = await MainActor.run { self.speech.isAuthorized }
            guard isAuthorized else {
                print("Speech recognition not authorized yet")
                return
            }

            print("Starting speech recognition")

            // Start speech recognition - the manager dispatches internally
            await MainActor.run {
                self.speech.start()
            }
        }
    }

    private func handleUserSentence(_ sentence: String) async {
        print("User: \(sentence)")

        // Update UI state on main thread
        await MainActor.run {
            self.lastUserSentence = sentence
        }

        // Notify other managers that user spoke
        NotificationCenter.default.post(
            name: Notification.Name("SpeechConversationManager.userSentenceRecognized"),
            object: nil,
            userInfo: ["sentence": sentence]
        )
    }

    public func speakText(_ text: String, withLipSync: Bool = true) {
        Task { @MainActor in
            let clean = Self.sanitize(text)
            if withLipSync {
                // Start lip sync when speaking begins
                await self.lipSync.startLipSyncWithTTS(text: clean)
            }
            self.tts.speak(clean, streaming: false)
        }
    }

    public func speakStreamingChunk(_ chunk: String, withLipSync: Bool = true) {
        Task { @MainActor in
            let clean = Self.sanitize(chunk)
            if withLipSync {
                // Start lip sync when speaking begins
                if !self.lipSync.isActive {
                    await self.lipSync.startLipSyncWithTTS(text: clean)
                }
            }
            self.tts.speak(clean, streaming: false)
        }
    }

    public func stopSpeech() {
        tts.stop()
        // Stop lip sync with delay to let TTS finish
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            await MainActor.run {
                self.lipSync.stopLipSync()
            }
        }
    }

    public func stopSpeechRecognition() {
        speech.stopRecording()
    }

    public func pause() {
        speech.stopRecording()
        tts.stop()
    }

    public func resume() {
        if speech.isAuthorized {
            speech.start()
        }
    }

    // MARK: - State Management

    public func setGenerating(_ generating: Bool) {
        Task { @MainActor in
            self.isGenerating = generating
        }
    }
}

// MARK: - Sanitization helpers
extension SpeechConversationManager {
    static func sanitize(_ text: String) -> String {
        var s = text
        let patterns = [
            "[\\u{1F300}-\\u{1F9FF}]",
            "[\\u{1FA70}-\\u{1FAFF}]",
            "[\\u{2600}-\\u{26FF}]",
            "[\\u{2700}-\\u{27BF}]"
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove consecutive duplicate words
        let words = s.split(separator: " ")
        var filtered: [String.SubSequence] = []
        for word in words {
            if filtered.last != word {
                filtered.append(word)
            }
        }
        s = filtered.joined(separator: " ")
        
        // Keep short streaming chunks; cap length
        return String(s.prefix(240))
    }
}