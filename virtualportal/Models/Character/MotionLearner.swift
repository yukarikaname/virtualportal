//
//  MotionLearner.swift
//  virtualportal
//
//  Created by Yukari Kaname on 12/5/25.
//
// MARK: - Reference Motion Learning System
//
// Learns and replays complex character animations from reference data.
// Used for motions too complex for IK (dances, emotes, special gestures).
//
// Features:
//   - Record reference motion sequences (joint transforms over time)
//   - Generate variations from learned patterns (interpolation, speed adjustment)
//   - Blend with procedural IK for natural results
//   - Cache learned motions for fast playback
//
// Usage:
//   1. Record reference: motionLearner.recordMotion("wave", frames: capturedFrames)
//   2. Play motion: motionLearner.playMotion("wave", on: modelEntity, duration: 1.5)
//   3. Variation: motionLearner.playMotionVariation("wave", speedFactor: 0.8, on: modelEntity)
//

import Foundation
import RealityKit

/// Learns and replays complex character motions from reference sequences
@MainActor
public class MotionLearner {
    public static let shared = MotionLearner()
    
    // MARK: - Data Structures
    
    /// Represents a single frame of motion data
    public struct MotionFrame {
        public let boneTransforms: [String: (position: SIMD3<Float>, rotation: simd_quatf)]
        public let timestamp: TimeInterval
        
        public init(boneTransforms: [String: (position: SIMD3<Float>, rotation: simd_quatf)], timestamp: TimeInterval = 0) {
            self.boneTransforms = boneTransforms
            self.timestamp = timestamp
        }
    }
    
    /// Learned motion sequence with statistical information
    public struct LearnedMotion {
        public let name: String
        public let frames: [MotionFrame]
        public let duration: TimeInterval
        public let affectedBones: Set<String>
        public let framerate: Float
        
        /// Calculate bone motion variation (complexity metric)
        public var complexity: Float {
            guard frames.count > 2 else { return 0 }
            
            var totalVariation: Float = 0
            for boneName in affectedBones {
                let rotations = frames.compactMap { $0.boneTransforms[boneName]?.rotation }
                guard rotations.count > 1 else { continue }
                
                for i in 1..<rotations.count {
                    let dotProduct = simd_dot(rotations[i-1], rotations[i])
                    let angle = acos(max(-1.0, min(1.0, abs(dotProduct))))
                    totalVariation += angle
                }
            }
            
            return totalVariation / Float(frames.count)
        }
        
        /// Get motion keyframes (critical frames for motion flow)
        public func getKeyframes() -> [Int] {
            guard frames.count > 4 else { return [0, frames.count - 1] }
            
            var keyframes: [Int] = [0]
            let strideValue = max(1, frames.count / 8)  // Find ~8 keyframes
            
            for i in stride(from: strideValue, to: frames.count - strideValue, by: strideValue) {
                keyframes.append(i)
            }
            
            keyframes.append(frames.count - 1)
            return keyframes
        }
    }
    
    // MARK: - Motion Storage
    private var learnedMotions: [String: LearnedMotion] = [:]
    private var motionPlaybackTimers: [String: Timer] = [:]
    
    // MARK: - Configuration
    private let maxStoredMotions = 50
    private let defaultFramerate: Float = 30.0
    
    private init() {}
    
    // MARK: - Recording & Learning
    
