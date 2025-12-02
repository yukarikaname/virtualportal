//
//  ConversationStateManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

import Foundation
import Combine

/// Manages overall conversation state and coordinates between managers
@MainActor
public final class ConversationStateManager: ObservableObject {
    public static let shared = ConversationStateManager()

    @Published public private(set) var lastVLMSummary: String = ""

    private let speechManager = SpeechConversationManager.shared
    private let llmManager = LLMConversationManager.shared
    private let autoCommentaryManager = AutoCommentaryManager.shared

    private var cancellables = Set<AnyCancellable>()
    private var conversationTurnCount: Int = 0
    private var isPaused: Bool = false

    private init() {
        setupNotifications()
    }

    private func setupNotifications() {
        // Observe user sentence recognition
        NotificationCenter.default.publisher(for: Notification.Name("SpeechConversationManager.userSentenceRecognized"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let sentence = notification.userInfo?["sentence"] as? String {
                    Task {
                        await self.handleUserSentence(sentence)
                    }
                }
            }
            .store(in: &cancellables)

        // Observe AI speech requests from auto commentary
        NotificationCenter.default.publisher(for: Notification.Name("AutoCommentaryManager.requestAISpeech"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let userText = notification.userInfo?["userText"] as? String,
                   let vlmContext = notification.userInfo?["vlmContext"] as? String {
                    Task {
                        await self.handleAIRequest(userText, vlmContext: vlmContext)
                    }
                }
            }
            .store(in: &cancellables)

        // Observe VLM output changes
        VLMModelManager.shared.$currentOutput
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.lastVLMSummary = text
            }
            .store(in: &cancellables)
    }

    public func start() {
        speechManager.startSpeechRecognition()
    }

    private func handleUserSentence(_ sentence: String) async {
        // Get vision context
        let vlmContext = await MainActor.run { lastVLMSummary }

        // Update speech manager state
        await MainActor.run {
            speechManager.setGenerating(true)
            speechManager.stopSpeech()
        }

        // Stream LLM response
        await llmManager.streamResponse(userText: sentence, visionContext: vlmContext) { [weak self] (chunk: String, finished: Bool) in
            guard let self = self else { return }

            Task { @MainActor in
                if !chunk.isEmpty {
                    // Remove command syntax and sanitize
                    var cleanChunk = chunk
                        .replacingOccurrences(of: #"\[COMMAND:.*?\]"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"\[MEMORY:.*?\]"#, with: "", options: .regularExpression)
                    // Apply emoji/duplicate removal
                    cleanChunk = self.sanitizeChunk(cleanChunk)

                    if !cleanChunk.trimmingCharacters(in: .whitespaces).isEmpty {
                        speechManager.speakStreamingChunk(cleanChunk)
                    }
                }

                if finished {
                    speechManager.setGenerating(false)
                    conversationTurnCount += 1
                    autoCommentaryManager.updateLastAutoSpeakTime()
                    print("Conversation turn \(conversationTurnCount) complete")
                }
            }
        }
    }

    private func handleAIRequest(_ userText: String, vlmContext: String) async {
        // Update speech manager state
        await MainActor.run {
            speechManager.setGenerating(true)
            speechManager.stopSpeech()
        }

        // Stream LLM response
        await llmManager.streamResponse(userText: userText, visionContext: vlmContext) { [weak self] (chunk: String, finished: Bool) in
            guard let self = self else { return }

            Task { @MainActor in
                if !chunk.isEmpty {
                    // Remove command syntax and sanitize
                    var cleanChunk = chunk
                        .replacingOccurrences(of: #"\[COMMAND:.*?\]"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"\[MEMORY:.*?\]"#, with: "", options: .regularExpression)
                    // Apply emoji/duplicate removal
                    cleanChunk = self.sanitizeChunk(cleanChunk)

                    if !cleanChunk.trimmingCharacters(in: .whitespaces).isEmpty {
                        speechManager.speakStreamingChunk(cleanChunk)
                    }
                }

                if finished {
                    speechManager.setGenerating(false)
                    autoCommentaryManager.updateLastAutoSpeakTime()
                    print("Speech request complete")
                }
            }
        }
    }

    /// Public API to trigger the LLM/TTS pipeline without user speech
    public func speakAI(overrideUserPrompt: String? = nil) {
        Task {
            let userText = overrideUserPrompt ?? ""
            let vlmContext = await MainActor.run { lastVLMSummary }
            await handleAIRequest(userText, vlmContext: vlmContext)
        }
    }

    public func stop() {
        print("Stopping ConversationStateManager...")
        llmManager.cancelCurrentTask()
        speechManager.stopSpeechRecognition()
        speechManager.stopSpeech()
    }

    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        print("Pausing ConversationStateManager...")

        llmManager.cancelCurrentTask()
        speechManager.pause()
        speechManager.setGenerating(false)
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        print("Resuming ConversationStateManager...")

        speechManager.resume()
    }

    // MARK: - Sanitization
    private func sanitizeChunk(_ text: String) -> String {
        // Strip emojis
        let patterns = [
            "[\\u{1F300}-\\u{1F9FF}]",
            "[\\u{1FA70}-\\u{1FAFF}]",
            "[\\u{2600}-\\u{26FF}]",
            "[\\u{2700}-\\u{27BF}]"
        ]
        var s = text
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        // Collapse whitespace
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove consecutive duplicate words only
        let words = s.split(separator: " ")
        var filtered: [String.SubSequence] = []
        for word in words {
            if filtered.last != word {
                filtered.append(word)
            }
        }
        return filtered.joined(separator: " ")
    }
}