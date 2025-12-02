//
//  ConversationViewModel.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

import Foundation
import Combine

/// ViewModel for conversation/AI interaction
/// Coordinates speech, VLM, LLM, and TTS
@MainActor
public class ConversationViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published public var lastUserSentence: String = ""
    @Published public var lastVLMSummary: String = ""
    @Published public var lastLLMResponse: String = ""
    @Published public var isGenerating: Bool = false
    @Published public var isSpeaking: Bool = false
    @Published public var isRecording: Bool = false
    
    // MARK: - Dependencies
    private let conversationManager = ConversationManager.shared
    private let speechManager = SpeechRecognitionManager.shared
    private let ttsManager = TextToSpeechManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    public init() {
        setupBindings()
    }
    
    private func setupBindings() {
        // Bind to ConversationManager
        conversationManager.$lastUserSentence
            .assign(to: &$lastUserSentence)
        
        conversationManager.$lastVLMSummary
            .assign(to: &$lastVLMSummary)
        
        conversationManager.$lastLLMResponse
            .assign(to: &$lastLLMResponse)
        
        conversationManager.$isGenerating
            .assign(to: &$isGenerating)
        
        // Bind to TTS
        ttsManager.$isSpeaking
            .assign(to: &$isSpeaking)
        
        // Bind to Speech Recognition
        speechManager.$isRecording
            .assign(to: &$isRecording)
    }
    
    // MARK: - Public Methods
    
    /// Start conversation pipeline
    public func startConversation() {
        conversationManager.start()
    }
    
    /// Stop conversation pipeline
    public func stopConversation() {
        conversationManager.stop()
    }
    
    /// Check if speech recognition is authorized
    public var isAuthorized: Bool {
        speechManager.isAuthorized
    }
    
    /// Check permissions
    public func checkPermissions() -> (microphone: Bool, speechRecognition: Bool) {
        PermissionManager.checkPermissions()
    }
    
    /// Manually trigger speech recognition
    public func startListening() {
        speechManager.start()
    }
    
    /// Stop listening
    public func stopListening() {
        speechManager.stopRecording()
    }
    
    /// Stop TTS
    public func stopSpeaking() {
        ttsManager.stop()
    }
}
