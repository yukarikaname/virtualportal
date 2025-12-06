//
//  TextToSpeechManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import Foundation
import AVFoundation
import Combine
import UIKit

@MainActor
public class TextToSpeechManager: NSObject, ObservableObject {
    public static let shared = TextToSpeechManager()
    
    @Published public var isSpeaking: Bool = false
    @Published public var usePersonalVoice: Bool = false
    @Published public var personalVoiceAvailable: Bool = false
    
    @MainActor private let synthesizer = AVSpeechSynthesizer()
    private var personalVoice: AVSpeechSynthesisVoice?
    private var speechQueue: [String] = []
    private var isProcessingQueue: Bool = false
    private var willEnterForegroundObserver: NSObjectProtocol?
    
    @MainActor
    private override init() {
        super.init()
        synthesizer.delegate = self
        checkPersonalVoiceAvailability()
        // Default to preferring Personal Voice; actual use depends on availability.
        usePersonalVoice = true
        
        // Refresh personal voice availability when returning to foreground
        willEnterForegroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPersonalVoiceAvailability()
            }
        }
    }

    @MainActor
    deinit {
        if let observer = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    
    private func checkPersonalVoiceAvailability() {
        // We must request permission before the voice appears in speechVoices()
        PermissionManager.requestPersonalVoicePermission { [weak self] granted in
            Task { @MainActor in
                guard let self = self else { return }
                
                if granted {
                    // Permission granted: Now we can see the voices
                    let voices = AVSpeechSynthesisVoice.speechVoices()
                    self.personalVoice = voices.first { voice in
                        return voice.voiceTraits.contains(.isPersonalVoice)
                    }
                    self.personalVoiceAvailable = self.personalVoice != nil
                    
                    if !self.personalVoiceAvailable {
                         print("Personal Voice Authorized, but no voice created in Settings yet.")
                    }
                } else {
                    self.personalVoiceAvailable = false
                    print("Personal Voice not available or denied.")
                }
            }
        }
    }

    /// Public: refresh personal voice availability synchronously
    /// Note: This will only return true if permission was ALREADY granted.
    public func refreshPersonalVoiceAvailability() -> Bool {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        personalVoice = voices.first { voice in
            return voice.voiceTraits.contains(.isPersonalVoice)
        }
        personalVoiceAvailable = personalVoice != nil

        return personalVoiceAvailable
    }
    
    /// Speak text with streaming support - splits by punctuation
    @MainActor
    public func speak(_ text: String, streaming: Bool = true) {
        guard !text.isEmpty else { return }
        
        if streaming {
            // Split text into chunks by punctuation
            let chunks = splitTextByPunctuation(text)
            for chunk in chunks {
                if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    speechQueue.append(chunk)
                }
            }
            processQueue()
        } else {
            // Add to queue without splitting (already chunked by caller)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                speechQueue.append(trimmed)
                processQueue()
            }
        }
    }
    
    /// Speak SSML markup
    /// - Parameters:
    ///   - ssml: Valid SSML string (e.g., from SSMLBuilder.build())
    ///   - Note: Personal Voice is compatible with SSML. The voice property is set before SSML processing,
    ///     allowing Personal Voice to be used with SSML prosody markup.
    @MainActor
    public func speakSSML(_ ssml: String) {
        guard !ssml.isEmpty else { return }
        
        // SSML is not split - it's sent as a single utterance
        speechQueue.append(ssml)
        processQueue()
    }
    
    /// Speak with SSMLBuilder convenience
    /// - Parameters:
    ///   - builder: Closure that builds SSML
    @MainActor
    public func speakWithSSML(_ builder: (SSMLBuilder) -> SSMLBuilder) {
        let ssmlBuilder = builder(SSMLBuilder())
        speakSSML(ssmlBuilder.build())
    }
    
    private func splitTextByPunctuation(_ text: String) -> [String] {
        var chunks: [String] = []
        var currentChunk = ""
        
        for char in text {
            currentChunk.append(char)
            
            // Split at sentence-ending punctuation
            if char == "." || char == "," || char == "!" || char == "?" || char == ";" {
                let trimmed = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunks.append(trimmed)
                }
                currentChunk = ""
            }
        }
        
        // Add remaining text
        let trimmed = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            chunks.append(trimmed)
        }
        
        return chunks
    }
    
    @MainActor
    private func processQueue() {
        guard !isProcessingQueue else { return }
        guard !speechQueue.isEmpty else {
            isProcessingQueue = false
            isSpeaking = false
            return
        }
        
        isProcessingQueue = true
        let chunk = speechQueue.removeFirst()
        speakImmediately(chunk)
    }
    
    @MainActor
    private func speakImmediately(_ text: String) {
        // Check if text is SSML (starts with <?xml or <speak)
        let isSSML = text.trimmingCharacters(in: .whitespaces).hasPrefix("<?xml") || 
                     text.trimmingCharacters(in: .whitespaces).hasPrefix("<speak")
        
        let utterance: AVSpeechUtterance
        
        if isSSML {
            // Use SSML initialization
            if let ssmlUtterance = AVSpeechUtterance(ssmlRepresentation: text) {
                utterance = ssmlUtterance
                print("Speaking SSML markup")
            } else {
                print("Invalid SSML markup, falling back to plain text")
                utterance = AVSpeechUtterance(string: text)
            }
        } else {
            // Plain text initialization
            utterance = AVSpeechUtterance(string: text)
        }
        
        // Use Personal Voice if available and enabled
        if usePersonalVoice, personalVoiceAvailable, let personalVoice = personalVoice {
            utterance.voice = personalVoice
            print("Using Personal Voice")
        } else {
            utterance.voice = AVSpeechSynthesisVoice()
            if usePersonalVoice && !personalVoiceAvailable {
                print("Personal Voice requested but not available, using default voice")
            }
        }
        
        // Configure speech parameters
        // NOTE: For SSML utterances, rate and pitchMultiplier are ignored
        // Prosody is controlled via SSML tags instead
        if !isSSML {
            let rate = UserDefaults.standard.double(forKey: "speechRate")
            if rate > 0 {
                utterance.rate = Float(rate)
            } else {
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            }
            utterance.pitchMultiplier = 1.0
        }
        utterance.volume = 1.0
        
        // Configure audio session for playback
        configureAudioSession()
        
        isSpeaking = true
        synthesizer.speak(utterance)
    }
    
    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Use playAndRecord to allow both TTS and speech recognition (input + output)
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            // audio session configured for TTS
        } catch {
            print("Failed to configure audio session for TTS: \(error)")
        }
    }
    
    @MainActor
    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speechQueue.removeAll()
        isProcessingQueue = false
        isSpeaking = false
    }
    
    @MainActor
    public func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }
    
    @MainActor
    public func resume() {
        synthesizer.continueSpeaking()
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension TextToSpeechManager: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Mark current processing as complete
            self.isProcessingQueue = false
            
            // Process next chunk if available
            if !self.speechQueue.isEmpty {
                self.processQueue()
            } else {
                // All chunks processed
                self.isSpeaking = false
            }
        }
    }
    
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.speechQueue.removeAll()
            self.isProcessingQueue = false
            self.isSpeaking = false
        }
    }
}
