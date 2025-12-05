//
//  LipSyncController.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/9/25.
//

import Foundation
import RealityKit
@preconcurrency import Combine
import AVFoundation

/// Controls lip sync animation using blendshapes
/// Integrates with TTS to animate mouth movements in sync with speech
@MainActor
public class LipSyncController: NSObject, ObservableObject {
    public static let shared = LipSyncController()
    
    // MARK: - Published Properties
    @Published public var isActive: Bool = false
    
    // MARK: - Dependencies
    private let characterController = ModelRenderer.shared
    private let tts = TextToSpeechManager.shared
    
    // MARK: - Animation State
    private var currentAnimationTask: Task<Void, Never>?
    private var speechSynthesizer: AVSpeechSynthesizer?
    private var cancellables = Set<AnyCancellable>()
    // Language selection removed — phoneme extraction is script-driven
    
    // MARK: - Timing
    private var phonemeTimings: [(phoneme: String, startTime: TimeInterval, duration: TimeInterval)] = []
    private var animationStartTime: TimeInterval = 0
    private var lastAnimationTickTime: CFTimeInterval = 0
    private var lastBlendshapeValues: [String: Float] = [:]
    private var currentUtteranceLength: Int = 0
    
    // MARK: - Initialization
    private override init() {
        super.init()
        setupTTSCallbacks()
    }
    
    deinit {
        cancellables.removeAll()
        currentAnimationTask?.cancel()
    }
    
    // MARK: - Public Methods
    
    /// Start lip sync for the given text with specified language
    public func startLipSync(for text: String) async {
        let clean = sanitizeText(text)
        guard !clean.isEmpty else { return }
        
        stopLipSync() // Stop any ongoing animation
        
        isActive = true
        print("Starting lip sync for text: \(clean)")

        currentUtteranceLength = clean.count
        lastAnimationTickTime = 0
        lastBlendshapeValues.removeAll()
        for viseme in LipSyncMap.Viseme.allCases {
            let name = LipSyncMap.blendshapeName(for: viseme)
            lastBlendshapeValues[name] = 0.0
        }

        let phonemes = await LipSyncMap.phonemes(from: clean)
        
        // Create basic timing (simplified - in reality, you'd get this from TTS)
        createBasicTiming(for: phonemes, text: clean)
        
        // Start animation
        animateLipSync()
    }
    
    /// Stop lip sync animation
    public func stopLipSync() {
        // Debounce duplicate stops
        guard isActive else { return }
        isActive = false
        currentAnimationTask?.cancel()
        currentAnimationTask = nil

        // Reset to neutral mouth
        Task { @MainActor in
            await resetMouth()
        }

        phonemeTimings.removeAll()
        lastBlendshapeValues.removeAll()
        lastAnimationTickTime = 0
        currentUtteranceLength = 0
        print("Stopped lip sync")
    }
    
    /// Start lip sync synchronized with TTS
    public func startLipSyncWithTTS(text: String) async {
        let clean = sanitizeText(text)
        guard !clean.isEmpty else { return }
        
        stopLipSync()
        isActive = true
        
        print("Starting lip sync with TTS for text: \(clean)")
        
        // For now, use basic timing. In a full implementation,
        // you'd extract phoneme timings from the TTS engine
        await startLipSync(for: clean)
    }
    
    // MARK: - Private Methods
    
