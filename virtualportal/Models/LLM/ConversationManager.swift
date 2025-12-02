//
//  ConversationManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

import Foundation
import Combine

/// Main conversation manager that coordinates between specialized managers
@MainActor
public final class ConversationManager: ObservableObject {

    @MainActor static let shared = ConversationManager()

    // Forward published properties from specialized managers
    @Published public private(set) var lastUserSentence: String = ""
    @Published public private(set) var lastVLMSummary: String = ""
    @Published public private(set) var lastLLMResponse: String = ""
    @Published public private(set) var isGenerating: Bool = false
    @Published public var autoCommentaryEnabled: Bool = true

    private let stateManager = ConversationStateManager.shared
    private let speechManager = SpeechConversationManager.shared
    private let autoCommentaryManager = AutoCommentaryManager.shared
    private let llmManager = LLMConversationManager.shared

    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupPropertyForwarding()
    }

    private func setupPropertyForwarding() {
        // Forward properties from specialized managers
        speechManager.$lastUserSentence
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastUserSentence)

        speechManager.$isGenerating
            .receive(on: DispatchQueue.main)
            .assign(to: &$isGenerating)

        stateManager.$lastVLMSummary
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastVLMSummary)

        autoCommentaryManager.$autoCommentaryEnabled
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoCommentaryEnabled)

        llmManager.$lastLLMResponse
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastLLMResponse)
    }
    
    public func start() {
        stateManager.start()
    }

    /// Public API to trigger the LLM/TTS pipeline without user speech.
    public func speakAI(overrideUserPrompt: String? = nil) {
        stateManager.speakAI(overrideUserPrompt: overrideUserPrompt)
    }

    public func stop() {
        stateManager.stop()
    }

    public func pause() {
        stateManager.pause()
    }

    public func resume() {
        stateManager.resume()
    }
}
