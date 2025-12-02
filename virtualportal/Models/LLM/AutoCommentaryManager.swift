//
//  AutoCommentaryManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

import Foundation
import Combine

/// Manages automatic commentary based on VLM observations
@MainActor
public final class AutoCommentaryManager: ObservableObject {
        @MainActor static let shared = AutoCommentaryManager()

    @Published public var autoCommentaryEnabled: Bool = true

    // Auto-commentary cooldown tracking
    private var lastAutoSpeakTime: Date? = nil
    private var lastAutoSpokenSummary: String = ""
    private let autoCommentaryCooldown: TimeInterval = 15.0

    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupVLMObserver()
        setupSettingsObserver()
    }

    private func setupVLMObserver() {
#if os(iOS)
        VLMModelManager.shared.$currentOutput
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.global(qos: .utility))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                Task { @MainActor in
                    await self?.maybeTriggerAutoSpeak(with: text)
                }
            }
            .store(in: &cancellables)
#endif
    }

    private func setupSettingsObserver() {
#if os(iOS)
        // Observe UserDefaults changes and update autoCommentaryEnabled
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.autoCommentaryEnabled = UserDefaults.standard.bool(forKey: "autoCommentaryEnabled")
                }
            }
            .store(in: &cancellables)

        // Initialize from persisted setting
        self.autoCommentaryEnabled = UserDefaults.standard.object(forKey: "autoCommentaryEnabled") as? Bool ?? true
#endif
    }

    @MainActor
    private func maybeTriggerAutoSpeak(with text: String) async {
        guard autoCommentaryEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Check if speech conversation manager is currently generating
        let isGenerating = SpeechConversationManager.shared.isGenerating
        guard !isGenerating else { return }

        // Cooldown check
        if let last = lastAutoSpeakTime,
           Date().timeIntervalSince(last) < autoCommentaryCooldown {
            return
        }

        // Prevent repeating same summary
        if !lastAutoSpokenSummary.isEmpty && trimmed == lastAutoSpokenSummary {
            return
        }

        // Ask the LLM whether it should speak. The LLM will return a short decision.
        Task.detached { [weak self] in
            guard let self else { return }
            let decision = await LLMConversationManager.shared.decideWhetherToSpeak(vision: trimmed)
            guard let decision = decision else { return }

            if decision.shouldSpeak {
                // Update last summary immediately on main actor to avoid duplicates while speaking
                await MainActor.run {
                    self.lastAutoSpokenSummary = trimmed
                }

                if let utterance = decision.utterance, !utterance.isEmpty {
                    // LLM returned a suggested utterance - speak it directly
                    await self.handleAIRequest(utterance)
                } else {
                    // No suggested utterance - let LLM generate full response with VLM context
                    await self.handleAIRequest(nil)
                }
            }
        }
    }

    private func handleAIRequest(_ overrideUserPrompt: String?) async {
        // Build prompt using optional override (or empty user string)
        let userText = overrideUserPrompt ?? ""

        // Gather vision context on main actor
        let vlmContext = await MainActor.run { VLMModelManager.shared.currentOutput }

        // Notify that we want to trigger AI speech
        NotificationCenter.default.post(
            name: Notification.Name("AutoCommentaryManager.requestAISpeech"),
            object: nil,
            userInfo: [
                "userText": userText,
                "vlmContext": vlmContext
            ]
        )
    }

    public func updateLastAutoSpeakTime() {
        lastAutoSpeakTime = Date()
    }
}