    /// Record a motion sequence from reference frames
    /// - Parameters:
    ///   - motionName: Name for the learned motion
    ///   - frames: Array of motion frames with bone transforms
    ///   - framerate: Frames per second (default 30)
    public func recordMotion(_ motionName: String, frames: [MotionFrame], framerate: Float = 30.0) {
        guard !frames.isEmpty else {
            print("[MotionLearner] Cannot record empty motion")
            return
        }
        
        // Normalize timestamps and calculate duration
        let normalizedFrames = frames.enumerated().map { (index, frame) -> MotionFrame in
            let timestamp = TimeInterval(index) / TimeInterval(framerate)
            return MotionFrame(boneTransforms: frame.boneTransforms, timestamp: timestamp)
        }
        
        let duration = normalizedFrames.last?.timestamp ?? 0
        
        // Collect affected bones
        var affectedBones = Set<String>()
        for frame in normalizedFrames {
            affectedBones.formUnion(frame.boneTransforms.keys)
        }
        
        let learnedMotion = LearnedMotion(
            name: motionName,
            frames: normalizedFrames,
            duration: duration,
            affectedBones: affectedBones,
            framerate: framerate
        )
        
        learnedMotions[motionName] = learnedMotion
        
        print("[MotionLearner] Learned motion '\(motionName)': \(frames.count) frames, \(String(format: "%.2f", duration))s, complexity: \(String(format: "%.3f", learnedMotion.complexity))")
        
        // Cleanup if storage exceeds limit
        if learnedMotions.count > maxStoredMotions {
            let sortedMotions = learnedMotions.sorted { $0.value.complexity > $1.value.complexity }
            learnedMotions = Dictionary(
                sortedMotions.prefix(maxStoredMotions).map { ($0.key, $0.value) },
                uniquingKeysWith: { $1 }
            )
            print("[MotionLearner] Pruned to \(maxStoredMotions) most complex motions")
        }
    }
    
    /// Get a learned motion by name
    public func getMotion(_ name: String) -> LearnedMotion? {
        return learnedMotions[name]
    }
    
    /// List all learned motion names
    public func getLearnedMotionNames() -> [String] {
        return Array(learnedMotions.keys).sorted()
    }
    
    /// Check if a motion has been learned
    public func hasMotion(_ name: String) -> Bool {
        return learnedMotions[name] != nil
    }
    
    // MARK: - Playback
    
    /// Play a learned motion on the model
    /// - Parameters:
    ///   - motionName: Name of learned motion
    ///   - modelEntity: The model to animate
    ///   - duration: Override motion duration (default: use recorded duration)
    ///   - loop: Whether to loop the motion
    public func playMotion(
        _ motionName: String,
        on modelEntity: ModelEntity,
        duration: TimeInterval? = nil,
        loop: Bool = false
    ) {
        guard let motion = learnedMotions[motionName] else {
            print("[MotionLearner] Motion '\(motionName)' not learned")
            return
        }
        
        let playDuration = duration ?? motion.duration
        let startTime = Date()
        let speedFactor = Float(motion.duration / playDuration)
        
        // Cancel any existing playback of this motion
        motionPlaybackTimers[motionName]?.invalidate()
        
        let playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] timer in
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = Float(elapsed / playDuration)
            