    private func setupTTSCallbacks() {
        // Listen to TTS speaking state
        tts.$isSpeaking
            .sink { [weak self] isSpeaking in
                if !isSpeaking {
                    // TTS finished, stop lip sync after a short delay
                    Task { @MainActor in
                        // If another stop is already in progress, don't double-stop
                        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                        self?.stopLipSync()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func createBasicTiming(for phonemes: [String], text: String) {
        phonemeTimings.removeAll()
        
        // Estimate total duration roughly proportional to text length
        let adjustedTotalDuration = Double(text.count) * 0.1

        // Avoid division by zero
        let count = max(1, phonemes.count)
        let phonemeDuration = adjustedTotalDuration / Double(count)
        
        var currentTime: TimeInterval = 0
        
        for phoneme in phonemes {
            phonemeTimings.append((
                phoneme: phoneme,
                startTime: currentTime,
                duration: phonemeDuration
            ))
            currentTime += phonemeDuration
        }
    }

    
    
    private func animateLipSync() {
        currentAnimationTask = Task {
            animationStartTime = CACurrentMediaTime()
            
            while !Task.isCancelled && isActive {
                let now = CACurrentMediaTime()
                let currentTime = now - animationStartTime
                let dt = lastAnimationTickTime > 0 ? (now - lastAnimationTickTime) : (1.0 / 60.0)
                lastAnimationTickTime = now
                
                // Find current phoneme
                if let currentPhoneme = phonemeTimings.first(where: { timing in
                    currentTime >= timing.startTime && currentTime < timing.startTime + timing.duration
                }) {
                    // Smoothly move blendshapes toward the target viseme based on sentence length
                    let currentViseme = LipSyncMap.viseme(for: currentPhoneme.phoneme)
                    let alpha = smoothingAlpha(dt: dt, length: currentUtteranceLength)

                    for viseme in LipSyncMap.Viseme.allCases {
                        let name = LipSyncMap.blendshapeName(for: viseme)
                        let target: Float = (viseme == currentViseme) ? 1.0 : 0.0
                        let current = lastBlendshapeValues[name] ?? 0.0
                        let next = lerp(from: current, to: target, alpha: alpha)
                        lastBlendshapeValues[name] = next
                        await setBlendShape(name: name, value: next)
                    }
                } else if currentTime > phonemeTimings.last?.startTime ?? 0 + (phonemeTimings.last?.duration ?? 0) {
                    // Animation finished
                    await resetMouth()
                    break
                }
                
                // Wait for next frame
                try? await Task.sleep(nanoseconds: 16_666_667) // ~60fps
            }
        }
    }
    
    private func smoothingAlpha(dt: Double, length: Int) -> Float {
        // Map sentence length to speed: shorter -> faster, longer -> slower
        let minSpeed = 0.7
        let maxSpeed = 1.4
        let k = 40.0
        let speed = minSpeed + (maxSpeed - minSpeed) * exp(-Double(length) / k)
        let tau = 0.06 // seconds
        let alpha = 1.0 - exp(-speed * dt / tau)
        return Float(max(0.0, min(1.0, alpha)))
    }

    // Remove emojis/non-word symbols, collapse whitespace, cap length
    private func sanitizeText(_ input: String) -> String {
        // Strip common emoji ranges and non-ASCII symbols
        let filtered = input.unicodeScalars.filter { scalar in
            // Keep basic ASCII and Latin letters/punctuation
            return scalar.value <= 0x007E || CharacterSet.alphanumerics.union(CharacterSet.whitespacesAndNewlines).union(CharacterSet.punctuationCharacters).contains(scalar)
        }
        var s = String(String.UnicodeScalarView(filtered))
        // Collapse whitespace
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Split into sentences by ., !, ? and dedupe consecutive identical sentences
        let sentences = s.split(whereSeparator: { ".!?".contains($0) })
        var unique: [String] = []
        var last: String?
        for raw in sentences {
            let sentence = raw.trimmingCharacters(in: .whitespaces)
            if sentence.isEmpty { continue }
            if last != sentence { unique.append(sentence); last = sentence }
            if unique.count >= 2 { break } // cap to 2 sentences
        }
        s = unique.joined(separator: ". ")

        // Remove consecutive duplicate words (common streaming artifact)
        let words = s.split(separator: " ")
        var dedupWords: [Substring] = []
        var prev: Substring?
        for w in words {
            if prev != w { dedupWords.append(w); prev = w }
        }
        s = dedupWords.joined(separator: " ")

        // Cap to a reasonable length for lip sync
        if s.count > 240 { s = String(s.prefix(240)) }
        return s
    }

    private func lerp(from: Float, to: Float, alpha: Float) -> Float {
        return from + (to - from) * alpha
    }
    
    private func resetMouth() async {
        // Reset all mouth blendshapes to 0
        let allVisemes = LipSyncMap.Viseme.allCases
        for viseme in allVisemes {
            let blendshapeName = LipSyncMap.blendshapeName(for: viseme)
            await setBlendShape(name: blendshapeName, value: 0.0)
            lastBlendshapeValues[blendshapeName] = 0.0
        }
    }
    
    private func setBlendShape(name: String, value: Float) async {
        characterController.setBlendShape(name: name, value: value)
    }
}

