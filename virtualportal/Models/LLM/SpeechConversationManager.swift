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
        // Perform permission check on MainActor
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            let perms = PermissionManager.checkPermissions()
            
            // Update speech authorization if needed
            if !perms.speechRecognition || !perms.microphone {
                print("Speech recognition not authorized. Mic: \(perms.microphone), Speech: \(perms.speechRecognition)")
            }
            
            // Start continuous speech recognition handler
            self.speech.onSentenceRecognized = { [weak self] sentence in
                // Handle on background thread to avoid blocking UI
                Task.detached { [weak self] in
                    await self?.handleUserSentence(sentence)
                }
            }

            // Check if authorized and start
            guard self.speech.isAuthorized else {
                print("Speech recognition will start once permissions are granted")
                // The startRecording method will request permissions if needed
                self.speech.start()
                return
            }

            print("Starting speech recognition")
            self.speech.start()
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
    
    /// Speak SSML markup with optional lip sync
    public func speakSSML(_ ssml: String, withLipSync: Bool = true) {
        Task { @MainActor in
            // Note: SSML may contain markup that doesn't have plain text equivalent
            // For lip sync, we can extract plain text or skip lip sync
            if withLipSync {
                // Extract plain text from SSML for lip sync approximation
                let plainText = self.extractPlainTextFromSSML(ssml)
                await self.lipSync.startLipSyncWithTTS(text: plainText)
            }
            self.tts.speakSSML(ssml)
        }
    }
    
    /// Speak using SSML builder with optional lip sync
    public func speakWithSSML(withLipSync: Bool = true, builder: (SSMLBuilder) -> SSMLBuilder) {
        let ssmlBuilder = builder(SSMLBuilder())
        speakSSML(ssmlBuilder.build(), withLipSync: withLipSync)
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
    
    /// Speak a streaming chunk with SSML support
    /// Converts text to SSML if it contains markup/emphasis, otherwise uses plain text
    public func speakStreamingChunkWithSSML(_ chunk: String, withLipSync: Bool = true, tone: String = "friendly") {
        Task { @MainActor in
            let clean = Self.sanitize(chunk)
            
            // Check if chunk contains SSML markers or emphasis markers
            let hasSSMLMarkers = clean.contains("*") || clean.contains("_") || clean.contains("<")
            
            if hasSSMLMarkers {
                // Convert to SSML
                let llmManager = LLMConversationManager.shared
                let ssml = llmManager.convertToSSML(clean)
                
                if withLipSync {
                    // Extract plain text for lip sync
                    let plainText = self.extractPlainTextFromSSML(ssml)
                    if !self.lipSync.isActive {
                        await self.lipSync.startLipSyncWithTTS(text: plainText)
                    }
                }
                
                self.tts.speakSSML(ssml)
            } else {
                // Plain text - use normal TTS
                if withLipSync {
                    if !self.lipSync.isActive {
                        await self.lipSync.startLipSyncWithTTS(text: clean)
                    }
                }
                self.tts.speak(clean, streaming: false)
            }
        }
    }
    
    /// Enable SSML mode for all streaming speech
    private var useSSMLMode: Bool {
        return UserDefaults.standard.bool(forKey: "useSSMLSpeech") ?? true
    }
    
    /// Set whether to use SSML for speech
    public func setUseSSML(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "useSSMLSpeech")
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
    
    /// Extract plain text from SSML for lip sync purposes
    private func extractPlainTextFromSSML(_ ssml: String) -> String {
        var text = ssml
        
        // Remove XML declaration
        text = text.replacingOccurrences(of: "<?xml[^?]*\\?>", with: "", options: .regularExpression)
        
        // Remove SSML tags but keep content
        text = text.replacingOccurrences(of: "<speak>", with: "")
        text = text.replacingOccurrences(of: "</speak>", with: "")
        
        // Remove prosody tags
        text = text.replacingOccurrences(of: "<prosody[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</prosody>", with: "")
        
        // Remove emphasis tags
        text = text.replacingOccurrences(of: "<emphasis[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</emphasis>", with: "")
        
        // Remove break tags
        text = text.replacingOccurrences(of: "<break[^>]*/>", with: "", options: .regularExpression)
        
        // Remove voice tags
        text = text.replacingOccurrences(of: "<voice[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</voice>", with: "")
        
        // Remove say-as tags but keep content
        text = text.replacingOccurrences(of: "<say-as[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</say-as>", with: "")
        
        // Remove sentence/paragraph tags
        text = text.replacingOccurrences(of: "<[sp]>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</[sp]>", with: "", options: .regularExpression)
        
        // Clean up HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        
        // Clean up whitespace
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return text
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