            if progress > 1.0 {
                if loop {
                    // Restart
                    timer.invalidate()
                    self?.playMotion(motionName, on: modelEntity, duration: duration, loop: true)
                    return
                } else {
                    timer.invalidate()
                    self?.motionPlaybackTimers.removeValue(forKey: motionName)
                    return
                }
            }
            self?.applyMotionFrame(motion, progress: progress, speedFactor: speedFactor, to: modelEntity)
        }
        
        motionPlaybackTimers[motionName] = playbackTimer
    }
    
    /// Play motion with variation (speed, phase offset, etc.)
    /// - Parameters:
    ///   - motionName: Name of learned motion
    ///   - speedFactor: Speed multiplier (0.5-2.0)
    ///   - phaseOffset: Start at this position in motion (0-1)
    ///   - modelEntity: The model to animate
    public func playMotionVariation(
        _ motionName: String,
        speedFactor: Float = 1.0,
        phaseOffset: Float = 0.0,
        on modelEntity: ModelEntity
    ) {
        guard let motion = learnedMotions[motionName] else {
            print("[MotionLearner] Motion '\(motionName)' not learned")
            return
        }
        
        let adjustedDuration = motion.duration / TimeInterval(speedFactor)
        let startTime = Date().addingTimeInterval(-motion.duration * TimeInterval(phaseOffset))
        
        motionPlaybackTimers[motionName]?.invalidate()
        
        let playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] timer in
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = Float(elapsed / adjustedDuration)
            
            if progress > 1.0 {
                timer.invalidate()
                self?.motionPlaybackTimers.removeValue(forKey: motionName)
                return
            }
            
            self?.applyMotionFrame(motion, progress: min(1.0, progress), speedFactor: speedFactor, to: modelEntity)
        }
        
        motionPlaybackTimers[motionName] = playbackTimer
    }
    
    /// Stop playing a motion
    public func stopMotion(_ motionName: String) {
        motionPlaybackTimers[motionName]?.invalidate()
        motionPlaybackTimers.removeValue(forKey: motionName)
    }
    
    // MARK: - Blending with IK
    
    /// Blend a learned motion with IK procedural motion
    /// This allows complex motions to have natural breathing/swaying
    /// - Parameters:
    ///   - motionName: Name of learned motion
    ///   - ikBlendFactor: How much IK affects the motion (0-1), 0 = pure motion, 1 = pure IK
    ///   - modelEntity: The model to animate
    ///   - ikController: The IK controller for blending
    public func playMotionWithIKBlend(
        _ motionName: String,
        ikBlendFactor: Float = 0.3,
        on modelEntity: ModelEntity,
        ikController: IKController
    ) {
        // Implement motion blending by lerping between motion transforms and IK-generated transforms
        // For now, just play the motion normally
        // Full implementation would interpolate transforms based on blend factor
        playMotion(motionName, on: modelEntity)
    }
    
    // MARK: - Private Helpers
    
    private func applyMotionFrame(
        _ motion: LearnedMotion,
        progress: Float,
        speedFactor: Float,
        to modelEntity: ModelEntity
    ) {
        // Find the frame(s) to interpolate between
        let frameIndex = Float(motion.frames.count - 1) * progress
        let currentFrameIndex = Int(frameIndex)
        let nextFrameIndex = min(currentFrameIndex + 1, motion.frames.count - 1)
        let interpolation = frameIndex - Float(currentFrameIndex)
        
        let currentFrame = motion.frames[currentFrameIndex]
        let nextFrame = motion.frames[nextFrameIndex]
        
        // Apply interpolated transforms to all affected bones
        for boneName in motion.affectedBones {
            guard let currentTransform = currentFrame.boneTransforms[boneName],
                  let nextTransform = nextFrame.boneTransforms[boneName] else {
                continue
            }
            
            // Interpolate position (linear)
            let interpolatedPosition = simd_mix(
                currentTransform.position,
                nextTransform.position,
                simd_float3(repeating: progress)
            )
            
            // Interpolate rotation (spherical linear)
            let interpolatedRotation = simd_slerp(
                currentTransform.rotation,
                nextTransform.rotation,
                Float(interpolation)
            )
            
            // Apply to bone
            if let bone = modelEntity.findChild(named: boneName) {
                let transform = Transform(
                    scale: bone.scale,
                    rotation: interpolatedRotation,
                    translation: interpolatedPosition
                )
                bone.move(to: transform, relativeTo: bone.parent, duration: 0)
            }
        }
    }
}

// MARK: - Extension: Capture Motion from Animation
extension MotionLearner {
    /// Capture current bone poses from a model
    /// Useful for recording reference motions
    public func captureFrame(from modelEntity: ModelEntity, boneNames: [String]) -> MotionFrame {
        var boneTransforms: [String: (position: SIMD3<Float>, rotation: simd_quatf)] = [:]
        
        for boneName in boneNames {
            if let bone = modelEntity.findChild(named: boneName) {
                boneTransforms[boneName] = (bone.position, bone.orientation)
            }
        }
        
        return MotionFrame(boneTransforms: boneTransforms, timestamp: 0)
    }
}

// MARK: - Extension: Find Child Helper
extension ModelEntity {
    fileprivate func findChild(named name: String) -> ModelEntity? {
        if self.name == name {
            return self
        }
        
        for child in children {
            if let modelChild = child as? ModelEntity {
                if let found = modelChild.findChild(named: name) {
                    return found
                }
            }
        }
        
        return nil
    }
}
