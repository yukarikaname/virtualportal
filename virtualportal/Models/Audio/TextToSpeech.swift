//
//  TextToSpeech.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import Foundation
import AVFoundation
import Combine

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
    
    @MainActor
    private override init() {
        super.init()
        synthesizer.delegate = self
        checkPersonalVoiceAvailability()
        loadSettings()
    }
    
    private func loadSettings() {
        usePersonalVoice = UserDefaults.standard.bool(forKey: "usePersonalVoice")
    }
    
    private func checkPersonalVoiceAvailability() {
        Task {
            // Check for Personal Voice availability (iOS 17+)
            if #available(iOS 17.0, *) {
                let voices = AVSpeechSynthesisVoice.speechVoices()
                personalVoice = voices.first { voice in
                    voice.voiceTraits.contains(.isPersonalVoice)
                }
                personalVoiceAvailable = personalVoice != nil
                
                if personalVoiceAvailable {
                    print("Personal Voice available")
                } else {
                    print("Personal Voice not available, using default voice")
                }
            } else {
                personalVoiceAvailable = false
                print("Personal Voice requires iOS 17+")
            }
        }
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
            // Speak all at once
            speakImmediately(text)
        }
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
        guard !speechQueue.isEmpty else { return }
        
        isProcessingQueue = true
        let chunk = speechQueue.removeFirst()
        speakImmediately(chunk)
    }
    
    @MainActor
    private func speakImmediately(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        
        // Use Personal Voice if available and enabled
            if #available(iOS 17.0, *), usePersonalVoice, personalVoiceAvailable, let personalVoice = personalVoice {
            utterance.voice = personalVoice
            print("Using Personal Voice")
        } else {
            // Use default high-quality English voice
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            if usePersonalVoice && !personalVoiceAvailable {
                print("Personal Voice requested but not available, using default voice")
            }
        }
        
        // Configure speech parameters
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        // Configure audio session for playback
        configureAudioSession()
        
        isSpeaking = true
        synthesizer.speak(utterance)
        
    // speaking text
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
        Task { @MainActor in
            // Process next chunk if available
            if !speechQueue.isEmpty {
                processQueue()
            } else {
                isProcessingQueue = false
                isSpeaking = false
            }
        }
    }
    
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isProcessingQueue = false
            isSpeaking = false
        }
    }
}
